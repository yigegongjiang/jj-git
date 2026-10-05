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
                Button { newGroup = true } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.plain).help("新建分组")
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
                            .onDrag { dragProvider(.group(group.id)) }
                            .modifier(dropDestination(.group(group.id, after: false)))
                            .help("拖拽调整分组顺序；拖入仓库移动到此分组")
                            .contextMenu {
                                groupOrderMenu(group)
                                Divider()
                                Button("重命名分组") { editingGroup = group }
                                Button("删除分组") { workspace.deleteGroup(group.id) }
                            }
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
                Spacer()
                Button { workspace.chooseRepository(scan: true) } label: {
                    Label("扫描", systemImage: "magnifyingglass")
                }.disabled(workspace.scanning)
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
            }
            .padding(.vertical, 3)
            .foregroundStyle(marker?.color ?? (workspace.library.selectedPath == repository.path
                    ? Theme.accent : Theme.foreground))
            .background(workspace.library.selectedPath == repository.path
                ? Theme.accent.opacity(0.12) : .clear)
            .onDrag { dragProvider(.repository(repository.path)) }
            .modifier(dropDestination(.repository(repository.path, after: false)))
            .help("\(repository.path)\n拖拽调整顺序或移动到分组")
            .accessibilityValue(marker?.title ?? "默认颜色")
            .contextMenu {
                Button("打开仓库") { Task { await workspace.open(repository.path) } }
                repositoryOrderMenu(repository)
                Divider()
                colorPicker(repository).pickerStyle(.menu)
                groupPicker(repository)
                Button("在终端打开") { workspace.openTerminal(repository.path) }
                Button("在编辑器打开") { workspace.openEditor(repository.path) }
                Divider()
                Button("从列表移除") { workspace.remove(repository.path) }
                    .disabled(workspace.sessions[repository.path]?.operation != nil)
            }
        }
    }

    private func groupPicker(_ repository: SavedRepository) -> some View {
        Menu("移动到分组") {
            Button("未分组") { workspace.move(repository.path, to: nil) }
            ForEach(workspace.orderedGroups) { group in
                Button(group.name) { workspace.move(repository.path, to: group.id) }
            }
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

    @ViewBuilder
    private func repositoryOrderMenu(_ repository: SavedRepository) -> some View {
        let items = workspace.orderedRepositories(in: repository.groupID)
        let index = items.firstIndex(where: { $0.path == repository.path }) ?? 0
        Button("上移") {
            workspace.reorderRepository(repository.path, relativeTo: items[index - 1].path, after: false)
        }.disabled(index == 0)
        Button("下移") {
            workspace.reorderRepository(repository.path, relativeTo: items[index + 1].path, after: true)
        }.disabled(index + 1 >= items.count)
    }

    @ViewBuilder
    private func groupOrderMenu(_ group: RepositoryGroup) -> some View {
        let items = workspace.orderedGroups
        let index = items.firstIndex(where: { $0.id == group.id }) ?? 0
        Button("上移") {
            workspace.reorderGroup(group.id, relativeTo: items[index - 1].id, after: false)
        }.disabled(index == 0)
        Button("下移") {
            workspace.reorderGroup(group.id, relativeTo: items[index + 1].id, after: true)
        }.disabled(index + 1 >= items.count)
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
            .help(workspace.library.sidebarHidden ? "显示侧边栏 ⌃⌘S" : "隐藏侧边栏 ⌃⌘S")
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
                        HStack(spacing: 8) {
                            Button { workspace.select(path) } label: {
                                HStack(spacing: 5) {
                                    if workspace.sessions[path]?.operation != nil {
                                        ProgressView().controlSize(.mini)
                                    }
                                    Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1)
                                        .foregroundStyle(mounted ? Theme.foreground : Theme.badge)
                                }
                            }.buttonStyle(.plain)
                            Button { workspace.close(path) } label: {
                                Image(systemName: "xmark").font(.ui(-3))
                            }
                            .buttonStyle(.plain).help("关闭标签 ⌘W")
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
                        ThemedDivider().frame(height: 18)
                    }
                }
                // 撑满可见宽度，标签右侧空白也能拖动 / 双击缩放窗口。
                .frame(minWidth: proxy.size.width, alignment: .leading).windowDragArea()
            }.scrollIndicators(.hidden)
        }.frame(height: 32)
    }
}

/// 仓库检索：输入筛选，↑↓ 选择，回车打开，Esc 关闭。
struct RepositoryPickerView: View {
    let workspace: Workspace
    var allRepositories = false
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    private var repositories: [SavedRepository] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if allRepositories {
            return workspace.sidebarRepositories(matching: term)
        }
        return workspace.recentRepositories(matching: term)
    }

    var body: some View {
        let items = repositories
        VStack(spacing: 0) {
            TextField(allRepositories ? "全部仓库（输入名称或路径筛选）" : "最近仓库（输入名称筛选）", text: $query)
                .textFieldStyle(.plain).font(.ui(1)).padding(10)
                .focused($focused)
                .onSubmit { open(items) }
                .onKeyPress(.upArrow) { move(-1, count: items.count) }
                .onKeyPress(.downArrow) { move(1, count: items.count) }
                .onKeyPress(.escape) {
                    dismiss()
                    return .handled
                }
            ThemedDivider()
            if items.isEmpty {
                Text(query.isEmpty ? (allRepositories ? "没有仓库" : "没有其他仓库") : "无匹配仓库")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(16)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { offset, repository in
                                row(repository, selected: offset == index).id(offset)
                                    .onTapGesture {
                                        index = offset
                                        open(items)
                                    }
                            }
                        }.padding(.vertical, 4)
                    }
                    .frame(maxHeight: 520).fixedSize(horizontal: false, vertical: true)
                    .onChange(of: index) { _, value in proxy.scrollTo(value) }
                }
            }
        }
        .frame(width: 520).themed()
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in index = 0 }
    }

    private func row(_ repository: SavedRepository, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(repository.name).lineLimit(1)
                .foregroundStyle(workspace.library.tabs.contains(repository.path) ? Theme.foreground : Theme.badge)
            Spacer(minLength: 12)
            Text((repository.path as NSString).abbreviatingWithTildeInPath).foregroundStyle(.secondary)
                .font(.ui(-2)).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(selected ? Theme.accent.opacity(0.2) : .clear)
        .contentShape(Rectangle())
        .help(repository.path)
    }

    private func move(_ offset: Int, count: Int) -> KeyPress.Result {
        guard count > 0 else { return .handled }
        index = (index + offset + count) % count
        return .handled
    }

    private func open(_ items: [SavedRepository]) {
        guard items.indices.contains(index) else { return }
        let path = items[index].path
        dismiss()
        Task { await workspace.open(path) }
    }
}
