# 검수 리포트: Increment 7 — 기본 제공 한글 자음·모음 앨범

## 반영 결과 (2026-06-09, 개발자)
**M-1·M-2 반영 완료. 빌드 SUCCEEDED.** minor/nit는 "이상 없음" 판정이라 조치 불필요.
- **M-1(중복 시드)**: `HangulSeeder`에 `@MainActor static var isSeeding` 가드 추가 — 비동기 렌더 gap 동안 재진입 차단. 삽입 직전 메인에서 `album.templates`의 보유 글자(name)를 **재확인**해 이미 있는 글자는 건너뜀(중복 삽입 원천 차단). 커버도 `coverImageData == nil`일 때만 채움.
- **M-2(부분 실패 시 ProgressView 영구 노출)**: `Task` 종료 시 `defer { isSeeding = false }`로 가드 해제 → 다음 `ensure` 호출이 missing 재계산으로 자가복구. 재시도 트리거로 **`AlbumCarouselView.onAppear`에서도 `HangulSeeder.ensure` 호출**(완료 상태면 fetch+스칼라 비교만, 0 렌더·0 삽입). 시작 1회 + 앨범 화면 진입 시 재시도 두 경로 모두 멱등.

---

검수 대상 신규 2 + 수정 5 파일을 정독, 디자인 스펙 §32-5 평가자 체크포인트(6개)와 대조.
결론: **blocker 0건, major 2건, minor 3건, nit 2건.** 채색 핫패스 회귀 없음.

판정은 실제 코드 근거로만 했고, 실측 필요 항목은 "확인 필요"로 표시.

---

## MAJOR

### M-1. 시드 in-flight 가드 부재 — 시작 직후 짧은 창에서 **중복 시드** 가능
- 위치: `Utilities/HangulSeeder.swift:25-58` (`ensure` / `Task {}`)
- 문제: `ensure`는 동기 fetch로 missing을 계산한 뒤 `Task {}`(MainActor)로 비동기 렌더→삽입을 띄운다. 렌더가 끝나기 전(수백 ms)에는 SwiftData에 아직 한글 앨범/도안이 persist되지 않는다. 이 async gap 동안 `ensure`가 한 번 더 불리면(아래 근거) 두 번째 호출도 동일 missing을 다시 계산해 두 번째 렌더·삽입 Task를 띄운다 → **24자 도안이 2배로 삽입**될 수 있다. 정적 가드(`isSeeding` 플래그)도, name 기준 upsert/중복제거도 없다.
- 근거: 현재 호출부는 `RootView.onAppear` 1회뿐이라 통상 경로에선 재진입이 드물다. 다만 (a) scenePhase 복귀나 향후 onAppear가 또 붙는 변경, (b) NavigationStack 구성 변화로 RootView가 재구성되는 경우 재진입이 발생할 수 있다. 일단 중복 삽입되면 보호 앨범이라 사용자가 못 지우고, 갤러리에 "ㄱ"이 2개씩 보이는 영구 손상이 된다.
- 권고: `@MainActor` enum에 `private static var isSeeding = false` 가드 추가 — `ensure` 진입 시 `guard !isSeeding`, Task 시작 직전 `isSeeding = true`, 삽입/save 후(또는 defer) 해제. 보강으로 삽입 직전 missing을 **메인에서 재확인**(렌더 사이 다른 경로가 이미 넣었을 수 있음)하면 더 안전.

### M-2. 빈 '한글' 앨범이 잠깐 persist + `systemPreparingState`의 ProgressView가 영구 노출될 여지
- 위치: `Utilities/HangulSeeder.swift:46-56`, `Views/GalleryView.swift:92-93,341-356`
- 문제: 첫 실행에서 앨범이 없으면 `album = Album(...); context.insert(album)` 후 글자 24개를 for 루프로 삽입하고 **루프 끝에서 단 한 번 save**한다. 루프 자체는 동기라 중간 save가 없어 "빈 앨범만 보이는" 영속 상태는 짧지만, 첫 진입 사용자가 시드 완료 전 캐러셀→갤러리로 들어가면 `templates.isEmpty && isSystemAlbum` → `systemPreparingState`(ProgressView)가 뜬다. 이 화면은 @Query가 새 도안 삽입을 감지하면 자동 갱신되므로 정상 복구되지만, **시드 Task가 실패(렌더 nil 등)하면 save가 빈 앨범만 남기고 ProgressView가 영구 노출**된다(재시도 트리거 없음 — onAppear는 이미 소진).
- 근거: 첫 실행 + 글리프 렌더 실패(폰트 폴백까지 실패)는 드물지만, 실패 시 사용자가 앱을 껐다 켜기 전엔 회복 불가. 또한 앨범 커버만 needCover인 재방문 경로에서도 동일 Task 구조라 표시 깜빡임 가능.
- 권고: (1) 글자 삽입을 청크로 나눠 부분 save(첫 글자 묶음 먼저 보이게)하거나 그대로 두되, (2) 시드 실패/부분완료를 다음 `ensure`가 missing으로 잡아 재시도하도록 M-1 가드와 함께 멱등성을 보장. (3) `systemPreparingState`에 타임아웃/재시도 트리거를 두면 영구 ProgressView 방지.

---

## MINOR

### m-1. 존재 판정이 전체 시스템 도안의 `templates` 관계를 faulting — 이미지 디코딩은 없으나 N행 스칼라 fault
- 위치: `Utilities/HangulSeeder.swift:27-30`
- 사실: `$0.templates.filter { $0.isSystem }.map(\.name)`는 관계 fault를 풀어 24개 Template 행의 `isSystem`/`name` 스칼라만 읽는다. `imageData`/`thumbnailData`는 `@Attribute(.externalStorage)`라 **접근하지 않는 한 디코딩·로드되지 않는다** → 체크포인트 #1의 "이미지 디코딩 없이 name 비교만" 요건은 **충족**. 다만 매 시작 24행 fault는 발생한다(가벼움).
- 근거: 24행 스칼라 fetch는 무시 수준. 다 있으면 missing 비어 `guard`에서 즉시 반환(렌더·삽입 0회) — 체크포인트 #1 "다 있으면 0회" **충족**.
- 권고: 그대로 둬도 무방. 굳이 줄이려면 `FetchDescriptor<Template>`에 `propertiesToFetch = [\.name]` + `predicate isSystem`로 카운트만 세는 방식도 가능(선택).

### m-2. `makeItems()`의 `albums.filter` 2회 — 드래그 프레임마다는 아니나 @Query 변경마다 전체 순회 2패스
- 위치: `Views/AlbumCarouselView.swift:114-124`
- 사실: 드래그 상태(scrollIndex/drag)는 자식 `AlbumCarouselDeck`이 소유하므로 스와이프 프레임마다 부모 body가 무효화되지 않는다 → `makeItems`는 **드래그 프레임마다 재계산되지 않음**(체크포인트 #5 충족, increment6 [중간]#1과 충돌 없음). 다만 `allTemplates` 전체 순회(counts) + `albums.filter(\.isSystem)` + `albums.filter { !$0.isSystem }`로 albums를 2번 훑는다. @Query 변경·진입·시트 토글 때만 도므로 N(앨범·도안)이 작아 비용은 무시 수준.
- 권고: 그대로 무방. 정리하려면 단일 패스 `partition`/`sorted(by: isSystem)` 또는 `albums.sorted { $0.isSystem && !$1.isSystem }`로 1패스화(선택).

### m-3. `selectableAlbums`/`isSystemAlbum`/`artworkByTemplate`가 computed — body·셀 핫패스 진입 여부
- 위치: `Views/GalleryView.swift:43,46,69-75,170`
- 사실: `artworkByTemplate`는 grid에서 `let lookup`으로 **1회만** 계산해 셀에 넘기므로 셀 핫패스 재계산 없음(increment4 #2 규약 유지). `isSystemAlbum`은 단순 옵셔널 체이닝이라 무해. `selectableAlbums`(categories.filter)는 body에서 업로드 시트 표시 시(`TemplateUploadView(albums:)`)와 이동 다이얼로그 `ForEach(selectableAlbums)`에서 평가된다 — confirmationDialog 빌더 안에서 호출되므로 다이얼로그 표시 시에만, 셀 렌더 핫패스 밖. **체크포인트 #6 충족**(셀/@Query 핫패스 부담 없음).
- 근거: 다만 `selectableAlbums`가 다이얼로그 빌더에서 매 재평가 시 categories를 다시 filter한다. categories는 소수라 무해.
- 권고: 조치 불필요. 신경 쓰이면 `let selectable = selectableAlbums`로 다이얼로그 진입 시 1회 캐싱(선택).

---

## NIT

### n-1. 동시성/actor 경계 — **이상 없음** 확인
- `ensure`(@MainActor) 안 `Task {}`는 MainActor 상속, 그 안에서 `await Task.detached(priority:.utility) { renderPayload(...) }.value`로 렌더만 오프메인. `renderPayload`/`HangulGlyphRenderer`는 `nonisolated`, **모델/ModelContext를 만지지 않고 String→Data만** 다룬다. actor 경계를 넘는 건 `Payload`(Sendable, Data only) — 체크포인트 #2·#3 "Data만 넘긴다" **충족**. `context`/`albumID`(`PersistentIdentifier`는 Sendable) 캡처는 MainActor Task 안에서만 사용 → 같은 actor에서만 접근. 렌더가 메인을 동기 블로킹하지 않아 첫 실행 끊김 없음(체크포인트 #2 충족).

### n-2. 글자 도안 해상도 분리 — increment4 규약과 **일치** 확인
- `HangulSeeder`: 색칠용 1024(`fullSide`) / 썸네일 480(`thumbSide`) → Template.imageData/thumbnailData에 각각 저장. increment4의 "그리드는 thumbnailData만 디코딩, 풀해상은 색칠 화면에서만" 규약과 일치(체크포인트 #4 충족). 다만 `HangulGlyphRenderer`는 다운샘플이 아니라 **각 해상도를 직접 렌더**(format.scale=1, side만 다름)한다 — 선이 흐려지지 않게 한 의도된 선택이며 업로드 경로의 다운샘플과는 다른 방식이나 결과 산출물(분리 저장) 규약은 동일. `format.opaque=true`로 알파 없는 PNG라 용량/디코딩 가벼움.

---

## "이상 없음" 명시 판정
- **#1 시작 1회·0회 단축**: onAppear 1회 호출, missing 비면 guard 즉시 반환(렌더·삽입 0). name 키 비교만(외부저장 blob 미접근). 충족. (단 M-1: 재진입 멱등성 보강 권장.)
- **#2 백그라운드 렌더**: 렌더는 detached(.utility), 메인은 fetch+insert만. 동기 블로킹 없음. 충족.
- **#3 동시성/레이스**: actor 경계 Data only, context 단일 actor 사용. 단 in-flight 중복 시드 가드 부재(M-1).
- **#4 해상도 분리**: 1024/480, Template 분리 저장. 충족.
- **#5 캐러셀 맨 앞 고정**: 드래그 상태 자식 소유 → makeItems 드래그 프레임 비재계산. 무한 인덱스 계산과 충돌 없음. 충족(m-2는 비핫패스 미세 낭비).
- **#6 GalleryView 변경**: lookup 1회 계산 규약 유지, system 분기는 옵셔널 체이닝/다이얼로그 빌더 내 평가. 셀·@Query 핫패스 부담 없음. 충족.

---

## 요약

| 심각도 | 건수 | 항목 |
|---|---|---|
| blocker | 0 | — |
| major | 2 | M-1 중복 시드 가드 부재, M-2 빈 앨범/ProgressView 회복 멱등성 |
| minor | 3 | m-1 존재판정 fault, m-2 filter 2패스, m-3 computed 평가 위치 |
| nit | 2 | n-1·n-2 (이상 없음) |

**Top 3 우선 수정**: M-1(`isSeeding` 가드 + 삽입 직전 missing 재확인으로 멱등성) → M-2(시드 실패/부분완료 재시도 경로) → m-2/m-1(비핫패스 미세 정리, 선택).
