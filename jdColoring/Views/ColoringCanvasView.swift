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
                    ZStack {
                        CanvasArea(
                            initialData: existing?.progressData,
                            lineart: lineImage,
                            aspect: aspect,
                            color: selectedColor,
                            lineWidth: brushWidth,
                            isEraser: isEraser,
                            tool: tool,
                            saver: saver,
                            onPersist: persist
                        )
                        .equatable()
                    }
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
            if timerEnd == nil, let end = peerSession.receivedTimerEnd {
                timerEnd = end
            }
        }
        .onDisappear { saver.flush() }
        // C-1: 타이머가 없을 때는 state 갱신 안 함 → body 불필요 재평가 차단
        .onReceive(clockTimer) { date in
            guard timerEnd != nil else { return }
            timerNow = date
        }
        .onChange(of: peerSession.receivedTimerEnd) { _, end in
            timerExpired = false   // 새 타이머 시작/취소 시 expired 초기화
            withAnimation(.easeInOut(duration: 0.3)) { timerEnd = end }
        }
        // C-2: expired 플래그로 만료 진입점 단일화 (onDisappear flush와 중복 방지)
        // MAJOR-1: flush 완료 후 화면 전환 → 마지막 색칠 보장
        // MINOR-1: withAnimation으로 전환 부드럽게
        .onChange(of: timerRemaining) { _, rem in
            guard let rem, rem <= 0, !timerExpired else { return }
            timerExpired = true
            timerEnd = nil
            saver.flushThen {
                withAnimation { path.removeAll() }
            }
        }
        // MAJOR-2: 포그라운드 복귀 즉시 timerNow 갱신 → 백그라운드 중 만료된 타이머 즉시 반영
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, timerEnd != nil {
                timerNow = Date()
            }
        }
        .alert("’\(template.name)’의 색칠을 모두 지울까요?", isPresented: $showResetConfirm) {
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
                Text(template.name)
                    .font(Theme.rounded(22, weight: .bold))
                    .foregroundStyle(Theme.ink)
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

    /// 우측 열: 툴 레일 + 그 아래 색칠 초기화(휴지통) 버튼.
    private var rightColumn: some View {
        VStack(spacing: 16) {
            rightRail
            resetButton
        }
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
    let saver: CanvasSaver
    var onPersist: (Data, Data) -> Void

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
                saver: saver,
                onPersist: onPersist
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

    /// 렌더 출력에 영향을 주는 값만 비교. `initialData`/`saver`/`onPersist`는
    /// 최초 1회 `configure`에만 쓰이고(엔진이 이후 자체 보유) 출력에 영향 없어 제외.
    static func == (a: CanvasArea, b: CanvasArea) -> Bool {
        a.color == b.color &&
        a.lineWidth == b.lineWidth &&
        a.isEraser == b.isEraser &&
        a.tool == b.tool &&
        a.aspect == b.aspect &&
        a.lineart === b.lineart
    }
}
