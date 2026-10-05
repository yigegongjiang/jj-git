import SwiftUI

struct RepositoryView: View {
    let workspace: Workspace
    @Bindable var session: RepositorySession
    @State private var dialog: RepositoryDialog?
    @State private var showOperationOutput = false

    private var pullHelp: String {
        let pull = workspace.config.pull
        return (pull.rebase ? "Rebase 到上游" : "Merge 上游") + (pull.autostash ? "，本地变更自动贮藏后恢复" : "") + " ⇧⌘P"
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ThemedDivider()
            if let error = session.error {
                WarningBanner {
                    ScrollView {
                        Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 80)
                } actions: {
                    Button { session.error = nil } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭错误提示").help("关闭错误提示")
                }
            }
            if let operation = session.interruptedOperation {
                WarningBanner {
                    Text("\(operation)：请在终端完成或中止当前操作。")
                } actions: {
                    Button("打开终端") { workspace.openTerminal(session.location.root) }
                }
            }
            SplitPane(name: "repository.sidebar", initial: 170, minimum: (130, 480)) {
                RepositorySidebar(workspace: workspace, session: session, dialog: $dialog)
            } second: {
                if session.section == .changes {
                    ChangesView(workspace: workspace, session: session)
                } else {
                    HistoryView(session: session, dialog: $dialog)
                }
            }
            ThemedDivider()
            statusBar
        }
        .sheet(item: $dialog) {
            ActionDialog(dialog: $0, session: session).themed().dismissOnBackgroundClick()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Label(session.status.detached ? String(session.status.head.prefix(8)) : session.status.branch,
                  systemImage: "arrow.triangle.branch")
                .font(.ui(weight: .semibold)).lineLimit(1).help(session.location.root)
            Text("↑\(session.status.ahead) ↓\(session.status.behind)").font(.ui(-2)).foregroundStyle(.secondary)
            Spacer(minLength: 5)
            Button { session.fetch() } label: {
                Label("Fetch", systemImage: "arrow.down.to.line")
            }
            .disabled(session.remotes.isEmpty || session.operation != nil)
            Button { session.perform(.pull, title: "Pull") } label: { Label("Pull", systemImage: "arrow.down") }
                .disabled(session.status.upstream.isEmpty || session.operation != nil)
                .help(pullHelp)
            Menu {
                Button("Push…") { dialog = .push(force: false) }
                Button("强制推送（force-with-lease）…") { dialog = .push(force: true) }
            } label: { Label("Push", systemImage: "arrow.up") }
                .fixedSize().disabled(session.remotes.isEmpty || session.status.detached || session.operation != nil)
            ThemedDivider().frame(height: 16)
            Button { workspace.openTerminal(session.location.root) } label: { Image(systemName: "terminal") }
                .help("在终端打开 ⇧⌘T")
            Button { workspace.openEditor(session.location.root) } label: {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
            }
            .help("在编辑器打开 ⇧⌘E")
            Button { session.refresh(forceHistory: true) } label: { Image(systemName: "arrow.clockwise") }
                .help("刷新 ⌘R").disabled(session.operation != nil)
        }.buttonStyle(.borderless).controlSize(.small).padding(.horizontal, 10).frame(height: 32)
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            if let operation = session.operation {
                ProgressView().controlSize(.mini)
                Text(operation + "…")
                Button("取消") { session.cancelOperation() }.buttonStyle(.borderless)
            } else if !session.notice.isEmpty {
                Button { showOperationOutput.toggle() } label: {
                    Label(session.notice.components(separatedBy: "\n").first ?? "操作完成", systemImage: "checkmark.circle")
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showOperationOutput) {
                    ScrollView { Text(session.notice).textSelection(.enabled).padding(12) }.themed().frame(
                        width: 520,
                        height: 220
                    )
                }
            } else {
                Text(session.location.root).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            }
            Spacer()
            if session.refreshing {
                ProgressView().controlSize(.mini)
            }
            Text("\(session.status.changes.count) 个变更").foregroundStyle(.secondary)
        }.font(.ui(-1)).padding(.horizontal, 10).frame(height: 26)
    }
}

struct RepositorySidebar: View {
    let workspace: Workspace
    @Bindable var session: RepositorySession
    @Binding var dialog: RepositoryDialog?

    /// Unstaged (orange) / staged (green) file counts; same split as the change lists.
    @ViewBuilder private var changeCounts: some View {
        let changes = session.status.changes
        let unstaged = changes.count(where: \.unstaged)
        let staged = changes.count(where: \.staged)
        if unstaged > 0 {
            countBadge(unstaged, color: Theme.orange).help("未暂存 \(unstaged) 个文件")
        }
        if staged > 0 {
            countBadge(staged, color: Theme.green).help("已暂存 \(staged) 个文件")
        }
    }

    private func countBadge(_ count: Int, color: Color) -> some View {
        Text("\(count)").font(.ui(-2, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.window)
            .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 15)
            .background(color, in: Capsule())
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 7) {
                ForEach(RepositorySection.allCases) { section in
                    Button { session.changeSection(section) } label: {
                        HStack(spacing: 4) {
                            Label(
                                section.rawValue,
                                systemImage: section == .changes ? "square.and.pencil" : "clock.arrow.circlepath"
                            )
                            .foregroundStyle(session.section == section ? Theme.accent : Theme.foreground)
                            Spacer(minLength: 0)
                            if section == .changes {
                                changeCounts
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.vertical, 3)
                }
                let local = session.references.filter { !$0.remote && !$0.tag }
                let remote = session.references.filter(\.remote)
                let tags = session.references.filter(\.tag)
                let worktrees = session.worktrees.filter { !$0.bare }
                Section {
                    if expanded("localBranches") {
                        ForEach(local) { branch in branchRow(branch) }
                    }
                } header: {
                    heading("本地分支", key: "localBranches", count: local.count, shortcut: "b") {
                        dialog = .branch(start: "HEAD")
                    }
                }
                Section {
                    if expanded("remoteBranches") {
                        ForEach(remote) { branch in branchRow(branch) }
                    }
                } header: { heading("远端分支", key: "remoteBranches", count: remote.count, action: nil) }
                Section {
                    if expanded("tags") {
                        ForEach(tags) { tag in
                            Label(tag.name, systemImage: "tag").lineLimit(1).help(tag.name)
                                .contextMenu {
                                    Button("推送标签…") { dialog = .pushTag(tag) }.disabled(session.remotes.isEmpty)
                                    Button("删除标签…") { dialog = .deleteTag(tag) }
                                }
                        }
                    }
                } header: { heading("标签", key: "tags", count: tags.count) { dialog = .tag(target: "HEAD") } }
                Section {
                    if expanded("remotes") {
                        ForEach(session.remotes) { remote in
                            Label(remote.name, systemImage: "network").help(remote.url)
                                .contextMenu { Button("编辑远程…") { dialog = .remote(remote) } }
                        }
                    }
                } header: { heading("远程", key: "remotes", count: session.remotes.count) { dialog = .remote(nil) } }
                Section {
                    if expanded("worktrees") {
                        ForEach(worktrees) { tree in worktreeRow(tree) }
                    }
                } header: { heading("工作树", key: "worktrees", count: worktrees.count, action: nil) }
            }.padding(10)
        }
    }

    private func expanded(_ key: String) -> Bool {
        !workspace.library.collapsedSections.contains(key)
    }

    private func worktreeRow(_ tree: GitWorktree) -> some View {
        let current = tree.path == session.location.root
        return Button { Task { await workspace.open(tree.path) } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: current ? "checkmark" : "folder.badge.gearshape")
                VStack(alignment: .leading, spacing: 1) {
                    Text(URL(fileURLWithPath: tree.path).lastPathComponent)
                        .lineLimit(1).font(.ui(weight: current ? .semibold : .regular))
                    Text(tree.branch.isEmpty ? String(tree.head.prefix(8))
                        : tree.branch.replacingOccurrences(of: "refs/heads/", with: ""))
                        .font(.ui(-1)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).help(tree.path).disabled(tree.prunable)
    }

    private func heading(
        _ text: String, key: String, count: Int, shortcut: KeyEquivalent? = nil, action: (() -> Void)?
    ) -> some View {
        HStack {
            Button { workspace.toggleSection(key) } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded(key) ? "chevron.down" : "chevron.right")
                        .font(.ui(-3, weight: .semibold)).frame(width: 10)
                    Text(text).font(.ui(-1, weight: .semibold))
                    Text("\(count)").font(.ui(-2).monospacedDigit())
                }
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            if let action {
                let button = Button(action: action) { Image(systemName: "plus") }.buttonStyle(.plain)
                    .disabled(session.operation != nil || (text != "远程" && session.status.unborn))
                if let shortcut {
                    button.keyboardShortcut(shortcut, modifiers: .command)
                        .help("新建（⌘\(shortcut.character.uppercased())）")
                } else {
                    button.help("新建")
                }
            }
        }.padding(.top, 4)
    }

    private func branchRow(_ branch: GitReference) -> some View {
        HStack(spacing: 5) {
            Image(systemName: branch.current ? "checkmark" : "arrow.triangle.branch")
                .foregroundStyle(branch.current ? Theme.accent : Color.secondary)
            Text(branch.name).lineLimit(1).font(.ui(weight: branch.current ? .semibold : .regular))
        }
        .padding(.vertical, 3)
        .help(branch.name + (branch.checkedOutPath.isEmpty ? "" : "\n" + branch.checkedOutPath))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { session.checkout(branch) }
        .contextMenu {
            let target = branch.remote ? session.localBranch(for: branch) ?? branch : branch
            Button(branch.remote ? "检出为本地分支" : "检出分支") { session.checkout(branch) }
                .disabled(target.current || !target.checkedOutPath.isEmpty || session.operation != nil)
            Button("从此处新建分支…") { dialog = .branch(start: branch.name) }
            if !branch.remote {
                Button("重命名分支…") { dialog = .renameBranch(branch) }
            }
            Button(branch.remote ? "删除远端分支…" : "删除分支…") { dialog = .deleteBranch(branch) }
                .disabled(branch.current || !branch.checkedOutPath.isEmpty)
        }
    }
}
