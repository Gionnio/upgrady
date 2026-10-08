import SwiftUI
import UpgradyCore

/// The icon of an installed app.
struct AppIconView: View {
    let url: URL
    var size: CGFloat = 32

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

/// How much Upgrady can do for an app.
enum SupportLevel {
    /// Upgrady installs the update itself (Sparkle, Homebrew).
    case installs
    /// The App Store installs it; Upgrady knows the exact version.
    case appStore
    /// The app updates itself; Upgrady only knows the version from Homebrew's catalog and lets you know.
    case notice
    /// No update information.
    case none

    var symbol: String {
        switch self {
        case .installs: "checkmark.seal.fill"
        case .appStore: "bag.fill"
        case .notice: "arrow.triangle.2.circlepath"
        case .none: "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .installs: .green
        case .appStore: .blue
        case .notice: .orange
        case .none: .secondary
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .installs: "Upgrady installs updates"
        case .appStore: "Updated by the App Store"
        case .notice: "The app updates itself"
        case .none: "No update information"
        }
    }
}

extension UpdateSource {
    var supportLevel: SupportLevel {
        switch self {
        case .homebrew, .sparkle: .installs
        case .appStore: .appStore
        case .homebrewAvailable: .notice
        case .none: .none
        }
    }
}

/// A small label with the update source. Filled when Upgrady installs or the App Store does,
/// outlined when it is only a notice, grey without information.
struct SourceBadge: View {
    let source: UpdateSource

    var body: some View {
        let level = source.supportLevel
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(level == .notice || level == .none ? Color.clear : color.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(level == .notice ? color.opacity(0.6) : .clear, lineWidth: 1))
            .foregroundStyle(color)
            .help(Text(level.title))
    }

    private var label: LocalizedStringKey {
        switch source {
        case .appStore: "App Store"
        case .homebrew: "Homebrew"
        case .homebrewAvailable: "Homebrew"
        case .sparkle: "Sparkle"
        case .none: "Unsupported"
        }
    }

    private var color: Color {
        switch source {
        case .appStore: .blue
        case .homebrew, .homebrewAvailable: .orange
        case .sparkle: .green
        case .none: .secondary
        }
    }
}

/// "current → new" in secondary text.
struct VersionLine: View {
    let status: AppStatus

    var body: some View {
        if let available = status.available, status.updateAvailable {
            Text(verbatim: "\(status.app.version) → \(available)")
        } else {
            Text(verbatim: status.app.version.description)
        }
    }
}

/// The capsule button of an update: "Update", then a progress bar with percentage.
struct UpdateCapsule: View {
    @EnvironmentObject private var center: UpdateCenter
    let status: AppStatus
    var prominent = false

    var body: some View {
        switch center.operations[status.id] {
        case .queued?:
            progress(nil, label: "Queued")
        case .preparing?:
            progress(nil, label: "Preparing")
        case .downloading(let fraction)?:
            progress(fraction, label: nil)
        case .installing?:
            progress(nil, label: "Installing")
        case .failed(let message)?:
            Button {
                center.clearFailure(status)
                center.update(status)
            } label: {
                Label("Retry", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Color.red.opacity(0.15), in: Capsule())
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help(message)
        case nil:
            Button { center.update(status) } label: {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 3)
                    .background(prominent ? Color.accentColor : Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(prominent ? Color.white : Color.accentColor)
            }
            .buttonStyle(.plain)
        }
    }

    private var title: LocalizedStringKey {
        switch status.source {
        case .appStore: "App Store"
        case .homebrew, .sparkle: "Update"
        default: "Open"
        }
    }

    private func progress(_ fraction: Double?, label: LocalizedStringKey?) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.accentColor.opacity(0.12))
            if let fraction {
                GeometryReader { geometry in
                    Capsule().fill(Color.accentColor.opacity(0.35))
                        .frame(width: max(geometry.size.width * fraction, 8))
                }
                Text(verbatim: "\(Int((fraction * 100).rounded(.down)))%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .frame(maxWidth: .infinity)
            } else if let label {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text(label).font(.caption2)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(Color.accentColor)
        .frame(width: 92, height: 20)
        .contextMenu {
            Button("Cancel") { center.cancel(status) }
        }
    }
}

/// Section header used in the panel and in Settings.
struct SectionLabel: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(nil)
    }
}

extension View {
    /// Liquid Glass capsule on macOS 26 and later, a translucent material before.
    @ViewBuilder
    func floatingCapsule() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
        }
    }

    /// Prominent Liquid Glass button on macOS 26 and later, a bordered prominent button before.
    @ViewBuilder
    func prominentGlassButton() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}
