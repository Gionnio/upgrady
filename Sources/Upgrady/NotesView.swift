import SwiftUI
import WebKit
import UpgradyCore

/// Shows the release notes of an update.
struct NotesView: View {
    let status: AppStatus
    @State private var html: String?
    @State private var page: URL?
    @State private var message: LocalizedStringKey?

    @State private var loaded = false

    var body: some View {
        // The web view stays in place while notes load, so the panel does not jump or flash.
        ZStack {
            WebView(html: html, page: page, loaded: $loaded)
                .opacity(loaded && message == nil ? 1 : 0)
            if let message {
                Text(message).foregroundStyle(.secondary).padding()
            } else if !loaded {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: loaded)
        .task(id: status.id) { await load() }
    }

    private func load() async {
        loaded = false; message = nil
        switch status.notes {
        case .html(let text):
            page = nil; html = Self.wrap(text)
        case .text(let text):
            page = nil; html = Self.wrap("<p style=\"white-space: pre-wrap\">\(Self.escape(text))</p>")
        case .page(let url):
            html = nil; page = url
        case .gitHub(let repository, let newVersion, let installedVersion):
            do {
                let releases = try await GitHubReleases().releases(of: repository)
                let relevant = GitHubReleases.relevant(releases, newest: newVersion, installed: installedVersion)
                guard !relevant.isEmpty else { message = "No release notes"; return }
                let date = DateFormatter()
                date.dateStyle = .long
                let body = relevant.map { release in
                    let title = Self.escape(release.title?.isEmpty == false ? release.title! : release.tag)
                    let when = release.published.map { " <span class=\"date\">\(date.string(from: $0))</span>" } ?? ""
                    return "<h2>\(title)\(when)</h2>\(release.html ?? "")"
                }.joined(separator: "<hr>")
                let link = "<p><a href=\"\(repository.releasesPage.absoluteString)\">\(Self.escape(String(localized: "All releases on GitHub")))</a></p>"
                page = nil; html = Self.wrap(body + link)
            } catch GitHubReleases.LoadError.rateLimited {
                message = "GitHub is limiting requests. Try again later."
            } catch {
                message = "Release notes could not be loaded."
            }
        case nil:
            message = "No release notes"
        }
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Wraps notes in a page that follows the system font and light/dark appearance.
    static func wrap(_ body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <style>
        body { font: 13px -apple-system, sans-serif; line-height: 1.5; margin: 14px; color: CanvasText; background: transparent; }
        h1, h2, h3 { font-size: 14px; margin: 14px 0 6px; }
        .date { font-weight: normal; color: GrayText; font-size: 12px; }
        a { color: AccentColor; } img { max-width: 100%; height: auto; }
        hr { border: 0; border-top: 1px solid rgba(128,128,128,.25); margin: 16px 0; }
        pre, code { font-size: 12px; } ul { padding-left: 20px; }
        </style></head><body>\(body)</body></html>
        """
    }
}

/// A web view for release notes; links open in the browser.
///
/// It only loads when the content changes (SwiftUI calls `updateNSView` often) and reports when the page is ready.
struct WebView: NSViewRepresentable {
    let html: String?
    let page: URL?
    @Binding var loaded: Bool

    func makeCoordinator() -> Coordinator { Coordinator(loaded: $loaded) }

    func makeNSView(context: Context) -> WKWebView {
        let view = FlexibleWebView()
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.loaded = $loaded
        let key = html ?? page?.absoluteString
        guard let key, key != context.coordinator.currentKey else { return }
        context.coordinator.currentKey = key
        if let html {
            view.loadHTMLString(html, baseURL: nil)
        } else if let page {
            view.load(URLRequest(url: page))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: Binding<Bool>
        var currentKey: String?

        init(loaded: Binding<Bool>) {
            self.loaded = loaded
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded.wrappedValue = true
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            loaded.wrappedValue = true
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

/// A web view that takes the space it is given. A plain `WKWebView` asks for the height of the whole page,
/// which made the window content taller than the window and pushed it out of place.
private final class FlexibleWebView: WKWebView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
}
