import SwiftUI

/// 원형 아바타(이름 없음). 컨텍스트 메뉴 프리뷰가 원형으로 잡히도록 라벨과 분리한다.
struct ProfileAvatar: View {
    let profile: Profile
    var diameter: CGFloat = 130

    var body: some View {
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
    }
}

#Preview {
    HStack(spacing: 24) {
        ProfileAvatar(profile: Profile(name: "지호", colorIndex: 0), diameter: 130)
        ProfileAvatar(profile: Profile(name: "서연", colorIndex: 1), diameter: 130)
    }
    .padding(40)
    .background(Theme.bgGradient)
}
