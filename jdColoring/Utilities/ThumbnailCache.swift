import SwiftUI
import UIKit

typealias PlatformImage = UIImage

/// 썸네일 Data를 **디코딩한 결과**를 캐시한다.
///
/// 검수 #1 대응: `Image(data:)`는 호출(=렌더/애니메이션 프레임)마다 원본을 재디코딩한다.
/// 같은 Data는 한 번만 디코딩하고 결과를 NSCache에 보관해 A1/A2 애니메이션 중 반복 디코딩을 제거한다.
/// Data 내용이 바뀌면(사진 수정) 내용이 달라져 자동으로 새로 디코딩된다.
///
/// 키: NSData(바이트 동등 비교 + 앞부분 샘플링 해시). NSNumber(hashValue)는 해시 충돌 시
/// 다른 이미지를 반환할 수 있으므로 교체.
/// 메모리: totalCostLimit 50MB + cost = data.count 로 디코딩 비트맵 누적을 제한한다.
enum ThumbnailCache {
    private static let cache: NSCache<NSData, UIImage> = {
        let c = NSCache<NSData, UIImage>()
        c.totalCostLimit = 50 * 1024 * 1024   // 50 MB
        return c
    }()

    static func image(for data: Data) -> Image? {
        let key = data as NSData
        if let cached = cache.object(forKey: key) {
            return Image(uiImage: cached)
        }
        guard let decoded = UIImage(data: data) else { return nil }
        cache.setObject(decoded, forKey: key, cost: data.count)
        return Image(uiImage: decoded)
    }
}
