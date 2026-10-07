import SwiftUI

/// 工具栏「自定义操作」：`customActions` 按顺序列出，未配置时提示配置键；执行中显示进度。
struct CustomActionMenu: View {
    let workspace: Workspace
    let session: RepositorySession

    /// 有操作执行时不可用。
    private var actions: [MenuAction] {
        workspace.config.customActions.map { action in
            MenuAction(title: action.name, enabled: session.operation == nil) { session.run(action) }
        }
    }

    var body: some View {
        let openConfig = MenuAction(title: "打开配置文件") { workspace.openConfig() }
        Menu {
            if actions.isEmpty {
                Text("未配置：config.jsonc → customActions")
            }
            MenuActionGroups(groups: [actions, [openConfig]])
        } label: {
            Label {
                Text("自定义操作")
            } icon: {
                if case .custom = session.operationAction {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "play.circle")
                }
            }.labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden).fixedSize()
        .help("自定义操作").accessibilityLabel("自定义操作").accessibilityIdentifier("toolbar.custom-actions")
        .accessibilityMenuActions(actions + [openConfig])
    }
}
