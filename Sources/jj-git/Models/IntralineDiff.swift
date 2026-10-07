import Foundation

/// 相邻替换块内按相似度顺序配对；超限保留整行底色。全部计算在 diff 解析阶段完成。
struct IntralineDiff {
    private let deadline: ContinuousClock.Instant
    private var remaining = 1_000_000

    init(deadline: ContinuousClock.Instant?) {
        let limit = ContinuousClock.now.advanced(by: .milliseconds(30))
        self.deadline = min(deadline ?? limit, limit)
    }

    var available: Bool {
        remaining > 0 && !Task.isCancelled && ContinuousClock.now < deadline
    }

    mutating func annotate(_ lines: inout [DiffLine]) {
        var cursor = 0
        while cursor < lines.count, available {
            guard lines[cursor].changed else {
                cursor += 1
                continue
            }
            let start = cursor
            while cursor < lines.count, lines[cursor].changed {
                cursor += 1
                if cursor.isMultiple(of: 256), !available {
                    return
                }
            }
            guard cursor - start <= 256 else { continue }
            let removed = (start..<cursor).filter { lines[$0].kind == "-" }
            let added = (start..<cursor).filter { lines[$0].kind == "+" }
            pair(removed: removed, added: added, lines: &lines)
        }
    }

    private mutating func pair(removed: [Int], added: [Int], lines: inout [DiffLine]) {
        var next = 0
        for oldIndex in removed {
            guard available, next < added.count else { break }
            guard let old = characters(lines[oldIndex]) else { continue }
            var best: (index: Int, edit: Edit)?
            // 有额外新增行时向前找相似行；有界搜索避免大型替换块的平方复杂度。
            for candidate in next..<min(next + 8, added.count) {
                guard available else { break }
                guard let new = characters(lines[added[candidate]]), let edit = compare(old, new) else {
                    continue
                }
                if edit.similarity >= 0.5, edit.similarity > (best?.edit.similarity ?? 0) {
                    best = (candidate, edit)
                }
                if edit.similarity == 1 {
                    break
                }
            }
            if let best {
                lines[oldIndex].emphasis = best.edit.old
                lines[added[best.index]].emphasis = best.edit.new
                next = best.index + 1
            }
        }
    }

    private func characters(_ line: DiffLine) -> [Character]? {
        // 字节限制同时防止单个 grapheme 含大量 combining scalars。
        guard line.raw.utf8.count <= 16384 else { return nil }
        let result = Array(line.raw.dropFirst().prefix(DiffLine.displayLimit + 1))
        return result.count <= DiffLine.displayLimit ? result : nil
    }

    private struct Edit {
        let old: [NSRange]
        let new: [NSRange]
        let similarity: Double
    }

    private mutating func compare(_ old: [Character], _ new: [Character]) -> Edit? {
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var oldEnd = old.count
        var newEnd = new.count
        while oldEnd > prefix, newEnd > prefix, old[oldEnd - 1] == new[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        let cost = (oldEnd - prefix + 1) * (newEnd - prefix + 1) + old.count + new.count
        guard cost <= 65536, cost <= remaining else { return nil }
        remaining -= cost
        let changes = Array(new[prefix..<newEnd]).difference(from: Array(old[prefix..<oldEnd]))
        var oldChanged = Set<Int>()
        var newChanged = Set<Int>()
        for change in changes {
            switch change {
            case let .remove(offset, _, _): oldChanged.insert(prefix + offset)
            case let .insert(offset, _, _): newChanged.insert(prefix + offset)
            }
        }
        // 空格和缩进不能单独使不相关的代码行配对。
        let oldWeight = old.filter { !$0.isWhitespace }.count
        let newWeight = new.filter { !$0.isWhitespace }.count
        let common = old.indices.filter { !oldChanged.contains($0) && !old[$0].isWhitespace }.count
        let weight = oldWeight + newWeight
        let similarity = weight == 0 ? 1 : Double(common * 2) / Double(weight)
        return Edit(old: ranges(oldChanged, in: old), new: ranges(newChanged, in: new), similarity: similarity)
    }

    /// Character 边界转为 NSTextField 的 UTF-16 范围，制表符与 display 同步展开。
    private func ranges(_ changed: Set<Int>, in characters: [Character]) -> [NSRange] {
        var result: [NSRange] = []
        var offset = 0
        for (index, character) in characters.enumerated() {
            let length = character == "\t" ? 4 : String(character).utf16.count
            if changed.contains(index) {
                if let last = result.last, NSMaxRange(last) == offset {
                    result[result.count - 1].length += length
                } else {
                    result.append(NSRange(location: offset, length: length))
                }
            }
            offset += length
        }
        return result
    }
}
