import Foundation
import SwiftData

/// 색칠 작업물 — (프로필 × 도안) 당 하나. 프로필별 진행 상태를 보관한다.
///
/// 실제 색칠 데이터(스트로크·채움 등)의 형식은 색칠 캔버스 화면에서 확정한다.
/// 이 화면(갤러리)은 `progressThumbnail` 만 그리드 셀에 표시한다.
@Model
final class Artwork {
    /// 어떤 도안인지 (Template.artworks 의 inverse).
    var template: Template?
    /// 누구의 작업물인지.
    var profile: Profile?
    /// 그리드 표시용 진행 썸네일. nil 이면 '미착수'로 빈 도안을 보여준다.
    @Attribute(.externalStorage) var progressThumbnail: Data?
    /// 색칠 진행 데이터. RegionPaintEngine 색칠 버퍼의 PNG.
    @Attribute(.externalStorage) var progressData: Data?
    var updatedAt: Date

    init(template: Template?, profile: Profile?,
         progressThumbnail: Data? = nil, progressData: Data? = nil, updatedAt: Date = .now) {
        self.template = template
        self.profile = profile
        self.progressThumbnail = progressThumbnail
        self.progressData = progressData
        self.updatedAt = updatedAt
    }
}
