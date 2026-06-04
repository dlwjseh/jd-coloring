import SwiftUI

/// 캔버스 엔진에 대한 명령 핸들(부모 → 엔진). 화면 이탈 시 즉시 저장(flush),
/// 색칠 초기화(reset)를 부모가 **동기로** 트리거하기 위해 사용한다.
/// ⚠️ flush·reset 클로저는 DrawingCanvas.onAppear에서 채워진다.
/// 캔버스가 화면에 나타난 뒤에만 호출해야 하며, 그 이전엔 no-op이다.
final class CanvasSaver {
    var flush: () -> Void = {}
    /// 저장 완료 후 completion 호출 (엔진 미준비 시 즉시 호출).
    var flushThen: (_ completion: @escaping () -> Void) -> Void = { $0() }
    var reset: () -> Void = {}
}

/// 채색 표면. iPad 전용 — 라인아트를 칸으로 분할해 브러시가 검은 선을
/// 넘지 못하게 가두는 래스터 엔진(`RegionPaintEngine`)을 SwiftUI `Canvas`로 표시한다.
struct DrawingCanvas: View {
    let initialData: Data?
    let lineart: PlatformImage?
    var color: Color
    var lineWidth: CGFloat
    var isEraser: Bool
    var tool: BrushTool
    /// true = Apple Pencil 입력만 색칠 처리, 손가락 터치는 무시.
    var penOnly: Bool
    let saver: CanvasSaver
    var onPersist: (_ progressData: Data, _ thumbnail: Data) -> Void

    // ── 줌/팬 이벤트 콜백 ──────────────────────────────────────────────────
    /// 핀치 배율 델타(1.0 기준). ended=true 이면 제스처 완료.
    var onPinch: (_ delta: CGFloat, _ ended: Bool) -> Void = { _, _ in }
    /// 패닝 델타(window 좌표계 pt). ended=true 이면 제스처 완료.
    var onPan: (_ delta: CGSize, _ ended: Bool) -> Void = { _, _ in }
    /// 두 손가락 더블탭 → 줌 리셋.
    var onZoomReset: () -> Void = {}

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
            // 단일 터치 색칠 + 두 손가락 줌/팬/더블탭을 하나의 UIView에서 처리.
            // UIKit이 scaleEffect 역변환을 적용해 색칠 좌표는 자동으로 canvas 로컬 공간으로 들어옴.
            .overlay {
                PenOnlyGestureView(
                    penOnly: penOnly,
                    onChanged: { loc in engine.strokeChanged(at: loc, viewSize: geo.size) },
                    onEnded:   { engine.strokeEnded() },
                    onPinch:   onPinch,
                    onPan:     onPan,
                    onZoomReset: onZoomReset
                )
            }
            .onAppear {
                engine.color = color
                engine.brushPointWidth = lineWidth
                engine.isEraser = isEraser
                engine.tool = tool
                engine.configure(lineart: lineart, initialData: initialData, onPersist: onPersist)
                saver.flush = { engine.flush() }
                saver.flushThen = { engine.flushThen($0) }
                saver.reset = { engine.clear() }
            }
            .onDisappear {
                engine.stopDisplayLink()
            }
            .onChange(of: lineart == nil) { _, isNil in
                if !isNil {
                    engine.configure(lineart: lineart, initialData: initialData, onPersist: onPersist)
                }
            }
            .onChange(of: color)     { _, c in engine.color = c }
            .onChange(of: lineWidth) { _, w in engine.brushPointWidth = w }
            .onChange(of: isEraser)  { _, e in engine.isEraser = e }
            .onChange(of: tool)      { _, t in engine.tool = t }
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
        renderer.isOpaque = true
        return renderer.uiImage?.jpegData(compressionQuality: 0.85)
    }
}

extension Image {
    init?(platform image: PlatformImage) {
        self = Image(uiImage: image)
    }
}

// MARK: - PenOnlyGestureView

/// 색칠 캔버스 위에 얹는 투명 터치 레이어.
///
/// 단일 터치(또는 Pencil):
///   - penOnly = true 이면 .pencil 타입만 색칠, 손가락 터치는 무시.
///   - UI 버튼(레일·팔레트 등)은 이 뷰 범위 밖이라 영향 없음.
///
/// 두 손가락 제스처:
///   - UIPinchGestureRecognizer  → onPinch(delta, ended)
///   - UIPanGestureRecognizer(2) → onPan(screenDelta, ended)
///   - UITapGestureRecognizer(2탭, 2터치) → onZoomReset()
///
/// isMultipleTouchEnabled = false 유지:
///   UIKit 규약상 제스처 인식기는 isMultipleTouchEnabled 에 구애받지 않아
///   2-finger 제스처 인식기가 정상 동작하며, touchesBegan 계열은 단일 터치만 받아
///   안전하게 색칠에 집중할 수 있다.
struct PenOnlyGestureView: UIViewRepresentable {
    var penOnly: Bool
    var onChanged: (CGPoint) -> Void
    var onEnded: () -> Void
    var onPinch: (CGFloat, Bool) -> Void
    var onPan: (CGSize, Bool) -> Void
    var onZoomReset: () -> Void

    func makeUIView(context: Context) -> Inner {
        let v = Inner()
        v.backgroundColor = .clear
        v.isMultipleTouchEnabled = false   // 색칠 touchesBegan 단일 터치 보장 (제스처 인식기는 무관)
        v.apply(penOnly: penOnly,
                onChanged: onChanged, onEnded: onEnded,
                onPinch: onPinch, onPan: onPan, onZoomReset: onZoomReset)
        return v
    }

    func updateUIView(_ v: Inner, context: Context) {
        v.apply(penOnly: penOnly,
                onChanged: onChanged, onEnded: onEnded,
                onPinch: onPinch, onPan: onPan, onZoomReset: onZoomReset)
    }

    // MARK: Inner UIView

    final class Inner: UIView, UIGestureRecognizerDelegate {

        // ── 색칠 ──────────────────────────────────────────────────────────
        private var penOnly = true
        private var onChanged: ((CGPoint) -> Void)?
        private var onEnded: (() -> Void)?
        /// 진행 중인 터치 추적 — touchesBegan에서 수락한 터치만 이후 이벤트에서 처리
        private weak var activeTouch: UITouch?

        // ── 줌/팬 ─────────────────────────────────────────────────────────
        private var onPinch: ((CGFloat, Bool) -> Void)?
        private var onPan: ((CGSize, Bool) -> Void)?
        private var onZoomReset: (() -> Void)?

        private var pinchRecognizer: UIPinchGestureRecognizer!
        private var panRecognizer:   UIPanGestureRecognizer!
        private var tapRecognizer:   UITapGestureRecognizer!

        override init(frame: CGRect) {
            super.init(frame: frame)
            setupGestureRecognizers()
        }
        required init?(coder: NSCoder) { fatalError() }

        func apply(penOnly: Bool,
                   onChanged: @escaping (CGPoint) -> Void,
                   onEnded: @escaping () -> Void,
                   onPinch: @escaping (CGFloat, Bool) -> Void,
                   onPan: @escaping (CGSize, Bool) -> Void,
                   onZoomReset: @escaping () -> Void) {
            self.penOnly = penOnly
            self.onChanged = onChanged
            self.onEnded = onEnded
            self.onPinch = onPinch
            self.onPan = onPan
            self.onZoomReset = onZoomReset
        }

        // MARK: 제스처 인식기 설정

        private func setupGestureRecognizers() {
            // 핀치 줌
            pinchRecognizer = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
            pinchRecognizer.delegate = self
            addGestureRecognizer(pinchRecognizer)

            // 두 손가락 패닝 (min 2, max 2 → 단일 터치 드래그와 겹치지 않음)
            panRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
            panRecognizer.minimumNumberOfTouches = 2
            panRecognizer.maximumNumberOfTouches = 2
            panRecognizer.delegate = self
            addGestureRecognizer(panRecognizer)

            // 두 손가락 더블탭 리셋
            tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
            tapRecognizer.numberOfTapsRequired    = 2
            tapRecognizer.numberOfTouchesRequired = 2
            tapRecognizer.delegate = self
            addGestureRecognizer(tapRecognizer)

            // 패닝이 더블탭보다 우선 인식되지 않도록: 더블탭이 실패해야 패닝 인정
            panRecognizer.require(toFail: tapRecognizer)
        }

        // MARK: UIGestureRecognizerDelegate

        /// 핀치·패닝·더블탭은 서로 동시 인식 허용.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool {
            let zoomSet: Set<UIGestureRecognizer> = [pinchRecognizer, panRecognizer, tapRecognizer]
            return zoomSet.contains(g) && zoomSet.contains(o)
        }

        // MARK: 핀치 핸들러

        @objc private func handlePinch(_ r: UIPinchGestureRecognizer) {
            switch r.state {
            case .began:
                cancelActiveDrawStroke()
            case .changed:
                // r.scale 은 누적값 → 델타를 얻기 위해 매 프레임 1로 리셋
                let delta = r.scale
                r.scale = 1.0
                onPinch?(delta, false)
            case .ended:
                onPinch?(1.0, true)
            case .cancelled, .failed:
                onPinch?(1.0, true)
            default: break
            }
        }

        // MARK: 패닝 핸들러

        @objc private func handlePan(_ r: UIPanGestureRecognizer) {
            guard r.numberOfTouches == 2 else { return }
            // window 좌표계로 델타를 읽어야 한다.
            // PenOnlyGestureView.Inner 는 scaleEffect 로 변환된 CanvasArea 안에 있어
            // 뷰 로컬 좌표계가 이미 역변환된 캔버스 공간이다. 이 공간에서 읽으면
            // delta * currentScale 을 적용해야 screen-pt 와 일치하게 된다.
            // window 좌표계는 항상 screen-pt 와 일치하므로 변환 없이 offset 에 직접 더할 수 있다.
            guard let win = window else { return }
            switch r.state {
            case .began:
                cancelActiveDrawStroke()
                r.setTranslation(.zero, in: win)
            case .changed:
                let t = r.translation(in: win)
                onPan?(CGSize(width: t.x, height: t.y), false)
                r.setTranslation(.zero, in: win)
            case .ended:
                let t = r.translation(in: win)
                if t != .zero { onPan?(CGSize(width: t.x, height: t.y), false) }
                onPan?(.zero, true)
            case .cancelled, .failed:
                onPan?(.zero, true)
            default: break
            }
        }

        // MARK: 더블탭 핸들러

        @objc private func handleDoubleTap(_ r: UITapGestureRecognizer) {
            cancelActiveDrawStroke()
            onZoomReset?()
        }

        // MARK: 색칠 스트로크 취소 (줌/팬 제스처 시작 시)

        private func cancelActiveDrawStroke() {
            guard activeTouch != nil else { return }
            activeTouch = nil
            onEnded?()
        }

        // MARK: 색칠 터치 핸들러

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = touches.first else { return }
            // penOnly ON 이면 Pencil 타입 아닌 터치는 버린다
            guard !penOnly || t.type == .pencil else { return }
            // 줌/팬 제스처가 이미 인식 중이면 드로잉 시작 금지
            guard !isZoomGestureActive else { return }
            // 이전 스트로크가 ended/cancelled 없이 남아있으면 먼저 정리
            if activeTouch != nil { onEnded?() }
            activeTouch = t
            onChanged?(t.location(in: self))
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = touches.first(where: { $0 === activeTouch }) else { return }
            // MAJOR-2: Apple Pencil 120Hz 입력에서 UIKit이 묶어 전달하는 중간 샘플을
            // 모두 처리해 고속 스트로크의 끊김·각짐을 방지한다.
            let samples = event?.coalescedTouches(for: t) ?? [t]
            for sample in samples {
                onChanged?(sample.location(in: self))
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard touches.contains(where: { $0 === activeTouch }) else { return }
            activeTouch = nil
            onEnded?()
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            activeTouch = nil
            onEnded?()
        }

        // MARK: 헬퍼

        private var isZoomGestureActive: Bool {
            let active: [UIGestureRecognizer.State] = [.began, .changed]
            return active.contains(pinchRecognizer.state) ||
                   active.contains(panRecognizer.state)
        }
    }
}
