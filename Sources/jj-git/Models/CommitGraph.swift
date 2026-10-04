import Foundation

struct GraphEdge: Sendable {
    let from: Int
    let target: Int
    let beginsAtCommit: Bool
}

struct CommitGraphRow: Identifiable, Sendable {
    let commit: GitCommit
    let lane: Int
    let width: Int
    let continuesFromAbove: Bool
    let edges: [GraphEdge]
    /// 可从 HEAD 到达；其余提交（未合并的分支 / 标签）淡化显示。
    let merged: Bool
    var id: String {
        commit.id
    }

    static func build(_ commits: [GitCommit], head: String) -> [Self] {
        let merged = reachable(from: head, in: commits)
        var lanes: [String] = []
        return commits.map { commit in
            let continued = lanes.contains(commit.hash)
            if !continued {
                lanes.append(commit.hash)
            }
            let lane = lanes.firstIndex(of: commit.hash) ?? 0
            let before = lanes
            lanes.remove(at: lane)
            for (index, parent) in commit.parents.enumerated() where !lanes.contains(parent) {
                lanes.insert(parent, at: index == 0 ? min(lane, lanes.count) : lanes.count)
            }
            var edges: [GraphEdge] = []
            for (index, hash) in before.enumerated() where index != lane {
                if let target = lanes.firstIndex(of: hash) {
                    edges.append(GraphEdge(from: index, target: target, beginsAtCommit: false))
                }
            }
            for parent in commit.parents {
                if let target = lanes.firstIndex(of: parent) {
                    edges.append(GraphEdge(from: lane, target: target, beginsAtCommit: true))
                }
            }
            return Self(commit: commit, lane: lane, width: max(before.count, lanes.count),
                        continuesFromAbove: continued, edges: edges,
                        merged: merged.isEmpty || merged.contains(commit.hash))
        }
    }

    /// HEAD 不在已加载的提交中（未出生 / 分离到范围外）时返回空，全部按已合并显示。
    private static func reachable(from head: String, in commits: [GitCommit]) -> Set<String> {
        let parents = Dictionary(commits.map { ($0.hash, $0.parents) }, uniquingKeysWith: { first, _ in first })
        guard parents[head] != nil else { return [] }
        var result: Set<String> = []
        var pending = [head]
        while let hash = pending.popLast() {
            guard result.insert(hash).inserted, let next = parents[hash] else { continue }
            pending.append(contentsOf: next)
        }
        return result
    }
}
