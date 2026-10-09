import SwiftUI

struct ContentView: View {
    @Bindable var workspace: Workspace
    let openHandler: RepositoryOpenHandler
    @State private var showingPerformance = false
    @State private var performanceBaseline: ProcessSample?

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
        .background(SectionTabKey(workspace: workspace))
        .sheet(isPresented: $workspace.showingKeyboardShortcuts) {
            KeyboardShortcutsView().themed().dismissOnBackgroundClick()
        }
        .task {
            openHandler.connect(workspace)
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                if !workspace.missingRepositories.isEmpty {
                    workspace.checkMissingRepositories()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            workspace.selected?.refresh()
            workspace.checkMissingRepositories()
        }
        .sheet(item: $workspace.repositoryPicker) { picker in
            RepositoryPickerView(workspace: workspace, allRepositories: picker == .all).dismissOnBackgroundClick()
        }
        // 用 sheet：popover 弹出动画会让内存瞬时上涨约 130 MB，测量会把它算进去。
        .sheet(isPresented: $showingPerformance) {
            PerformanceView(workspace: workspace, baseline: performanceBaseline).dismissOnBackgroundClick()
        }
    }

    private var main: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if workspace.library.sidebarHidden {
                    WindowBar { SidebarToggle(workspace: workspace) }
                }
                RepositoryTabs(workspace: workspace)
                Button { workspace.showingKeyboardShortcuts = true } label: {
                    Image(systemName: "keyboard")
                }
                .buttonStyle(.borderless).padding(.horizontal, 8)
                .accessibilityLabel("快捷键").help("查看快捷键")
                Button("重启应用", systemImage: "arrow.clockwise.circle") { workspace.restart() }
                    .buttonStyle(.borderless).padding(.horizontal, 8)
                    .help("重新读取配置；有未提交的提交信息或任务进行中时不可重启")
                    .disabled(!workspace.canRestart)
                Button("性能", systemImage: "gauge.with.dots.needle.33percent") {
                    // 弹窗出现前采样内存，读数不含面板自身。
                    performanceBaseline = ProcessSample.current()
                    showingPerformance = true
                }
                .buttonStyle(.borderless).padding(.horizontal, 8)
                .help("查看 CPU / 内存与各标签内存占用")
            }
            .background(Theme.titleBar)
            ThemedDivider()
            if !workspace.missingRepositories.isEmpty {
                missingRepositoriesBanner
            }
            if let error = workspace.error {
                WarningBanner {
                    ScrollView {
                        Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.scrollerGutter().frame(maxHeight: 80)
                } actions: {
                    Button { workspace.error = nil } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭错误提示").help("关闭错误提示")
                }
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
                        Button("打开仓库…") { workspace.chooseRepository() }
                        Button("扫描目录…") { workspace.chooseRepository(scan: true) }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var missingRepositoriesBanner: some View {
        WarningBanner {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(workspace.missingRepositories.count) 个仓库路径不存在")
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(workspace.missingRepositories, id: \.self) { path in
                            HStack {
                                Text(path).textSelection(.enabled).lineLimit(1).truncationMode(.middle).help(path)
                                Spacer(minLength: 8)
                                Button("从列表移除") { workspace.removeMissingRepositories([path]) }
                                    .help("移除仓库记录并关闭标签：\(path)")
                                    .disabled(workspace.sessions[path]?.operation != nil)
                            }
                        }
                    }
                }.scrollerGutter().frame(height: CGFloat(min(workspace.missingRepositories.count, 4)) * 24)
            }
        } actions: {
            Button("重新检查") { workspace.checkMissingRepositories() }.help("重新检查全部仓库路径")
            Button("全部移除") { workspace.removeMissingRepositories(workspace.missingRepositories) }
                .help("移除全部失效仓库记录并关闭标签")
        }
    }
}
