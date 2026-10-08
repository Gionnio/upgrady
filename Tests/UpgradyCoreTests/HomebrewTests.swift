import XCTest
@testable import UpgradyCore

final class HomebrewTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func app(_ fileName: String, id: String, version: String = "1.0") -> InstalledApp {
        InstalledApp(url: URL(fileURLWithPath: "/Applications/\(fileName)"), bundleIdentifier: id, name: fileName,
                     version: AppVersion(display: version, build: nil))
    }

    func testCatalogParsing() throws {
        let catalog = CaskCatalog.parse(try fixture("casks.json"))
        let chrome = try XCTUnwrap(catalog.cask(token: "google-chrome"))
        XCTAssertEqual(chrome.version, "154.0.8037.98")
        XCTAssertEqual(chrome.appNames, ["Google Chrome.app"])
        XCTAssertTrue(chrome.autoUpdates)
        XCTAssertTrue(chrome.identifierHints.contains("com.google.Chrome"))

        // `app` with a target and the sibling `target` form.
        XCTAssertEqual(catalog.cask(token: "prusaslicer")?.appNames, ["PrusaSlicer.app"])
        XCTAssertEqual(catalog.cask(token: "balenaetcher")?.appNames, ["balenaEtcher.app"])
        // `version :latest` has no comparable version.
        XCTAssertNil(catalog.cask(token: "nightly-thing")?.version)
    }

    func testRubyCask() {
        let source = """
        cask "midnightoil" do
          version "1.3.0"
          sha256 "abc"
          url "https://github.com/coreyhaines31/midnightoil/releases/download/v#{version}/MidnightOil-#{version}.dmg"
          homepage "https://midnightoil.app"
          auto_updates true
          app "Midnight Oil.app"
          app "Tools/Helper.app", target: "Midnight Helper.app"
          zap trash: "~/Library/Preferences/app.midnightoil.MidnightOil.plist"
        end
        """
        let cask = RubyCask.parse(source, token: "midnightoil", tap: "coreyhaines31/tap")
        XCTAssertEqual(cask.version, "1.3.0")
        XCTAssertEqual(cask.appNames, ["Midnight Oil.app", "Midnight Helper.app"])
        XCTAssertTrue(cask.autoUpdates)
        XCTAssertEqual(cask.homepage, "https://midnightoil.app")
        XCTAssertEqual(cask.qualifiedName, "coreyhaines31/tap/midnightoil")
        XCTAssertTrue(cask.identifierHints.contains("app.midnightoil.MidnightOil"))
    }

    func testCaskroomReceipts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = root.appendingPathComponent("renamy/.metadata")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("renamy/2.0.1"), withIntermediateDirectories: true)
        try fixture("receipt.json").write(to: metadata.appendingPathComponent("INSTALL_RECEIPT.json"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("firefox/150.0"), withIntermediateDirectories: true)

        let casks = Caskroom.read(caskroom: root)
        let renamy = try XCTUnwrap(casks.first { $0.token == "renamy" })
        XCTAssertEqual(renamy.tap, "gionnio/tap")
        XCTAssertEqual(renamy.versions, ["2.0.1"])
        XCTAssertEqual(renamy.appNames, ["Renamy.app"])
        let firefox = try XCTUnwrap(casks.first { $0.token == "firefox" })
        XCTAssertNil(firefox.tap)
        XCTAssertTrue(firefox.appNames.isEmpty)
    }

    func testMatchingIsCautious() {
        let cemuCalculator = Cask(token: "cemu", version: "2.0", appNames: ["CEmu.app"], identifierHints: ["com.yourcompany.CEmu"])
        let chrome = Cask(token: "google-chrome", version: "154", appNames: ["Google Chrome.app"], identifierHints: ["com.google.Chrome"])
        let matcher = CaskMatcher(installedCasks: [], catalog: CaskCatalog(casks: [cemuCalculator, chrome]), tapCasks: [])

        // Same name only when ignoring case, identifier does not confirm: no match.
        XCTAssertNil(matcher.availableCask(for: app("Cemu.app", id: "info.cemu.Cemu")))
        // Exact name: match.
        XCTAssertEqual(matcher.availableCask(for: app("Google Chrome.app", id: "com.google.Chrome"))?.token, "google-chrome")
        // Generic vendor prefixes do not confirm.
        XCTAssertFalse(CaskMatcher.confirms(["com.github.someone.Other"], "com.github.gionnio.Renamy"))
        XCTAssertTrue(CaskMatcher.confirms(["com.google.Keystone"], "com.google.Chrome"))
    }

    func testChannelVariantsAndDisabledCasks() throws {
        let stable = Cask(token: "motrix", version: "1.8.19", appNames: ["Motrix.app"])
        let beta = Cask(token: "motrix@beta", version: "2.0.0-beta", appNames: ["Motrix.app"])
        let catalog = CaskCatalog(casks: [stable, beta])
        let motrix = app("Motrix.app", id: "app.motrix.native")

        // Not installed with brew: the stable cask is suggested.
        XCTAssertEqual(CaskMatcher(installedCasks: [], catalog: catalog, tapCasks: []).availableCask(for: motrix)?.token, "motrix")
        // Installed from the beta channel (receipt without app names): the installed cask wins.
        let betaInstalled = InstalledCask(token: "motrix@beta", tap: nil, versions: ["2.0.0-beta"], appNames: [])
        XCTAssertEqual(CaskMatcher(installedCasks: [betaInstalled], catalog: catalog, tapCasks: []).installedCask(for: motrix)?.token, "motrix@beta")

        let parsed = CaskCatalog.parse(try fixture("casks.json"))
        XCTAssertNil(parsed.cask(token: "old-disabled"))
    }

    func testInstalledCaskDecision() {
        let installed = InstalledCask(token: "google-chrome", tap: nil, versions: ["154.0.8037.93"], appNames: ["Google Chrome.app"])
        let cask = Cask(token: "google-chrome", version: "154.0.8037.98", appNames: ["Google Chrome.app"], autoUpdates: true)
        let matcher = CaskMatcher(installedCasks: [installed], catalog: CaskCatalog(casks: [cask]), tapCasks: [])
        let resolver = SourceResolver(matcher: matcher, appStore: [:], options: CheckOptions())

        let outdated = resolver.status(for: app("Google Chrome.app", id: "com.google.Chrome", version: "154.0.8037.93"))
        XCTAssertEqual(outdated?.source, .homebrew(cask: "google-chrome"))
        XCTAssertEqual(outdated?.decision, .updateAvailable)

        // The app updated itself: up to date even though brew recorded an older version.
        let selfUpdated = resolver.status(for: app("Google Chrome.app", id: "com.google.Chrome", version: "154.0.8037.98"))
        XCTAssertEqual(selfUpdated?.decision, .upToDate)
    }
}
