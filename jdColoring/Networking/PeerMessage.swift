import Foundation

/// iPhone ↔ iPad 간 주고받는 메시지 타입.
enum PeerMessage: Codable {
    case timerStart(endDate: Date)
    case timerCancel
}
