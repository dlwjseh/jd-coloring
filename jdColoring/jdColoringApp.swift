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
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [Profile.self, Template.self, Artwork.self])
    }
}

/// NavigationStack을 소유하는 루트 뷰.
struct RootView: View {
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            UserSelectionView(path: $path)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case let .gallery(profile):
                        // G1: 프로필이 흩어진 뒤 갤러리 카드가 밑에서 올라온다(디자인 스펙 §12).
                        // 화면 전환 자체는 애니메이션 없이(가로 슬라이드 방지) — 연출은 양쪽 콘텐츠가 담당.
                        GalleryView(profile: profile, path: $path)
                    case let .coloring(profile, template):
                        ColoringCanvasView(profile: profile, template: template)
                    }
                }
        }
    }
}
