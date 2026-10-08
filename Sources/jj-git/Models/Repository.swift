import Foundation

struct RepositoryLocation: Hashable, Sendable {
    let root: String
    let gitDirectory: String
    let commonDirectory: String
    var name: String {
        URL(fileURLWithPath: root).lastPathComponent
    }
}

struct FileChange: Identifiable, Hashable, Sendable {
    let path: String
    let originalPath: String?
    let index: Character
    let worktree: Character
    let conflicted: Bool
    let submodule: Bool
    var id: String {
        path
    }

    var staged: Bool {
        index != "." && index != "?"
    }

    var unstaged: Bool {
        worktree != "." || conflicted
    }

    var untracked: Bool {
        index == "?"
    }

    var paths: [String] {
        [path] + (originalPath.map { [$0] } ?? [])
    }

    /// 暂存区里的 rename/copy 原路径已不在 index 与工作区，传给 git add 会使整批 pathspec 失败；
    /// 仅工作区 rename（intent-to-add）需带原路径以暂存其删除。
    var stagePaths: [String] {
        index == "." ? paths : [path]
    }
}

struct WorkingCopyStatus: Equatable, Sendable {
    var branch = ""
    var head = ""
    var upstream = ""
    var ahead = 0
    var behind = 0
    var changes: [FileChange] = []
    var unborn: Bool {
        head == "(initial)"
    }

    var detached: Bool {
        branch == "(detached)"
    }

    var conflicts: Bool {
        changes.contains(where: \.conflicted)
    }

    static func parse(_ text: String) throws -> Self {
        var status = Self()
        let records = text.split(separator: "\0", omittingEmptySubsequences: true)
        var cursor = 0
        while cursor < records.count {
            let record = records[cursor]
            cursor += 1
            if record.hasPrefix("# ") {
                status.parseHeader(record)
                continue
            }
            if record.hasPrefix("? ") {
                status.changes.append(FileChange(path: String(record.dropFirst(2)), originalPath: nil,
                                                 index: "?", worktree: "?", conflicted: false, submodule: false))
                continue
            }
            guard let kind = record.first, ["1", "2", "u"].contains(kind) else { continue }
            let fieldCount = kind == "1" ? 8 : (kind == "2" ? 9 : 10)
            let fields = record.split(separator: " ", maxSplits: fieldCount, omittingEmptySubsequences: false)
            guard fields.count == fieldCount + 1, fields[1].count == 2 else {
                throw GitFailure(message: "无法解析 Git status 记录。")
            }
            var original: String?
            if kind == "2" {
                guard cursor < records.count else { throw GitFailure(message: "Git rename 记录缺少原路径。") }
                original = String(records[cursor])
                cursor += 1
            }
            status.changes.append(FileChange(
                path: String(fields[fieldCount]), originalPath: original,
                index: fields[1].first ?? ".", worktree: fields[1].last ?? ".",
                conflicted: kind == "u", submodule: fields[2].first == "S"
            ))
        }
        status.changes.sort { FilePath.precedes($0.path, $1.path) }
        return status
    }

    private mutating func parseHeader(_ record: Substring) {
        let parts = record.split(separator: " ", maxSplits: 2)
        guard parts.count == 3 else { return }
        switch parts[1] {
        case "branch.oid": head = String(parts[2])
        case "branch.head": branch = String(parts[2])
        case "branch.upstream": upstream = String(parts[2])
        case "branch.ab":
            let counts = parts[2].split(separator: " ")
            ahead = Int(counts.first?.dropFirst() ?? "") ?? 0
            behind = Int(counts.last?.dropFirst() ?? "") ?? 0
        default: break
        }
    }
}

struct GitReference: Identifiable, Hashable, Sendable {
    let name: String
    let fullName: String
    let target: String
    let upstream: String
    let current: Bool
    let checkedOutPath: String
    var id: String {
        fullName
    }

    var remote: Bool {
        fullName.hasPrefix("refs/remotes/")
    }

    var tag: Bool {
        fullName.hasPrefix("refs/tags/")
    }
}

struct GitRemote: Identifiable, Hashable, Sendable {
    let name: String
    let url: String
    var id: String {
        name
    }
}

struct GitWorktree: Identifiable, Hashable, Sendable {
    var path: String
    var branch = ""
    var head = ""
    var bare = false
    var locked = false
    var prunable = false
    var id: String {
        path
    }

    static func parse(_ text: String) -> [Self] {
        var items: [Self] = []
        for field in text.split(separator: "\0", omittingEmptySubsequences: false) {
            if field.hasPrefix("worktree ") {
                items.append(Self(path: String(field.dropFirst(9))))
            } else if !items.isEmpty {
                let index = items.count - 1
                if field.hasPrefix("branch ") {
                    items[index].branch = String(field.dropFirst(7))
                }
                if field.hasPrefix("HEAD ") {
                    items[index].head = String(field.dropFirst(5))
                }
                if field == "bare" {
                    items[index].bare = true
                }
                if field.hasPrefix("locked") {
                    items[index].locked = true
                }
                if field.hasPrefix("prunable") {
                    items[index].prunable = true
                }
            }
        }
        return items
    }
}

struct GitCommit: Identifiable, Hashable, Sendable {
    let hash: String
    let parents: [String]
    let author: String
    let email: String
    let date: Date
    let subject: String
    let decorations: String
    var id: String {
        hash
    }

    var shortHash: String {
        String(hash.prefix(8))
    }
}

struct CommitDetail: Sendable {
    let message: String
    let files: [CommitFile]
}

/// 文件列表按目录归组：同目录文件相邻（目录内先文件、后子目录），数字按数值比较；
/// 仅大小写不同时按字节比较，保证轮询间顺序稳定。
enum FilePath {
    static func split(_ path: String) -> (directory: String, name: String) {
        // 未跟踪目录 / 子模块可能以 "/" 结尾，名称保留该后缀。
        guard let slash = path.dropLast().lastIndex(of: "/") else { return ("", path) }
        return (String(path[..<slash]), String(path[path.index(after: slash)...]))
    }

    static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        let left = split(lhs), right = split(rhs)
        for (lhsPart, rhsPart) in [(left.directory, right.directory), (left.name, right.name)] {
            switch lhsPart.localizedStandardCompare(rhsPart) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: continue
            }
        }
        return lhs < rhs
    }
}

struct CommitFile: Identifiable, Hashable, Sendable {
    let path: String
    let status: String
    var id: String {
        path
    }
}
