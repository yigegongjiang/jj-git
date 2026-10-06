import SwiftUI

/// 右键菜单项：同一份定义渲染菜单，并暴露为辅助功能命名动作（AX 动作名 `Name:<title>`）。
struct MenuAction {
    let title: String
    var enabled = true
    /// 仅在右键菜单中显示提示；实际按键由 `copyPathShortcuts` 等处理。
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

    /// 焦点在文件列表时：⌘C 复制完整路径，⇧⌘C 复制相对路径；只作用于该列表，文本视图的 ⌘C 不受影响。
    /// `paths` 为空时放行按键。
    func copyPathShortcuts(root: String, paths: @escaping () -> [String]) -> some View {
        onKeyPress(characters: CharacterSet(charactersIn: "cC"), phases: .down) { press in
            let paths = paths()
            let full = press.modifiers == .command
            guard full || press.modifiers == [.command, .shift], !paths.isEmpty else { return .ignored }
            copyToPasteboard(pathText(paths, root: full ? root : nil))
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
