import SwiftUI
import SwiftData

/// 화면 1 — 사용자 선택
struct UserSelectionView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Profile.createdAt) private var profiles: [Profile]

    /// A1 진입 애니메이션 트리거
    @State private var appeared = false

    // 편집기(추가/수정) 상태
    @State private var isEditorPresented = false
    @State private var editingProfile: Profile?      // nil = 추가, 값 있음 = 수정
    @State private var draftName = ""
    @State private var draftImageData: Data?

    /// A2 흩어짐 거리 산정을 위한 컨테이너 폭 (창 리사이즈 대응)
    @State private var containerWidth: CGFloat = 1000

    /// 삭제 확인 다이얼로그 대상 (nil = 미표시)
    @State private var pendingDelete: Profile?

    /// 선택해서 갤러리로 진입할 프로필 (nil = 현재 화면)
    @State private var selected: Profile?

    private let editorAnimation: Animation = .spring(response: 0.5, dampingFraction: 0.82)

    var body: some View {
        ZStack {
            Theme.bgGradient.ignoresSafeArea()
            BubbleBackground()

            // 브라우징 레이어
            VStack(spacing: 0) {
                header
                    .padding(.top, 60)
                    .opacity(isEditorPresented ? 0 : 1)
                Spacer(minLength: 0)
                profileRow
                Spacer(minLength: 0)
                dragHint
                    .padding(.bottom, 44)
                    .opacity(isEditorPresented ? 0 : 1)
            }

            // 우하단 추가 버튼
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    AddButton(action: presentAdd)
                        .padding(.trailing, 40)
                        .padding(.bottom, 32)
                        .opacity(isEditorPresented ? 0 : 1)
                }
            }

            // A2: 편집기 폼 (아래에서 등장)
            if isEditorPresented {
                ProfileEditorView(
                    title: editingProfile == nil ? "새 친구 추가" : "프로필 수정",
                    colorIndex: editingProfile?.colorIndex ?? nextColorIndex,
                    name: $draftName,
                    imageData: $draftImageData,
                    onCancel: dismissEditor,
                    onSave: saveEditor
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { containerWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, width in containerWidth = width }
            }
        )
        .onAppear {
            appeared = false
            Task { @MainActor in
                appeared = true
                // 첫 실행(등록된 사용자 0명) → 곧바로 추가 화면
                if profiles.isEmpty { presentAdd() }
            }
        }
        // 삭제 확인 다이얼로그
        .alert(
            "‘\(pendingDelete?.name ?? "")’ 프로필을 삭제할까요?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { profile in
            Button("삭제", role: .destructive) { deleteProfile(profile) }
            Button("취소", role: .cancel) { }  // 닫힘 시 Binding이 pendingDelete를 nil로 정리
        } message: { _ in
            Text("이 작업은 되돌릴 수 없어요")
        }
        // 프로필 선택 → 화면 2(갤러리) 진입
        .navigationDestination(item: $selected) { profile in
            GalleryView(profile: profile)
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 10) {
            Text("오늘은 누가 색칠할까요?")
                .font(Theme.rounded(40, weight: .heavy))
                .foregroundStyle(Theme.ink)
            Text("프로필을 선택하세요")
                .font(Theme.rounded(22))
                .foregroundStyle(Theme.subText)
        }
    }

    private var profileRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 64) {
                ForEach(Array(profiles.enumerated()), id: \.element.persistentModelID) { index, profile in
                    ProfileCircleView(profile: profile, diameter: 190)
                        // A1: 오른쪽 바깥 → 제자리, index 기반 stagger
                        .staggeredEntrance(index: index, visible: appeared)
                        // A2: 편집 진입 시 좌·우로 흩어짐
                        .offset(x: isEditorPresented ? scatterOffset(index: index) : 0)
                        .opacity(isEditorPresented ? 0 : 1)
                        .onTapGesture { selectProfile(profile) }
                        // iPad: 롱프레스 / Mac: 우클릭(컨트롤+클릭) → 수정·삭제
                        .contextMenu {
                            Button {
                                presentEdit(profile)
                            } label: {
                                Label("수정", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                pendingDelete = profile
                            } label: {
                                Label("삭제", systemImage: "trash")
                            }
                        }
                }
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 24)
            // 기본 가운데 정렬: 콘텐츠가 화면 폭보다 좁으면 중앙으로 모으고,
            // 넘치면 프레임이 콘텐츠 폭으로 커져 좌측부터 스크롤된다.
            .frame(minWidth: containerWidth, alignment: .center)
        }
        .scrollDisabled(isEditorPresented)
    }

    private var dragHint: some View {
        Text("‹   좌우로 드래그해서 더 보기   ›")
            .font(Theme.rounded(20))
            .foregroundStyle(Theme.faintText)
    }

    // MARK: - Helpers

    /// 새 프로필 링 색: 현재 안 쓰는 색을 우선 배정(중간 삭제 후 색 충돌 방지),
    /// 6색이 모두 쓰이면 가장 적게 쓰인 색을 재사용.
    private var nextColorIndex: Int {
        let count = Theme.ringColors.count
        var used = Array(repeating: 0, count: count)
        for profile in profiles {
            used[((profile.colorIndex % count) + count) % count] += 1
        }
        if let unused = used.firstIndex(of: 0) { return unused }
        return used.firstIndex(of: used.min() ?? 0) ?? 0
    }

    /// 가운데 기준 좌/우로 밀어내는 흩어짐 오프셋 (화면 밖으로 완전히 나가도록 컨테이너 폭 기반)
    private func scatterOffset(index: Int) -> CGFloat {
        guard !profiles.isEmpty else { return 0 }
        let mid = Double(profiles.count - 1) / 2
        let distance = containerWidth + 200
        return Double(index) <= mid ? -distance : distance
    }

    // MARK: - Actions

    private func presentAdd() {
        editingProfile = nil
        draftName = ""
        draftImageData = nil
        withAnimation(editorAnimation) { isEditorPresented = true }
    }

    private func presentEdit(_ profile: Profile) {
        editingProfile = profile
        draftName = profile.name
        draftImageData = profile.imageData
        withAnimation(editorAnimation) { isEditorPresented = true }
    }

    private func dismissEditor() {
        withAnimation(editorAnimation) { isEditorPresented = false }
    }

    private func saveEditor() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let profile = editingProfile {
            profile.name = trimmed
            profile.imageData = draftImageData
        } else {
            let new = Profile(name: trimmed, imageData: draftImageData, colorIndex: nextColorIndex)
            context.insert(new)
        }
        do {
            try context.save()
        } catch {
            print("프로필 저장 실패: \(error)")
        }
        dismissEditor()
    }

    private func deleteProfile(_ profile: Profile) {
        // 타이틀이 참조하는 상태를 삭제보다 먼저 해제 → 삭제된 @Model 접근 윈도우 제거
        pendingDelete = nil
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            context.delete(profile)
        }
        do {
            try context.save()
        } catch {
            print("프로필 삭제 실패: \(error)")
        }
    }

    private func selectProfile(_ profile: Profile) {
        selected = profile
    }
}

#Preview {
    UserSelectionView()
        .modelContainer(for: Profile.self, inMemory: true)
}
