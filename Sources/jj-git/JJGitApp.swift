import SwiftUI

@main
struct JJGitApp: App {
    @NSApplicationDelegateAdaptor(RepositoryOpenHandler.self) private var openHandler
    @State private var workspace = Workspace()

    init() {
        ShellEnvironment.load()
        // 固定 Dracula 深色主题，不跟随系统外观。
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    }

    var body: some Scene {
        Window(windowTitle, id: "main") {
            ContentView(workspace: workspace, openHandler: openHandler)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1360, height: 840)
        .commands { WorkspaceCommands(workspace: workspace) }
    }

    private var windowTitle: String {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "jj-git"
        return DebugInstance.tag.map { "\(name) · \($0)" } ?? name
    }
}

/// `scripts/debug.sh` 传入的 worktree 名，区分并行运行的多个 Debug 实例；Release 恒为 nil。
enum DebugInstance {
    static let tag: String? = {
        #if DEBUG
        ProcessInfo.processInfo.environment["JJGIT_DEBUG_TAG"].flatMap { $0.isEmpty ? nil : $0 }
        #else
        nil
        #endif
    }()
}
