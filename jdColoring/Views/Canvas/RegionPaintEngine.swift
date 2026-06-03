import SwiftUI
import CoreGraphics
import ImageIO
import UIKit
import UniformTypeIdentifiers

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
    // 첫 칠(처음 닿는 픽셀)이 올리는 불투명도(0.78*255). 한 획만으로도 본색이 살아 있다.
    private static let pencilAlphaFirst: UInt32 = 200
    // 덧칠(이미 칠해진 픽셀에 다시)이 올리는 불투명도(0.29*255). 첫 칠 이후엔 천천히 누적 —
    // 봉우리 기준 첫 칠(78%) + 덧칠 약 9번이면 99%(본색)에 도달((1-0.29)^9·0.22 ≈ 0.01).
    // (첫 칠은 그대로 두고 그 이후만 느리게, 2026-06-02 튜닝)
    private static let pencilAlphaBuild: UInt32 = 74
    // grain(0~255) → 올림 불투명도 a = (alpha*grain+127)/255 의 LUT.
    // alpha가 상수라 1회 precompute → 핫패스(stamp)에서 픽셀당 곱셈·나눗셈 제거(무손실).
    private static let pencilAlphaFirstLUT: [UInt8] =
        (0...255).map { UInt8((pencilAlphaFirst * UInt32($0) + 127) / 255) }
    private static let pencilAlphaBuildLUT: [UInt8] =
        (0...255).map { UInt8((pencilAlphaBuild * UInt32($0) + 127) / 255) }
    private var grain: [UInt8] = []            // 종이결: 픽셀별 불투명도 배율(종이=좌표에 고정)
    // 색연필 덧칠(쌓임) 게이트 — 픽셀별 "마지막으로 칠한 누적 이동거리(px)". 0 = 아직 안 칠함.
    // 한 번 지나가며 생기는 인접 스탬프 겹침과 정지는 무시하고(균일·정지 시 안 진해짐),
    // 브러시가 한 지름 넘게 벗어났다 되돌아와 겹친 곳만 다시 칠해 진해진다.
    private var coverage: [UInt32] = []
    private var travel: UInt32 = 0             // 세션 단조 증가 누적 이동거리(px)
    private var travelCarry: CGFloat = 0       // travel 정수화 잔여분
    private let penDownJump: UInt32 = 4096      // 새 획 시작 시 점프(이전 획과 분리 → 항상 덧칠)

    // 스트로크 상태
    private var lockedLabel: Int32 = 0
    private var lastImagePoint: CGPoint?

    // 표시 갱신 throttle (H-1): 샘플마다가 아니라 디스플레이 프레임당 1회만 makeImage.
    private var needsDisplayRefresh = false
    private var displayLink: CADisplayLink?
    private var linkProxy: DisplayLinkProxy?

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
    // 초기화(clear) 가드: 비운 직후 빈 버퍼가 다시 저장돼 작업물이 되살아나는 것을 막는다.
    // savingEnabled=false면 새로 칠하기 전까지 저장 안 함. clearGeneration은 clear 시점에
    // 증가시켜, clear 이전에 시작된 백그라운드 인코딩 결과(옛 색칠)를 폐기한다.
    private var savingEnabled = true
    private var clearGeneration = 0

    /// CADisplayLink를 메인 스레드에서 안전하게 정리한다.
    /// DrawingCanvas.onDisappear에서 호출. deinit은 어느 스레드에서나 불릴 수 있어
    /// CADisplayLink.invalidate()를 deinit에 두면 안전을 보장할 수 없다.
    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        linkProxy = nil
    }

    deinit {
        // invalidate는 stopDisplayLink()가 담당. deinit에서 link 참조만 해제.
        displayLink = nil
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
                // 새 획: 이동거리를 크게 점프시켜 이전 획이 칠한 자리와 분리한다.
                // → 이전 획 위에 다시 그으면 항상 덧칠로 진해지고, 버퍼 초기화 memset은 피한다.
                travel = travel &+ penDownJump
                travelCarry = 0
            }
            if lockedLabel != 0 { stamp(center: p, radius: radius) }
        }
        // 실제로 칠해지는 칸에 닿았을 때만 저장 재개(초기화 후 빈 채로 나가면 저장 안 함).
        if lockedLabel != 0 { savingEnabled = true }
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

    /// 색칠 초기화: 색칠 버퍼를 비우고 진행 중/예약된 저장을 무효화한다.
    /// (작업물 Artwork 삭제는 뷰 쪽 책임. 여기선 엔진 버퍼만 비운다.)
    @MainActor func clear() {
        // 예약 저장 취소 + 인코딩 세대 증가 → 진행 중 백그라운드 저장 결과(옛 색칠) 폐기.
        saveTask?.cancel(); saveTask = nil
        resaveRequested = false
        clearGeneration &+= 1
        savingEnabled = false            // 새로 칠하기 전까지 빈 버퍼를 저장하지 않음
        // 스트로크 상태 리셋(혹시 드래그 중이었다면 끊는다)
        lastImagePoint = nil
        lockedLabel = 0
        // 색칠 버퍼 비우기(투명). 픽셀 포인터는 그대로 유효.
        if let ctx = paintCtx {
            ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        }
        // 색연필 쌓임 상태도 초기화(덧칠이 처음부터 다시 옅게 시작).
        if !coverage.isEmpty {
            coverage.withUnsafeMutableBufferPointer { b in
                b.baseAddress?.update(repeating: 0, count: b.count)
            }
        }
        refreshDisplay()
    }

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
        let spacing = dist / CGFloat(count)
        for i in 0...count {
            let t = CGFloat(i) / CGFloat(count)
            if i > 0 {                       // 색연필 덧칠 게이트용 누적 이동거리(정수화)
                travelCarry += spacing
                let whole = travelCarry.rounded(.down)
                travel = travel &+ UInt32(whole)
                travelCarry -= whole
            }
            stamp(center: CGPoint(x: a.x + dx * t, y: a.y + dy * t), radius: radius)
        }
    }

    /// 원형 스탬프: 잠긴 칸(lockedLabel)에 속한 픽셀만 칠한다.
    /// - 지우개: 알파 0으로 비움.
    /// - 마커: 불투명 단색 덮어쓰기.
    /// - 색연필: 종이결로 변조한 반투명을 source-over로 누적. 한 지름 넘게 벗어났다
    ///   되돌아와 겹친 곳은 덧칠로 진해진다(한 번 지나감·정지는 균일 유지).
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
        let tv = travel
        // 덧칠 게이트 거리: 한 지름(2r)+여유. 이만큼 벗어났다 와야 다시 쌓인다.
        // 한 번 지나갈 때 인접 스탬프가 같은 픽셀을 덮는 폭(최대 2r)보다 커야 균일 유지.
        let revisit = UInt32(radius * 2) + 3

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
                    // 막 지나간 자리(또는 정지)는 다시 안 칠함 → 균일. 한 지름 넘게
                    // 벗어났다 되돌아온 곳만(거리 게이트 통과) 덧칠해 진해진다.
                    let last = coverage[i]
                    if last != 0 && tv &- last < revisit { continue }
                    // 이번 픽셀의 올림 불투명도 = 알파 × 종이결(0.55~1.0). LUT 조회(무손실).
                    // 봉우리(grain=255)는 본색이 진하게, 골은 옅게 → 연필 결이 또렷.
                    // 첫 칠(last==0)은 진하게, 덧칠(last!=0)은 약하게 → 첫 획 후 천천히 누적.
                    let a = UInt32(last == 0 ? Self.pencilAlphaFirstLUT[Int(grain[i])]
                                             : Self.pencilAlphaBuildLUT[Int(grain[i])])
                    coverage[i] = tv
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
            coverage = [UInt32](repeating: 0, count: n)   // 0 = 아직 안 칠함
        }
    }

    /// 종이결 마스크: 픽셀별 불투명도 배율(100~255 → 0.39~1.0). 종이=좌표에 고정이라
    /// 칠을 움직여도 결이 떨리지 않는다. 미세 결(per-pixel)에 거친 결(4px 덩어리)을 섞어
    /// 연필이 종이 결에 걸리는 거칠거칠한 질감을 낸다. 골을 더 낮춰(이전 140) 흰 종이가
    /// 더 비쳐 보이게 하고, 거친 octave로 잔점을 또렷하게 한다.(2026-06-02 튜닝)
    private static func makeGrain(width w: Int, height h: Int) -> [UInt8] {
        var g = [UInt8](repeating: 255, count: w * h)
        let minByte: UInt32 = 100
        let span: UInt32 = 256 - minByte           // 156
        g.withUnsafeMutableBufferPointer { buf in
            for y in 0..<h {
                let row = y * w
                let yU = UInt32(truncatingIfNeeded: y)
                let yQuart = UInt32(truncatingIfNeeded: y >> 2)
                for x in 0..<w {
                    let h1 = hash2(UInt32(truncatingIfNeeded: x), yU)              // 미세 결
                    let h2 = hash2(UInt32(truncatingIfNeeded: x >> 2), yQuart)     // 거친 결(4px 덩어리)
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

    private func scheduleDisplayRefresh() {
        needsDisplayRefresh = true
        startDisplayLinkIfNeeded()
    }

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

    // MARK: - 저장

    private func scheduleSave() {
        guard savingEnabled else { return }      // 초기화 직후 빈 버퍼 저장 방지
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    @MainActor private func saveNow() {
        saveTask?.cancel()
        guard savingEnabled else { return }      // 초기화 후 미채색 상태면 저장하지 않음(flush 포함)
        // C: 인코딩이 진행 중이면 중복 실행하지 않고, 끝난 뒤 1회만 다시 저장하도록 표시.
        guard !isEncoding else { resaveRequested = true; return }
        // 스냅샷 + 썸네일 합성은 메인에서(ImageRenderer는 메인 전용).
        guard let cg = paintCtx?.makeImage() else { return }
        let base = Image(decorative: cg, scale: 1).resizable()
        let aspect = CGSize(width: width, height: height)
        guard let thumb = CanvasThumb.render(base: base, lineart: lineart, aspect: aspect) else { return }
        // L-3: 무거운 PNG 인코딩은 백그라운드, 완료 후 메인에서 저장.
        isEncoding = true
        let gen = clearGeneration                 // 이 저장이 시작된 시점의 세대
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = self?.pngData(from: cg)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isEncoding = false
                // clear가 끼어들었으면(세대 변경) 옛 색칠 결과이므로 폐기 → 작업물 부활 방지.
                guard self.clearGeneration == gen else { self.resaveRequested = false; return }
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

// MARK: - 헬퍼

/// CADisplayLink는 @objc 셀렉터(NSObject)가 필요해 얇은 프록시로 감싼다.
private final class DisplayLinkProxy: NSObject {
    private let onTick: () -> Void
    init(onTick: @escaping () -> Void) { self.onTick = onTick }
    @objc func tick() { onTick() }
}

private func cgImage(from image: PlatformImage) -> CGImage? {
    image.cgImage
}

private func rgbComponents(of color: Color) -> (UInt8, UInt8, UInt8) {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
    func u(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(1, v)) * 255) }
    return (u(r), u(g), u(b))
}
