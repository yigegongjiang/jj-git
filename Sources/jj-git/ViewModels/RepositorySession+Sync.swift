import Foundation

extension RepositorySession {
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
        let remote = defaultRemote
        guard !remote.isEmpty, !status.detached, !status.unborn else { return }
        let branch = status.upstream.hasPrefix(remote + "/")
            ? String(status.upstream.dropFirst(remote.count + 1)) : status.branch
        perform(.push(remote: remote, branch: branch, lease: nil), title: "Push")
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
                autoFetchFailure = nil
                if active {
                    refresh()
                }
            } catch is CancellationError {
                return
            } catch {
                let message = error.localizedDescription
                guard let self, message != autoFetchFailure else { return }
                autoFetchFailure = message
                self.error = "自动 Fetch \(remote) 失败：\(message)"
            }
        }
        autoFetchRun = run
        await run.value
        if autoFetchRun == run {
            autoFetchRun = nil
        }
    }
}
