import CoreServices
import Foundation

final class RepositoryMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "jj-git.filesystem", qos: .utility)
    private var stream: FSEventStreamRef?
    private let contextBox: MonitorCallback

    convenience init(location: RepositoryLocation, callback: @escaping @Sendable () -> Void) {
        let paths = Set([location.root, location.gitDirectory, location.commonDirectory])
        self.init(paths: Array(paths), callback: callback)
    }

    /// `ignoring` 下的变化不触发回调（如监听目录内持续写入的日志）。
    init(paths: [String], ignoring: URL? = nil, callback: @escaping @Sendable () -> Void) {
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
        stream = FSEventStreamCreate(
            nil, { _, info, count, eventPaths, _, _ in
                guard let info else { return }
                let box = Unmanaged<MonitorCallback>.fromOpaque(info).takeUnretainedValue()
                if let ignored = box.ignored {
                    let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
                    guard (0..<count).contains(where: { !String(cString: paths[$0]).hasPrefix(ignored) }) else {
                        return
                    }
                }
                box.callback()
            }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
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
    let callback: @Sendable () -> Void
    init(ignored: String? = nil, _ callback: @escaping @Sendable () -> Void) {
        self.ignored = ignored
        self.callback = callback
    }
}
