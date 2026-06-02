import SwiftUI

/// 도안 그리드 셀. 현재 프로필의 작업물이 있으면 진행 썸네일 + '진행 중' 배지,
/// 없으면 빈 도안(라인아트)을 보여준다. ('진행 중'은 배지 + 채움 유무로 이중 표시)
struct TemplateCellView: View {
    let template: Template
    let artwork: Artwork?

    private var inProgress: Bool { artwork?.progressThumbnail != nil }
    /// 그리드 표시는 항상 작은 썸네일만 디코딩 (풀해상 색칠 이미지 디코딩 회피 — 검수 increment4)
    private var displayData: Data { artwork?.progressThumbnail ?? template.thumbnailData }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 28)
                    .fill(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: 28).stroke(Theme.cardBorder, lineWidth: 2))
                    .shadow(color: Theme.softShadow, radius: 10, x: 0, y: 6)

                if let image = ThumbnailCache.image(for: displayData) {
                    image
                        .resizable()
                        .scaledToFit()
                        .padding(22)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                if inProgress {
                    Text("진행 중")
                        .font(Theme.rounded(15, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Theme.coral))
                        .padding(12)
                }
            }

            Text(template.name)
                .font(Theme.rounded(19, weight: .bold))
                .foregroundStyle(inProgress ? Theme.ink : Theme.subText)
                .lineLimit(1)
        }
    }
}

/// 컨텍스트 메뉴(롱프레스) lift 프리뷰. 그림자/배지 없이 **캐시된 썸네일만** 그려
/// iOS의 자동 스냅샷(오프스크린 그림자 렌더로 수 초 지연)을 피한다. (GalleryView)
struct TemplateMenuPreview: View {
    let template: Template
    let artwork: Artwork?

    private var displayData: Data { artwork?.progressThumbnail ?? template.thumbnailData }

    var body: some View {
        ZStack {
            Color.white
            if let image = ThumbnailCache.image(for: displayData) {
                image
                    .resizable()
                    .scaledToFit()
                    .padding(20)
            }
        }
        .frame(width: 240, height: 240)
    }
}
