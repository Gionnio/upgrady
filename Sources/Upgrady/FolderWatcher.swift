import CoreServices
import Foundation

/// Watches the app folders and reports changes (apps installed, updated or removed), grouped by a short delay.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    private(set) var folders: [URL] = []

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    func watch(_ folders: [URL]) {
        guard folders != self.folders else { return }
        stop()
        self.folders = folders
        let paths = folders.map(\.path).filter { FileManager.default.fileExists(atPath: $0) } as CFArray
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        // Latency of a few seconds: an installation touches many files, one notification is enough.
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               4.0, FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
