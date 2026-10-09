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
        let previous = fileDiffs
        guard !targets.isEmpty else {
            fileDiffs = []; diff = nil; selectedFile = nil; loadingDiff = false; diffFallback = false
            readError = nil
            return
        }
        loadingDiff = diff == nil && fileDiffs.isEmpty
        diffTask = Task { [weak self] in
            guard let self else { return }
            var prepared: [FileDiff]?
            do {
                prepared = try await command.query.allDiffs(targets, commit: commit, reusing: previous)
            } catch {
                // 批量超时、输出上限或文件瞬时消失均退回单文件；上级取消不触发回退。
            }
            guard !Task.isCancelled, generation == diffGeneration else { return }
            if let prepared, !prepared.isEmpty {
                readError = nil
                fileDiffs = prepared
                diffFallback = false
                if commit == nil {
                    let focused = prepared.first {
                        $0.target.path == selectedFile?.path && $0.target.staged == selectedStaged
                    } ?? prepared[0]
                    focusDiff(focused)
                } else {
                    diff = prepared[0].diff
                }
                loadingDiff = false
            } else {
                fallbackDiff(targets, commit: commit)
            }
        }
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
