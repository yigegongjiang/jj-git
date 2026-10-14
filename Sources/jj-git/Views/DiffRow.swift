import Foundation

/// 文件头 / 块头 / 说明 / 差异行扁平化后的一行。
struct DiffRow {
    enum Content {
        case file
        case message(String)
        case hunk(DiffHunk)
        case line(DiffLine)
    }

    let entry: FileDiff
    let content: Content

    static func make(_ entry: FileDiff) -> [Self] {
        var rows = [Self(entry: entry, content: .file)]
        if entry.diff.binary {
            rows.append(Self(entry: entry, content: .message("二进制文件")))
        } else if entry.diff.hunks.isEmpty {
            let headers = String(entry.diff.headers.joined(separator: "\n").prefix(500))
            rows.append(Self(entry: entry, content: .message("无文本差异\n" + headers)))
        } else {
            if let restriction = entry.diff.partialRestriction {
                rows.append(Self(entry: entry, content: .message(restriction)))
            }
            for hunk in entry.diff.hunks {
                rows.append(Self(entry: entry, content: .hunk(hunk)))
                rows += hunk.lines.map { Self(entry: entry, content: .line($0)) }
            }
        }
        return rows
    }
}
