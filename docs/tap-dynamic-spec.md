---
overview: Design spec for TapDynamic — automatic JSON-based get/set/call dispatch for any NSObject in the SwiftUITap state tree, using KVC and ObjC runtime. No opt-in protocol needed.
repo: ~/github.com/hayeah/SwiftUITap
tags:
  - spec
---

# TapDynamic: NSObject Dynamic Dispatch for SwiftUITap

## Problem

`TapWindowStore` is a hand-written switch table mapping JSON get/set/call to `NSWindow` properties and methods. Every new property or method requires editing the switch. We want any NSObject in the state tree to be automatically drivable — no explicit conformance, no allowlists.

## Design Principle

This is a **debug tool**. Expose everything by default. No opt-in protocol. If an object in the state tree is an `NSObject`, use KVC for get/set and ObjC runtime for call. The existing `@SwiftUITap` macro dispatch takes priority; dynamic dispatch is the fallback.

## Core: JSON ↔ `[String: Any]` ↔ KVC/ObjC Runtime

JSON and KVC already share the same intermediate representation: `[String: Any]` dictionaries with plist-compatible leaf types. The conversion chain:

```
JSON string ←→ [String: Any] ←→ KVC / NSInvocation
```

Plist-compatible types pass through untouched:
- `NSString` ↔ JSON string
- `NSNumber` ↔ JSON number / bool
- `NSArray` ↔ JSON array
- `NSDictionary` ↔ JSON object
- `NSNull` / `nil` ↔ JSON null

Struct-in-NSValue types: use Swift's stdlib `Codable` conformances via `JSONEncoder`/`JSONDecoder`. The stdlib uses positional arrays — compact and canonical:
- `CGRect` → `[[x, y], [w, h]]` (nested: `[CGPoint, CGSize]`)
- `CGPoint` → `[x, y]`
- `CGSize` → `[w, h]`
- `CGAffineTransform` → `[a, b, c, d, tx, ty]`

Types not `Codable` out of the box (e.g. `NSEdgeInsets`): add a small `Codable` extension, or fall back to `.description`.

The only registry needed maps ObjC encoding string → NSValue extract function:
```swift
// encoding → (NSValue) -> Encodable
"{CGRect={CGPoint=dd}{CGSize=dd}}"  → { $0.rectValue }
"{CGPoint=dd}"                       → { $0.pointValue }
"{CGSize=dd}"                        → { $0.sizeValue }
```
All actual serialization is handled by stdlib `Codable`. The agent knows these types — provide a reference doc listing the JSON encoding for common types.

## Dispatch Flow

```
JSON request
  → Dispatcher.dispatch()
    → 1. dot-prefix builtins (.windows, etc.)
    → 2. TapDispatchable (macro-generated, type-safe)
    → 3. NEW: NSObject dynamic dispatch (KVC + runtime)
    → 4. error
```

Step 3 kicks in when a path resolves to an object that is an `NSObject` but not a `TapDispatchable`. No protocol conformance check — just `is NSObject`.

## Operations

### Get: KVC `value(forKey:)`

```swift
let obj: NSObject = ...  // e.g. NSWindow
let val = obj.value(forKey: "title")  // → NSString
return .value(coerceToJSON(val))
```

For dot paths, walk each segment with `value(forKey:)`:
- `window.frame` → `value(forKey: "frame")` → NSValue(CGRect) → `{"__type__": "CGRect", "__value__": [[x,y],[w,h]]}`
- `window.screen.visibleFrame` → walk `screen`, then `visibleFrame`

### Set: KVC `setValue(_:forKey:)`

```swift
obj.setValue(coerceFromJSON(jsonVal, key: key), forKey: key)
```

Reverse coercion for struct types:
- `[[0, 0], [800, 600]]` + target expects `CGRect` → `JSONDecoder.decode(CGRect.self)` → `NSValue(rect:)`

Use `objc_property_t` attribute string to determine the expected type for the key, then coerce via `Codable`.

### Call: ObjC Runtime (existing `AgentDispatch`)

Already implemented in `AgentDispatchObjC/AgentDispatch.m`:

```swift
let result = try AgentDispatch.call(obj, method: methodName, params: params)
return .value(coerceToJSON(result))
```

Handles: selector resolution, param name extraction from selectors, type coercion for int/double/float/bool/object args and returns.

### Snapshot

**Do NOT use `dictionaryWithValues(forKeys:)`** — it crashes on properties that aren't truly KVC-compliant (e.g. `NSScreen.supportedWindowDepths`). Instead, loop individually and catch exceptions:

```swift
func safeDictionaryWithValues(_ obj: NSObject, forKeys keys: [String]) -> [String: Any] {
    var dict: [String: Any] = [:]
    for key in keys {
        do {
            let val = try ObjC.catching { obj.value(forKey: key) }
            dict[key] = coerceToJSON(val)
        } catch {
            // skip — property not KVC-compliant
        }
    }
    return dict
}
```

To get the key list, use `class_copyPropertyList` from the ObjC runtime. Filter out `_`-prefixed properties.

### List Methods

Already implemented: `AgentDispatch.callableMethodNames(_:)` filters out NSObject base methods, setters, and underscored methods. Expose via a special path like `__methods__` or include in snapshot.

## Type Coercion Examples

### NSWindow (macOS)

```bash
# Get — primitives return bare values
swiftui-tap state get .windows.0.title        → "My App"
swiftui-tap state get .windows.0.isVisible     → true

# Get — structs return typed wrappers
swiftui-tap state get .windows.0.frame
→ {"__type__": "CGRect", "__value__": [[100, 200], [800, 600]]}

# Snapshot — shallow, NSObject children are __ref__ stubs
swiftui-tap state get .windows.0
→ {"__type__": "NSWindow", "__id__": "0x...", "title": "My App",
   "frame": {"__type__": "CGRect", "__value__": [[100,200],[800,600]]},
   "screen": {"__type__": "NSScreen", "__ref__": "0x..."},
   ...}

# Snapshot — deep
swiftui-tap state get .windows.0 --depth 3

# Set — KVC
swiftui-tap state set .windows.0.title '"New Title"'

# Call — ObjC runtime
swiftui-tap state call .windows.0.toggleFullScreen '{}'
swiftui-tap state call .windows.0.center '{}'
```

This replaces the entire `TapWindowStore` switch table.

### Traversal

```bash
# Multi-hop KVC traversal
swiftui-tap state get .windows.0.screen.visibleFrame
→ {"__type__": "CGRect", "__value__": [[0, 0], [1920, 1055]]}

swiftui-tap state get .windows.0.contentView.frame
→ {"__type__": "CGRect", "__value__": [[0, 0], [800, 572]]}

# Primitives at any depth
swiftui-tap state get .windows.0.screen.backingScaleFactor → 2
```

## NSValue Coercion Table

Uses stdlib `Codable` (positional arrays). Registry maps ObjC encoding → extract + Swift type.

| ObjC type encoding | Swift type | JSON (stdlib Codable) |
|---|---|---|
| `{CGRect={CGPoint=dd}{CGSize=dd}}` | `CGRect` | `[[x,y],[w,h]]` |
| `{CGPoint=dd}` | `CGPoint` | `[x,y]` |
| `{CGSize=dd}` | `CGSize` | `[w,h]` |
| `{CGAffineTransform=dddddd}` | `CGAffineTransform` | `[a,b,c,d,tx,ty]` |

Non-Codable types (`NSEdgeInsets`, etc.): add `Codable` extension or fall back to `.description`.

Unrecognized `NSValue` subtypes → return `.description` string as fallback.

## Coercion Module: `TapCoerce`

Single place for JSON ↔ native conversion. Delegates to stdlib `Codable` for struct types.

```swift
enum TapCoerce {
    /// Native (KVC result) → JSON-safe value
    /// - plist primitives (NSString, NSNumber, NSArray, NSDictionary, NSNull): pass through
    /// - NSValue: look up ObjC encoding in registry, extract struct, JSONEncoder.encode()
    /// - NSDate: ISO8601 string
    /// - NSData: base64 string
    /// - unknown: .description fallback
    static func toJSON(_ value: Any?) -> Any? { ... }

    /// JSON value → native, guided by ObjC type encoding string
    /// - For NSValue struct types: JSONDecoder.decode(T.self), wrap in NSValue
    /// - Everything else: pass through (KVC handles NSString/NSNumber/etc.)
    static func fromJSON(_ json: Any?, encoding: String) -> Any? { ... }
}
```

## What Gets Replaced

- `TapWindowStore.swift` — entire file. Window dispatch becomes just a `resolveWindow` helper that returns an `NSObject`, then dynamic dispatch handles the rest.
- The `.windows` prefix in `dispatchBuiltin` routes to the dynamic dispatcher instead.

## What Stays the Same

- `TapDispatchable` / `@SwiftUITap` macro — still the primary dispatch for user's `@Observable` state classes. Type-safe, compile-time generated.
- `AgentDispatchObjC` — reused as-is for method calls.
- `Dispatcher.swift` — gains one new fallback branch.

## Traversal and Snapshot Policy

**Explicit-path get**: allow unlimited depth. Each segment is one `value(forKey:)` call. If the result is an NSObject, keep walking. Wrap each hop in ObjC `@try/@catch` — if a key isn't KVC-compliant, return an error rather than crashing.

```
.windows.0.screen.visibleFrame   →  3 hops, all fine
.windows.0.screen.frame.origin   →  screen → CGRect (NSValue) → can't KVC into NSValue → error
```

### Type tagging

Every non-primitive value carries a `__type__` tag so the agent always knows what it's looking at.

**Primitives** (string, number, bool, null): bare values, no wrapper.

**NSValue structs**: wrapped with type and value:
```json
"frame": {"__type__": "CGRect", "__value__": [[100, 200], [800, 600]]}
"center": {"__type__": "CGPoint", "__value__": [196.5, 448]}
"contentSize": {"__type__": "CGSize", "__value__": [393, 2400]}
```

**NSObjects**: tagged with type and id:
```json
"screen": {"__type__": "NSScreen", "__id__": "0x600001234568", "frame": ..., ...}
```

**Refs** (cycle or shallow boundary):
```json
"window": {"__type__": "NSWindow", "__ref__": "0x600001234567"}
```

### Shallow Snapshot (default)

Serialize one level of the object's own properties. At NSObject boundaries, emit a `__ref__` stub. The agent can follow up with an explicit path to go deeper.

### Deep Snapshot (opt-in: `--depth N`)

Recursively expand NSObject children up to N levels. Every NSObject gets an `__id__` on first visit. On revisit (cycle) or depth limit, emit `__ref__`.

```bash
# Shallow (default)
swiftui-tap state get .windows.0

# Deep
swiftui-tap state get .windows.0 --depth 5
```

Wire format:
```json
{"type": "get", "path": ".windows.0", "depth": 5}
```

### Example

```json
{
  "__type__": "NSWindow",
  "__id__": "0x600001234567",
  "title": "My App",
  "frame": {"__type__": "CGRect", "__value__": [[100, 200], [800, 600]]},
  "isVisible": true,
  "screen": {
    "__type__": "NSScreen",
    "__id__": "0x600001234568",
    "frame": {"__type__": "CGRect", "__value__": [[0, 0], [1920, 1080]]},
    "backingScaleFactor": 2
  },
  "contentView": {
    "__type__": "NSView",
    "__id__": "0x60000abcdef0",
    "frame": {"__type__": "CGRect", "__value__": [[0, 0], [800, 572]]},
    "window": {"__type__": "NSWindow", "__ref__": "0x600001234567"}
  }
}
```

### Property filtering

Skip these properties from snapshots:
- `_`-prefixed (private)
- `accessibility*` (noisy, rarely useful for agents)
- `superclass` (class object, not an instance property)
- `description`, `debugDescription` (redundant with the snapshot itself)

### Implementation

- Track visited objects by pointer address (`Unmanaged.passUnretained(obj).toOpaque()`)
- On revisit or depth limit, emit `__ref__` stub
- Wrap each `value(forKey:)` in ObjC `@try/@catch` — skip properties that throw

### Coercion rules

- Primitives (`NSString`, `NSNumber`, `NSNull`): inline, no wrapper
- `NSValue` structs: `{"__type__": "<struct name>", "__value__": <Codable output>}`
- Plist collections (`NSArray`, `NSDictionary`): inline (recurse into elements)
- `NSObject` subclasses: `{"__type__": "<class>", "__id__": "<addr>", ...}` or `{"__type__": "<class>", "__ref__": "<addr>"}`

## Dot-Prefix Builtins

System objects accessible via `.` prefix, resolved to NSObjects then handled by dynamic dispatch.

### macOS

| Path | Object | Notes |
|---|---|---|
| `.app` | `NSApplication.shared` | activation, appearance, mainMenu |
| `.windows` | `NSApplication.shared.windows` | already implemented |
| `.screens` | `NSScreen.screens` | display geometry, scale |
| `.pasteboard` | `NSPasteboard.general` | clipboard read/write |
| `.workspace` | `NSWorkspace.shared` | open URLs, running apps |
| `.defaults` | `UserDefaults.standard` | app preferences |
| `.bundle` | `Bundle.main` | app info, resources |
| `.process` | `ProcessInfo.processInfo` | env vars, hostname, memory |

### iOS

| Path | Object | Notes |
|---|---|---|
| `.app` | `UIApplication.shared` | badge, state, idle timer |
| `.windows` | active scene's windows | window hierarchy |
| `.screen` | `UIScreen.main` | bounds, scale, brightness |
| `.pasteboard` | `UIPasteboard.general` | clipboard |
| `.defaults` | `UserDefaults.standard` | app preferences |
| `.bundle` | `Bundle.main` | app info |
| `.process` | `ProcessInfo.processInfo` | env, thermal state |
| `.device` | `UIDevice.current` | model, OS version, battery |

All NSObject subclasses — dynamic dispatch handles them automatically. Just need a routing table from prefix → object.

## Open Questions

- **Non-NSValue, non-plist objects**: `UIFont`, `UIColor`, etc. — fall back to `.description`. Good enough for debug?
- **NSEdgeInsets**: not `Codable` out of the box. Add extension or handle in the registry alongside the NSValue struct types?

## Prototype

Working ObjC prototype at `~/Dropbox/notes/2026-03-30/tmp/101607.876-typed_dump.m` — demonstrates shallow/deep snapshots with `__type__`/`__id__`/`__ref__` tagging, property filtering, and cycle detection. Sample outputs:

- `screen_typed_shallow.json` — NSScreen, 101 lines
- `window_typed_shallow.json` — NSWindow, 292 lines (down from 440 after filtering `accessibility*`)
- `window_typed_deep.json` — NSWindow depth 3, 580 lines with cycle refs
