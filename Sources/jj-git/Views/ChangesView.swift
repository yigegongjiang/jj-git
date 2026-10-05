import AppKit
import SwiftUI

struct ChangesView: View {
    let workspace: Workspace
    @Bindable var session: RepositorySession

    var body: some View {
        SplitPane(name: "changes.files", initial: 300, minimum: (220, 290)) {
            SplitPane(name: "changes.composer", vertical: true, pinned: .second, initial: 190,
                      minimum: (180, 150)) {
                SplitPane(name: "changes.lists", vertical: true, pinned: nil, initial: 260, minimum: (90, 90)) {
                    ChangeList(workspace: workspace, session: session, staged: false)
                } second: {
                    ChangeList(workspace: workspace, session: session, staged: true)
                }
            } second: {
                CommitComposer(session: session)
            }
        } second: {
            DiffView(session: session, editable: true)
        }
    }
}

struct ChangeList: View {
    let workspace: Workspace
    @Bindable var session: RepositorySession
    let staged: Bool
    @State private var selection: Set<String> = []
    @State private var discarding: [FileChange] = []

    private var files: [FileChange] {
        session.status.changes.filter { staged ? $0.staged : $0.unstaged }
    }

    private var selectedFiles: [FileChange] {
        files.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            SectionHeading(title: "\(staged ? "已暂存" : "未暂存") · \(files.count)",
                           titleAction: showOverview) {
                HStack(spacing: 10) {
                    Button { transfer(selectedFiles) } label: {
                        Image(systemName: staged ? "chevron.up" : "chevron.down")
                    }
                    .help(staged ? "取消暂存选中 (空格)" : "暂存选中 (空格)")
                    .disabled(selectedFiles.isEmpty || session.operation != nil)
                    Button { transfer(files) } label: {
                        Image(systemName: staged ? "chevron.up.2" : "chevron.down.2")
                    }
                    .help(staged ? "全部取消暂存" : "全部暂存")
                    .disabled(files.isEmpty || session.operation != nil)
                }.buttonStyle(.borderless).font(.ui(weight: .semibold))
            }
            if files.isEmpty {
                Text(staged ? "暂存文件后提交" : "工作目录无变更")
                    .font(.ui(-2)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle()).onTapGesture(perform: showOverview)
            } else {
                List(selection: $selection) {
                    ForEach(files) { file in
                        HStack(spacing: 6) {
                            Text(file.conflicted ? "!" : String(staged ? file.index : file.worktree))
                                .font(.mono(-1, weight: .bold))
                                .foregroundStyle(file.conflicted ? Theme.deleted : Color.secondary).frame(width: 14)
                            Text(file.path).font(.ui()).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .tag(file.id).help(file.path)
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                // 双击 / 回车 / 空格暂存或取消暂存；右键作用于选中文件。
                .contextMenu(forSelectionType: String.self) { ids in
                    contextMenu(files.filter { ids.contains($0.id) })
                } primaryAction: { ids in
                    transfer(files.filter { ids.contains($0.id) })
                }
                .onKeyPress(.space) {
                    guard !selectedFiles.isEmpty, session.operation == nil else { return .ignored }
                    transfer(selectedFiles)
                    return .handled
                }
                .onChange(of: selection) { _, _ in
                    if let file = files.first(where: { selection.contains($0.path) }) {
                        session.selectFile(file, staged: staged)
                    }
                }
                .background(ChangeListBlankArea(action: showOverview))
                .task(id: files) {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    selection.formIntersection(files.map(\.id))
                }
                .onChange(of: session.selectedStaged) { _, value in
                    if value != staged {
                        selection = []
                    }
                }
            }
        }
        .dismissConfirmationOnBackgroundClick(isPresented: Binding(
            get: { !discarding.isEmpty }, set: {
                if !$0 {
                    discarding = []
                }
            }
        ))
        .confirmationDialog("放弃未暂存变更？", isPresented: Binding(
            get: { !discarding.isEmpty }, set: {
                if !$0 {
                    discarding = []
                }
            }
        ), titleVisibility: .visible) {
            Button("放弃 \(discarding.count) 个文件的变更", role: .destructive) {
                session.perform(.discard(discarding), title: "放弃变更")
                discarding = []
            }
            Button("取消", role: .cancel) { discarding = [] }
        } message: {
            Text(discarding.prefix(8).map(\.path).joined(separator: "\n")
                + (discarding.contains(where: \.untracked) ? "\n未跟踪文件将移至废纸篓。" : ""))
        }
    }

    @ViewBuilder
    private func contextMenu(_ targets: [FileChange]) -> some View {
        if !targets.isEmpty {
            Button(staged ? "取消暂存" : "暂存") { transfer(targets) }
                .disabled(session.operation != nil)
            if !staged {
                Button("放弃未暂存变更…") { discarding = targets }
                    .disabled(targets.contains { $0.conflicted || $0.submodule } || session.operation != nil)
                if targets.count == 1, let file = targets.first, file.untracked {
                    Button("加入 .gitignore") { session.perform(.ignore(file.path), title: "忽略文件") }
                        .disabled(session.operation != nil)
                }
            }
            if targets.count == 1, let file = targets.first {
                Divider()
                Button("在编辑器打开") { workspace.openEditor(session.location.root + "/" + file.path) }
            }
        }
    }

    private func showOverview() {
        selection = []
        session.selectChanges(staged: staged)
    }

    private func transfer(_ targets: [FileChange]) {
        guard !targets.isEmpty, session.operation == nil else { return }
        // 选中项全部被转移时改选其后一项（末尾则前一项）并预览，便于连续按空格逐个处理。
        let ids = Set(targets.map(\.id))
        let next = !selection.isEmpty && selection.isSubset(of: ids) ? nextSelection(after: ids) : nil
        session.perform(staged ? .unstage(targets) : .stage(targets), title: staged ? "取消暂存" : "暂存")
        if let next {
            selection = [next.id]
        }
    }

    private func nextSelection(after ids: Set<String>) -> FileChange? {
        guard let last = files.lastIndex(where: { ids.contains($0.id) }) else { return nil }
        return files[(last + 1)...].first { !ids.contains($0.id) }
            ?? files[..<last].last { !ids.contains($0.id) }
    }
}

struct CommitComposer: View {
    @Bindable var session: RepositorySession
    @State private var confirmAmendPush = false
    @State private var destination: PushDestination?

    private var canCommit: Bool {
        session.operation == nil && !session.status.conflicts && session.interruptedOperation == nil
            && !session.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (session.amend || session.status.changes.contains(where: \.staged))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("提交信息").font(.ui(-1, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Toggle("Amend", isOn: Binding(get: { session.amend }, set: { session.setAmend($0) }))
                    .toggleStyle(.checkbox).font(.ui(-2))
                    .disabled(session.status.unborn || session.operation != nil)
            }
            TextEditor(text: $session.message)
                .font(.code()).scrollContentBackground(.hidden)
                .padding(4).background(Theme.window).overlay(Rectangle().stroke(Theme.border))
                .frame(minHeight: 60, maxHeight: .infinity)
                .accessibilityLabel("提交信息")
            if session.status.conflicts {
                Text("存在冲突，请解决后暂存。").font(.ui(-2)).foregroundStyle(Theme.orange)
            }
            HStack {
                Button(session.amend ? "Amend" : "提交") { submit(push: false) }
                    .keyboardShortcut(.return, modifiers: [.command]).disabled(!canCommit)
                Spacer(minLength: 4)
                Button(session.amend ? "Amend 并推送" : "提交并推送") {
                    let target = PushDestination(session: session)
                    // 远端已有该分支时 Amend 会改写历史，需确认后用 force-with-lease 推送。
                    if session.amend, target.lease != nil {
                        destination = target
                        confirmAmendPush = true
                    } else {
                        submit(push: true, destination: target)
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command, .option])
                .disabled(!canCommit || session.remotes.isEmpty || session.status.detached)
            }.controlSize(.small)
        }.padding(10)
            .dismissConfirmationOnBackgroundClick(isPresented: $confirmAmendPush)
            .confirmationDialog("Amend 并强制推送？", isPresented: $confirmAmendPush, titleVisibility: .visible) {
                Button("Amend 并推送", role: .destructive) { submit(push: true, destination: destination) }
                Button("取消", role: .cancel) {
                }
            } message: {
                Text("将修补当前提交并推送到 \(destination?.remote ?? "")/\(destination?.branch ?? "")，使用 force-with-lease。")
            }
    }

    private func submit(push: Bool, destination: PushDestination? = nil) {
        let target = destination ?? PushDestination(session: session)
        let amend = session.amend
        session.perform(.commit(message: session.message, amend: amend), title: amend ? "Amend" : "提交") {
            session.message = ""
            session.amend = false
            if push {
                session.perform(.push(remote: target.remote, branch: target.branch, lease: amend ? target.lease : nil),
                                title: "Push")
            }
        }
    }
}

/// 原生列表空白点击独立于 selection；保留文件行与滚动条的原生交互。
private struct ChangeListBlankArea: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> BlankAreaView {
        BlankAreaView()
    }

    func updateNSView(_ view: BlankAreaView, context: Context) {
        view.action = action
    }

    static func dismantleNSView(_ view: BlankAreaView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class BlankAreaView: NSView {
        var action: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        private func handle(_ event: NSEvent) {
            guard event.window === window, let content = window?.contentView,
                  bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            var hit = content.hitTest(point)
            while let view = hit {
                if view is NSScroller || view is NSTableRowView {
                    return
                }
                if let table = view as? NSTableView,
                   table.row(at: table.convert(event.locationInWindow, from: nil)) >= 0 {
                    return
                }
                hit = view.superview
            }
            action?()
        }
    }
}
