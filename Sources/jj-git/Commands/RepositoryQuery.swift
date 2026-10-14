import Foundation

struct ReferenceSnapshot: Sendable {
    let references: [GitReference]
    let remotes: [GitRemote]
    let worktrees: [GitWorktree]
}

struct RepositoryQuery: Sendable {
    let location: RepositoryLocation

    static func locate(_ path: String) async throws -> RepositoryLocation {
        async let root = GitProcess.run(at: path, ["rev-parse", "--show-toplevel"])
        async let directory = GitProcess.run(at: path, ["rev-parse", "--absolute-git-dir"])
        async let common = GitProcess.run(at: path, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        let paths: [String]
        do {
            paths = try await [root, directory, common].map { try String($0.checkedText().dropLast()) }
        } catch let failure as GitFailure where failure.timedOut {
            // 新版本首次访问「文稿」等受保护目录时，Git 会阻塞到用户响应系统授权弹窗。
            throw GitFailure(message: "读取仓库超时。若 macOS 正在询问文件夹访问权限，允许后点击仓库重试。")
        }
        guard paths.allSatisfy({ $0.hasPrefix("/") }) else {
            throw GitFailure(message: "请选择带工作目录的 Git 仓库。")
        }
        // Git 输出的已是真实路径，与 `worktree list` 一致，直接使用。
        return RepositoryLocation(root: paths[0], gitDirectory: paths[1], commonDirectory: paths[2])
    }

    func status() async throws -> WorkingCopyStatus {
        let output = try await run(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"])
        return try WorkingCopyStatus.parse(output.checkedText())
    }

    func references() async throws -> [GitReference] {
        let format = "%(refname)%00%(objectname)%00%(upstream:short)%00%(HEAD)%00%(worktreepath)%00%(symref)%00"
        let output = try await run(["for-each-ref", "--sort=refname", "--format=\(format)",
                                    "refs/heads", "refs/remotes", "refs/tags"])
        return try output.checkedText().components(separatedBy: "\0\n").compactMap { line in
            let fields = line.components(separatedBy: "\0")
            guard fields.count == 6, fields[5].isEmpty else { return nil }
            let name = fields[0].split(separator: "/").dropFirst(2).joined(separator: "/")
            return GitReference(name: name, fullName: fields[0], target: fields[1], upstream: fields[2],
                                current: fields[3] == "*", checkedOutPath: fields[4])
        }
    }

    func remotes() async throws -> [GitRemote] {
        // `remote -v` 每个远程输出 fetch / push 两行，取 fetch 行。
        try await run(["remote", "-v"]).checkedText().split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2, fields[1].hasSuffix(" (fetch)") else { return nil }
            return GitRemote(name: String(fields[0]), url: String(fields[1].dropLast(8)))
        }
    }

    func worktrees() async throws -> [GitWorktree] {
        let output = try await run(["worktree", "list", "--porcelain", "-z"])
        return try GitWorktree.parse(output.checkedText())
    }

    /// ref / 远程 / 工作树并行读取。
    func referenceSnapshot() async throws -> ReferenceSnapshot {
        async let references = references()
        async let remotes = remotes()
        async let worktrees = worktrees()
        return try await ReferenceSnapshot(references: references, remotes: remotes, worktrees: worktrees)
    }

    /// 未出生的 HEAD（尚无提交）不存在；只读 ref，不扫描工作区。
    func headExists() async throws -> Bool {
        try await GitProcess.run(at: location.root, ["rev-parse", "--verify", "--quiet", "HEAD"],
                                 accepted: [0, 1], readOnly: true).status == 0
    }

    /// 只读暂存区中的未合并条目，与 status 的冲突记录一致，不扫描工作区。
    func hasConflicts() async throws -> Bool {
        try await !run(["ls-files", "--unmerged", "-z"]).data.isEmpty
    }

    /// 提交图在后台构建，主线程只接收结果。
    func history(limit: Int, includeHead: Bool, head: String) async throws -> CommitHistory {
        let commits = try await commits(limit: limit, includeHead: includeHead)
        try Task.checkCancellation()
        let rows = CommitGraphRow.build(commits, head: head)
        return CommitHistory(rows: rows, lanes: min(rows.map(\.width).max() ?? 1, 8),
                             complete: commits.count < limit)
    }

    /// 只取分支 / 远端 / 标签 / HEAD，排除 stash、notes 等内部引用；未出生的 HEAD 不能作为修订参数。
    private func commits(limit: Int, includeHead: Bool) async throws -> [GitCommit] {
        let format = "%H%x00%P%x00%an%x00%ae%x00%ct%x00%s%x00%D"
        let output = try await run(["log", "--branches", "--remotes", "--tags", "--date-order", "--no-show-signature",
                                    "--decorate=short", "--format=\(format)", "--max-count=\(limit)"]
                + (includeHead ? ["HEAD"] : []) + ["--"])
        return output.text.components(separatedBy: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\0")
            guard fields.count == 7 else { return nil }
            return GitCommit(hash: fields[0], parents: fields[1].split(separator: " ").map(String.init),
                             author: fields[2], email: fields[3],
                             date: Date(timeIntervalSince1970: Double(fields[4]) ?? 0),
                             subject: fields[5], decorations: fields[6])
        }
    }

    func detail(_ commit: GitCommit) async throws -> CommitDetail {
        async let message = run(["show", "--no-patch", "--no-show-signature", "--format=fuller", commit.hash, "--"])
        let fileArguments = ["diff-tree", "--root", "--no-commit-id", "--name-status", "--no-renames",
                             "-r", "-z"] + (commit.parents.isEmpty ? [commit.hash] : [commit.parents[0], commit.hash])
        async let files = run(fileArguments)
        let values = try await (message, files)
        let fields = try values.1.checkedText().split(separator: "\0").map(String.init)
        var changes: [CommitFile] = []
        for index in stride(from: 0, to: max(0, fields.count - 1), by: 2) {
            changes.append(CommitFile(path: fields[index + 1], status: fields[index]))
        }
        changes.sort { FilePath.precedes($0.path, $1.path) }
        return CommitDetail(message: values.0.text, files: changes)
    }

    func commitDiff(
        _ commit: GitCommit, path: String, deadline: ContinuousClock.Instant? = nil
    ) async throws -> TextDiff {
        let arguments = ["show", "--format=", "--first-parent", "--root"] + Self.diffOptions + [commit.hash, "--", path]
        let output = try await run(arguments)
        let (text, lossless) = output.diffText
        return try TextDiff(text, lossless: lossless, deadline: deadline)
    }

    /// 轮询刷新时内容通常未变：原文相同直接复用 previous，跳过大差异的重新解析。
    func diff(_ file: FileChange, staged: Bool, reusing previous: TextDiff? = nil,
              deadline: ContinuousClock.Instant? = nil) async throws -> TextDiff {
        var arguments = ["diff"] + Self.diffOptions
        if file.untracked {
            arguments += ["--no-index", "--", "/dev/null", file.path]
        } else {
            if staged {
                arguments.append("--cached")
            }
            arguments += ["--", file.path]
        }
        let output = try await GitProcess.run(at: location.root, arguments, accepted: file.untracked ? [0, 1] : [0],
                                              readOnly: true)
        let (text, lossless) = output.diffText
        if let previous, previous.lossless == lossless, previous.raw.utf8.elementsEqual(text.utf8) {
            return previous
        }
        return try TextDiff(text, lossless: lossless, deadline: deadline)
    }

    /// 同时读取的差异进程数：逐个读取时总耗时随文件数线性增长，过多则争抢 CPU 与磁盘。
    private static let parallelReads = 4
    /// 全部读取超过该时长时先显示已就绪的部分，避免大批文件期间界面空白。
    private static let prefixDelay = Duration.milliseconds(50)

    /// 有界并发读取、按原顺序返回；统一预算包含读取、解析与宽度计算，超时 / 超限返回 nil，取消会终止 Git。
    /// `known`：确认未变化的差异，直接沿用不执行 Git；`prefix`：读取超过 prefixDelay 仍未完成时，交出一次已就绪的连续前缀。
    func allDiffs(
        _ targets: [DiffTarget], commit: GitCommit?, reusing previous: [FileDiff], known: [String: TextDiff] = [:],
        prefix: (@MainActor @Sendable ([FileDiff]) -> Void)? = nil
    ) async throws -> [FileDiff]? {
        let timeout = AppConfig.current.diff.previewTimeoutMilliseconds
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeout))
        let cached = Dictionary(previous.map { ($0.id, $0.diff) }, uniquingKeysWith: { first, _ in first })
        return try await withThrowingTaskGroup(of: [FileDiff]?.self) { group in
            group.addTask {
                try await readDiffs(DiffBatch(targets: targets, commit: commit, cached: cached, known: known),
                                    deadline: deadline, prefix: prefix)
            }
            group.addTask {
                try await ContinuousClock().sleep(until: deadline)
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    /// `cached`：上次的结果，原文相同时跳过解析；`known`：确认未变化，不执行 Git。
    private struct DiffBatch: Sendable {
        let targets: [DiffTarget]
        let commit: GitCommit?
        let cached: [String: TextDiff]
        let known: [String: TextDiff]
    }

    private func readDiffs(
        _ batch: DiffBatch, deadline: ContinuousClock.Instant, prefix: (@MainActor @Sendable ([FileDiff]) -> Void)?
    ) async throws -> [FileDiff]? {
        let targets = batch.targets, commit = batch.commit, cached = batch.cached, known = batch.known
        let started = ContinuousClock.now
        let limit = AppConfig.current.git.outputLimitMiB * 1024 * 1024
        return try await withThrowingTaskGroup(of: (Int, TextDiff?).self) { readers in
            defer { readers.cancelAll() }
            var results = [TextDiff?](repeating: nil, count: targets.count)
            var next = 0, ready = 0, bytes = 0
            var prefix = prefix
            func read(_ index: Int) {
                let target = targets[index]
                let unchanged = known[target.id]
                readers.addTask {
                    if let unchanged {
                        return (index, unchanged)
                    }
                    if let commit {
                        return try await (index, commitDiff(commit, path: target.path, deadline: deadline))
                    }
                    guard let file = target.file else { return (index, nil) }
                    return try await (index, diff(file, staged: target.staged, reusing: cached[target.id],
                                                  deadline: deadline))
                }
            }
            while next < min(Self.parallelReads, targets.count) {
                read(next)
                next += 1
            }
            while let (index, diff) = try await readers.next() {
                guard let diff else { return nil }
                bytes += diff.raw.utf8.count
                guard bytes <= limit, ContinuousClock.now < deadline else { return nil }
                results[index] = diff
                if next < targets.count {
                    read(next)
                    next += 1
                }
                while ready < results.count, results[ready] != nil {
                    ready += 1
                }
                if let callback = prefix, ready > 0, ready < targets.count,
                   started.duration(to: .now) >= Self.prefixDelay {
                    prefix = nil
                    await callback(Self.zipped(targets[..<ready], results[..<ready]))
                }
            }
            return Self.zipped(targets[...], results[...])
        }
    }

    private static func zipped(_ targets: ArraySlice<DiffTarget>, _ diffs: ArraySlice<TextDiff?>) -> [FileDiff] {
        zip(targets, diffs).compactMap { target, diff in diff.map { FileDiff(target: target, diff: $0) } }
    }

    func lastMessage() async throws -> String {
        try await run(["log", "-1", "--format=%B"]).text.trimmingCharacters(in: .newlines)
    }

    func operationInProgress() -> String? {
        for marker in ["MERGE_HEAD", "rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD", "REVERT_HEAD"]
            where FileManager.default.fileExists(atPath: location.gitDirectory + "/" + marker) {
            return marker
        }
        return nil
    }

    private static var diffOptions: [String] {
        ["--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "--src-prefix=a/", "--dst-prefix=b/",
         "--unified=\(AppConfig.current.diff.contextLines)"]
    }

    private func run(_ arguments: [String]) async throws -> GitOutput {
        try await GitProcess.run(at: location.root, arguments, readOnly: true)
    }
}
