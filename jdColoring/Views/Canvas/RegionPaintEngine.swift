import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// 라인아트를 "칸(영역)"으로 분할하고, 브러시가 시작한 칸 안에서만 색이 칠해지도록
/// 가두는 래스터 채색 엔진.
///
/// 동작:
/// 1. 라인아트를 작업 해상도로 줄여 흰 배경에 합성 → 어두운 픽셀을 경계(barrier)로 판정.
/// 2. 비경계 픽셀을 union-find로 연결요소(칸)별 라벨링(`labels`). 경계 = 0.
/// 3. 브러시 다운 지점의 라벨을 잠그고(`lockedLabel`), 스트로크 내내 그 라벨 픽셀만 칠한다.
///    경계 픽셀은 라벨 0이라 절대 칠해지지 않으므로 검은 선은 깨끗하게 남는다.
@Observable
final class RegionPaintEngine {

    // 화면에 그릴 현재 색칠 결과 (Canvas가 이 값을 읽어 다시 그린다)
    private(set) var displayImage: CGImage?

    // MARK: 비공개 상태
    private var width = 0
    private var height = 0
    private var labels: [Int32] = []          // 픽셀별 칸 라벨(0 = 경계/없음)
    private var ready = false                  // 라벨링 완료 여부

    private var paintCtx: CGContext?           // RGBA8 색칠 버퍼(픽셀 직접 접근)
    private var pixels: UnsafeMutablePointer<UInt8>?

    // 현재 도구 상태(뷰에서 주입)
    var color: Color = .black {
        didSet { brushRGB = rgbComponents(of: color) }   // L-2: 스탬프마다 변환 않도록 캐시
    }
    var brushPointWidth: CGFloat = 16          // 뷰 좌표(point) 기준 굵기
    var isEraser = false
    var tool: BrushTool = .marker
    private var brushRGB: (UInt8, UInt8, UInt8) = (0, 0, 0)

    // 색연필(§18): 반투명 쌓임 + 종이결.
    // 한 획당 올리는 불투명도(0.4*255). 같은 칸을 덧칠하면 source-over로 진해진다.
    private let pencilAlpha: UInt32 = 102
    private var grain: [UInt8] = []            // 종이결: 픽셀별 불투명도 배율(종이=좌표에 고정)
    private var coverage: [UInt32] = []        // 획 내 1회 반영 마스크(= strokeID면 이미 칠함)
    private var strokeID: UInt32 = 0

    // 스트로크 상태
    private var lockedLabel: Int32 = 0
    private var lastImagePoint: CGPoint?

    // 표시 갱신 throttle (H-1): 샘플마다가 아니라 디스플레이 프레임당 1회만 makeImage.
    private var needsDisplayRefresh = false
    #if os(iOS)
    private var displayLink: CADisplayLink?
    private var linkProxy: DisplayLinkProxy?
    #endif

    // 라벨링 완료 전 들어온 입력 버퍼 (H-3): 준비되면 재생.
    private enum PendingEvent { case changed(CGPoint, CGSize); case ended }
    private var pendingEvents: [PendingEvent] = []

    // 저장
    private var lineart: PlatformImage?
    private var onPersist: ((Data, Data) -> Void)?
    private var saveTask: Task<Void, Never>?
    private var isEncoding = false             // PNG 인코딩 진행 중(중복 저장 직렬화, C)
    private var resaveRequested = false        // 인코딩 중 들어온 저장 요청 → 끝나고 1회 재실행
    private var configured = false

    deinit {
        #if os(iOS)
        displayLink?.invalidate()
        #endif
    }

    // MARK: - 구성

    /// 라인아트로 영역 맵을 만들고(백그라운드) 색칠 버퍼를 준비한다. 화면당 1회.
    func configure(lineart: PlatformImage?,
                   initialData: Data?,
                   onPersist: @escaping (Data, Data) -> Void) {
        guard !configured else { return }
        self.onPersist = onPersist

        // 라인아트가 아직 없으면 설정을 보류한다(configured를 세우지 않음).
        // 부모가 라인아트를 늦게 디코딩하는 경우 onChange로 다시 호출된다.
        guard let lineart, let cg = cgImage(from: lineart) else { return }
        configured = true
        self.lineart = lineart

        // 작업 해상도: 긴 변 1024px 이하
        let maxWork = 1024
        let iw = cg.width, ih = cg.height
        let longest = max(iw, ih)
        let scale = longest > maxWork ? CGFloat(maxWork) / CGFloat(longest) : 1
        let w = max(1, Int((CGFloat(iw) * scale).rounded()))
        let h = max(1, Int((CGFloat(ih) * scale).rounded()))

        setupPaintBuffer(width: w, height: h)
        if let initialData { loadPaint(initialData) }
        refreshDisplay()

        // 라벨링은 비용이 크므로 백그라운드에서. 종이결(grain)도 좌표 고정이라
        // 도구와 무관하게 여기서 같이 만들어 둔다(색연필 첫 터치의 메인 hitch 제거).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let labels = Self.buildLabels(from: cg, width: w, height: h)
            let grain = Self.makeGrain(width: w, height: h)
            DispatchQueue.main.async {
                guard let self else { return }
                self.labels = labels
                self.grain = grain
                self.ready = true
                self.replayPendingEvents()   // 준비 전 들어온 입력 재생
            }
        }
    }

    /// 라벨링 완료 전 버퍼링한 입력을 정상 경로로 재생한다(H-3).
    /// 한 번에 다 돌리지 않고 청크로 나눠 여러 런루프 틱에 분산 → 메인 점유(hitch) 방지.
    private func replayPendingEvents() {
        guard !pendingEvents.isEmpty else { return }
        let events = pendingEvents
        pendingEvents = []
        replayChunk(events, from: 0)
    }

    private func replayChunk(_ events: [PendingEvent], from start: Int) {
        let end = min(start + 200, events.count)
        for i in start..<end {
            switch events[i] {
            case let .changed(p, s): strokeChanged(at: p, viewSize: s)
            case .ended: strokeEnded()
            }
        }
        if end < events.count {
            DispatchQueue.main.async { [weak self] in self?.replayChunk(events, from: end) }
        }
    }

    private func setupPaintBuffer(width w: Int, height h: Int) {
        width = w; height = h
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: info) else { return }
        // 투명으로 시작(아래 흰 배경 + 위 라인아트는 뷰에서 합성)
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        paintCtx = ctx
        pixels = ctx.data?.assumingMemoryBound(to: UInt8.self)
    }

    // MARK: - 스트로크 입력 (뷰 좌표 → 이미지 픽셀)

    func strokeChanged(at viewPoint: CGPoint, viewSize: CGSize) {
        guard width > 0, viewSize.width > 0, viewSize.height > 0 else { return }
        guard ready else {                       // H-3: 라벨링 전이면 버퍼링
            bufferPending(.changed(viewPoint, viewSize))
            return
        }
        let p = imagePoint(viewPoint, viewSize: viewSize)
        let radius = brushRadius(viewSize: viewSize)

        if let last = lastImagePoint {
            stampLine(from: last, to: p, radius: radius)
        } else {
            // 다운: 시작 칸 라벨 잠금 + (색연필) 새 획 시작
            lockedLabel = label(atX: Int(p.x), y: Int(p.y))
            if tool == .pencil && !isEraser {
                ensurePencilBuffers()
                strokeID &+= 1            // 새 획 → 이 획에서 칠한 픽셀을 1회만 반영
            }
            if lockedLabel != 0 { stamp(center: p, radius: radius) }
        }
        lastImagePoint = p
        scheduleDisplayRefresh()
    }

    func strokeEnded() {
        guard ready else {                       // H-3
            bufferPending(.ended)
            return
        }
        lastImagePoint = nil
        lockedLabel = 0
        scheduleDisplayRefresh()
        scheduleSave()
    }

    private func bufferPending(_ event: PendingEvent) {
        if pendingEvents.count < 2_000 { pendingEvents.append(event) }   // 폭주 방지 상한
    }

    /// 화면 이탈 등에서 즉시 저장.
    @MainActor func flush() { saveNow() }

    // MARK: - 칠하기

    private func brushRadius(viewSize: CGSize) -> CGFloat {
        let imgScale = CGFloat(width) / viewSize.width
        return max(1, brushPointWidth * imgScale / 2)
    }

    private func imagePoint(_ vp: CGPoint, viewSize: CGSize) -> CGPoint {
        CGPoint(x: vp.x * CGFloat(width) / viewSize.width,
                y: vp.y * CGFloat(height) / viewSize.height)
    }

    private func label(atX x: Int, y: Int) -> Int32 {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return labels[y * width + x]
    }

    /// 두 점 사이를 스탬프로 채워 연속된 선을 만든다.
    private func stampLine(from a: CGPoint, to b: CGPoint, radius: CGFloat) {
        let dx = b.x - a.x, dy = b.y - a.y
        let dist = (dx * dx + dy * dy).squareRoot()
        let step = max(1, radius / 2)
        let count = max(1, Int(dist / step))
        for i in 0...count {
            let t = CGFloat(i) / CGFloat(count)
            stamp(center: CGPoint(x: a.x + dx * t, y: a.y + dy * t), radius: radius)
        }
    }

    /// 원형 스탬프: 잠긴 칸(lockedLabel)에 속한 픽셀만 칠한다.
    /// - 지우개: 알파 0으로 비움.
    /// - 마커: 불투명 단색 덮어쓰기.
    /// - 색연필: 종이결로 변조한 반투명을 source-over로 누적(획 내 1회). 덧칠 시 진해짐.
    private func stamp(center: CGPoint, radius: CGFloat) {
        guard lockedLabel != 0, let px = pixels else { return }
        let (r, g, b) = brushRGB                 // L-2: 캐시된 색 사용
        let rad = Int(radius.rounded())
        let cx = Int(center.x), cy = Int(center.y)
        let r2 = rad * rad

        let minX = max(0, cx - rad), maxX = min(width - 1, cx + rad)
        let minY = max(0, cy - rad), maxY = min(height - 1, cy + rad)
        guard minX <= maxX, minY <= maxY else { return }

        let pencil = (tool == .pencil) && !isEraser
        let rU = UInt32(r), gU = UInt32(g), bU = UInt32(b)

        for y in minY...maxY {
            let dy = y - cy
            let row = y * width
            for x in minX...maxX {
                let dx = x - cx
                if dx * dx + dy * dy > r2 { continue }
                let i = row + x
                if labels[i] != lockedLabel { continue }   // 칸 밖 → 무시
                let o = i * 4
                if isEraser {
                    px[o] = 0; px[o + 1] = 0; px[o + 2] = 0; px[o + 3] = 0
                } else if pencil {
                    // 획 내 1회만: 이미 이번 획에서 칠한 픽셀이면 건너뛴다(균일, 얼룩 방지).
                    if coverage[i] == strokeID { continue }
                    coverage[i] = strokeID
                    // 이번 픽셀의 올림 불투명도 = 한획 알파 × 종이결(0.72~1.0).
                    let a = (pencilAlpha * UInt32(grain[i]) + 127) / 255
                    if a == 0 { continue }
                    let inv = 255 - a
                    // premultipliedLast 버퍼에 정수 source-over.
                    // src RGB는 straight(rU)지만 분자에서 alpha(a)와 곱해져 premult로 변환됨
                    // → 별도 premultiply 보정을 추가하면 색이 어두워지니 금지. a+inv=255라 결과 ≤255.
                    px[o]     = UInt8((rU * a + UInt32(px[o])     * inv + 127) / 255)
                    px[o + 1] = UInt8((gU * a + UInt32(px[o + 1]) * inv + 127) / 255)
                    px[o + 2] = UInt8((bU * a + UInt32(px[o + 2]) * inv + 127) / 255)
                    px[o + 3] = UInt8((a * 255 + UInt32(px[o + 3]) * inv + 127) / 255)
                } else {
                    px[o] = r; px[o + 1] = g; px[o + 2] = b; px[o + 3] = 255
                }
            }
        }
    }

    /// 색연필 버퍼(커버리지) 지연 생성. 색연필 첫 획에서 호출. 화면당 1회 구축.
    /// grain은 보통 configure 백그라운드에서 이미 만들어져 있고, 여기선 안전망(폴백)으로만 생성.
    private func ensurePencilBuffers() {
        let n = width * height
        guard n > 0 else { return }
        if grain.count != n { grain = Self.makeGrain(width: width, height: height) }   // 폴백
        if coverage.count != n {
            coverage = [UInt32](repeating: 0, count: n)   // 0 = 아직 어떤 획도 안 칠함
            strokeID = 0
        }
    }

    /// 종이결 마스크: 픽셀별 불투명도 배율(185~255 → 0.72~1.0). 종이=좌표에 고정이라
    /// 칠을 움직여도 결이 떨리지 않는다. 두 주파수 해시를 섞어 백색잡음 티를 줄인다.
    private static func makeGrain(width w: Int, height h: Int) -> [UInt8] {
        var g = [UInt8](repeating: 255, count: w * h)
        let minByte: UInt32 = 185
        let span: UInt32 = 256 - minByte           // 71
        g.withUnsafeMutableBufferPointer { buf in
            for y in 0..<h {
                let row = y * w
                let yU = UInt32(truncatingIfNeeded: y)
                let yHalf = UInt32(truncatingIfNeeded: y >> 1)
                for x in 0..<w {
                    let h1 = hash2(UInt32(truncatingIfNeeded: x), yU)
                    let h2 = hash2(UInt32(truncatingIfNeeded: x >> 1), yHalf)
                    buf[row + x] = UInt8(minByte + ((h1 &+ h2) % span))
                }
            }
        }
        return g
    }

    private static func hash2(_ x: UInt32, _ y: UInt32) -> UInt32 {
        var h = x &* 0x27d4_eb2d &+ y &* 0x1656_67b1
        h ^= h >> 15; h = h &* 0x2c1b_3c6d; h ^= h >> 12
        return h
    }

    private func refreshDisplay() {
        displayImage = paintCtx?.makeImage()
    }

    // MARK: - 표시 갱신 throttle (H-1)

    /// 한 프레임에 여러 샘플이 들어와도 makeImage는 디스플레이 주기당 1회만 돌도록 합친다.
    /// iOS는 CADisplayLink로 프레임 정렬, macOS(보조)는 즉시 갱신.
    private func scheduleDisplayRefresh() {
        #if os(iOS)
        needsDisplayRefresh = true
        startDisplayLinkIfNeeded()
        #else
        refreshDisplay()
        #endif
    }

    #if os(iOS)
    private func startDisplayLinkIfNeeded() {
        if let link = displayLink {
            link.isPaused = false
            return
        }
        let proxy = DisplayLinkProxy { [weak self] in self?.onDisplayFrame() }
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        linkProxy = proxy
        displayLink = link
    }

    private func onDisplayFrame() {
        if needsDisplayRefresh {
            needsDisplayRefresh = false
            refreshDisplay()
        } else {
            displayLink?.isPaused = true   // 유휴 시 일시정지(전력 절약)
        }
    }
    #endif

    // MARK: - 저장

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    @MainActor private func saveNow() {
        saveTask?.cancel()
        // C: 인코딩이 진행 중이면 중복 실행하지 않고, 끝난 뒤 1회만 다시 저장하도록 표시.
        guard !isEncoding else { resaveRequested = true; return }
        // 스냅샷 + 썸네일 합성은 메인에서(ImageRenderer는 메인 전용).
        guard let cg = paintCtx?.makeImage() else { return }
        let base = Image(decorative: cg, scale: 1).resizable()
        let aspect = CGSize(width: width, height: height)
        guard let thumb = CanvasThumb.render(base: base, lineart: lineart, aspect: aspect) else { return }
        // L-3: 무거운 PNG 인코딩은 백그라운드, 완료 후 메인에서 저장.
        isEncoding = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = self?.pngData(from: cg)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isEncoding = false
                if let data, let onPersist = self.onPersist { onPersist(data, thumb) }
                if self.resaveRequested {            // 진행 중 들어온 요청 처리
                    self.resaveRequested = false
                    self.saveNow()
                }
            }
        }
    }

    private func loadPaint(_ data: Data) {
        guard let ctx = paintCtx,
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        // draw + makeImage는 방향을 보존(반전 없음) → 색칠 버퍼의 행0=상단 규약과 일치.
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func pngData(from cg: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: - 영역 라벨링 (Hoshen–Kopelman, 4-연결)

    private static func buildLabels(from cg: CGImage, width w: Int, height h: Int) -> [Int32] {
        let n = w * h
        // 라인아트를 흰 배경에 합성해 RGBA 픽셀을 읽는다.
        // draw + 픽셀 읽기는 방향을 보존(반전 없음) → 색칠 버퍼/표시의 행0=상단 규약과 일치.
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: info),
              let buf = ctx.data?.assumingMemoryBound(to: UInt8.self)
        else { return [Int32](repeating: 0, count: n) }

        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // 경계 판정: 어두운 픽셀(라인)
        let threshold = 130.0
        var barrier = [Bool](repeating: false, count: n)
        for i in 0..<n {
            let o = i * 4
            let lum = 0.299 * Double(buf[o]) + 0.587 * Double(buf[o + 1]) + 0.114 * Double(buf[o + 2])
            barrier[i] = lum < threshold
        }

        // union-find
        var parent: [Int32] = [0]                 // index 0 미사용
        func find(_ x: Int32) -> Int32 {
            var root = x
            while parent[Int(root)] != root { root = parent[Int(root)] }
            var cur = x
            while parent[Int(cur)] != root {
                let nxt = parent[Int(cur)]; parent[Int(cur)] = root; cur = nxt
            }
            return root
        }
        func union(_ a: Int32, _ b: Int32) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[Int(rb)] = ra }
        }

        var labels = [Int32](repeating: 0, count: n)
        var next: Int32 = 1
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                if barrier[i] { continue }
                let up: Int32 = y > 0 ? labels[i - w] : 0
                let left: Int32 = x > 0 ? labels[i - 1] : 0
                if up == 0 && left == 0 {
                    parent.append(next)           // parent[next] = next
                    labels[i] = next
                    next += 1
                } else if up != 0 && left == 0 {
                    labels[i] = find(up)
                } else if left != 0 && up == 0 {
                    labels[i] = find(left)
                } else {
                    let a = find(up)
                    labels[i] = a
                    union(a, left)
                }
            }
        }
        // 루트로 평탄화
        for i in 0..<n where labels[i] != 0 {
            labels[i] = find(labels[i])
        }
        return labels
    }
}

// MARK: - 플랫폼 헬퍼

#if os(iOS)
/// CADisplayLink는 @objc 셀렉터(NSObject)가 필요해 얇은 프록시로 감싼다.
private final class DisplayLinkProxy: NSObject {
    private let onTick: () -> Void
    init(onTick: @escaping () -> Void) { self.onTick = onTick }
    @objc func tick() { onTick() }
}
#endif

private func cgImage(from image: PlatformImage) -> CGImage? {
    #if canImport(UIKit)
    return image.cgImage
    #elseif canImport(AppKit)
    return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    #else
    return nil
    #endif
}

private func rgbComponents(of color: Color) -> (UInt8, UInt8, UInt8) {
    #if canImport(UIKit)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
    #elseif canImport(AppKit)
    let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
    let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
    #else
    let r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
    #endif
    func u(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(1, v)) * 255) }
    return (u(r), u(g), u(b))
}
