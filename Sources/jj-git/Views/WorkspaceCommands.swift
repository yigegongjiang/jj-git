import SwiftUI

struct WorkspaceCommands: Commands {
    let workspace: Workspace

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("快捷键…") { workspace.showingKeyboardShortcuts = true }
                .keyboardShortcut("/", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .appSettings) {
            Button("安装命令行工具…") { workspace.installCLI() }
            Divider()
            Button("打开配置文件") { workspace.openConfig() }.keyboardShortcut(",")
            Button("重启应用") { workspace.restart() }.disabled(!workspace.canRestart)
        }
        CommandGroup(replacing: .newItem) {
            Button("打开仓库…") { workspace.chooseRepository() }.keyboardShortcut("o")
            Button("扫描目录…") { workspace.chooseRepository(scan: true) }.keyboardShortcut(
                "o",
                modifiers: [.command, .shift]
            )
            // 已有弹窗时 SwiftUI 不会叠加第二个 sheet。
            Button("最近仓库…") {
                if NSApp.mainWindow?.attachedSheet == nil {
                    workspace.repositoryPicker = .recent
                }
            }.keyboardShortcut("p")
            Button("全部仓库…") {
                if NSApp.mainWindow?.attachedSheet == nil {
                    workspace.repositoryPicker = .all
                }
            }.keyboardShortcut("p", modifiers: [.command, .shift])
            Button("关闭仓库标签") {
                if let path = workspace.library.selectedPath {
                    workspace.close(path)
                }
            }.keyboardShortcut("w").disabled(workspace.selected == nil || workspace.selected?.operation != nil)
        }
        CommandGroup(replacing: .sidebar) {
            Button(workspace.library.sidebarHidden ? "显示侧边栏" : "隐藏侧边栏") { workspace.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.control, .command])
        }
        CommandMenu("仓库") {
            Button("刷新") { workspace.selected?.refresh(forceHistory: true) }.keyboardShortcut("r")
            Button("提交历史") { workspace.selected?.changeSection(.history) }.keyboardShortcut("1")
            Button("本地变更") { workspace.selected?.changeSection(.changes) }.keyboardShortcut("2")
            Divider()
            Button("Fetch") { workspace.selected?.fetch() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button(workspace.config.pull.rebase ? "Pull（Rebase）" : "Pull") {
                workspace.selected?.perform(.pull, title: "Pull")
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(workspace.selected?.status.upstream.isEmpty != false)
            Button("Push 到上游") { workspace.selected?.pushToUpstream() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(workspace.selected?.status.detached != false || workspace.selected?.remotes.isEmpty != false)
            Divider()
            Button("全部暂存") {
                if let session = workspace.selected {
                    session.perform(.stage(session.status.changes.filter(\.unstaged)), title: "暂存")
                }
            }.keyboardShortcut("a", modifiers: [.command, .shift])
            Divider()
            Button("在终端打开") {
                if let path = workspace.library.selectedPath {
                    workspace.openTerminal(path)
                }
            }.keyboardShortcut("t", modifiers: [.command, .shift])
            Button("在编辑器打开") {
                if let path = workspace.library.selectedPath {
                    workspace.openEditor(path)
                }
            }.keyboardShortcut("e", modifiers: [.command, .shift])
            Button("选择外部编辑器…") { workspace.chooseEditor() }
        }
        CommandGroup(after: .windowArrangement) {
            Button("下一个仓库标签") { nextTab(1) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("上一个仓库标签") { nextTab(-1) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("下一个仓库标签") { nextTab(1) }.keyboardShortcut(.tab, modifiers: [.control])
            Button("上一个仓库标签") { nextTab(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
        }
    }

    private func nextTab(_ offset: Int) {
        let tabs = workspace.library.tabs
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex(of: workspace.library.selectedPath ?? "") ?? 0
        workspace.select(tabs[(current + offset + tabs.count) % tabs.count])
    }
}
