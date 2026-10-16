import Foundation
import os

/// What Upgrady did, for finding out later why something did not happen:
/// `~/Library/Logs/Upgrady/Upgrady.log` (kept small) and the system log (subsystem of the app).
enum ActivityLog {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Upgrady", category: "activity")
    private static let queue = DispatchQueue(label: "Upgrady.ActivityLog")
    private static let maximumSize = 1_000_000

    static var fileURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Upgrady/Upgrady.log")
    }

    static func write(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        let line = "\(Date().formatted(Date.ISO8601FormatStyle(timeZone: .current))) \(message)\n"
        queue.async {
            let url = fileURL
            let manager = FileManager.default
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maximumSize {
                let old = url.deletingPathExtension().appendingPathExtension("old.log")
                try? manager.removeItem(at: old)
                try? manager.moveItem(at: url, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
