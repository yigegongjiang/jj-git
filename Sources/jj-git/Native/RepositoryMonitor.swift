import CoreServices
import Foundation

final class RepositoryMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "jj-git.filesystem", qos: .utility)
    private var stream: FSEventStreamRef?
    private let contextBox: MonitorCallback
    /// 事件可作为变化的完整来源：监听已启动且全部路径位于本地卷。网络卷上其他机器的修改不保证产生事件
    /// （Git 的 fsmonitor 同样默认不用于远程卷），此时调用方应定期全量核对。
    let reliable: Bool

    /// 回调参数为本批变化的路径（已排除 `ignoring`）与是否需要全量重扫（事件丢失 / 合并 / 根目录变化），
    /// 在后台队列调用。
    convenience init(location: RepositoryLocation, callback: @escaping @Sendable ([String], Bool) -> Void) {
        let paths = Set([location.root, location.gitDirectory, location.commonDirectory])
        // 命令记录可能位于被打开的仓库内（Debug 产物在工程目录下），写入不得触发刷新。
        self.init(paths: Array(paths), ignoring: GitCommandLog.directory, callback: callback)
    }

    /// `ignoring` 下的变化不触发回调（如监听目录内持续写入的日志）。
    init(paths: [String], ignoring: URL? = nil, callback: @escaping @Sendable ([String], Bool) -> Void) {
        // FSEvents 报告真实路径，前缀需同样解析符号链接。
        let ignored = ignoring.map { url in
            realpath(url.path, nil).map { pointer in
                defer { free(pointer) }
                return String(cString: pointer)
            } ?? url.path
        }
        contextBox = MonitorCallback(ignored: ignored, callback)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(contextBox).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        // 合并 1 秒内的事件：仓库位于频繁写入的目录（如主目录）时，每批事件都刷新会持续占用 CPU。
        stream = FSEventStreamCreate(
            nil, { _, info, count, eventPaths, eventFlags, _ in
                guard let info else { return }
                let box = Unmanaged<MonitorCallback>.fromOpaque(info).takeUnretainedValue()
                let pointers = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
                let paths = (0..<count).map { String(cString: pointers[$0]) }
                    .filter { path in box.ignored.map { !path.hasPrefix($0) } ?? true }
                let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
                    | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                    | kFSEventStreamEventFlagRootChanged)
                let rescan = (0..<count).contains { eventFlags[$0] & rescanFlags != 0 }
                guard rescan || !paths.isEmpty else { return }
                box.callback(paths, rescan)
            }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            if !FSEventStreamStart(stream) {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
        }
        reliable = stream != nil && paths.allSatisfy(Self.isLocal)
    }

    private static func isLocal(_ path: String) -> Bool {
        var info = statfs()
        return statfs(path, &info) == 0 && info.f_flags & UInt32(MNT_LOCAL) != 0
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            queue.sync {
            }
            FSEventStreamRelease(stream)
        }
    }
}

private final class MonitorCallback: Sendable {
    let ignored: String?
    let callback: @Sendable ([String], Bool) -> Void
    init(ignored: String? = nil, _ callback: @escaping @Sendable ([String], Bool) -> Void) {
        self.ignored = ignored
        self.callback = callback
    }
}
