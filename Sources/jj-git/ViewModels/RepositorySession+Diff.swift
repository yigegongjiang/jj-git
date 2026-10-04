import Foundation

extension RepositorySession {
    func selectFile(_ file: FileChange?, staged: Bool) {
        if let file, let entry = fileDiffs.first(where: { $0.target.path == file.path && $0.target.staged == staged }) {
            focusDiff(entry)
            diffScrollID = entry.id
            diffScrollRequest += 1
            return
        }
        if selectedStaged != staged, let file {
            selectChanges(staged: staged)
            selectedFile = file
            diffScrollID = DiffTarget(path: file.path, file: file, staged: staged).id
            return
        }
        if preparingDiffOverview, let file {
            selectedFile = file
            selectedLines = []
            diffScrollID = DiffTarget(path: file.path, file: file, staged: staged).id
            return
        }
        fileDiffs = []
        selectedFile = file
        selectedStaged = staged
        selectedLines = []
        diff = nil
        reloadSelectedDiff()
    }

    func selectChanges(staged: Bool) {
        selectedStaged = staged
        selectedFile = nil
        selectedLines = []
        fileDiffs = []
        diff = nil
        diffFallback = false
        diffScrollID = nil
        loadDiffOverview(DiffTarget.changes(status, staged: staged))
    }

    /// 行 ID 仅在单文件内唯一，跨文件选中前清空行选择。
    func focusDiff(_ entry: FileDiff) {
        if selectedFile?.path != entry.target.path || selectedStaged != entry.target.staged {
            selectedLines = []
        }
        selectedFile = entry.target.file
        selectedStaged = entry.target.staged
        if section == .history {
            selectedCommitFile = commitDetail?.files.first { $0.path == entry.target.path }
        }
        diff = entry.diff
    }

    func loadDiffOverview(_ targets: [DiffTarget], commit: GitCommit? = nil) {
        diffTask?.cancel()
        diffGeneration += 1
        let generation = diffGeneration
        let previous = fileDiffs
        let wasFallback = diffFallback
        preparingDiffOverview = !targets.isEmpty
        guard !targets.isEmpty else {
            fileDiffs = []; diff = nil; selectedFile = nil; loadingDiff = false; diffFallback = false
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
            preparingDiffOverview = false
            if let prepared, !prepared.isEmpty {
                let focused = prepared.first {
                    $0.target.path == (commit == nil ? selectedFile?.path : selectedCommitFile?.path)
                        && (commit != nil || $0.target.staged == selectedStaged)
                } ?? prepared[0]
                if diff?.raw != focused.diff.raw {
                    selectedLines = []
                }
                fileDiffs = prepared
                diffFallback = false
                focusDiff(focused)
                if previous.isEmpty, diffScrollID != nil {
                    diffScrollRequest += 1
                }
                loadingDiff = false
            } else {
                fallbackDiff(targets, commit: commit, preservingSelection: wasFallback)
            }
        }
    }

    private func fallbackDiff(_ targets: [DiffTarget], commit: GitCommit?, preservingSelection: Bool) {
        fileDiffs = []
        loadingDiff = false
        diffFallback = targets.count > 1
        if let commit {
            selectedCommit = commit
            selectCommitFile(commitDetail?.files.first)
        } else {
            let target = preservingSelection ? targets.first {
                $0.path == selectedFile?.path && $0.staged == selectedStaged
            } ?? targets[0] : targets[0]
            if selectedFile == target.file, selectedStaged == target.staged, diff != nil {
                reloadSelectedDiff()
            } else {
                selectFile(target.file, staged: target.staged)
            }
        }
    }
}
