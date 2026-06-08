# 검수 리포트: Increment 6 — 프로필 지정 타이머 (Targeted Timer)

> **반영 결과 (2026-06-08, 빌드 SUCCEEDED)**
> - **B-1 (해결)**: `RootView.reconcileProfileUUIDsOnce()` 기동 1회 백필 추가 — 중복/제로 UUID 발견 시 재할당+save. (실기기 마이그레이션 후 `profiles.map(\.uuid)` distinct·non-zero 검증은 여전히 권장.)
> - **M-1 (해결)**: 만료 핸들러 가드에 `timerAppliesToMe` 추가(`ColoringCanvasView`). 불일치 시 홈 복귀 없이 로컬 정리.
> - **M-2 (해결)**: `profileSignature`/per-body 순회 제거. 전송을 `UserSelectionView`의 CRUD 지점(`broadcastProfilesIfConnected`) + RootView 연결 시점으로 분리.
> - **m-1 (해결)**: 전송 썸네일을 `profileSummaries(_:)`에서 160px로 재다운샘플(저장본 512px과 분리).
> - **m-3 (해결)**: `ParentControlView` 만료 비교를 `rem <= 0` 임계 비교로.
> - **m-2 (보류)**: 진행 화면 매초 body 재평가 — 영향 미미·리팩터 위험 대비 효과 낮아 미적용(추후 TimelineView 분리 후보).
> - **n-1·n-2**: 이상 없음 확인됨(조치 불필요).

---


검수 대상 8개 파일을 정독, 기획서 §「프로필 지정 타이머」 및 디자인 스펙 §31 체크포인트와 대조.
결론: **blocker 1건, major 2건, minor 3건, nit 2건**. 채색 핫패스 회귀 없음.

---

## BLOCKER

### B-1. SwiftData 경량 마이그레이션이 기존 행 전부에 **동일/제로 UUID**를 부여할 위험
- 위치: `Models/Profile.swift` (`var uuid: UUID = UUID()`)
- 문제: `= UUID()`는 Swift 프로퍼티 초기화 식이지 저장소 스키마의 상수 기본값이 아니다. 경량 마이그레이션이 기존 행을 채울 때 이 식을 행마다 재평가한다는 보장이 없어, 최악의 경우 **모든 기존 프로필이 같은(또는 all-zero) UUID**를 받는다.
- 치명도: 타깃 매칭 전제가 `currentProfile.uuid == receivedTimerTarget`. uuid 충돌 시 지정 아닌 아이도 `timerAppliesToMe==true`가 되어 **엉뚱한 아이가 홈으로 쫓겨난다**(확정 #2 위반). 기존 설치 데이터에서만 발생 → 신규 시뮬레이터 검증으로는 못 잡음.
- 권고: (1) 앱 기동 1회 **백필** — 로드 후 중복/제로 UUID 발견 시 `uuid = UUID()` 재할당 + save. (2) 또는 `MigrationStage.custom`의 `didMigrate`에서 행별 고유 UUID 부여. 어느 쪽이든 실기기에서 `profiles.map(\.uuid)`가 모두 distinct·non-zero인지 검증.

---

## MAJOR

### M-1. 만료 핸들러가 **만료 순간 활성 프로필을 재검증하지 않음** — 기획 체크포인트 위반
- 위치: `Views/ColoringCanvasView.swift` `onChange(of: timerRemaining)`
- 기획 요구: "만료 핸들러에서 `currentProfile.uuid == receivedTimerTarget` 확인 후에만 flush+removeAll".
- 문제: 현재 `timerRemaining <= 0`만 보고 무조건 `path.removeAll()`. `syncTimerFromPeer`가 불일치 시 timerEnd를 nil로 둬 간접 우회되지만, 명시적 방어선 부재.
- 권고: `guard let rem, rem <= 0, !timerExpired, timerAppliesToMe else { return }`. false면 정리만.

### M-2. `profileSignature`가 `@Query profiles` 변경마다가 아니라 **body 재평가마다 전체 순회**
- 위치: `jdColoringApp.swift` `RootView`
- 문제: computed `profileSignature`는 `RootView.body`가 재평가될 때마다(=NavigationStack path push/pop, 즉 앨범/갤러리/캔버스 이동마다) N개 프로필을 Hasher로 재순회. 전송 자체는 변경 시에만 발생(폭주 아님)하나 해시 계산 빈도가 navigation에 결합.
- 규모: 프로필 2~5명에선 무시 수준이나 구조적 낭비.
- 권고: 전송 트리거를 프로필 CRUD 지점으로 옮겨 body 빈도와 분리, 또는 시그니처를 body 외부로.

---

## MINOR

### m-1. `profileList` 페이로드가 **512px 썸네일 합산** — 56pt 아바타엔 오버스펙
- 위치: `jdColoringApp.swift` `summaries`(`thumbnail: $0.imageData`) → reliable 전송
- 사실: 저장 썸네일은 maxPixel 512/0.8 (장당 50~150KB). 5명이면 250~750KB를 한 메시지로. iPhone 칩은 56pt라 128~160px면 충분.
- 권고: 전송용으로 더 작게(maxPixel ~160) 다운샘플해 담기. 저장본과 분리, 백그라운드 처리.

### m-2. 매초 `now` 갱신이 **진행 화면 body 전체** 재평가
- 위치: `ParentControlView.swift` `onReceive(clock)`
- 사실: 대기 화면은 guard로 차단(이상 없음). 진행 중엔 매초 `ParentControlView.body` 전체 무효화(connectionBar/BubbleBackground 포함).
- 권고: 남은 시간부를 서브뷰로 분리하거나 `TimelineView(.periodic)`로 갱신 범위 축소.

### m-3. 만료 판정이 부동소수 동치(`rem == 0`)에 의존
- 위치: `ParentControlView.swift` `onChange(of: remaining)`
- 사실: `max(0, …)`라 보통 정확히 0이 되어 안전하나 클럭 지터 시 한 박자 늦을 수 있음.
- 권고: `if let rem, rem <= 0` 임계 비교.

---

## NIT (둘 다 이상 없음 확인)

### n-1. target/end set 순서 레이스 — **이상 없음**
- `PeerSession.didReceive`에서 `receivedTimerTarget` → `receivedTimerEnd`를 동일 `Task { @MainActor }` 안에서 동기 연속 대입. SwiftUI는 트랜잭션 종료 후 한 번에 관찰하므로 `onChange(receivedTimerEnd)` 발화 시 target은 이미 최신. `timerAppliesToMe`가 최신값을 읽음.

### n-2. nonisolated 델리게이트 → MainActor hop / `[weak self]` — **이상 없음**
- 모든 델리게이트가 `Task { @MainActor [weak self] in guard let self else { return } }`로 일관. 순환참조 없음, deinit 정리 적절.

---

## "이상 없음" 명시 판정
- **#4 만료/소멸 3분기**: `syncTimerFromPeer` 무시/소멸/적용 분기가 기획표와 일치. 비활성 만료 후 뒤늦은 진입 시 receivedTimerEnd/Target 클리어, onAppear 재동기화·timerExpired 중복방지·scenePhase 복귀 처리까지 커버. (단 M-1 보강 필요.)
- **#5 selectedProfile 검증**: `onChange(of: availableProfiles)`로 사라진 대상 해제, 삭제 프로필 타깃은 소멸로 안전.
- **#6 채색 핫패스 회귀**: 타이머 게이트는 칩 표시·타이머 onChange/onReceive에만 국한. CanvasArea/ZoomableCanvasPanel/DrawingCanvas 무손상. **회귀 0.**
- **#3 레이스/hop**: n-1·n-2 — 이상 없음.

---

## 요약

| 심각도 | 건수 | 항목 |
|---|---|---|
| blocker | 1 | B-1 마이그레이션 UUID 중복 |
| major | 2 | M-1 만료 활성 재검증, M-2 시그니처 재계산 빈도 |
| minor | 3 | m-1 썸네일 페이로드, m-2 진행화면 body 범위, m-3 만료 임계 비교 |
| nit | 2 | n-1·n-2 (이상 없음) |

**Top 3 우선 수정**: B-1(매칭 토대) → M-1(한 줄 방어선) → M-2(navigation 결합 제거).
