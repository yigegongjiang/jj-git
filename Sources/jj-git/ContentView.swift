import SwiftUI

struct ContentView: View {
    @Bindable var workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            if let error = workspace.error {
                ErrorBanner(message: error) { workspace.error = nil }
            }
            HSplitView {
                LibraryView(workspace: workspace).frame(minWidth: 160, idealWidth: 190, maxWidth: 220)
                VStack(spacing: 0) {
                    if !workspace.library.tabs.isEmpty {
                        RepositoryTabs(workspace: workspace)
                        Divider()
                    }
                    if let session = workspace.selected {
                        RepositoryView(workspace: workspace, session: session).id(session.id)
                    } else {
                        VStack(spacing: 14) {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .font(.system(size: 40)).foregroundStyle(.secondary)
                            Text("jj-git").font(.title2.weight(.semibold))
                            Text("打开仓库开始工作，或扫描目录批量导入。")
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("打开仓库…") { workspace.chooseRepository() }.keyboardShortcut("o")
                                Button("扫描目录…") { workspace.chooseRepository(scan: true) }
                            }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(minWidth: 720, maxWidth: .infinity, maxHeight: .infinity)
            }
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
