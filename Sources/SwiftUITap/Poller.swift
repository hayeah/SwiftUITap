import Foundation

/// Long-polls the agent server for requests and dispatches them on MainActor.
@MainActor
final class Poller {
    private static let deviceUDIDHeader = "x-swiftui-tap-udid"

    private let dispatcher: Dispatcher
    let serverURL: URL
    let deviceUDID: String?
    private let session: URLSession
    private var isRunning = false

    init(state: any TapDispatchable, serverURL: URL) {
        self.dispatcher = Dispatcher(state: state)
        self.serverURL = serverURL
        self.deviceUDID = Self.resolveDeviceUDID()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        Task { @MainActor in
            await pollLoop()
        }
    }

    func stop() {
        isRunning = false
    }

    private func pollLoop() async {
        while isRunning {
            do {
                let request = try await fetchNextRequest(previousResponse: nil)
                await processAndRespond(request)
            } catch {
                print("[SwiftUITap] Poll error: \(error.localizedDescription). Retrying in 2s...")
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func fetchNextRequest(previousResponse: [String: Any]?) async throws -> [String: Any] {
        let pollURL = serverURL.appendingPathComponent("poll")
        var urlRequest = URLRequest(url: pollURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let deviceUDID {
            urlRequest.setValue(deviceUDID, forHTTPHeaderField: Self.deviceUDIDHeader)
        }

        if let response = previousResponse {
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: response)
        } else {
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: [:] as [String: Any])
        }

        let (data, _) = try await session.data(for: urlRequest)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PollerError.invalidResponse
        }
        return json
    }

    private func processAndRespond(_ request: [String: Any]) async {
        let result: TapResult
        let path = request["_path"] as? String ?? "/request"
        if path == "/view", let viewStore = TapViewStore.active {
            result = viewStore.dispatch(request)
        } else {
            result = dispatcher.dispatch(request)
        }

        // Build response with internal request tracking ID
        var fullResponse = result.json
        if let reqID = request["_reqID"] {
            fullResponse["_reqID"] = reqID
        }

        // Send response by polling again with the response body
        while isRunning {
            do {
                let nextRequest = try await fetchNextRequest(previousResponse: fullResponse)
                await processAndRespond(nextRequest)
                return
            } catch {
                print("[SwiftUITap] Response delivery error: \(error.localizedDescription). Retrying in 2s...")
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private static func resolveDeviceUDID() -> String? {
        let env = ProcessInfo.processInfo.environment

        if let simulatorUDID = trimmed(env["SIMULATOR_UDID"]) {
            return simulatorUDID
        }

        if let overrideUDID = trimmed(env["SWIFTUI_TAP_UDID"]) {
            return overrideUDID
        }

        return nil
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum PollerError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "invalid response from server"
        }
    }
}
