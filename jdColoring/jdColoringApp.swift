import SwiftUI
import SwiftData
import UIKit

/// 갤러리에서 보여줄 도안 묶음(앨범 또는 미분류).
enum AlbumSelection: Hashable {
    case album(Album)
    case uncategorized

    /// 화면 표시용 이름.
    var title: String {
        switch self {
        case .album(let a): return a.name
        case .uncategorized: return "미분류"
        }
    }
}

/// 앱의 화면 이동 경로 (iPad 전용). 프로필 → 앨범 → 갤러리 → 색칠.
enum Route: Hashable {
    case albums(Profile)
    case gallery(Profile, AlbumSelection)
    case coloring(Profile, Template)
}

@main
struct jdColoringApp: App {
    private static let isPhone = UIDevice.current.userInterfaceIdiom == .phone

    /// iPad = 광고(Advertiser), iPhone = 탐색(Browser). 앱 기동 시 1회 생성.
    @State private var peerSession = PeerSession(
        role: jdColoringApp.isPhone ? .phone : .pad
    )
    @State private var appSettings = AppSettings()
    // M-4: 백그라운드 진입 시 광고·탐색 정지 → 배터리 절약
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            if Self.isPhone {
                ParentControlView()
                    .environment(peerSession)
                    .environment(appSettings)
            } else {
                RootView()
                    .environment(peerSession)
                    .environment(appSettings)
            }
        }
        .modelContainer(for: [Profile.self, Album.self, Template.self, Artwork.self])
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: peerSession.suspend()
            case .active:     peerSession.resume()
            default: break
            }
        }
    }
}

/// Profile → 전송용 경량 요약.
/// m-1: 썸네일은 iPhone 칩(56pt)에 맞춰 작게(160px) 재다운샘플 — 저장본(512px)을 그대로 보내지 않는다.
/// 전송은 연결/프로필 CRUD 시에만 일어나므로(드묾) 동기 재다운샘플 비용은 N이 작아 무시 가능.
func profileSummaries(_ profiles: [Profile]) -> [ProfileSummary] {
    profiles.map { p in
        let thumb: Data? = p.imageData.flatMap {
            ImageDownsampler.thumbnailData(from: $0, maxPixel: 160, compression: 0.7) ?? $0
        }
        return ProfileSummary(id: p.uuid, name: p.name, colorIndex: p.colorIndex, thumbnail: thumb)
    }
}

/// NavigationStack을 소유하는 루트 뷰 (iPad).
struct RootView: View {
    @State private var path: [Route] = []
    @Environment(PeerSession.self) private var peer
    @Environment(\.modelContext) private var context
    @Query(sort: \Profile.createdAt) private var profiles: [Profile]
    @State private var didReconcile = false

    var body: some View {
        NavigationStack(path: $path) {
            UserSelectionView(path: $path)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case let .albums(profile):
                        AlbumCarouselView(profile: profile, path: $path)
                    case let .gallery(profile, selection):
                        GalleryView(profile: profile, selection: selection, path: $path)
                    case let .coloring(profile, template):
                        ColoringCanvasView(profile: profile, template: template, path: $path)
                    }
                }
        }
        // iPhone이 연결되면 현재 프로필 목록을 즉시 전송.
        // (이후 프로필 추가/수정/삭제 시 전송은 UserSelectionView CRUD 지점에서 직접 호출 —
        //  M-2: navigation body 재평가와 분리해 불필요한 재계산 제거.)
        .onChange(of: peer.isConnected) { _, connected in
            if connected { peer.sendProfileList(profileSummaries(profiles)) }
        }
        .onAppear {
            reconcileProfileUUIDsOnce()
            if peer.isConnected { peer.sendProfileList(profileSummaries(profiles)) }
        }
    }

    /// B-1: 경량 마이그레이션이 기존 행에 중복/제로 UUID를 부여했을 가능성에 대한 안전망.
    /// 기동 1회 — 중복·제로 UUID를 발견하면 새 UUID를 재할당해 타깃 매칭의 고유성을 보장한다.
    private func reconcileProfileUUIDsOnce() {
        guard !didReconcile else { return }
        didReconcile = true
        let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        var seen = Set<UUID>()
        var changed = false
        for p in profiles {
            if p.uuid == zero || seen.contains(p.uuid) {
                p.uuid = UUID()
                changed = true
            }
            seen.insert(p.uuid)
        }
        if changed { try? context.save() }
    }
}
