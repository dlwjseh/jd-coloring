import SwiftUI
import SwiftData

/// 화면 3 — 색칠 캔버스. 도안 위에 브러시로 색칠, 진행 자동 저장.
struct ColoringCanvasView: View {
    let profile: Profile
    let template: Template
    /// NavigationStack path — 만료 시 프로필 선택 화면(화면 1)으로 한 번에 복귀.
    @Binding var path: [Route]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(PeerSession.self) private var peerSession
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.scenePhase) private var scenePhase

    @Query private var artworks: [Artwork]

    @State private var selectedColor: Color = Palette.defaultColor
    @State private var brushWidth: CGFloat = Palette.brushWidths[1]
    @State private var isEraser = false
    @State private var tool: BrushTool = .marker
    @State private var recentColors: [Color] = []
    @State private var paletteOpen = false
    @State private var lineImage: PlatformImage?
    @State private var saver = CanvasSaver()
    @State private var showSaved = false
    @State private var saveFlashToken = 0
    @State private var showResetConfirm = false


    // 부모 타이머
    @State private var timerEnd: Date? = nil
    @State private var timerNow = Date()
    @State private var timerExpired = false   // C-2: 만료 중복 처리 방지
    private let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let panelAnimation: Animation = .spring(response: 0.42, dampingFraction: 0.86)

    init(profile: Profile, template: Template, path: Binding<[Route]>) {
        self.profile = profile
        self.template = template
        self._path = path
        let pid = profile.persistentModelID, tid = template.persistentModelID
        _artworks = Query(filter: #Predicate<Artwork> {
            $0.profile?.persistentModelID == pid && $0.template?.persistentModelID == tid
        })
    }

    private var existing: Artwork? { artworks.first }
    /// 초기화 다이얼로그 타이틀: 이름 있으면 "'{name}'의 색칠을…", 없으면 "이 그림의 색칠을…"
    private var resetAlertTitle: String {
        template.name.isEmpty
            ? "이 그림의 색칠을 모두 지울까요?"
            : "'\(template.name)'의 색칠을 모두 지울까요?"
    }
    private var aspect: CGSize {
        let s = lineImage?.size ?? CGSize(width: 1, height: 1)
        return (s.width > 0 && s.height > 0) ? s : CGSize(width: 1, height: 1)
    }

    var body: some View {
        ZStack {
            Theme.bgGradient.ignoresSafeArea()
            BubbleBackground()

            VStack(spacing: 0) {
                topBar
                HStack(spacing: 24) {
                    // ZoomableCanvasPanel 이 zoomState를 자체 @State로 보유.
                    // 핀치/팬 프레임마다 이 패널의 body만 재평가되고,
                    // topBar · rightColumn · BubbleBackground 등은 무효화되지 않는다.
                    ZoomableCanvasPanel(
                        initialData: existing?.progressData,
                        lineart: lineImage,
                        aspect: aspect,
                        color: selectedColor,
                        lineWidth: brushWidth,
                        isEraser: isEraser,
                        tool: tool,
                        penOnly: appSettings.penOnly,
                        saver: saver,
                        onPersist: persist
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    rightColumn
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 22)
            }

            if paletteOpen { palettePanel }
        }
        .onAppear {
            if lineImage == nil { lineImage = PlatformImage(data: template.imageData) }
            // M-2: 화면 재진입 시 이미 타이머가 설정돼 있으면 동기화 (onChange는 값 변화 시만 발화)
            // 단, 이 타이머가 '이 프로필' 대상일 때만 적용(프로필 지정 타이머).
            if timerEnd == nil { syncTimerFromPeer(peerSession.receivedTimerEnd) }
        }
        .onDisappear {
            saver.flush()
            // 풀해상 라인아트 비트맵(최대 1400px) 즉시 해제 — 반복 진입/이탈 시
            // 캔버스 작업 버퍼와 겹쳐 메모리가 누적되는 것을 막는다.
            lineImage = nil
        }
        // C-1: 타이머가 없을 때는 state 갱신 안 함 → body 불필요 재평가 차단
        .onReceive(clockTimer) { date in
            guard timerEnd != nil else { return }
            timerNow = date
        }
        .onChange(of: peerSession.receivedTimerEnd) { _, end in
            syncTimerFromPeer(end)
        }
        // C-2: expired 플래그로 만료 진입점 단일화 (onDisappear flush와 중복 방지)
        // MAJOR-1: flush 완료 후 화면 전환 → 마지막 색칠 보장
        // MINOR-1: withAnimation으로 전환 부드럽게
        .onChange(of: timerRemaining) { _, rem in
            guard let rem, rem <= 0, !timerExpired else { return }
            // M-1: 만료 순간 활성 프로필(이 캔버스)이 지정 대상인지 명시 재검증.
            // 불일치면 홈 복귀 없이 로컬 정리만(소멸). 기획 체크포인트(currentProfile.uuid == target) 명시화.
            guard timerAppliesToMe else {
                timerEnd = nil
                return
            }
            timerExpired = true
            timerEnd = nil
            peerSession.receivedTimerEnd = nil      // 재진입 시 만료 타이머 재적용 방지
            peerSession.receivedTimerTarget = nil
            saver.flushThen {
                withAnimation { path.removeAll() }
            }
        }
        // MAJOR-2: 포그라운드 복귀 즉시 timerNow 갱신 → 백그라운드 중 만료된 타이머 즉시 반영
        // 백그라운드 진입 시 flush → onDisappear가 보장되지 않는 시스템 종료에서도 색칠 보존.
        // (수동 저장 전용으로 전환되면서 디바운스 안전망이 사라진 것을 보완.)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, timerEnd != nil {
                timerNow = Date()
            }
            if phase == .background {
                saver.flush()
            }
        }
        .alert(resetAlertTitle, isPresented: $showResetConfirm) {
            Button("취소", role: .cancel) {}
            Button("초기화", role: .destructive) { performReset() }
        } message: {
            Text("지운 색칠은 되돌릴 수 없어요")
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Sections

    // MARK: - 타이머 헬퍼

    private var timerRemaining: TimeInterval? {
        guard let end = timerEnd else { return nil }
        return max(0, end.timeIntervalSince(timerNow))
    }

    /// 수신한 타이머가 '이 프로필' 대상인가 (프로필 지정 타이머).
    private var timerAppliesToMe: Bool {
        peerSession.receivedTimerTarget == profile.uuid
    }

    /// 수신 타이머를 로컬 timerEnd로 반영.
    /// - 대상이 이 프로필이 아니면 무시(칩 미표시·만료 동작 없음).
    /// - 대상이지만 이미 만료된 시각이면 '소멸'(동작 없이 정리) — 비활성 중 만료 후 뒤늦은 진입 케이스.
    /// - 대상이고 아직 미래면 적용 → 칩 표시 + 만료 시 저장·홈 복귀.
    private func syncTimerFromPeer(_ end: Date?) {
        timerExpired = false
        guard timerAppliesToMe, let end else {
            withAnimation(.easeInOut(duration: 0.3)) { timerEnd = nil }
            return
        }
        if end > Date() {
            withAnimation(.easeInOut(duration: 0.3)) { timerEnd = end }
        } else {
            // 비활성(다른 아이/홈) 중 만료된 타이머에 뒤늦게 진입 → 소멸.
            peerSession.receivedTimerEnd = nil
            peerSession.receivedTimerTarget = nil
            timerEnd = nil
        }
    }

    private func timerFormatted(_ interval: TimeInterval) -> String {
        let t = Int(interval)
        let minutes = t / 60
        let seconds = t % 60
        if minutes == 0 {
            return "\(seconds)초"
        }
        return "\(minutes)분 \(String(format: "%02d", seconds))초"
    }

    /// 슬림 상단: 좌측 뒤로가기 + 작은 도안명, 중앙에 잠깐 뜨는 "저장됨" 토스트,
    /// 우측에 부모 타이머 칩(타이머 없으면 숨김).
    private var topBar: some View {
        ZStack {
            if showSaved { savedToast.transition(.opacity) }
            HStack(spacing: 14) {
                Button { saver.flush(); dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Theme.card))
                        .overlay(Circle().stroke(Theme.cardBorder, lineWidth: 2))
                        .shadow(color: Theme.softShadow, radius: 8, x: 0, y: 4)
                }
                .buttonStyle(.plain)
                if !template.name.isEmpty {
                    Text(template.name)
                        .font(Theme.rounded(22, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .frame(maxWidth: 400, alignment: .leading)
                }
                Spacer()
                if let rem = timerRemaining {
                    TimerChip(remaining: rem, formatted: timerFormatted(rem))
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private var savedToast: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
            Text("저장됨").font(Theme.rounded(16, weight: .bold))
        }
        .foregroundStyle(Color(hex: 0x3FA86B))
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(Capsule().fill(Color(hex: 0xE0F6E9)))
    }

    /// 우측 열: 저장 버튼(위) · 툴 레일(중) · 색칠 초기화(아래). 디자인 §25.
    private var rightColumn: some View {
        VStack(spacing: 16) {
            saveButton
            rightRail
            resetButton
        }
    }

    /// 수동 저장 — 레일 위 원형 버튼. 초록 색감으로 저장됨 토스트와 시각 언어 통일.
    /// flush만 호출. 토스트는 실제 저장 완료(persist) 시 flashSaved()가 발화 — 중복 방지.
    private var saveButton: some View {
        Button {
            saver.flush()
        } label: {
            Image(systemName: "checkmark")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 96, height: 96)
                .background(Circle().fill(Color(hex: 0x3FA86B)))
                .shadow(color: Color(hex: 0x3FA86B).opacity(0.22), radius: 11, x: 0, y: 7)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("저장")
    }

    /// 색칠 초기화 — 레일 아래 원형 휴지통 버튼(지름 = 레일 폭 96). 디자인 §19-1.
    /// 크림/카드 톤(위험색 아님), 탭 시 확인 다이얼로그.
    private var resetButton: some View {
        Button { showResetConfirm = true } label: {
            Image(systemName: "trash")
                .font(.system(size: 26))
                .foregroundStyle(Color(hex: 0x6E6258))
                .frame(width: 96, height: 96)
                .background(Circle().fill(Theme.card))
                .overlay(Circle().stroke(Theme.cardBorder, lineWidth: 2))
                .shadow(color: Theme.softShadow, radius: 11, x: 0, y: 7)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("색칠 초기화")
    }

    /// 우측 세로 툴 레일: 현재색(=색 고르기) · 도구 · 굵기 · 지우개 (최근색은 펼침 패널로).
    private var rightRail: some View {
        VStack(spacing: 16) {
            // 현재색 동그라미 = 색 고르기 버튼. 탭하면 펼침 패널 등장(별도 '색' 버튼 폐지).
            // 힌트 아이콘·활성 링 없이 현재색만 표시(디자인 §21).
            Button {
                withAnimation(panelAnimation) { paletteOpen = true }
            } label: {
                Circle().fill(selectedColor)
                    .frame(width: 50, height: 50)
                    .overlay(Circle().stroke(Theme.ink, lineWidth: 3.5))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("색 고르기")

            railDivider
            toolToggle

            railDivider
            VStack(spacing: 10) {
                ForEach(Array(Palette.brushWidths.enumerated()), id: \.offset) { idx, w in
                    Button { brushWidth = w } label: {
                        Circle().fill(Theme.ink)
                            .frame(width: w * 0.7 + 6, height: w * 0.7 + 6)
                            .padding(7)
                            .overlay(Circle().stroke(brushWidth == w ? Theme.coral : .clear, lineWidth: 3))
                            .frame(minWidth: 44, minHeight: 44)   // 라벨 없이도 터치 타깃 44pt+ 보장
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("브러쉬 굵기 \(idx + 1)")
                }
            }

            railDivider
            Button { isEraser.toggle() } label: {
                Image(systemName: "eraser.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(isEraser ? Theme.coral : Theme.ink)
                    .frame(width: 50, height: 44)
                    .background(RoundedRectangle(cornerRadius: 14).fill(isEraser ? Theme.coral.opacity(0.15) : .clear))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("지우개")
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 14)
        .frame(width: 96)
        .background(RoundedRectangle(cornerRadius: 40).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 40).stroke(Theme.cardBorder, lineWidth: 2))
        .shadow(color: Theme.softShadow, radius: 11, x: 0, y: 7)
    }

    private var railDivider: some View {
        Rectangle().fill(Theme.cardBorder).frame(height: 2).padding(.horizontal, 8)
    }

    /// 도구 전환 — 브러쉬(단색) ↔ 색연필(질감). 디자인 §20-1. 세로 2칸, 활성은 코랄 강조.
    /// 라벨은 제거(아이콘만) — 접근성 라벨로 식별.
    private var toolToggle: some View {
        VStack(spacing: 8) {
            toolButton(.marker, symbol: "paintbrush.pointed")
            toolButton(.pencil, symbol: "pencil")
        }
    }

    private func toolButton(_ t: BrushTool, symbol: String) -> some View {
        let active = tool == t && !isEraser
        return Button {
            tool = t
            isEraser = false
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(active ? Theme.coral : Theme.ink)
                .frame(width: 50, height: 44)
                .background(RoundedRectangle(cornerRadius: 14).fill(active ? Theme.coral.opacity(0.12) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t == .marker ? "브러쉬" : "색연필")
    }

    /// '색' → 우측에서 슬라이드되는 팔레트 패널(최근색 + 72색). 캔버스 위 오버레이.
    private var palettePanel: some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.12).ignoresSafeArea()
                .onTapGesture { closePalette() }
                .transition(.opacity)
            ColorPaletteGrid(selected: selectedColor, recent: recentColors) { color in
                pick(color)
                closePalette()
            }
            .padding(.trailing, 128)
            .padding(.vertical, 36)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    private func closePalette() {
        withAnimation(panelAnimation) { paletteOpen = false }
    }

    // MARK: - Actions

    private func pick(_ color: Color) {
        selectedColor = color
        isEraser = false
        recentColors.removeAll { $0 == color }
        recentColors.insert(color, at: 0)
        if recentColors.count > 6 { recentColors = Array(recentColors.prefix(6)) }
    }

    /// 색칠 초기화 확정: 엔진 버퍼 비우기 + 작업물(Artwork) 삭제.
    /// 색/도구/굵기/지우개 상태는 건드리지 않음. 사용자는 캔버스에 그대로 머문다.
    ///
    /// 순서가 중요: `saver.reset()`은 엔진 `clear()`를 **동기로** 호출해
    /// 예약 저장 취소·`savingEnabled=false`·세대 증가를 먼저 확정한다. 그래야
    /// 이어지는 delete 이후 떠 있던 디바운스 저장/flush가 빈 버퍼를 되살리지 못한다.
    /// (SwiftUI onChange 토큰은 다음 업데이트로 지연돼 이 순서를 보장 못 하므로 직접 핸들 호출.)
    private func performReset() {
        saver.reset()                    // 동기: 엔진 clear + 저장 가드 활성화
        if let art = existing {
            context.delete(art)
            try? context.save()
        }
    }

    private func persist(_ data: Data, _ thumb: Data) {
        if let art = existing {
            art.progressData = data
            art.progressThumbnail = thumb
            art.updatedAt = .now
        } else {
            let art = Artwork(template: template, profile: profile,
                              progressThumbnail: thumb, progressData: data)
            context.insert(art)
        }
        try? context.save()
        flashSaved()
    }

    /// 저장 시 "저장됨" 토스트를 잠깐 표시(마지막 저장 기준 1.4초 후 사라짐).
    private func flashSaved() {
        saveFlashToken += 1
        let token = saveFlashToken
        withAnimation(.easeOut(duration: 0.2)) { showSaved = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if token == saveFlashToken {
                withAnimation(.easeIn(duration: 0.3)) { showSaved = false }
            }
        }
    }
}

// MARK: - 부모 타이머 칩

/// 남은 시간을 상단 바에 표시하는 칩.
/// 디자인 스펙 §22: 기본(파랑) → 5분 이하(주황) → 1분 이하(빨강+펄스).
private struct TimerChip: View {
    let remaining: TimeInterval
    let formatted: String

    @State private var pulse = false

    private var isAlert: Bool { remaining <= 60 }
    private var isWarning: Bool { remaining <= 300 }

    private var chipBg: Color {
        isAlert ? Color(hex: 0xFFE8E8) : isWarning ? Color(hex: 0xFFF3E0) : Color(hex: 0xEBF3FF)
    }
    private var chipFg: Color {
        isAlert ? Color(hex: 0xFF5A5F) : isWarning ? Color(hex: 0xD4720A) : Color(hex: 0x2F6CB8)
    }

    var body: some View {
        Text("⏱ \(formatted)")
            .font(Theme.rounded(18, weight: .bold))
            .foregroundStyle(chipFg)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Capsule().fill(chipBg))
            .scaleEffect(pulse ? 1.06 : 1.0)
            .animation(
                isAlert
                    ? .easeInOut(duration: 0.55).repeatForever(autoreverses: true)
                    : .default,
                value: pulse
            )
            .onChange(of: isAlert) { _, alert in
                pulse = alert
            }
            .onAppear { pulse = isAlert }
    }
}

/// 좌측 대형 캔버스(흰 배경 + 채색 + 라인아트 multiply).
/// `Equatable`로 분리 — 팔레트/토스트/최근색 등 캔버스와 무관한 상태가 바뀌어도
/// 도구·도안이 그대로면 이 서브트리(GeometryReader+Canvas) 재평가를 건너뛴다.
private struct CanvasArea: View, Equatable {
    let initialData: Data?
    let lineart: PlatformImage?
    let aspect: CGSize
    var color: Color
    var lineWidth: CGFloat
    var isEraser: Bool
    var tool: BrushTool
    var penOnly: Bool
    let saver: CanvasSaver
    var onPersist: (Data, Data) -> Void

    // ── 줌/팬 콜백 ── Equatable 비교 제외 (렌더 출력에 영향 없음)
    var onPinch: (CGFloat, Bool) -> Void = { _, _ in }
    var onPan: (CGSize, Bool) -> Void = { _, _ in }
    var onZoomReset: () -> Void = {}

    var body: some View {
        ZStack {
            Color.white
            DrawingCanvas(
                initialData: initialData,
                lineart: lineart,
                color: color,
                lineWidth: lineWidth,
                isEraser: isEraser,
                tool: tool,
                penOnly: penOnly,
                saver: saver,
                onPersist: onPersist,
                onPinch: onPinch,
                onPan: onPan,
                onZoomReset: onZoomReset
            )
            if let lineart, let image = Image(platform: lineart) {
                image.resizable().scaledToFit()
                    .blendMode(.multiply)
                    .allowsHitTesting(false)
            }
        }
        .aspectRatio(aspect.width / aspect.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(Theme.cardBorder, lineWidth: 2))
        .shadow(color: Theme.softShadow, radius: 10, x: 0, y: 6)
    }

    /// 렌더 출력에 영향을 주는 값만 비교.
    /// `initialData`/`saver`/`onPersist`/`onPinch`/`onPan`/`onZoomReset` 은
    /// 렌더에 영향 없어 제외 — 콜백이 교체돼도 CanvasArea 서브트리 재렌더 없음.
    static func == (a: CanvasArea, b: CanvasArea) -> Bool {
        a.color == b.color &&
        a.lineWidth == b.lineWidth &&
        a.isEraser == b.isEraser &&
        a.tool == b.tool &&
        a.aspect == b.aspect &&
        a.lineart === b.lineart &&
        a.penOnly == b.penOnly
    }
}

// MARK: - ZoomableCanvasPanel

/// CanvasArea + 줌/팬 상태를 캡슐화한 패널.
///
/// `zoomState` / `canvasCardSize` 를 이 뷰의 `@State`로 격리함으로써,
/// 핀치·팬 프레임(60~120Hz)마다 이 body 만 재평가되고
/// `ColoringCanvasView.body`(topBar · rightColumn · BubbleBackground 등)는
/// 무효화되지 않는다.
private struct ZoomableCanvasPanel: View {
    // CanvasArea 에 그대로 전달할 프로퍼티
    let initialData: Data?
    let lineart: PlatformImage?
    let aspect: CGSize
    var color: Color
    var lineWidth: CGFloat
    var isEraser: Bool
    var tool: BrushTool
    var penOnly: Bool
    let saver: CanvasSaver
    var onPersist: (Data, Data) -> Void

    @State private var zoomState = ZoomPanState()
    /// 캔버스 카드 레이아웃 크기 — 패닝 offset 클램핑 계산에 사용.
    @State private var canvasCardSize: CGSize = .zero

    var body: some View {
        ZStack {
            CanvasArea(
                initialData: initialData,
                lineart: lineart,
                aspect: aspect,
                color: color,
                lineWidth: lineWidth,
                isEraser: isEraser,
                tool: tool,
                penOnly: penOnly,
                saver: saver,
                onPersist: onPersist,
                onPinch: handlePinch,
                onPan: handlePan,
                onZoomReset: handleZoomReset
            )
            .equatable()
            // transform은 CanvasArea 밖에서 적용 → equatable() 서브트리와 독립.
            .scaleEffect(zoomState.scale)
            .offset(zoomState.offset)
            .clipped()

            // 배율 뱃지: 1× 초과일 때만 좌상단에 표시 (디자인 §27-1)
            if zoomState.isZoomed {
                zoomBadge
                    .padding(10)
                    .transition(.opacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        // 캔버스 카드 크기 캡처 — 레이아웃 변경(회전 등) 시에만 발화
        .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasCardSize = $0 }
    }

    // MARK: 줌/팬 핸들러

    /// 핀치 배율 델타(매 프레임 1.0 기준). ended=true 이면 경계 스프링 복귀.
    private func handlePinch(delta: CGFloat, ended: Bool) {
        zoomState.applyPinchDelta(delta, canvasSize: canvasCardSize)
        guard ended else { return }
        if zoomState.scale <= ZoomPanState.minScale + 0.01 {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { zoomState.reset() }
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                zoomState.clampOffset(canvasSize: canvasCardSize)
            }
        }
    }

    /// 패닝 델타(window 좌표계 screen-pt). 1× 상태에선 무시.
    private func handlePan(delta: CGSize, ended: Bool) {
        guard zoomState.isZoomed, !ended else { return }
        zoomState.applyPanDelta(delta, canvasSize: canvasCardSize)
    }

    /// 두 손가락 더블탭 → 스프링 애니메이션으로 1× 원위치 복귀.
    private func handleZoomReset() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { zoomState.reset() }
    }

    /// 배율 뱃지 (scale > 1×일 때만 노출).
    private var zoomBadge: some View {
        let s = zoomState.scale
        let text = abs(s - s.rounded()) < 0.05
            ? "\(Int(s.rounded()))×"
            : String(format: "%.1f×", s)
        return Text(text)
            .font(.system(size: 15, weight: .black, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color(hex: 0x3B3A4E).opacity(0.82)))
            .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
            .accessibilityLabel("확대 \(text)")
    }
}
