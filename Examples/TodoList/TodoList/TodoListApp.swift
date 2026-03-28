import SwiftUI
import SwiftAgentSDK
#if canImport(AppKit)
import AppKit
#endif

private let sharedAppState = AppState()

@main
struct TodoListApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(sharedAppState)
                .onAppear {
                    #if DEBUG
                    let serverURL = ProcessInfo.processInfo.environment["AGENTSDK_URL"]
                        ?? "http://localhost:9876"
                    SwiftAgentSDK.poll(state: sharedAppState, server: serverURL)
                    #endif
                }
        }
    }

    init() {
        #if canImport(AppKit)
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        #endif
    }
}
