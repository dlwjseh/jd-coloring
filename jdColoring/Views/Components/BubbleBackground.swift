import SwiftUI

/// 화면 배경에 흩뿌려진 파스텔 방울(장식). 디자인 목업의 배경 방울을 구현.
/// 정적(애니메이션 없음) + 히트테스트 비활성 → 성능 부담 없음.
struct BubbleBackground: View {
    /// (상대 x, 상대 y, 지름, 색, 불투명도) — 화면 크기에 비례 배치
    private let bubbles: [(x: CGFloat, y: CGFloat, d: CGFloat, color: Color, opacity: Double)] = [
        (0.05, 0.15, 250, Theme.ringColors[1], 0.12),  // 퍼플 · 좌상
        (0.94, 0.12, 300, Theme.ringColors[2], 0.11),  // 티일 · 우상
        (0.62, 0.07, 140, Theme.ringColors[4], 0.10),  // 핑크 · 상단중앙
        (0.08, 0.60, 180, Theme.ringColors[3], 0.13),  // 옐로 · 좌중하
        (0.80, 0.52, 130, Theme.ringColors[2], 0.09),  // 티일 · 우중
        (0.24, 0.90, 180, Theme.ringColors[5], 0.12),  // 그린 · 좌하
        (0.58, 0.94, 130, Theme.ringColors[0], 0.10),  // 코랄 · 하단중앙
    ]

    var body: some View {
        GeometryReader { geo in
            ForEach(Array(bubbles.enumerated()), id: \.offset) { _, b in
                Circle()
                    .fill(b.color)
                    .opacity(b.opacity)
                    .frame(width: b.d, height: b.d)
                    .position(x: geo.size.width * b.x, y: geo.size.height * b.y)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
