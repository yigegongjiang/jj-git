import SwiftUI

struct ContentView: View {
    @Bindable var workspace: Workspace

    var body: some View {
        HSplitView {
            if workspace.library.sidebarHidden != true {
                // HSplitView 每栏单独承载，各自让顶部条占用隐藏的标题栏区域。
                LibraryView(workspace: workspace).frame(minWidth: 160, idealWidth: 190, maxWidth: 220)
                    .ignoresSafeArea(.container, edges: .top)
            }
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if workspace.library.sidebarHidden == true {
                        WindowBar { SidebarToggle(workspace: workspace) }
                    }
                    RepositoryTabs(workspace: workspace)
                }
                Divider()
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
            .frame(minWidth: 720, maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .top)
        }
        .frame(minWidth: 1000, minHeight: 640)
        .task {
            await workspace.restore()
            for path in ProcessInfo.processInfo.arguments.dropFirst() where path.hasPrefix("/") {
                await workspace.open(path)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            workspace.selected?.refresh()
        }
    }
}
