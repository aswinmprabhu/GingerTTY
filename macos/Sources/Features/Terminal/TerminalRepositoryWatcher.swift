import CoreServices
import Foundation

final class TerminalRepositoryWatcher {
    private let queue = DispatchQueue(label: "com.gingertty.terminal.repository-watcher")
    private var stream: FSEventStreamRef?
    private var onEvent: (() -> Void)?

    func start(paths: [String], onEvent: @escaping () -> Void) {
        stop()

        let uniquePaths = Array(Set(paths)).sorted()
        guard !uniquePaths.isEmpty else { return }

        self.onEvent = onEvent

        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<TerminalRepositoryWatcher>
                .fromOpaque(info)
                .takeUnretainedValue()
            watcher.onEvent?()
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagUseCFTypes
        )

        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            uniquePaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            flags
        ) else {
            self.onEvent = nil
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else {
            onEvent = nil
            return
        }

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        self.onEvent = nil
    }

    deinit {
        stop()
    }
}
