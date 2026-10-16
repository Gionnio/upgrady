import XCTest
@testable import UpgradyCore

final class BrewRunnerTests: XCTestCase {
    /// A stand-in for brew that runs `body` as a shell script.
    private func fakeBrew(_ body: String) throws -> BrewRunner {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("brew")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return BrewRunner(installation: HomebrewInstallation(brewURL: script))
    }

    func testHangingCommandIsStopped() async throws {
        // The child (`sleep`) keeps the output open, like a hanging curl download started by brew.
        let runner = try fakeBrew("echo start; sleep 600 & wait")
        let started = Date()
        let output = await runner.run(["upgrade"], watchdog: BrewWatchdog(timeout: 2))
        XCTAssertTrue(output.stalled)
        XCTAssertFalse(output.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testCommandWithOutputKeepsRunning() async throws {
        let runner = try fakeBrew("for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do echo $i; sleep 1; done")
        let output = await runner.run(["upgrade"], watchdog: BrewWatchdog(timeout: 5))
        XCTAssertFalse(output.stalled)
        XCTAssertTrue(output.succeeded)
        XCTAssertTrue(output.text.contains("20"))
    }

    func testFailureIsReported() async throws {
        let runner = try fakeBrew("echo 'Error: nope'; exit 1")
        let output = await runner.run(["upgrade"], watchdog: BrewWatchdog(timeout: 30))
        XCTAssertFalse(output.stalled)
        XCTAssertEqual(output.status, 1)
    }
}
