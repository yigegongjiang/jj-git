import SwiftUI

struct ContentView: View {
    @Bindable var workspace: Workspace

    var body: some View {
        Group {
            if workspace.library.sidebarHidden {
                main
            } else {
                // 每栏单独承载，各自让顶部条占用隐藏的标题栏区域。
                SplitPane(name: "library", initial: 190, minimum: (150, 600)) {
                    LibraryView(workspace: workspace).ignoresSafeArea(.container, edges: .top)
                } second: { main }
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
        .frame(minWidth: 1000, minHeight: 640)
        .themed()
        .environment(\.workspace, workspace)
        .background(WindowFrameKeeper(workspace: workspace))
        .task {
            await workspace.restore()
            for path in ProcessInfo.processInfo.arguments.dropFirst() where path.hasPrefix("/") {
                await workspace.open(path)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            workspace.selected?.refresh()
            workspace.checkMissingRepositories()
        }
    }

    private var main: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if workspace.library.sidebarHidden {
                    WindowBar { SidebarToggle(workspace: workspace) }
                }
                RepositoryTabs(workspace: workspace)
                Button("重启应用", systemImage: "arrow.clockwise.circle") { workspace.restart() }
                    .buttonStyle(.borderless).padding(.horizontal, 8)
                    .help("重新读取配置；有未提交的提交信息或任务进行中时不可重启")
                    .disabled(!workspace.canRestart)
            }
            .background(Theme.titleBar)
            ThemedDivider()
            if !workspace.missingRepositories.isEmpty {
                MissingRepositoriesBanner(workspace: workspace)
            }
            if let error = workspace.error {
                ErrorBanner(message: error) { workspace.error = nil }
            }
            if let session = workspace.selected {
                RepositoryView(workspace: workspace, session: session).id(session.id)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("打开仓库开始工作，或扫描目录批量导入。")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("打开仓库…") { workspace.chooseRepository() }.keyboardShortcut("o")
                        Button("扫描目录…") { workspace.chooseRepository(scan: true) }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
    }
}
