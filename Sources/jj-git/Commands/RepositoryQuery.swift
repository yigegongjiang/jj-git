import Foundation

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

    /// 只取分支 / 远端 / 标签 / HEAD，排除 stash、notes 等内部引用；未出生的 HEAD 不能作为修订参数。
    func commits(limit: Int, includeHead: Bool) async throws -> [GitCommit] {
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
        return CommitDetail(message: values.0.text, files: changes)
    }

    func commitDiff(_ commit: GitCommit, path: String) async throws -> TextDiff {
        let arguments = ["show", "--format=", "--first-parent", "--root"] + Self.diffOptions + [commit.hash, "--", path]
        return try await TextDiff(run(arguments).checkedText())
    }

    /// 轮询刷新时内容通常未变：原文相同直接复用 previous，跳过大差异的重新解析。
    func diff(_ file: FileChange, staged: Bool, reusing previous: TextDiff? = nil) async throws -> TextDiff {
        var arguments = ["diff"] + Self.diffOptions
        if file.untracked {
            arguments += ["--no-index", "--", "/dev/null", file.path]
        } else {
            if staged {
                arguments.append("--cached")
            }
            arguments += ["--", file.path]
        }
        let output = try await GitProcess.run(at: location.root, arguments, accepted: file.untracked ? [0, 1] : [0])
        let text = try output.checkedText()
        if let previous, previous.raw.utf8.elementsEqual(text.utf8) {
            return previous
        }
        return TextDiff(text)
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
        try await GitProcess.run(at: location.root, arguments)
    }
}
