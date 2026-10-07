import Foundation

enum RepositoryAction: Sendable {
    case stage([FileChange])
    case unstage([FileChange])
    case partial(FileChange, staged: Bool, diff: TextDiff, lines: Set<Int>)
    case discardLines(FileChange, diff: TextDiff, lines: Set<Int>)
    case discard([FileChange])
    case ignore(String)
    case commit(message: String, amend: Bool)
    case createBranch(String, start: String)
    case checkout(GitReference)
    case renameBranch(String, String)
    case deleteBranch(String, force: Bool)
    case deleteRemoteBranch(GitReference, remote: String)
    case createTag(String, target: String, message: String)
    case deleteTag(String, remotes: [String] = [])
    case pushTag(String, remote: String)
    case addRemote(String, url: String)
    case editRemote(String, url: String, newName: String? = nil)
    case fetch(remote: String)
    case pull
    case push(remote: String, branch: String, lease: String?)
    /// `variables`：`CustomAction.variables` 各名称的当前取值。
    case custom(CustomAction, variables: [String: String])

    enum Transfer {
        case fetch, pull, push
    }

    /// 工具栏 Fetch / Pull / Push 按钮对应的操作。
    var transfer: Transfer? {
        switch self {
        case .fetch: .fetch
        case .pull: .pull
        case .push: .push
        default: nil
        }
    }
}

actor RepositoryCommand {
    nonisolated let query: RepositoryQuery
    private var running = false
    /// 当前操作的进度回调；操作结束即清除。
    private var progress: GitProgressHandler?

    init(location: RepositoryLocation) {
        query = RepositoryQuery(location: location)
    }

    func perform(_ action: RepositoryAction, progress: GitProgressHandler? = nil) async throws -> String {
        guard !running else { throw GitFailure(message: "当前仓库有操作正在执行。") }
        running = true
        self.progress = progress
        defer {
            running = false
            self.progress = nil
        }
        try Task.checkCancellation()
        switch action {
        case .stage, .unstage, .partial, .discardLines, .discard, .ignore:
            return try await editChanges(action)
        case let .commit(message, amend):
            return try await commitChanges(message: message, amend: amend)
        case let .custom(action, variables):
            return try await runCustom(action, variables: variables)
        default:
            return try await manage(action)
        }
    }

    private func editChanges(_ action: RepositoryAction) async throws -> String {
        switch action {
        case let .stage(files):
            return try await run(["add", "--"] + paths(files))
        case let .unstage(files):
            if try await query.status().unborn {
                return try await run(["rm", "--cached", "-r", "-f", "--"] + paths(files))
            }
            return try await run(["restore", "--staged", "--"] + paths(files))
        case let .partial(file, staged, diff, lines):
            return try await applyLines(file, diff: diff, lines: lines, staged: staged, discard: false)
        case let .discardLines(file, diff, lines):
            return try await applyLines(file, diff: diff, lines: lines, staged: false, discard: true)
        case let .discard(files):
            return try await discard(files)
        case let .ignore(path):
            return try ignore(path)
        default:
            throw GitFailure(message: "不支持的 Git 操作。")
        }
    }

    /// 暂存：正向补丁作用于暂存区；取消暂存：已暂存差异反向作用于暂存区；放弃：未暂存差异反向作用于工作区。
    private func applyLines(_ file: FileChange, diff: TextDiff, lines: Set<Int>, staged: Bool,
                            discard: Bool) async throws -> String {
        if discard, file.untracked {
            throw GitFailure(message: "未跟踪文件请整个放弃。")
        }
        let current = try await query.diff(file, staged: staged)
        guard current.raw == diff.raw else { throw GitFailure(message: "文件已变化，请刷新差异后重新选择。") }
        let patch = try diff.patch(selecting: lines, reverse: staged || discard)
        return try await run(["apply"] + (discard ? [] : ["--cached"]) + ["--whitespace=nowarn", "-"], input: patch)
    }

    /// 已跟踪文件恢复为暂存区内容；未跟踪文件移至废纸篓，可找回。
    private func discard(_ files: [FileChange]) async throws -> String {
        guard !files.isEmpty else { throw GitFailure(message: "请先选择文件。") }
        guard !files.contains(where: { $0.conflicted || $0.submodule }) else {
            throw GitFailure(message: "冲突文件或子模块请在编辑器/终端处理。")
        }
        let tracked = files.filter { !$0.untracked }.map(\.path)
        if !tracked.isEmpty {
            _ = try await run(["restore", "--worktree", "--"] + tracked)
        }
        let root = URL(fileURLWithPath: query.location.root)
        for file in files where file.untracked {
            try FileManager.default.trashItem(at: root.appendingPathComponent(file.path), resultingItemURL: nil)
        }
        return "已放弃 \(files.count) 个文件的变更"
    }

    private func commitChanges(message: String, amend: Bool) async throws -> String {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitFailure(message: "提交信息不能为空。")
        }
        let status = try await query.status()
        guard !status.conflicts else { throw GitFailure(message: "请先解决并暂存全部冲突。") }
        if let operation = query.operationInProgress() {
            throw GitFailure(message: "仓库正在进行 \(operation)，请在终端完成或中止后再提交。")
        }
        return try await run(["commit"] + (amend ? ["--amend"] : []) + ["--file=-"],
                             input: Data(message.utf8), timeout: Self.commitTimeout)
    }

    private func manage(_ action: RepositoryAction) async throws -> String {
        switch action {
        case let .createBranch(name, start):
            try await validateBranch(name)
            try validateRevision(start)
            return try await run(["switch", "-c", name, start, "--"])
        case let .checkout(reference):
            if reference.remote {
                return try await run(["switch", "--track", reference.name, "--"])
            }
            return try await run(["switch", reference.name, "--"])
        case let .renameBranch(old, new):
            try await validateBranch(new)
            return try await run(["branch", "-m", "--", old, new])
        case let .deleteBranch(name, force):
            return try await run(["branch", force ? "-D" : "-d", "--", name])
        case let .deleteRemoteBranch(reference, remote):
            guard reference.remote, reference.name.hasPrefix(remote + "/") else {
                throw GitFailure(message: "远端分支与所选 remote 不匹配。")
            }
            let branch = String(reference.name.dropFirst(remote.count + 1))
            return try await deleteRemoteReference("refs/heads/" + branch, remote: remote, expected: reference.target)
        default:
            return try await synchronize(action)
        }
    }

    private func synchronize(_ action: RepositoryAction) async throws -> String {
        switch action {
        case let .createTag(name, target, message):
            try validateName(name)
            _ = try await run(["check-ref-format", "refs/tags/" + name])
            try validateRevision(target)
            return try await run(["tag", "-a", "-F", "-", "--", name, target],
                                 input: Data((message.isEmpty ? name : message).utf8))
        case let .deleteTag(name, remotes):
            for remote in remotes { _ = try await deleteRemoteReference("refs/tags/" + name, remote: remote) }
            return try await run(["tag", "-d", "--", name])
        case let .pushTag(name, remote):
            try validateName(remote)
            return try await run(["push", "--progress", "--", remote, "refs/tags/\(name):refs/tags/\(name)"],
                                 timeout: Self.networkTimeout)
        case let .addRemote(name, url):
            try validateRemote(name, url: url)
            return try await run(["remote", "add", "--", name, url])
        case let .editRemote(name, url, newName):
            return try await editRemote(name, url: url, newName: newName ?? name)
        case let .fetch(remote):
            try validateName(remote)
            return try await run(["fetch", "--progress", "--", remote], timeout: Self.networkTimeout)
        case .pull:
            let pull = AppConfig.current.pull
            return try await run(["pull", "--progress", pull.rebase ? "--rebase" : "--no-rebase"]
                + (pull.autostash ? ["--autostash"] : []), timeout: Self.networkTimeout)
        case let .push(remote, branch, lease):
            return try await push(remote: remote, branch: branch, lease: lease)
        default:
            throw GitFailure(message: "不支持的 Git 操作。")
        }
    }

    private func editRemote(_ oldName: String, url: String, newName: String) async throws -> String {
        try validateRemote(newName, url: url)
        if oldName != newName {
            _ = try await run(["remote", "rename", "--", oldName, newName])
        }
        do {
            return try await run(["remote", "set-url", "--", newName, url])
        } catch {
            throw GitFailure(message: "远程当前名称：\(newName)。更新 URL 失败：\n\(error.localizedDescription)")
        }
    }

    private func deleteRemoteReference(_ reference: String, remote: String,
                                       expected: String? = nil) async throws -> String {
        try validateName(remote)
        let result = try await GitProcess.run(at: query.location.root,
                                              ["ls-remote", "--exit-code", "--refs", "--", remote, reference],
                                              accepted: [0, 2], timeout: Self.networkTimeout, progress: progress)
        if result.status == 2 {
            if reference.hasPrefix("refs/heads/") {
                return try await run(["branch", "-dr", "--", remote + "/" + reference.dropFirst(11)])
            }
            return "远端标签已不存在"
        }
        let remoteHash = String(result.text.prefix(while: { $0 != "\t" }))
        let lease = expected ?? remoteHash
        return try await run(["push", "--progress", "--force-with-lease=\(reference):\(lease)", "--",
                              remote, ":" + reference], timeout: Self.networkTimeout)
    }

    private func push(remote: String, branch: String, lease: String?) async throws -> String {
        try validateName(remote)
        try await validateBranch(branch)
        var arguments = ["push", "--progress", "--set-upstream"]
        if let lease {
            guard lease.allSatisfy(\.isHexDigit), [40, 64].contains(lease.count) else {
                throw GitFailure(message: "缺少远端分支的已知提交，先 Fetch 再进行强制推送。")
            }
            arguments.append("--force-with-lease=refs/heads/\(branch):\(lease)")
        }
        return try await run(arguments + ["--", remote, "HEAD:refs/heads/\(branch)"], timeout: Self.networkTimeout)
    }

    private func paths(_ files: [FileChange]) throws -> [String] {
        guard !files.isEmpty else { throw GitFailure(message: "请先选择文件。") }
        return Array(Set(files.flatMap(\.paths))).sorted()
    }

    private func validateName(_ value: String) throws {
        guard !value.isEmpty, !value.hasPrefix("-"), !value.contains("\0"), !value.contains("\n") else {
            throw GitFailure(message: "名称不能为空或以 - 开头。")
        }
    }

    private func validateRevision(_ value: String) throws {
        try validateName(value)
        guard !value.contains(":") else { throw GitFailure(message: "请输入分支名或提交 SHA。") }
    }

    private func validateBranch(_ name: String) async throws {
        try validateName(name)
        _ = try await run(["check-ref-format", "--branch", name])
    }

    private func validateRemote(_ name: String, url: String) throws {
        try validateName(name)
        guard !url.isEmpty, !url.hasPrefix("-"), !url.contains("\n"), !url.contains("\0") else {
            throw GitFailure(message: "请输入有效的远程 URL。")
        }
    }

    private func ignore(_ path: String) throws -> String {
        guard !path.contains("\n"), !path.contains("\r") else {
            throw GitFailure(message: "含换行的文件名无法写入 .gitignore。")
        }
        var escaped = ""
        for character in path {
            if ["\\", "*", "?", "[", "]", " ", "#", "!"].contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        let url = URL(fileURLWithPath: query.location.root).appendingPathComponent(".gitignore")
        let existing = try FileManager.default.fileExists(atPath: url.path)
            ? String(contentsOf: url, encoding: .utf8) : ""
        let rule = "/" + escaped
        if existing.components(separatedBy: "\n").contains(rule) {
            return "忽略规则已存在"
        }
        let text = existing + (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n") + rule + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        return "已加入 .gitignore"
    }

    private static var commitTimeout: TimeInterval {
        TimeInterval(AppConfig.current.git.commitTimeoutSeconds)
    }

    private static var networkTimeout: TimeInterval {
        TimeInterval(AppConfig.current.git.networkTimeoutSeconds)
    }

    private func run(_ arguments: [String], input: Data? = nil, timeout: TimeInterval? = nil) async throws -> String {
        let output = try await GitProcess.run(at: query.location.root, arguments, input: input, timeout: timeout,
                                              progress: progress)
        return [output.text, output.error].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

extension RepositoryCommand {
    /// 自定义操作：不等待的只负责启动；等待的接受任意退出码，失败提示带上操作名与退出码。
    private func runCustom(_ action: CustomAction, variables: [String: String]) async throws -> String {
        let executable = try action.resolvedExecutable(searchPath: GitProcess.searchPath)
        let arguments = action.expandedArguments(variables)
        let command = ProcessCommand(
            executable: executable, arguments: arguments, logged: [executable] + arguments,
            environment: Dictionary(uniqueKeysWithValues: variables.map { ("JJ_GIT_" + $0.key, $0.value) }),
            name: "「\(action.name)」", timeoutHint: "可调整 config.jsonc customActions 的 timeoutSeconds。",
            limitHint: "请减少命令输出。"
        )
        guard action.waitForExit else {
            try GitProcess.launch(command, at: query.location.root)
            return ""
        }
        let output = try await GitProcess.execute(command, at: query.location.root, accepted: Set(0...255),
                                                  timeout: TimeInterval(action.timeoutSeconds), progress: progress)
        let text = [output.text, output.error].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        guard output.status == 0 else {
            throw GitFailure(message: "「\(action.name)」退出码 \(output.status)" + (text.isEmpty ? "" : "\n" + text))
        }
        return text
    }
}
