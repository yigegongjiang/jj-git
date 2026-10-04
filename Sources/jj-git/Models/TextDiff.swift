import Foundation

struct DiffLine: Identifiable, Hashable, Sendable {
    let id: Int
    let raw: String
    let oldLine: Int?
    let newLine: Int?
    var noNewline = false
    var kind: Character {
        raw.first ?? " "
    }

    var content: String {
        String(raw.dropFirst())
    }

    var changed: Bool {
        kind == "+" || kind == "-"
    }
}

struct DiffHunk: Identifiable, Sendable {
    let id: Int
    let header: String
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    var lines: [DiffLine]
    var changeIDs: Set<Int> {
        Set(lines.filter(\.changed).map(\.id))
    }
}

struct TextDiff: Sendable {
    let raw: String
    var headers: [String] = []
    var hunks: [DiffHunk] = []
    var partialRestriction: String?
    var binary: Bool {
        headers.contains { $0.hasPrefix("Binary files ") || $0 == "GIT binary patch" }
    }

    var changeIDs: Set<Int> {
        Set(hunks.flatMap(\.lines).filter(\.changed).map(\.id))
    }

    init(_ raw: String) {
        self.raw = raw
        var oldLine = 0
        var newLine = 0
        var nextID = 0
        for line in raw.components(separatedBy: "\n") {
            if let hunk = Self.hunk(line, id: hunks.count) {
                hunks.append(hunk)
                oldLine = hunk.oldStart
                newLine = hunk.newStart
            } else if let last = hunks.indices.last, line.hasPrefix("\\"), !hunks[last].lines.isEmpty {
                hunks[last].lines[hunks[last].lines.count - 1].noNewline = true
            } else if let last = hunks.indices.last, let kind = line.first, [" ", "+", "-"].contains(kind) {
                hunks[last].lines.append(DiffLine(id: nextID, raw: line,
                                                  oldLine: kind == "+" ? nil : oldLine,
                                                  newLine: kind == "-" ? nil : newLine))
                nextID += 1
                if kind != "+" {
                    oldLine += 1
                }
                if kind != "-" {
                    newLine += 1
                }
            } else if hunks.isEmpty, !line.isEmpty {
                headers.append(line)
            } else if line.hasPrefix("diff --git ") {
                partialRestriction = "文件类型发生变化，请按整个文件操作。"
            }
        }
        if raw.contains("Subproject commit ") || raw.contains("mode 120000") {
            partialRestriction = "子模块与符号链接请按整个文件操作。"
        }
        if raw.hasPrefix("diff --cc ") || raw.hasPrefix("diff --combined ") {
            partialRestriction = "请先在编辑器解决冲突，再暂存整个文件。"
        }
    }

    /// 以 index 为应用基准；未选中的删除转为上下文，未选中的新增不进入补丁。
    func patch(selecting selection: Set<Int>, reverse: Bool) throws -> Data {
        if let partialRestriction {
            throw GitFailure(message: partialRestriction)
        }
        let selected = selection.intersection(changeIDs)
        guard !selected.isEmpty else { throw GitFailure(message: "请先选择差异行。") }
        let complete = selected == changeIDs
        var output = patchHeaders(reverse: reverse, complete: complete)
        var offset = 0
        for hunk in hunks where !hunk.changeIDs.isDisjoint(with: selected) {
            let transformed = transform(hunk, selected: selected, reverse: reverse)
            let oldCount = transformed.filter { $0.first != "+" && $0.first != "\\" }.count
            let newCount = transformed.filter { $0.first != "-" && $0.first != "\\" }.count
            let sourceStart = reverse ? hunk.newStart : hunk.oldStart
            let sourceCount = reverse ? hunk.newCount : hunk.oldCount
            let logicalStart = sourceStart + (sourceCount == 0 ? 1 : 0)
            let oldStart = logicalStart - (oldCount == 0 ? 1 : 0)
            let newStart = logicalStart + offset - (newCount == 0 ? 1 : 0)
            output.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@")
            output.append(contentsOf: transformed)
            offset += newCount - oldCount
        }
        return Data((output.joined(separator: "\n") + "\n").utf8)
    }

    private func transform(_ hunk: DiffHunk, selected: Set<Int>, reverse: Bool) -> [String] {
        var result: [String] = []
        var cursor = 0
        func append(_ line: DiffLine, prefix: String) {
            result.append(prefix + line.content)
            if line.noNewline {
                result.append("\\ No newline at end of file")
            }
        }
        while cursor < hunk.lines.count {
            let line = hunk.lines[cursor]
            if !line.changed {
                append(line, prefix: " ")
                cursor += 1
                continue
            }
            let start = cursor
            while cursor < hunk.lines.count, hunk.lines[cursor].changed { cursor += 1 }
            let block = hunk.lines[start..<cursor]
            let removed = block.filter { $0.kind == (reverse ? "+" : "-") }
            let added = block.filter { $0.kind == (reverse ? "-" : "+") }
            // 同一个替换块按行配对，避免未选中的旧行出现在已选中的新行前面。
            for index in 0..<max(removed.count, added.count) {
                if index < removed.count {
                    let old = removed[index]
                    append(old, prefix: selected.contains(old.id) ? "-" : " ")
                }
                if index < added.count, selected.contains(added[index].id) {
                    append(added[index], prefix: "+")
                }
            }
        }
        return Self.normalizeEndOfFile(result)
    }

    private static func normalizeEndOfFile(_ lines: [String]) -> [String] {
        var result: [String] = []
        let lastContent = lines.lastIndex { $0.hasPrefix("+") || $0.hasPrefix(" ") } ?? -1
        for (index, line) in lines.enumerated() {
            let marked = index + 1 < lines.count && lines[index + 1].hasPrefix("\\")
            if line.hasPrefix(" "), marked, lastContent > index + 1 {
                result += ["-" + line.dropFirst(), lines[index + 1], "+" + line.dropFirst()]
            } else if line.hasPrefix("\\"), index > 0, lines[index - 1].hasPrefix(" "),
                      lastContent > index {
                continue
            } else {
                result.append(line)
            }
        }
        return result
    }

    private func patchHeaders(reverse: Bool, complete: Bool) -> [String] {
        let oldPath = headers.first { $0.hasPrefix("--- ") }.map { String($0.dropFirst(4)) } ?? "/dev/null"
        let newPath = headers.first { $0.hasPrefix("+++ ") }.map { String($0.dropFirst(4)) } ?? "/dev/null"
        let source = reverse ? newPath : oldPath
        let target = reverse ? oldPath : newPath
        let sourceExists = source != "/dev/null"
        let targetExists = target != "/dev/null" || !complete
        let mode = headers.first { $0.hasPrefix("new file mode ") || $0.hasPrefix("deleted file mode ") }
            .map { String($0.suffix(6)) } ?? "100644"
        var result: [String] = []
        if let header = headers.first, header.hasPrefix("diff --git ") {
            result.append(header)
        }
        if !sourceExists {
            result.append("new file mode \(mode)")
        }
        if !targetExists {
            result.append("deleted file mode \(mode)")
        }
        let existing = sourceExists ? source : target
        let sourcePath = sourceExists ? Self.prefixed(existing, "a/") : "/dev/null"
        let targetPath = targetExists ? Self.prefixed(existing, "b/") : "/dev/null"
        result.append("--- " + sourcePath)
        result.append("+++ " + targetPath)
        return result
    }

    private static func prefixed(_ path: String, _ prefix: String) -> String {
        if path.hasPrefix("\"") {
            return "\"" + prefix + path.dropFirst(3)
        }
        return prefix + path.dropFirst(2)
    }

    private static func hunk(_ line: String, id: Int) -> DiffHunk? {
        guard line.hasPrefix("@@ ") else { return nil }
        let fields = line.split(separator: " ")
        guard fields.count >= 4 else { return nil }
        let old = fields[1].dropFirst().split(separator: ",")
        let new = fields[2].dropFirst().split(separator: ",")
        guard let oldStart = old.first.flatMap({ Int($0) }), let newStart = new.first.flatMap({ Int($0) }) else {
            return nil
        }
        return DiffHunk(id: id, header: line, oldStart: oldStart,
                        oldCount: old.count == 2 ? Int(old[1]) ?? 0 : 1,
                        newStart: newStart, newCount: new.count == 2 ? Int(new[1]) ?? 0 : 1, lines: [])
    }
}
