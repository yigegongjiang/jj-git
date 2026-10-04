import Foundation

struct RepositoryGroup: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var collapsed = false

    /// 外部编辑 state.json 新增分组时只需填写 name。
    init(name: String) {
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        collapsed = try container.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
    }
}

struct SavedRepository: Identifiable, Codable, Equatable, Sendable {
    let path: String
    var groupID: UUID?
    /// 使用热度：每次切换到该仓库 +1，按半衰期指数衰减；值为 `usedAt` 时刻的分数。
    var usage: Double?
    /// 最近一次切换到该仓库的时间（Unix 秒）。
    var usedAt: Double?
    var id: String {
        path
    }

    var name: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    static let usageHalfLife: Double = 3 * 24 * 3600

    /// 衰减到 `now` 的热度；从未使用为 0。
    func usage(at now: Double) -> Double {
        guard let usage, let usedAt else { return 0 }
        return usage * pow(0.5, max(0, now - usedAt) / Self.usageHalfLife)
    }

    mutating func recordUse(at now: Double) {
        usage = usage(at: now) + 1
        usedAt = now
    }
}

struct RepositoryLibrary: Codable, Sendable {
    var repositories: [SavedRepository] = []
    var groups: [RepositoryGroup] = []
    var tabs: [String] = []
    var selectedPath: String?
    var sidebarHidden = false
    /// 仓库侧栏已折叠的分区键（localBranches / remoteBranches / tags / remotes / worktrees）；空 = 全部展开。
    var collapsedSections: [String] = []
    /// 主窗口位置与尺寸（屏幕坐标）；nil 时用默认尺寸。
    var window: WindowFrame?
    /// 分栏名 -> 保持尺寸一栏的宽 / 高。
    var splits: [String: Double] = [:]
}

struct WindowFrame: Codable, Equatable, Sendable {
    var minX: Double
    var minY: Double
    var width: Double
    var height: Double
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

/// 仅明确的路径不存在允许快捷移除；权限 / Git 错误保留原记录。
extension SavedRepository {
    static func isMissing(_ path: String) -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: path)
            return false
        } catch {
            let failure = error as NSError
            return (failure.domain == NSCocoaErrorDomain &&
                [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code)) ||
                (failure.domain == NSPOSIXErrorDomain && failure.code == Int(ENOENT))
        }
    }
}
