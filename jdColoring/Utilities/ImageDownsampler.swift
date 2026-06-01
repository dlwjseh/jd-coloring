import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// 갤러리 원본을 썸네일 크기로 다운샘플링해 JPEG Data로 변환한다.
///
/// 검수 #2 대응: 원본 고해상도(예: 12MP) 이미지를 그대로 디코딩·보관하면 메모리가 폭증한다.
/// `CGImageSource` 썸네일 API로 디코딩 단계에서 축소하며, **반드시 백그라운드에서 호출**한다.
enum ImageDownsampler {
    static func thumbnailData(from data: Data,
                             maxPixel: CGFloat = 512,
                             compression: CGFloat = 0.8) -> Data? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // EXIF 회전 반영
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }

        let output = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let destOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: compression]
        CGImageDestinationAddImage(dest, cgThumb, destOptions as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return output as Data
    }
}
