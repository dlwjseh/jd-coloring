import SwiftUI

/// 원형 프로필 + 이름 라벨
struct ProfileCircleView: View {
    let profile: Profile
    var diameter: CGFloat = 130

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.tint(profile.colorIndex))

                if let data = profile.imageData, let image = ThumbnailCache.image(for: data) {
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: diameter, height: diameter)
                        .clipShape(Circle())
                } else {
                    SmileyFace(size: diameter)
                }
            }
            .frame(width: diameter, height: diameter)
            .overlay(
                Circle().stroke(Theme.ring(profile.colorIndex), lineWidth: diameter * 0.066)
            )
            .shadow(color: Theme.softShadow, radius: 11, x: 0, y: 7)

            Text(profile.name)
                .font(Theme.rounded(diameter * 0.18, weight: .bold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
        }
    }
}

#Preview {
    HStack(spacing: 24) {
        ProfileCircleView(profile: Profile(name: "지호", colorIndex: 0))
        ProfileCircleView(profile: Profile(name: "서연", colorIndex: 1))
    }
    .padding(40)
    .background(Theme.bgGradient)
}
