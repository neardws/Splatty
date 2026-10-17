import SwiftUI

@main
struct SplattyApp: App {
    @State private var store = AssetStore()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(store)
        }
    }
}
