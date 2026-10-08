import Foundation
import UpgradyCore

/// `Upgrady --scan`: prints what Upgrady finds, for checking results from the terminal.
enum ScanCommand {

    static func run() async {
        let started = Date()
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.github.gionnio.Upgrady")
        let checker = UpdateChecker(options: CheckOptions(), excludedIdentifiers: [Bundle.main.bundleIdentifier ?? "com.github.gionnio.Upgrady"],
                                    cacheDirectory: cache, homebrew: HomebrewInstallation.locate())
        let result = await checker.run()

        print(pad("APP", 30), pad("FONTE", 40), pad("INSTALLATA", 22), pad("DISPONIBILE", 22), pad("AGG.", 5), "NOTE")
        for status in result.statuses {
            let source: String = switch status.source {
            case .appStore: "App Store"
            case .homebrew(let cask): "Homebrew (\(cask))"
            case .homebrewAvailable(let cask): "Homebrew disponibile (\(cask))"
            case .sparkle: "Sparkle"
            case .none: "—"
            }
            let decision: String = switch status.decision {
            case .updateAvailable: "SÌ"
            case .upToDate: "no"
            case .unknown: "?"
            }
            let notes: String = switch status.notes {
            case .html: "html"
            case .text: "testo"
            case .page: "pagina"
            case .gitHub(let repository, _, _): "github \(repository.owner)/\(repository.name)"
            case nil: "-"
            }
            print(pad(status.app.name, 30), pad(source, 40), pad(status.app.version.description, 22),
                  pad(status.available?.description ?? "-", 22), pad(decision, 5), notes)
        }
        print("\nDa agganciare a Homebrew:")
        for candidate in result.adoptionCandidates {
            print("  \(candidate.app.name) → \(candidate.cask.qualifiedName)\(candidate.versionMatches ? " (stessa versione)" : "")\(candidate.cask.autoUpdates ? " (si aggiorna da sola)" : "")\(candidate.needsTrust ? " [tap non affidabile]" : "")")
        }
        let updates = result.statuses.filter(\.updateAvailable).count
        print("\n\(result.statuses.count) app, \(updates) aggiornamenti, \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        let clipped = text.count > width - 1 ? String(text.prefix(width - 2)) + "…" : text
        return clipped.padding(toLength: width, withPad: " ", startingAt: 0)
    }
}
