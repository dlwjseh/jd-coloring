# 성능 검수 리포트 — Increment 3 (컨텍스트 메뉴 · 삭제 확인 다이얼로그 · deleteProfile)

대상: `/Users/JD/workspace/jd-coloring/jdColoring/` 전 .swift 파일 (특히 `Views/UserSelectionView.swift`)
검수일: 2026-06-01
관점: iOS/macOS(SwiftUI) 성능·정합성 — `.contextMenu`/`.alert`/SwiftData 삭제, 상태 꼬임, 메인스레드, retain cycle, 향후 채색 단계 위험 패턴.
방침: 코드 수정 없음. 진단·권고만. 실제 코드 라인 근거로만 판단. 불확실은 '확인 필요' 표기.

---

## 반영 결과 (2026-06-01, 개발자)

- **#1 alert 타이틀의 무효 @Model 접근 (중간) — 반영 완료.** `deleteProfile`에서 `pendingDelete = nil`을 `context.delete`보다 **먼저** 실행해, 삭제된 객체를 타이틀이 읽을 윈도우를 제거.
- **#2 nextColorIndex 색 충돌 (낮음→격상) — 반영 완료.** `profiles.count % 6` → **현재 안 쓰는 색 우선 배정**(모두 쓰이면 최소 사용 색 재사용)으로 변경. 중간 삭제 후에도 색 충돌 없음.
- **#3 pendingDelete nil 정리 분산 (낮음) — 반영 완료.** 취소 버튼 action을 비우고 닫힘 정리를 Binding으로 일원화. 삭제 경로의 nil 해제는 #1 안전장치로 의미 유지.
- 정보성/강점 항목은 변경 없음. 반영 후 macOS 빌드 통과 확인.

---

## 이번 increment 3 범위 확인 (먼저 점검)

- **임시 `.onLongPressGesture` 제거 — 확인 완료.** 전 .swift 파일에서 `onLongPressGesture` / `longPress` / `simultaneousGesture` 검색 결과 없음. increment 2 리뷰가 참조하던 롱프레스(당시 `:96`, 수정만 수행)는 완전히 제거되고 `.contextMenu`(`UserSelectionView.swift:124-135`)로 대체됨. 의도대로 정리됨.
- **`.contextMenu`** 각 셀 부착(`:124-135`), **`.alert` 삭제 확인 + Binding 브리지**(`:84-96`), **`deleteProfile`**(`:203-213`) 모두 존재 확인.
- requirements.md:33-34, 52-54 (롱프레스→수정/삭제, 삭제 시 확인 다이얼로그), requirements.md:88 / design-spec.md:85 (Mac 우클릭 대체) 요구를 구조적으로 충족. design-spec.md:48-49(컨텍스트 메뉴 카드 + 확인 다이얼로그)도 SwiftUI 기본 `.contextMenu`/`.alert`로 충족.

---

## 총평

Increment 3은 범위가 좁고 **대체로 견고**하다. 삭제 플로우(컨텍스트 메뉴 → `pendingDelete` 상태 → `.alert` 확인 → `deleteProfile`)는 SwiftUI/SwiftData 관용 패턴을 충실히 따랐고, `.alert`가 `presenting: pendingDelete`로 **삭제 대상 객체를 클로저 인자(`profile`)로 캡처**한 점은 "이미 삭제된 객체 접근"을 상당 부분 막아주는 좋은 선택이다. 명백한 메인스레드 블로킹·retain cycle은 없다.

다만 (1) **`.alert` 타이틀이 `pendingDelete?.name`을 직접 보간**해 삭제 직후 dismiss 애니메이션 프레임에서 무효화된 @Model 객체에 접근할 수 있는 위험(중간), (2) **`deleteProfile`의 `pendingDelete = nil`과 Binding `set`의 nil 처리가 이중**으로 도는 상태 정리 중복(낮음), (3) increment 2에서 "삭제 도입 시 표면화"로 예고된 **`nextColorIndex` 색 충돌이 이번에 실제 활성화**(낮음, 정합성), (4) `.contextMenu` 셀별 부착의 다수 프로필 비용(낮음/정보) 등이 남는다. increment 2의 중간 2건(디코딩 캐시·A2 흩어짐)은 코드 반영 완료되어 이번 삭제 경로에 새 악영향은 없다.

---

## 발견 항목

### [중간] `.alert` 타이틀이 `pendingDelete?.name`을 직접 보간 — 삭제 직후 무효화된 @Model 접근 위험
- **위치**: `Views/UserSelectionView.swift:85` (타이틀 문자열), 연계 `:90`(`presenting: pendingDelete`), `:203-213`(`deleteProfile`)
- **문제**:
  - alert 타이틀 `"'\(pendingDelete?.name ?? "")' 프로필을 삭제할까요?"`는 **타이틀 텍스트가 `pendingDelete`(@State Profile?)의 프로퍼티를 직접 읽는다.** 본문 메시지/버튼은 `presenting:` 클로저 인자(`profile`, `:91-94`)를 쓰지만, **타이틀만 `pendingDelete?.name`을 직접 보간**한다(불일치).
  - 삭제 플로우: 사용자가 [삭제] 탭 → `deleteProfile(profile)` 호출 → `context.delete(profile)`로 모델이 컨텍스트에서 제거 → `pendingDelete = nil`(`:212`). alert가 닫히는 **dismiss 트랜지션 동안 SwiftUI가 body(타이틀 포함)를 한두 프레임 더 재평가**할 수 있는데, 만약 그 시점에 `pendingDelete`가 아직 nil로 전파되기 전이고 그 객체가 이미 `context.delete`된 상태라면, 삭제된 @Model의 `name` 접근이 일어난다. SwiftData에서 삭제된 객체 프로퍼티 접근은 **빈 값/이전 캐시값을 반환하거나, 구성에 따라 트랩**할 수 있다(확인 필요 — 통상 즉시 크래시는 드물지만 보장되지 않음).
  - `deleteProfile`이 `pendingDelete = nil`을 `context.delete` "뒤"에 하므로(`:205` delete → `:212` nil), **delete와 nil 사이에 짧은 윈도우**가 존재한다. 본문/버튼은 캡처된 `profile`을 써서 안전하지만 타이틀은 그 보호를 못 받는다.
- **근거**: `:85`가 `presenting:`이 주는 `profile` 대신 `pendingDelete?.name`을 직접 사용. `deleteProfile`은 `:205`에서 delete를 먼저 하고 `:212`에서 nil 설정. 본문 `:94-96`/버튼 `:91-93`은 `profile`(또는 `_`) 인자 사용으로 대조적.
- **권고**:
  - 타이틀도 `presenting:` 인자를 받도록 **타이틀 자체를 클로저화**하거나(현재 `.alert(title:isPresented:presenting:actions:message:)` 시그니처에서 타이틀은 정적 문자열이라 인자 못 받음 → 아래 대안), 삭제 순서를 **`pendingDelete = nil`을 `context.delete`보다 먼저** 호출해 무효화 객체가 타이틀에 묶이는 윈도우 자체를 없애는 방안 검토. 즉 `deleteProfile`에서 먼저 로컬 상수로 대상을 잡고 `pendingDelete = nil`을 선행시킨 뒤 delete/save를 하면 타이틀이 무효 객체를 읽을 여지가 사라진다.
  - 또는 타이틀에 쓸 이름을 `pendingDelete` 설정 시점에 **별도 @State(String)로 스냅샷**해 두고 타이틀은 그 문자열을 보간(객체 대신 값 보간 → 삭제 후에도 안전).
  - 현재 가족 단위 소량·단일 삭제라 실제 충돌 확률은 낮으나, "삭제 직후 무효 객체 접근"은 채색 작업물 삭제 등 더 무거운 경로로 확장될 때 정확히 같은 패턴이 재현되므로 지금 정리 권장.

### [낮음] `pendingDelete = nil` 이중 정리 — `deleteProfile`과 Binding `set`의 중복 nil 처리
- **위치**: `Views/UserSelectionView.swift:86-89`(Binding get/set), `:93`(취소 버튼), `:212`(`deleteProfile` 내부)
- **문제**:
  - `.alert`의 `isPresented` Binding은 `set`에서 `if !$0 { pendingDelete = nil }`로 닫힐 때 nil 처리(`:88`). 그런데 [삭제] 버튼 → `deleteProfile`도 끝에서 `pendingDelete = nil`(`:212`), [취소] 버튼도 `pendingDelete = nil`(`:93`)을 **직접** 한다.
  - 즉 alert가 닫힐 때 (a) 버튼 액션의 직접 nil 설정과 (b) `isPresented` Binding set의 nil 설정이 **모두** 발생할 수 있다. 둘 다 `pendingDelete = nil`로 결과는 동일(idempotent)이라 **상태 꼬임/중복 표시는 발생하지 않는다**(이미 nil에 nil 대입은 무해). 따라서 버그는 아니나 **중복 경로**다.
  - 위험은 없지만, 향후 nil 설정에 부수효과(예: 정리 로직)를 붙이면 **두 번 실행**될 소지가 있다. 또한 의도를 읽기 어렵게 만든다(어느 경로가 닫는지 불명확).
- **근거**: nil 설정 지점이 `:88`, `:93`, `:212` 3곳. get은 `pendingDelete != nil`(`:87`)로 단순·정확.
- **권고**: 버튼 액션에서 `pendingDelete = nil`을 직접 하지 않고 **Binding set 한 곳에만** 정리를 위임하거나(액션은 삭제/취소 의미만 수행), 반대로 Binding set의 nil 처리를 두고 버튼의 직접 nil을 제거해 단일 책임화. 현재는 무해하므로 우선순위 낮음.

### [낮음] `nextColorIndex`가 `profiles.count` 기반 — 삭제 도입으로 색 충돌이 실제 활성화 (정합성)
- **위치**: `Views/UserSelectionView.swift:152-154`(`nextColorIndex = profiles.count % ringColors.count`), `:192`(신규 생성 시 사용), `:59`(편집기 colorIndex 표시)
- **문제**:
  - increment 2 리뷰 [낮음] 항목에서 "삭제 미구현이라 잠재"로 기록했던 색 충돌이, **이번에 `deleteProfile`이 도입되며 실제 표면화**된다. 예: 6명(인덱스 0~5) 등록 후 중간 1명 삭제 → `profiles.count == 5` → 다음 추가 색 인덱스 `5 % 6 = 5`. 이미 인덱스 5색을 쓰는 기존 프로필과 **링/틴트 색이 겹친다.** 삭제 위치에 따라 더 빈번해진다.
  - 성능 이슈는 아니나, design-spec.md(추가 순서대로 6색 순환)의 시각적 구분 의도가 깨지는 **정합성/UX 문제**다. 컬러링 앱 특성상 프로필 색은 아이별 식별 단서라 체감될 수 있다.
- **근거**: `:153`이 `profiles.count` 기반. 색은 `Profile.colorIndex`로 모델에 이미 저장되어 있어(`Profile.swift:11`) "사용 중 색 집합" 조회가 가능.
- **권고**: 신규 색을 "현재 `profiles`의 `colorIndex` 집합에서 비어 있는 가장 작은 인덱스"로 정하거나(꽉 차면 count 기반 fallback), 최소한 마지막 프로필의 `colorIndex + 1`을 쓰는 방식 검토. O(n) 한 번 스캔이라 비용 무시 가능.

### [낮음/정보] `.contextMenu`를 `ForEach` 각 셀에 부착 — 다수 프로필 시 비용 (현재 무해)
- **위치**: `Views/UserSelectionView.swift:124-135`(`.contextMenu`), `:114-115`(`LazyHStack` + `ForEach`), `:116`(`ProfileCircleView`)
- **문제 아님(정보)**:
  - `.contextMenu`가 `ForEach` 내부 각 `ProfileCircleView`에 부착된다. SwiftUI `.contextMenu`의 메뉴 콘텐츠(`Button×2`, `:125-134`)는 **메뉴가 실제로 열릴 때 평가/구성**되는 게 일반적이라, 셀이 화면에 있다는 것만으로 메뉴 뷰가 즉시 렌더되지는 않는다. 따라서 셀 수에 비례한 즉각적 큰 비용은 없다(확인 필요 — 플랫폼/버전별로 미리보기 스냅샷 비용이 다를 수 있음).
  - `LazyHStack`과의 상호작용: lazy 실체화된 셀에만 `.contextMenu`가 붙으므로 화면 밖 셀에는 부착 비용이 없다. 다만 **macOS에서 `.contextMenu`는 우클릭 시 대상 셀의 프리뷰/하이라이트를 생성**하는데, 셀에 `.shadow`(ProfileCircleView.swift:27)와 `Canvas`(SmileyFace) 또는 디코딩 이미지가 포함되어 메뉴 열림 시 프리뷰 스냅샷 비용이 약간 있을 수 있다(소량이라 무해).
  - `.contextMenu`와 `.onTapGesture`(`:122`)가 같은 셀에 공존한다. iPad에서 탭(선택)과 롱프레스(메뉴)는 제스처가 분리되어 충돌이 적지만, **롱프레스 인식 임계 동안 탭이 지연**될 여지(시스템 기본 동작)는 플랫폼 표준이라 수용 가능.
- **근거**: `:124-135`가 `ForEach` 항목마다 부착. 메뉴 콘텐츠는 정적 버튼 2개로 가벼움.
- **권고**: 현행 유지(좋음). 프로필이 수십~수백 개로 커지고 우클릭 프리뷰 비용이 체감되면 `.contextMenu`에 가벼운 커스텀 프리뷰(`preview:`)를 지정해 기본 스냅샷 비용을 통제하는 방안 검토. 현 규모에선 과잉.

### [낮음] `deleteProfile`의 메인스레드 `context.save()` — 빈도·크기상 무해, 에러는 print만
- **위치**: `Views/UserSelectionView.swift:207-211`(`try context.save()` + do/catch), `:204-206`(`withAnimation { context.delete }`)
- **문제**:
  - `deleteProfile`이 메인 컨텍스트에서 `context.save()`를 동기 호출(메인 디스크 I/O). 삭제는 작업당 1회·외부저장 썸네일 파일 1개 정리 수준이라 **현재 비용은 낮다.** increment 2에서 `try?` → do/catch로 개선된 패턴을 그대로 따른다(`:207-211`, 좋음).
  - 다만 에러를 `print`만 한다(`:210`). 삭제 저장 실패 시 사용자에겐 `withAnimation`으로 셀이 이미 사라진 것처럼 보이지만(애니메이션은 `@Query` 변화에 반응), 실제 영속화 실패면 다음 실행 시 되살아날 수 있다(정합성). 성능보다 견고성 항목.
  - `withAnimation`이 감싼 것은 `context.delete`(`:205`)뿐이다. `context.delete`는 `@Query`를 통해 `profiles` 배열을 줄이고, 그 변화가 `ForEach`(`:115`)의 항목 제거 + `withAnimation`의 스프링으로 제거 애니메이션을 만든다. **삭제 애니메이션을 `withAnimation`으로 거는 방식은 적절**하다. 다만 `ForEach`가 `id: \.element.persistentModelID`(`:115`)라 안정적 식별로 제거 애니메이션이 정확히 해당 셀에만 적용된다(좋음).
- **근거**: `:205` delete를 withAnimation으로 감쌈, `:207` save는 밖. `:115` persistentModelID 안정 id.
- **권고**: 현행 유지 무방. 에러 시 사용자 알림/로깅 강화는 향후. 다수 일괄 삭제 기능이 생기면 백그라운드 `ModelContext` 검토(increment 2 권고와 동일).

### [낮음/정보] 삭제 ↔ A1/A2 애니메이션 상태(`appeared`, `isEditorPresented`) 충돌 점검 — 충돌 없음
- **위치**: `Views/UserSelectionView.swift:118`(A1 `staggeredEntrance(index:visible:appeared)`), `:120-121`(A2 `offset`/`opacity` `isEditorPresented`), `:204`(삭제 `withAnimation`)
- **문제 아님(정보)**:
  - **A1과의 충돌**: A1 stagger는 `StaggeredEntrance`에서 `.animation(..., value: visible)`로 **`visible`(=`appeared`) 변화에만** 반응하도록 고정되어 있다(StaggeredEntrance.swift:17-21). 삭제는 `appeared`를 건드리지 않으므로(삭제 경로에 `appeared` 변경 없음) **A1 진입 연출이 삭제에 끌려가지 않는다**(설계 의도대로, StaggeredEntrance 주석 그대로 동작).
  - 단, **삭제 시 `index` 재배열 부작용**은 확인 필요: `ForEach(Array(profiles.enumerated())...)`(`:115`)에서 `index`는 배열 위치다. 중간 항목 삭제 시 뒤 항목들의 `index`가 1씩 줄어 `staggeredEntrance(index:)`/`scatterOffset(index:)`에 넘기는 값이 바뀐다. A1 애니메이션은 `value: visible`에만 반응하므로 index 변경이 **즉시 재생을 유발하진 않으나**, 남은 항목의 stagger delay 기준(`Double(index)*perItemDelay`)이 바뀌어 **다음 진입 시 등장 순서 타이밍이 한 칸 당겨진다**(시각적으로만, 무해). A2 `scatterOffset`의 mid 계산도 삭제 후 즉시 갱신되는데, 편집기가 안 열려 있으면(`isEditorPresented == false`) offset이 0이라 영향 없음.
  - **A2와의 충돌**: 삭제는 `.contextMenu`(브라우징 상태, `isEditorPresented == false`)에서만 트리거된다. 편집기가 열린 동안은 `.scrollDisabled`(`:141`)이고 셀 opacity 0이라 컨텍스트 메뉴 접근 자체가 사실상 불가. 따라서 **A2 흩어짐 진행 중 삭제가 끼어드는 경로는 실질적으로 닫혀 있다.** 동시 발생 위험 낮음.
- **근거**: `appeared`는 onAppear에서만 토글(`:76-81`), 삭제 경로(`:203-213`)는 미변경. A2는 `isEditorPresented` 의존, 삭제는 브라우징 상태 전용.
- **권고**: 현행 유지. 만약 향후 "편집기 안에서 삭제" 같은 경로가 추가되면 `isEditorPresented`와 삭제 `withAnimation`이 동시에 같은 셀의 offset/opacity/제거를 다투게 되므로 그때 재검토.

### [낮음/정보] retain cycle / 클로저 캡처 — 이상 없음
- **위치**: `:91-94`(alert actions), `:125-134`(contextMenu buttons), `:86-89`(Binding 클로저), `:122`(onTapGesture)
- **문제 아님(정보)**: alert/contextMenu/Binding의 모든 클로저는 **값 타입 View 컨텍스트**에서 `self`(struct) 또는 `pendingDelete`/`profile`을 캡처한다. struct View는 참조 순환을 만들지 않으며, `profile`(@Model 클래스 인스턴스)을 캡처해도 클로저가 뷰 트리와 함께 해제되므로 누수 없음. Binding의 get/set 클로저도 동일. **이상 없음.**
- **권고**: 없음.

### [낮음/정보] increment 2 중간 2건 반영 확인 — 이번 삭제 경로에 악영향 없음
- **위치**: `Utilities/ThumbnailCache.swift`(디코딩 캐시), `Views/UserSelectionView.swift:160`(`containerWidth + 200` 흩어짐)
- **확인**: increment 2의 [중간] #1(디코딩 캐시)는 `ThumbnailCache` 도입으로 반영됨 — `ProfileCircleView.swift:13`이 `ThumbnailCache.image(for:)` 사용. [중간] #2(A2 흩어짐 고정 offset)는 `scatterOffset`이 `containerWidth + 200`(`:160`)으로 폭 기반화됨. 삭제 시 셀이 제거되어도 캐시는 Data 해시 키라 **삭제된 프로필의 캐시 엔트리가 NSCache에 잠시 잔존**할 뿐(메모리 압력 시 자동 방출), 정합성/성능 영향 없음. 향후 "수정으로 이미지 교체" 빈번 시 캐시가 옛 해시 엔트리를 누적할 수 있으나 NSCache가 관리(무해, 확인 필요).
- **권고**: 없음. 캐시 무효화가 필요한 시나리오(대량 이미지 교체)가 생기면 명시적 evict 검토.

---

## 메인 스레드 / 메모리 / retain cycle 점검 결과 (increment 3 관점)

- **메인 스레드 무거운 연산**: 삭제 경로(`context.delete` + `context.save`, `:205/:207`)는 메인 동기 디스크 I/O이나 1회/소량으로 무해. 다운샘플은 여전히 `Task.detached` 백그라운드(ProfileEditorView.swift:128). `.contextMenu`/`.alert` 자체는 무거운 연산 없음.
- **retain cycle / [weak self]**: alert·contextMenu·Binding의 모든 클로저는 값 타입 View 컨텍스트. **이상 없음.**
- **무효 객체 접근**: 유일한 실질 위험은 alert 타이틀의 `pendingDelete?.name` 직접 보간(위 [중간]). 본문/버튼은 `presenting:` 인자 캡처로 안전.
- **상태 꼬임(중복 표시/잔존 참조)**: Binding get(`pendingDelete != nil`)은 정확. nil 정리가 3곳 중복이나 idempotent라 중복 표시·꼬임 없음(위 [낮음]). 삭제 후 `pendingDelete` 잔존 참조는 `:212`에서 nil로 해제 — 단 delete와 nil 사이 윈도우만 위 [중간]에서 다룸.
- **불필요 재계산**: `isEditorPresented`/`pendingDelete` 토글이 `body` 재평가를 부르지만 범위가 화면 하나라 비용 낮음. `ForEach` 안정 id로 삭제 애니메이션 정확.
- **향후 채색 단계 위험 패턴**: "삭제 직후 무효 @Model 접근"(타이틀 보간), "count 기반 인덱스가 삭제로 깨짐"(색)은 작업물 삭제/관리 화면으로 그대로 확장될 패턴 — 지금 정리하면 채색 단계에서 재발 방지.

---

## 심각도별 개수 요약

| 심각도 | 개수 | 항목 |
|--------|------|------|
| 높음 | 0 | — |
| 중간 | 1 | alert 타이틀의 `pendingDelete?.name` 직접 보간 → 삭제 직후 무효 @Model 접근 윈도우 |
| 낮음 | 5 | pendingDelete 이중 nil 정리 / nextColorIndex 색 충돌(삭제로 활성화) / `.contextMenu` 셀별 부착(정보) / deleteProfile 메인 save·에러 print / 삭제↔A1·A2 충돌 점검(정보) |
| 정보(추가) | 2 | retain cycle 이상없음 / increment2 중간 2건 반영 확인 |
| **합계** | **6** (정보 2건 별도) | |

> 낮음 5건 중 2건(`.contextMenu` 비용, 삭제↔애니메이션 충돌)은 "현재 문제 아님 + 향후 대비 정보성"이다.

## 가장 먼저 고칠 Top 3

1. **[중간] alert 타이틀의 무효 객체 접근 윈도우 제거** (`UserSelectionView.swift:85`, `:203-213`). 타이틀이 `pendingDelete?.name`을 직접 보간하므로 삭제 직후 dismiss 프레임에서 무효화된 @Model을 읽을 여지가 있다. `deleteProfile`에서 `pendingDelete = nil`을 `context.delete`보다 **먼저** 호출하거나, `pendingDelete` 설정 시 이름을 별도 @State(String)로 스냅샷해 타이틀이 값을 보간하도록 변경.
2. **[낮음] `nextColorIndex` 색 충돌 해소** (`UserSelectionView.swift:152-154`). 삭제 도입으로 `profiles.count` 기반 색 인덱스가 기존 프로필과 겹치기 시작했다. "사용 중 `colorIndex` 집합의 빈 최소 인덱스" 선택으로 변경(O(n) 1회 스캔). 컬러링 앱의 아이별 색 식별 의도 보존.
3. **[낮음] `pendingDelete` nil 정리 단일화** (`UserSelectionView.swift:88, 93, 212`). nil 설정 3경로를 한 곳(Binding set 또는 버튼 액션)으로 통합해, 향후 정리 로직 추가 시 중복 실행을 예방하고 닫힘 책임을 명확히.

---

## 이월 항목 검증

- **increment 2 [중간] #1 디코딩 캐시 / #2 A2 흩어짐** — 둘 다 반영 완료(`ThumbnailCache.swift`, `:160` `containerWidth + 200`). 이번 삭제 경로가 새로 악영향을 주지 않음(위 [낮음/정보] 항목).
- **increment 2 [낮음] nextColorIndex 색 충돌** — 예고대로 **이번 increment에서 활성화됨**. 위 [낮음] 항목 + Top 3 #2로 격상 권고.
- **increment 2 [낮음] context.save 에러 처리** — `deleteProfile`도 do/catch 패턴 계승(`:207-211`, 좋음). 단 에러가 `print`만이라 사용자 피드백은 여전히 미흡(견고성, 우선순위 낮음).
- **increment 1 [중간] #2 다운샘플링** — increment 2에서 해결 완료. 이번 범위 무관.

견고한 부분은 솔직히 견고하다: 삭제 플로우의 `presenting:` 인자 캡처, `ForEach` 안정 id 기반 제거 애니메이션, `withAnimation` 적용 범위, retain cycle 부재, 롱프레스 임시코드 완전 제거가 모두 적절하다. 불확실로 표기한 항목(삭제된 @Model 접근의 정확한 런타임 거동, `.contextMenu` 프리뷰 스냅샷 비용, NSCache 옛 해시 잔존)은 실제 다수 프로필/실기기 계측으로 확인 필요.
