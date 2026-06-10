import SwiftUI
import SwiftData

/// 화면 2 — 색칠 도안 갤러리. 앨범(또는 미분류)을 선택해 진입.
struct GalleryView: View {
    let profile: Profile
    let selection: AlbumSelection
    @Binding var path: [Route]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// 선택된 앨범의 도안만 (init에서 selection 기준 predicate 주입).
    @Query private var templates: [Template]
    @Query private var allArtworks: [Artwork]
    /// 업로드/이동 시 앨범 선택용 (생성순).
    @Query(sort: \Album.createdAt) private var categories: [Album]

    /// 진입 연출 트리거(G1 §12): 프로필이 흩어진 뒤 카드가 밑에서 우수수 올라온다.
    @State private var appeared = false
    /// 뒤로가기 연출(진입의 역): 타이틀 위로 + 카드·버튼 아래로 빠진 뒤 pop.
    @State private var exiting = false
    /// 빠짐→pop 동기화 작업(취소 가능 — dangling dismiss 방지).
    @State private var exitTask: Task<Void, Never>?
    @State private var isUploadPresented = false
    @State private var pendingDelete: Template?
    @State private var renameTarget: Template?
    @State private var renameText = ""
    /// [앨범 이동] 대상 (nil = 미표시). 선택 시 confirmationDialog로 대상 앨범 고름.
    @State private var moveTarget: Template?

    /// 정렬(편집) 모드 — 카드를 끌어 순서를 바꾼다(§도안 정렬).
    @State private var isReordering = false
    /// 정렬 모드 중 로컬 순서. 드래그로 라이브 변경되고, '완료'/이탈 시 sortOrder 로 1회 커밋.
    @State private var reorderIDs: [PersistentIdentifier] = []
    /// 정렬 진입 시점의 id→도안 매핑 캐시. 드래그 reflow마다 dict를 재구축하지 않도록 1회만 만든다(검수 M-2).
    @State private var reorderByID: [PersistentIdentifier: Template] = [:]
    /// 현재 끌고 있는 도안(빈 자리 표시·히트 판정용).
    @State private var draggingID: PersistentIdentifier?
    /// 끌고 있는 카드를 띄울 위치(그리드 좌표, 손가락 추적). 플로팅 오버레이가 여기에 그려진다.
    @State private var dragLocation: CGPoint = .zero
    /// 끌고 있는 카드의 크기(진입 시 1회 캡처). 플로팅 오버레이가 cellFrames 를 안 읽게 분리(검수 H-2).
    @State private var draggedSize: CGSize = .zero
    /// 셀별 그리드 좌표 프레임(히트 판정 전용). 참조 타입이라 갱신해도 body 를 깨우지 않음(검수 H-2).
    @State private var frameStore = FrameStore()
    /// 정렬 진입 시 작업물 매핑 스냅샷(검수 H-1). 드래그 중 body 재평가마다 전체 재구축하지 않게.
    @State private var reorderLookup: [PersistentIdentifier: Artwork] = [:]
    /// 드래그 히트 판정·플로팅 위치 계산에 쓰는 좌표 공간 이름.
    private let gridSpace = "galleryGrid"

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 240), spacing: 44)]
    private let sheetAnimation: Animation = .spring(response: 0.5, dampingFraction: 0.82)

    /// 현재 보고 있는 앨범(미분류면 nil) — 업로드 시 기본 앨범으로 쓴다.
    private var currentAlbum: Album? {
        if case .album(let a) = selection { return a }
        return nil
    }

    /// 보호된 시스템 앨범('한글') 보기 중인가 — 추가 버튼 숨김·도안 보호(디자인 §32-2).
    private var isSystemAlbum: Bool { currentAlbum?.isSystem ?? false }

    /// 업로드/앨범이동 대상 후보 — 시스템 앨범('한글')은 제외(사용자 도안을 넣지 못하게).
    private var selectableAlbums: [Album] { categories.filter { !$0.isSystem } }

    /// '정렬' 버튼 노출 조건: 비시스템 앨범 + 도안 2개 이상(§도안 정렬 — 시스템 앨범은 자모/알파벳 순 잠금).
    private var canReorder: Bool { !isSystemAlbum && templates.count >= 2 }

    /// 표시 순서 — 정렬 모드에선 로컬 순서(reorderIDs), 평상시엔 쿼리 순서(sortOrder).
    /// reorderIDs·reorderByID 는 진입 시 `templates` 스냅샷이라(정렬 중 write 없음) compactMap 1회면 충분.
    private var displayTemplates: [Template] {
        guard isReordering else { return templates }
        return reorderIDs.compactMap { reorderByID[$0] }
    }

    init(profile: Profile, selection: AlbumSelection, path: Binding<[Route]>) {
        self.profile = profile
        self.selection = selection
        self._path = path
        // 검수 increment4 #3: 전체 작업물을 가져와 거르지 않고, 현재 프로필 것만 fetch.
        let pid = profile.persistentModelID
        _allArtworks = Query(filter: #Predicate<Artwork> { $0.profile?.persistentModelID == pid })
        // 선택된 앨범(또는 미분류)의 도안만 가져온다.
        // 수동 정렬: sortOrder 오름차순 + 동률(백필 전 0) 시 createdAt 폴백 (§도안 정렬).
        let order: [SortDescriptor<Template>] = [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
        switch selection {
        case .uncategorized:
            _templates = Query(filter: #Predicate<Template> { $0.album == nil }, sort: order)
        case .album(let album):
            let aid = album.persistentModelID
            _templates = Query(filter: #Predicate<Template> { $0.album?.persistentModelID == aid }, sort: order)
        }
    }

    /// 작업물을 도안별로 빠르게 찾기 위한 매핑 (allArtworks는 이미 현재 프로필로 한정됨).
    /// ⚠️ computed이므로 호출마다 재계산된다 → body 경로에서는 `grid`에서 1회만 계산해 쓴다(검수 #2).
    private var artworkByTemplate: [PersistentIdentifier: Artwork] {
        var dict: [PersistentIdentifier: Artwork] = [:]
        for art in allArtworks {
            if let t = art.template { dict[t.persistentModelID] = art }
        }
        return dict
    }

    var body: some View {
        ZStack {
            Theme.bgGradient.ignoresSafeArea()
            BubbleBackground()

            VStack(spacing: 0) {
                topBar
                    .padding(.top, 30)
                    .opacity(isUploadPresented ? 0 : (appeared ? 1 : 0))    // 진입 시 위에서 내려오며 등장
                    .offset(y: (appeared || reduceMotion) ? 0 : -30)
                    .animation(.spring(response: 0.5, dampingFraction: 0.85), value: appeared)
                    .opacity(exiting ? 0 : 1)                                // 뒤로가기 시 위로 빠짐
                    .offset(y: (exiting && !reduceMotion) ? -40 : 0)

                Group {
                    if templates.isEmpty {
                        if isSystemAlbum { systemPreparingState } else { emptyState }
                    } else {
                        grid
                    }
                }
                .opacity(exiting ? 0 : 1)        // 뒤로가기 시 카드가 아래로 빠짐
                .offset(y: (exiting && !reduceMotion) ? 80 : 0)
            }

            // 우하단 추가 버튼 — 보호된 시스템 앨범('한글')·정렬 모드에는 표시하지 않음(디자인 §32-2, §34-2).
            if !isSystemAlbum && !isReordering {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        AddButton(caption: "도안 추가", action: presentUpload)
                            .padding(.trailing, 40)
                            .padding(.bottom, 32)
                            .opacity(isUploadPresented ? 0 : (appeared ? 1 : 0))   // 진입 시 밑에서 올라옴
                            .offset(y: (appeared || reduceMotion) ? 0 : 90)
                            .animation(.spring(response: 0.5, dampingFraction: 0.82).delay(0.12), value: appeared)
                            .opacity(exiting ? 0 : 1)                              // 뒤로가기 시 아래로 빠짐
                            .offset(y: (exiting && !reduceMotion) ? 120 : 0)
                    }
                }
            }

            // 업로드 시트 (아래에서 등장)
            if isUploadPresented {
                Color.black.opacity(0.28).ignoresSafeArea()
                    .transition(.opacity)
                TemplateUploadView(albums: selectableAlbums, initialAlbum: currentAlbum, onCancel: dismissUpload) { name, image, thumb, album in
                    saveTemplate(name, image, thumb, album: album)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // 백그라운드 전환·전화 등으로 드래그 제스처가 끊기면 onEnded가 안 올 수 있다 → 활성 이탈 시 강제 해제.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { clearDrag() }
        }
        .onAppear {
            appeared = false
            Task { @MainActor in appeared = true }
        }
        .onDisappear {
            exitTask?.cancel()                // 외부 요인 pop 시 늦은 dismiss 취소
            if isReordering { commitReorder() }   // 정렬 모드 중 이탈 시 순서 보존(1회 저장)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        // 도안 삭제 확인 (공유 도안 → 강한 경고)
        .alert(
            "‘\(pendingDelete?.name ?? "")’ 도안을 삭제할까요?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { template in
            Button("삭제", role: .destructive) { deleteTemplate(template) }
            Button("취소", role: .cancel) { }
        } message: { _ in
            Text("이 도안과 모든 식구의 색칠 작업물이 함께 사라져요. 되돌릴 수 없어요.")
        }
        // 이름 수정 얼럿 — iOS 16+에서 alert 안 TextField 지원
        .alert("이름 수정", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil; renameText = "" } }
        )) {
            TextField("도안 이름 (선택)", text: $renameText)
            Button("저장") { commitRename() }
            Button("취소", role: .cancel) { renameTarget = nil }
        } message: {
            Text("이름을 비워두면 이름이 표시되지 않아요")
        }
        // 앨범 이동 — 대상 앨범(또는 미분류) 선택
        .confirmationDialog(
            "어느 앨범으로 옮길까요?",
            isPresented: Binding(get: { moveTarget != nil },
                                 set: { if !$0 { moveTarget = nil } }),
            titleVisibility: .visible,
            presenting: moveTarget
        ) { template in
            ForEach(selectableAlbums) { album in
                if album.persistentModelID != template.album?.persistentModelID {
                    Button(album.name) { moveTemplate(template, to: album) }
                }
            }
            if template.album != nil {
                Button("미분류") { moveTemplate(template, to: nil) }
            }
            Button("취소", role: .cancel) { }
        }
    }

    // MARK: - Sections

    private var topBar: some View {
        ZStack {
            VStack(spacing: 6) {
                Text(isReordering ? "끌어서 순서 바꾸기" : "무엇을 색칠해볼까요?")
                    .font(Theme.rounded(38, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Text(isReordering ? "원하는 자리로 카드를 옮겨요"
                                  : "\(profile.name) · \(selection.title) · \(templates.count)개")
                    .font(Theme.rounded(20))
                    .foregroundStyle(Theme.subText)
            }
            HStack(spacing: 14) {
                backButton
                    .disabled(isReordering)               // 정렬 중엔 '완료'로 먼저 나가게
                    .opacity(isReordering ? 0.4 : 1)
                if canReorder || isReordering { sortButton }
                Spacer()
                profileChip
                    .opacity(isReordering ? 0.4 : 1)
            }
            .padding(.horizontal, 40)
        }
    }

    /// '정렬'(아웃라인) ↔ '완료'(코랄) 토글 버튼. 좌상단 뒤로가기 옆(디자인 §34-1/2).
    private var sortButton: some View {
        Button(action: toggleReorder) {
            HStack(spacing: 8) {
                if isReordering {
                    Text("완료")
                        .font(Theme.rounded(20, weight: .heavy))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.coral)
                    Text("정렬")
                        .font(Theme.rounded(19, weight: .bold))
                        .foregroundStyle(Theme.ink)
                }
            }
            .padding(.horizontal, 22)
            .frame(height: 52)
            .background(Capsule().fill(isReordering ? Theme.coral : Theme.card))
            .overlay(Capsule().stroke(isReordering ? Color.clear : Theme.cardBorder, lineWidth: 2))
            .shadow(color: Theme.softShadow, radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isReordering ? "정렬 완료" : "도안 정렬")
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

    private var grid: some View {
        // 검수 #2: 매 셀 접근마다 재계산되지 않도록 매핑을 1회만 계산해 재사용.
        // 정렬 중에는 진입 시 뜬 스냅샷(reorderLookup)을 써서 body 재평가마다 전체 재구축을 피한다(검수 H-1).
        let lookup = isReordering ? reorderLookup : artworkByTemplate
        let items = displayTemplates
        return ScrollView {
            ZStack(alignment: .topLeading) {
                LazyVGrid(columns: columns, spacing: 44) {
                    ForEach(Array(items.enumerated()), id: \.element.persistentModelID) { index, template in
                        cell(template, artwork: lookup[template.persistentModelID], index: index)
                    }
                }
                // 끌고 있는 카드는 그리드 흐름에선 빈 칸(opacity 0)이고, 여기 플로팅 오버레이가 손가락을 따라 떠다닌다.
                floatingCard(lookup: lookup)
            }
            .coordinateSpace(name: gridSpace)
            // 정렬 모드에서만 컨테이너에 단일 드래그 제스처. 평상시(.subviews)엔 셀 버튼/롱프레스가 동작.
            .gesture(gridReorderGesture, including: isReordering ? .all : .subviews)
            .padding(.horizontal, 60)
            .padding(.top, 40)
            .padding(.bottom, 150)
            // 참조 컨테이너에 저장 → 갱신해도 body 재평가를 유발하지 않음(reflow 매 프레임 churn 제거 — 검수 H-2).
            .onPreferenceChange(CellFramePreference.self) { frameStore.frames = $0 }
        }
        // 정렬 모드에선 스크롤을 꺼 컨테이너 드래그(즉시 잡기)와 충돌하지 않게 한다.
        .scrollDisabled(isUploadPresented || isReordering)
        // 카드가 잡히는 순간(nil→id) 햅틱 '톡' — "이제 옮길 수 있어요" 신호(햅틱 없는 기기에선 무시).
        .sensoryFeedback(trigger: draggingID) { old, new in
            (old == nil && new != nil) ? .impact(weight: .medium) : nil
        }
    }

    /// 끌고 있는 카드의 플로팅 오버레이 — 그리드 좌표 `dragLocation`(손가락)에 떠서 따라온다.
    /// 잡히는 순간 **확 떠오르며(scale 1.12) 코랄 글로우 + 깊은 그림자**로 "이제 옮길 수 있어요"를 알린다(§34-2).
    @ViewBuilder
    private func floatingCard(lookup: [PersistentIdentifier: Artwork]) -> some View {
        if let id = draggingID, let t = reorderByID[id], draggedSize != .zero {
            TemplateCellView(template: t, artwork: lookup[id])
                .frame(width: draggedSize.width, height: draggedSize.height)
                .scaleEffect(1.12)
                .shadow(color: Theme.coral.opacity(0.45), radius: 14, x: 0, y: 6)   // 코랄 글로우 = "잡힘(활성)"
                .shadow(color: Theme.softShadow, radius: 20, x: 0, y: 16)            // 깊은 그림자 = 떠 있음
                .position(dragLocation)
                .allowsHitTesting(false)
        }
    }

    /// 도안 셀 + 탭(열기) + 롱프레스 컨텍스트 메뉴.
    /// - 탭과 롱프레스가 같은 뷰에서 충돌해 롱프레스 확정이 지연되던 문제 →
    ///   `Button`으로 탭을 분리해 제스처 조율을 시스템에 맡긴다.
    /// - iOS는 `preview:`를 명시한다. 미지정 시 iOS가 그림자 블러까지 포함한 셀을
    ///   오프스크린 스냅샷(메인 스레드 동기)하느라 롱프레스 후 메뉴가 수 초 늦게 떴다.
    ///   캐시된 썸네일만 그리는 가벼운 프리뷰로 그 비용을 제거한다.
    ///   캐시된 썸네일만 그리는 가벼운 프리뷰를 명시한다.
    @ViewBuilder
    private func cell(_ template: Template, artwork: Artwork?, index: Int) -> some View {
        if isReordering {
            reorderCell(template, artwork: artwork, index: index)
        } else {
            normalCell(template, artwork: artwork, index: index)
        }
    }

    @ViewBuilder
    private func normalCell(_ template: Template, artwork: Artwork?, index: Int) -> some View {
        let base = Button { openColoring(template) } label: {
            TemplateCellView(template: template, artwork: artwork)
        }
        .buttonStyle(.plain)
        .gridEntrance(index: index, visible: appeared)

        // 보호 도안('한글')이 아직 색칠 전이면 메뉴 항목이 없다 → 빈 메뉴를 띄우지 않게 contextMenu 자체를 생략.
        if template.isSystem && artwork == nil {
            base
        } else {
            base.contextMenu { menuItems(for: template, hasArtwork: artwork != nil) } preview: {
                TemplateMenuPreview(template: template, artwork: artwork)
            }
        }
    }

    /// 정렬 모드 셀 — 탭(색칠 진입)·롱프레스 메뉴 없이 jiggle + 빈칸(opacity 0) 표시.
    /// 드래그 제스처는 셀이 아니라 **그리드 컨테이너**에 하나만 둔다(reorder 시 셀이 이동해도
    /// 제스처 소유 뷰가 안 바뀌어 매번 재인식됨). 끌고 있는 셀은 플로팅 오버레이가 손가락을 따라간다.
    private func reorderCell(_ template: Template, artwork: Artwork?, index: Int) -> some View {
        let id = template.persistentModelID
        return TemplateCellView(template: template, artwork: artwork)
            .opacity(draggingID == id ? 0 : 1)
            .jiggle(active: draggingID != id, index: index, reduceMotion: reduceMotion)
            .background(frameReporter(id))               // 그리드 좌표 프레임 보고(히트 판정용)
    }

    /// 셀의 그리드 좌표 프레임을 `CellFramePreference`로 올린다.
    private func frameReporter(_ id: PersistentIdentifier) -> some View {
        GeometryReader { geo in
            Color.clear.preference(key: CellFramePreference.self,
                                   value: [id: geo.frame(in: .named(gridSpace))])
        }
    }

    /// 그리드 컨테이너에 붙는 단일 드래그 제스처. 정렬 모드에선 스크롤이 꺼져 있어, 카드를 만지는 즉시
    /// (첫 onChanged, minimumDistance 0) 그 자리 카드를 들어 올리고(lift+pop+햅틱) 손가락을 따라 라이브 재배치.
    /// `onEnded`가 손 뗄 때 반드시 불려 정리한다(stuck 방지). 컨테이너(위치 고정)라 reorder로 셀이 이동해도 매번 재인식.
    private var gridReorderGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(gridSpace))
            .onChanged { value in
                if draggingID == nil {
                    // 만지는 즉시 그 자리 카드를 집어 올린다(편집 모드 직접 조작).
                    guard let picked = cellID(at: value.startLocation) else { return }
                    beginLift(picked, at: value.location)
                }
                guard let dragged = draggingID else { return }
                dragLocation = value.location
                // 재배치 대상은 중심 최근접으로(검수 M-1): reflow 중 프레임 겹침에서도 결정적 — first(contains) 비결정성 제거.
                if let target = nearestCellID(to: value.location), target != dragged {
                    moveReorder(dragged, over: target)
                }
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { draggingID = nil }
            }
    }

    private func beginLift(_ id: PersistentIdentifier, at location: CGPoint) {
        guard draggingID != id else { return }
        draggedSize = frameStore.frames[id]?.size ?? .zero   // 플로팅 카드 크기 1회 캡처(검수 H-2)
        dragLocation = location
        withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) { draggingID = id }
    }

    /// 그리드 좌표 `point` 를 **포함**하는 셀의 id(픽업용 — 빈 영역을 만지면 nil).
    private func cellID(at point: CGPoint) -> PersistentIdentifier? {
        frameStore.frames.first { $0.value.contains(point) }?.key
    }

    /// `point` 에 **중심이 가장 가까운** 셀의 id(재배치 대상용 — 겹침에서도 결정적).
    private func nearestCellID(to point: CGPoint) -> PersistentIdentifier? {
        frameStore.frames.min { a, b in
            let ca = CGPoint(x: a.value.midX, y: a.value.midY)
            let cb = CGPoint(x: b.value.midX, y: b.value.midY)
            return hypot(ca.x - point.x, ca.y - point.y) < hypot(cb.x - point.x, cb.y - point.y)
        }?.key
    }

    /// 끌고 있는 도안을 `target` 위치로 옮긴다(로컬 reorderIDs만 — 저장은 '완료' 시).
    private func moveReorder(_ dragged: PersistentIdentifier, over target: PersistentIdentifier) {
        guard let from = reorderIDs.firstIndex(of: dragged),
              let to = reorderIDs.firstIndex(of: target), from != to else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            reorderIDs.move(fromOffsets: IndexSet(integer: from),
                            toOffset: to > from ? to + 1 : to)
        }
    }

    /// 드래그 상태 강제 정리(백그라운드 전환·모드 종료 안전망).
    private func clearDrag() {
        draggingID = nil
    }

    @ViewBuilder
    private func menuItems(for template: Template, hasArtwork: Bool) -> some View {
        if template.isSystem {
            // 보호된 시스템 도안('한글') — '내 색칠 초기화'만 허용. 이름수정·앨범이동·삭제 없음(디자인 §32-2).
            if hasArtwork {
                Button { resetArtwork(template) } label: {
                    Label("내 색칠 초기화", systemImage: "arrow.counterclockwise")
                }
            }
        } else {
            Button {
                renameText = template.name
                renameTarget = template
            } label: {
                Label("이름 수정", systemImage: "pencil")
            }
            Button {
                moveTarget = template
            } label: {
                Label("앨범 이동", systemImage: "rectangle.stack.badge.plus")
            }
            if hasArtwork {
                Button {
                    resetArtwork(template)
                } label: {
                    Label("내 색칠 초기화", systemImage: "arrow.counterclockwise")
                }
            }
            Button(role: .destructive) {
                pendingDelete = template
            } label: {
                Label("도안 삭제", systemImage: "trash")
            }
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            VStack(spacing: 24) {
                ZStack {
                    RoundedRectangle(cornerRadius: 36)
                        .strokeBorder(style: StrokeStyle(lineWidth: 4, dash: [14, 12]))
                        .foregroundStyle(Color(hex: 0xE4D5C6))
                        .frame(width: 300, height: 230)
                    Image(systemName: "paintbrush.pointed.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(Theme.coral.opacity(0.85))
                        .rotationEffect(.degrees(-12))
                }
                VStack(spacing: 8) {
                    Text("아직 색칠할 도안이 없어요")
                        .font(Theme.rounded(30, weight: .heavy))
                        .foregroundStyle(Theme.ink)
                    Text("오른쪽 아래 ＋ 버튼으로 사진을 올려 도안을 만들어요")
                        .font(Theme.rounded(20))
                        .foregroundStyle(Theme.subText)
                }
            }
            Spacer()
            Spacer()
        }
    }

    /// 시스템 앨범('한글'·'알파벳')이 시드 직후 잠깐 비어 보일 때의 안내(추가 버튼 없음 — 준비 중).
    private var systemPreparingState: some View {
        VStack {
            Spacer()
            VStack(spacing: 20) {
                ProgressView().scaleEffect(1.4)
                Text("\(currentAlbum?.name ?? "도안") 도안을 준비하고 있어요")
                    .font(Theme.rounded(26, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Text("글자 도안을 만들고 있어요. 잠시만요!")
                    .font(Theme.rounded(18))
                    .foregroundStyle(Theme.subText)
            }
            Spacer()
            Spacer()
        }
    }

    // MARK: - Actions

    /// 프로필로 복귀(진입의 역): 갤러리 요소가 빠진 뒤 가로 슬라이드 없이 pop.
    /// pop 후 프로필 화면이 흩어졌던 요소를 제자리로 되돌리며 등장(전환 대칭, §12).
    private func goBack() {
        guard !exiting else { return }              // 뒤로가기 연타 가드
        let dur = reduceMotion ? 0.18 : 0.30
        withAnimation(.easeIn(duration: dur)) { exiting = true }
        exitTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(dur))
            guard !Task.isCancelled else { return }  // 도중 다른 내비게이션 → 늦은 dismiss 방지
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { dismiss() }
        }
    }

    private func presentUpload() { withAnimation(sheetAnimation) { isUploadPresented = true } }
    private func dismissUpload() { withAnimation(sheetAnimation) { isUploadPresented = false } }

    private func saveTemplate(_ name: String, _ image: Data, _ thumbnail: Data, album: Album?) {
        // 새 도안은 해당 앨범 순서의 맨 끝(§도안 정렬).
        let template = Template(name: name, imageData: image, thumbnailData: thumbnail,
                                album: album, sortOrder: nextSortOrder(in: album))
        context.insert(template)
        do {
            try context.save()
        } catch {
            print("도안 저장 실패: \(error)")
        }
        dismissUpload()
    }

    /// 도안을 다른 앨범(nil = 미분류)으로 이동. 현재 화면(선택 앨범)에서 빠지면 자동으로 그리드에서 사라진다.
    private func moveTemplate(_ template: Template, to album: Album?) {
        moveTarget = nil
        guard template.modelContext != nil else { return }
        template.sortOrder = nextSortOrder(in: album)   // 목적 앨범 맨 끝에 배치(§도안 정렬)
        template.album = album
        do {
            try context.save()
        } catch {
            print("앨범 이동 실패: \(error)")
        }
    }

    /// 대상 앨범(nil = 미분류) 안 도안들의 (max sortOrder)+1 — 새 도안/이동 도안을 맨 끝에 둔다.
    /// 전체를 가져오지 않고 sortOrder 최댓값 1행만 fetch(검수 L-1).
    private func nextSortOrder(in album: Album?) -> Int {
        var desc: FetchDescriptor<Template>
        if let aid = album?.persistentModelID {
            desc = FetchDescriptor<Template>(predicate: #Predicate { $0.album?.persistentModelID == aid })
        } else {
            desc = FetchDescriptor<Template>(predicate: #Predicate { $0.album == nil })
        }
        desc.sortBy = [SortDescriptor(\.sortOrder, order: .reverse)]
        desc.fetchLimit = 1
        let top = (try? context.fetch(desc))?.first
        return (top?.sortOrder ?? -1) + 1
    }

    // MARK: - 정렬(편집) 모드

    private func toggleReorder() {
        if isReordering { exitReorder() } else { enterReorder() }
    }

    private func enterReorder() {
        reorderIDs = templates.map(\.persistentModelID)
        reorderByID = Dictionary(templates.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { a, _ in a })
        reorderLookup = artworkByTemplate                    // 작업물 매핑 1회 스냅샷(검수 H-1)
        // 지난 세션의 stale 프레임(삭제·이동된 도안) 제거 — 현재 도안 키만 남긴다(검수 M-3).
        // 참조 컨테이너라 body 를 깨우지 않음. 남은 키는 같은 레이아웃이라 좌표가 유효(coalesce 대비).
        frameStore.frames = frameStore.frames.filter { reorderByID[$0.key] != nil }
        draggingID = nil
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { isReordering = true }
    }

    private func exitReorder() {
        commitReorder()
        draggingID = nil
        draggedSize = .zero
        reorderByID = [:]
        reorderLookup = [:]
        // frameStore 는 비우지 않는다 — 레이아웃이 그대로면 재진입 시 preference 값이 동일해
        // onPreferenceChange 가 다시 안 불릴 수 있다(coalesce). 남겨두면 같은 좌표라 즉시 유효하고,
        // 실제 레이아웃이 바뀌면 그때 preference 가 갱신해 자가 보정한다(stale 키는 enterReorder 에서 정리).
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { isReordering = false }
    }

    /// 로컬 순서(reorderIDs)를 sortOrder 0..n 으로 커밋 — 드롭마다가 아니라 여기서 **1회만** 저장(평가자 체크포인트).
    private func commitReorder() {
        guard !reorderIDs.isEmpty else { return }
        let byID = Dictionary(templates.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { a, _ in a })
        var idx = 0
        var changed = false
        for id in reorderIDs {
            guard let t = byID[id] else { continue }
            if t.sortOrder != idx { t.sortOrder = idx; changed = true }
            idx += 1
        }
        // reorderIDs 에 없던 도안(외부 추가 등)은 뒤에 붙임.
        let placed = Set(reorderIDs)
        for t in templates where !placed.contains(t.persistentModelID) {
            if t.sortOrder != idx { t.sortOrder = idx; changed = true }
            idx += 1
        }
        guard changed else { return }
        do { try context.save() } catch { print("정렬 저장 실패: \(error)") }
    }

    private func commitRename() {
        // 삭제된 객체에 쓰는 것을 방지 (외부 동기화 등으로 도중 삭제된 경우 대비)
        guard let target = renameTarget, target.modelContext != nil else {
            renameTarget = nil
            renameText = ""
            return
        }
        target.name = renameText.trimmingCharacters(in: .whitespaces)
        try? context.save()
        renameTarget = nil
        renameText = ""
    }

    private func deleteTemplate(_ template: Template) {
        pendingDelete = nil   // 알림 타이틀이 참조하는 상태를 먼저 해제
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            context.delete(template)   // cascade로 작업물도 함께 삭제
        }
        do {
            try context.save()
        } catch {
            print("도안 삭제 실패: \(error)")
        }
    }

    private func resetArtwork(_ template: Template) {
        // 전체 dict를 만들지 않고 단건만 찾는다(검수 M-1). allArtworks는 이미 현재 프로필로 한정됨.
        let tid = template.persistentModelID
        guard let art = allArtworks.first(where: { $0.template?.persistentModelID == tid }) else { return }
        context.delete(art)
        try? context.save()
    }

    private func openColoring(_ template: Template) {
        path.append(.coloring(profile, template))
    }
}
