import SwiftUI
import SwiftData
import UIKit

/// 앱의 화면 이동 경로 (iPad 전용).
enum Route: Hashable {
    case gallery(Profile)
    case coloring(Profile, Template)
}

@main
struct jdColoringApp: App {
    private static let isPhone = UIDevice.current.userInterfaceIdiom == .phone

    /// iPad = 광고(Advertiser), iPhone = 탐색(Browser). 앱 기동 시 1회 생성.
    @State private var peerSession = PeerSession(
        role: jdColoringApp.isPhone ? .phone : .pad
    )

    var body: some Scene {
        WindowGroup {
            if Self.isPhone {
                ParentControlView()
                    .environment(peerSession)
            } else {
                RootView()
                    .environment(peerSession)
            }
        }
        .modelContainer(for: [Profile.self, Template.self, Artwork.self])
    }
}

/// NavigationStack을 소유하는 루트 뷰 (iPad).
struct RootView: View {
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            UserSelectionView(path: $path)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case let .gallery(profile):
                        GalleryView(profile: profile, path: $path)
                    case let .coloring(profile, template):
                        ColoringCanvasView(profile: profile, template: template)
                    }
                }
        }
    }
}
