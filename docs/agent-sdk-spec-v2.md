---
overview: "Design spec for SwiftAgentSDK v2: uses an @AgentSDK Swift macro instead of @objc dynamic + KVC. Generates AgentDispatchable conformance at compile time. Pure Swift — no NSObject, no KVC, no NSInvocation. Works cleanly with @Observable and SwiftUI."
tags:
  - spec
---

# SwiftAgentSDK v2 — `@AgentSDK` Macro Approach

## Goal

Same as v1: a drop-in Swift package that makes any SwiftUI app agent-drivable via `get`/`set`/`call` over HTTP long-poll. But instead of relying on the ObjC runtime, v2 uses a Swift macro to generate dispatch tables at compile time.

---

## Why Not `@objc dynamic` + KVC (v1 Post-Mortem)

The v1 approach required `NSObject` inheritance + `@objc dynamic` on every property. This conflicts with `@Observable`:

- **`@Observable` and `@objc dynamic` are two separate observation systems.** `@Observable` tracks changes by intercepting the property setter (macro-generated computed property). `@objc dynamic` uses ObjC runtime isa-swizzling for KVO. Using both on the same property creates ambiguity — neither system reliably sees the other's mutations.

- **`NSMutableArray` mutations are invisible to `@Observable`.** KVC requires `NSMutableArray` for indexed access (`items.0.name`). But `NSMutableArray.add()` mutates in place without calling the property setter, so `@Observable` never fires. Even reassigning the property (`todos = NSMutableArray(array: todos)`) didn't trigger SwiftUI updates. **Confirmed experimentally:** fixing the `@State` init() bug (using a shared global instance) still didn't make the UI update — the `NSMutableArray` + `@Observable` conflict is real, not a misdiagnosis.

- **`@State` init() bug compounds the problem.** Accessing `@State` properties in the App struct's `init()` gives you a throwaway instance — SwiftUI may create multiple struct instances and the `@State` storage isn't wired up during init. The poller ends up mutating a different object than the one SwiftUI renders. Fix: use a global `let` instance or wire up in `.onAppear`.

- **ObjC type constraints leak into app code.** Arrays must be `NSMutableArray`, methods must return `NSDictionary?`, enums need `rawValue` wrappers. The app author writes ObjC-shaped Swift instead of idiomatic Swift.

**Bottom line:** `@objc dynamic` gives you free string-based dispatch, but it's fundamentally incompatible with `@Observable`. Since `@Observable` is the future of SwiftUI state management, the SDK needs to work *with* it, not against it.

---

## Coding Convention

The macro only processes declarations it can fully understand from syntax alone. **Explicit type annotations are required** — if the macro can't determine the type, the property or method is silently skipped (not agent-accessible).

### Properties

Every agent-exposed property **must** have an explicit type annotation:

```swift
@AgentSDK
@Observable
final class AppState {
    // SUPPORTED — explicit type annotation on all of these
    var counter: Int = 0
    var label: String = "hello"
    var darkMode: Bool = false
    var ratio: Double = 1.0
    var name: String? = nil
    var todos: [TodoItem] = []
    var tags: [String] = []
    var settings: SettingsState = SettingsState()

    // SKIPPED — no type annotation, macro can't determine type
    var settings = SettingsState()
    var count = 0
    var items = [TodoItem]()

    // SKIPPED — complex/generic types the macro doesn't handle
    var lookup: [String: TodoItem] = [:]
    var result: Result<String, Error> = .success("")
    var callback: (() -> Void)? = nil
}
```

**Supported property types:**

| Type annotation | Category | `agentGet` | `agentSet` | Notes |
|---|---|---|---|---|
| `String`, `Int`, `Double`, `Bool` | Primitive | yes | yes | Direct JSON mapping |
| `String?`, `Int?`, etc. | Optional primitive | yes | yes | nil ↔ JSON null |
| `[T]` | Array | yes | no (use methods) | `T` can be primitive or class |
| Any other single identifier (e.g. `SettingsState`) | Child state | yes | delegate | Runtime `as? AgentDispatchable` |
| `let` properties | Constant | yes | no | Read-only |
| Computed properties (no `=`) | Computed | yes | no | Read-only |
| Everything else | — | skipped | skipped | No error, just invisible |

### Methods

Every agent-exposed method **must** have labeled parameters with supported types:

```swift
@AgentSDK
@Observable
final class AppState {
    // SUPPORTED — labeled params, primitive types
    func addTodo(title: String) -> [String: Any]? { ... }
    func toggleTodo(index: Int) { ... }
    func loadBook(bookID: String, chapter: Int) -> [String: Any]? { ... }
    func setVolume(level: Double) { ... }
    func reset() { ... }  // zero params is fine

    // SKIPPED — unlabeled param
    func process(_ items: [TodoItem]) { ... }

    // SKIPPED — non-primitive param type
    func configure(opts: MyStruct) { ... }

    // SKIPPED — private
    private func internalHelper() { ... }
}
```

**Supported parameter types:** `String`, `Int`, `Double`, `Bool`

**Return types:** anything JSON-serializable, or `Void`. Void methods return `.value(nil)`.

**Skipped methods:**
- `private` or `fileprivate`
- `static` or `class` methods
- `init`, `deinit`
- Any param without a label (uses `_`)
- Any param whose type annotation is not in the supported set
- Property accessors

**Skipping is silent.** No compile error, no warning. The method just won't appear in `agentCall` dispatch. To verify what's exposed, the agent reads `__doc__`.

### Macro Type Resolution

The macro matches type annotation tokens as literal strings:

```
"String"           → primitive, cast: as? String
"Int"              → primitive, cast: (as? NSNumber)?.intValue
"Double"           → primitive, cast: (as? NSNumber)?.doubleValue
"Bool"             → primitive, cast: (as? NSNumber)?.boolValue
"String?"          → optional primitive (same cast, nil-safe)
"Int?", etc.       → optional primitive
"[Foo]"            → array of Foo (Foo resolved recursively)
"[String]"         → array of primitives
any other ident    → assume class, use as? AgentDispatchable at runtime
missing            → skip entirely
```

No type inference. No type alias resolution. No cross-file lookups. Just string matching on the annotation token.

---

## Core Concepts

### `@AgentSDK` Macro

An attached macro that generates `AgentDispatchable` conformance. The app author writes normal `@Observable` classes — no NSObject, no `@objc`, no special types. All properties must have explicit type annotations:

```swift
import SwiftAgentSDK

@AgentSDK
@Observable
final class AppState {
    var counter: Int = 0
    var label: String = "hello"
    var settings: SettingsState = SettingsState()
    var todos: [TodoItem] = []

    var __doc__: String {
        """
        AppState — root of the global state tree
        ...
        """
    }

    func addTodo(title: String) -> [String: Any]? {
        let item = TodoItem(title: title)
        todos.append(item)
        return ["index": todos.count - 1]
    }

    func toggleTodo(index: Int) {
        guard index >= 0 && index < todos.count else { return }
        todos[index].isCompleted.toggle()
    }
}

@AgentSDK
@Observable
final class SettingsState {
    var darkMode: Bool = false
    var fontSize: Int = 16
}

@AgentSDK
@Observable
final class TodoItem {
    var title: String
    var isCompleted: Bool = false

    init(title: String) {
        self.title = title
    }
}
```

The macro generates an extension with three methods: `__agentGet`, `__agentSet`, `__agentCall`. The `__` prefix avoids collisions with app methods. No runtime reflection — all dispatch is compiled switch tables.

### What the Macro Generates

```swift
// Generated for AppState:
extension AppState: AgentDispatchable {
    func __agentGet(_ path: String) -> AgentResult {
        let (head, tail) = AgentPath.split(path)
        switch head {
        case "__doc__": return .value(__doc__)
        case "counter": return .value(counter)
        case "label": return .value(label)
        case "settings":
            guard let tail else { return .error("settings requires a sub-path") }
            return (settings as? AgentDispatchable)?.__agentGet(tail) ?? .error("not dispatchable: settings")
        case "todos":
            guard let tail else { return .error("todos requires an index path") }
            let (indexStr, rest) = AgentPath.split(tail)
            guard let index = Int(indexStr), index >= 0, index < todos.count else {
                return .error("index out of bounds: \(indexStr)")
            }
            guard let rest else { return .error("todos.\(index) requires a sub-path") }
            return (todos[index] as? AgentDispatchable)?.__agentGet(rest) ?? .error("not dispatchable: todos[]")
        default: return .error("unknown property: \(head)")
        }
    }

    func __agentSet(_ path: String, value: Any?) -> AgentResult {
        let (head, tail) = AgentPath.split(path)
        switch head {
        case "counter":
            guard let v = value as? Int else { return .error("type mismatch: counter expects Int") }
            counter = v
            return .value(nil)
        case "label":
            guard let v = value as? String else { return .error("type mismatch") }
            label = v
            return .value(nil)
        case "settings":
            guard let tail else { return .error("cannot replace settings object") }
            return (settings as? AgentDispatchable)?.__agentSet(tail, value: value) ?? .error("not dispatchable")
        case "todos":
            guard let tail else { return .error("cannot replace todos array") }
            let (indexStr, rest) = AgentPath.split(tail)
            guard let index = Int(indexStr), index >= 0, index < todos.count else {
                return .error("index out of bounds")
            }
            guard let rest else { return .error("cannot replace array element") }
            return (todos[index] as? AgentDispatchable)?.__agentSet(rest, value: value) ?? .error("not dispatchable")
        default: return .error("unknown property: \(head)")
        }
    }

    func __agentCall(_ method: String, params: [String: Any]) -> AgentResult {
        switch method {
        case "addTodo":
            guard let title = params["title"] as? String else {
                return .error("missing param: title (String)")
            }
            let result = addTodo(title: title)
            return .value(result as Any)
        case "toggleTodo":
            guard let index = (params["index"] as? NSNumber)?.intValue else {
                return .error("missing param: index (Int)")
            }
            toggleTodo(index: index)
            return .value(nil)
        default: return .error("unknown method: \(method)")
        }
    }
}
```

### `AgentDispatchable` Protocol

```swift
public protocol AgentDispatchable: AnyObject {
    func __agentGet(_ path: String) -> AgentResult
    func __agentSet(_ path: String, value: Any?) -> AgentResult
    func __agentCall(_ method: String, params: [String: Any]) -> AgentResult
    /// Return all properties as a JSON-serializable dictionary.
    func __agentSnapshot() -> [String: Any]
}

public enum AgentResult {
    case value(Any?)  // success — nil means void/no data
    case error(String)
}
```

The Dispatcher supports `get "."` to snapshot the root state object via `__agentSnapshot()`.

---

## Nested State Traversal

The key insight: the macro doesn't need cross-file type information. It uses a **runtime protocol check** to delegate traversal.

When the macro sees `var settings: SettingsState`, it generates code that checks at runtime whether the value conforms to `AgentDispatchable`:

```swift
case "settings":
    guard let tail else {
        return .value((settings as? AgentDispatchable)?.__agentSnapshot())
    }
    return (settings as? AgentDispatchable)?.__agentGet(tail) ?? .error("not dispatchable: settings")
```

If `SettingsState` has `@AgentSDK`, it conforms and traversal works. If it doesn't, the snapshot/traversal returns nil.

This means:
- `get "settings.darkMode"` → splits to `("settings", "darkMode")`, delegates to `SettingsState.__agentGet("darkMode")`
- `set "settings.fontSize" 18` → delegates to `SettingsState.__agentSet("fontSize", value: 18)`
- `get "settings"` → returns full snapshot via `__agentSnapshot()` (all properties as a dict)
- `get "."` → returns root snapshot (handled by Dispatcher)

---

## Array Handling

Arrays of `@AgentSDK` classes support indexed traversal and whole-object reads. The macro recognizes `[T]` syntax and generates index-based dispatch:

```swift
case "todos":
    guard let tail else {
        // get "todos" → snapshot entire array
        return .value(todos.compactMap { ($0 as? AgentDispatchable)?.__agentSnapshot() })
    }
    let (indexStr, rest) = AgentPath.split(tail)
    guard let index = Int(indexStr), index >= 0, index < todos.count else {
        return .error("index out of bounds: \(indexStr)")
    }
    guard let rest else {
        // get "todos.0" → snapshot single item
        return .value((todos[index] as? AgentDispatchable)?.__agentSnapshot())
    }
    // get "todos.0.title" → delegate to element
    return (todos[index] as? AgentDispatchable)?.__agentGet(rest)
        ?? .error("not dispatchable: todos[]")
```

**Set on array elements** works because `TodoItem` is a reference type (`class`). Mutating `todos[index].title` modifies the object in place, and since `TodoItem` is `@Observable`, SwiftUI picks up the change.

**Why this works with `@Observable`:** Swift `[TodoItem]` is a value-type array of reference-type elements. `todos.append(item)` triggers the property setter (array changes identity), so `@Observable` fires. `todos[0].isCompleted = true` mutates the object via reference — `@Observable` on `TodoItem` fires. Either way, SwiftUI updates.

---

## Method Dispatch

The macro inspects each `func` declaration (non-private, non-computed) and generates a dispatch case. It reads parameter names and type annotations from syntax:

```swift
// Source:
func openBook(bookID: String, chapter: Int) -> [String: Any]? { ... }

// Generated:
case "openBook":
    guard let bookID = params["bookID"] as? String else {
        return .error("missing param: bookID (String)")
    }
    guard let chapter = (params["chapter"] as? NSNumber)?.intValue else {
        return .error("missing param: chapter (Int)")
    }
    let result = openBook(bookID: bookID, chapter: chapter)
    return .value(result as Any)
```

### Supported Parameter Types

The macro generates type-appropriate casting from JSON:

| Swift type | JSON casting |
|---|---|
| `String` | `as? String` |
| `Int` | `(as? NSNumber)?.intValue` |
| `Double` | `(as? NSNumber)?.doubleValue` |
| `Bool` | `(as? NSNumber)?.boolValue` |
| `[String: Any]` | `as? [String: Any]` |
| `[Any]` | `as? [Any]` |

No ObjC type constraints. Methods use normal Swift types and return whatever they want — the SDK serializes the result.

### Which Methods Are Dispatched

The macro generates dispatch for methods that:
- Are instance methods (not static)
- Are not private/fileprivate
- Are not property accessors (getters/setters)
- Are not overrides of standard methods (init, deinit, etc.)

If you want to exclude a method from agent dispatch, mark it `private`.

---

## Macro Implementation Notes

### What the Macro Sees

The macro is an **extension macro** that has access to the class declaration's syntax tree. It can see:
- Property declarations: name, type annotation, initial value
- Method declarations: name, parameters (labels + types), return type
- Access modifiers

It **cannot** see:
- Types defined in other files (no cross-file type resolution)
- Whether a type conforms to a protocol
- Resolved types of type aliases

This is why nested traversal uses runtime `as? AgentDispatchable` checks, and why explicit type annotations are required (see Coding Convention).

### Macro Type

`@AgentSDK` is an **extension macro**:
- Adds `AgentDispatchable` conformance via extension
- Generates `__agentGet`, `__agentSet`, `__agentCall`, `__agentSnapshot` in the extension
- No member injection needed — everything lives in the extension

### What Gets Skipped

The macro silently skips anything it can't handle. No errors, no warnings — the declaration just doesn't appear in the generated dispatch. This keeps the macro simple and avoids blocking compilation on edge cases.

A property or method is skipped if:
- Property has no type annotation (`var x = Foo()`)
- Type annotation is not a recognized primitive, optional, `[T]` array, or single identifier
- Method has unlabeled params (`_`), non-primitive param types, or is private/static/init

---

## HTTP Long-Poll Protocol

Unchanged from v1. See the v1 spec for details.

- `POST /poll` — app long-polls, receives requests, sends responses
- `POST /request` — agent sends `get`/`set`/`call`, blocks until response
- `GET /health` — server status

The only change: the Dispatcher uses `AgentDispatchable` protocol methods instead of KVC + NSInvocation.

```swift
// Dispatcher.swift (v2)
@MainActor
func dispatch(_ request: [String: Any]) -> AgentResult {
    guard let type = request["type"] as? String else {
        return .error("missing type")
    }
    switch type {
    case "get":
        let path = request["path"] as! String
        return state.__agentGet(path)
    case "set":
        let path = request["path"] as! String
        return state.__agentSet(path, value: request["value"])
    case "call":
        let method = request["method"] as! String
        let params = request["params"] as? [String: Any] ?? [:]
        return state.__agentCall(method, params: params)
    default:
        return .error("unknown type: \(type)")
    }
}

// Poller converts to JSON at the HTTP boundary:
// let json = dispatch(request).json
```

---

## `__doc__` Convention

Unchanged. The root state class has a computed `var __doc__: String` covering the entire state tree. The macro includes it in `__agentGet` like any other computed property.

## Special Paths

- `get "."` — returns `__agentSnapshot()` of the root state (full dump of all properties)
- `get "todos"` — returns array of snapshots
- `get "todos.0"` — returns snapshot of single element
- `get "settings"` — returns snapshot of child state object

---

## Packaging

### Swift Package (SPM)

```
SwiftAgentSDK/
├── Package.swift
├── Sources/
│   ├── SwiftAgentSDK/
│   │   ├── SwiftAgentSDK.swift       # Public API: SwiftAgentSDK.poll(state:server:)
│   │   ├── AgentDispatchable.swift    # Protocol + AgentResult + @AgentSDK macro declaration
│   │   ├── AgentPath.swift            # Path splitting utility
│   │   ├── Poller.swift               # URLSession long-poll loop
│   │   └── Dispatcher.swift           # Routes get/set/call via AgentDispatchable
│   └── SwiftAgentSDKMacros/
│       ├── AgentSDKMacro.swift        # ExtensionMacro implementation (SwiftSyntax)
│       └── Plugin.swift               # CompilerPlugin entry point
├── server/
│   ├── index.ts                       # Bun HTTP server
│   └── package.json
└── Examples/
    └── TodoList/                      # macOS example app
```

No ObjC files. Pure Swift. Depends on swift-syntax 509.x for the macro plugin.

### Server (TypeScript + Bun)

Unchanged from v1.

---

## Integration Checklist

- Add `SwiftAgentSDK` SPM dependency
- Add `@AgentSDK` to each state class (root + children)
- Add `@Observable` as usual for SwiftUI
- **Explicit type annotations** on all agent-exposed properties (`var x: Type = ...`)
- **Labeled params with primitive types** on all agent-exposed methods
- Add `var __doc__: String` computed property on the root
- Use normal Swift `[T]` arrays, not `NSMutableArray`
- Start server: `bunx agentsdk-server --port 9876`
- Call `SwiftAgentSDK.poll(state:server:)` in `.onAppear` or use a global instance — **never in init()**
- Anything without an explicit type annotation or with unsupported types is silently skipped

---

## v1 vs v2 Comparison

| | v1 (`@objc dynamic` + KVC) | v2 (`@AgentSDK` macro) |
|---|---|---|
| NSObject required | Yes | No |
| Array type | `NSMutableArray` | `[T]` |
| Method return | `NSDictionary?` | Any Swift type |
| Enum support | rawValue wrapper needed | Direct (with RawRepresentable) |
| SwiftUI observation | Broken — `@objc dynamic` conflicts with `@Observable` | Native — `@Observable` just works |
| Dispatch mechanism | Runtime (KVC + NSInvocation) | Compile-time (generated switch tables) |
| ObjC code needed | Yes (AgentDispatch.m) | No |
| Boilerplate | Low (ObjC runtime is magic) | Low (macro generates it) |
| Cross-file type info | Full (runtime reflection) | None (runtime `as?` check) |
| Error messages | KVC exceptions (crashes) | Typed error strings |
