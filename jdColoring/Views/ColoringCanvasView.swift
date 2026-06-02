import SwiftUI
import SwiftData

/// 화면 3 — 색칠 캔버스. 도안 위에 브러시로 색칠, 진행 자동 저장.
struct ColoringCanvasView: View {
    let profile: Profile
    let template: Template

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

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

    private let panelAnimation: Animation = .spring(response: 0.42, dampingFraction: 0.86)

    init(profile: Profile, template: Template) {
        self.profile = profile
        self.template = template
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
        }
        .onDisappear { saver.flush() }
        .alert("‘\(template.name)’의 색칠을 모두 지울까요?", isPresented: $showResetConfirm) {
            Button("취소", role: .cancel) {}
            Button("초기화", role: .destructive) { performReset() }
        } message: {
            Text("지운 색칠은 되돌릴 수 없어요")
        }
        .navigationBarBackButtonHidden(true)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    // MARK: - Sections

    /// 슬림 상단: 좌측 뒤로가기 + 작은 도안명, 중앙에 잠깐 뜨는 "저장됨" 토스트.
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
            VStack(spacing: 4) {
                Image(systemName: "trash")
                    .font(.system(size: 26))
                    .foregroundStyle(Color(hex: 0x6E6258))
                    .frame(width: 96, height: 96)
                    .background(Circle().fill(Theme.card))
                    .overlay(Circle().stroke(Theme.cardBorder, lineWidth: 2))
                    .shadow(color: Theme.softShadow, radius: 11, x: 0, y: 7)
                Text("초기화").font(Theme.rounded(13, weight: .semibold)).foregroundStyle(Theme.subText)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("색칠 초기화")
    }

    /// 우측 세로 툴 레일: 현재색 · 색 · 굵기 · 지우개 (최근색은 펼침 패널로).
    private var rightRail: some View {
        VStack(spacing: 16) {
            Circle().fill(selectedColor)
                .frame(width: 50, height: 50)
                .overlay(Circle().stroke(Theme.ink, lineWidth: 3.5))

            railDivider
            Button {
                withAnimation(panelAnimation) { paletteOpen = true }
            } label: {
                VStack(spacing: 6) {
                    paletteIcon
                    Text("색").font(Theme.rounded(14, weight: .bold))
                        .foregroundStyle(paletteOpen ? Theme.coral : Color(hex: 0x7A6E64))
                }
                .padding(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(paletteOpen ? Theme.coral : .clear, lineWidth: 2.5)
                )
            }
            .buttonStyle(.plain)

            railDivider
            toolToggle

            railDivider
            VStack(spacing: 10) {
                ForEach(Array(Palette.brushWidths.enumerated()), id: \.offset) { _, w in
                    Button { brushWidth = w } label: {
                        Circle().fill(Theme.ink)
                            .frame(width: w * 0.7 + 6, height: w * 0.7 + 6)
                            .padding(7)
                            .overlay(Circle().stroke(brushWidth == w ? Theme.coral : .clear, lineWidth: 3))
                    }
                    .buttonStyle(.plain)
                }
                Text("굵기").font(Theme.rounded(13, weight: .semibold)).foregroundStyle(Theme.subText)
            }

            railDivider
            Button { isEraser.toggle() } label: {
                VStack(spacing: 4) {
                    Image(systemName: "eraser.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(isEraser ? Theme.coral : Theme.ink)
                        .frame(width: 50, height: 44)
                        .background(RoundedRectangle(cornerRadius: 14).fill(isEraser ? Theme.coral.opacity(0.15) : .clear))
                    Text("지우개").font(Theme.rounded(13, weight: .semibold)).foregroundStyle(Theme.subText)
                }
            }
            .buttonStyle(.plain)
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

    private var paletteIcon: some View {
        let cells: [Color] = [Theme.coral, Color(hex: 0xFFC740), Color(hex: 0x36C5C0), Color(hex: 0x8A6CFF)]
        return VStack(spacing: 3) {
            HStack(spacing: 3) { cell(cells[0]); cell(cells[1]) }
            HStack(spacing: 3) { cell(cells[2]); cell(cells[3]) }
        }
        .frame(height: 34)
    }
    private func cell(_ c: Color) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(c).frame(width: 14, height: 14)
    }

    /// 도구 전환 — 마커(단색) ↔ 색연필(질감). 디자인 §18-1. 활성 도구는 코랄 강조.
    private var toolToggle: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                toolButton(.marker, symbol: "highlighter")
                toolButton(.pencil, symbol: "pencil")
            }
            Text("도구").font(Theme.rounded(13, weight: .semibold)).foregroundStyle(Theme.subText)
        }
    }

    private func toolButton(_ t: BrushTool, symbol: String) -> some View {
        let active = tool == t && !isEraser
        return Button {
            tool = t
            isEraser = false
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(active ? Theme.coral : Theme.ink)
                .frame(width: 28, height: 38)
                .background(RoundedRectangle(cornerRadius: 10).fill(active ? Theme.coral.opacity(0.12) : .clear))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(active ? Theme.coral : Theme.cardBorder, lineWidth: active ? 2.5 : 1.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t == .marker ? "마커" : "색연필")
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
