import SwiftUI

/// 그리드 셀을 페이드 + 살짝 스케일 업으로 순차(stagger) 등장시키는 진입 연출 (화면 2, A1 톤).
///
/// `value: visible` 로 고정해 visible false→true 일 때만 재생(타이머 미사용).
/// index 지연은 14개에서 포화시켜 도안이 많아도 마지막까지 너무 늦지 않게 한다.
struct GridEntrance: ViewModifier {
    let index: Int
    let visible: Bool
    var perItemDelay: Double = 0.045

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .scaleEffect(visible ? 1 : 0.85)
            .animation(
                .spring(response: 0.5, dampingFraction: 0.78)
                    .delay(Double(min(index, 14)) * perItemDelay),
                value: visible
            )
    }
}

extension View {
    /// index 순서대로 시차를 두고 페이드+스케일로 등장 (화면 2 진입 연출)
    func gridEntrance(index: Int, visible: Bool) -> some View {
        modifier(GridEntrance(index: index, visible: visible))
    }
}
