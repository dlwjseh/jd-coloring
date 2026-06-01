import SwiftUI
#if os(iOS)
import PencilKit
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 화면 이탈 시 즉시 저장(flush)을 트리거하기 위한 핸들.
final class CanvasSaver {
    var flush: () -> Void = {}
}

/// macOS 폴백 캔버스의 스트로크(벡터). progressData에 JSON으로 직렬화.
struct BrushStroke: Codable {
    var pts: [CGPoint]
    var r: Double, g: Double, b: Double
    var w: Double
    var erase: Bool
}

/// 플랫폼 드로잉 표면. iOS=PencilKit, macOS=Canvas 브러시 폴백.
/// 같은 인터페이스: 초기 데이터 / 라인아트(썸네일 합성용) / 도구 / 저장 콜백.
struct DrawingCanvas: View {
    let initialData: Data?
    let lineart: PlatformImage?
    var color: Color
    var lineWidth: CGFloat
    var isEraser: Bool
    let saver: CanvasSaver
    var onPersist: (_ progressData: Data, _ thumbnail: Data) -> Void

    var body: some View {
        #if os(iOS)
        PencilCanvasRep(initialData: initialData, lineart: lineart,
                        color: color, lineWidth: lineWidth, isEraser: isEraser,
                        saver: saver, onPersist: onPersist)
        #else
        FallbackBrushCanvas(initialData: initialData, lineart: lineart,
                            color: color, lineWidth: lineWidth, isEraser: isEraser,
                            saver: saver, onPersist: onPersist)
        #endif
    }
}

// MARK: - 썸네일 합성 (공용)

@MainActor
enum CanvasThumb {
    /// 흰 배경 + 색칠(base) + 라인아트(multiply) 를 합성해 JPEG 썸네일 Data 생성.
    static func render<Base: View>(base: Base, lineart: PlatformImage?,
                                   aspect: CGSize, maxPixel: CGFloat = 480) -> Data? {
        let longest = max(aspect.width, aspect.height)
        let scale = longest > 0 ? min(1, maxPixel / longest) : 1
        let w = max(1, aspect.width * scale), h = max(1, aspect.height * scale)

        let content = ZStack {
            Color.white
            base
            if let lineart, let img = Image(platform: lineart) {
                img.resizable().blendMode(.multiply)
            }
        }
        .frame(width: w, height: h)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        #if os(iOS)
        return renderer.uiImage?.jpegData(compressionQuality: 0.85)
        #else
        guard let ns = renderer.nsImage, let tiff = ns.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        #endif
    }
}

extension Image {
    /// PlatformImage → SwiftUI Image
    init?(platform image: PlatformImage) {
        #if os(iOS)
        self = Image(uiImage: image)
        #elseif os(macOS)
        self = Image(nsImage: image)
        #else
        return nil
        #endif
    }
}

// MARK: - iOS: PencilKit

#if os(iOS)
struct PencilCanvasRep: UIViewRepresentable {
    let initialData: Data?
    let lineart: PlatformImage?
    var color: Color
    var lineWidth: CGFloat
    var isEraser: Bool
    let saver: CanvasSaver
    var onPersist: (Data, Data) -> Void

    func makeUIView(context: Context) -> PKCanvasView {
        let cv = PKCanvasView()
        cv.backgroundColor = .clear
        cv.isOpaque = false
        cv.drawingPolicy = .anyInput   // 펜 + 손가락 모두 허용
        if let d = initialData, let drawing = try? PKDrawing(data: d) {
            cv.drawing = drawing
        }
        cv.delegate = context.coordinator
        context.coordinator.canvas = cv
        context.coordinator.lineart = lineart
        context.coordinator.onPersist = onPersist
        saver.flush = { context.coordinator.save() }
        apply(cv)
        return cv
    }

    func updateUIView(_ cv: PKCanvasView, context: Context) {
        context.coordinator.lineart = lineart
        context.coordinator.onPersist = onPersist
        apply(cv)
    }

    private func apply(_ cv: PKCanvasView) {
        cv.tool = isEraser ? PKEraserTool(.bitmap)
                           : PKInkingTool(.pen, color: UIColor(color), width: lineWidth)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        weak var canvas: PKCanvasView?
        var lineart: PlatformImage?
        var onPersist: ((Data, Data) -> Void)?
        private var pending: DispatchWorkItem?

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.save() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
        }

        @MainActor func save() {
            pending?.cancel()
            guard let cv = canvas, let onPersist else { return }
            let bounds = cv.bounds
            guard bounds.width > 1, bounds.height > 1, !cv.drawing.strokes.isEmpty else { return }
            let data = cv.drawing.dataRepresentation()
            let drawImg = cv.drawing.image(from: bounds, scale: 1)
            let base = Image(uiImage: drawImg).resizable()
            guard let thumb = CanvasThumb.render(base: base, lineart: lineart, aspect: bounds.size) else { return }
            onPersist(data, thumb)
        }
    }
}
#endif

// MARK: - macOS: Canvas 브러시 폴백 (검증·Mac 사용용)

#if os(macOS)
struct FallbackBrushCanvas: View {
    let initialData: Data?
    let lineart: PlatformImage?
    var color: Color
    var lineWidth: CGFloat
    var isEraser: Bool
    let saver: CanvasSaver
    var onPersist: (Data, Data) -> Void

    @State private var strokes: [BrushStroke] = []
    @State private var current: [CGPoint] = []
    @State private var canvasSize: CGSize = .zero
    @State private var pending: DispatchWorkItem?

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                draw(strokes, in: &ctx)
                if !current.isEmpty {
                    draw([stroke(from: current)], in: &ctx)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in current.append(v.location) }
                    .onEnded { _ in
                        if !current.isEmpty { strokes.append(stroke(from: current)); current = [] }
                        scheduleSave()
                    }
            )
            .onAppear {
                canvasSize = geo.size
                if let d = initialData, let s = try? JSONDecoder().decode([BrushStroke].self, from: d) {
                    strokes = s
                }
                saver.flush = { save() }
            }
            .onChange(of: geo.size) { _, s in canvasSize = s }
        }
    }

    private func stroke(from pts: [CGPoint]) -> BrushStroke {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return BrushStroke(pts: pts,
                           r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent),
                           w: Double(lineWidth), erase: isEraser)
    }

    private func draw(_ list: [BrushStroke], in ctx: inout GraphicsContext) {
        for s in list {
            guard s.pts.count > 0 else { continue }
            var path = Path()
            path.addLines(s.pts)
            if s.pts.count == 1, let p = s.pts.first {
                path.addEllipse(in: CGRect(x: p.x - s.w/2, y: p.y - s.w/2, width: s.w, height: s.w))
            }
            let paint = s.erase ? Color.white : Color(.sRGB, red: s.r, green: s.g, blue: s.b)
            ctx.stroke(path, with: .color(paint),
                       style: StrokeStyle(lineWidth: s.w, lineCap: .round, lineJoin: .round))
        }
    }

    private func scheduleSave() {
        pending?.cancel()
        let work = DispatchWorkItem { save() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    @MainActor private func save() {
        pending?.cancel()
        guard !strokes.isEmpty, canvasSize.width > 1, canvasSize.height > 1 else { return }
        guard let data = try? JSONEncoder().encode(strokes) else { return }
        let snapshot = strokes
        let base = Canvas { ctx, _ in self.draw(snapshot, in: &ctx) }
        guard let thumb = CanvasThumb.render(base: base, lineart: lineart, aspect: canvasSize) else { return }
        onPersist(data, thumb)
    }
}
#endif
