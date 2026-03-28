import Foundation
import AgentDispatchObjC

/// Handles get/set/call operations on the state tree.
struct Dispatcher {
    let state: NSObject

    /// Dispatch a request and return the response dictionary.
    @MainActor
    func dispatch(_ request: [String: Any]) -> [String: Any] {
        guard let type = request["type"] as? String else {
            return ["error": "missing 'type' field"]
        }

        switch type {
        case "get":
            return handleGet(request)
        case "set":
            return handleSet(request)
        case "call":
            return handleCall(request)
        default:
            return ["error": "unknown type: \(type)"]
        }
    }

    // MARK: - Get

    private func handleGet(_ request: [String: Any]) -> [String: Any] {
        guard let path = request["path"] as? String else {
            return ["error": "missing 'path' for get"]
        }

        do {
            let value = try getValue(at: path)
            return ["data": serialize(value)]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    private func getValue(at path: String) throws -> Any? {
        // Handle empty path — return description of root
        if path.isEmpty {
            return serialize(state)
        }

        // Use KVC for dot-path traversal
        // Handle array index access: "items.0.name" → items[0].name
        let components = path.split(separator: ".").map(String.init)
        var current: Any = state

        for component in components {
            if let index = Int(component) {
                // Array index access
                if let array = current as? NSArray {
                    guard index >= 0 && index < array.count else {
                        throw DispatchError.invalidPath("index \(index) out of bounds (count: \(array.count))")
                    }
                    current = array[index]
                } else {
                    throw DispatchError.invalidPath("'\(component)' is not an array index")
                }
            } else if let obj = current as? NSObject {
                // KVC property access
                guard let value = obj.value(forKey: component) else {
                    return nil
                }
                current = value
            } else {
                throw DispatchError.invalidPath("cannot traverse into \(type(of: current))")
            }
        }

        return current
    }

    // MARK: - Set

    private func handleSet(_ request: [String: Any]) -> [String: Any] {
        guard let path = request["path"] as? String else {
            return ["error": "missing 'path' for set"]
        }

        let value = request["value"] // Can be nil (setting to null)

        do {
            try setValue(value, at: path)
            return ["data": NSNull()]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    private func setValue(_ value: Any?, at path: String) throws {
        let components = path.split(separator: ".").map(String.init)
        guard !components.isEmpty else {
            throw DispatchError.invalidPath("empty path")
        }

        if components.count == 1 {
            // Direct property on root
            state.setValue(value, forKey: components[0])
            return
        }

        // Navigate to parent, then set on the last component
        let parentPath = components.dropLast()
        let lastKey = components.last!
        var current: Any = state

        for component in parentPath {
            if let index = Int(component) {
                if let array = current as? NSArray {
                    guard index >= 0 && index < array.count else {
                        throw DispatchError.invalidPath("index \(index) out of bounds")
                    }
                    current = array[index]
                } else {
                    throw DispatchError.invalidPath("'\(component)' is not an array index")
                }
            } else if let obj = current as? NSObject {
                guard let val = obj.value(forKey: component) else {
                    throw DispatchError.invalidPath("property '\(component)' is nil")
                }
                current = val
            } else {
                throw DispatchError.invalidPath("cannot traverse into \(type(of: current))")
            }
        }

        // Set the final property
        if let index = Int(lastKey) {
            if let array = current as? NSMutableArray {
                guard index >= 0 && index < array.count else {
                    throw DispatchError.invalidPath("index \(index) out of bounds")
                }
                array[index] = value ?? NSNull()
            } else {
                throw DispatchError.invalidPath("cannot set index on non-mutable-array")
            }
        } else if let obj = current as? NSObject {
            obj.setValue(value, forKey: lastKey)
        } else {
            throw DispatchError.invalidPath("cannot set property on \(type(of: current))")
        }
    }

    // MARK: - Call

    private func handleCall(_ request: [String: Any]) -> [String: Any] {
        guard let method = request["method"] as? String else {
            return ["error": "missing 'method' for call"]
        }

        let params = request["params"] as? NSDictionary ?? NSDictionary()

        do {
            let result = try AgentDispatch.call(state, method: method, params: params as! [String: Any])
            return ["data": serialize(result)]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    // MARK: - Serialization

    /// Convert a value to something JSON-serializable.
    private func serialize(_ value: Any?) -> Any {
        guard let value else { return NSNull() }

        switch value {
        case is NSNull:
            return NSNull()
        case let n as NSNumber:
            return n
        case let s as String:
            return s
        case let arr as NSArray:
            return arr.map { serialize($0) }
        case let dict as NSDictionary:
            var result: [String: Any] = [:]
            for (k, v) in dict {
                if let key = k as? String {
                    result[key] = serialize(v)
                }
            }
            return result
        case let obj as NSObject:
            return serializeObject(obj)
        default:
            return String(describing: value)
        }
    }

    /// Serialize an NSObject by reading its @objc dynamic properties via KVC.
    private func serializeObject(_ obj: NSObject) -> [String: Any] {
        var result: [String: Any] = [:]
        var propertyCount: UInt32 = 0
        guard let properties = class_copyPropertyList(type(of: obj), &propertyCount) else {
            return result
        }
        defer { free(properties) }

        for i in 0..<Int(propertyCount) {
            let name = String(cString: property_getName(properties[i]))
            // Skip internal properties
            if name.hasPrefix("_") && name != "__doc__" { continue }
            if name == "hash" || name == "superclass" || name == "description" || name == "debugDescription" { continue }

            if let value = obj.value(forKey: name) {
                result[name] = serialize(value)
            } else {
                result[name] = NSNull()
            }
        }

        return result
    }
}

enum DispatchError: LocalizedError {
    case invalidPath(String)

    var errorDescription: String? {
        switch self {
        case .invalidPath(let msg): return "invalid path: \(msg)"
        }
    }
}
