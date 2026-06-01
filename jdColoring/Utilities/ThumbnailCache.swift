import SwiftUI
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

/// 썸네일 Data를 **디코딩한 결과**를 캐시한다.
///
/// 검수 #1 대응: `Image(data:)`는 호출(=렌더/애니메이션 프레임)마다 원본을 재디코딩한다.
/// 같은 Data는 한 번만 디코딩하고 결과를 NSCache에 보관해 A1/A2 애니메이션 중 반복 디코딩을 제거한다.
/// Data 내용이 바뀌면(사진 수정) 해시가 달라져 자동으로 새로 디코딩된다.
enum ThumbnailCache {
    private static let cache = NSCache<NSNumber, PlatformImage>()

    static func image(for data: Data) -> Image? {
        let key = NSNumber(value: data.hashValue)
        if let cached = cache.object(forKey: key) {
            return swiftUIImage(cached)
        }
        guard let decoded = PlatformImage(data: data) else { return nil }
        cache.setObject(decoded, forKey: key)
        return swiftUIImage(decoded)
    }

    private static func swiftUIImage(_ image: PlatformImage) -> Image {
        #if canImport(UIKit)
        Image(uiImage: image)
        #else
        Image(nsImage: image)
        #endif
    }
}
