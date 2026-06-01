import SwiftUI

/// 72색 펼침 그리드 팝오버 (8행 × 9열). 디자인 `10-palette.svg`.
struct ColorPaletteGrid: View {
    var selected: Color
    var onPick: (Color) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("색 고르기")
                    .font(Theme.rounded(24, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Text("프리즈마컬러 72색 · 탭하면 선택돼요")
                    .font(Theme.rounded(15))
                    .foregroundStyle(Theme.subText)
            }

            VStack(spacing: 10) {
                ForEach(Array(Palette.rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 10) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, color in
                            swatch(color)
                        }
                    }
                }
            }
        }
        .padding(28)
        .background(RoundedRectangle(cornerRadius: 32).fill(Theme.card))
        .shadow(color: Theme.softShadow, radius: 24, x: 0, y: 10)
    }

    private func swatch(_ color: Color) -> some View {
        let isSel = color == selected
        return Button { onPick(color) } label: {
            Circle()
                .fill(color)
                .frame(width: isSel ? 44 : 38, height: isSel ? 44 : 38)
                .overlay(Circle().stroke(isSel ? Theme.ink : Color(hex: 0xE6DDD3),
                                         lineWidth: isSel ? 3.5 : 1.5))
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
    }
}
