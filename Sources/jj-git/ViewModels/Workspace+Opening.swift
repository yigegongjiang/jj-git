import Foundation

enum RepositoryPicker: String, Identifiable {
    case recent, all
    var id: String {
        rawValue
    }
}

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

    /// ⌘P 列表：按衰减后的使用热度排序，未使用过的按标签 / 仓库列表顺序补足；排除当前与失效仓库。
    /// `query` 非空时按仓库名（忽略大小写）筛选。
    func recentRepositories(matching query: String = "") -> [SavedRepository] {
        let now = Date().timeIntervalSince1970
        let tabs = Dictionary(library.tabs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let candidates = library.repositories.enumerated().filter {
            $0.element.path != library.selectedPath && !missingRepositories.contains($0.element.path) &&
                (query.isEmpty || $0.element.name.localizedCaseInsensitiveContains(query))
        }
        let ranked = candidates.map { (offset: $0.offset, repository: $0.element, usage: $0.element.usage(at: now)) }
            .sorted { lhs, rhs in
                if lhs.usage != rhs.usage {
                    return lhs.usage > rhs.usage
                }
                let left = tabs[lhs.repository.path] ?? Int.max, right = tabs[rhs.repository.path] ?? Int.max
                return left != right ? left < right : lhs.offset < rhs.offset
            }
        return ranked.prefix(config.tabs.recentCount).map(\.repository)
    }

    /// 全部侧栏仓库：按名称排序，包含当前仓库，不限制数量；按名称 / 路径筛选。
    func sidebarRepositories(matching query: String = "") -> [SavedRepository] {
        library.repositories.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) ||
                $0.path.localizedCaseInsensitiveContains(query)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
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
