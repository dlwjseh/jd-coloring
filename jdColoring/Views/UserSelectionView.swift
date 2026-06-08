import SwiftUI
import SwiftData

/// 화면 1 — 사용자 선택
struct UserSelectionView: View {
    @Binding var path: [Route]

    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(PeerSession.self) private var peer
    @Query(sort: \Profile.createdAt) private var profiles: [Profile]

    /// A1 진입 애니메이션 트리거
    @State private var appeared = false
    /// 갤러리 진입 직전 프로필 흩어짐(G1, §12). 흩어진 뒤 갤러리로 넘어간다.
    @State private var leaving = false
    /// 전환 진행 중 가드(연타·재진입 방지). 복귀 시 onAppear에서 해제.
    @State private var transitioning = false
    /// 흩어짐→push 동기화 작업(취소 가능 — dangling 방지).
    @State private var leaveTask: Task<Void, Never>?

    // 편집기(추가/수정) 상태
    @State private var isEditorPresented = false
    @State private var editingProfile: Profile?      // nil = 추가, 값 있음 = 수정
    @State private var draftName = ""
    @State private var draftImageData: Data?

    /// A2 흩어짐 거리 산정을 위한 컨테이너 폭 (창 리사이즈 대응)
    @State private var containerWidth: CGFloat = 1000

    /// 삭제 확인 다이얼로그 대상 (nil = 미표시)
    @State private var pendingDelete: Profile?
    /// 설정 시트 표시 여부
    @State private var showSettings = false

    private let editorAnimation: Animation = .spring(response: 0.5, dampingFraction: 0.82)

    /// 프로필이 흩어져(좌·우로 밀려 사라짐) 보여야 하는 상태: 편집 진입 또는 갤러리 진입.
    private var scattered: Bool { isEditorPresented || leaving }

    var body: some View {
        ZStack {
            Theme.bgGradient.ignoresSafeArea()
            BubbleBackground()

            // 브라우징 레이어
            VStack(spacing: 0) {
                header
                    .padding(.top, 60)
                    .opacity(scattered ? 0 : 1)
                    .offset(y: (leaving && !reduceMotion) ? -260 : 0)   // G1: 갤러리 진입 시 위로 빠짐
                Spacer(minLength: 0)
                profileRow
                Spacer(minLength: 0)
                dragHint
                    .padding(.bottom, 44)
                    .opacity(scattered ? 0 : 1)
                    .offset(y: (leaving && !reduceMotion) ? 140 : 0)
            }

            // 우하단 추가 버튼
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    AddButton(action: presentAdd)
                        .padding(.trailing, 40)
                        .padding(.bottom, 32)
                        .opacity(scattered ? 0 : 1)
                        .offset(y: (leaving && !reduceMotion) ? 260 : 0)   // G1: 아래로 화면 밖 빠짐
                }
            }

            // 좌상단 설정 버튼 (디자인 §26)
            VStack {
                HStack {
                    settingsButton
                        .padding(.leading, 40)
                        .padding(.top, 32)
                        .opacity(scattered ? 0 : 1)
                        .offset(y: (leaving && !reduceMotion) ? -260 : 0)  // G1: 헤더와 함께 위로 빠짐
                    Spacer()
                }
                Spacer()
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
            transitioning = false       // 복귀 → 다시 진입 가능
            if leaving {
                // 갤러리에서 복귀(G1 §12): 흩어졌던 프로필·타이틀·버튼이 제자리로 되돌아온다
                // (정방향 흩어짐의 역, 같은 spring 톤). A1은 재생하지 않는다.
                let anim: Animation = reduceMotion
                    ? .easeOut(duration: 0.18)
                    : .spring(response: 0.5, dampingFraction: 0.85)
                withAnimation(anim) { leaving = false }
            } else {
                // 최초 진입 → A1 순차 등장
                appeared = false
                Task { @MainActor in
                    appeared = true
                    // 첫 실행(등록된 사용자 0명) → 곧바로 추가 화면
                    if profiles.isEmpty { presentAdd() }
                }
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
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    // MARK: - Sections

    /// 좌상단 설정 버튼 — 지름 56pt, 크림/카드 톤, gearshape 아이콘. 디자인 §26-1.
    private var settingsButton: some View {
        Button { showSettings = true } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color(hex: 0x6E6258))
                .frame(width: 56, height: 56)
                .background(Circle().fill(Theme.card))
                .overlay(Circle().stroke(Theme.cardBorder, lineWidth: 2))
                .shadow(color: Theme.softShadow, radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("설정")
    }

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
            LazyHStack(spacing: 48) {
                ForEach(Array(profiles.enumerated()), id: \.element.persistentModelID) { index, profile in
                    let diameter: CGFloat = 190
                    VStack(spacing: 4) {
                        ProfileAvatar(profile: profile, diameter: diameter)
                            // 컨텍스트 메뉴는 아바타(원)에만 붙인다 — 누름/해제 시 프리뷰가 이름 없이 원으로.
                            // 패딩 없이는 기본 스냅샷이 뷰 bounds로 잘려 링(stroke 바깥 절반)이 잘린다.
                            // 패딩으로 링·여백을 담고, contextMenuPreview 형태를 원으로 맞춘다.
                            .padding(8)
                            .profilePreviewShape()
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

                        Text(profile.name)
                            .font(Theme.rounded(diameter * 0.18, weight: .bold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                    }
                    // A1: 오른쪽 바깥 → 제자리, index 기반 stagger
                    .staggeredEntrance(index: index, visible: appeared)
                    // A2(편집) / G1(갤러리 진입): 좌·우로 흩어지며 사라짐 (동작 줄이기 시 페이드만)
                    .offset(x: (scattered && !reduceMotion) ? scatterOffset(index: index) : 0)
                    .opacity(scattered ? 0 : 1)
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
        broadcastProfilesIfConnected()   // M-2: CRUD 시점에 직접 전송(부모 제어판 목록 갱신)
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
        broadcastProfilesIfConnected()   // M-2: 삭제도 즉시 부모 제어판 목록에 반영
    }

    /// iPhone(부모 제어판)이 연결돼 있으면 현재 프로필 목록을 전송.
    /// SwiftData CRUD가 끝난 뒤 profiles 쿼리가 갱신되도록 다음 런루프에서 보낸다.
    private func broadcastProfilesIfConnected() {
        guard peer.isConnected else { return }
        DispatchQueue.main.async {
            peer.sendProfileList(profileSummaries(profiles))
        }
    }

    private func selectProfile(_ profile: Profile) {
        // G1(§12): ① 프로필이 좌·우로 흩어져 사라진 뒤 → ② 갤러리 카드가 밑에서 올라온다.
        // 화면 전환 자체는 애니메이션 없이(가로 슬라이드 방지) 넘긴다. 두 화면이 같은
        // 크림 배경을 공유하므로 즉시 전환이 눈에 띄지 않고 흩어짐→카드 등장이 매끄럽게 이어진다.
        guard !transitioning else { return }        // 연타/재진입 가드
        transitioning = true
        let dur = reduceMotion ? 0.18 : 0.30
        withAnimation(.easeIn(duration: dur)) { leaving = true }
        leaveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(dur))
            guard !Task.isCancelled else { return }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { path.append(.albums(profile)) }
        }
    }
}

private extension View {
    func profilePreviewShape() -> some View {
        contentShape(.contextMenuPreview, Circle())
    }
}

#Preview {
    UserSelectionView(path: .constant([]))
        .modelContainer(for: Profile.self, inMemory: true)
}
