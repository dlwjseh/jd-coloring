import SwiftUI

/// 우하단 코너의 플로팅 추가 버튼 (캡션 교체로 화면마다 재사용)
struct AddButton: View {
    var caption: String = "프로필 추가"
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Theme.coral)
                        .frame(width: 96, height: 96)
                        .shadow(color: Theme.softShadow, radius: 11, x: 0, y: 7)
                    Image(systemName: "plus")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(.white)
                }
                Text(caption)
                    .font(Theme.rounded(18, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x7A6E64))
            }
        }
        .buttonStyle(.plain)
    }
}
