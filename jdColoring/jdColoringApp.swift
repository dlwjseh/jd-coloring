import SwiftUI
import SwiftData

/// 앱의 화면 이동 경로. 모든 목적지를 루트 스택 한 곳에서만 선언해
/// `navigationDestination`이 중첩되며 무시되는 문제를 피한다.
enum Route: Hashable {
    case gallery(Profile)
    case coloring(Profile, Template)
}

@main
struct jdColoringApp: App {
    @State private var path: [Route] = []

    var body: some Scene {
        WindowGroup {
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
        .modelContainer(for: [Profile.self, Template.self, Artwork.self])
    }
}
