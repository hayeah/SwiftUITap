import SwiftUI
import SwiftAgentSDK
#if canImport(AppKit)
import AppKit
#endif

@main
struct TodoListApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
        }
    }

    init() {
        #if canImport(AppKit)
        // Make SPM executable appear in dock with a proper window
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        #endif

        #if DEBUG
        let serverURL = ProcessInfo.processInfo.environment["AGENTSDK_URL"]
            ?? "http://localhost:9876"
        SwiftAgentSDK.poll(state: appState, server: serverURL)
        #endif
    }
}
