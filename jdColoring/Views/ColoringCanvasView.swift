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
    @State private var recentColors: [Color] = []
    @State private var paletteOpen = false
    @State private var lineImage: PlatformImage?
    @State private var saver = CanvasSaver()

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
                topBar.padding(.top, 30)
                Spacer(minLength: 12)
                canvasCard.padding(.horizontal, 40)
                Spacer(minLength: 12)
                dock.padding(.bottom, 26)
            }

            if paletteOpen { palettePopover }
        }
        .onAppear {
            if lineImage == nil { lineImage = PlatformImage(data: template.imageData) }
        }
        .onDisappear { saver.flush() }
        .navigationBarBackButtonHidden(true)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    // MARK: - Sections

    private var topBar: some View {
        ZStack {
            VStack(spacing: 4) {
                Text("\(template.name) 색칠하기")
                    .font(Theme.rounded(30, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Text("색칠하면 자동으로 저장돼요")
                    .font(Theme.rounded(17))
                    .foregroundStyle(Theme.subText)
            }
            HStack {
                Button { saver.flush(); dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 60, height: 60)
                        .background(Circle().fill(Theme.card))
                        .overlay(Circle().stroke(Theme.cardBorder, lineWidth: 2))
                        .shadow(color: Theme.softShadow, radius: 8, x: 0, y: 4)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 40)
        }
    }

    private var canvasCard: some View {
        ZStack {
            Color.white
            DrawingCanvas(
                initialData: existing?.progressData,
                lineart: lineImage,
                color: selectedColor,
                lineWidth: brushWidth,
                isEraser: isEraser,
                saver: saver,
                onPersist: persist
            )
            if let img = lineImage, let image = Image(platform: img) {
                image.resizable().scaledToFit()
                    .blendMode(.multiply)
                    .allowsHitTesting(false)
            }
        }
        .aspectRatio(aspect.width / aspect.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(Theme.cardBorder, lineWidth: 2))
        .shadow(color: Theme.softShadow, radius: 10, x: 0, y: 6)
        .frame(maxWidth: 900, maxHeight: 520)
    }

    private var dock: some View {
        HStack(spacing: 18) {
            // 현재 색 + 최근색
            HStack(spacing: 12) {
                Circle().fill(selectedColor)
                    .frame(width: 52, height: 52)
                    .overlay(Circle().stroke(Theme.ink, lineWidth: 3.5))
                ForEach(Array(recentColors.prefix(6).enumerated()), id: \.offset) { _, c in
                    Button { pick(c) } label: {
                        Circle().fill(c).frame(width: 34, height: 34)
                            .overlay(Circle().stroke(Color(hex: 0xE6DDD3), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }

            divider
            // 색 펼치기
            Button { paletteOpen = true } label: {
                VStack(spacing: 6) {
                    paletteIcon
                    Text("색").font(Theme.rounded(14, weight: .bold)).foregroundStyle(Color(hex: 0x7A6E64))
                }
            }
            .buttonStyle(.plain)

            divider
            // 브러시 굵기
            HStack(spacing: 14) {
                ForEach(Array(Palette.brushWidths.enumerated()), id: \.offset) { _, w in
                    Button { brushWidth = w; isEraser = false } label: {
                        Circle().fill(Theme.ink)
                            .frame(width: w * 0.7 + 6, height: w * 0.7 + 6)
                            .padding(8)
                            .overlay(Circle().stroke(brushWidth == w && !isEraser ? Theme.coral : .clear, lineWidth: 3))
                    }
                    .buttonStyle(.plain)
                }
            }

            divider
            // 지우개
            Button { isEraser.toggle() } label: {
                Image(systemName: "eraser.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(isEraser ? Theme.coral : Theme.ink)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(isEraser ? Theme.coral.opacity(0.15) : .clear))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .background(Capsule().fill(Theme.card))
        .shadow(color: Theme.softShadow, radius: 11, x: 0, y: 7)
    }

    private var divider: some View {
        Rectangle().fill(Theme.cardBorder).frame(width: 2, height: 44)
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

    private var palettePopover: some View {
        ZStack {
            Color.black.opacity(0.2).ignoresSafeArea()
                .onTapGesture { paletteOpen = false }
            ColorPaletteGrid(selected: selectedColor) { color in
                pick(color)
                paletteOpen = false
            }
        }
        .transition(.opacity)
    }

    // MARK: - Actions

    private func pick(_ color: Color) {
        selectedColor = color
        isEraser = false
        recentColors.removeAll { $0 == color }
        recentColors.insert(color, at: 0)
        if recentColors.count > 6 { recentColors = Array(recentColors.prefix(6)) }
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
    }
}
