import XCTest
@testable import UpgradyCore

final class VersionNumberTests: XCTestCase {

    private func v(_ text: String) -> VersionNumber { VersionNumber(text)! }

    func testParsingSkipsPrefixesAndSuffixes() {
        XCTAssertEqual(v("v1.2.3").text, "1.2.3")
        XCTAssertEqual(v("Version 2.0").text, "2.0")
        XCTAssertEqual(v("5.1 (431)").text, "5.1")
        XCTAssertEqual(v("PrusaSlicer-2.9.6").text, "2.9.6")
        XCTAssertNil(VersionNumber("latest"))
        XCTAssertNil(VersionNumber(""))
    }

    func testNumericOrder() {
        XCTAssertLessThan(v("1.2.9"), v("1.2.10"))
        XCTAssertLessThan(v("1.9"), v("1.10"))
        XCTAssertLessThan(v("2026.9.30"), v("2026.10.1"))
        XCTAssertGreaterThan(v("154.0.8037.98"), v("154.0.8037.93"))
    }

    func testTrailingZerosAreEqual() {
        XCTAssertEqual(v("2.0"), v("2.0.0"))
        XCTAssertEqual(v("3"), v("3.0"))
        XCTAssertLessThan(v("2.0"), v("2.0.1"))
    }

    func testPreReleases() {
        XCTAssertLessThan(v("2.0b3"), v("2.0"))
        XCTAssertLessThan(v("2.0a1"), v("2.0b1"))
        XCTAssertLessThan(v("2.0b2"), v("2.0rc1"))
        XCTAssertLessThan(v("2.0-beta.2"), v("2.0-beta.10"))
        XCTAssertLessThan(v("1.9"), v("2.0b1"))
        XCTAssertTrue(v("2.0rc1").isPreRelease)
        XCTAssertFalse(v("2.0").isPreRelease)
    }
}

final class UpdateDecisionTests: XCTestCase {

    private func decide(_ installed: (String?, String?), _ available: (String?, String?)) -> UpdateDecision {
        UpdateDecision.compare(installed: AppVersion(display: installed.0, build: installed.1),
                               available: AppVersion(display: available.0, build: available.1))
    }

    func testNewerDisplayVersion() {
        XCTAssertEqual(decide(("3.0.19", "3019"), ("3.1", nil)), .updateAvailable)
        XCTAssertEqual(decide(("3.1", "3100"), ("3.0.19", nil)), .upToDate)
    }

    func testBuildBreaksTies() {
        XCTAssertEqual(decide(("1.2", "40"), ("1.2", "41")), .updateAvailable)
        XCTAssertEqual(decide(("1.2", "41"), ("1.2", "41")), .upToDate)
        XCTAssertEqual(decide(("1.2", "41"), ("1.2", nil)), .upToDate)
    }

    func testBuildAppendedToRemoteVersion() {
        // 1.2 (40) installed, remote reports 1.2.40: same release.
        XCTAssertEqual(decide(("1.2", "40"), ("1.2.40", nil)), .upToDate)
        XCTAssertEqual(decide(("1.2", "40"), ("1.2.41", nil)), .updateAvailable)
    }

    func testVersionEqualToBuild() {
        XCTAssertEqual(decide(("4.3.2", "4.3.2"), ("4.3.2", nil)), .upToDate)
        XCTAssertEqual(decide(("4.3.2", "4.3.2"), ("4.3.3", nil)), .updateAvailable)
    }

    func testOnlyBuildsKnown() {
        XCTAssertEqual(decide(("2.1", "377"), (nil, "380")), .updateAvailable)
        XCTAssertEqual(decide(("2.1", "377"), (nil, "377")), .upToDate)
        XCTAssertEqual(decide(("2.1", nil), (nil, "380")), .unknown)
    }

    func testPreReleaseOnlyForPreReleaseUsers() {
        XCTAssertEqual(decide(("2.0", nil), ("2.1b1", nil)), .upToDate)
        XCTAssertEqual(decide(("2.1b1", nil), ("2.1b2", nil)), .updateAvailable)
        XCTAssertEqual(decide(("2.1b2", nil), ("2.1", nil)), .updateAvailable)
    }

    func testCaskVersionWithComma() {
        let available = AppVersion(caskVersion: "2.19675.0,5706e5524dba58b23e105c31c358df8ab0a95852")
        XCTAssertEqual(available.display, "2.19675.0")
        XCTAssertEqual(UpdateDecision.compare(installed: AppVersion(display: "2.16120.0", build: "2.16120.0"), available: available), .updateAvailable)
    }

    func testUnreadableVersionsAreNotUpdates() {
        XCTAssertFalse(decide(("abc", nil), ("def", nil)).isUpdate)
    }
}
