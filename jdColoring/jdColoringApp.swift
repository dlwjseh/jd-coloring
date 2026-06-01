import SwiftUI
import SwiftData

@main
struct jdColoringApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                UserSelectionView()
            }
        }
        .modelContainer(for: [Profile.self, Template.self, Artwork.self])
    }
}
