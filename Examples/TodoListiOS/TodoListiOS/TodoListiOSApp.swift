import SwiftUI
import SwiftAgentSDK

private let sharedAppState = AppState()

@main
struct TodoListiOSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(sharedAppState)
                .agentInspectable()
                .onAppear {
                    #if DEBUG
                    let serverURL = ProcessInfo.processInfo.environment["AGENTSDK_URL"]
                        ?? "http://localhost:9876"
                    SwiftAgentSDK.poll(state: sharedAppState, server: serverURL)
                    #endif
                }
        }
    }
}
