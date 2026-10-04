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
            Divider()
            if let error = session.error {
                ErrorBanner(message: error) { session.error = nil }
            }
            if let operation = session.interruptedOperation {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text("\(operation)：请在终端完成或中止当前操作。")
                    Spacer()
                    Button("打开终端") { workspace.openTerminal(session.location.root) }
                }.font(.caption).padding(8).background(.orange.opacity(0.1))
            }
            SplitPane(autosave: "repository.sidebar", initial: 170, minimum: (130, 480)) {
                RepositorySidebar(workspace: workspace, session: session, dialog: $dialog)
            } second: {
                if session.section == .changes {
                    ChangesView(workspace: workspace, session: session)
                } else {
                    HistoryView(session: session, dialog: $dialog)
                }
            }
            Divider()
            statusBar
        }
        .sheet(item: $dialog) { ActionDialog(dialog: $0, session: session) }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Label(session.status.detached ? String(session.status.head.prefix(8)) : session.status.branch,
                  systemImage: "arrow.triangle.branch")
                .font(.system(size: 12, weight: .semibold)).lineLimit(1).help(session.location.root)
            Text("↑\(session.status.ahead) ↓\(session.status.behind)").font(.caption).foregroundStyle(.secondary)
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
            Divider().frame(height: 16)
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
                    ScrollView { Text(session.notice).textSelection(.enabled).padding(12) }.frame(
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
        }.font(.system(size: 11)).padding(.horizontal, 10).frame(height: 26)
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
            countBadge(unstaged, color: .orange).help("未暂存 \(unstaged) 个文件")
        }
        if staged > 0 {
            countBadge(staged, color: .green).help("已暂存 \(staged) 个文件")
        }
    }

    private func countBadge(_ count: Int, color: Color) -> some View {
        Text("\(count)").font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
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
                            .foregroundStyle(session.section == section ? Color.accentColor : Color.primary)
                            Spacer(minLength: 0)
                            if section == .changes {
                                changeCounts
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.vertical, 3)
                }
                Section {
                    ForEach(session.references.filter { !$0.remote && !$0.tag }) { branch in branchRow(branch) }
                } header: { heading("本地分支", shortcut: "b") { dialog = .branch(start: "HEAD") } }
                Section {
                    ForEach(session.references.filter(\.remote)) { branch in branchRow(branch) }
                } header: { heading("远端分支", action: nil) }
                Section {
                    ForEach(session.references.filter(\.tag)) { tag in
                        Label(tag.name, systemImage: "tag").lineLimit(1).help(tag.name)
                            .contextMenu {
                                Button("推送标签…") { dialog = .pushTag(tag) }.disabled(session.remotes.isEmpty)
                                Button("删除标签…") { dialog = .deleteTag(tag) }
                            }
                    }
                } header: { heading("标签") { dialog = .tag(target: "HEAD") } }
                Section {
                    ForEach(session.remotes) { remote in
                        Label(remote.name, systemImage: "network").help(remote.url)
                            .contextMenu { Button("编辑远程…") { dialog = .remote(remote) } }
                    }
                } header: { heading("远程") { dialog = .remote(nil) } }
                Section {
                    ForEach(session.worktrees.filter { !$0.bare }) { tree in
                        let current = tree.path == session.location.root
                        Button { Task { await workspace.open(tree.path) } } label: {
                            HStack(spacing: 5) {
                                Label(
                                    URL(fileURLWithPath: tree.path).lastPathComponent,
                                    systemImage: current ? "checkmark" : "folder.badge.gearshape"
                                )
                                .lineLimit(1).fontWeight(current ? .semibold : .regular).layoutPriority(1)
                                Spacer(minLength: 4)
                                Text(tree.branch.isEmpty ? String(tree.head.prefix(8))
                                    : tree.branch.replacingOccurrences(of: "refs/heads/", with: ""))
                                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            .padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).help(tree.path).disabled(tree.prunable)
                    }
                } header: { heading("工作树", action: nil) }
            }.padding(10)
        }.font(.system(size: 12))
    }

    private func heading(_ text: String, shortcut: KeyEquivalent? = nil, action: (() -> Void)?) -> some View {
        HStack {
            Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
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
                .foregroundStyle(branch.current ? Color.accentColor : Color.secondary)
            Text(branch.name).lineLimit(1).fontWeight(branch.current ? .semibold : .regular)
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
