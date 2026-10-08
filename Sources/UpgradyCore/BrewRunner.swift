import Foundation

/// Runs brew commands for a GUI app.
public struct BrewRunner: Sendable {
    public let installation: HomebrewInstallation
    /// A script that asks for the administrator password with a dialog (`sudo -A`).
    public var passwordPromptScript: URL?

    public init(installation: HomebrewInstallation, passwordPromptScript: URL? = nil) {
        self.installation = installation
        self.passwordPromptScript = passwordPromptScript
    }

    public struct Output: Sendable {
        public let status: Int32
        public let text: String
        public var succeeded: Bool { status == 0 }

        /// macOS refused to let brew change an app: the "App Management" permission is missing.
        public var lacksAppManagementPermission: Bool { text.contains("Operation not permitted") }
        /// Homebrew ignores casks from taps that are not trusted.
        public var needsTapTrust: Bool { text.localizedCaseInsensitiveContains("tap trust") && !succeeded }
    }

    /// Runs brew and waits for it. `onOutput` receives output as it arrives.
    public func run(_ arguments: [String], includeErrors: Bool = true, onOutput: (@Sendable (String) -> Void)? = nil) async -> Output {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = installation.brewURL
            process.arguments = arguments
            process.environment = environment()
            process.standardInput = FileHandle.nullDevice

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = includeErrors ? pipe : FileHandle.nullDevice

            let collected = OutputBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                collected.append(data)
                onOutput?(String(decoding: data, as: UTF8.self))
            }
            process.terminationHandler = { process in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                if !rest.isEmpty {
                    collected.append(rest)
                    onOutput?(String(decoding: rest, as: UTF8.self))
                }
                continuation.resume(returning: Output(status: process.terminationStatus, text: collected.text))
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: Output(status: -1, text: error.localizedDescription))
            }
        }
    }

    private func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let bin = installation.brewURL.deletingLastPathComponent().path
        environment["PATH"] = ([bin, "/usr/bin", "/bin", "/usr/sbin", "/sbin"] + [environment["PATH"] ?? ""]).joined(separator: ":")
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["HOMEBREW_NO_COLOR"] = "1"
        environment["NONINTERACTIVE"] = "1"
        if let passwordPromptScript { environment["SUDO_ASKPASS"] = passwordPromptScript.path }
        return environment
    }

    /// Writes the password prompt script used by `sudo -A` and returns its location.
    public static func installPasswordPrompt(in directory: URL, message: String) -> URL? {
        let safe = message.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\\", with: "")
        let script = """
        #!/bin/sh
        exec /usr/bin/osascript -e 'display dialog "\(safe)" with title "Upgrady" default answer "" with hidden answer with icon caution' -e 'text returned of result'
        """
        let url = directory.appendingPathComponent("password-prompt.sh")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ more: Data) { lock.withLock { data.append(more) } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

// MARK: - Download progress

/// Follows a cask download while brew runs, by watching the partial file in brew's cache.
public final class CaskDownloadProgress: @unchecked Sendable {
    public typealias Handler = @Sendable (_ fraction: Double) -> Void

    private let runner: BrewRunner
    private let cask: Cask
    private let handler: Handler
    private var task: Task<Void, Never>?

    public init(runner: BrewRunner, cask: Cask, handler: @escaping Handler) {
        self.runner = runner
        self.cask = cask
        self.handler = handler
    }

    public func start() {
        task = Task.detached { [runner, cask, handler] in
            let cachePath = await runner.run(["--cache", "--cask", cask.qualifiedName], includeErrors: false).text
                .split(separator: "\n").last(where: { $0.hasPrefix("/") }).map(String.init)
            guard let cachePath, let total = await Self.expectedSize(of: cask), total > 0 else { return }
            let partial = cachePath + ".incomplete"
            var lastReported = -1.0
            while !Task.isCancelled {
                if let size = (try? FileManager.default.attributesOfItem(atPath: partial))?[.size] as? NSNumber {
                    let fraction = min(Double(size.int64Value) / Double(total), 1)
                    if fraction - lastReported >= 0.005 {
                        lastReported = fraction
                        handler(fraction)
                    }
                } else if lastReported >= 0 {
                    handler(1)
                    return
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    public func stop() {
        task?.cancel()
    }

    /// The size of the cask download, asked to the server.
    static func expectedSize(of cask: Cask) async -> Int64? {
        guard var address = cask.downloadURL else { return nil }
        if let version = cask.version {
            address = address.replacingOccurrences(of: "#{version}", with: version)
        }
        guard !address.contains("#{"), let url = URL(string: address) else { return nil }
        var head = URLRequest(url: url, timeoutInterval: 15)
        head.httpMethod = "HEAD"
        if let (_, response) = try? await URLSession.shared.data(for: head), response.expectedContentLength > 0 {
            return response.expectedContentLength
        }
        var range = URLRequest(url: url, timeoutInterval: 15)
        range.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let (_, response) = try? await URLSession.shared.data(for: range),
              let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"),
              let total = header.split(separator: "/").last.flatMap({ Int64($0) }) else { return nil }
        return total
    }
}
