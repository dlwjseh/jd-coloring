import SwiftUI
import SwiftData

/// 화면 2 — 색칠 도안 갤러리. 프로필 선택 후 진입.
struct GalleryView: View {
    let profile: Profile

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @Query(sort: \Template.createdAt) private var templates: [Template]
    @Query private var allArtworks: [Artwork]

    /// 진입 stagger 트리거
    @State private var appeared = false
    @State private var isUploadPresented = false
    @State private var pendingDelete: Template?
    @State private var selectedTemplate: Template?   // 탭 → 색칠 캔버스 진입

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 240), spacing: 44)]
    private let sheetAnimation: Animation = .spring(response: 0.5, dampingFraction: 0.82)

    init(profile: Profile) {
        self.profile = profile
        // 검수 increment4 #3: 전체 작업물을 가져와 거르지 않고, 현재 프로필 것만 fetch.
        let pid = profile.persistentModelID
        _allArtworks = Query(filter: #Predicate<Artwork> { $0.profile?.persistentModelID == pid })
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
                    .opacity(isUploadPresented ? 0 : 1)

                if templates.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }

            // 우하단 추가 버튼
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    AddButton(caption: "도안 추가", action: presentUpload)
                        .padding(.trailing, 40)
                        .padding(.bottom, 32)
                        .opacity(isUploadPresented ? 0 : 1)
                }
            }

            // 업로드 시트 (아래에서 등장)
            if isUploadPresented {
                Color.black.opacity(0.28).ignoresSafeArea()
                    .transition(.opacity)
                TemplateUploadView(onCancel: dismissUpload, onSave: saveTemplate)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear {
            appeared = false
            Task { @MainActor in appeared = true }
        }
        .navigationBarBackButtonHidden(true)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
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
        .navigationDestination(item: $selectedTemplate) { template in
            ColoringCanvasView(profile: profile, template: template)
        }
    }

    // MARK: - Sections

    private var topBar: some View {
        ZStack {
            VStack(spacing: 6) {
                Text("무엇을 색칠해볼까요?")
                    .font(Theme.rounded(38, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Text("\(profile.name)의 색칠 도안 · \(templates.count)개")
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
        Button(action: { dismiss() }) {
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
        let lookup = artworkByTemplate
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 44) {
                ForEach(Array(templates.enumerated()), id: \.element.persistentModelID) { index, template in
                    TemplateCellView(template: template,
                                     artwork: lookup[template.persistentModelID])
                        .gridEntrance(index: index, visible: appeared)
                        .onTapGesture { openColoring(template) }
                        .contextMenu {
                            if lookup[template.persistentModelID] != nil {
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
            }
            .padding(.horizontal, 60)
            .padding(.top, 40)
            .padding(.bottom, 150)
        }
        .scrollDisabled(isUploadPresented)
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

    // MARK: - Actions

    private func presentUpload() { withAnimation(sheetAnimation) { isUploadPresented = true } }
    private func dismissUpload() { withAnimation(sheetAnimation) { isUploadPresented = false } }

    private func saveTemplate(_ image: Data, _ thumbnail: Data) {
        let template = Template(name: "도안 \(templates.count + 1)",
                                imageData: image,
                                thumbnailData: thumbnail)
        context.insert(template)
        do {
            try context.save()
        } catch {
            print("도안 저장 실패: \(error)")
        }
        dismissUpload()
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
        guard let art = artworkByTemplate[template.persistentModelID] else { return }
        context.delete(art)
        try? context.save()
    }

    private func openColoring(_ template: Template) {
        selectedTemplate = template
    }
}
