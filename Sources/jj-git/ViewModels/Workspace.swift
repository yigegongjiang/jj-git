import AppKit
import Foundation
import Observation

@MainActor @Observable
final class Workspace {
    var library: RepositoryLibrary
    var sessions: [String: RepositorySession] = [:]
    var opening: Set<String> = []
    var scanning = false
    var scanProgress = ""
    var error: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    var selected: RepositorySession? {
        library.selectedPath.flatMap { sessions[$0] }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "repository-library") {
            do {
                library = try JSONDecoder().decode(RepositoryLibrary.self, from: data)
            } catch {
                library = RepositoryLibrary()
                defaults.set(data, forKey: "repository-library-unreadable")
                self.error = "仓库列表无法读取，原始配置已保留。\n\(error.localizedDescription)"
            }
        } else {
            library = RepositoryLibrary()
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

    func toggleSidebar() {
        library.sidebarHidden = !(library.sidebarHidden ?? false)
        save()
    }

    func toggleGroup(_ groupID: UUID) {
        guard let index = library.groups.firstIndex(where: { $0.id == groupID }) else { return }
        library.groups[index].collapsed = !(library.groups[index].collapsed ?? false)
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

    /// 优先 iTerm，未安装时使用系统终端。
    func openTerminal(_ path: String) {
        let application = ["com.googlecode.iterm2", "com.apple.Terminal"].lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
        guard let application else {
            error = "找不到终端 App"
            return
        }
        launch(path, with: application)
    }

    func openEditor(_ path: String) {
        if let editorPath = library.editorPath, FileManager.default.fileExists(atPath: editorPath) {
            launch(path, with: URL(fileURLWithPath: editorPath))
        } else if let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") {
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
                self?.library.editorPath = url.path
                self?.save()
                if let path {
                    self?.launch(path, with: url)
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

    private func save() {
        do {
            let data = try JSONEncoder().encode(library)
            defaults.set(data, forKey: "repository-library")
        } catch { self.error = error.localizedDescription }
    }
}
