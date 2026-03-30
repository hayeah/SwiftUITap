import Foundation
import TapDispatchObjC

/// Dynamic get/set/call dispatch for any NSObject via KVC + ObjC runtime.
@MainActor
enum TapDynamic {

    // MARK: - Get

    /// Get a property (or snapshot) from an NSObject.
    /// - `key`: dot-separated path (empty = snapshot the object)
    /// - `depth`: 0 = shallow, N = recurse N levels into NSObject children
    static func get(_ obj: NSObject, key: String, depth: Int) -> TapResult {
        if key.isEmpty {
            var visited = [ObjectIdentifier: String]()
            let snapshot = TapCoerce.snapshotObject(obj, depth: 0, maxDepth: depth, visited: &visited)
            return .value(snapshot)
        }

        // Walk the dot path
        let segments = key.split(separator: ".", maxSplits: .max, omittingEmptySubsequences: true).map(String.init)
        var current: Any = obj

        for (i, segment) in segments.enumerated() {
            // Handle array indexing
            if let index = Int(segment) {
                guard let arr = current as? NSArray else {
                    return .error("expected array for index \(index), got \(type(of: current))")
                }
                guard index >= 0, index < arr.count else {
                    return .error("index out of bounds: \(index) (count: \(arr.count))")
                }
                current = arr[index]
                continue
            }

            guard let nsObj = current as? NSObject else {
                return .error("cannot traverse into \(type(of: current)) at segment '\(segment)'")
            }

            var val: Any? = nil
            do {
                try TapDispatch.tryCatch {
                    val = nsObj.value(forKey: segment)
                }
            } catch {
                return .error("KVC error on '\(segment)': \(error.localizedDescription)")
            }

            if let val {
                if i == segments.count - 1 {
                    var visited = [ObjectIdentifier: String]()
                    let coerced = TapCoerce.toJSON(val, depth: 0, maxDepth: depth, visited: &visited)
                    return .value(coerced)
                }
                current = val
            } else {
                return .value(NSNull())
            }
        }

        var visited = [ObjectIdentifier: String]()
        return .value(TapCoerce.toJSON(current, depth: 0, maxDepth: depth, visited: &visited))
    }

    // MARK: - Set

    /// Set a property on an NSObject via KVC.
    static func set(_ obj: NSObject, key: String, value: Any?) -> TapResult {
        guard !key.isEmpty else {
            return .error("cannot set on empty path")
        }

        let segments = key.split(separator: ".", maxSplits: .max, omittingEmptySubsequences: true).map(String.init)

        // Walk to the penultimate object
        var current: NSObject = obj
        for segment in segments.dropLast() {
            if let index = Int(segment) {
                guard let arr = current as? NSArray else {
                    return .error("expected array for index \(index)")
                }
                guard index >= 0, index < arr.count else {
                    return .error("index out of bounds: \(index)")
                }
                guard let next = arr[index] as? NSObject else {
                    return .error("array element is not NSObject")
                }
                current = next
                continue
            }

            var val: Any? = nil
            do {
                try TapDispatch.tryCatch {
                    val = current.value(forKey: segment)
                }
            } catch {
                return .error("cannot traverse to '\(segment)': \(error.localizedDescription)")
            }
            guard let next = val as? NSObject else {
                return .error("cannot traverse to '\(segment)': not an object")
            }
            current = next
        }

        let finalKey = segments.last!

        // Get type encoding for coercion
        var coercedValue = value
        if let encoding = TapCoerce.propertyEncoding(forKey: finalKey, on: type(of: current)) {
            coercedValue = TapCoerce.fromJSON(value, encoding: encoding)
        }

        do {
            try TapDispatch.tryCatch {
                current.setValue(coercedValue, forKey: finalKey)
            }
            return .value(nil)
        } catch {
            return .error("set '\(finalKey)' failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Call

    /// Call a method on an NSObject via ObjC runtime.
    static func call(_ obj: NSObject, method: String, params: [String: Any]) -> TapResult {
        guard !method.isEmpty else {
            return .error("empty method name")
        }

        do {
            let result: Any = try TapDispatch.call(obj, method: method, params: params)
            if !(result is NSNull) {
                var visited = [ObjectIdentifier: String]()
                return .value(TapCoerce.toJSON(result, depth: 0, maxDepth: 0, visited: &visited))
            }
            return .value(nil)
        } catch {
            return .error(error.localizedDescription)
        }
    }
}
