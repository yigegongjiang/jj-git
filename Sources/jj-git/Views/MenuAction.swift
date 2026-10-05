import SwiftUI

/// 右键菜单项：同一份定义渲染菜单，并暴露为辅助功能命名动作（AX 动作名 `Name:<title>`）。
struct MenuAction {
    let title: String
    var enabled = true
    let action: () -> Void
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
                Button(menu.title, action: menu.action).disabled(!menu.enabled)
            }
        }
    }
}

extension View {
    /// 可用项同时暴露为命名动作与子按钮（Peekaboo 等只认 AXPress 的工具按子按钮操作）。
    /// 二者都不受 `.disabled` 约束，因此只暴露当前可用项。
    func accessibilityMenuActions(_ actions: [MenuAction]) -> some View {
        accessibilityActions { MenuActionGroups(groups: [actions.filter(\.enabled)]) }
            .accessibilityChildren { MenuActionGroups(groups: [actions.filter(\.enabled)]) }
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
