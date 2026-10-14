import Foundation

extension RepositorySession {
    /// 中断进行中的刷新，其范围并入排队请求，之后的刷新补上。
    func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration += 1
        if refreshing {
            pendingRefresh = (pendingRefresh ?? []).union(refreshingScope)
            refreshing = false
        }
    }

    /// 总会读取工作区状态；`scope` 指定附加范围。进行中 / 操作期间的请求合并，结束后执行一次。
    func refresh(_ scope: RefreshScope = .references) {
        if scope.contains(.contents) {
            invalidateDiffs()
        }
        pendingRefresh = (pendingRefresh ?? []).union(scope)
        guard operation == nil, !refreshing, let scope = pendingRefresh else { return }
        pendingRefresh = nil
        refreshingScope = scope
        refreshing = true
        refreshGeneration += 1
        let generation = refreshGeneration
        let trace = operationTrace
        operationTrace = nil
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == refreshGeneration {
                    refreshing = false
                    if pendingRefresh != nil, active {
                        refresh([])
                    }
                }
            }
            do {
                try await refreshSnapshot(scope, trace: trace)
                refreshError = nil
                refreshFailure = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, generation == refreshGeneration else { return }
                // 同一错误只提示一次，避免每次轮询重新弹出已关闭的提示。
                let message = error.localizedDescription
                if message != refreshFailure {
                    refreshFailure = message
                    refreshError = message
                }
            }
        }
    }

    /// 状态先行发布并刷新差异，ref 与提交历史随后；只在内容变化时赋值，避免无变化的刷新重绘界面。
    private func refreshSnapshot(_ scope: RefreshScope, trace: OperationTrace?) async throws {
        let query = command.query
        var trace = trace
        let readsReferences = scope.contains(.references) || scope.contains(.history)
        async let referenceRead = readsReferences ? query.referenceSnapshot() : nil
        let newStatus = try await query.status()
        try Task.checkCancellation()
        // 文件变化归类可能漏掉 HEAD 移动（如外部提交只改了松散 ref 以外的文件），按状态补读 ref。
        let headMoved = newStatus.head != status.head || newStatus.branch != status.branch
        let changed = newStatus != status
        if changed {
            status = newStatus
        }
        let interrupted = query.operationInProgress()
        if interrupted != interruptedOperation {
            interruptedOperation = interrupted
        }
        if section == .changes, changed || !scope.isDisjoint(with: [.contents, .worktree]) {
            if changed {
                selectedLines = []
            }
            refreshChangesDiff()
        }
        trace?.mark("status")
        var snapshot = try await referenceRead
        if snapshot == nil, headMoved {
            snapshot = try await query.referenceSnapshot()
        }
        try Task.checkCancellation()
        if let snapshot {
            try await publish(snapshot, forceHistory: scope.contains(.history))
            trace?.mark("references")
        }
        lastRefreshed = .now
        trace?.record(at: location.root)
        if let selectedCommit, detailFailed, section == .history {
            selectCommit(selectedCommit)
        }
        if sectionAutoPending {
            sectionAutoPending = false
            if section == .changes, status.changes.isEmpty, !graph.isEmpty {
                changeSection(.history)
            }
        }
    }

    /// ref 键含 HEAD、当前分支与各 ref 指向：提交 / 检出 / Fetch / 标签变化都会改变它，键不变时跳过历史读取。
    private func publish(_ snapshot: ReferenceSnapshot, forceHistory: Bool) async throws {
        if references != snapshot.references {
            references = snapshot.references
        }
        if remotes != snapshot.remotes {
            remotes = snapshot.remotes
        }
        if let remote = fetchFailureRemote, !remotes.contains(where: { $0.name == remote }) {
            fetchFailure = nil
            fetchFailureRemote = nil
            fetchError = nil
        }
        if worktrees != snapshot.worktrees {
            worktrees = snapshot.worktrees
        }
        let key = ([status.head, status.branch] + references.map { $0.fullName + $0.target + ($0.current ? "*" : "") })
            .joined(separator: "\0")
        guard forceHistory || key != referenceKey else { return }
        let history = try await command.query.history(limit: historyLimit, includeHead: !status.unborn,
                                                      head: status.head)
        try Task.checkCancellation()
        graph = history.rows
        if graphLanes != history.lanes {
            graphLanes = history.lanes
        }
        if hasMoreHistory == history.complete {
            hasMoreHistory = !history.complete
        }
        referenceKey = key
        if let selectedCommit, !graph.contains(where: { $0.id == selectedCommit.id }) {
            selectCommit(nil)
        }
    }
}

/// 刷新范围：工作区状态总会读取，以下为附加部分。
struct RefreshScope: OptionSet, Sendable {
    let rawValue: Int
    /// ref / 远程 / 工作树；ref 变化时重读提交历史。
    static let references = Self(rawValue: 1)
    /// 无论 ref 是否变化都重读提交历史（加载更多 / 手动刷新 / 自定义操作）。
    static let history = Self(rawValue: 2)
    /// 全部差异失效并重读：文件事件可能遗漏或不完整时（激活 / 手动刷新 / 根目录重扫 / 大批改写工作区的操作）。
    static let contents = Self(rawValue: 4)
    /// 只重读工作区中报告了变化的文件的差异，其余按 `FileChange.objects` 判断沿用。
    static let worktree = Self(rawValue: 8)
    static let everything: Self = [.references, .history, .contents]
}

/// 一批 FSEvents 的归类：工作区文件只影响状态与这些文件的差异；index 只需重读状态（暂存区 / HEAD 内容变化
/// 体现在 `FileChange.objects`）；其他 Git 元数据（HEAD / ref / 配置 / 工作树）另读 ref。对象与 reflog 随 ref /
/// index 一起变化、FETCH_HEAD 不参与显示，单独出现时忽略。根目录本身变化（移动 / 需重扫）全部重读。
struct FileSystemChange: Sendable {
    /// nil：本批变化无需刷新。
    let scope: RefreshScope?
    /// `.worktree` 对应的路径（相对仓库根）。
    let paths: [String]

    init(_ events: [String], in location: RepositoryLocation) {
        var scope: RefreshScope?
        var paths: [String] = []
        for path in events.map({ $0.hasSuffix("/") ? String($0.dropLast()) : $0 }) {
            var change: RefreshScope?
            if let name = Self.relative(path, to: location.gitDirectory)
                ?? Self.relative(path, to: location.commonDirectory) {
                if name == "index" || name == "index.lock" {
                    change = []
                } else if !name.hasPrefix("objects/"), !name.hasPrefix("logs/"), name != "FETCH_HEAD" {
                    change = .references
                }
            } else if let name = Self.relative(path, to: location.root), !name.isEmpty {
                change = .worktree
                paths.append(name)
            } else {
                change = [.references, .contents]
            }
            if let change {
                scope = (scope ?? []).union(change)
            }
        }
        self.scope = scope
        self.paths = scope?.contains(.contents) == true ? [] : paths
    }

    private static func relative(_ path: String, to directory: String) -> String? {
        if path == directory {
            return ""
        }
        return path.hasPrefix(directory + "/") ? String(path.dropFirst(directory.count + 1)) : nil
    }
}

/// 操作阶段计时（点击 → 等待自动 Fetch → Git → 状态可见 → ref / 历史可见），写入命令记录供排查滞后。
struct OperationTrace: Sendable {
    let name: String
    let start: ContinuousClock.Instant
    private let date = Date()
    private var last: ContinuousClock.Instant
    private var phases: [String] = []

    init(name: String, start: ContinuousClock.Instant) {
        self.name = name
        self.start = start
        last = start
    }

    mutating func mark(_ phase: String) {
        let now = ContinuousClock.now
        phases.append("\(phase)=\(Self.milliseconds(now - last))")
        last = now
    }

    func record(at repository: String) {
        GitCommandLog.trace(at: repository, event: ["jj-git", name] + phases, start: date,
                            milliseconds: Self.milliseconds(last - start))
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
