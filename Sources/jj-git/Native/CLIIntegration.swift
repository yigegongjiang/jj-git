import AppKit
import Darwin

@MainActor
final class RepositoryOpenHandler: NSObject, NSApplicationDelegate {
    private var workspace: Workspace?
    private var pending: [URL] = []
    private var openingTask: Task<Void, Never>?

    func application(_: NSApplication, open urls: [URL]) {
        pending.append(contentsOf: urls.filter(\.isFileURL))
        drain()
    }

    func connect(_ workspace: Workspace) {
        guard self.workspace == nil else { return }
        self.workspace = workspace
        openingTask = Task {
            await workspace.restore()
            for path in ProcessInfo.processInfo.arguments.dropFirst() where path.hasPrefix("/") {
                await workspace.open(path)
            }
            openingTask = nil
            drain()
        }
    }

    private func drain() {
        guard let workspace, openingTask == nil, !pending.isEmpty else { return }
        openingTask = Task {
            defer { openingTask = nil }
            while !pending.isEmpty {
                let url = pending.removeFirst()
                await workspace.open(url.path)
            }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.identifier?.rawValue == "main" }?.makeKeyAndOrderFront(nil)
        }
    }
}

extension Workspace {
    func installCLI() {
        let manager = FileManager.default
        let destination = manager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/jj-git")
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/jj-git-cli")
        do {
            guard manager.isExecutableFile(atPath: executable.path) else {
                throw CLIInstallError("找不到 CLI：\(executable.path)")
            }
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let attributes = try? manager.attributesOfItem(atPath: destination.path) {
                guard attributes[.type] as? FileAttributeType == .typeSymbolicLink,
                      try manager.destinationOfSymbolicLink(atPath: destination.path)
                      .hasSuffix(".app/Contents/Resources/jj-git-cli") else {
                    throw CLIInstallError("安装路径已被占用：\(destination.path)")
                }
            }
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent(".jj-git-\(UUID().uuidString)")
            try manager.createSymbolicLink(at: temporary, withDestinationURL: executable)
            defer { try? manager.removeItem(at: temporary) }
            guard rename(temporary.path, destination.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let alert = NSAlert()
            alert.messageText = "已安装 jj-git 命令"
            alert.informativeText = "\(destination.path)\n\njj-git [path] 打开仓库；不传 path 时使用当前目录。"
            let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            if !paths.contains(Substring(destination.deletingLastPathComponent().path)) {
                alert.informativeText += "\n\n请在 shell 配置中加入：\nexport PATH=\"$HOME/.local/bin:$PATH\""
            }
            alert.runModal()
        } catch { self.error = error.localizedDescription }
    }
}

private struct CLIInstallError: LocalizedError {
    let message: String
    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
