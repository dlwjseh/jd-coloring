import Foundation
import SwiftData

/// 색칠 도안 (전역 공유). 누군가 올리면 모든 프로필이 함께 본다.
/// 색칠 결과는 프로필별 `Artwork` 로 따로 저장된다.
///
/// 표시용 썸네일과 색칠용 이미지를 **분리 저장**한다(검수 increment4):
/// 그리드 셀은 작은 `thumbnailData`만 디코딩하고, 풀해상 `imageData`는 색칠 화면에서만 쓴다.
@Model
final class Template {
    var name: String
    /// 색칠용 도안 이미지(다운샘플 보관). 색칠 캔버스의 베이스.
    @Attribute(.externalStorage) var imageData: Data
    /// 그리드 표시용 작은 썸네일.
    @Attribute(.externalStorage) var thumbnailData: Data
    var createdAt: Date

    /// 이 도안에 달린 작업물들 — 도안 삭제 시 함께 삭제(cascade).
    @Relationship(deleteRule: .cascade, inverse: \Artwork.template)
    var artworks: [Artwork] = []

    init(name: String, imageData: Data, thumbnailData: Data, createdAt: Date = .now) {
        self.name = name
        self.imageData = imageData
        self.thumbnailData = thumbnailData
        self.createdAt = createdAt
    }
}
