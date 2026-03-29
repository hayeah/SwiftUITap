#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// Built-in window control for SwiftUITap.
/// Accessible via dot-prefixed paths: `.windows.0.frame`, `.windows.0.maximize`, etc.
@MainActor
public enum TapWindowStore {

    // MARK: - Dispatch

    /// Handle a get/set/call on a `.windows` path.
    /// Path format: `.windows.N.property` or `.windows.N.method`
    static func dispatch(_ request: [String: Any]) -> TapResult? {
        guard let type = request["type"] as? String else { return nil }

        switch type {
        case "get":
            guard let path = request["path"] as? String else { return nil }
            return get(path)
        case "call":
            guard let method = request["method"] as? String else { return nil }
            let params = request["params"] as? [String: Any] ?? [:]
            return call(method, params: params)
        case "set":
            guard let path = request["path"] as? String else { return nil }
            return set(path, value: request["value"])
        default:
            return nil
        }
    }

    // MARK: - Get

    static func get(_ path: String) -> TapResult? {
        // ".windows" → list all windows
        if path == ".windows" {
            return .value(snapshotAll())
        }

        // ".windows.N..." → specific window
        guard let (window, tail) = resolveWindow(path) else { return nil }

        guard let prop = tail else {
            return .value(snapshot(window))
        }

        switch prop {
        case "frame":
            let f = window.frame
            return .value(["x": f.origin.x, "y": f.origin.y,
                           "width": f.width, "height": f.height])
        case "title":
            return .value(window.title)
        case "isVisible":
            return .value(window.isVisible)
        case "isFullScreen":
            return .value(window.styleMask.contains(.fullScreen))
        case "screen":
            guard let s = window.screen else { return .value(nil) }
            let v = s.visibleFrame
            return .value(["x": v.origin.x, "y": v.origin.y,
                           "width": v.width, "height": v.height])
        default:
            return .error("unknown window property: \(prop)")
        }
    }

    // MARK: - Set

    static func set(_ path: String, value: Any?) -> TapResult? {
        guard let (window, tail) = resolveWindow(path), let prop = tail else {
            return nil
        }

        switch prop {
        case "title":
            guard let v = value as? String else { return .error("title must be String") }
            window.title = v
            return .value(nil)
        default:
            return .error("cannot set window.\(prop)")
        }
    }

    // MARK: - Call

    static func call(_ method: String, params: [String: Any]) -> TapResult? {
        // ".windows.N.method"
        guard let (window, tail) = resolveWindow(method), let action = tail else {
            return nil
        }

        switch action {
        case "maximize":
            guard let screen = window.screen ?? NSScreen.main else {
                return .error("no screen")
            }
            window.setFrame(screen.visibleFrame, display: true, animate: true)
            return .value(frameDict(window))
        case "center":
            window.center()
            return .value(frameDict(window))
        case "setFrame":
            guard let x = params["x"] as? Double,
                  let y = params["y"] as? Double,
                  let w = params["width"] as? Double,
                  let h = params["height"] as? Double else {
                return .error("setFrame requires x, y, width, height (Double)")
            }
            let animate = params["animate"] as? Bool ?? true
            window.setFrame(NSRect(x: x, y: y, width: w, height: h),
                            display: true, animate: animate)
            return .value(frameDict(window))
        case "setSize":
            guard let w = params["width"] as? Double,
                  let h = params["height"] as? Double else {
                return .error("setSize requires width, height (Double)")
            }
            var frame = window.frame
            frame.size = NSSize(width: w, height: h)
            window.setFrame(frame, display: true, animate: true)
            return .value(frameDict(window))
        default:
            return .error("unknown window method: \(action)")
        }
    }

    // MARK: - Helpers

    /// Parse ".windows.N.rest" → (NSWindow, "rest"?)
    private static func resolveWindow(_ path: String) -> (NSWindow, String?)? {
        // Strip leading ".windows."
        let prefix = ".windows."
        guard path.hasPrefix(prefix) else { return nil }
        let rest = String(path.dropFirst(prefix.count))

        let (indexStr, tail) = TapPath.split(rest)
        guard let idx = Int(indexStr) else { return nil }

        let windows = NSApplication.shared.windows
        guard idx >= 0, idx < windows.count else { return nil }

        return (windows[idx], tail)
    }

    private static func frameDict(_ window: NSWindow) -> [String: Any] {
        let f = window.frame
        return ["x": f.origin.x, "y": f.origin.y,
                "width": f.width, "height": f.height]
    }

    private static func snapshot(_ window: NSWindow) -> [String: Any] {
        let f = window.frame
        var dict: [String: Any] = [
            "frame": ["x": f.origin.x, "y": f.origin.y,
                      "width": f.width, "height": f.height],
            "title": window.title,
            "isVisible": window.isVisible,
            "isFullScreen": window.styleMask.contains(.fullScreen),
        ]
        if let s = window.screen {
            let v = s.visibleFrame
            dict["screen"] = ["x": v.origin.x, "y": v.origin.y,
                              "width": v.width, "height": v.height]
        }
        return dict
    }

    private static func snapshotAll() -> [[String: Any]] {
        NSApplication.shared.windows.map { snapshot($0) }
    }
}
#endif
