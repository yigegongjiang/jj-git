import Foundation

extension Workspace {
    func restore() async {
        checkMissingRepositories()
        await repositoryCheckTask?.value
        let selected = library.selectedPath
        for path in library.tabs where !missingRepositories.contains(path) {
            await open(path, select: path == selected)
        }
        // 打开失败的标签保留（可能只是等待系统授权），点击标签时重试；不再需要时手动关闭。
        if self.selected == nil, let path = library.tabs.first(where: { sessions[$0] != nil }) {
            select(path)
        }
    }

    func reportOpenFailure(_ failure: Error, path: String) {
        if SavedRepository.isMissing(path) {
            if !missingRepositories.contains(path) {
                missingRepositories.append(path)
                missingRepositories.sort()
            }
        } else {
            missingRepositories.removeAll { $0 == path }
            error = "\(path)\n\(failure.localizedDescription)"
        }
    }

    /// 检查全部已保存仓库与标签；文件系统访问在后台执行。
    func checkMissingRepositories() {
        repositoryCheckTask?.cancel()
        let paths = Array(Set(library.repositories.map(\.path) + library.tabs + missingRepositories)).sorted()
        let check = Task.detached(priority: .utility) {
            var missing: [String] = []
            for path in paths {
                guard !Task.isCancelled else { break }
                if SavedRepository.isMissing(path) {
                    missing.append(path)
                }
            }
            return missing
        }
        repositoryCheckTask = Task { [weak self] in
            let missing = await withTaskCancellationHandler {
                await check.value
            } onCancel: { check.cancel() }
            guard let self, !Task.isCancelled else { return }
            let known = Set(library.repositories.map(\.path) + library.tabs + missingRepositories)
            let added = missingRepositories.filter { !paths.contains($0) }
            missingRepositories = (missing + added).filter { known.contains($0) }.sorted()
        }
    }

    func removeMissingRepositories(_ paths: [String]) {
        // 点击时重新检查，避免移除已恢复的路径。
        for path in paths where SavedRepository.isMissing(path) {
            remove(path)
        }
        checkMissingRepositories()
    }
}
