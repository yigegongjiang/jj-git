import Foundation

extension RepositorySession {
    /// 远端分支对应的本地分支：优先跟踪它的分支，其次同名分支。
    func localBranch(for remoteBranch: GitReference) -> GitReference? {
        let locals = references.filter { !$0.remote && !$0.tag }
        if let tracking = locals.first(where: { $0.upstream == remoteBranch.name }) {
            return tracking
        }
        guard let remote = remotes.filter({ remoteBranch.name.hasPrefix($0.name + "/") })
            .max(by: { $0.name.count < $1.name.count }) else { return nil }
        let name = String(remoteBranch.name.dropFirst(remote.name.count + 1))
        return locals.first { $0.name == name }
    }

    func checkout(_ branch: GitReference) {
        let target = branch.remote ? localBranch(for: branch) ?? branch : branch
        guard !target.current else { return }
        guard target.checkedOutPath.isEmpty else {
            error = "\(target.name) 已在其他工作树检出：\(target.checkedOutPath)"
            return
        }
        perform(.checkout(target), title: "检出 \(target.name)")
    }

    /// 0.4s / 12s / 2m05s
    nonisolated static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return seconds < 10 ? String(format: "%.1fs", seconds)
            : total < 60 ? "\(total)s" : String(format: "%dm%02ds", total / 60, total % 60)
    }

    var displayedError: String? {
        error ?? refreshError ?? readError ?? fetchError
    }

    func dismissErrors() {
        error = nil
        refreshError = nil
        readError = nil
        fetchError = nil
    }

    func clearFetchError(remote: String) {
        guard fetchFailureRemote == remote else { return }
        fetchFailure = nil
        fetchFailureRemote = nil
        fetchError = nil
    }

    func reportFetchFailure(remote: String, failure: Error, automatic: Bool) {
        let message = failure.localizedDescription
        guard !automatic || message != fetchFailure || fetchFailureRemote != remote else { return }
        fetchFailure = message
        fetchFailureRemote = remote
        fetchError = (automatic ? "自动 " : "") + "Fetch \(remote) 失败：\(message)"
    }

    /// 上游所在远程，其次 origin，最后第一个远程。
    var defaultRemote: String {
        remotes.first { status.upstream.hasPrefix($0.name + "/") }?.name
            ?? remotes.first { $0.name == "origin" }?.name ?? remotes.first?.name ?? ""
    }

    func fetch() {
        let remote = defaultRemote
        guard !remote.isEmpty else { return }
        perform(.fetch(remote: remote), title: "Fetch \(remote)")
    }

    /// 直接推送当前分支到上游（无上游时推送到默认远程的同名分支并建立跟踪）。
    func pushToUpstream() {
        let destination = PushDestination(session: self)
        guard !destination.remote.isEmpty, !status.detached, !status.unborn else { return }
        perform(.push(remote: destination.remote, branch: destination.branch, lease: nil), title: "Push")
    }

    /// 静默 Fetch：不占用操作状态栏；同一错误只提示一次，成功后清除。
    /// 切换标签 / 手动操作不取消进行中的 Fetch：取消即 SIGKILL，可能残留 ref `.lock`。
    func autoFetch() async {
        let remote = defaultRemote
        guard active, operation == nil, autoFetchRun == nil, !remote.isEmpty else { return }
        let run = Task { [weak self, command] in
            do {
                _ = try await command.perform(.fetch(remote: remote))
                guard let self else { return }
                clearFetchError(remote: remote)
                if active {
                    refresh()
                }
            } catch is CancellationError {
                return
            } catch {
                self?.reportFetchFailure(remote: remote, failure: error, automatic: true)
            }
        }
        autoFetchRun = run
        await run.value
        if autoFetchRun == run {
            autoFetchRun = nil
        }
    }

    /// 自定义操作：等待退出的占用操作状态栏（可取消、显示输出），否则启动即完成。
    func run(_ action: CustomAction) {
        let values = [
            "REPO": location.root,
            "BRANCH": status.detached ? "HEAD" : status.branch,
            "SHA": status.unborn ? "" : status.head,
            "REMOTE": defaultRemote
        ]
        perform(.custom(action, variables: values), title: action.waitForExit ? action.name : "启动「\(action.name)」")
    }
}
