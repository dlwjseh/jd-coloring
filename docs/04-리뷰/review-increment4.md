> ## ✅ 반영 결과 (2026-06-01)
> 검수 후, **라인아트 변환 기능 제거**(기획 변경)와 맞물려 지적 사항을 모두 반영함. macOS BUILD SUCCEEDED + 실행 검증(갤러리 진입·도안 1개 그리드 표시, 크래시 없음).
> - **[중간 #1] 표시용 썸네일 분리 — 해결.** `Template`을 `imageData`(색칠용 1400px) + `thumbnailData`(그리드용 480px)로 **분리 저장**. `TemplateCellView`는 `thumbnailData`만 디코딩(`TemplateCellView.swift`). 풀해상 PNG의 그리드 디코딩 제거.
> - **[중간 #2] `artworkByTemplate` body 경로 재계산 — 해결.** `grid`에서 `let lookup = artworkByTemplate`로 **1회만 계산**해 셀/컨텍스트메뉴가 공유(`GalleryView.swift` `grid`). 셀당 2회 전체 재스캔 제거.
> - **[낮음 #3] `@Query` 전체 fetch — 해결.** `init(profile:)`에서 `#Predicate { $0.profile?.persistentModelID == pid }`로 **현재 프로필 작업물만 fetch**. (관계==모델 직접 비교는 predicate 미지원이라 `persistentModelID` 비교로 구현)
> - **[낮음] `originalData` 미사용 보관 — 해결.** 변환 제거로 원본 별도 보관 필드 자체를 삭제(`Template`에서 제거).
> - **[정보] `LineArtConverter` — 제거됨.** 변환 기능 폐지로 파일 삭제. 관련 강점/지적(인코딩·CIContext 등)은 해당 없음 처리.
> - 남은 `ThumbnailCache` 키(`data.hashValue`) 비용은 낮음으로 유지(현 규모 영향 미미).

# 성능 검수 리포트 — Increment 4 (화면 2 "색칠 도안 갤러리" · LineArt 변환 · 그리드 셀)

대상: `/Users/JD/workspace/jd-coloring/jdColoring/` 화면 2 신규/변경 .swift 파일
검수일: 2026-06-01
관점: iOS/macOS(SwiftUI) 성능 — `body` 재계산, LazyVGrid 셀 렌더, 이미지 디코딩/다운샘플, Core Image 변환, SwiftData `@Query` 클라이언트 필터링, 메인스레드/메모리, 네비게이션 재생성. 향후 채색 단계로 이어질 위험 패턴 포함.
방침: 코드 수정 없음. 진단·권고만. 실제 코드 라인 근거로만 판단. 불확실은 '확인 필요' 표기. 빌드는 macOS BUILD SUCCEEDED 상태(기능 버그가 아닌 성능 관점).

---

## 검수 대상 확인 (먼저 점검)

- **화면 2 진입**: `UserSelectionView.swift:102-104`의 `.navigationDestination(item: $selected)`에서 `GalleryView(profile:)` 생성. 프로필 선택(`selectProfile`, `:238-240`) → `selected` 설정 → 네비게이션 push. 구조 확인.
- **신규 모델**: `Template`(전역 공유 도안, `lineArtData`/`originalData` 외부저장 + cascade 작업물), `Artwork`(프로필×도안 1개, `progressThumbnail` 외부저장) 확인.
- **신규 유틸**: `LineArtConverter`(Core Image 라인아트 변환), 기존 `ImageDownsampler`/`ThumbnailCache` 재사용 확인.
- **신규 뷰**: `GalleryView`(@Query 2개 + `artworkByTemplate` computed), `TemplateCellView`(셀), `TemplateUploadView`(시트 + 백그라운드 변환), `GridEntrance`(stagger) 확인.

---

## 총평

화면 2는 **변환 파이프라인의 백그라운드 분리(`TemplateUploadView`의 `Task.detached` 병렬)와 stagger 연출의 `value:` 고정(`GridEntrance`)이 견고**하고, increment 1~3에서 다진 패턴(do/catch save, `persistentModelID` 안정 id, `ThumbnailCache` 디코딩 캐시 재사용, alert 삭제 순서 선-nil 정리)을 잘 계승했다. 메인스레드에서 도는 무거운 Core Image 변환은 없다.

다만 이번 화면 특유의 **두 가지 구조적 성능 문제**가 뚜렷하다. (1) **`artworkByTemplate` computed property가 매 `body` 평가마다 `@Query allArtworks` 전체를 순회해 Dictionary를 새로 만든다** — 그리드 셀 수만큼 룩업까지 더해 도안·작업물·프로필이 늘수록 비용이 곱으로 커지고, stagger·삭제·시트 애니메이션이 도는 동안 매 프레임 재구성될 수 있다(중간). (2) **`TemplateCellView`가 최대 1400px PNG 라인아트(`lineArtData`)를 ~200pt 셀 썸네일로 풀해상도 디코딩**한다 — 표시용 다운샘플이 없어 셀 하나당 수 MB급 디코딩 비트맵이 `ThumbnailCache`(NSCache)에 도안 수만큼 누적된다(중간/메모리). 여기에 `@Query allArtworks` 전체 fetch + 클라이언트 필터(낮음, 확장성), `data.hashValue` 캐시 키의 함의(낮음), PNG 인코딩/`originalData` 중복 저장(낮음/정보) 등이 남는다. retain cycle·명백한 메인 블로킹은 없다.

---

## 발견 항목

### [중간] `artworkByTemplate` computed property — 매 `body` 평가마다 `@Query allArtworks` 전체 순회 + 셀당 룩업
- **위치**: `Views/GalleryView.swift:23-29`(computed), `:12`(`@Query allArtworks`), `:148-154`(`ForEach` 내부에서 `artworkByTemplate[...]` 2회 호출), `:235`(`resetArtwork`에서 1회 더)
- **문제**:
  - `artworkByTemplate`는 **저장 프로퍼티가 아니라 computed property**다. 즉 SwiftUI가 `GalleryView.body`를 평가할 때마다(`grid` 빌드 시 `:150`/`:154`에서 접근), **`allArtworks` 전체를 `for` 루프로 순회**(`:25`)하며 `profile` 일치 필터 + `art.template`별 Dictionary를 **매번 새로 구성**한다. body가 자주 재평가되면 이 O(전체 작업물 수) 구성이 그 빈도만큼 반복된다.
  - body 재평가를 부르는 트리거가 이 화면에 다수다: `appeared`(stagger, `:15/:68-71`), `isUploadPresented`(시트 등장/`opacity` 토글, `:16/:39/:56/:61`), `pendingDelete`(alert, `:17/:78-83`). 특히 시트 등장은 `.spring` 애니메이션(`:20/:206-207`)으로 토글되어 **애니메이션이 도는 프레임마다 body가 재평가**될 수 있다. 그때마다 Dictionary 전체 재구성이 동반된다(확인 필요 — SwiftUI가 동일 입력에 대해 body를 스킵하는지는 보장되지 않으며, `@State` 변화가 끼면 재평가가 강제됨).
  - 비용은 **곱으로 증가**한다: `grid`의 `ForEach`(`:148`)가 도안 수 N만큼 돌고, 각 셀에서 `artworkByTemplate[...]`를 `TemplateCellView` 인자(`:150`)와 `contextMenu` 가드(`:154`)로 **2번** 호출한다. computed라 매 호출마다 전체 재구성이면 N개 셀 × 작업물 M = O(N·M)가 한 body당 발생한다(딕셔너리 재생성 자체가 매 접근마다 일어나므로). 가족 단위 소량(도안 수십·작업물 수십)에선 체감 전이나, 도안/프로필이 누적되면(전역 공유 도안이라 식구 수 × 도안 수만큼 작업물이 생김) 빠르게 커진다.
- **근거**: `:23` `private var artworkByTemplate: [...] { ... }`는 computed(저장/캐시 아님). `:25`가 `allArtworks` 전체 순회. `:150`과 `:154`가 같은 body 안에서 각각 접근. `@Query allArtworks`(`:12`)는 필터 없는 전체 fetch라 M이 곧 전역 작업물 총수.
- **권고**:
  - Dictionary 구성을 **body 평가 경로에서 분리**하라. 방향: (a) `allArtworks`/`templates` 변화에만 반응해 한 번 계산하도록 별도 타입(`@Observable` 모델 또는 `.task(id:)`로 채우는 `@State` 캐시)으로 옮겨, body는 만들어진 Dictionary를 **참조만** 하게 한다. (b) 최소한 `grid` 빌드 직전에 **지역 상수로 한 번만** 스냅샷해 `ForEach` 안에서 셀당 재구성을 막는다(현재는 computed 접근이 N×2회라 한 번으로 줄이는 것만으로도 큰 차이).
  - 더 근본적으로는 아래 [낮음] "`@Query allArtworks` 전체 fetch + 클라이언트 필터" 항목과 함께, **현재 프로필 작업물만 가져오는 predicate `@Query`** 또는 `template.artworks` 관계 탐색으로 M을 "이 프로필의 작업물"로 줄이는 방안 검토.
  - 컬러링 앱은 그리드 스크롤·진입 연출이 핵심 체감 지점(requirements 60fps 계열 요구)이라, 스크롤/애니메이션 중 Dictionary 전체 재구성은 우선 제거 권장.

### [중간] `TemplateCellView`가 최대 1400px PNG 라인아트를 ~200pt 셀에 풀해상도 디코딩 — 표시용 썸네일 부재 + NSCache 메모리 누적
- **위치**: `Views/Components/TemplateCellView.swift:9-10`(`displayData`), `:20`(`ThumbnailCache.image(for: displayData)`), 연계 `Models/Template.swift:10`(`lineArtData` 외부저장), `LineArtConverter.swift:17`(`maxPixel: 1400`), `TemplateUploadView.swift:157`(변환 호출), `Utilities/ThumbnailCache.swift:18-26`
- **문제**:
  - 셀은 `displayData = artwork?.progressThumbnail ?? template.lineArtData`(`:10`)를 `ThumbnailCache.image(for:)`로 디코딩해 표시한다. **미착수 도안(작업물 없음 또는 `progressThumbnail == nil`)에선 `lineArtData`를 그대로 쓴다.** `lineArtData`는 `LineArtConverter.convert(_, maxPixel: 1400)`(TemplateUploadView.swift:157)이 만든 **최대 1400px PNG**다.
  - 그런데 셀의 표시 크기는 `GridItem(.adaptive(minimum: 190, maximum: 240))`(GalleryView.swift:19)에 `padding(22)`(`:24`)를 뺀 **~150~200pt** 수준이다. 즉 1400px 이미지를 200pt(@2x 400px, @3x 600px) 영역에 그리려고 **풀해상도로 디코딩**한다. `ThumbnailCache`는 `PlatformImage(data:)`로 디코딩하는데(ThumbnailCache.swift:23) 이는 **표시 크기와 무관하게 전체 픽셀을 디코딩**한다 — `ImageDownsampler`의 `CGImageSourceCreateThumbnailAtIndex`(디코딩 단계 축소)와 달리 다운샘플이 없다.
  - **메모리 영향**: 1400×1400 비트맵은 디코딩 시 약 1400·1400·4 ≈ **7.8MB**(픽셀당 RGBA 4바이트). `ThumbnailCache`는 이 디코딩 결과(`PlatformImage`)를 NSCache에 **도안마다 보관**한다(`:24`). 미착수 도안 N개면 ~7.8MB×N가 NSCache에 쌓인다(작업물 썸네일은 더 작을 수 있으나 `progressThumbnail`의 해상도는 채색 화면에서 확정 — 확인 필요). 도안 20개면 ~150MB로 iPad에서 메모리 경고·축출(jetsam) 위험. increment 1~2가 프로필 썸네일을 512px JPEG로 다운샘플한 것과 대조적으로, **도안 셀은 표시용 썸네일 단계가 통째로 빠져 있다.**
  - **디코딩 비용**: 셀이 처음 보일 때(스크롤로 lazy 실체화) 1400px PNG 디코딩이 **메인스레드에서 동기로**(`ThumbnailCache.image(for:)`가 `body` 안에서 호출, `:20`) 일어난다. PNG는 무손실 압축이라 JPEG보다 디코딩이 무겁다. 캐시 미스 시 스크롤 중 프레임 드랍 가능. 첫 진입 stagger(`GridEntrance`)와 겹치면 더 체감된다.
- **근거**: `TemplateCellView.swift:10`이 `template.lineArtData`(1400px PNG)를 표시 데이터로 사용. `:20`이 `ThumbnailCache.image(for: displayData)`. `ThumbnailCache.swift:23`은 `PlatformImage(data:)` 전체 디코딩(다운샘플 없음). `LineArtConverter.swift:17` `maxPixel: 1400`. 셀 표시 영역은 `GalleryView.swift:19` adaptive 190~240 - padding 22.
- **권고**:
  - **그리드 표시용 썸네일을 별도로 둬라.** 방향: (a) 도안 저장 시 `lineArtData`(색칠 베이스, 고해상)와 별개로 **그리드용 다운샘플 썸네일(예: 400~600px)**을 만들어 `Template`에 보관하고 셀은 그것을 표시. 색칠 캔버스만 풀해상 `lineArtData`를 로드. (b) 또는 `ThumbnailCache`에 **표시 픽셀 상한을 받는 다운샘플 경로**를 추가해(`ImageDownsampler.thumbnailData`처럼 `CGImageSourceCreateThumbnailAtIndex` 사용) 셀이 풀해상 대신 축소본을 디코딩·캐시하게 한다.
  - 디코딩을 **백그라운드로** 분리하는 것도 검토(첫 표시 시 메인 동기 디코딩 → `.task`로 비동기 디코딩 후 채우기). 다운샘플과 병행하면 효과가 크다.
  - 이 항목은 **메모리(축출 위험)와 스크롤 프레임 양쪽**에 걸린 화면 2 핵심 이슈로, [중간]에서도 우선순위 높음.

### [낮음] `@Query allArtworks` 전체 fetch + 클라이언트 필터링 — 전역 공유 도안 구조상 확장성 취약
- **위치**: `Views/GalleryView.swift:12`(`@Query private var allArtworks: [Artwork]`), `:25`(`where art.profile?... == profile...` 클라이언트 필터)
- **문제**:
  - `@Query`에 predicate가 없어 **모든 프로필·모든 도안의 작업물을 전부 fetch**한 뒤, `artworkByTemplate`에서 `profile` 일치만 메모리에서 거른다(`:25`). `Template`이 **전역 공유**(Template.swift:4 주석 "누군가 올리면 모든 프로필이 함께 본다")라, 작업물 총수는 대략 **식구 수 × 도안 수**로 늘어난다. 가족 5명 × 도안 30개면 150개, 더 늘면 선형 증가.
  - 현재 규모(가족 단위)에선 무해하나, fetch가 전부를 끌어오고 그중 1/식구수만 쓰는 구조라 **데이터·정렬·역직렬화 비용이 화면과 무관하게 커진다.** `allArtworks`는 `progressThumbnail`(외부저장 Data) 관계를 포함해, 필터로 버려질 타 프로필 작업물의 모델 인스턴스화 비용도 든다(외부저장이라 Data 본문은 지연 로드일 수 있음 — 확인 필요).
  - 위 [중간] `artworkByTemplate`와 결합되면 비용이 곱해진다(M이 전역 총수).
- **근거**: `:12` 필터 없는 `@Query`. `:25` 클라이언트 측 `where`. `Template`은 프로필 미연관 전역(Template.swift), `Artwork`만 `profile`/`template` 보유(Artwork.swift:11-12).
- **권고**:
  - `@Query`에 **predicate를 걸어 현재 프로필의 작업물만** 가져오라(예: `#Predicate<Artwork> { $0.profile?.persistentModelID == ... }` — 단, `@Query`는 뷰 생성 시 `profile` 캡처가 필요해 init 주입 또는 `@Query` 동적 구성 검토). 또는 **`Profile.artworks` 역관계**(현재 미정의 — 확인 필요)나 `template.artworks` 관계 탐색으로 N+1 없이 좁히는 방안.
  - 현 규모 무해이나 전역 공유 도안 특성상 식구·도안이 함께 늘면 가장 먼저 표면화될 확장성 항목. increment 2 [낮음] "@Query 전체 fetch"와 같은 계열이며, 여기선 **클라이언트 필터까지 겹쳐** 한 단계 더 무겁다.

### [낮음] `ThumbnailCache` 키가 `data.hashValue` — 대형 Data 해시 비용 + 충돌·잔존 함의
- **위치**: `Utilities/ThumbnailCache.swift:19`(`NSNumber(value: data.hashValue)`), 연계 `TemplateCellView.swift:20`(1400px PNG Data로 호출), `GalleryView.swift:133`(프로필 이미지)
- **문제**:
  - 캐시 키가 `data.hashValue`다. `Data.hashValue`는 **내용 기반 해시라 큰 Data일수록 해시 계산 자체에 바이트를 훑는 비용**이 있다(전량은 아니어도 길이에 영향받음 — 확인 필요, 구현 의존). 도안 라인아트는 위 [중간]대로 1400px PNG(수 MB)라, 셀 표시 때마다 `image(for:)` 진입에서 **캐시 히트 판정 전에 해시를 계산**한다. 히트여도 매 접근 해시 비용이 들고, 이는 body 재평가 빈도(위 [중간])와 곱해진다.
  - **해시 충돌 시 오디코딩**: `Int` 해시 공간에서 충돌 확률은 낮으나, 충돌하면 서로 다른 Data가 같은 키로 매핑돼 **엉뚱한 이미지를 반환**할 수 있다(정합성, 성능 무관). `Data.hashValue`는 프로세스마다 시드가 달라(Swift Hashable 랜덤 시드) 영속성은 없으나 세션 내에선 일관 — 기능상은 대체로 안전하나 이론적 충돌은 남는다.
  - **잔존**: increment 3에서 짚었듯 도안 삭제(`GalleryView.swift:222-232`) 후에도 캐시 엔트리는 NSCache에 잔존(메모리 압력 시 자동 축출). 1400px 엔트리가 크므로(위 [중간]) 삭제 후에도 메모리 회수가 지연될 수 있다.
- **근거**: `ThumbnailCache.swift:19` `data.hashValue` 키. `:20-25` 히트 시 즉시 반환, 미스 시 디코딩. 키가 내용 해시라 대형 Data에 민감.
- **권고**:
  - 키를 **`persistentModelID` 기반**(또는 `template.id` + "lineart" 같은 안정 식별자)으로 바꿔 대형 Data 해시 비용·충돌을 피하는 방안 검토. 단, "내용이 바뀌면 자동 무효화"(ThumbnailCache.swift:14 주석 의도)를 잃으므로, 모델 식별자 + 변경 카운터/`updatedAt` 조합 키가 절충. 위 [중간] "표시용 썸네일 도입"과 함께 설계하면 자연스럽게 정리된다.
  - 충돌·잔존은 현재 무해 수준이라 우선순위 낮음. 다만 대형 Data 해시 비용은 위 디코딩 다운샘플을 도입하면(작은 Data) 자연 완화된다.

### [낮음/정보] `LineArtConverter` — 백그라운드·CIContext 재사용·입력 다운샘플 적정. PNG 인코딩만 점검
- **위치**: `Utilities/LineArtConverter.swift:14`(`static let context = CIContext()`), `:17-44`(변환), `:46-54`(PNG 인코딩), 호출부 `TemplateUploadView.swift:153-158`(`Task.detached` 병렬)
- **문제 아님(정보, 강점) + 한 가지 점검**:
  - **백그라운드 분리 정상**: 변환은 `TemplateUploadView.startProcessing`에서 `Task.detached(priority: .userInitiated)`로 실행(`:156-158`)하고, 다운샘플(`orig`)과 변환(`line`)을 **두 detached로 병렬** 수행 후 `MainActor.run`으로 결과만 반영(`:160-165`). `loadTask` 보관 + `onChange`/`onDisappear` 취소(`:145/:84`)로 increment 2 권고(Task 취소)까지 반영됨. 메인 블로킹 없음(좋음).
  - **CIContext 재사용 정상**: `static let context = CIContext()`(`:14`)로 한 번만 생성해 재사용(매 변환 생성은 비싼 안티패턴인데 잘 피함). `CIContext`는 **스레드 세이프**해 `Task.detached` 병렬 호출에 안전(Apple 문서 — 확인 필요하나 통상 안전). 5개 필터 체인(`:32-40`)은 GPU에서 한 번에 평가되어 적정.
  - **입력 다운샘플 정상**: `maxPixel: 1400`로 변환 전 과대 이미지 축소(`:25-28`) — 변환 부하·메모리 절약. 다만 이 1400px 결과가 그대로 **셀 표시 데이터로도 쓰여** 위 [중간]을 유발한다(변환용으로는 합당, 표시용으로는 과대 — 두 용도가 한 Data를 공유하는 게 문제). 색칠 캔버스가 이 해상도를 베이스로 쓸 것이라 변환 해상도 자체는 유지가 타당.
  - **점검(PNG 인코딩)**: 결과를 PNG로 인코딩(`:48/:50`). PNG는 무손실이라 **인코딩 비용·산출 Data 크기가 JPEG보다 크다.** 라인아트(흰 바탕+검은 선)는 색 수가 적어 PNG 압축이 잘 듣지만, 디코딩(셀 표시 시)은 여전히 무겁다(위 [중간]). 색칠 베이스로 무손실이 필요해 PNG 선택은 합리적이나, **표시용 썸네일은 별도 JPEG**로 두면 디코딩·메모리 모두 이득.
- **근거**: `:14` static CIContext, `:25-28` 입력 축소, `:32-40` 필터 체인, `:48/:50` PNG. 호출부 `TemplateUploadView.swift:153-167` 병렬 detached + 취소.
- **권고**: 변환 파이프라인 자체는 현행 유지(견고). 단 **PNG 산출물을 셀 표시에 직접 쓰지 말 것**(위 [중간] 표시용 썸네일 분리). `CIContext` 스레드 세이프·필터 파라미터는 실기기 변환 시간 계측으로 확인 권장(확인 필요).

### [낮음/정보] `@Attribute(.externalStorage)` 대형 Data + `originalData` 중복 보관 비용
- **위치**: `Models/Template.swift:10`(`lineArtData` 외부저장), `:12`(`originalData` 외부저장), `Models/Artwork.swift:15`(`progressThumbnail` 외부저장), 저장부 `GalleryView.swift:209-218`(`saveTemplate`), `TemplateUploadView.swift:64`(`onSave(d, originalData)`)
- **문제**:
  - 도안 저장 시 `lineArtData`(1400px PNG)와 `originalData`(1024px JPEG 다운샘플, TemplateUploadView.swift:154)를 **둘 다 외부저장으로 보관**(`Template.swift:10/12`). 둘 다 `.externalStorage`라 DB 인라인 폭증은 피하지만(좋음), **도안 1개당 파일 2개 + Data 본문 2벌**이 디스크에 남는다. `originalData`는 주석상 "참고용"(Template.swift:11)인데, 갤러리/색칠 어디서도 표시에 안 쓰면(현재 `TemplateCellView`는 `lineArtData`/`progressThumbnail`만 사용) **저장 공간·쓰기 비용만 차지**한다(확인 필요 — 향후 "원본 보기" 기능 예정 여부).
  - `saveTemplate`(GalleryView.swift:209-218)는 메인 컨텍스트에서 `context.insert` + `context.save()` 동기(메인 디스크 I/O). 외부저장 파일 2개 쓰기가 포함되나 도안 추가는 1회성·저빈도라 현재 무해. do/catch 패턴 계승(`:214-218`, 좋음).
  - `Data` copy-on-write라 `onSave(d, original)`(TemplateUploadView.swift:64) → `Template(lineArtData: doan, originalData: original)`(GalleryView.swift:211) 전달은 실복사 없음. 단 외부저장 직렬화 시점에 본문이 디스크로 쓰인다.
- **근거**: `Template.swift:10/12` 외부저장 2개. `originalData`가 표시 경로(`TemplateCellView`)에서 미사용. `saveTemplate`(`:209-218`) 메인 동기 save.
- **권고**: `originalData`가 실제 사용처가 없다면 **보관 여부 재검토**(요구사항 확인 필요). 보관한다면 현행 외부저장 유지 무방(인라인보다 나음). 다수 도안 일괄 import가 생기면 백그라운드 `ModelContext` 검토(increment 2~3 동일 권고).

### [낮음/정보] `GridEntrance` stagger + `ForEach` 식별자 — 적정. index 재배열만 참고
- **위치**: `Views/Components/GridEntrance.swift:12-21`, `GalleryView.swift:148`(`ForEach(Array(templates.enumerated()), id: \.element.persistentModelID)`), `:151`(`.gridEntrance(index:visible:)`)
- **문제 아님(정보, 강점)**:
  - `GridEntrance`는 `.animation(..., value: visible)`로 **`visible` 변화에만** 반응하도록 고정(GridEntrance.swift:16-20). increment 1~2의 stagger 교훈(`value:` 고정으로 의도치 않은 재생 방지)을 그대로 계승(좋음). delay를 `min(index, 14)`로 포화(`:18`)해 도안이 많아도 마지막 셀 등장이 과도하게 늦지 않게 함(좋음).
  - `ForEach` 식별자가 `persistentModelID`(`:148`)로 안정적 — LazyVGrid 셀 재사용·제거 애니메이션이 정확. `LazyVGrid`라 화면 밖 셀은 실체화 전(셀당 디코딩 비용이 위 [중간]이라 lazy가 중요).
  - **참고**: increment 3 [낮음/정보]와 동일하게, 중간 도안 삭제 시 `enumerated()`의 `index`가 재배열돼 남은 셀의 stagger delay 기준이 바뀐다. `value: visible`에만 반응하므로 즉시 재생은 없고 다음 진입 타이밍만 한 칸 당겨짐(시각적, 무해).
- **근거**: `GridEntrance.swift:16-20` value 고정 + delay 포화. `GalleryView.swift:148` 안정 id.
- **권고**: 현행 유지(좋음). 단 위 [중간] 셀 디코딩이 무거운 상태에선 **stagger 진입과 첫 디코딩이 겹쳐** 첫 프레임이 무거울 수 있으니, 표시용 썸네일 다운샘플(위 [중간])을 먼저 처리하면 진입 체감이 개선된다.

### [낮음/정보] 네비게이션 — `navigationDestination(item:)` Gallery 재생성 / `@Query` 재실행 빈도
- **위치**: `Views/UserSelectionView.swift:102-104`(`.navigationDestination(item: $selected)`), `GalleryView.swift:11-12`(`@Query` 2개), `:8`(`@Environment(\.dismiss)`)
- **문제 아님(정보) + 참고**:
  - 프로필 선택 시마다 `GalleryView(profile:)`가 생성되고, **진입할 때마다 `@Query templates`/`@Query allArtworks`가 재실행**된다(SwiftData `@Query`는 뷰 인스턴스 생성 시 fetch 설정). 뒤로 갔다 다시 들어오기를 반복하면 그때마다 fetch + (위 [낮음]) 전체 작업물 로드 + (위 [중간]) Dictionary 재구성이 일어난다. 가족 단위 소량이라 현재 무해이나, 위 [중간]/[낮음] 비용이 **진입 반복마다 재발**한다는 점에서 그 항목들의 우선순위를 높인다.
  - `navigationDestination(item:)`은 `selected`가 nil로 돌아오면(`dismiss`, GalleryView.swift:114) GalleryView를 해제 — 메모리 누적은 없음(좋음). retain cycle 없음(값 타입 뷰).
- **근거**: `UserSelectionView.swift:102-104` item 기반 destination. `GalleryView.swift:11-12` 진입 시 fetch.
- **권고**: 네비게이션 구조 자체는 적정. 위 [중간]·[낮음]을 해소하면 진입 반복 비용도 함께 내려간다. `@Query` 재실행은 SwiftData 표준 동작이라 별도 조치 불필요.

### [낮음/정보] retain cycle / 클로저 캡처 / cascade 삭제 — 이상 없음
- **위치**: `GalleryView.swift:64`(`onSave`/`onCancel` 클로저), `:84-89`(alert), `:153-166`(contextMenu), `:225`(cascade delete), `TemplateUploadView.swift:147-167`(Task)
- **문제 아님(정보)**:
  - 모든 클로저는 **값 타입 View 컨텍스트**(struct `self` 또는 `template`/`art` 캡처). 누수 없음. `TemplateUploadView`의 `loadTask`(Task 핸들)도 self 강참조 순환 없음(값 타입). increment 3과 동일하게 **이상 없음.**
  - **cascade 삭제**: `Template.artworks`가 `deleteRule: .cascade`(Template.swift:16) — 도안 삭제(GalleryView.swift:225) 시 모든 식구의 작업물 + 각 `progressThumbnail` 외부저장 파일이 함께 정리된다. 식구 수만큼 작업물·외부파일을 지우므로 **도안 1개 삭제 비용이 작업물 수에 비례**하나, 메인 동기 save(`:227-228`)는 저빈도·소량이라 현재 무해. alert 삭제 순서도 `pendingDelete = nil` 선-처리(`:223`)로 increment 3 권고 반영됨(좋음).
- **근거**: 값 타입 뷰 전반. `Template.swift:16` cascade. `GalleryView.swift:222-232` 삭제 + 선-nil.
- **권고**: 없음. 식구·도안이 매우 커져 일괄/대량 삭제가 생기면 cascade 외부파일 정리 비용을 백그라운드로 검토.

---

## 메인 스레드 / 메모리 / retain cycle 점검 결과 (increment 4 관점)

- **메인 스레드 무거운 연산**: 라인아트 변환·원본 다운샘플은 `Task.detached` 병렬 백그라운드(TemplateUploadView.swift:153-158, 좋음). **남은 메인 부하는 셀 표시 시 1400px PNG 디코딩**(`ThumbnailCache.image(for:)`가 `TemplateCellView.body`에서 동기, 위 [중간]) + `artworkByTemplate` Dictionary 재구성(위 [중간]). 이 둘이 스크롤·진입 프레임에 실린다.
- **메모리**: 1400px 디코딩 비트맵(~7.8MB/도안)이 `ThumbnailCache`(NSCache)에 도안 수만큼 누적 → 다수 도안에서 메모리 경고·축출 위험(위 [중간]). 외부저장 Data 본문 2벌(`lineArtData`+`originalData`)은 디스크 비용(위 [낮음/정보]).
- **retain cycle / [weak self]**: alert·contextMenu·onSave/onCancel·Task 클로저 전부 값 타입 뷰 컨텍스트. **이상 없음.**
- **불필요 재계산**: `appeared`/`isUploadPresented`/`pendingDelete` 토글이 `GalleryView.body` 재평가를 부르고, 그때 `artworkByTemplate` 전체 재구성이 동반(위 [중간] 핵심). 시트 등장은 `.spring`이라 애니메이션 프레임마다 재평가 가능.
- **SwiftData**: `@Query allArtworks` 전체 fetch + 클라이언트 필터(위 [낮음]). cascade 삭제는 작업물 수 비례(무해). predicate/관계 탐색으로 좁히는 게 확장 방향.
- **향후 채색 단계 위험 패턴**: 셀의 풀해상 디코딩(표시용 썸네일 부재)·`@Query` 전체 후 클라이언트 필터는 작업물이 늘어나는 채색 단계에서 정확히 증폭될 패턴 — 지금 표시용 썸네일 분리 + predicate `@Query`로 정리하면 채색 단계 재발 방지.

---

## 심각도별 개수 요약

| 심각도 | 개수 | 항목 |
|--------|------|------|
| 높음 | 0 | — |
| 중간 | 2 | `artworkByTemplate` computed의 매 body 전체 순회·Dictionary 재구성 / 셀이 1400px PNG를 풀해상 디코딩(표시용 썸네일 부재 + NSCache 메모리 누적) |
| 낮음 | 5 | `@Query allArtworks` 전체 fetch + 클라이언트 필터(확장성) / `ThumbnailCache` 키 `data.hashValue` 대형 Data 비용·충돌(정보) / LineArtConverter PNG 인코딩 점검(정보·강점) / 외부저장 Data 2벌·`originalData` 중복(정보) / GridEntrance·ForEach 식별자(정보·강점) / 네비게이션 재생성(정보) / retain cycle·cascade(정보) |
| **합계** | **2 중간 + 다수 낮음/정보** | |

> 낮음 묶음 다수는 "현재 문제 아님 + 강점/향후 대비 정보성"(LineArtConverter, GridEntrance, 네비게이션, retain cycle/cascade)이다. 실질 조치 대상은 **중간 2건 + `@Query` 클라이언트 필터(낮음, 중간과 결합)**.

## 가장 먼저 고칠 Top 3

1. **[중간] 셀 표시용 썸네일 다운샘플 도입** (`TemplateCellView.swift:10/:20`, `ThumbnailCache.swift:23`, `Template.swift:10`). 1400px PNG `lineArtData`를 ~200pt 셀에 풀해상 디코딩 → 도안당 ~7.8MB 비트맵이 NSCache에 누적(축출 위험) + 스크롤 중 메인 PNG 디코딩. 그리드용 다운샘플 썸네일(400~600px)을 별도 보관하거나 `ThumbnailCache`에 표시 픽셀 상한 다운샘플 경로를 추가. 색칠 베이스(`lineArtData`)는 풀해상 유지.

2. **[중간] `artworkByTemplate`를 body 평가 경로에서 분리** (`GalleryView.swift:23-29/:150/:154`). computed라 매 body마다 `allArtworks` 전체 순회로 Dictionary를 재구성하고, `ForEach`가 셀당 2회 접근해 O(N·M)가 stagger/시트/삭제 애니메이션 프레임마다 재발. `@Observable` 캐시 또는 `.task(id:)`로 `allArtworks`/`templates` 변화에만 한 번 계산하게 옮기고, 최소한 `grid` 빌드 직전 지역 상수로 한 번만 스냅샷.

3. **[낮음] `@Query allArtworks` predicate로 좁히기** (`GalleryView.swift:12/:25`). 전역 공유 도안 구조상 작업물 총수가 식구×도안으로 늘어 전체 fetch + 클라이언트 필터가 확장성에 취약. 현재 프로필 작업물만 가져오는 predicate `@Query`(또는 관계 탐색)로 M을 줄이면 Top 2의 Dictionary 비용도 함께 내려간다.

---

## 이월 항목 검증

- **increment 2 [중간] 디코딩 캐시(`ThumbnailCache`)** — 도입 완료, 화면 2에서도 재사용(`TemplateCellView.swift:20`, `GalleryView.swift:133`). 다만 **다운샘플 없는 풀해상 디코딩**이라 도안 셀에선 캐시만으로 부족 → 위 [중간] 표시용 썸네일로 보완 필요. 즉 "재디코딩 제거"는 됐으나 "디코딩 크기 축소"는 도안 셀에 미적용.
- **increment 2 [낮음] `@Query` 전체 fetch** — 화면 2에서 `allArtworks`로 **재현 + 클라이언트 필터까지 가중**(위 [낮음]). 같은 계열 한 단계 심화.
- **increment 1~2 stagger 교훈(`value:` 고정)** — `GridEntrance`가 충실히 계승(위 [낮음/정보]).
- **increment 3 alert 삭제 순서(선-nil 정리)** — `deleteTemplate`의 `pendingDelete = nil` 선-처리(`GalleryView.swift:223`)로 계승됨(좋음).
- **increment 2~3 Task 취소·do/catch save** — `TemplateUploadView`(loadTask 취소, `:145/:84`), `saveTemplate`/`deleteTemplate`(do/catch) 모두 계승(좋음).

견고한 부분은 솔직히 견고하다: 변환 백그라운드 병렬 분리·CIContext 재사용·Task 취소(`TemplateUploadView`/`LineArtConverter`), stagger `value:` 고정과 delay 포화(`GridEntrance`), `persistentModelID` 안정 id, cascade·alert 삭제 순서가 모두 적절하다. 핵심 개선은 **"한 Data(1400px PNG)를 색칠 베이스와 그리드 표시에 겸용"하는 구조를 분리**하는 것 — 표시용 썸네일을 떼어내면 [중간] 두 건과 [낮음] 해시 비용이 동시에 완화된다. 불확실로 표기한 항목(body 재평가 빈도의 정확한 거동, `progressThumbnail` 실제 해상도, 외부저장 Data 지연 로드, `Data.hashValue` 비용, `CIContext` 병렬 안전성)은 실기기·다수 도안 계측으로 확인 필요.
