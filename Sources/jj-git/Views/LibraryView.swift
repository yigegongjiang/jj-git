import SwiftUI

struct LibraryView: View {
    @Bindable var workspace: Workspace
    @State private var newGroup = false
    @State private var editingGroup: RepositoryGroup?

    var body: some View {
        VStack(spacing: 0) {
            WindowBar {
                SidebarToggle(workspace: workspace)
                Spacer()
                Button { newGroup = true } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.plain).help("新建分组")
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    repositories(in: nil)
                    ForEach(sortedGroups) { group in
                        Section {
                            if group.collapsed != true {
                                repositories(in: group.id)
                            }
                        } header: {
                            Button { workspace.toggleGroup(group.id) } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: group.collapsed == true ? "chevron.right" : "chevron.down")
                                        .font(.system(size: 9, weight: .semibold)).frame(width: 10)
                                    Text(group.name).font(.system(size: 11, weight: .semibold))
                                    Spacer(minLength: 0)
                                }
                                .foregroundStyle(.secondary).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
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
                }.font(.caption).padding(8)
            } else if !workspace.scanProgress.isEmpty {
                Text(workspace.scanProgress).font(.caption).foregroundStyle(.secondary).padding(8)
            }
            Divider()
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
        }
        .sheet(item: $editingGroup) { group in
            NamePrompt(title: "重命名分组", initial: group.name) { workspace.renameGroup(group.id, name: $0) }
        }
    }

    private var sortedGroups: [RepositoryGroup] {
        workspace.library.groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func repositories(in groupID: UUID?) -> some View {
        ForEach(workspace.library.repositories.filter { $0.groupID == groupID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { repository in
                Button {
                    Task { await workspace.open(repository.path) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(repository.name).lineLimit(1)
                        Spacer(minLength: 0)
                        if workspace.opening.contains(repository.path) {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .padding(.vertical, 3)
                    .foregroundStyle(workspace.library.selectedPath == repository.path ? Color.accentColor : Color
                        .primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(repository.path)
                .contextMenu {
                    Button("打开仓库") { Task { await workspace.open(repository.path) } }
                    Menu("移动到分组") {
                        Button("未分组") { workspace.move(repository.path, to: nil) }
                        ForEach(workspace.library.groups) { group in
                            Button(group.name) { workspace.move(repository.path, to: group.id) }
                        }
                    }
                    Button("在终端打开") { workspace.openTerminal(repository.path) }
                    Button("在编辑器打开") { workspace.openEditor(repository.path) }
                    Divider()
                    Button("从列表移除") { workspace.remove(repository.path) }
                        .disabled(workspace.sessions[repository.path]?.operation != nil)
                }
            }
    }
}

struct SidebarToggle: View {
    let workspace: Workspace

    var body: some View {
        Button { workspace.toggleSidebar() } label: { Image(systemName: "sidebar.left") }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help(workspace.library.sidebarHidden == true ? "显示侧边栏 ⌃⌘S" : "隐藏侧边栏 ⌃⌘S")
    }
}

struct RepositoryTabs: View {
    @Bindable var workspace: Workspace

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(workspace.library.tabs, id: \.self) { path in
                        HStack(spacing: 8) {
                            Button { workspace.select(path) } label: {
                                HStack(spacing: 5) {
                                    if workspace.sessions[path]?.operation != nil {
                                        ProgressView().controlSize(.mini)
                                    }
                                    Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1)
                                        .foregroundStyle(workspace.sessions[path] == nil ? .secondary : .primary)
                                }
                            }.buttonStyle(.plain)
                            Button { workspace.close(path) } label: {
                                Image(systemName: "xmark").font(.system(size: 9))
                            }
                            .buttonStyle(.plain).help("关闭标签 ⌘W")
                            .disabled(workspace.sessions[path]?.operation != nil)
                        }
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(workspace.library.selectedPath == path ? Color.accentColor.opacity(0.12) : .clear)
                        .overlay(alignment: .bottom) {
                            if workspace.library.selectedPath == path {
                                Color.accentColor.frame(height: 2)
                            }
                        }
                        .help(path)
                        Divider().frame(height: 18)
                    }
                }
                // 撑满可见宽度，标签右侧空白也能拖动 / 双击缩放窗口。
                .frame(minWidth: proxy.size.width, alignment: .leading).windowDragArea()
            }.scrollIndicators(.hidden)
        }.frame(height: 32)
    }
}
