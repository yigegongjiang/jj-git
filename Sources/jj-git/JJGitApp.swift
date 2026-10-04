import SwiftUI

@main
struct JJGitApp: App {
    @State private var workspace = Workspace()

    init() {
        ShellEnvironment.load()
    }

    var body: some Scene {
        Window(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "jj-git", id: "main") {
            ContentView(workspace: workspace)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1360, height: 840)
        .commands { WorkspaceCommands(workspace: workspace) }
    }
}
