import Foundation
import WebKit

/// Main entry point for SwiftUITap.
/// Call `SwiftUITap.poll(state:server:)` to start the long-poll loop.
public enum SwiftUITap {

    /// Start polling the agent server for commands.
    /// Must be called from the main actor (typically in your App's init).
    ///
    /// - Parameters:
    ///   - state: The root state object (must conform to TapDispatchable)
    ///   - server: The server URL, e.g. "http://localhost:9876"
    @MainActor
    public static func poll(state: any TapDispatchable, server: String) {
        guard let url = URL(string: server) else {
            print("[SwiftUITap] Invalid server URL: \(server)")
            return
        }
        let poller = Poller(state: state, serverURL: url)
        // Retain the poller via global storage
        _activePollers.append(poller)
        poller.start()
        if let deviceUDID = poller.deviceUDID {
            print("[SwiftUITap] Polling \(server) as \(deviceUDID)")
        } else {
            print("[SwiftUITap] Polling \(server)")
        }
    }

    /// URLs of all currently-running pollers. Useful for surfacing in a
    /// debug view.
    @MainActor
    public static var activeServerURLs: [String] {
        _activePollers.map { $0.serverURL.absoluteString }
    }

    // MARK: - WebView Registration

    /// Register a WKWebView for agent-driven JS evaluation.
    @MainActor
    public static func registerWebView(_ webView: WKWebView, tag: String) {
        TapWebViewStore.shared.register(webView, tag: tag)
    }

    /// Unregister a previously registered WKWebView.
    @MainActor
    public static func unregisterWebView(tag: String) {
        TapWebViewStore.shared.unregister(tag: tag)
    }
}

@MainActor
var _activePollers: [Poller] = []
