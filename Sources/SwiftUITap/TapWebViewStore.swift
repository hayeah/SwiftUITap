import Foundation
import WebKit

/// Stores registered WKWebViews by tag for agent-driven JS evaluation.
@MainActor
public final class TapWebViewStore {
    public static let shared = TapWebViewStore()

    private var webViews: [String: WeakWebView] = [:]

    private init() {}

    // MARK: - Registration

    public func register(_ webView: WKWebView, tag: String) {
        webViews[tag] = WeakWebView(webView)
    }

    public func unregister(tag: String) {
        webViews.removeValue(forKey: tag)
    }

    /// Tags of all currently registered (alive) webviews.
    public var tags: [String] {
        pruneReleased()
        return Array(webViews.keys).sorted()
    }

    /// Tag → current URL string, for `__doc__` integration.
    public var info: [String: String] {
        pruneReleased()
        var result: [String: String] = [:]
        for (tag, weak) in webViews {
            if let wv = weak.webView {
                result[tag] = wv.url?.absoluteString ?? "(no URL)"
            }
        }
        return result
    }

    // MARK: - Eval

    func eval(tag: String?, code: String) async -> TapResult {
        pruneReleased()

        let resolvedTag: String
        if let tag, !tag.isEmpty {
            resolvedTag = tag
        } else {
            let liveTags = tags
            switch liveTags.count {
            case 0:
                return .error("no webviews registered")
            case 1:
                resolvedTag = liveTags[0]
            default:
                return .error("multiple webviews registered (\(liveTags.joined(separator: ", "))) — specify a tag")
            }
        }

        guard let webView = webViews[resolvedTag]?.webView else {
            return .error("webview '\(resolvedTag)' not registered")
        }

        let wrapped = """
        (async () => {
            return (\(code));
        })()
        """

        do {
            let result = try await webView.callAsyncJavaScript(
                wrapped,
                arguments: [:],
                in: nil,
                contentWorld: .page
            )
            return .value(result)
        } catch {
            return .error("JS error: \(error.localizedDescription)")
        }
    }

    // MARK: - Internal

    private func pruneReleased() {
        webViews = webViews.filter { $0.value.webView != nil }
    }
}

/// Weak wrapper to avoid retaining WKWebView instances.
private struct WeakWebView {
    weak var webView: WKWebView?
    init(_ webView: WKWebView) {
        self.webView = webView
    }
}
