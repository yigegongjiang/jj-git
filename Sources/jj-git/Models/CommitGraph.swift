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
    var id: String {
        commit.id
    }

    static func build(_ commits: [GitCommit]) -> [Self] {
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
                        continuesFromAbove: continued, edges: edges)
        }
    }
}
