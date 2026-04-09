#if canImport(UIKit) && !targetEnvironment(macCatalyst)
import UIKit
import KIFTouch

/// Handles `.kif.*` commands for touch synthesis via KIF's private API approach.
@MainActor
enum TapKIF {

    static func dispatch(_ command: String, params: [String: Any]) -> TapResult {
        guard let window = keyWindow() else {
            return .error("no key window available")
        }

        switch command {
        case "tap":
            return tap(params: params, window: window)
        case "swipe":
            return swipe(params: params, window: window)
        case "longpress":
            return longpress(params: params, window: window)
        case "type":
            return typeText(params: params)
        default:
            return .error("unknown kif command: \(command)")
        }
    }

    private static func tap(params: [String: Any], window: UIWindow) -> TapResult {
        guard let x = asDouble(params["x"]), let y = asDouble(params["y"]) else {
            return .error("kif.tap requires x, y")
        }
        KIFTouchActions.tap(at: CGPoint(x: x, y: y), in: window)
        return .value("ok")
    }

    private static func swipe(params: [String: Any], window: UIWindow) -> TapResult {
        guard let x1 = asDouble(params["x1"]),
              let y1 = asDouble(params["y1"]),
              let x2 = asDouble(params["x2"]),
              let y2 = asDouble(params["y2"]) else {
            return .error("kif.swipe requires x1, y1, x2, y2")
        }
        let duration = asDouble(params["duration"]) ?? 0.3
        KIFTouchActions.swipe(
            from: CGPoint(x: x1, y: y1),
            to: CGPoint(x: x2, y: y2),
            duration: duration,
            in: window
        )
        return .value("ok")
    }

    private static func longpress(params: [String: Any], window: UIWindow) -> TapResult {
        guard let x = asDouble(params["x"]), let y = asDouble(params["y"]) else {
            return .error("kif.longpress requires x, y")
        }
        let duration = asDouble(params["duration"]) ?? 1.0
        KIFTouchActions.longPress(at: CGPoint(x: x, y: y), duration: duration, in: window)
        return .value("ok")
    }

    private static func typeText(params: [String: Any]) -> TapResult {
        guard let text = params["text"] as? String else {
            return .error("kif.type requires text")
        }
        for char in text {
            KIFTypist.enterCharacter(String(char))
        }
        return .value("ok")
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    private static func asDouble(_ value: Any?) -> Double? {
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }
        if let s = value as? String { return Double(s) }
        return nil
    }
}
#endif
