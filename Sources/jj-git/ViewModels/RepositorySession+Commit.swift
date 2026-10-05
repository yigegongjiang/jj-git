import Foundation

extension RepositorySession {
    /// 为空或仍是默认内容：可被 Amend 的上次提交信息替换，也不阻止重启。
    var messageUntouched: Bool {
        message.isEmpty || message == AppConfig.current.commit.defaultMessage
    }

    func setAmend(_ enabled: Bool) {
        amend = enabled
        guard enabled, messageUntouched else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let previous = try await command.query.lastMessage()
                if amend, messageUntouched {
                    message = previous
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}
