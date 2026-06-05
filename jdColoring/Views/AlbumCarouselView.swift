import SwiftUI
import SwiftData

/// 화면 1.5 — 앨범 캐러셀 (디자인 §28).
/// 가운데 큰 카드 + 양옆 잘린 미리보기(coverflow) + 좌우 스와이프 무한 순환.
/// 미분류는 사용자 앨범들 맨 끝에 한 장으로 포함(도안 0개면 제외).
///
/// 성능(검수 increment6 [중간]#1): 드래그 상태(center/drag)는 자식 `AlbumCarouselDeck`이
/// 소유한다. 덕분에 스와이프(매 프레임 drag 변경)가 이 부모를 무효화하지 않아
/// `makeItems()`(allTemplates 전체 순회)가 **드래그 프레임마다 재계산되지 않는다.**
/// 부모 body는 @Query(앨범/도안) 변경·진입/시트 상태 변화에만 재평가된다.
struct AlbumCarouselView: View {
    let profile: Profile
    @Binding var path: [Route]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Query(sort: \Album.createdAt) private var albums: [Album]
    @Query private var allTemplates: [Template]

    @State private var appeared = false
    @State private var exiting = false
    @State private var exitTask: Task<Void, Never>?

    // 앨범 만들기/수정 시트
    @State private var isEditorPresented = false
    @State private var editingAlbum: Album?     // nil = 만들기
    @State private var draftName = ""
    @State private var draftCover: Data?
    // 삭제 확인
    @State private var pendingDelete: Album?

    private let editorAnimation: Animation = .spring(response: 0.5, dampingFraction: 0.82)

    var body: some View {
        ZStack {
            Theme.bgGradient.ignoresSafeArea()
            BubbleBackground()

            let items = makeItems()

            VStack(spacing: 0) {
                topBar(count: items.count)
                    .padding(.top, 30)
                AlbumCarouselDeck(
                    items: items,
                    appeared: appeared,
                    exiting: exiting,
                    onOpen: openGallery,
                    onEdit: presentEdit,
                    onDelete: { pendingDelete = $0 }
                )
            }
            .opacity(isEditorPresented ? 0 : (exiting ? 0 : 1))

            // 우하단 앨범 추가 버튼 (캐러셀과 독립)
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    AddButton(caption: "앨범 추가", action: presentAdd)
                        .padding(.trailing, 40)
                        .padding(.bottom, 32)
                        .opacity(isEditorPresented || exiting ? 0 : (appeared ? 1 : 0))
                        .offset(y: (appeared || reduceMotion) ? 0 : 90)
                        .animation(.spring(response: 0.5, dampingFraction: 0.82).delay(0.1), value: appeared)
                }
            }

            // 앨범 만들기/수정 시트
            if isEditorPresented {
                Color.black.opacity(0.42).ignoresSafeArea().transition(.opacity)
                CategoryEditorView(
                    title: editingAlbum == nil ? "새 앨범 만들기" : "앨범 수정",
                    confirmTitle: editingAlbum == nil ? "만들기" : "저장",
                    name: $draftName,
                    coverData: $draftCover,
                    onCancel: dismissEditor,
                    onSave: saveEditor
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear {
            appeared = false
            Task { @MainActor in appeared = true }
        }
        .onDisappear { exitTask?.cancel() }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog(
            "‘\(pendingDelete?.name ?? "")’ 앨범을 삭제할까요?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { album in
            Button("삭제", role: .destructive) { deleteAlbum(album) }
            Button("취소", role: .cancel) { }
        } message: { _ in
            Text("앨범만 사라지고, 안의 도안은 ‘미분류’로 옮겨져요.")
        }
    }

    // MARK: - Items

    /// 캐러셀에 표시할 항목: 사용자 앨범(생성순) + 미분류(맨 끝, 도안 1개 이상일 때만).
    /// 부모 body에서만 호출(드래그와 무관) — 자식이 drag를 소유하므로 스와이프 시 재계산 안 됨.
    private func makeItems() -> [AlbumItem] {
        var counts: [PersistentIdentifier: Int] = [:]
        var uncategorized = 0
        for t in allTemplates {
            if let a = t.album { counts[a.persistentModelID, default: 0] += 1 }
            else { uncategorized += 1 }
        }
        var result = albums.map { AlbumItem(kind: .album($0), count: counts[$0.persistentModelID] ?? 0) }
        if uncategorized > 0 {
            result.append(AlbumItem(kind: .uncategorized, count: uncategorized))
        }
        return result
    }

    // MARK: - Top bar

    private func topBar(count: Int) -> some View {
        ZStack {
            VStack(spacing: 6) {
                Text("어떤 앨범을 열어볼까요?")
                    .font(Theme.rounded(38, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Text("\(profile.name)의 색칠 앨범 · \(count)개")
                    .font(Theme.rounded(20))
                    .foregroundStyle(Theme.subText)
            }
            HStack {
                backButton
                Spacer()
                profileChip
            }
            .padding(.horizontal, 40)
        }
    }

    private var backButton: some View {
        Button(action: goBack) {
            Image(systemName: "chevron.left")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.ink)
                .frame(width: 60, height: 60)
                .background(Circle().fill(Theme.card))
                .overlay(Circle().stroke(Theme.cardBorder, lineWidth: 2))
                .shadow(color: Theme.softShadow, radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("뒤로")
    }

    private var profileChip: some View {
        HStack(spacing: 12) {
            Text(profile.name)
                .font(Theme.rounded(22, weight: .bold))
                .foregroundStyle(Theme.ink)
            ZStack {
                Circle().fill(Theme.tint(profile.colorIndex))
                if let data = profile.imageData, let image = ThumbnailCache.image(for: data) {
                    image.resizable().scaledToFill().frame(width: 56, height: 56).clipShape(Circle())
                } else {
                    SmileyFace(size: 56)
                }
            }
            .frame(width: 56, height: 56)
            .overlay(Circle().stroke(Theme.ring(profile.colorIndex), lineWidth: 4))
            .shadow(color: Theme.softShadow, radius: 8, x: 0, y: 4)
        }
    }

    // MARK: - Actions

    private func openGallery(_ item: AlbumItem) {
        switch item.kind {
        case .album(let a):  path.append(.gallery(profile, .album(a)))
        case .uncategorized: path.append(.gallery(profile, .uncategorized))
        }
    }

    private func goBack() {
        guard !exiting else { return }
        let dur = reduceMotion ? 0.18 : 0.30
        withAnimation(.easeIn(duration: dur)) { exiting = true }
        exitTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(dur))
            guard !Task.isCancelled else { return }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { dismiss() }
        }
    }

    private func presentAdd() {
        editingAlbum = nil
        draftName = ""
        draftCover = nil
        withAnimation(editorAnimation) { isEditorPresented = true }
    }

    private func presentEdit(_ album: Album) {
        editingAlbum = album
        draftName = album.name
        draftCover = album.coverImageData
        withAnimation(editorAnimation) { isEditorPresented = true }
    }

    private func dismissEditor() {
        withAnimation(editorAnimation) { isEditorPresented = false }
    }

    private func saveEditor() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let album = editingAlbum, album.modelContext != nil {
            album.name = trimmed
            album.coverImageData = draftCover
        } else {
            let new = Album(name: trimmed, coverImageData: draftCover)
            context.insert(new)
        }
        do { try context.save() } catch { print("앨범 저장 실패: \(error)") }
        dismissEditor()
    }

    private func deleteAlbum(_ album: Album) {
        pendingDelete = nil
        // nullify 규칙으로 안의 도안은 미분류로 이동(삭제 안 됨).
        context.delete(album)
        do { try context.save() } catch { print("앨범 삭제 실패: \(error)") }
    }
}

// MARK: - Deck (드래그 상태 소유: center/drag)

/// 캐러셀 카드 덱 + 페이지 도트. center/drag를 **이 뷰가 소유**해, 스와이프가
/// 부모(`AlbumCarouselView`)를 무효화하지 않게 한다(검수 increment6 [중간]#1).
private struct AlbumCarouselDeck: View {
    let items: [AlbumItem]
    let appeared: Bool
    let exiting: Bool
    var onOpen: (AlbumItem) -> Void
    var onEdit: (Album) -> Void
    var onDelete: (Album) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 정착 스크롤 위치(카드 단위, **무한 누적 — wrap 안 함**). 카드가 반대편으로
    /// 순간이동하지 않게 하는 핵심: 가운데 슬롯 = round(scrollIndex).
    @State private var scrollIndex: CGFloat = 0
    /// 라이브 드래그 변위(px).
    @State private var drag: CGFloat = 0

    private let snap: Animation = .spring(response: 0.45, dampingFraction: 0.85)

    var body: some View {
        if items.isEmpty {
            VStack { Spacer(); emptyState; Spacer(); Spacer() }
        } else {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                carousel
                Spacer(minLength: 0)
                footer
                    .padding(.bottom, 28)
            }
        }
    }

    // MARK: Carousel — 가상 슬롯 무한 스크롤

    /// 보이는 자리(슬롯 k)마다 `item = k mod n` 을 그린다. 스와이프하면 슬롯들이 연속으로
    /// 미끄러지고, 한쪽 끝에서 빠지는 카드와 같은 앨범이 **반대 끝에서 새 슬롯으로 등장**한다
    /// (카드가 화면을 가로질러 순간이동하지 않음).
    private var carousel: some View {
        GeometryReader { geo in
            let n = items.count
            // 카드 1.5× 확대(디자인 §28-2): 세로 계수 0.52→0.78. 폭 상한(0.62)은 유지해
            // 세로 모드 과대 확대/겹침 방지. step(0.52) 불변 → 양옆 노출 살짝↑, 겹침 없음.
            let cardH = min(geo.size.height * 0.78, geo.size.width * 0.62)
            let cardW = cardH * 0.83
            let step = geo.size.width * 0.52

            ZStack {
                if n == 1 {
                    // 한 장뿐 → 단독 표시(양옆 복제·순환 없음).
                    card(slot: 0, item: items[0], idx: 0, p: 0, centered: true,
                         cardW: cardW, cardH: cardH, step: step)
                } else {
                    let pos = scrollIndex - drag / step      // 드래그 반영 실효 위치
                    let centerSlot = Int(pos.rounded())
                    ForEach(centerSlot - 3 ... centerSlot + 3, id: \.self) { k in
                        let p = CGFloat(k) - pos             // 0=중앙, ±1=양옆
                        if abs(p) < 2.6 {
                            let idx = ((k % n) + n) % n        // 가상 슬롯 → 실제 앨범
                            card(slot: k, item: items[idx], idx: idx, p: p, centered: abs(p) < 0.5,
                                 cardW: cardW, cardH: cardH, step: step)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(n > 1 ? dragGesture(step: step) : nil)
            .opacity(appeared ? 1 : 0)
            .offset(y: (appeared || reduceMotion) ? 0 : 40)
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: appeared)
        }
    }

    /// 카드 1장. tint는 **실제 앨범 인덱스(idx)** 기준 → 같은 앨범이 양끝에서 크로스페이드돼도 톤 일관.
    /// 가운데(centered)이고 사용자 앨범일 때만 contextMenu(가벼운 preview 명시 — 스냅샷 히치 방지).
    @ViewBuilder
    private func card(slot k: Int, item: AlbumItem, idx: Int, p: CGFloat, centered: Bool,
                      cardW: CGFloat, cardH: CGFloat, step: CGFloat) -> some View {
        let base = AlbumCardView(item: item, width: cardW, height: cardH, tintIndex: idx)
            .scaleEffect(max(0.7, 1 - 0.15 * min(abs(p), 2)))
            .opacity(max(0, 1 - 0.5 * Double(abs(p))))
            .offset(x: p * step)
            .zIndex(2 - Double(abs(p)))
            .onTapGesture { tap(slot: k, centered: centered, item: item) }

        if centered, case let .album(album) = item.kind {
            base
                .contextMenu {
                    Button { onEdit(album) } label: { Label("수정", systemImage: "pencil") }
                    Button(role: .destructive) { onDelete(album) } label: { Label("삭제", systemImage: "trash") }
                } preview: {
                    AlbumCardPreview(item: item)
                }
        } else {
            base
        }
    }

    // MARK: Gesture

    private func dragGesture(step: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { drag = $0.translation.width }
            .onEnded { value in
                // 한 번의 스와이프(반 칸 이상)당 한 칸. 멀리 끌면 그만큼. wrap 없이 무한 누적.
                let endPos = scrollIndex - value.translation.width / step
                withAnimation(snap) {
                    scrollIndex = endPos.rounded()
                    drag = 0
                }
            }
    }

    private func tap(slot k: Int, centered: Bool, item: AlbumItem) {
        if centered {
            onOpen(item)
        } else {
            withAnimation(snap) { scrollIndex = CGFloat(k); drag = 0 }
        }
    }

    // MARK: Footer / empty

    private var footer: some View {
        let count = items.count
        let activeIndex = ((Int(scrollIndex.rounded()) % count) + count) % count
        return VStack(spacing: 14) {
            if count > 1 {
                HStack(spacing: 10) {
                    ForEach(0..<count, id: \.self) { i in
                        let active = i == activeIndex
                        Capsule()
                            .fill(active ? Theme.coral : Color(hex: 0xD8C9BA))
                            .frame(width: active ? 30 : 12, height: 12)
                    }
                }
                Text("‹ 좌우로 넘겨 앨범을 골라요 · 끝에서 다시 처음으로 ›")
                    .font(Theme.rounded(18, weight: .semibold))
                    .foregroundStyle(Theme.faintText)
            }
        }
        .opacity(appeared && !exiting ? 1 : 0)
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            ZStack {
                RoundedRectangle(cornerRadius: 36)
                    .strokeBorder(style: StrokeStyle(lineWidth: 4, dash: [14, 12]))
                    .foregroundStyle(Color(hex: 0xE4D5C6))
                    .frame(width: 300, height: 230)
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.system(size: 70))
                    .foregroundStyle(Theme.coral.opacity(0.85))
            }
            VStack(spacing: 8) {
                Text("아직 앨범이 없어요")
                    .font(Theme.rounded(30, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Text("오른쪽 아래 ＋ 버튼으로 앨범을 만들어요")
                    .font(Theme.rounded(20))
                    .foregroundStyle(Theme.subText)
            }
        }
    }
}

// MARK: - Album item + card

/// 캐러셀 한 칸: 사용자 앨범 또는 미분류.
private struct AlbumItem {
    enum Kind {
        case album(Album)
        case uncategorized
    }
    let kind: Kind
    let count: Int

    var name: String {
        switch kind {
        case .album(let a):  return a.name
        case .uncategorized: return "미분류"
        }
    }
    var coverData: Data? {
        switch kind {
        case .album(let a):  return a.coverImageData
        case .uncategorized: return nil
        }
    }
    var isUncategorized: Bool {
        if case .uncategorized = kind { return true }
        return false
    }
    /// 커버 영역 파스텔 톤(앨범마다 약간씩 다르게).
    static let coverTints: [UInt] = [0xFFE9CF, 0xFFEBF3, 0xE6F0FF, 0xE3F6EC, 0xF1E9FF, 0xFFF6D9]
}

/// 앨범 카드 — 대표 이미지(또는 플레이스홀더) + 이름 + 도안 개수.
private struct AlbumCardView: View {
    let item: AlbumItem
    let width: CGFloat
    let height: CGFloat
    let tintIndex: Int

    private var coverTint: Color {
        item.isUncategorized ? Color(hex: 0xF3EEE7)
                             : Color(hex: AlbumItem.coverTints[tintIndex % AlbumItem.coverTints.count])
    }

    var body: some View {
        let coverH = height * 0.66
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 30).fill(coverTint)
                if let data = item.coverData, let image = ThumbnailCache.image(for: data) {
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: width - 40, height: coverH - 8)
                        .clipShape(RoundedRectangle(cornerRadius: 30))
                } else {
                    Image(systemName: item.isUncategorized ? "tray.full" : "rectangle.stack")
                        .font(.system(size: coverH * 0.32, weight: .regular))
                        .foregroundStyle(Color(hex: 0xB6A89B))
                }
            }
            .frame(width: width - 40, height: coverH)
            .padding(.top, 20)

            Spacer(minLength: 0)

            Text(item.name)
                .font(Theme.rounded(min(34, height * 0.085), weight: .heavy))
                .foregroundStyle(item.isUncategorized ? Theme.subText : Theme.ink)
                .lineLimit(1)
            Text("\(item.count)개 도안")
                .font(Theme.rounded(min(20, height * 0.05)))
                .foregroundStyle(Theme.subText)
                .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .frame(width: width, height: height)
        .background(RoundedRectangle(cornerRadius: 40).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 40).stroke(Theme.cardBorder, lineWidth: 2))
        .shadow(color: Theme.softShadow, radius: 22, x: 0, y: 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), 도안 \(item.count)개")
    }
}

/// 롱프레스 lift 프리뷰 — 큰 그림자 없이 가벼운 카드(자동 스냅샷 히치 방지).
private struct AlbumCardPreview: View {
    let item: AlbumItem

    private var coverTint: Color {
        item.isUncategorized ? Color(hex: 0xF3EEE7) : Color(hex: 0xFFE9CF)
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 24).fill(coverTint)
                if let data = item.coverData, let image = ThumbnailCache.image(for: data) {
                    image.resizable().scaledToFill()
                        .frame(width: 200, height: 170)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                } else {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 56))
                        .foregroundStyle(Color(hex: 0xB6A89B))
                }
            }
            .frame(width: 200, height: 170)
            Text(item.name)
                .font(Theme.rounded(24, weight: .heavy))
                .foregroundStyle(Theme.ink)
        }
        .padding(20)
        .frame(width: 240, height: 270)
        .background(Color.white)
    }
}
