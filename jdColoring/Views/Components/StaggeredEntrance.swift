import SwiftUI

/// 항목을 오른쪽 바깥에서 제자리로 순차(stagger) 등장시키는 진입 애니메이션 (A1).
///
/// 애니메이션을 `value: visible` 로 고정해 **visible이 false→true로 바뀔 때만** 재생되게 한다.
/// 덕분에 프로필 내용 변경 등 다른 상태 변화가 이 진입 연출에 끌려가지 않는다. (타이머 미사용)
struct StaggeredEntrance: ViewModifier {
    /// 접근성 "동작 줄이기" 시 이동·stagger 생략하고 페이드만.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let index: Int
    let visible: Bool
    var perItemDelay: Double = 0.07
    var offBoundsX: CGFloat = 700

    func body(content: Content) -> some View {
        let offX = reduceMotion ? 0 : offBoundsX
        let delay = reduceMotion ? 0 : Double(index) * perItemDelay
        content
            .offset(x: visible ? 0 : offX)
            .opacity(visible ? 1 : 0)
            .animation(
                .spring(response: 0.5, dampingFraction: 0.75).delay(delay),
                value: visible
            )
    }
}

extension View {
    /// index 순서대로 시차를 두고 오른쪽에서 등장 (A1 진입 연출)
    func staggeredEntrance(index: Int, visible: Bool) -> some View {
        modifier(StaggeredEntrance(index: index, visible: visible))
    }
}
