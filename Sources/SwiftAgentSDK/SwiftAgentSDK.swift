import Foundation
import AgentDispatchObjC

/// Main entry point for the SwiftAgentSDK.
/// Call `SwiftAgentSDK.poll(state:server:)` to start the long-poll loop.
public enum SwiftAgentSDK {

    /// Start polling the agent server for commands.
    /// Must be called from the main actor (typically in your App's init).
    ///
    /// - Parameters:
    ///   - state: The root state object (NSObject subclass with @objc dynamic properties)
    ///   - server: The server URL, e.g. "http://localhost:9876"
    @MainActor
    public static func poll(state: NSObject, server: String) {
        guard let url = URL(string: server) else {
            print("[AgentSDK] Invalid server URL: \(server)")
            return
        }
        let poller = Poller(state: state, serverURL: url)
        // Retain the poller by storing in associated object
        objc_setAssociatedObject(state, &pollerKey, poller, .OBJC_ASSOCIATION_RETAIN)
        poller.start()
        print("[AgentSDK] Polling \(server)")
    }
}

private var pollerKey: UInt8 = 0
