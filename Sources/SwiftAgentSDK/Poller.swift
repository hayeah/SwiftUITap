import Foundation

/// Long-polls the agent server for requests and dispatches them on MainActor.
@MainActor
final class Poller {
    private let dispatcher: Dispatcher
    private let serverURL: URL
    private let session: URLSession
    private var isRunning = false

    init(state: NSObject, serverURL: URL) {
        self.dispatcher = Dispatcher(state: state)
        self.serverURL = serverURL
        // Use a long timeout for the poll request (5 minutes)
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
                // POST /poll with optional response body
                let request = try await fetchNextRequest(previousResponse: nil)
                await processAndRespond(request)
            } catch {
                // Connection error — retry after a short delay
                print("[AgentSDK] Poll error: \(error.localizedDescription). Retrying in 2s...")
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Fetch the next request from the server via long-poll.
    /// If previousResponse is provided, it's sent as the poll body (to deliver the response for the previous request).
    private func fetchNextRequest(previousResponse: [String: Any]?) async throws -> [String: Any] {
        let pollURL = serverURL.appendingPathComponent("poll")
        var urlRequest = URLRequest(url: pollURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

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

    /// Dispatch the request on MainActor and send the response back.
    private func processAndRespond(_ request: [String: Any]) async {
        // Dispatch on MainActor (we're already on MainActor)
        let response = dispatcher.dispatch(request)

        // Include the request ID in the response
        var fullResponse = response
        if let id = request["id"] {
            fullResponse["id"] = id
        }

        // Send response by polling again with the response body
        while isRunning {
            do {
                let nextRequest = try await fetchNextRequest(previousResponse: fullResponse)
                // Got next request — process it
                await processAndRespond(nextRequest)
                return
            } catch {
                print("[AgentSDK] Response delivery error: \(error.localizedDescription). Retrying in 2s...")
                try? await Task.sleep(for: .seconds(2))
            }
        }
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
