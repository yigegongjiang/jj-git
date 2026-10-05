import AppKit
import Observation

@MainActor @Observable
final class Workspace {
    var library: RepositoryLibrary
    private(set) var config: AppConfig
    var sessions: [String: RepositorySession] = [:]
    var opening: Set<String> = []
    var showingKeyboardShortcuts = false
    var scanning = false
    var scanProgress = ""
    var error: String?
    var missingRepositories: [String] = []
    var repositoryPicker: RepositoryPicker?
    @ObservationIgnored var repositoryCheckTask: Task<Void, Never>?
    /// 避免重复写入相同状态。
    @ObservationIgnored private var stateData: Data?
    @ObservationIgnored private var stateValid = true
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var idleUnloads: [String: Task<Void, Never>] = [:]

    var selected: RepositorySession? {
        library.selectedPath.flatMap { sessions[$0] }
    }

    deinit {
        for task in idleUnloads.values {
            task.cancel()
        }
    }

    private func scheduleIdleUnload(_ path: String) {
        idleUnloads[path]?.cancel()
        let seconds = config.tabs.idleUnloadSeconds
        idleUnloads[path] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            // 写操作不中断；完成后的刷新随 session 一起取消。
            await self?.sessions[path]?.waitForOperation()
            guard !Task.isCancelled, let self, library.selectedPath != path else { return }
            sessions[path]?.dispose()
            sessions.removeValue(forKey: path)
            idleUnloads.removeValue(forKey: path)
        }
    }

    init() {
        library = RepositoryLibrary()
        config = AppConfig()
        do {
            try FileManager.default.createDirectory(at: GitCommandLog.directory, withIntermediateDirectories: true)
            let defaultConfig = try ConfigStore.encodeConfig(AppConfig())
            if (try? ConfigStore.read(ConfigStore.defaultsURL)) != defaultConfig {
                try ConfigStore.write(defaultConfig, to: ConfigStore.defaultsURL)
            }
            if !FileManager.default.fileExists(atPath: ConfigStore.configURL.path) {
                try ConfigStore.write(defaultConfig, to: ConfigStore.configURL)
            }
        } catch { self.error = "\(ConfigStore.directory.path)\n\(error.localizedDescription)" }
        loadConfig()
        loadState()
    }

    func open(_ path: String, groupID: UUID? = nil) async {
        guard !opening.contains(path) else { return }
        opening.insert(path)
        defer { opening.remove(path) }
        do {
            let location = try await RepositoryQuery.locate(path)
            if !library.repositories.contains(where: { $0.path == location.root }) {
                library.repositories.append(SavedRepository(path: location.root, groupID: groupID))
            }
            if sessions[location.root] == nil {
                sessions[location.root] = RepositorySession(location: location)
            }
            if !library.tabs.contains(location.root) {
                library.tabs.append(location.root)
            }
            select(location.root)
            missingRepositories.removeAll { $0 == path || $0 == location.root }
            save()
        } catch { reportOpenFailure(error, path: path) }
    }

    func select(_ path: String) {
        guard sessions[path] != nil else {
            Task { await open(path) }
            return
        }
        if library.selectedPath != path {
            selected?.deactivate()
            if let previous = library.selectedPath {
                scheduleIdleUnload(previous)
            }
            // 仅切换时计入使用：启动恢复 / 重复点击当前标签不计。
            if let index = library.repositories.firstIndex(where: { $0.path == path }) {
                library.repositories[index].recordUse(at: Date().timeIntervalSince1970)
            }
        }
        idleUnloads.removeValue(forKey: path)?.cancel()
        library.selectedPath = path
        selected?.activate()
        save()
    }

    func close(_ path: String) {
        guard sessions[path]?.operation == nil else { return }
        idleUnloads.removeValue(forKey: path)?.cancel()
        sessions[path]?.dispose()
        sessions.removeValue(forKey: path)
        let index = library.tabs.firstIndex(of: path) ?? 0
        library.tabs.removeAll { $0 == path }
        if library.selectedPath == path {
            library.selectedPath = nil
            if !library.tabs.isEmpty {
                select(library.tabs[min(index, library.tabs.count - 1)])
            }
        }
        save()
    }

    /// 批量关闭；当前标签在其中时先切到 `anchor`，避免逐个关闭时依次激活相邻标签。
    func close(_ paths: [String], keeping anchor: String) {
        let closable = paths.filter { $0 != anchor && sessions[$0]?.operation == nil }
        if let selected = library.selectedPath, closable.contains(selected) {
            select(anchor)
        }
        for path in closable {
            close(path)
        }
    }

    func remove(_ path: String) {
        guard sessions[path]?.operation == nil else { return }
        close(path)
        library.repositories.removeAll { $0.path == path }
        missingRepositories.removeAll { $0 == path }
        save()
    }

    func scan(_ directory: String) {
        guard !scanning else { return }
        scanning = true
        scanProgress = "正在扫描…"
        scanTask = Task { [weak self] in
            guard let self else { return }
            defer { scanning = false }
            do {
                let result = try await RepositoryScanner.scan(directory)
                var groupID: UUID?
                var imported = 0
                var failures = result.inaccessible
                for (index, path) in result.paths.enumerated() {
                    try Task.checkCancellation()
                    scanProgress = "识别仓库 \(index + 1)/\(result.paths.count)"
                    do {
                        let location = try await RepositoryQuery.locate(path)
                        if !library.repositories.contains(where: { $0.path == location.root }) {
                            if groupID == nil {
                                groupID = addGroup(URL(fileURLWithPath: directory).lastPathComponent)
                            }
                            library.repositories.append(SavedRepository(path: location.root, groupID: groupID))
                            imported += 1
                        }
                    } catch { failures.append(path) }
                }
                scanProgress = "已导入 \(imported) 个仓库"
                if !failures.isEmpty {
                    error = "未能读取 \(failures.count) 个目录：\n" + failures.prefix(10).joined(separator: "\n")
                }
                save()
            } catch is CancellationError {
                scanProgress = "扫描已取消"
                save()
            } catch { self.error = error.localizedDescription }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    func chooseRepository(scan: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = !scan
        panel.prompt = scan ? "扫描并导入" : "打开仓库"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for url in panel.urls {
                    if scan {
                        self.scan(url.path)
                    } else {
                        await open(url.path)
                    }
                }
            }
        }
    }

    func openTerminal(_ path: String) {
        let application = config.terminal.bundleIDs.lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
        guard let application else {
            error = "找不到终端 App"
            return
        }
        launch(path, with: application)
    }

    func openEditor(_ path: String) {
        if !config.editor.path.isEmpty, FileManager.default.fileExists(atPath: config.editor.path) {
            launch(path, with: URL(fileURLWithPath: config.editor.path))
        } else if let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: config.editor.bundleID) {
            launch(path, with: application)
        } else {
            chooseEditor(open: path)
        }
    }

    /// Finder 直接选中文件；其他文件管理器打开该文件路径（QSpace 等定位到所在文件夹）。
    /// 文件已删除时退到最近的已存在上级目录。
    func revealInFileManager(_ path: String) {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        let bundleID = config.fileManager.bundleID
        if bundleID != "com.apple.finder",
           let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            launch(url.path, with: application)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func chooseEditor(open path: String? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "选择编辑器"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let data = try ConfigStore.read(ConfigStore.configURL)
                    var saved = try ConfigStore.readConfig(data)
                    saved.editor.path = url.path
                    try ConfigStore.saveConfig(saved, original: data)
                } catch { self.error = error.localizedDescription }
                if let path {
                    launch(path, with: url)
                }
            }
        }
    }

    private func launch(_ path: String, with application: URL) {
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: application,
                                configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            if let error {
                Task { @MainActor [weak self] in self?.error = error.localizedDescription }
            }
        }
    }
}

// MARK: - ~/.config/jj-git 文件

extension Workspace {
    /// 外部修改配置后，重启应用生效。
    func openConfig() {
        do {
            if !FileManager.default.fileExists(atPath: ConfigStore.configURL.path) {
                try ConfigStore.write(ConfigStore.encodeConfig(config), to: ConfigStore.configURL)
            }
            openEditor(ConfigStore.configURL.path)
        } catch { self.error = error.localizedDescription }
    }

    var canRestart: Bool {
        !scanning && opening.isEmpty && sessions.values.allSatisfy { $0.operation == nil && $0.message.isEmpty }
    }

    /// 仅重启当前产物；等待旧进程退出，避免两个实例同时写入状态。
    func restart() {
        guard canRestart else { return }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", """
        for attempt in 1 2 3 4 5 6 7 8 9 10; do
            if ! kill -0 "$1" 2>/dev/null; then
                exec /usr/bin/open -n --env "JJGIT_DEBUG_TAG=$3" "$2"
            fi
            sleep 1
        done
        """, "jj-git-restart", String(ProcessInfo.processInfo.processIdentifier),
        Bundle.main.bundleURL.path, DebugInstance.tag ?? ""]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
            NSApplication.shared.terminate(nil)
        } catch { self.error = error.localizedDescription }
    }

    func save() {
        guard stateValid else { return }
        do {
            let data = try ConfigStore.encode(library)
            guard data != stateData else { return }
            try ConfigStore.write(data, to: ConfigStore.stateURL)
            stateData = data
        } catch { self.error = error.localizedDescription }
    }

    private func loadConfig() {
        do {
            let data = try ConfigStore.read(ConfigStore.configURL)
            config = try data.map {
                try ConfigStore.decode($0, defaults: AppConfig(), comments: true)
            }?.normalized() ?? AppConfig()
        } catch { self.error = "\(ConfigStore.configURL.path)：\n\(error.localizedDescription)" }
        AppConfig.current = config
        if let warning = Typography.shared.apply(config.appearance) {
            error = warning
        }
    }

    private func loadState() {
        do {
            if let data = try ConfigStore.read(ConfigStore.stateURL) {
                library = try ConfigStore.decode(data, defaults: RepositoryLibrary())
                stateData = data
            }
        } catch {
            stateValid = false
            self.error = "\(ConfigStore.stateURL.path)：\n\(error.localizedDescription)"
        }
    }
}

/// Window / sidebar layout state persisted in state.json.
extension Workspace {
    func setSplit(_ name: String, size: Double) {
        guard library.splits[name] != size else { return }
        library.splits[name] = size
        save()
    }

    func setWindowFrame(_ frame: WindowFrame) {
        guard library.window != frame else { return }
        library.window = frame
        save()
    }

    func toggleSidebar() {
        library.sidebarHidden.toggle()
        save()
    }

    func setHistoryColumn(_ keyPath: WritableKeyPath<AppConfig.History, Bool>, visible: Bool) {
        do {
            let data = try ConfigStore.read(ConfigStore.configURL)
            var saved = try ConfigStore.readConfig(data)
            saved.history[keyPath: keyPath] = visible
            try ConfigStore.saveConfig(saved, original: data)
            config.history[keyPath: keyPath] = visible
            AppConfig.current = config
        } catch { self.error = "\(ConfigStore.configURL.path)：\n\(error.localizedDescription)" }
    }

    func toggleSection(_ key: String) {
        let sections = library.collapsedSections
        library.collapsedSections = sections.contains(key) ? sections.filter { $0 != key } : sections + [key]
        save()
    }

    func toggleGroup(_ groupID: UUID) {
        guard let index = library.groups.firstIndex(where: { $0.id == groupID }) else { return }
        library.groups[index].collapsed.toggle()
        save()
    }
}
