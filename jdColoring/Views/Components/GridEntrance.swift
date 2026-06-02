import SwiftUI

/// 그리드 셀을 **밑에서 위로 올라오며** 페이드 인하는 순차(stagger) 진입 연출 (화면 2, G1 §12).
/// 프로필이 흩어진 뒤 도안들이 "우수수" 올라오는 느낌.
///
/// `value: visible` 로 고정해 visible false→true 일 때만 재생(타이머 미사용).
/// index 지연은 14개에서 포화시켜 도안이 많아도 마지막까지 너무 늦지 않게 한다.
struct GridEntrance: ViewModifier {
    /// 접근성 "동작 줄이기" 시 올라오는 이동·stagger 생략하고 페이드만.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let index: Int
    let visible: Bool
    var perItemDelay: Double = 0.04
    /// 등장 시작 시 아래로 내려가 있는 거리(px) — 이만큼 아래에서 올라온다.
    var riseFrom: CGFloat = 56

    func body(content: Content) -> some View {
        let rise = reduceMotion ? 0 : riseFrom
        let delay = reduceMotion ? 0 : Double(min(index, 14)) * perItemDelay
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : rise)
            .animation(
                .spring(response: 0.5, dampingFraction: 0.82).delay(delay),
                value: visible
            )
    }
}

extension View {
    /// index 순서대로 시차를 두고 **밑에서 올라오며** 페이드 인 (화면 2 진입 연출, G1)
    func gridEntrance(index: Int, visible: Bool) -> some View {
        modifier(GridEntrance(index: index, visible: visible))
    }
}
