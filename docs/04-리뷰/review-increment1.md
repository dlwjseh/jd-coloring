# 성능 검수 리포트 — Increment 1 (사용자 선택 화면)

대상: `/Users/JD/workspace/jd-coloring/jdColoring/` 전 .swift 파일
검수일: 2026-06-01
관점: iOS/macOS(SwiftUI) 성능 — 렌더링/스레드/메모리, 그리고 향후 채색 단계로 이어질 위험 패턴
방침: 코드 수정 없음. 진단·권고만. 실제 코드 라인 근거로만 판단. 불확실은 '확인 필요' 표기.

## 반영 결과 (2026-06-01, 개발자)

- **#1 A1 stagger 방식 (중간) — 반영 완료.** 진입 연출을 `StaggeredEntrance` ViewModifier(`Views/Components/StaggeredEntrance.swift`)로 분리하고 `value: visible`로 스코프를 고정. `UserSelectionView`에서 `.staggeredEntrance(index:visible:)`로 사용. 타이머 미사용 유지.
- **#3 비-lazy HStack (낮음) — 반영 완료.** `UserSelectionView` 프로필 줄을 `HStack` → `LazyHStack`으로 전환.
- **#2 이미지 다운샘플링 부재 (중간) — increment 2로 이월.** 갤러리 사진 선택 기능이 붙는 단계에서 `CGImageSource` 썸네일 + 백그라운드 디코딩 + 캐시로 설계 예정.
- 나머지 낮음 항목(향후 채색 단계 대비 권고 등)은 해당 increment에서 반영 예정.
- 반영 후 macOS 빌드 통과 확인.

---

## 총평

이번 increment는 **사용자 선택 화면 하나로 범위가 좁고, 대체로 견고**하다. 무거운 픽셀 연산·flood fill·undo 스택 같은 채색 핵심 경로는 아직 존재하지 않으며, 현재 코드에서 명백한 메인 스레드 블로킹이나 retain cycle은 발견되지 않았다. 다만 **A1 진입 애니메이션 구현 방식 1건(중간)**, **이미지 다운샘플링 부재로 인한 향후 위험 1건(중간)**, 그리고 몇 가지 낮은 수준의 개선점·향후 대비 권고가 있다. 기획서가 명시한 평가자 체크포인트("stagger를 타이머 남발 없이", "매 진입 재생이라 가볍게")는 타이머 측면에선 잘 지켜졌으나, 항목별 `.animation(value:)` 사용에 미묘한 위험이 있다.

---

## 발견 항목

### [중간] A1 stagger를 항목별 암시적 `.animation(_:value:)`로 구현 — 항목 수 증가 시 동시 스프링 부하 및 의도치 않은 재생 위험
- **위치**: `Views/UserSelectionView.swift:58-66`
- **문제**:
  - 각 프로필에 `.offset` + `.opacity` + `.animation(.spring(...).delay(index*0.07), value: appeared)`를 항목별로 붙였다. `appeared`가 false→true로 바뀌면 모든 항목이 동시에 자기 delay 타이머를 걸고 스프링 보간을 시작한다. 프로필이 많아질수록(기획 "최대 개수 제한 없음", requirements.md:100) 동시에 진행되는 스프링 애니메이션 개수가 선형 증가한다.
  - 더 중요한 건 **암시적 `.animation(value:)`의 부수효과**다. 이 수식어는 `appeared`뿐 아니라 그 뷰에 영향을 주는 다른 상태 변화도 애니메이션 대상으로 끌어들일 수 있다. 향후 이 화면에 프로필 추가/삭제(A2), 선택 하이라이트 등이 붙으면 `.offset`/`.opacity`가 의도치 않게 스프링으로 재생되며 버벅임으로 체감될 수 있다.
- **근거**: requirements.md:79 / design-spec.md:80가 "프로필 多일 때 동시 애니메이션 부하", "매 진입 재생이라 무거우면 바로 체감"을 평가자 체크포인트로 명시. 화면에 올 때마다(`onAppear`) 전 항목이 매번 재생되므로 항목 수가 곧 비용이다.
- **권고**:
  - 항목별 `.animation(value:)` 대신 **명시적 `withAnimation` + per-item delay**, 또는 `phaseAnimator`/`PhaseAnimator`(iOS17+)나 컨테이너 단위 transition으로 전환. 기획서 구현 메모(requirements.md:76-78, design-spec.md:80)가 이미 "transition+delay"를 권한다.
  - 화면 밖(오른쪽 700pt)에 있어도 ForEach 항목은 여전히 레이아웃·렌더 대상이다. 항목 수가 커지면 **수평 ScrollView를 `LazyHStack`으로** 바꿔 가시 영역 밖 비용을 줄이는 것을 검토(아래 별도 항목 참조).
  - delay를 항목 인덱스 비례(`0.07*index`)로 두면 항목이 많을 때 마지막 항목 등장까지 누적 지연이 길어진다. **상한 캡**(예: 처음 N개만 stagger, 이후는 동시) 권장.

### [중간] 프로필 이미지 다운샘플링 부재 — 향후 갤러리 원본 다수 로딩 시 메모리·디코딩 비용
- **위치**: `Utilities/Image+Data.swift:10-20`, `Views/Components/ProfileCircleView.swift:13-18`
- **문제**:
  - `Image(data:)`가 `UIImage(data:)`/`NSImage(data:)`로 **원본 해상도 전체를 디코딩**한다. 130pt(레티나 2x여도 260px) 원형 썸네일에 표시하면서도 디코딩되는 픽셀 버퍼는 원본 크기다.
  - 이번 increment는 메모리 내 샘플 데이터라 `imageData`가 모두 nil(Profile.swift:21-25)이라 **현재는 미발현**이지만, 기획상 곧 "사진 앨범에서 선택"(requirements.md:42)이 붙는다. 사용자가 12MP HEIC 등을 고르면 프로필당 수십 MB 디코딩 버퍼가 잡히고, 프로필이 여러 개면 가로 스크롤 중 메모리·디코딩 비용이 누적된다.
  - 비기능 요구사항이 이를 직접 명시: "프로필 이미지 다수여도 썸네일 다운샘플링으로 메모리 절약"(requirements.md:92).
- **근거**: 현재 코드 자체는 안전(데이터 nil)하나, 다음 increment에서 즉시 체감될 구조적 부재. 다운샘플링 경로가 어디에도 없음(전 파일 확인).
- **권고**:
  - increment 2에서 갤러리 선택을 붙일 때 **`CGImageSourceCreateThumbnailAtIndex` + `kCGImageSourceThumbnailMaxPixelSize`(다이아미터*scale 기준)** 로 다운샘플링한 썸네일을 생성·표시하라. 저장 시에도 원본 대신 다운샘플 또는 리사이즈본을 앱 내부에 보관(requirements.md:83 "내부 저장소 복사·보관"과 결합).
  - 디코딩은 백그라운드에서 수행하고 결과만 메인에서 표시(아래 스레드 항목과 연계).
  - `Image(data:)`를 표시 시점마다 호출하면 body 재계산마다 재디코딩 위험이 있으므로, **디코딩 결과를 캐시**(또는 모델 측 썸네일 보관)하는 구조로.

### [낮음] 수평 ScrollView가 비-lazy HStack — 프로필 다수 시 전 항목 즉시 생성
- **위치**: `Views/UserSelectionView.swift:56-72`
- **문제**: `ScrollView(.horizontal) { HStack { ForEach(...) } }`는 화면 밖 항목까지 한 번에 생성·레이아웃한다. 프로필이 적을 땐 무해하나, 기획상 개수 제한이 없고(requirements.md:100) 각 항목이 이미지 디코딩(위 항목)을 동반하면 비용이 선형으로 쌓인다.
- **근거**: 현재 샘플 5개로는 체감 없음. 다수 + 이미지 결합 시 진입(매번 재생) 비용 증가.
- **권고**: `LazyHStack`으로 교체 검토. 단, A1 stagger가 "화면 밖→제자리" 슬라이드라 lazy화하면 화면 밖 항목이 아직 생성 전이라 등장 타이밍이 달라질 수 있으니, **다운샘플링·캐시와 함께** 설계할 것. 소규모(수~십수 개)면 현행 유지도 합리적.

### [낮음] ProfileCircleView가 ID 식별자에 의존하나 등장 애니메이션이 인덱스 기반 — 삭제/재정렬 시 어긋남 가능성(확인 필요)
- **위치**: `Views/UserSelectionView.swift:58` (`id: \.element.id`) + `:64` (`delay(Double(index)*0.07)`)
- **문제**: ForEach 식별자는 안정적인 `profile.id`(UUID)로 올바르게 잡혀 있어 **현재는 좋다**. 다만 stagger delay가 `enumerated()`의 인덱스 기반이라, 향후 정렬 변경·중간 삭제(requirements.md:101-102 열린 질문)가 생기면 같은 프로필이 진입할 때마다 다른 인덱스→다른 delay를 받아 등장 순서가 들쭉날쭉해질 수 있다. 성능보다는 일관성 이슈에 가깝지만, 잘못된 diff가 발생하면 불필요한 리렌더로 이어질 수 있어 기재.
- **근거**: 코드상 식별자는 정상. 영향은 increment 2(추가/삭제) 도입 후에야 발생 → '확인 필요'.
- **권고**: 식별자(`\.element.id`)는 그대로 유지(좋음). stagger 기준은 "표시 순서 인덱스"가 의도라면 현행 OK이나, A2 도입 시 항목 추가/삭제가 전체 재-stagger를 유발하지 않도록 애니메이션 트리거 범위를 분리.

### [낮음] `onAppear`에서 `appeared=false` 직후 `Task { appeared=true }` — 의도대로 동작하나 미세 취약
- **위치**: `Views/UserSelectionView.swift:35-39`
- **문제**: "매 진입 재생" 요구(requirements.md:64)를 만족시키려 false로 리셋 후 다음 런루프에서 true로 토글하는 패턴. 타이머를 쓰지 않아 평가자 체크포인트("타이머 남발 금지")를 잘 지킨다. 다만 `Task { @MainActor in ... }`는 `onAppear` 동기 컨텍스트(이미 메인) 대비 한 틱 뒤 실행이라 토글이 보장되지만, SwiftUI가 같은 트랜잭션에서 false→true를 합쳐버려 애니메이션이 스킵될 가능성은 이론상 존재(보통은 분리됨). 또한 같은 화면이 빠르게 재진입하면 직전 Task와 경합 가능(현재는 단순해 영향 미미).
- **근거**: 현재 단일 화면·단순 구조라 실측 문제는 관찰되지 않음. 구조적 미세 취약점으로만 기재.
- **권고**: 동작에 문제 없으면 유지. 더 견고히 하려면 진입마다 증가하는 `id`로 ForEach 컨테이너에 `.transition` + `withAnimation`을 명시적으로 거는 방식(또는 `.transaction`으로 first-appear 제어)이 의도를 더 분명히 표현. 정착 스프링 파라미터는 design-spec.md:71의 `response:0.45`와 코드의 `0.5`가 미세 불일치 — 의도 확인 필요(성능 무관, 메모).

### [낮음/정보] SmileyFace의 `Canvas` 사용 — 현재 적절, 향후 채색 단계 참고 포인트
- **위치**: `Views/Components/SmileyFace.swift:9-37`
- **문제 아님(정보)**: 정적인 단순 도형 몇 개를 `Canvas`로 그린다. 비율 기반 좌표라 크기 무관 재사용 가능하고, 그릴 요소가 적어 비용이 낮다. **현재 적절**하다. 다만 매 body마다 `Canvas` 클로저가 재실행되므로, 만약 이 컴포넌트가 빈번히 재계산되는 부모(예: 스크롤/애니메이션 중) 안에서 다수 인스턴스로 쓰이면 누적 비용이 생길 수 있다. 현 화면은 프로필당 1개라 무해.
- **근거**: 도형 수 소수, 입력 불변. 실측 부담 없음.
- **권고**: 현행 유지. **향후 채색 캔버스**에서는 이 패턴(매 변경마다 전체 Canvas 재그리기)이 곧 "매 터치마다 전체 캔버스 재그리기" 안티패턴으로 직결되므로, 그 단계에선 더티 영역만 갱신/레이어 분리/`drawingGroup()`·Metal 검토가 필요함을 미리 기록.

### [낮음/정보] `ProfileStore.profiles`가 `@Published` 단일 배열 — increment 1에선 무해, 향후 입력 빈도 높은 상태와 분리 권장
- **위치**: `Models/ProfileStore.swift:6-11`
- **문제 아님(정보)**: 현재 프로필 목록만 담는 가벼운 `ObservableObject`. `@MainActor`로 격리되어 있어 적절. 향후 채색 진행 상태·드로잉 좌표처럼 **고빈도로 바뀌는 상태**를 같은 ObservableObject의 `@Published`에 넣으면 구독하는 모든 뷰 body가 재계산되어 성능 문제가 된다.
- **근거**: 현재는 변경 빈도가 매우 낮아(추가/삭제 시점만) 무해.
- **권고**: 채색 상태는 별도 모델/`@Observable`(iOS17+)로 분리하고, 뷰는 필요한 최소 프로퍼티만 구독하도록 설계.

---

## 메인 스레드 / 메모리 / retain cycle 점검 결과

- **메인 스레드 무거운 연산**: 현재 파일 IO·디코딩·대형 연산이 화면 로직에 없음(이미지 데이터가 모두 nil). 갤러리/디코딩 도입 시 백그라운드 분리 필요(위 다운샘플링 항목).
- **retain cycle / [weak self]**: 클로저는 `AddButton.action`, `onTapGesture`, `onAppear`의 `Task` 정도이며 모두 값 타입 뷰 컨텍스트로 self 강참조 누수 위험 없음. **이상 없음.**
- **대형 객체 불필요 복사·보관**: `Profile.imageData: Data?`(Profile.swift:7)는 값 타입이라 배열·전달 시 복사 의미를 가지나, Swift `Data`는 copy-on-write라 실제 복사는 변형 시에만 발생. 다만 원본 Data를 모델에 그대로 보관하는 구조는 위 다운샘플링 미적용과 결합 시 메모리 보관량이 커진다 → 다운샘플본 보관 권장.
- **타이트 루프 내 할당 / O(n^2)**: 현재 코드에 루프 기반 핫패스 없음. `Theme.ring/tint`의 모듈러 인덱싱(Theme.swift:44-45)은 O(1).

---

## 심각도별 개수 요약

| 심각도 | 개수 | 항목 |
|--------|------|------|
| 높음 | 0 | — |
| 중간 | 2 | A1 항목별 `.animation(value:)` stagger / 이미지 다운샘플링 부재 |
| 낮음 | 5 | 비-lazy HStack / 인덱스 기반 stagger 일관성(확인 필요) / onAppear 토글 미세 취약 / SmileyFace Canvas(정보) / ProfileStore @Published(정보) |
| **합계** | **7** | |

> 참고: 낮음 5건 중 2건(SmileyFace, ProfileStore)은 "현재 문제 아님 + 향후 대비 정보성"이다.

## 가장 먼저 고칠 Top 3

1. **[중간] A1 stagger를 항목별 `.animation(value:)` → 명시적 `withAnimation`/`transition`+delay 또는 `phaseAnimator`로 전환** (UserSelectionView.swift:58-66). 매 진입 재생 + 항목 수 비례 동시 스프링 + 의도치 않은 상태가 애니메이션에 끌려가는 위험을 함께 해소. 기획서 평가자 체크포인트와 직접 연결.
2. **[중간] 이미지 다운샘플링 경로 선설계** (Image+Data.swift / ProfileCircleView.swift). increment 2의 갤러리 선택을 붙이기 전에 `CGImageSource` 썸네일 다운샘플 + 백그라운드 디코딩 + 결과 캐시 구조를 미리 마련. 비기능 요구(requirements.md:92) 직접 충족.
3. **[낮음] 수평 리스트 lazy화 + 디코딩 캐시 검토** (UserSelectionView.swift:56-72). 1·2번과 묶어, 프로필 다수 + 이미지 결합 시 진입 비용이 선형 폭증하지 않도록 `LazyHStack`/캐시 적용 여부를 결정.
