import Foundation
import TapDispatchObjC

/// JSON ↔ native coercion for KVC values.
enum TapCoerce {

    // MARK: - Property Filtering

    static func shouldSkip(_ name: String) -> Bool {
        if name.hasPrefix("_") { return true }
        if name.hasPrefix("accessibility") { return true }
        if name == "superclass" { return true }
        if name == "description" { return true }
        if name == "debugDescription" { return true }
        return false
    }

    // MARK: - To JSON

    /// Coerce a native KVC value to a JSON-safe representation.
    /// - `depth`: current recursion depth
    /// - `maxDepth`: 0 = shallow (NSObject children become __ref__ stubs)
    /// - `visited`: tracks object identity for cycle detection
    static func toJSON(_ value: Any?, depth: Int, maxDepth: Int, visited: inout [ObjectIdentifier: String]) -> Any {
        guard let value else { return NSNull() }
        if value is NSNull { return NSNull() }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n }

        if let arr = value as? [Any] {
            return arr.map { toJSON($0, depth: depth, maxDepth: maxDepth, visited: &visited) }
        }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[k] = toJSON(v, depth: depth, maxDepth: maxDepth, visited: &visited)
            }
            return out
        }

        if let nsValue = value as? NSValue, !(value is NSNumber) {
            return coerceNSValue(nsValue)
        }

        if let obj = value as? NSObject {
            return snapshotObject(obj, depth: depth, maxDepth: maxDepth, visited: &visited)
        }

        return String(describing: value)
    }

    // MARK: - NSValue Coercion

    static func coerceNSValue(_ nsValue: NSValue) -> Any {
        let enc = String(cString: nsValue.objCType)

        if enc.contains("CGRect") || enc.contains("NSRect") {
            let r = tapExtractRect(nsValue)
            return ["__type__": "CGRect", "__value__": [[r.origin.x, r.origin.y], [r.size.width, r.size.height]]] as [String: Any]
        }
        if enc.contains("CGPoint") || enc.contains("NSPoint") {
            let p = tapExtractPoint(nsValue)
            return ["__type__": "CGPoint", "__value__": [p.x, p.y]] as [String: Any]
        }
        if enc.contains("CGSize") || enc.contains("NSSize") {
            let s = tapExtractSize(nsValue)
            return ["__type__": "CGSize", "__value__": [s.width, s.height]] as [String: Any]
        }
        #if canImport(UIKit)
        if enc.contains("UIEdgeInsets") {
            let e = nsValue.uiEdgeInsetsValue
            return ["__type__": "UIEdgeInsets", "__value__": [e.top, e.left, e.bottom, e.right]] as [String: Any]
        }
        #endif
        #if canImport(AppKit)
        if enc.contains("NSEdgeInsets") {
            let e = nsValue.edgeInsetsValue
            return ["__type__": "NSEdgeInsets", "__value__": [e.top, e.left, e.bottom, e.right]] as [String: Any]
        }
        #endif
        if enc.contains("NSRange") || enc.contains("_NSRange") {
            let r = nsValue.rangeValue
            return ["__type__": "NSRange", "__value__": [r.location, r.length]] as [String: Any]
        }
        if enc.contains("CGAffineTransform") {
            let t = tapExtractAffineTransform(nsValue)
            return ["__type__": "CGAffineTransform", "__value__": [t.a, t.b, t.c, t.d, t.tx, t.ty]] as [String: Any]
        }

        return "<NSValue \(enc)>"
    }

    // MARK: - NSObject Snapshot

    static func ptrID(_ obj: NSObject) -> String {
        let ptr = Unmanaged.passUnretained(obj).toOpaque()
        return String(format: "%p", Int(bitPattern: ptr))
    }

    static func snapshotObject(_ obj: NSObject, depth: Int, maxDepth: Int, visited: inout [ObjectIdentifier: String]) -> Any {
        let oid = ObjectIdentifier(obj)
        let addr = ptrID(obj)
        let cls = String(describing: type(of: obj))

        // Cycle detection (deep mode only)
        if visited[oid] != nil {
            return ["__type__": cls, "__ref__": addr] as [String: Any]
        }

        // Depth limit: NSObject children become .description strings
        if depth > maxDepth {
            return obj.description
        }

        visited[oid] = addr

        var dict: [String: Any] = [:]
        dict["__type__"] = cls
        dict["__id__"] = addr

        let propertyNames = allPropertyNames(for: type(of: obj))
        for name in propertyNames {
            if shouldSkip(name) { continue }

            var val: Any? = nil
            do {
                try TapDispatch.tryCatch {
                    val = obj.value(forKey: name)
                }
                dict[name] = toJSON(val, depth: depth + 1, maxDepth: maxDepth, visited: &visited)
            } catch {
                // Skip properties that throw — silently
            }
        }

        return dict
    }

    // MARK: - Class Hierarchy

    /// Collect property names from the full class hierarchy, stopping at NSObject.
    static func allPropertyNames(for cls: AnyClass) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        var current: AnyClass? = cls

        while let c = current, c !== NSObject.self {
            for name in TapDispatch.propertyNames(for: c) {
                if seen.insert(name).inserted {
                    names.append(name)
                }
            }
            current = class_getSuperclass(c)
        }

        return names
    }

    // MARK: - From JSON (for set operations)

    /// Coerce a JSON value to native, guided by ObjC type encoding string.
    static func fromJSON(_ json: Any?, encoding: String) -> Any? {
        guard let json else { return nil }

        if encoding.contains("CGRect") || encoding.contains("NSRect") {
            guard let outer = json as? [[NSNumber]], outer.count == 2,
                  outer[0].count == 2, outer[1].count == 2 else { return json }
            let rect = CGRect(x: outer[0][0].doubleValue, y: outer[0][1].doubleValue,
                              width: outer[1][0].doubleValue, height: outer[1][1].doubleValue)
            return nsValueFromRect(rect)
        }
        if encoding.contains("CGPoint") || encoding.contains("NSPoint") {
            guard let arr = json as? [NSNumber], arr.count == 2 else { return json }
            let point = CGPoint(x: arr[0].doubleValue, y: arr[1].doubleValue)
            return nsValueFromPoint(point)
        }
        if encoding.contains("CGSize") || encoding.contains("NSSize") {
            guard let arr = json as? [NSNumber], arr.count == 2 else { return json }
            let size = CGSize(width: arr[0].doubleValue, height: arr[1].doubleValue)
            return nsValueFromSize(size)
        }

        // Pass through for primitives — KVC handles NSString/NSNumber
        return json
    }

    /// Get the ObjC type encoding for a property on a class.
    static func propertyEncoding(forKey key: String, on cls: AnyClass) -> String? {
        guard let prop = class_getProperty(cls, key) else { return nil }
        guard let attrs = property_getAttributes(prop) else { return nil }
        let str = String(cString: attrs)
        // Attribute string starts with "T<encoding>,"
        guard str.hasPrefix("T") else { return nil }
        let afterT = str.dropFirst(1)
        if let comma = afterT.firstIndex(of: ",") {
            return String(afterT[afterT.startIndex..<comma])
        }
        return String(afterT)
    }
}

// MARK: - Platform-specific NSValue helpers

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

private func tapExtractRect(_ v: NSValue) -> CGRect { v.rectValue }
private func tapExtractPoint(_ v: NSValue) -> CGPoint { v.pointValue }
private func tapExtractSize(_ v: NSValue) -> CGSize { v.sizeValue }
private func tapExtractAffineTransform(_ v: NSValue) -> CGAffineTransform {
    var t = CGAffineTransform.identity
    v.getValue(&t)
    return t
}
private func nsValueFromRect(_ r: CGRect) -> NSValue { NSValue(rect: r) }
private func nsValueFromPoint(_ p: CGPoint) -> NSValue { NSValue(point: p) }
private func nsValueFromSize(_ s: CGSize) -> NSValue { NSValue(size: s) }

#elseif canImport(UIKit)
import UIKit

private func tapExtractRect(_ v: NSValue) -> CGRect { v.cgRectValue }
private func tapExtractPoint(_ v: NSValue) -> CGPoint { v.cgPointValue }
private func tapExtractSize(_ v: NSValue) -> CGSize { v.cgSizeValue }
private func tapExtractAffineTransform(_ v: NSValue) -> CGAffineTransform { v.cgAffineTransformValue }
private func nsValueFromRect(_ r: CGRect) -> NSValue { NSValue(cgRect: r) }
private func nsValueFromPoint(_ p: CGPoint) -> NSValue { NSValue(cgPoint: p) }
private func nsValueFromSize(_ s: CGSize) -> NSValue { NSValue(cgSize: s) }
#endif
