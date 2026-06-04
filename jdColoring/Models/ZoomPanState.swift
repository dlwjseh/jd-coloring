import CoreGraphics

/// 캔버스 줌/팬 상태 (1× ~ 3×).
/// PenOnlyGestureView 제스처 콜백이 이 값을 업데이트하고,
/// ColoringCanvasView가 .scaleEffect + .offset 으로 CanvasArea에 적용한다.
struct ZoomPanState: Equatable {
    var scale: CGFloat = 1.0
    var offset: CGSize = .zero

    static let minScale: CGFloat = 1.0
    static let maxScale: CGFloat = 3.0

    var isZoomed: Bool { scale > 1.001 }

    /// 핀치 배율 누적. 경계에서 부드럽게 클램핑.
    mutating func applyPinchDelta(_ delta: CGFloat, canvasSize: CGSize) {
        scale = min(Self.maxScale, max(Self.minScale, scale * delta))
        clampOffset(canvasSize: canvasSize)
    }

    /// 패닝 델타(스크린 좌표계 pt) 적용. 도안 가장자리가 뷰 밖으로 완전히 벗어나지 않게 클램핑.
    mutating func applyPanDelta(_ delta: CGSize, canvasSize: CGSize) {
        offset.width  += delta.width
        offset.height += delta.height
        clampOffset(canvasSize: canvasSize)
    }

    /// offset을 현재 scale / canvasSize 기준으로 클램핑.
    mutating func clampOffset(canvasSize: CGSize) {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        let maxX = canvasSize.width  * (scale - 1) / 2
        let maxY = canvasSize.height * (scale - 1) / 2
        offset.width  = min(maxX,  max(-maxX,  offset.width))
        offset.height = min(maxY, max(-maxY, offset.height))
    }

    /// 1× 원위치. 더블탭 리셋 및 1× 도달 시 스프링 복귀용.
    mutating func reset() { scale = 1.0; offset = .zero }
}
