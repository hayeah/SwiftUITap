import Foundation
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Routes dot-prefixed paths to system NSObjects for dynamic dispatch.
@MainActor
enum TapBuiltins {

    /// Resolve a dot-prefixed path to (NSObject, remainingPath).
    /// Returns nil if the path doesn't match any builtin.
    static func resolve(_ path: String) -> (NSObject, String?)? {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return resolveMacOS(path)
        #elseif canImport(UIKit)
        return resolveIOS(path)
        #else
        return nil
        #endif
    }

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    private static func resolveMacOS(_ path: String) -> (NSObject, String?)? {
        if path == ".windows" {
            // Return the array itself — snapshot will list all windows
            return (NSApplication.shared.windows as NSArray, nil)
        }
        if path.hasPrefix(".windows.") {
            return resolveIndexed(path, prefix: ".windows.", array: NSApplication.shared.windows)
        }
        if path == ".screens" {
            return (NSScreen.screens as NSArray, nil)
        }
        if path.hasPrefix(".screens.") {
            return resolveIndexed(path, prefix: ".screens.", array: NSScreen.screens)
        }
        if path == ".app" || path.hasPrefix(".app.") {
            return resolveSimple(path, prefix: ".app", obj: NSApplication.shared)
        }
        if path == ".pasteboard" || path.hasPrefix(".pasteboard.") {
            return resolveSimple(path, prefix: ".pasteboard", obj: NSPasteboard.general)
        }
        if path == ".workspace" || path.hasPrefix(".workspace.") {
            return resolveSimple(path, prefix: ".workspace", obj: NSWorkspace.shared)
        }
        if path == ".defaults" || path.hasPrefix(".defaults.") {
            return resolveSimple(path, prefix: ".defaults", obj: UserDefaults.standard)
        }
        if path == ".bundle" || path.hasPrefix(".bundle.") {
            return resolveSimple(path, prefix: ".bundle", obj: Bundle.main)
        }
        if path == ".process" || path.hasPrefix(".process.") {
            return resolveSimple(path, prefix: ".process", obj: ProcessInfo.processInfo)
        }
        return nil
    }
    #endif

    #if canImport(UIKit)
    private static func resolveIOS(_ path: String) -> (NSObject, String?)? {
        if path == ".app" || path.hasPrefix(".app.") {
            return resolveSimple(path, prefix: ".app", obj: UIApplication.shared)
        }
        if path == ".windows" || path.hasPrefix(".windows.") {
            if let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first {
                let windows = scene.windows
                if path == ".windows" {
                    return (windows as NSArray, nil)
                }
                return resolveIndexed(path, prefix: ".windows.", array: windows)
            }
            return nil
        }
        if path == ".screen" || path.hasPrefix(".screen.") {
            return resolveSimple(path, prefix: ".screen", obj: UIScreen.main)
        }
        if path == ".pasteboard" || path.hasPrefix(".pasteboard.") {
            return resolveSimple(path, prefix: ".pasteboard", obj: UIPasteboard.general)
        }
        if path == ".defaults" || path.hasPrefix(".defaults.") {
            return resolveSimple(path, prefix: ".defaults", obj: UserDefaults.standard)
        }
        if path == ".bundle" || path.hasPrefix(".bundle.") {
            return resolveSimple(path, prefix: ".bundle", obj: Bundle.main)
        }
        if path == ".process" || path.hasPrefix(".process.") {
            return resolveSimple(path, prefix: ".process", obj: ProcessInfo.processInfo)
        }
        if path == ".device" || path.hasPrefix(".device.") {
            return resolveSimple(path, prefix: ".device", obj: UIDevice.current)
        }
        return nil
    }
    #endif

    // MARK: - Helpers

    /// Resolve a simple singleton path like ".app" or ".app.foo.bar"
    private static func resolveSimple(_ path: String, prefix: String, obj: NSObject) -> (NSObject, String?) {
        if path == prefix {
            return (obj, nil)
        }
        // Strip prefix + dot
        let tail = String(path.dropFirst(prefix.count + 1))
        return (obj, tail.isEmpty ? nil : tail)
    }

    /// Resolve an indexed path like ".windows.0.title"
    private static func resolveIndexed(_ path: String, prefix: String, array: [some NSObject]) -> (NSObject, String?)? {
        let rest = String(path.dropFirst(prefix.count))
        let (indexStr, tail) = TapPath.split(rest)
        guard let index = Int(indexStr), index >= 0, index < array.count else { return nil }
        return (array[index], tail)
    }
}
