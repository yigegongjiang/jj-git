import SwiftUI

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
                .accessibilityIdentifier("picker.query")
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
                                Button {
                                    index = offset
                                    open(items)
                                } label: { row(repository, selected: offset == index) }
                                    .buttonStyle(.plain).id(offset)
                                    .accessibilityLabel(repository.name).accessibilityHint(repository.path)
                                    .accessibilityIdentifier("picker.row")
                            }
                        }.padding(.vertical, 4)
                    }
                    .scrollerGutter().frame(maxHeight: 520).fixedSize(horizontal: false, vertical: true)
                    .onChange(of: index) { _, value in proxy.scrollTo(value) }
                }
            }
        }
        .frame(width: 520).themed()
        .accessibilityAction(.escape) { dismiss() }
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
