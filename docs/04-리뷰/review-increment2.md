# 성능 검수 리포트 — Increment 2 (SwiftData 영속화 · 갤러리 사진/다운샘플링 · A2 애니메이션)

대상: `/Users/JD/workspace/jd-coloring/jdColoring/` 전 .swift 파일
검수일: 2026-06-01
관점: iOS/macOS(SwiftUI) 성능 — SwiftData, 이미지/메모리, 렌더링, 스레드. 향후 채색 단계로 이어질 위험 패턴 포함.
방침: 코드 수정 없음. 진단·권고만. 실제 코드 라인 근거로만 판단. 불확실은 '확인 필요' 표기.

---

## 반영 결과 (2026-06-01, 개발자)

- **#1 썸네일 재디코딩 (중간) — 반영 완료.** `Utilities/ThumbnailCache.swift` 추가(NSCache, Data 해시 키). `ProfileCircleView`가 `Image(data:)` → `ThumbnailCache.image(for:)` 사용으로 렌더/애니메이션 프레임마다의 재디코딩 제거. 사진 수정 시 해시 변경으로 자동 무효화.
- **#2(A2 흩어짐 고정 offset) (중간) — 반영 완료.** `±1000` 하드코딩 → 컨테이너 폭 기반(`containerWidth + 200`). `GeometryReader`로 폭을 추적해 창 리사이즈(Mac)에도 항상 화면 밖까지 흩어짐. *(다수 프로필에서의 동시 스프링 부하 계측은 프로필 수가 늘면 재검토 — 현재 규모에선 문제 없음.)*
- **#3 save 에러 처리 + Task 취소 (낮음) — 반영 완료.** `context.save()`를 do/catch로 감싸고, 연속 사진 선택 시 이전 다운샘플 `Task`를 cancel + `onDisappear`에서도 cancel.
- 나머지 낮음 항목(@Query 전체 fetch 등)은 향후 규모 확장 시 대비.
- **increment 1 이월 #2(다운샘플링): 이번 검수에서 '부분해결' 판정 → 캐시 도입으로 완전해결.**
- 반영 후 macOS 빌드 통과 확인.

---

## 총평

Increment 2는 increment 1의 핵심 이월 과제였던 **이미지 다운샘플링(#2)을 제대로 해결**했다. `CGImageSource` 썸네일 API로 디코딩 단계에서 축소하고, `Task.detached`로 백그라운드 분리하며, 다운샘플된 작은 JPEG만 모델에 외부저장(`.externalStorage`)으로 보관하는 구조는 견고하다. SwiftData 도입도 단순하고 적절하다.

다만 **다운샘플 결과를 표시할 때 매 렌더마다 `Image(data:)`로 재디코딩하는 캐시 부재(중간)**, **A2 흩어짐 오프셋을 `LazyHStack` + 수평 ScrollView 안에서 ±1000pt로 처리하면서 생기는 레이아웃/클리핑/lazy 상호작용 위험(중간)**, 그리고 SwiftData 저장·뷰 무효화 관련 낮은 항목 몇 가지가 남아 있다. 메인스레드 블로킹·retain cycle은 발견되지 않았다.

---

## 발견 항목

### [중간] 표시 시점마다 `Image(data:)` 재디코딩 — 썸네일 디코딩 캐시 부재
- **위치**: `Views/Components/ProfileCircleView.swift:13`, `Views/Components/ProfileEditorView.swift:91`, `Utilities/Image+Data.swift:10-20`
- **문제**:
  - `ProfileCircleView.body`가 `Image(data: data)` → `UIImage(data:)`/`NSImage(data:)`로 매 body 재계산 시 JPEG을 다시 디코딩한다. 썸네일은 512px JPEG으로 작아졌지만(다운샘플 덕분에 원본 12MP 재디코딩 위험은 제거됨), 여전히 **표시 시점마다 디코딩**이 일어난다.
  - 이 뷰는 A2 흩어짐(`offset`/`opacity`, UserSelectionView.swift:93-94)과 A1 stagger(`staggeredEntrance`)의 애니메이션 대상이다. 애니메이션 프레임마다 SwiftUI가 자식 body를 재평가하면, **흩어짐/진입 애니메이션이 도는 동안 프레임마다 재디코딩**이 발생할 수 있다(확인 필요 — SwiftUI가 `Image` 동일 입력을 캐시하는지는 구현 의존적이며 보장되지 않음).
  - increment 1 리뷰(#2 권고 마지막 줄)가 명시적으로 "표시 시점마다 `Image(data:)` 호출 → body 재계산마다 재디코딩 위험 → 디코딩 결과를 캐시"하라고 요청했는데, 이 부분은 미반영이다.
- **근거**: `ProfileCircleView.swift:13`는 `let data = profile.imageData`에서 곧바로 `Image(data: data)`를 호출. 디코딩 결과(UIImage/NSImage 또는 SwiftUI Image)를 들고 있는 캐시 계층이 전 파일 어디에도 없음. `requirements.md:91`("수평 스크롤·드래그 60fps")와 직접 연관.
- **권고**:
  - 디코딩 결과를 캐시하라. 간단하게는 `persistentModelID`를 키로 하는 `NSCache<NSString, UIImage>`(플랫폼별 PlatformImage) 캐시를 두고, `ProfileCircleView`가 캐시 조회 후 없을 때만 디코딩.
  - 또는 모델/뷰모델 측에서 `imageData`를 한 번만 디코딩한 `Image`/플랫폼 이미지를 보관하고 뷰는 그것을 참조.
  - 디코딩 자체도 메인에서 동기로 일어나므로(아래 항목과 연계), 큰 목록에선 백그라운드 디코딩 후 캐시 채우기를 검토.

### [중간] A2 흩어짐 오프셋 ±1000pt를 `LazyHStack` + 수평 ScrollView 안에서 처리 — 레이아웃/클리핑/lazy 상호작용 위험
- **위치**: `Views/UserSelectionView.swift:86-103` (특히 `:93` `offset(x: ... ±1000)`, `:87` `LazyHStack`, `:99` `padding(.horizontal, 60)`)
- **문제**:
  - 흩어짐을 각 항목의 `.offset(x: ±1000)`(`scatterOffset`, :118-122)으로 구현했다. `offset`은 **레이아웃을 바꾸지 않고 그리기만 평행이동**하므로, 항목들의 실제 레이아웃 위치는 그대로다. ±1000pt 밀어내도 ScrollView의 contentSize는 변하지 않아 동작 자체는 의도대로지만, 항목이 화면 밖으로 밀려나가는 동안 **부모 ScrollView의 클리핑 경계와 무관하게 1000pt 떨어진 위치까지 합성(compositing)**이 일어난다. opacity가 0으로 가더라도 transition이 도는 중간 프레임에서는 화면 밖 큰 오프셋 위치의 뷰를 계속 그린다.
  - `LazyHStack`과의 상호작용: lazy 컨테이너는 "현재 보이는(레이아웃상) 영역" 기준으로 항목을 실체화한다. 흩어짐은 offset(그리기)만 바꾸므로 lazy 실체화 판단에는 영향이 없어 큰 충돌은 없으나, A1 stagger(`offBoundsX: 700`, StaggeredEntrance.swift:11)도 같은 offset 방식이라 **초기 진입 시 화면 밖 700pt에 있어야 할 항목이 lazy 때문에 아직 실체화 전이면 등장 타이밍이 어긋날 수 있다**(increment 1 #3 권고에서 이미 지적된 사항이 lazy화 이후 그대로 남음, 확인 필요).
  - 프로필이 많을 때: 흩어짐 트리거 시 **모든 항목**에 동시에 ±1000 offset + opacity 스프링이 걸린다(`isEditorPresented` 토글이 전 항목 body에 반영). 항목 수에 비례해 동시 애니메이션 부하가 선형 증가 — `requirements.md:79` 평가자 체크포인트("프로필 多일 때 동시 애니메이션 부하")와 직결.
- **근거**: `UserSelectionView.swift:93` `offset(x: isEditorPresented ? scatterOffset(index: index) : 0)`가 `ForEach` 내부 전 항목에 적용. `scatterOffset`은 ±1000 고정값(:121). ScrollView/LazyHStack 안에서 transition 없이 offset+opacity 토글로만 처리.
- **권고**:
  - 흩어짐 양을 고정 ±1000pt 대신 **화면폭 기반(예: `UIScreen`/`GeometryReader` 폭)** 으로 최소화하거나, offset 대신 컨테이너 단위 `transition`(예: 프로필 줄 전체를 하나의 뷰로 묶어 `.transition(.move)`)으로 처리해 항목별 동시 스프링 수를 줄이는 안을 검토.
  - lazy + 화면 밖 오프셋 등장 타이밍은 실제 다수 프로필(수십 개)에서 프레임/등장 순서를 계측해 확인 필요.
  - 흩어짐이 도는 동안 화면 밖 큰 오프셋 위치의 합성 비용이 체감되면, opacity가 0에 도달한 항목을 빠르게 렌더 트리에서 제외(예: 조건부 제거 + transition)하는 방식 검토.

### [낮음] SwiftData `context.save()`를 저장 액션마다 메인스레드에서 호출 + 빈도/실패 무시
- **위치**: `Views/UserSelectionView.swift:155` (`try? context.save()`), `:144-157` (`saveEditor`)
- **문제**:
  - `saveEditor`가 메인 컨텍스트에서 `try? context.save()`를 호출한다. 저장 데이터가 작은 썸네일 JPEG(외부저장)이라 현재 비용은 낮지만, **저장이 메인스레드 동기 디스크 I/O**다. 빈도는 추가/수정 1회당 1번이라 낮아 현재는 무해.
  - `try?`로 **에러를 완전히 무시**한다. 디스크 가득참·외부저장 파일 쓰기 실패 시 사용자는 저장된 줄 알지만 실제로는 누락된다(데이터 정합성 이슈, 성능보다는 견고성).
- **근거**: `UserSelectionView.swift:155`. SwiftData는 명시 save 없이도 autosave가 동작하지만 여기선 명시 호출.
- **권고**: 현재 빈도/크기에선 메인 저장 유지 무방. 다만 `try?` 대신 do/catch로 실패를 사용자에게 알리거나 로깅. 향후 일괄 저장(다수 프로필 import 등)이 생기면 백그라운드 `ModelContext`로 분리 검토.

### [낮음] `imageData` 바인딩으로 큰(작지만) Data 값 복사 경로 — draft를 통한 왕복
- **위치**: `Views/UserSelectionView.swift:16` (`@State draftImageData`), `:136` (`draftImageData = profile.imageData`), `:150` (`profile.imageData = draftImageData`), `ProfileEditorView.swift:9` (`@Binding imageData`), `:77` (`imageData = thumb`)
- **문제**:
  - 갤러리 선택 → 썸네일 Data가 `draftImageData`(@State)에 들어가고, 편집기에는 `@Binding`으로 전달, 저장 시 모델로 대입. `Data`는 copy-on-write라 읽기·전달만으로는 실복사가 없지만, **편집 진입 시 `draftImageData = profile.imageData`(:136)로 모델의 Data를 State로 끌어와 보관**한다. 썸네일이 512px JPEG(수십~수백 KB)라 비용은 작다.
  - 핵심 문제는 아니지만, 편집기가 열려 있는 동안 같은 썸네일 Data가 모델·draft 두 곳에 참조되며, `imageData` 바인딩 변경이 `ProfileEditorView` + 부모 일부를 무효화한다(아래 항목과 연계).
- **근거**: `Data` 값 의미 전달 경로가 State↔Binding↔Model로 3중. 썸네일이라 실측 부담은 낮음.
- **권고**: 현행 유지 무방(다운샘플 덕에 데이터가 작음). 향후 원본/대용량을 다루게 되면 Data를 직접 State에 담는 대신 파일 URL/식별자만 전달하는 구조 검토.

### [낮음] `@Query(sort: \Profile.createdAt)`가 전체 fetch — 페이지네이션/상한 부재
- **위치**: `Views/UserSelectionView.swift:7`
- **문제**: `@Query(sort: \Profile.createdAt)`는 필터 없이 **모든 Profile을 createdAt 정렬로 전부 fetch**한다. 정렬 키 `createdAt`에 인덱스가 없어 대량 시 정렬 비용이 있으나, 가족 단위 프로필(수~십수 개)이라 현재는 완전히 무해. `requirements.md:100`(최대 개수 제한 없음)을 고려한 향후 대비 항목.
- **근거**: `UserSelectionView.swift:7`. 필터·fetchLimit 없음. `Profile`에 `#Index` 없음(Profile.swift:5-19).
- **권고**: 현 규모 유지 무방. 만약 향후 프로필이 수백 개 이상으로 커지는 시나리오가 생기면 `@Query`에 fetchLimit/페이지네이션 또는 `createdAt`에 인덱스 추가 검토. 현 단계에선 과잉 최적화이므로 권고 수준.

### [낮음] `nextColorIndex`가 `profiles.count` 기반 — 삭제 후 색 충돌(성능 무관, 일관성)
- **위치**: `Views/UserSelectionView.swift:113-115`, `:152`
- **문제**: 새 프로필 색을 `profiles.count % ringColors.count`로 정한다. 중간 삭제가 생기면(아직 삭제 미구현) count가 줄어 기존 프로필과 색이 겹칠 수 있다. 성능 이슈는 아니나 increment 3 삭제 도입 시 표면화될 일관성 문제로 기록.
- **근거**: `UserSelectionView.swift:114`. 삭제 기능은 아직 없음(롱프레스가 수정만, :96).
- **권고**: 색 인덱스를 모델에 이미 저장하고 있으므로(`Profile.colorIndex`), 신규 색 선택을 "사용 중 색 집합에서 비는 인덱스"로 정하는 방식 검토(향후).

### [낮음/정보] `Task.detached`로 다운샘플 분리 — 올바름, 우선순위/취소만 참고
- **위치**: `Views/Components/ProfileEditorView.swift:71-81`, `:122-127`
- **문제 아님(정보)**: `onChange(of: pickerItem)`에서 `loadTransferable` 후 `Task.detached(priority: .userInitiated)`로 `ImageDownsampler.thumbnailData`를 호출하고 결과만 `MainActor.run`으로 반영. **백그라운드 분리·메인 갱신 분리가 올바르다.** retain cycle 없음(값 타입 뷰, self 미캡처). `Task.detached`는 액터 상속을 끊는 의도된 사용으로 적절.
- **근거**: `ProfileEditorView.swift:74-80`, `:124-126`. 디코딩·인코딩 전부 detached 클로저 내부.
- **권고**: 현행 유지(좋음). 사소한 개선: 사용자가 사진을 빠르게 연속 변경하면 이전 `Task`가 취소되지 않아 마지막 직전 작업이 늦게 끝나 결과를 덮을 수 있다(`onChange`가 새 Task를 띄우되 이전 것을 취소 안 함). 현재는 `isProcessing` 가드로 UX상 큰 문제는 없으나, 향후 `.task(id:)`나 Task 핸들 보관 후 취소로 정리 권장. `pickerItem`을 nil로 되돌리지 않아 같은 사진 재선택 시 `onChange`가 안 불릴 수 있음(동작 이슈, 확인 필요).

### [낮음/정보] `ImageDownsampler` 구현 — 디코딩 단계 축소 정상, 옵션 점검
- **위치**: `Utilities/ImageDownsampler.swift:10-38`
- **문제 아님(정보, 강점)**: `CGImageSourceCreateThumbnailAtIndex` + `kCGImageSourceThumbnailMaxPixelSize: 512`로 **디코딩 단계에서 축소**한다(원본 전체 디코딩 후 축소가 아님 — #2의 핵심). `kCGImageSourceShouldCache: false`로 원본 캐시 억제, `kCGImageSourceCreateThumbnailWithTransform: true`로 EXIF 회전 반영, `ShouldCacheImmediately: true`로 썸네일 즉시 디코딩. JPEG 0.8로 재인코딩해 작은 Data 산출. 설계가 교과서적으로 견고.
- **근거**: `ImageDownsampler.swift:19-27`. `kCGImageSourceThumbnailMaxPixelSize` 사용이 핵심.
- **권고**: 현행 유지(좋음). 미세 개선:
  - `maxPixel: 512` 고정 — 표시 지름은 130pt(@2x 260px, @3x 390px)이므로 512는 약간 여유가 있다. 편집기 라벨이 156pt(@3x 468px, ProfileEditorView.swift:89)이라 512는 합리적. 과도하지 않음.
  - `kCGImageSourceCreateThumbnailFromImageAlways: true`는 항상 풀 이미지 기준 썸네일을 만든다. 일부 포맷은 임베디드 썸네일이 너무 작아 품질↓일 수 있어 Always가 안전하나, 대형 이미지에서 약간 더 비용. 현 선택 합리적.
  - 실패 시 `nil` 반환만 하고 호출부(`ProfileEditorView.loadThumbnail`)도 nil이면 이미지 미반영 — 사용자 피드백 없음(견고성, 성능 무관).

### [낮음/정보] `SmileyFace` Canvas — 채색 단계 대비 (increment 1에서 이어진 기록)
- **위치**: `Views/Components/SmileyFace.swift:9-37`
- **문제 아님(정보)**: increment 1 리뷰와 동일하게, 현재는 정적 도형 소수라 무해. 향후 채색 캔버스에서 "매 변경마다 전체 Canvas 재그리기"가 안티패턴이 되므로 더티 영역/레이어 분리/`drawingGroup()`·Metal을 그 단계에서 검토할 것을 계속 기록.
- **근거**: 도형 수 소수, 입력 불변.
- **권고**: 현행 유지. 채색 단계 진입 시 재검토.

---

## 메인 스레드 / 메모리 / retain cycle 점검 결과

- **메인 스레드 무거운 연산**: 다운샘플(디코딩+인코딩)은 `Task.detached`로 백그라운드 분리됨(ProfileEditorView.swift:124). **남은 메인 디코딩은 표시 시 `Image(data:)`**(ProfileCircleView.swift:13, ProfileEditorView.swift:91) — 썸네일이라 가볍지만 캐시 부재로 반복 발생 가능(위 중간 항목).
- **retain cycle / [weak self]**: 클로저는 `Task`/`Task.detached`/`onChange`/`onTapGesture`/`onLongPressGesture`/`onAppear`. 모두 값 타입 뷰 컨텍스트, self 강참조 누수 없음. **이상 없음.**
- **대형 객체 복사·보관**: 모델에 보관되는 `imageData`가 **다운샘플된 작은 JPEG**(외부저장)으로 바뀌어 increment 1의 "원본 보관" 위험이 해소됨. `Data` copy-on-write 유지.
- **O(n^2)/타이트 루프**: 없음. `scatterOffset`/`nextColorIndex`는 O(1). `Theme.ring/tint` 모듈러 인덱싱 O(1).
- **메인 동기 대기**: `try? context.save()`(UserSelectionView.swift:155)가 메인 동기 디스크 I/O이나 빈도 1회/작은 데이터로 무해(위 낮음 항목).

---

## 심각도별 개수 요약

| 심각도 | 개수 | 항목 |
|--------|------|------|
| 높음 | 0 | — |
| 중간 | 2 | 표시 시 `Image(data:)` 재디코딩 캐시 부재 / A2 흩어짐 ±1000 offset + LazyHStack 상호작용·동시 스프링 부하 |
| 낮음 | 6 | save 메인/에러무시 / Data State↔Binding 왕복 / @Query 전체 fetch / nextColorIndex 색충돌(일관성) / Task.detached 취소(정보) / ImageDownsampler·SmileyFace(정보, 강점) |
| **합계** | **8** | |

> 참고: 낮음 6건 중 3건(Task.detached, ImageDownsampler, SmileyFace)은 "현재 문제 아님 + 강점/향후 대비 정보성"이다.

## 가장 먼저 고칠 Top 3

1. **[중간] 썸네일 디코딩 캐시 도입** (ProfileCircleView.swift:13, Image+Data.swift). `persistentModelID` 키 `NSCache`로 디코딩 결과를 캐시해 body 재계산/애니메이션 프레임마다의 재디코딩을 제거. increment 1 #2 권고의 미반영분이자 60fps 요구(requirements.md:91) 직결.
2. **[중간] A2 흩어짐 구현 재검토** (UserSelectionView.swift:86-103). ±1000 고정 offset을 화면폭 기반으로 줄이거나 컨테이너 단위 transition으로 전환해 항목 수 비례 동시 스프링 부하·화면 밖 합성 비용을 줄이고, lazy + 화면 밖 등장 타이밍을 다수 프로필로 계측.
3. **[낮음] `context.save()` 에러 처리 + Task 취소 정리** (UserSelectionView.swift:155, ProfileEditorView.swift:71-81). `try?` 무시를 do/catch로 바꿔 저장 실패를 드러내고, 연속 사진 선택 시 이전 다운샘플 Task를 취소(`.task(id:)`/핸들 취소)해 늦은 결과가 덮어쓰는 것을 방지.

---

## 이월 항목 검증 — increment 1 "#2 이미지 다운샘플링"

**판정: 부분해결 (핵심 해결, 캐시 권고만 미반영)**

해결된 근거(코드 라인):
- **디코딩 단계 축소**: `Utilities/ImageDownsampler.swift:19-27`이 `CGImageSourceCreateThumbnailAtIndex` + `kCGImageSourceThumbnailMaxPixelSize: 512`를 사용 → 원본 전체 디코딩 후 축소가 아니라 디코딩 단계에서 축소. #2의 핵심 요구를 정확히 충족.
- **백그라운드 분리**: `Views/Components/ProfileEditorView.swift:124-126`이 `Task.detached(priority: .userInitiated)`로 다운샘플을 실행하고 `:76` `MainActor.run`으로 결과만 메인 반영. increment 1 권고의 "백그라운드 수행, 결과만 메인 표시" 충족.
- **다운샘플본 보관**: `Models/Profile.swift:9`이 `@Attribute(.externalStorage) var imageData: Data?`로 다운샘플된 작은 JPEG만 외부저장에 보관 → increment 1 "원본 대신 다운샘플/리사이즈본 보관"(requirements.md:83, :92) 충족. DB 인라인 대신 외부저장 선택도 적절.

미반영 근거(코드 라인):
- increment 1 #2 권고의 마지막 항목 **"`Image(data:)`를 표시 시점마다 호출하면 body 재계산마다 재디코딩 위험 → 디코딩 결과를 캐시"** 가 미반영. `ProfileCircleView.swift:13`과 `ProfileEditorView.swift:91`이 여전히 표시 시점에 `Image(data:)`를 호출하고, 디코딩 캐시 계층이 전 파일에 없음(위 [중간] 첫 항목).

따라서 다운샘플링·백그라운드·다운샘플본 보관이라는 #2의 본질은 **해결**됐고, 부수 권고였던 **디코딩 캐시만 남아 "부분해결"** 로 판정한다. 남은 1건은 위 Top 3의 1번으로 처리 권고.
