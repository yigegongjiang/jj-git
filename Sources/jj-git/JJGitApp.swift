import SwiftUI

@main
struct JJGitApp: App {
    @State private var workspace = Workspace()

    init() {
        ShellEnvironment.load()
        // 固定 Dracula 深色主题，不跟随系统外观。
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
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
