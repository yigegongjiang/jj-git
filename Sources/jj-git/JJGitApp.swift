import SwiftUI

@main
struct JJGitApp: App {
    var body: some Scene {
        Window(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "jj-git", id: "main") {
            ContentView()
        }
        .defaultSize(width: 640, height: 400)
    }
}
