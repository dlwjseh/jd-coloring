import SwiftUI

/// 캔버스 엔진에 대한 명령 핸들(부모 → 엔진). 화면 이탈 시 즉시 저장(flush),
/// 색칠 초기화(reset)를 부모가 **동기로** 트리거하기 위해 사용한다.
/// ⚠️ flush·reset 클로저는 DrawingCanvas.onAppear에서 채워진다.
/// 캔버스가 화면에 나타난 뒤에만 호출해야 하며, 그 이전엔 no-op이다.
final class CanvasSaver {
    var flush: () -> Void = {}
    var reset: () -> Void = {}
}

/// 채색 표면. iPad·Mac 공용 — 라인아트를 칸으로 분할해 브러시가 검은 선을
/// 넘지 못하게 가두는 래스터 엔진(`RegionPaintEngine`)을 SwiftUI `Canvas`로 표시한다.
struct DrawingCanvas: View {
    let initialData: Data?
    let lineart: PlatformImage?
    var color: Color
    var lineWidth: CGFloat
    var isEraser: Bool
    var tool: BrushTool
    let saver: CanvasSaver
    var onPersist: (_ progressData: Data, _ thumbnail: Data) -> Void

    @State private var engine = RegionPaintEngine()

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                if let cg = engine.displayImage {
                    ctx.draw(Image(decorative: cg, scale: 1),
                             in: CGRect(origin: .zero, size: size))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in engine.strokeChanged(at: v.location, viewSize: geo.size) }
                    .onEnded { _ in engine.strokeEnded() }
            )
            .onAppear {
                engine.color = color
                engine.brushPointWidth = lineWidth
                engine.isEraser = isEraser
                engine.tool = tool
                engine.configure(lineart: lineart, initialData: initialData, onPersist: onPersist)
                saver.flush = { engine.flush() }
                saver.reset = { engine.clear() }
            }
            .onDisappear {
                // CADisplayLink는 메인 스레드에서만 안전하게 invalidate 가능.
                // deinit이 어느 스레드에서 불릴지 보장이 없어 여기서 명시 정리.
                engine.stopDisplayLink()
            }
            // 부모가 라인아트를 늦게 디코딩하면(onAppear 시 nil) 준비가 안 되므로,
            // 라인아트가 채워지는 시점에 다시 구성한다.
            .onChange(of: lineart == nil) { _, isNil in
                if !isNil {
                    engine.configure(lineart: lineart, initialData: initialData, onPersist: onPersist)
                }
            }
            .onChange(of: color) { _, c in engine.color = c }
            .onChange(of: lineWidth) { _, w in engine.brushPointWidth = w }
            .onChange(of: isEraser) { _, e in engine.isEraser = e }
            .onChange(of: tool) { _, t in engine.tool = t }
        }
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
        // 배경이 흰색으로 항상 불투명 → 알파 채널 제거. JPEG 저장 시 ImageIO 경고를
        // 막고, 디코딩 시 메모리가 2배로 드는 것을 피한다.
        renderer.isOpaque = true
        return renderer.uiImage?.jpegData(compressionQuality: 0.85)
    }
}

extension Image {
    init?(platform image: PlatformImage) {
        self = Image(uiImage: image)
    }
}
