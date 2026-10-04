import Foundation

/// 标签持有数据的估算体积：字符串字节 + 元素固定开销；不含视图、渲染缓存与系统框架内存。
struct SessionUsage: Sendable {
    var bytes = 0
    var commits = 0
    var diffFiles = 0
    var diffLines = 0
}

/// 主线程上拷贝（写时复制，开销为常数），在后台遍历计算。
struct SessionSnapshot: Sendable {
    let status: WorkingCopyStatus
    let references: [GitReference]
    let graph: [CommitGraphRow]
    let commitDetail: CommitDetail?
    let diff: TextDiff?
    let fileDiffs: [FileDiff]

    func usage() -> SessionUsage {
        var usage = SessionUsage(commits: graph.count, diffFiles: fileDiffs.count)
        usage.bytes += Self.array(status.changes) { Self.string($0.path) + Self.string($0.originalPath ?? "") }
        usage.bytes += Self.array(references) {
            Self.string($0.name) + Self.string($0.fullName) + Self.string($0.target) + Self.string($0.upstream)
                + Self.string($0.checkedOutPath)
        }
        usage.bytes += Self.array(graph) { row in
            let commit = row.commit
            return Self.string(commit.hash) + Self.string(commit.author) + Self.string(commit.email)
                + Self.string(commit.subject) + Self.string(commit.decorations)
                + Self.array(commit.parents, Self.string) + Self.array(row.edges) { _ in 0 }
        }
        if let commitDetail {
            usage.bytes += Self.string(commitDetail.message)
                + Self.array(commitDetail.files) { Self.string($0.path) + Self.string($0.status) }
        }
        var lines = 0
        usage.bytes += Self.array(fileDiffs) { Self.string($0.target.path) + Self.diff($0.diff, lines: &lines) }
        // 单文件差异通常与总览中的某一项共享存储，只统计独立的那份。
        if let diff, !fileDiffs.contains(where: { $0.diff.raw == diff.raw }) {
            usage.diffFiles += 1
            usage.bytes += Self.diff(diff, lines: &lines)
        }
        usage.diffLines = lines
        return usage
    }

    private static func diff(_ diff: TextDiff, lines: inout Int) -> Int {
        lines += diff.hunks.reduce(0) { $0 + $1.lines.count }
        return string(diff.raw) + array(diff.headers, string)
            + array(diff.hunks) { string($0.header) + array($0.lines) { string($0.raw) } }
    }

    /// 15 字节以内的字符串内联存储；更长的另有堆对象（约 32 字节头部）。
    private static func string(_ value: String) -> Int {
        let count = value.utf8.count
        return count > 15 ? count + 32 : 0
    }

    private static func array<T>(_ items: [T], _ element: (T) -> Int) -> Int {
        guard !items.isEmpty else { return 0 }
        return 32 + items.count * MemoryLayout<T>.stride + items.reduce(0) { $0 + element($1) }
    }
}

extension RepositorySession {
    var snapshot: SessionSnapshot {
        SessionSnapshot(status: status, references: references, graph: graph,
                        commitDetail: commitDetail, diff: diff, fileDiffs: fileDiffs)
    }
}
