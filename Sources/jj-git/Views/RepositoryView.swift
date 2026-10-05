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
                .accessibilityIdentifier("toolbar.branch")
            Text("↑\(session.status.ahead) ↓\(session.status.behind)").font(.ui(-2)).foregroundStyle(.secondary)
                .accessibilityLabel("领先 \(session.status.ahead)，落后 \(session.status.behind)")
                .accessibilityIdentifier("toolbar.ahead-behind")
            Spacer(minLength: 5)
            Button { session.fetch() } label: { transferLabel("Fetch", systemImage: "arrow.down.to.line", .fetch) }
                .disabled(session.remotes.isEmpty || session.operation != nil)
                .accessibilityIdentifier("toolbar.fetch")
            Button { session.perform(.pull, title: "Pull") } label: {
                transferLabel("Pull", systemImage: "arrow.down", .pull)
            }
            .disabled(session.status.upstream.isEmpty || session.operation != nil)
            .help(pullHelp).accessibilityIdentifier("toolbar.pull")
            // Menu 标签不渲染 ProgressView，进度指示放在菜单前。
            if session.operationAction?.transfer == .push {
                ProgressView().controlSize(.mini)
            }
            Menu {
                Button("Push…") { dialog = .push(force: false) }
                Button("强制推送（force-with-lease）…") { dialog = .push(force: true) }
            } label: { Label("Push", systemImage: "arrow.up") }
                .fixedSize().disabled(session.remotes.isEmpty || session.status.detached || session.operation != nil)
                .accessibilityIdentifier("toolbar.push")
            ThemedDivider().frame(height: 16)
            Button { workspace.openTerminal(session.location.root) } label: { Image(systemName: "terminal") }
                .help("在终端打开 ⇧⌘T").accessibilityLabel("在终端打开").accessibilityIdentifier("toolbar.terminal")
            Button { workspace.openEditor(session.location.root) } label: {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
            }
            .help("在编辑器打开 ⇧⌘E").accessibilityLabel("在编辑器打开").accessibilityIdentifier("toolbar.editor")
            Button { session.refresh(forceHistory: true) } label: { Image(systemName: "arrow.clockwise") }
                .help("刷新 ⌘R").disabled(session.operation != nil)
                .accessibilityLabel("刷新").accessibilityIdentifier("toolbar.refresh")
        }.buttonStyle(.borderless).controlSize(.small).padding(.horizontal, 10).frame(height: 32)
    }

    /// 正在执行的同步操作在其按钮上显示进度，点击处即可看到反馈。
    private func transferLabel(_ title: String, systemImage: String,
                               _ transfer: RepositoryAction.Transfer) -> some View {
        Label {
            Text(title)
        } icon: {
            if session.operationAction?.transfer == transfer {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: systemImage)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            if let operation = session.operation {
                operationStatus(operation)
            } else if !session.notice.isEmpty {
                Label(session.notice, systemImage: "checkmark.circle").lineLimit(1).fixedSize()
                    .accessibilityIdentifier("status.notice")
                if let summary = session.operationOutput.split(whereSeparator: \.isNewline).first {
                    Button { showOperationOutput.toggle() } label: {
                        Text(summary).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).help("查看完整输出").accessibilityIdentifier("status.output")
                    .popover(isPresented: $showOperationOutput) {
                        ScrollView { Text(session.operationOutput).textSelection(.enabled).padding(12) }.themed()
                            .frame(width: 520, height: 220)
                    }
                }
            } else {
                Text(session.location.root).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            }
            Spacer()
            if session.refreshing {
                ProgressView().controlSize(.mini)
            }
            Text("\(session.status.changes.count) 个变更").foregroundStyle(.secondary)
                .accessibilityIdentifier("status.changes")
        }.font(.ui(-1)).padding(.horizontal, 10).frame(height: 26)
    }
}

extension RepositoryView {
    /// 操作名 + Git 最新输出（阶段 / 百分比 / 速率）+ 已用时间；有百分比时显示确定进度条。
    private func operationStatus(_ operation: String) -> some View {
        let line = session.operationProgress
        let percent = line.flatMap(Self.percent)
        return Group {
            if let percent {
                ProgressView(value: percent, total: 100).progressViewStyle(.linear).frame(width: 80)
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(line.map { operation + " · " + $0 } ?? operation + "…")
                .lineLimit(1).truncationMode(.middle).monospacedDigit().help(line ?? operation)
            if let started = session.operationStarted {
                Text(timerInterval: started ... .distantFuture, countsDown: false)
                    .monospacedDigit().foregroundStyle(.secondary).fixedSize()
            }
            Button("取消") { session.cancelOperation() }.buttonStyle(.borderless)
                .accessibilityIdentifier("status.cancel")
        }.accessibilityIdentifier("status.operation")
    }

    /// `Writing objects:  45% (9/20)` 中最后一个百分比。
    /// `, done.` = 该阶段已结束、下一阶段尚无输出，显示不确定进度而非满格。
    private static func percent(_ line: String) -> Double? {
        guard !line.hasSuffix("done."), let match = line.matches(of: /(\d{1,3})%/).last,
              let value = Double(match.1), value <= 100 else { return nil }
        return value
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

    private var changeSummary: String {
        let changes = session.status.changes
        return "未暂存 \(changes.count(where: \.unstaged))，已暂存 \(changes.count(where: \.staged))"
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
                        .accessibilityLabel(section.rawValue)
                        .accessibilityValue(section == .changes ? changeSummary : "")
                        .accessibilityAddTraits(session.section == section ? .isSelected : [])
                        .accessibilityIdentifier("section.\(section == .changes ? "changes" : "history")")
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
                                .accessibilityElement(children: .combine).accessibilityLabel("标签 \(tag.name)")
                                .menuActions([[
                                    MenuAction(title: "推送标签…", enabled: !session.remotes.isEmpty) {
                                        dialog = .pushTag(tag)
                                    },
                                    MenuAction(title: "删除标签…") { dialog = .deleteTag(tag) }
                                ]])
                        }
                    }
                } header: { heading("标签", key: "tags", count: tags.count) { dialog = .tag(target: "HEAD") } }
                Section {
                    if expanded("remotes") {
                        ForEach(session.remotes) { remote in
                            Label(remote.name, systemImage: "network").help(remote.url)
                                .accessibilityElement(children: .combine).accessibilityLabel("远程 \(remote.name)")
                                .accessibilityValue(remote.url)
                                .menuActions([[MenuAction(title: "编辑远程…") { dialog = .remote(remote) }]])
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
            .accessibilityLabel("工作树 \(URL(fileURLWithPath: tree.path).lastPathComponent)")
            .accessibilityValue((current ? "当前，" : "") + (tree.branch.isEmpty ? String(tree.head.prefix(8))
                    : tree.branch.replacingOccurrences(of: "refs/heads/", with: "")))
            .accessibilityHint(tree.path)
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
                .accessibilityLabel("\(text) \(count)").accessibilityValue(expanded(key) ? "已展开" : "已折叠")
                .accessibilityIdentifier("heading.\(key)")
            if let action {
                let button = Button(action: action) { Image(systemName: "plus") }.buttonStyle(.plain)
                    .disabled(session.operation != nil || (text != "远程" && session.status.unborn))
                    .accessibilityLabel(text == "远程" ? "添加远程" : "新建\(text == "标签" ? "标签" : "分支")")
                    .accessibilityIdentifier("heading.\(key).add")
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
        // 不设默认 AXPress：检出会改动工作区，只作为命名动作。
        .accessibilityElement(children: .combine)
        .accessibilityLabel((branch.remote ? "远端分支 " : "分支 ") + branch.name)
        .accessibilityValue(branch.current ? "当前分支"
            : branch.checkedOutPath.isEmpty ? "" : "已在 \(branch.checkedOutPath) 检出")
        .menuActions([branchActions(branch)])
    }

    private func branchActions(_ branch: GitReference) -> [MenuAction] {
        let target = branch.remote ? session.localBranch(for: branch) ?? branch : branch
        var actions = [
            MenuAction(title: branch.remote ? "检出为本地分支" : "检出分支",
                       enabled: !target.current && target.checkedOutPath.isEmpty && session.operation == nil) {
                session.checkout(branch)
            },
            MenuAction(title: "从此处新建分支…") { dialog = .branch(start: branch.name) }
        ]
        if !branch.remote {
            actions.append(MenuAction(title: "重命名分支…") { dialog = .renameBranch(branch) })
        }
        actions.append(MenuAction(title: branch.remote ? "删除远端分支…" : "删除分支…",
                                  enabled: !branch.current && branch.checkedOutPath.isEmpty) {
                dialog = .deleteBranch(branch)
            })
        return actions
    }
}
