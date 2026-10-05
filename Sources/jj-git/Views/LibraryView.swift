import SwiftUI

struct LibraryView: View {
    @Bindable var workspace: Workspace
    @State private var draggedItem: SidebarItem?
    @State private var dropTarget: SidebarDropTarget?
    @State private var dragToken = UUID().uuidString
    @State private var newGroup = false
    @State private var editingGroup: RepositoryGroup?

    var body: some View {
        VStack(spacing: 0) {
            WindowBar {
                SidebarToggle(workspace: workspace)
                if let tag = DebugInstance.tag {
                    Text(tag).font(.ui(-2)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Menu {
                    Text("拖拽仓库或分组调整顺序")
                    Divider()
                    Button("按名称排序") { workspace.sortSidebarByName() }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("排序：拖拽仓库或分组调整顺序").accessibilityLabel("仓库与分组排序")
                    .accessibilityMenuActions([MenuAction(title: "按名称排序") { workspace.sortSidebarByName() }])
                Button { newGroup = true } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.plain).help("新建分组").accessibilityLabel("新建分组")
            }
            .background(Theme.titleBar)
            ThemedDivider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if !workspace.library.groups.isEmpty {
                        Text("未分组").font(.ui(-1, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 3)
                            .modifier(dropDestination(.intoGroup(nil)))
                    }
                    repositories(in: nil)
                    ForEach(workspace.orderedGroups) { group in
                        Section {
                            if !group.collapsed {
                                repositories(in: group.id)
                            }
                        } header: {
                            Button { workspace.toggleGroup(group.id) } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: group.collapsed ? "chevron.right" : "chevron.down")
                                        .font(.ui(-3, weight: .semibold)).frame(width: 10)
                                    Text(group.name).font(.ui(-1, weight: .semibold))
                                    Spacer(minLength: 0)
                                }
                                .foregroundStyle(.secondary).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("分组 \(group.name)")
                            .accessibilityValue(group.collapsed ? "已折叠" : "已展开")
                            .onDrag { dragProvider(.group(group.id)) }
                            .modifier(dropDestination(.group(group.id, after: false)))
                            .help("拖拽调整分组顺序；拖入仓库移动到此分组")
                            .menuActions([groupOrderActions(group), [
                                MenuAction(title: "重命名分组") { editingGroup = group },
                                MenuAction(title: "删除分组") { workspace.deleteGroup(group.id) }
                            ]])
                        }
                    }
                }
                .padding(10)
            }
            Spacer(minLength: 0)
            if workspace.scanning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(workspace.scanProgress).lineLimit(1)
                    Button("取消") { workspace.cancelScan() }.buttonStyle(.borderless)
                }.font(.ui(-2)).padding(8)
            } else if !workspace.scanProgress.isEmpty {
                Text(workspace.scanProgress).font(.ui(-2)).foregroundStyle(.secondary).padding(8)
            }
            ThemedDivider()
            HStack {
                Button { workspace.chooseRepository() } label: { Label("打开", systemImage: "folder") }
                    .accessibilityIdentifier("library.open")
                Spacer()
                Button { workspace.chooseRepository(scan: true) } label: {
                    Label("扫描", systemImage: "magnifyingglass")
                }.disabled(workspace.scanning).accessibilityIdentifier("library.scan")
            }.buttonStyle(.borderless).padding(10)
        }
        .sheet(isPresented: $newGroup) {
            NamePrompt(title: "新建仓库分组", initial: "") { workspace.addGroup($0) }
                .dismissOnBackgroundClick()
        }
        .sheet(item: $editingGroup) { group in
            NamePrompt(title: "重命名分组", initial: group.name) { workspace.renameGroup(group.id, name: $0) }
                .dismissOnBackgroundClick()
        }
    }

    private func repositories(in groupID: UUID?) -> some View {
        ForEach(workspace.orderedRepositories(in: groupID)) { repository in
            let marker = repository.color.flatMap(RepositoryColor.init(rawValue:))
            let selected = workspace.library.selectedPath == repository.path
            HStack(spacing: 6) {
                repositoryIcon(repository)
                Button {
                    Task { await workspace.open(repository.path) }
                } label: {
                    HStack(spacing: 6) {
                        Text(repository.name).lineLimit(1)
                        Spacer(minLength: 0)
                        if workspace.opening.contains(repository.path) {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(repository.name)
                    .accessibilityValue((selected ? "当前标签，" : "") + (marker?.title ?? "默认颜色"))
                    .accessibilityHint(repository.path)
                    .accessibilityMenuActions(repositoryActions(repository).flatMap(\.self)
                        + moveActions(repository, prefix: "移动到分组："))
            }
            .padding(.vertical, 3)
            .foregroundStyle(marker?.color ?? (selected ? Theme.accent : Theme.foreground))
            .background(selected ? Theme.accent.opacity(0.12) : .clear)
            .onDrag { dragProvider(.repository(repository.path)) }
            .modifier(dropDestination(.repository(repository.path, after: false)))
            .help("\(repository.path)\n拖拽调整顺序或移动到分组")
            .contextMenu {
                let groups = repositoryActions(repository)
                MenuActionGroups(groups: [groups[0]])
                Divider()
                colorPicker(repository).pickerStyle(.menu)
                Menu("移动到分组") { MenuActionGroups(groups: [moveActions(repository, prefix: "")]) }
                MenuActionGroups(groups: Array(groups[1...]))
            }
        }
    }

    /// 打开 + 排序 / 外部工具 / 移除；颜色与分组单独渲染（颜色由图标菜单暴露给辅助功能）。
    private func repositoryActions(_ repository: SavedRepository) -> [[MenuAction]] {
        [
            [MenuAction(title: "打开仓库") { Task { await workspace.open(repository.path) } }]
                + repositoryOrderActions(repository),
            [
                MenuAction(title: "在终端打开") { workspace.openTerminal(repository.path) },
                MenuAction(title: "在编辑器打开") { workspace.openEditor(repository.path) }
            ],
            [MenuAction(title: "从列表移除", enabled: workspace.sessions[repository.path]?.operation == nil) {
                workspace.remove(repository.path)
            }]
        ]
    }

    private func moveActions(_ repository: SavedRepository, prefix: String) -> [MenuAction] {
        [MenuAction(title: prefix + "未分组") { workspace.move(repository.path, to: nil) }]
            + workspace.orderedGroups.map { group in
                MenuAction(title: prefix + group.name) { workspace.move(repository.path, to: group.id) }
            }
    }

    private func dragProvider(_ item: SidebarItem) -> NSItemProvider {
        draggedItem = item
        dropTarget = nil
        let provider = NSItemProvider()
        let payload = Data("\(dragToken)\n\(item.payload)".utf8)
        provider.registerDataRepresentation(
            forTypeIdentifier: SidebarDropModifier.type.identifier, visibility: .ownProcess
        ) { completion in
            completion(payload, nil)
            return nil
        }
        return provider
    }

    private func dropDestination(_ destination: SidebarDropTarget) -> SidebarDropModifier {
        SidebarDropModifier(destination: destination, draggedItem: $draggedItem, target: $dropTarget,
                            token: dragToken, workspace: workspace)
    }

    private func repositoryOrderActions(_ repository: SavedRepository) -> [MenuAction] {
        let items = workspace.orderedRepositories(in: repository.groupID)
        let index = items.firstIndex(where: { $0.path == repository.path }) ?? 0
        return [
            MenuAction(title: "上移", enabled: index > 0) {
                workspace.reorderRepository(repository.path, relativeTo: items[index - 1].path, after: false)
            },
            MenuAction(title: "下移", enabled: index + 1 < items.count) {
                workspace.reorderRepository(repository.path, relativeTo: items[index + 1].path, after: true)
            }
        ]
    }

    private func groupOrderActions(_ group: RepositoryGroup) -> [MenuAction] {
        let items = workspace.orderedGroups
        let index = items.firstIndex(where: { $0.id == group.id }) ?? 0
        return [
            MenuAction(title: "上移", enabled: index > 0) {
                workspace.reorderGroup(group.id, relativeTo: items[index - 1].id, after: false)
            },
            MenuAction(title: "下移", enabled: index + 1 < items.count) {
                workspace.reorderGroup(group.id, relativeTo: items[index + 1].id, after: true)
            }
        ]
    }

    private func repositoryIcon(_ repository: SavedRepository) -> some View {
        let marker = repository.color.flatMap(RepositoryColor.init(rawValue:))
        return Image(systemName: marker == nil ? "folder" : "folder.fill")
            .foregroundStyle(marker?.color ?? .secondary)
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
            .overlay {
                Menu {
                    colorPicker(repository).pickerStyle(.inline)
                } label: {
                    Color.clear.frame(width: 18, height: 18)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("仓库颜色").accessibilityLabel("\(repository.name) 仓库颜色")
                .accessibilityMenuActions(colorActions(repository))
            }
    }

    private func colorActions(_ repository: SavedRepository) -> [MenuAction] {
        [MenuAction(title: "颜色：默认") { workspace.setRepositoryColor(repository.path, color: nil) }]
            + RepositoryColor.allCases.map { color in
                MenuAction(title: "颜色：" + color.title) {
                    workspace.setRepositoryColor(repository.path, color: color.rawValue)
                }
            }
    }

    private func colorPicker(_ repository: SavedRepository) -> some View {
        Picker("仓库颜色", selection: Binding(
            get: { repository.color.flatMap(RepositoryColor.init(rawValue:))?.rawValue ?? "" },
            set: { workspace.setRepositoryColor(repository.path, color: $0.isEmpty ? nil : $0) }
        )) {
            Text("默认").tag("")
            ForEach(RepositoryColor.allCases, id: \.rawValue) { color in
                Text(color.title).tag(color.rawValue)
            }
        }
    }
}

private enum RepositoryColor: String, CaseIterable {
    case red, orange, yellow, green, cyan, purple, pink

    var title: String {
        switch self {
        case .red: "红色"
        case .orange: "橙色"
        case .yellow: "黄色"
        case .green: "绿色"
        case .cyan: "青色"
        case .purple: "紫色"
        case .pink: "粉色"
        }
    }

    var color: Color {
        switch self {
        case .red: Theme.deleted
        case .orange: Theme.orange
        case .yellow: Color(.sRGB, red: 241 / 255, green: 250 / 255, blue: 140 / 255)
        case .green: Theme.green
        case .cyan: Color(.sRGB, red: 139 / 255, green: 233 / 255, blue: 253 / 255)
        case .purple: Theme.accent
        case .pink: Color(.sRGB, red: 255 / 255, green: 121 / 255, blue: 198 / 255)
        }
    }
}

struct SidebarToggle: View {
    let workspace: Workspace

    var body: some View {
        Button { workspace.toggleSidebar() } label: { Image(systemName: "sidebar.left") }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help(workspace.library.sidebarHidden ? "显示侧边栏 ⇧⌘S" : "隐藏侧边栏 ⇧⌘S")
            .accessibilityLabel(workspace.library.sidebarHidden ? "显示侧边栏" : "隐藏侧边栏")
            .accessibilityIdentifier("sidebar.toggle")
    }
}

struct RepositoryTabs: View {
    @Bindable var workspace: Workspace

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(workspace.library.tabs, id: \.self) { path in
                        let mounted = workspace.sessions[path] != nil
                        let name = URL(fileURLWithPath: path).lastPathComponent
                        HStack(spacing: 8) {
                            Button { workspace.select(path) } label: {
                                HStack(spacing: 5) {
                                    if workspace.sessions[path]?.operation != nil {
                                        ProgressView().controlSize(.mini)
                                    }
                                    Text(name).lineLimit(1)
                                        .foregroundStyle(mounted ? Theme.foreground : Theme.badge)
                                }
                            }.buttonStyle(.plain)
                                .accessibilityLabel(name).accessibilityIdentifier("tab")
                                .accessibilityValue(workspace.library.selectedPath == path ? "当前标签"
                                    : mounted ? "" : "未挂载")
                                .accessibilityAddTraits(workspace.library.selectedPath == path ? .isSelected : [])
                                .accessibilityHint(path)
                                .accessibilityMenuActions(tabActions(path).flatMap(\.self))
                            Button { workspace.close(path) } label: {
                                Image(systemName: "xmark").font(.ui(-3))
                            }
                            .buttonStyle(.plain).help("关闭标签 ⌘W").accessibilityLabel("关闭 \(name)")
                            .disabled(workspace.sessions[path]?.operation != nil)
                        }
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(workspace.library.selectedPath == path ? Theme.accent.opacity(0.12) : .clear)
                        .overlay(alignment: .bottom) {
                            if workspace.library.selectedPath == path {
                                Theme.accent.frame(height: 2)
                            }
                        }
                        .help(mounted ? path : "未挂载，点击重新加载\n\(path)")
                        .contextMenu { MenuActionGroups(groups: tabActions(path)) }
                        ThemedDivider().frame(height: 18)
                    }
                }
                // 撑满可见宽度，标签右侧空白也能拖动 / 双击缩放窗口。
                .frame(minWidth: proxy.size.width, alignment: .leading).windowDragArea()
            }.scrollIndicators(.hidden)
        }.frame(height: 32)
    }

    private func tabActions(_ path: String) -> [[MenuAction]] {
        let tabs = workspace.library.tabs
        let index = tabs.firstIndex(of: path) ?? 0
        let left = Array(tabs[..<index]), right = Array(tabs[(index + 1)...])
        return [
            [MenuAction(title: "关闭标签", enabled: workspace.sessions[path]?.operation == nil) {
                workspace.close(path)
            }],
            [
                MenuAction(title: "关闭其他标签", enabled: tabs.count > 1) {
                    workspace.close(left + right, keeping: path)
                },
                MenuAction(title: "关闭左侧标签", enabled: !left.isEmpty) { workspace.close(left, keeping: path) },
                MenuAction(title: "关闭右侧标签", enabled: !right.isEmpty) { workspace.close(right, keeping: path) }
            ]
        ]
    }
}
