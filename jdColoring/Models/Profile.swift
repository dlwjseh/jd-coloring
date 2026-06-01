import Foundation
import SwiftData

/// 사용자 프로필 (SwiftData 영속 모델)
@Model
final class Profile {
    var name: String
    /// 다운샘플링된 썸네일 JPEG. 외부 파일로 저장해 DB를 가볍게 유지.
    @Attribute(.externalStorage) var imageData: Data?
    var colorIndex: Int
    var createdAt: Date

    init(name: String, imageData: Data? = nil, colorIndex: Int, createdAt: Date = .now) {
        self.name = name
        self.imageData = imageData
        self.colorIndex = colorIndex
        self.createdAt = createdAt
    }
}
