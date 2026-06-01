import SwiftUI

/// 디자인 스펙(docs/02-디자인/design-spec.md)의 컬러·타이포 토큰
enum Theme {
    // 배경 (거의 화이트, 따뜻한 기 살짝)
    static let bgTop = Color(hex: 0xFFFFFF)
    static let bgBottom = Color(hex: 0xFFF4EC)
    static let bgGradient = LinearGradient(colors: [bgTop, bgBottom],
                                           startPoint: .top, endPoint: .bottom)

    // 텍스트 / 표면
    static let ink = Color(hex: 0x3B3A4E)
    static let subText = Color(hex: 0x9A8F86)
    static let faintText = Color(hex: 0xB6A89B)
    static let card = Color.white
    static let cardBorder = Color(hex: 0xEBDFD2)

    // 포인트
    static let coral = Color(hex: 0xFF7A59)   // CTA
    static let danger = Color(hex: 0xFF5A5F)  // 삭제

    // 부드러운 그림자
    static let softShadow = Color(hex: 0xC9A88C, alpha: 0.35)

    /// 프로필 링 색 — 추가 순서대로 6색 순환
    static let ringColors: [Color] = [
        Color(hex: 0xFF7A59), // 코랄
        Color(hex: 0x8A6CFF), // 퍼플
        Color(hex: 0x36C5C0), // 티일
        Color(hex: 0xFFC740), // 옐로
        Color(hex: 0xFF6FAF), // 핑크
        Color(hex: 0x5FD08A)  // 그린
    ]
    /// 프로필 옅은 채움 틴트 (ringColors와 동일 순서)
    static let ringTints: [Color] = [
        Color(hex: 0xFFE4DB),
        Color(hex: 0xECE6FF),
        Color(hex: 0xDBF6F5),
        Color(hex: 0xFFF1CC),
        Color(hex: 0xFFE1EF),
        Color(hex: 0xE0F6E9)
    ]

    static func ring(_ index: Int) -> Color { ringColors[((index % ringColors.count) + ringColors.count) % ringColors.count] }
    static func tint(_ index: Int) -> Color { ringTints[((index % ringTints.count) + ringTints.count) % ringTints.count] }

    /// SF Pro Rounded 기반 폰트
    static func rounded(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}
