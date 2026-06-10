import SwiftUI
import SwiftData

/// 도안 갤러리 '정렬' 모드의 드래그-재배치 지원.
/// (기획/디자인 §도안 정렬, 2026-06-09)
///
/// 구현 방침(2차 개정 — `onDrag`/`onDrop` 폐기):
///  - `.onDrag`/`.onDrop` 은 **지글(회전 중) 카드를 시스템이 스냅샷**하려다 "Invalid frame dimension"·
///    "gesture gate timed out" 로그를 내고, 드래그 세션이 깔끔히 시작/종료되지 않아 dim 이 stuck 됐다.
///  - 대신 **LongPress→Drag 커스텀 제스처**로 바꾼다. `onEnded` 가 손 뗄 때 **반드시** 불려 dim 을 확실히
///    풀고(자체 종료 신호), 시스템 드래그 스냅샷이 없어 프레임 오류도 사라진다.
///  - 드래그 중에는 로컬 순서 배열(`reorderIDs`)만 바꾼다(SwiftData write 없음). 저장은 '완료'/이탈 시 1회.

// MARK: - Jiggle (편집 모드 흔들림)

/// 카드가 "옮길 수 있음"을 알리는 미세 흔들림(±`amp`°). Reduce Motion 이면 흔들지 않는다(정적).
///
/// `PhaseAnimator`(iOS 17+)로 구동 — `repeatForever`+`@State` 는 드래그 reflow 의 `withAnimation`
/// 트랜잭션에 한번 끊기면 재시작되지 않는다(드래그 후 흔들림 멈춤 버그). PhaseAnimator 는 자체 타임라인이라
/// 외부 트랜잭션에 영향받지 않는다.
struct Jiggle: ViewModifier {
    let active: Bool
    let index: Int
    let reduceMotion: Bool

    private var amp: Double { 1.8 }
    /// 인접 카드끼리 위상이 어긋나 보이도록 인덱스 패리티로 방향을 뒤집는다.
    private var sign: Double { index % 2 == 0 ? 1 : -1 }
    /// 모든 셀이 같은 프레임에 동시에 꺾이지 않게 시작 위상을 분산(동시 갱신 피크 완화 — 검수 H-1).
    private var phaseDelay: Double { Double(index % 4) * 0.07 }

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            content.phaseAnimator([false, true]) { view, up in
                view.rotationEffect(.degrees((up ? amp : -amp) * sign))
            } animation: { _ in
                // 0.6s 주기(검수 H-1: 과빈도 완화) + 인덱스별 시작 위상 분산.
                .easeInOut(duration: 0.6).delay(phaseDelay)
            }
        } else {
            content   // Reduce Motion(또는 들린 카드): 흔들지 않음.
        }
    }
}

extension View {
    func jiggle(active: Bool, index: Int, reduceMotion: Bool) -> some View {
        modifier(Jiggle(active: active, index: index, reduceMotion: reduceMotion))
    }
}

// MARK: - 셀 프레임 수집 (드래그 히트 판정용)

/// 각 도안 셀의 그리드 좌표 프레임을 모은다. 드래그 위치가 어느 셀 위인지 판정해 재배치 대상을 찾는다.
/// (정렬 모드에서만 셀에 부착되므로 평상시엔 수집·전파 비용이 없다.)
struct CellFramePreference: PreferenceKey {
    static let defaultValue: [PersistentIdentifier: CGRect] = [:]
    static func reduce(value: inout [PersistentIdentifier: CGRect],
                       nextValue: () -> [PersistentIdentifier: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 셀 프레임을 **참조 타입**으로 보관한다(검수 H-2). `@State` 딕셔너리에 담으면 reflow 스프링 동안
/// 매 프레임 `onPreferenceChange` write → body 전체 재평가 루프가 생긴다. 프레임은 히트 판정(제스처
/// 콜백)에서만 읽고 화면 표시에는 안 쓰이므로, 클래스에 담아 갱신해도 body 를 invalidate 하지 않게 한다.
@MainActor
final class FrameStore {
    var frames: [PersistentIdentifier: CGRect] = [:]
}
