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

    init(paths: [String], callback: @escaping @Sendable () -> Void) {
        contextBox = MonitorCallback(callback)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(contextBox).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(
            nil, { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<MonitorCallback>.fromOpaque(info).takeUnretainedValue().callback()
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
    let callback: @Sendable () -> Void
    init(_ callback: @escaping @Sendable () -> Void) {
        self.callback = callback
    }
}
