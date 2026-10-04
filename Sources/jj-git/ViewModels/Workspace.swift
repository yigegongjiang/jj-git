import AppKit
import Foundation
import Observation

@MainActor @Observable
final class Workspace {
    var library: RepositoryLibrary
    var config: AppConfig
    var sessions: [String: RepositorySession] = [:]
    var opening: Set<String> = []
    var scanning = false
    var scanProgress = ""
    var error: String?
    @ObservationIgnored private var configMonitor: RepositoryMonitor?
    /// 最近一次读写的文件内容，用于忽略自身写入触发的监听事件。
    @ObservationIgnored private var configData: Data?
    @ObservationIgnored private var stateData: Data?
    @ObservationIgnored private var configValid = true
    @ObservationIgnored private var stateValid = true
    @ObservationIgnored private var fileErrors: [String: String] = [:]
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    var selected: RepositorySession? {
        library.selectedPath.flatMap { sessions[$0] }
    }

    init() {
        library = RepositoryLibrary()
        config = AppConfig()
        do {
            try FileManager.default.createDirectory(at: ConfigStore.directory, withIntermediateDirectories: true)
            let defaultConfig = try ConfigStore.encode(AppConfig())
            if (try? ConfigStore.read(ConfigStore.defaultsURL)) != defaultConfig {
                try ConfigStore.write(defaultConfig, to: ConfigStore.defaultsURL)
            }
            if !FileManager.default.fileExists(atPath: ConfigStore.configURL.path) {
                try ConfigStore.write(defaultConfig, to: ConfigStore.configURL)
            }
        } catch { self.error = "\(ConfigStore.directory.path)\n\(error.localizedDescription)" }
        reloadConfig()
        reloadState(restoring: false)
        configMonitor = RepositoryMonitor(paths: [ConfigStore.directory.path]) { [weak self] in
            Task { @MainActor [weak self] in
                self?.reloadConfig()
                self?.reloadState(restoring: true)
            }
        }
    }

    func restore() async {
        let selected = library.selectedPath
        for path in library.tabs {
            await open(path, select: path == selected)
        }
        // 打开失败的标签保留（可能只是等待系统授权），点击标签时重试；不再需要时手动关闭。
        if self.selected == nil, let path = library.tabs.first(where: { sessions[$0] != nil }) {
            select(path)
        }
    }

    func open(_ path: String, select shouldSelect: Bool = true, groupID: UUID? = nil) async {
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
            if shouldSelect {
                select(location.root)
            }
            save()
        } catch { self.error = "\(path)\n\(error.localizedDescription)" }
    }

    func select(_ path: String) {
        guard sessions[path] != nil else {
            Task { await open(path) }
            return
        }
        if library.selectedPath != path {
            selected?.deactivate()
        }
        library.selectedPath = path
        selected?.activate()
        save()
    }

    func close(_ path: String) {
        guard sessions[path]?.operation == nil else { return }
        sessions[path]?.deactivate()
        sessions.removeValue(forKey: path)
        let index = library.tabs.firstIndex(of: path) ?? 0
        library.tabs.removeAll { $0 == path }
        if library.selectedPath == path {
            library.selectedPath = library.tabs.isEmpty ? nil : library.tabs[min(index, library.tabs.count - 1)]
            selected?.activate()
        }
        save()
    }

    func remove(_ path: String) {
        guard sessions[path]?.operation == nil else { return }
        close(path)
        library.repositories.removeAll { $0.path == path }
        save()
    }

    @discardableResult
    func addGroup(_ name: String) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let group = RepositoryGroup(name: trimmed)
        library.groups.append(group)
        save()
        return group.id
    }

    func renameGroup(_ groupID: UUID, name: String) {
        guard let index = library.groups.firstIndex(where: { $0.id == groupID }),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        library.groups[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    func deleteGroup(_ groupID: UUID) {
        library.groups.removeAll { $0.id == groupID }
        for index in library.repositories.indices where library.repositories[index].groupID == groupID {
            library.repositories[index].groupID = nil
        }
        save()
    }

    func move(_ path: String, to groupID: UUID?) {
        guard let index = library.repositories.firstIndex(where: { $0.path == path }) else { return }
        library.repositories[index].groupID = groupID
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

    func chooseEditor(open path: String? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "选择编辑器"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if configValid {
                    config.editor.path = url.path
                    saveConfig()
                }
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
    /// 用编辑器打开 config.json；文件被删除时先按当前配置重建。
    func openConfig() {
        if !FileManager.default.fileExists(atPath: ConfigStore.configURL.path) {
            saveConfig()
        }
        openEditor(ConfigStore.configURL.path)
    }

    private func saveConfig() {
        do {
            let data = try ConfigStore.encode(config)
            try ConfigStore.write(data, to: ConfigStore.configURL)
            configData = data
            AppConfig.current = config
        } catch { self.error = error.localizedDescription }
    }

    private func save() {
        guard stateValid else { return }
        do {
            let data = try ConfigStore.encode(library)
            guard data != stateData else { return }
            try ConfigStore.write(data, to: ConfigStore.stateURL)
            stateData = data
        } catch { self.error = error.localizedDescription }
    }

    /// 解析失败时沿用上次的有效配置。
    private func reloadConfig() {
        let data: Data?
        do { data = try ConfigStore.read(ConfigStore.configURL) } catch {
            reportFile(ConfigStore.configURL, error)
            return
        }
        guard data != configData else { return }
        configData = data
        do {
            config = try data.map { try ConfigStore.decode($0, defaults: AppConfig()) }?.normalized() ?? AppConfig()
            AppConfig.current = config
            configValid = true
            reportFile(ConfigStore.configURL, nil)
        } catch {
            configValid = false
            reportFile(ConfigStore.configURL, error)
        }
    }

    /// 解析失败时停止写入 state.json，避免界面操作覆盖外部编辑；修正后按文件内容恢复。
    private func reloadState(restoring: Bool) {
        let data: Data?
        do { data = try ConfigStore.read(ConfigStore.stateURL) } catch {
            reportFile(ConfigStore.stateURL, error)
            return
        }
        guard data != stateData else { return }
        stateData = data
        guard let data else {
            stateValid = true
            save()
            return
        }
        do {
            let value = try ConfigStore.decode(data, defaults: RepositoryLibrary())
            stateValid = true
            reportFile(ConfigStore.stateURL, nil)
            restoring ? apply(value) : (library = value)
        } catch {
            stateValid = false
            reportFile(ConfigStore.stateURL, error)
        }
    }

    /// 外部修改了 state.json：关闭被移除的标签，打开新增的标签。
    private func apply(_ value: RepositoryLibrary) {
        let previous = selected
        library = value
        for (path, session) in sessions where !library.tabs.contains(path) {
            if session.operation != nil {
                library.tabs.append(path)
            } else {
                session.deactivate()
                sessions.removeValue(forKey: path)
            }
        }
        if selected !== previous {
            previous?.deactivate()
            selected?.activate()
        }
        Task {
            for path in library.tabs where sessions[path] == nil {
                await open(path, select: path == library.selectedPath)
            }
        }
    }

    private func reportFile(_ url: URL, _ failure: Error?) {
        let message = failure.map { "\(url.path) 无效，修正前沿用上次内容：\n\($0.localizedDescription)" }
        if let previous = fileErrors[url.path], error == previous {
            error = message
        } else if let message {
            error = message
        }
        fileErrors[url.path] = message
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
