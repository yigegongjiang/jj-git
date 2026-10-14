import Foundation

extension RepositorySession {
    /// 选中文件即切到单文件差异；全部差异预览中已读取的内容先行显示，随后按文件刷新。
    func selectFile(_ file: FileChange?, staged: Bool) {
        guard let file else { return selectChanges(staged: staged) }
        let cached = fileDiffs.first { $0.target.path == file.path && $0.target.staged == staged }?.diff
        if selectedFile?.path != file.path || selectedStaged != staged {
            selectedLines = []
        }
        diffOverview = false
        diffReveal = nil
        fileDiffs = []
        diffFallback = false
        selectedFile = file
        selectedStaged = staged
        diff = cached
        readError = nil
        reloadSelectedDiff()
    }

    /// `focus`：全部差异读取完成后聚焦、回退时单独显示的文件。
    func selectChanges(staged: Bool, focus: FileChange? = nil) {
        diffOverview = true
        diffReveal = nil
        selectedStaged = staged
        selectedFile = focus
        selectedLines = []
        fileDiffs = []
        diff = nil
        diffFallback = false
        readError = nil
        loadDiffOverview(DiffTarget.changes(status, staged: staged))
    }

    /// 定位按钮：显示（或保持）全部差异并滚动到该文件；全部差异回退单文件时显示该文件。
    func revealChange(_ file: FileChange, staged: Bool) {
        let id = DiffTarget(path: file.path, staged: staged).id
        if diffOverview, let entry = fileDiffs.first(where: { $0.id == id }) {
            focusDiff(entry)
        } else {
            selectChanges(staged: staged, focus: file)
        }
        reveal(id)
    }

    func reveal(_ id: String) {
        revealCount += 1
        diffReveal = DiffReveal(id: id, token: revealCount)
    }

    /// 单文件模式下刷新选中文件；该文件已不在当前列表（暂存 / 放弃 / 提交）时回到全部差异。
    func refreshChangesDiff() {
        guard !diffOverview else {
            return loadDiffOverview(DiffTarget.changes(status, staged: selectedStaged))
        }
        let staged = selectedStaged
        guard let file = status.changes.first(where: {
            $0.path == selectedFile?.path && (staged ? $0.staged : $0.unstaged)
        }) else { return selectChanges(staged: staged) }
        selectedFile = file
        reloadSelectedDiff()
    }

    /// 行 ID 仅在单文件内唯一，跨文件选中前清空行选择。
    func focusDiff(_ entry: FileDiff) {
        if selectedFile?.path != entry.target.path || selectedStaged != entry.target.staged {
            selectedLines = []
        }
        selectedFile = entry.target.file
        selectedStaged = entry.target.staged
        diff = entry.diff
    }

    /// 全部差异时不选中文件，点击任一文件（含第一个）都能切到单文件。
    func showCommitOverview() {
        guard let selectedCommit, let commitDetail else { return }
        selectedCommitFile = nil
        diffReveal = nil
        diff = nil
        loadDiffOverview(commitDetail.files.map { DiffTarget(path: $0.path) }, commit: selectedCommit)
    }

    /// 定位按钮：已在全部差异中则直接滚动，否则先切到全部差异。
    func revealCommitFile(_ file: CommitFile) {
        let id = DiffTarget(path: file.path).id
        if selectedCommitFile != nil || !fileDiffs.contains(where: { $0.id == id }) {
            showCommitOverview()
        }
        reveal(id)
    }

    /// 提交内容不变，全部差异中已读取的文件直接复用。
    func selectCommitFile(_ file: CommitFile?) {
        diffTask?.cancel()
        diffGeneration += 1
        let generation = diffGeneration
        let cached = fileDiffs.first { $0.target.path == file?.path }?.diff
        fileDiffs = []
        diffFallback = false
        diffReveal = nil
        selectedCommitFile = file
        diff = cached
        readError = nil
        guard let file, let selectedCommit, cached == nil else { loadingDiff = false; return }
        loadingDiff = true
        diffTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await command.query.commitDiff(selectedCommit, path: file.path)
                try Task.checkCancellation()
                guard generation == diffGeneration else { return }
                diff = result
                readError = nil
            } catch is CancellationError { return } catch {
                guard !Task.isCancelled, generation == diffGeneration else { return }
                readError = error.localizedDescription
            }
            if generation == diffGeneration {
                loadingDiff = false
            }
        }
    }

    func loadDiffOverview(_ targets: [DiffTarget], commit: GitCommit? = nil) {
        diffTask?.cancel()
        diffGeneration += 1
        let generation = diffGeneration
        guard !targets.isEmpty else {
            fileDiffs = []; diff = nil; selectedFile = nil; loadingDiff = false; diffFallback = false
            readError = nil
            return
        }
        if let commit, let cached = commitCache.entry(for: commit)?.diffs,
           cached.map(\.target.path) == targets.map(\.path) {
            return present(cached, commit: commit, complete: true)
        }
        if commit == nil {
            dropRemoved(targets)
        }
        let previous = fileDiffs
        let known = commit == nil ? unchangedDiffs(targets) : [:]
        let sequence = changeSequence
        // 全部沿用且列表不变（如被忽略的构建产物变化）：不启动读取，也不重新发布。
        if commit == nil, known.count == targets.count, previous.map(\.target) == targets {
            loadingDiff = false
            return diffsRead(through: sequence)
        }
        // 界面空白时先显示已读到的部分；已有内容时保留旧内容直到全部读完，避免闪动。
        let progressive = diff == nil && fileDiffs.isEmpty
        loadingDiff = progressive
        // 空白界面的读取计时（首屏 / 全部完成），写入命令记录。
        overviewTrace = progressive ? OperationTrace(name: "全部差异 \(targets.count)", start: .now) : nil
        let prefix: @MainActor @Sendable ([FileDiff]) -> Void = { [weak self] prepared in
            guard let self, generation == diffGeneration else { return }
            present(prepared, commit: commit, complete: false)
            overviewTrace?.mark("first")
        }
        diffTask = Task { [weak self] in
            guard let self else { return }
            var prepared: [FileDiff]?
            do {
                prepared = try await command.query.allDiffs(targets, commit: commit, reusing: previous, known: known,
                                                            prefix: progressive ? prefix : nil)
            } catch {
                // 批量超时、输出上限或文件瞬时消失均退回单文件；上级取消不触发回退。
            }
            guard !Task.isCancelled, generation == diffGeneration else { return }
            finishOverview(prepared, targets: targets, commit: commit, sequence: sequence)
        }
    }

    private func finishOverview(_ prepared: [FileDiff]?, targets: [DiffTarget], commit: GitCommit?, sequence: Int) {
        defer {
            overviewTrace?.record(at: location.root)
            overviewTrace = nil
        }
        guard let prepared, !prepared.isEmpty else {
            overviewTrace?.mark("fallback")
            return fallbackDiff(targets, commit: commit)
        }
        present(prepared, commit: commit, complete: true)
        overviewTrace?.mark("done")
        if let commit {
            if let commitDetail, selectedCommit?.id == commit.id {
                commitCache.store(commit, detail: commitDetail, diffs: prepared)
            }
        } else {
            diffsRead(through: sequence)
        }
    }

    /// 已不在列表中的文件（暂存 / 放弃 / 提交后）立即移除，重新读取完成前界面即反映操作结果。
    private func dropRemoved(_ targets: [DiffTarget]) {
        guard !fileDiffs.isEmpty else { return }
        let ids = Set(targets.map(\.id))
        let kept = fileDiffs.filter { ids.contains($0.id) }
        if !kept.isEmpty, kept.count < fileDiffs.count {
            present(kept, commit: nil, complete: true)
        }
    }

    /// 工作区文件变化（FSEvents 报告的相对路径）；累积过多时改为全部失效，避免长期停留在提交历史时无限增长。
    func markChanged(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        changeSequence += 1
        for path in paths {
            changedPaths[path] = changeSequence
        }
        if changedPaths.count > Self.changedPathLimit {
            invalidateDiffs()
        }
    }

    func invalidateDiffs() {
        changeSequence += 1
        diffsInvalidated = changeSequence
        changedPaths = [:]
    }

    private static let changedPathLimit = 2000

    /// 序号之前的变化都已读到最新内容；读取期间到达的变化保留到下次。
    private func diffsRead(through sequence: Int) {
        changedPaths = changedPaths.filter { $0.value > sequence }
        if let invalidated = diffsInvalidated, invalidated <= sequence {
            diffsInvalidated = nil
        }
    }

    /// 上次完整读取后仍有效、无需重新执行 Git 的差异：`FileChange` 相同（含 HEAD / 暂存区对象名）即已暂存差异不变；
    /// 未暂存 / 未跟踪差异另需文件及其所在目录没有变化报告。
    private func unchangedDiffs(_ targets: [DiffTarget]) -> [String: TextDiff] {
        guard diffsInvalidated == nil, !fileDiffs.isEmpty else { return [:] }
        let previous = Dictionary(fileDiffs.map { ($0.target, $0.diff) }, uniquingKeysWith: { first, _ in first })
        var result: [String: TextDiff] = [:]
        for target in targets {
            guard let diff = previous[target] else { continue }
            if target.staged || !changed(target.path) {
                result[target.id] = diff
            }
        }
        return result
    }

    /// 文件本身或任一上级目录有变化报告（目录事件来自 FSEvents 合并 / 需重扫）。
    private func changed(_ path: String) -> Bool {
        var current = Substring(path)
        while true {
            if changedPaths[String(current)] != nil {
                return true
            }
            guard let slash = current.lastIndex(of: "/") else { return false }
            current = current[..<slash]
        }
    }

    /// 本地变更聚焦选中文件；`complete` 为 false（仅前缀）且选中文件尚未读到时保持选择不变。
    private func present(_ prepared: [FileDiff], commit: GitCommit?, complete: Bool) {
        readError = nil
        fileDiffs = prepared
        diffFallback = false
        if commit == nil {
            if let focused = prepared.first(where: {
                $0.target.path == selectedFile?.path && $0.target.staged == selectedStaged
            }) {
                focusDiff(focused)
            } else if complete || selectedFile == nil {
                focusDiff(prepared[0])
            }
        } else {
            diff = prepared[0].diff
        }
        loadingDiff = false
    }

    /// 全部差异读取失败时显示单文件，但保持全部差异模式，后续刷新继续尝试全量读取。
    private func fallbackDiff(_ targets: [DiffTarget], commit: GitCommit?) {
        fileDiffs = []
        loadingDiff = false
        if let commit {
            selectedCommit = commit
            let files = commitDetail?.files ?? []
            selectCommitFile(files.first { DiffTarget(path: $0.path).id == diffReveal?.id } ?? files.first)
        } else {
            let target = targets.first { $0.path == selectedFile?.path && $0.staged == selectedStaged } ?? targets[0]
            if selectedFile != target.file || selectedStaged != target.staged || diff == nil {
                selectedLines = []
                diff = nil
                selectedFile = target.file
                selectedStaged = target.staged
            }
            reloadSelectedDiff()
        }
        diffFallback = targets.count > 1
    }
}

/// 最近查看的提交详情与全部差异：提交内容不可变，按哈希 + 上下文行数缓存，重新选中时立即显示；
/// 超出条数或差异字节上限时淘汰最久未查看的，标签释放时清空。
struct CommitDiffCache {
    struct Entry {
        let key: String
        let detail: CommitDetail
        let diffs: [FileDiff]
        let bytes: Int
    }

    private static let maxEntries = 32
    private static let maxBytes = 8 * 1024 * 1024
    private var entries: [Entry] = []

    mutating func entry(for commit: GitCommit) -> Entry? {
        let key = Self.key(commit)
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry
    }

    mutating func store(_ commit: GitCommit, detail: CommitDetail, diffs: [FileDiff]) {
        let key = Self.key(commit)
        let bytes = diffs.reduce(0) { $0 + $1.diff.raw.utf8.count }
        entries.removeAll { $0.key == key }
        guard bytes <= Self.maxBytes / 2 else { return }
        entries.append(Entry(key: key, detail: detail, diffs: diffs, bytes: bytes))
        var total = entries.reduce(0) { $0 + $1.bytes }
        while entries.count > Self.maxEntries || total > Self.maxBytes {
            total -= entries.removeFirst().bytes
        }
    }

    func diffs(excluding commit: GitCommit?) -> [[FileDiff]] {
        let shown = commit.map(Self.key)
        return entries.filter { $0.key != shown }.map(\.diffs)
    }

    private static func key(_ commit: GitCommit) -> String {
        commit.hash + ":" + String(AppConfig.current.diff.contextLines)
    }
}
