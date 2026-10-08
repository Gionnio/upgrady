import XCTest
@testable import UpgradyCore

final class ScannerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func makeApp(_ path: String, info: [String: Any], receipt: Bool = false) throws -> URL {
        let app = root.appendingPathComponent(path)
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        if receipt {
            let folder = contents.appendingPathComponent("_MASReceipt")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([1]).write(to: folder.appendingPathComponent("receipt"))
        }
        return app
    }

    func testFindsAppsInSubfoldersAndReadsDetails() throws {
        try makeApp("Stats.app", info: ["CFBundleIdentifier": "eu.exelban.Stats", "CFBundleName": "Stats",
                                         "CFBundleShortVersionString": "3.0.19", "CFBundleVersion": "3019",
                                         "SUFeedURL": "https://example.org/appcast.xml"])
        try makeApp("Utilities/Tool.app", info: ["CFBundleIdentifier": "org.example.tool", "CFBundleShortVersionString": "1.0"])
        try makeApp("Pages.app", info: ["CFBundleIdentifier": "com.apple.iWork.Pages", "CFBundleShortVersionString": "15.4"], receipt: true)

        let apps = AppScanner(folders: [root]).scan()
        XCTAssertEqual(apps.map(\.name), ["Pages", "Stats", "Tool"])

        let stats = try XCTUnwrap(apps.first { $0.name == "Stats" })
        XCTAssertEqual(stats.version, AppVersion(display: "3.0.19", build: "3019"))
        XCTAssertEqual(stats.sparkleFeedURL?.absoluteString, "https://example.org/appcast.xml")
        XCTAssertTrue(try XCTUnwrap(apps.first { $0.name == "Pages" }).hasAppStoreReceipt)
    }

    func testReadsWrappedMobileApps() throws {
        let inner = root.appendingPathComponent("Keepa.app/Wrapper/Keepa.app")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.keepa.app", "CFBundleDisplayName": "Keepa",
                                   "CFBundleShortVersionString": "4.20", "CFBundleVersion": "4200"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: inner.appendingPathComponent("Info.plist"))
        try Data().write(to: root.appendingPathComponent("Keepa.app/Wrapper/iTunesMetadata.plist"))

        let app = try XCTUnwrap(AppScanner(folders: [root]).scan().first)
        XCTAssertEqual(app.name, "Keepa")
        XCTAssertTrue(app.isMobileApp)
        XCTAssertTrue(app.hasAppStoreReceipt)
        XCTAssertEqual(app.version, AppVersion(display: "4.20", build: "4200"))
    }

    func testSkipsSystemExcludedAndBrokenApps() throws {
        try makeApp("Safari.app", info: ["CFBundleIdentifier": "com.apple.Safari", "CFBundleShortVersionString": "26.0"])
        try makeApp("Upgrady.app", info: ["CFBundleIdentifier": "com.github.gionnio.Upgrady", "CFBundleShortVersionString": "2.0.0"])
        try makeApp("Broken.app", info: ["CFBundleName": "Broken"])
        try makeApp("NoVersion.app", info: ["CFBundleIdentifier": "org.example.noversion"])

        let apps = AppScanner(folders: [root], excludedIdentifiers: ["com.github.gionnio.Upgrady"]).scan()
        XCTAssertTrue(apps.isEmpty, "\(apps.map(\.name))")
    }
}
