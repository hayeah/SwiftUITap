import Foundation

/// Routes get/set/call operations to the TapDispatchable state tree.
struct Dispatcher {
    let state: any TapDispatchable

    @MainActor
    func dispatch(_ request: [String: Any]) async -> TapResult {
        // Intercept .kif.* commands for touch synthesis
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        if let result = dispatchKIF(request) {
            return result
        }
        #endif

        // Intercept dot-prefixed paths for built-in system objects
        if let result = dispatchBuiltin(request) {
            return result
        }

        guard let type = request["type"] as? String else {
            return .error("missing 'type' field")
        }

        switch type {
        case "get":
            guard let path = request["path"] as? String else {
                return .error("missing 'path' for get")
            }
            if path == "." { return .value(state.__tapSnapshot()) }
            return state.__tapGet(path)

        case "set":
            guard let path = request["path"] as? String else {
                return .error("missing 'path' for set")
            }
            return state.__tapSet(path, value: request["value"])

        case "call":
            guard let method = request["method"] as? String else {
                return .error("missing 'method' for call")
            }
            let params = request["params"] as? [String: Any] ?? [:]
            return state.__tapCall(method, params: params)

        case "eval":
            guard let code = request["code"] as? String else {
                return .error("missing 'code' for eval")
            }
            let tag = request["tag"] as? String
            return await TapWebViewStore.shared.eval(tag: tag, code: code)

        default:
            return .error("unknown type: \(type)")
        }
    }

    /// Route .kif.* commands to KIF touch synthesis.
    #if canImport(UIKit) && !targetEnvironment(macCatalyst)
    @MainActor
    private func dispatchKIF(_ request: [String: Any]) -> TapResult? {
        let type = request["type"] as? String ?? ""
        guard type == "call" else { return nil }

        let method = request["method"] as? String ?? ""
        guard method.hasPrefix(".kif.") else { return nil }

        let command = String(method.dropFirst(".kif.".count))
        let params = request["params"] as? [String: Any] ?? [:]
        return TapKIF.dispatch(command, params: params)
    }
    #endif

    /// Route dot-prefixed paths to built-in system objects via dynamic dispatch.
    @MainActor
    private func dispatchBuiltin(_ request: [String: Any]) -> TapResult? {
        let type = request["type"] as? String ?? ""
        let path = (type == "call")
            ? request["method"] as? String
            : request["path"] as? String

        guard let path, path.hasPrefix("."), path != "." else { return nil }

        guard let (obj, tail) = TapBuiltins.resolve(path) else {
            return .error("unknown system path: \(path)")
        }

        let depth = request["depth"] as? Int ?? 0

        switch type {
        case "get":
            return TapDynamic.get(obj, key: tail ?? "", depth: depth)
        case "set":
            return TapDynamic.set(obj, key: tail ?? "", value: request["value"])
        case "call":
            let params = request["params"] as? [String: Any] ?? [:]
            return TapDynamic.call(obj, method: tail ?? "", params: params)
        default:
            return .error("unknown type: \(type)")
        }
    }
}
