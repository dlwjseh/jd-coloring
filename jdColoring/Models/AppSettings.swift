import Observation
import Foundation

/// 기기 전역 앱 설정. UserDefaults에 영구 저장, 모든 프로필에 동일 적용.
/// @Observable이므로 @Environment(AppSettings.self)로 주입 후 observe 가능.
@Observable
final class AppSettings {
    var penOnly: Bool {
        didSet { UserDefaults.standard.set(penOnly, forKey: "penOnly") }
    }

    init() {
        // 최초 설치 시 기본값 true (펜 전용 ON)
        UserDefaults.standard.register(defaults: ["penOnly": true])
        penOnly = UserDefaults.standard.bool(forKey: "penOnly")
    }
}
