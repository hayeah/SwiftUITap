import Foundation

/// Routes get/set/call operations to the AgentDispatchable state tree.
struct Dispatcher {
    let state: any AgentDispatchable

    @MainActor
    func dispatch(_ request: [String: Any]) -> AgentResult {
        guard let type = request["type"] as? String else {
            return .error("missing 'type' field")
        }

        switch type {
        case "get":
            guard let path = request["path"] as? String else {
                return .error("missing 'path' for get")
            }
            if path == "." { return .value(state.__agentSnapshot()) }
            return state.__agentGet(path)

        case "set":
            guard let path = request["path"] as? String else {
                return .error("missing 'path' for set")
            }
            return state.__agentSet(path, value: request["value"])

        case "call":
            guard let method = request["method"] as? String else {
                return .error("missing 'method' for call")
            }
            let params = request["params"] as? [String: Any] ?? [:]
            return state.__agentCall(method, params: params)

        default:
            return .error("unknown type: \(type)")
        }
    }
}
