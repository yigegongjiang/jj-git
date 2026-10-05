import AppKit
import Foundation
import Observation

@MainActor @Observable
final class RepositorySession: Identifiable {
    nonisolated let location: RepositoryLocation
    nonisolated var id: String {
        location.root
    }

    let command: RepositoryCommand
    var status = WorkingCopyStatus()
    var references: [GitReference] = []
    var remotes: [GitRemote] = []
    var worktrees: [GitWorktree] = []
    var graph: [CommitGraphRow] = []
    /// 提交图列宽（轨道数），超过上限的轨道被裁剪，保证提交标题对齐。
    var graphLanes = 1
    var historyLimit = AppConfig.current.history.initialCount
    var hasMoreHistory = false
    var selectedCommit: GitCommit?
    var commitDetail: CommitDetail?
    var selectedCommitFile: CommitFile?
    var selectedFile: FileChange?
    var selectedStaged = false
    var diff: TextDiff?
    var fileDiffs: [FileDiff] = []
    var diffScrollID: String?
    var diffScrollRequest = 0
    var diffFallback = false
    var selectedLines: Set<Int> = []
    var message = ""
    var amend = false
    var section = RepositorySection.changes
    var error: String?
    var notice = ""
    var operation: String?
    var refreshing = false
    var loadingDiff = false
    var lastRefreshed: Date?
    var interruptedOperation: String?

    @ObservationIgnored private var active = false
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var monitor: RepositoryMonitor?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored var diffTask: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var referenceKey = ""
    @ObservationIgnored var preparingDiffOverview = false
    @ObservationIgnored var diffGeneration = 0
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var refreshFailure: String?
    /// 打开 / 切换到仓库后首次刷新：无本地变更则显示提交历史；手动切换分区即取消。
    @ObservationIgnored private var sectionAutoPending = false

    init(location: RepositoryLocation) {
        self.location = location
        command = RepositoryCommand(location: location)
    }

    deinit {
        polling?.cancel()
        refreshTask?.cancel()
        detailTask?.cancel()
        diffTask?.cancel()
        operationTask?.cancel()
    }

    func activate() {
        guard !active else { return }
        active = true
        sectionAutoPending = true
        monitor = RepositoryMonitor(location: location) { [weak self] in
            Task { @MainActor [weak self] in self?.filesystemChanged() }
        }
        // FSEvents 负责实时刷新；轮询只兜底漏报，且仅在 App 位于前台时执行。
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(AppConfig.current.refresh.pollSeconds)) } catch { return }
                if NSApplication.shared.isActive {
                    self?.refresh()
                }
            }
        }
        refresh()
    }

    private func filesystemChanged() {
        if active {
            refresh()
        }
    }

    func deactivate() {
        active = false
        monitor = nil
        polling?.cancel()
        polling = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration += 1
        refreshing = false
    }

    func waitForOperation() async {
        await operationTask?.value
    }

    /// 关闭 / 闲置释放前取消读取任务，避免任务继续持有 session。
    func dispose() {
        deactivate()
        detailTask?.cancel()
        detailTask = nil
        diffTask?.cancel()
        diffTask = nil
    }

    func refresh(forceHistory: Bool = false) {
        if forceHistory {
            referenceKey = ""
        }
        guard operation == nil, !refreshing else { refreshPending = true; return }
        refreshing = true
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == refreshGeneration {
                    refreshing = false
                    if refreshPending, active {
                        refreshPending = false
                        refresh()
                    }
                }
            }
            do {
                try await refreshSnapshot()
                refreshFailure = nil
            } catch is CancellationError {
                return
            } catch {
                // 同一错误只提示一次，避免每次轮询重新弹出已关闭的提示。
                let message = error.localizedDescription
                if message != refreshFailure {
                    refreshFailure = message
                    self.error = message
                }
            }
        }
    }

    private func refreshSnapshot() async throws {
        let query = command.query
        async let newStatus = query.status()
        async let newRefs = query.references()
        async let newRemotes = query.remotes()
        async let newTrees = query.worktrees()
        let values = try await (newStatus, newRefs, newRemotes, newTrees)
        try Task.checkCancellation()
        let key = values.0.head + values.1.map { $0.fullName + $0.target }.joined()
        let changed = status != values.0
        status = values.0
        references = values.1
        remotes = values.2
        worktrees = values.3
        interruptedOperation = query.operationInProgress()
        if key != referenceKey {
            let commits = try await query.commits(limit: historyLimit, includeHead: !values.0.unborn)
            try Task.checkCancellation()
            graph = CommitGraphRow.build(commits, head: values.0.head)
            graphLanes = min(graph.map(\.width).max() ?? 1, 8)
            hasMoreHistory = commits.count == historyLimit
            referenceKey = key
            if let selectedCommit, !commits.contains(where: { $0.id == selectedCommit.id }) {
                selectCommit(nil)
            }
        }
        lastRefreshed = Date()
        if sectionAutoPending {
            sectionAutoPending = false
            if section == .changes, status.changes.isEmpty, !graph.isEmpty {
                changeSection(.history)
            }
        }
        if section == .changes {
            if changed {
                selectedLines = []
            }
            loadDiffOverview(DiffTarget.changes(status, staged: selectedStaged))
        }
    }
}

extension RepositorySession {
    func changeSection(_ section: RepositorySection) {
        sectionAutoPending = false
        self.section = section
        fileDiffs = []
        diff = nil
        diffScrollID = nil
        if section == .changes {
            detailTask?.cancel()
            selectChanges(staged: false)
        } else {
            selectCommit(selectedCommit ?? graph.first?.commit)
        }
    }

    func reloadSelectedDiff() {
        loadFileDiff(clearSelection: false)
    }

    private func loadFileDiff(clearSelection: Bool) {
        preparingDiffOverview = false
        diffTask?.cancel()
        diffGeneration += 1
        let generation = diffGeneration
        guard let selectedFile else { loadingDiff = false; return }
        let staged = selectedStaged
        if clearSelection {
            selectedLines = []
        }
        loadingDiff = diff == nil
        let previous = diff
        diffTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await command.query.diff(selectedFile, staged: staged, reusing: previous)
                try Task.checkCancellation()
                guard generation == diffGeneration else { return }
                if diff?.raw != result.raw {
                    selectedLines = []; diff = result
                }
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
            }
            if generation == diffGeneration {
                loadingDiff = false
            }
        }
    }

    func selectCommit(_ commit: GitCommit?) {
        detailTask?.cancel()
        diffTask?.cancel()
        diffGeneration += 1
        preparingDiffOverview = false
        selectedCommit = commit
        fileDiffs = []
        diffFallback = false
        diffScrollID = nil
        loadingDiff = false
        commitDetail = nil
        selectedCommitFile = nil
        diff = nil
        guard let commit else { return }
        detailTask = Task { [weak self] in
            guard let self else { return }
            do {
                let detail = try await command.query.detail(commit)
                try Task.checkCancellation()
                guard selectedCommit?.id == commit.id else { return }
                commitDetail = detail
                selectedCommitFile = detail.files.first
                loadDiffOverview(detail.files.map { DiffTarget(path: $0.path) }, commit: commit)
            } catch is CancellationError { return } catch { self.error = error.localizedDescription }
        }
    }

    func selectCommitFile(_ file: CommitFile?) {
        if let file, let entry = fileDiffs.first(where: { $0.target.path == file.path }) {
            focusDiff(entry)
            diffScrollID = entry.id
            diffScrollRequest += 1
            return
        }
        diffTask?.cancel()
        diffGeneration += 1
        let generation = diffGeneration
        selectedCommitFile = file
        diff = nil
        guard let file, let selectedCommit else { loadingDiff = false; return }
        loadingDiff = true
        diffTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await command.query.commitDiff(selectedCommit, path: file.path)
                try Task.checkCancellation()
                guard generation == diffGeneration else { return }
                diff = result
            } catch is CancellationError { return } catch { self.error = error.localizedDescription }
            if generation == diffGeneration {
                loadingDiff = false
            }
        }
    }

    func perform(_ action: RepositoryAction, title: String, completion: (@MainActor () -> Void)? = nil) {
        guard operation == nil else { return }
        operation = title
        error = nil
        notice = ""
        refreshTask?.cancel()
        refreshGeneration += 1
        refreshing = false
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await command.perform(action)
                notice = output.isEmpty ? "\(title)完成" : String(output.prefix(2000))
            } catch is CancellationError {
                notice = "操作已取消；正在重新读取仓库状态。"
            } catch {
                self.error = error.localizedDescription
            }
            operation = nil
            refreshing = false
            refresh(forceHistory: true)
            if error == nil, !Task.isCancelled {
                completion?()
            }
        }
    }

    /// 上游所在远程，其次 origin，最后第一个远程。
    var defaultRemote: String {
        remotes.first { status.upstream.hasPrefix($0.name + "/") }?.name
            ?? remotes.first { $0.name == "origin" }?.name ?? remotes.first?.name ?? ""
    }

    /// 远端分支对应的本地分支：优先跟踪它的分支，其次同名分支。
    func localBranch(for remoteBranch: GitReference) -> GitReference? {
        let locals = references.filter { !$0.remote && !$0.tag }
        if let tracking = locals.first(where: { $0.upstream == remoteBranch.name }) {
            return tracking
        }
        guard let remote = remotes.filter({ remoteBranch.name.hasPrefix($0.name + "/") })
            .max(by: { $0.name.count < $1.name.count }) else { return nil }
        let name = String(remoteBranch.name.dropFirst(remote.name.count + 1))
        return locals.first { $0.name == name }
    }

    func checkout(_ branch: GitReference) {
        let target = branch.remote ? localBranch(for: branch) ?? branch : branch
        guard !target.current else { return }
        guard target.checkedOutPath.isEmpty else {
            error = "\(target.name) 已在其他工作树检出：\(target.checkedOutPath)"
            return
        }
        perform(.checkout(target), title: "检出 \(target.name)")
    }

    func fetch() {
        let remote = defaultRemote
        guard !remote.isEmpty else { return }
        perform(.fetch(remote: remote), title: "Fetch \(remote)")
    }

    /// 直接推送当前分支到上游（无上游时推送到默认远程的同名分支并建立跟踪）。
    func pushToUpstream() {
        let remote = defaultRemote
        guard !remote.isEmpty, !status.detached, !status.unborn else { return }
        let branch = status.upstream.hasPrefix(remote + "/")
            ? String(status.upstream.dropFirst(remote.count + 1)) : status.branch
        perform(.push(remote: remote, branch: branch, lease: nil), title: "Push")
    }

    func cancelOperation() {
        operationTask?.cancel()
    }

    func setAmend(_ enabled: Bool) {
        amend = enabled
        guard enabled, message.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let previous = try await command.query.lastMessage()
                if amend, message.isEmpty {
                    message = previous
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}

enum RepositorySection: String, CaseIterable, Identifiable {
    case history = "提交历史"
    case changes = "本地变更"
    nonisolated var id: String {
        rawValue
    }
}
