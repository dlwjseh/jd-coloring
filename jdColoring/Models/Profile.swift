import Foundation
import SwiftData

/// 사용자 프로필 (SwiftData 영속 모델)
@Model
final class Profile {
    /// 기기 간(iPad↔iPhone) 안정 식별자. 부모 제어판의 프로필 지정 타이머 매칭에 사용.
    /// SwiftData `persistentModelID`는 기기 로컬·전송 부적합이라 별도 UUID를 둔다.
    /// (새 속성 + 기본값 → 경량 마이그레이션. 기존 행은 마이그레이션 시 UUID 부여.)
    var uuid: UUID = UUID()
    var name: String
    /// 다운샘플링된 썸네일 JPEG. 외부 파일로 저장해 DB를 가볍게 유지.
    @Attribute(.externalStorage) var imageData: Data?
    var colorIndex: Int
    var createdAt: Date

    init(name: String, imageData: Data? = nil, colorIndex: Int, createdAt: Date = .now, uuid: UUID = UUID()) {
        self.uuid = uuid
        self.name = name
        self.imageData = imageData
        self.colorIndex = colorIndex
        self.createdAt = createdAt
    }
}
