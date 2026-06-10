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

    /// 같은 앨범(또는 미분류) 안에서의 **수동 정렬 순서**(오름차순). 사용자가 갤러리 '정렬' 모드에서
    /// 끌어 바꾼 순서를 보관한다 — 기기 전체 공용, 앨범별 독립. (기획/디자인 §도안 정렬, 2026-06-09)
    /// 갤러리는 `sortOrder` 오름차순 + 동률 시 `createdAt` 으로 표시. 새 도안·앨범 이동은 맨 끝(max+1).
    /// 경량 마이그레이션: 기존 행 기본값 0 → `SortOrderBackfill` 가 앨범 그룹별 createdAt 순으로 1회 백필.
    var sortOrder: Int = 0

    /// 시스템(앱 기본 제공) 도안 여부. true = '한글' 자음·모음 같은 보호 도안 → 삭제·이름변경·
    /// 앨범이동 불가(롱프레스는 '내 색칠 초기화'만). 색칠·작업물은 일반 도안과 동일.
    /// (기획 §기본 제공 한글 앨범, 2026-06-09) 경량 마이그레이션: 기존 행은 기본값 false.
    var isSystem: Bool = false

    /// 소속 앨범(단일). `nil` = 미분류. 인버스는 `Album.templates`(앨범 삭제 시 nullify → 미분류).
    var album: Album?

    /// 이 도안에 달린 작업물들 — 도안 삭제 시 함께 삭제(cascade).
    @Relationship(deleteRule: .cascade, inverse: \Artwork.template)
    var artworks: [Artwork] = []

    init(name: String, imageData: Data, thumbnailData: Data, album: Album? = nil, createdAt: Date = .now, isSystem: Bool = false, sortOrder: Int = 0) {
        self.name = name
        self.imageData = imageData
        self.thumbnailData = thumbnailData
        self.album = album
        self.createdAt = createdAt
        self.isSystem = isSystem
        self.sortOrder = sortOrder
    }
}
