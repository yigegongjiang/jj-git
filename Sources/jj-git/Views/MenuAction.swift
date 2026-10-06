import SwiftUI

/// 右键菜单项：同一份定义渲染菜单，并暴露为辅助功能命名动作（AX 动作名 `Name:<title>`）。
struct MenuAction {
    let title: String
    var enabled = true
    /// 右键菜单中显示提示；实际按键由 `menuShortcuts` 处理。
    var shortcut: KeyboardShortcut?
    let action: () -> Void
}

extension MenuAction {
    /// 复制仓库内相对路径 / 完整路径；多个文件逐行拼接。
    static func copyPaths(_ paths: [String], root: String) -> [MenuAction] {
        [MenuAction(title: "复制相对路径", shortcut: KeyboardShortcut("c", modifiers: [.command, .shift])) {
            copyToPasteboard(pathText(paths, root: nil))
        },
        MenuAction(title: "复制完整路径", shortcut: KeyboardShortcut("c")) {
            copyToPasteboard(pathText(paths, root: root))
        }]
    }

    /// 单个文件：在编辑器打开 / 在文件夹中显示。
    @MainActor
    static func openFile(_ path: String, editable: Bool = true, workspace: Workspace?) -> [MenuAction] {
        [MenuAction(title: "在编辑器打开", enabled: editable,
                    shortcut: KeyboardShortcut("e", modifiers: [.command, .shift])) { workspace?.openEditor(path) },
         MenuAction(title: "在文件夹中显示", shortcut: KeyboardShortcut("r", modifiers: [.command, .shift])) {
             workspace?.revealInFileManager(path)
         }]
    }
}

/// `root` 非空时拼成完整路径。
private func pathText(_ paths: [String], root: String?) -> String {
    paths.map { path in root.map { $0 + "/" + path } ?? path }.joined(separator: "\n")
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// 各组菜单项，组间以分隔线隔开。
struct MenuActionGroups: View {
    let groups: [[MenuAction]]

    var body: some View {
        let groups = groups.filter { !$0.isEmpty }
        ForEach(groups.indices, id: \.self) { index in
            if index > 0 {
                Divider()
            }
            ForEach(groups[index].indices, id: \.self) { item in
                let menu = groups[index][item]
                Button(menu.title, action: menu.action).disabled(!menu.enabled).keyboardShortcut(menu.shortcut)
            }
        }
    }
}

extension View {
    /// 可用项同时暴露为命名动作与子按钮（Peekaboo 等只认 AXPress 的工具按子按钮操作）。
    /// 二者都不受 `.disabled` 约束，因此只暴露当前可用项。
    /// 去掉快捷键提示，避免隐藏子按钮注册按键。
    func accessibilityMenuActions(_ actions: [MenuAction]) -> some View {
        let actions = actions.filter(\.enabled).map { MenuAction(title: $0.title, action: $0.action) }
        return accessibilityActions { MenuActionGroups(groups: [actions]) }
            .accessibilityChildren { MenuActionGroups(groups: [actions]) }
    }

    /// 焦点在列表时按菜单项快捷键执行可用项；只作用于该列表，文本视图的 ⌘C 等不受影响。
    /// 无匹配可用项时放行按键。
    func menuShortcuts(_ actions: @escaping () -> [MenuAction]) -> some View {
        onKeyPress(phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            let key = String(press.key.character).lowercased()
            let match = actions().first { action in
                guard action.enabled, let shortcut = action.shortcut else { return false }
                return String(shortcut.key.character) == key && shortcut.modifiers == press.modifiers
            }
            guard let match else { return .ignored }
            match.action()
            return .handled
        }
    }

    func menuActions(_ groups: [[MenuAction]]) -> some View {
        contextMenu { MenuActionGroups(groups: groups) }.accessibilityMenuActions(groups.flatMap(\.self))
    }

    /// 列表行合并为单个辅助功能元素：AXPress 只做选择 / 打开，变更操作走子按钮 / 命名动作。
    func accessibilityRow(_ label: String, press: @escaping () -> Void) -> some View {
        accessibilityElement(children: .ignore).accessibilityLabel(label)
            .accessibilityAddTraits(.isButton).accessibilityAction(.default, press)
    }
}
