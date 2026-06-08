import Foundation

/// iPad가 iPhone에 보내는 프로필 요약 — 전송용 경량 모델.
/// iPhone은 SwiftData에 iPad의 프로필을 갖고 있지 않으므로, 타이머 대상 선택에 필요한
/// 최소 정보(식별자·이름·색·썸네일)만 받아 화면에 렌더한다.
struct ProfileSummary: Codable, Identifiable, Hashable {
    let id: UUID         // Profile.uuid (기기 간 안정 식별자)
    let name: String
    let colorIndex: Int  // 링/틴트 색 (Theme.ring / Theme.tint)
    let thumbnail: Data? // 이미 다운샘플된 프로필 썸네일(Profile.imageData)
}

/// iPhone ↔ iPad 간 주고받는 메시지 타입.
enum PeerMessage: Codable {
    /// iPhone → iPad: 타이머 시작. `targetProfileId` = 지정 아이(Profile.uuid).
    case timerStart(endDate: Date, targetProfileId: UUID)
    /// iPhone → iPad: 타이머 취소.
    case timerCancel
    /// iPad → iPhone: 현재 프로필 목록(연결 직후 + 추가/수정/삭제 시 갱신).
    case profileList([ProfileSummary])
}
