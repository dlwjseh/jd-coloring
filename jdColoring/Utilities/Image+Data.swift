import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Image {
    /// 플랫폼에 맞춰 Data로부터 Image 생성 (iPad/Mac 공용)
    init?(data: Data) {
        #if canImport(UIKit)
        guard let img = UIImage(data: data) else { return nil }
        self = Image(uiImage: img)
        #elseif canImport(AppKit)
        guard let img = NSImage(data: data) else { return nil }
        self = Image(nsImage: img)
        #else
        return nil
        #endif
    }
}
