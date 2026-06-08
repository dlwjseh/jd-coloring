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

/// iPhone 부모 제어판용 — 전송받은 ProfileSummary를 ProfileAvatar와 동일한 톤으로 렌더.
/// (iPhone은 SwiftData의 Profile을 갖지 않으므로 경량 요약 모델로 그린다.)
struct SummaryAvatar: View {
    let summary: ProfileSummary
    var diameter: CGFloat = 56

    var body: some View {
        ZStack {
            Circle().fill(Theme.tint(summary.colorIndex))

            if let data = summary.thumbnail, let image = ThumbnailCache.image(for: data) {
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
            Circle().stroke(Theme.ring(summary.colorIndex), lineWidth: max(3, diameter * 0.066))
        )
        .shadow(color: Theme.softShadow, radius: 6, x: 0, y: 3)
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
