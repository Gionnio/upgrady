import XCTest
@testable import UpgradyCore

final class AppcastTests: XCTestCase {

    private func items() throws -> [AppcastItem] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "appcast.xml", withExtension: nil, subdirectory: "Fixtures"))
        return Appcast.parse(try Data(contentsOf: url))
    }

    func testParsesItems() throws {
        let items = try items()
        XCTAssertEqual(items.count, 5)
        let release = try XCTUnwrap(items.first { $0.shortVersion == "3.1" })
        XCTAssertEqual(release.build, "310")
        XCTAssertEqual(release.minimumSystemVersion, "14.0")
        XCTAssertEqual(release.downloadURL?.absoluteString, "https://example.org/3.1.zip")
        XCTAssertNotNil(release.date)
        XCTAssertEqual(release.description(preferredLanguages: ["it-IT"]), "<ul><li>Più veloce</li></ul>")
        XCTAssertEqual(release.description(preferredLanguages: ["fr"]), "<ul><li>Faster</li></ul>")
        XCTAssertEqual(items.first { $0.shortVersion == "3.0" }?.releaseNotesURL?.absoluteString, "https://example.org/notes/3.0.html")
    }

    func testNewestSkipsBetaChannelOtherSystemsAndIncompatibleMacOS() throws {
        let newest = Appcast.newest(in: try items(), systemVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
        XCTAssertEqual(newest?.shortVersion, "3.1")
        let old = Appcast.newest(in: try items(), systemVersion: OperatingSystemVersion(majorVersion: 13, minorVersion: 6, patchVersion: 0))
        XCTAssertEqual(old?.shortVersion, "3.0")
    }

    func testUpdateDecisionFromFeed() throws {
        let newest = try XCTUnwrap(Appcast.newest(in: try items(), systemVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)))
        XCTAssertEqual(UpdateDecision.compare(installed: AppVersion(display: "3.0", build: "300"), available: newest.version), .updateAvailable)
        XCTAssertEqual(UpdateDecision.compare(installed: AppVersion(display: "3.1", build: "310"), available: newest.version), .upToDate)
    }
}
