import Foundation

struct RepositoryGroup: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    /// 可选字段，兼容旧配置。
    var collapsed: Bool?
}

struct SavedRepository: Identifiable, Codable, Equatable, Sendable {
    let path: String
    var groupID: UUID?
    var id: String {
        path
    }

    var name: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

struct RepositoryLibrary: Codable, Sendable {
    var repositories: [SavedRepository] = []
    var groups: [RepositoryGroup] = []
    var tabs: [String] = []
    var selectedPath: String?
    var sidebarHidden: Bool?
}

struct ScanResult: Sendable {
    var paths: [String] = []
    var inaccessible: [String] = []
}

enum RepositoryScanner {
    static func scan(_ root: String) async throws -> ScanResult {
        let task = Task.detached(priority: .userInitiated) { () throws -> ScanResult in
            try scanDirectory(root)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func scanDirectory(_ root: String) throws -> ScanResult {
        let manager = FileManager.default
        var result = ScanResult()
        func isRepository(_ path: String) -> Bool {
            manager.fileExists(atPath: path + "/.git")
        }
        if isRepository(root) {
            return ScanResult(paths: [root])
        }
        guard let enumerator = manager.enumerator(
            at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, _ in
                result.inaccessible.append(url.path)
                return true
            }
        ) else { throw GitFailure(message: "无法读取扫描目录。") }
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let resource = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard resource?.isDirectory == true else { continue }
            if resource?.isSymbolicLink == true || url.lastPathComponent == "node_modules" {
                enumerator.skipDescendants()
            } else if isRepository(url.path) {
                result.paths.append(url.path)
                enumerator.skipDescendants()
            }
        }
        return result
    }
}
