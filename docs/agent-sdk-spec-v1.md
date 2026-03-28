---
overview: Design spec for a reusable Swift package (SwiftAgentSDK) that makes any SwiftUI app agent-drivable. Uses @objc dynamic + KVC for property access, NSInvocation for typed method dispatch, and a minimal JSONL-over-TCP protocol with just three operations (get/set/call).
tags:
  - spec
---

# SwiftAgentSDK — Reusable Library Spec

## Goal

A drop-in Swift package that makes any SwiftUI app agent-drivable: an AI agent (or CLI tool) can read state, set properties, and call methods — all over a simple JSONL-over-TCP protocol. The app author marks properties `@objc dynamic` and writes normal `@objc` methods; the SDK handles the rest.

---

## Core Concepts

### Dynamic State Tree via `@objc dynamic`

The SDK exploits ObjC runtime for string-based property access. App state classes inherit from `NSObject` and mark properties `@objc dynamic`. This gives us `value(forKeyPath:)` and `setValue(_:forKeyPath:)` — full dynamic dispatch with zero boilerplate.

```swift
import SwiftAgentSDK

@Observable
final class AppState: NSObject {
    @objc dynamic var __doc__: String {
        """
        AppState — root of the global state tree

        Properties:
          counter (Int) — tap counter
          label (String) — display label
          settings (SettingsState) — user preferences
          items (NSMutableArray) — list of Item objects

        Methods:
          openBook(bookID: String, chapter: Int) → {sessionIndex: Int}
          closeSession(sessionID: String)
          navigate(route: String)
        """
    }

    @objc dynamic var counter: Int = 0
    @objc dynamic var label: String = "hello"
    @objc dynamic var settings = SettingsState()
    @objc dynamic var items: NSMutableArray = []

    // Agent-callable methods — normal @objc methods with typed args
    @objc func openBook(bookID: String, chapter: Int) -> NSDictionary? {
        let session = makeSession(bookID: bookID, at: chapter)
        return ["sessionIndex": sessions.count - 1]
    }

    @objc func closeSession(sessionID: String) {
        removeSession(id: UUID(uuidString: sessionID)!)
    }

    @objc func navigate(route: String) {
        router.push(route)
    }
}

@Observable
final class SettingsState: NSObject {
    @objc dynamic var darkMode: Bool = false
    @objc dynamic var fontSize: Int = 16
}
```

Properties are readable/writable via dot-path strings:

```
get  "counter"              → 0
get  "settings.darkMode"    → false
set  "settings.fontSize"    42
set  "items.0.name"         "Alice"
```

Methods are callable internally as normal Swift, and externally by name with JSON params:

```swift
// Internal — normal typed call, no overhead
appState.openBook(bookID: "abc", chapter: 3)

// External — agent sends JSON, SDK bridges via NSInvocation
// {"method": "openBook", "params": {"bookID": "abc", "chapter": 3}}
```

### `__doc__` Convention

The root state class exposes a single `__doc__` computed property that covers the **entire** state tree — every property path, every method, workflows, and notes. One read gives the agent everything it needs:

```bash
curl localhost:9876/request -d '{"type":"get","path":"__doc__"}'
```

No per-class docs. The root `__doc__` documents child classes by path (e.g., `settings.darkMode`, `sessions.N.currentChapterIndex`). See the SwiftUI State SKILL for the full `__doc__` template.

---

## Method Dispatch via NSInvocation

The SDK ships a small ObjC helper that bridges JSON params to typed method arguments at runtime. No registry, no wrapper types — just write `@objc` methods with normal signatures.

### How It Works

When the agent sends `{"type": "call", "method": "openBook", "params": {"bookID": "abc", "chapter": 3}}`:

- SDK finds the selector matching "openBook" on the target class (via `class_copyMethodList`)
- Reads `NSMethodSignature` to get each argument's type encoding
- Extracts parameter names from the selector (e.g., `openBookWithBookID:chapter:` → `["bookID", "chapter"]`)
- Creates an `NSInvocation`, sets each arg from the JSON dict with the right type
- Invokes and returns the result

### ObjC Runtime Helper

`NSInvocation` isn't available in Swift, so the SDK includes a small ObjC file:

```objc
// AgentDispatch.m
@implementation AgentDispatch

+ (id)call:(id)target method:(NSString *)name params:(NSDictionary *)params {
    SEL sel = [self findSelector:name onClass:[target class]];
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = target;
    inv.selector = sel;

    NSArray *paramNames = [self paramNamesFromSelector:sel];

    for (NSUInteger i = 0; i < paramNames.count; i++) {
        NSString *key = paramNames[i];
        id value = params[key];
        NSUInteger argIndex = i + 2;  // 0=self, 1=_cmd
        const char *type = [sig getArgumentTypeAtIndex:argIndex];

        switch (type[0]) {
            case 'q': case 'l': {  // Int
                NSInteger v = [value integerValue];
                [inv setArgument:&v atIndex:argIndex];
                break;
            }
            case 'd': {  // Double
                double v = [value doubleValue];
                [inv setArgument:&v atIndex:argIndex];
                break;
            }
            case 'B': {  // Bool
                BOOL v = [value boolValue];
                [inv setArgument:&v atIndex:argIndex];
                break;
            }
            case '@': {  // Object (String, NSDictionary, NSArray)
                [inv setArgument:&value atIndex:argIndex];
                break;
            }
        }
    }

    [inv invoke];

    const char *retType = sig.methodReturnType;
    if (retType[0] == '@') {
        id __unsafe_unretained result = nil;
        [inv getReturnValue:&result];
        return result;
    }
    return nil;
}

+ (NSArray<NSString *> *)paramNamesFromSelector:(SEL)sel {
    // "openBookWithBookID:chapter:" → ["bookID", "chapter"]
    // Split by ":", parse first segment to extract initial param name
    // ...
}

+ (SEL)findSelector:(NSString *)name onClass:(Class)cls {
    // Find selector whose base name matches (before first "With" or ":")
    // ...
}

@end
```

### Supported Argument Types

Constraint: args must be ObjC-representable.

| Swift type | ObjC encoding | JSON value |
|---|---|---|
| `String` | `@` | string |
| `Int` | `q` | number |
| `Double` | `d` | number |
| `Bool` | `B` | bool |
| `NSDictionary` | `@` | object (complex nested params) |
| `NSArray` | `@` | array |

For methods that need complex args beyond primitives, use a single `NSDictionary` parameter and destructure inside:

```swift
@objc func importBooks(options: NSDictionary) -> NSDictionary? {
    let urls = options["urls"] as! [String]
    let format = options["format"] as? String ?? "epub"
    // ...
}
```

### Selector Naming

Swift auto-generates ObjC selectors from method signatures. To keep param name extraction clean, you can use explicit `@objc` names:

```swift
// Implicit — selector becomes "openBookWithBookID:chapter:"
@objc func openBook(bookID: String, chapter: Int) -> NSDictionary? { ... }

// Explicit — cleaner selector "openBook:chapter:"
@objc(openBook:chapter:)
func openBook(bookID: String, chapter: Int) -> NSDictionary? { ... }
```

The SDK handles both forms.

---

## HTTP Long-Poll Protocol

### Architecture

```
┌──────────┐  POST /poll    ┌────────────┐  POST /request
│  iOS App │ ─────────────→ │   Server   │ ←──────────── Agent (curl)
│ (client) │ ←── request ── │ (host mac) │ ── response →
└──────────┘ ── response ─→ └────────────┘
```

The app is an HTTP **client** that long-polls a server on the dev machine. The agent interacts with the server via `curl`. No TCP sockets, no JSONL, no CLI wrapper.

**Flow:**

- App does `POST /poll` — blocks until the server has a request queued
- Agent does `POST /request` with a JSON body — blocks until the app responds
- Server pairs them: hands the agent's request to the app's waiting poll, hands the app's reply back to the agent's waiting request
- App immediately polls again

### Three Operations: `get`, `set`, `call`

```bash
# Read a property
curl localhost:9876/request -d '{"type":"get","path":"counter"}'
# → {"data": 0}

# Read nested property
curl localhost:9876/request -d '{"type":"get","path":"settings.darkMode"}'
# → {"data": false}

# Set a property
curl localhost:9876/request -d '{"type":"set","path":"counter","value":42}'
# → {"data": null}

# Call a method
curl localhost:9876/request -d '{"type":"call","method":"openBook","params":{"bookID":"abc","chapter":3}}'
# → {"data": {"sessionIndex": 0}}

# Introspect
curl localhost:9876/request -d '{"type":"call","method":"describe"}'
```

**Errors:**

```json
{"error": "unknown method: fooBar"}
{"error": "invalid path: settings.nonexistent"}
```

That's the whole protocol. `get` reads via KVC, `set` writes via KVC, `call` dispatches via NSInvocation. Screenshots are handled by external tooling (e.g., `xcrun simctl` for simulator).

### Server

A minimal HTTP server (~50 lines). The agent starts it in the background and knows the port.

- `POST /poll` — app long-polls here, receives the next queued request, responds with the result
- `POST /request` — agent sends a command, blocks until the app responds
- One app connection at a time, multiple agent requests queue up
- Logs traffic in debug mode

### App Side

The SDK polls in a loop using `URLSession`:

```swift
func pollLoop() {
    Task { @MainActor in
        while true {
            let request = try await fetchNextRequest()  // POST /poll, blocks
            let result = dispatch(request)               // get/set/call on MainActor
            try await sendResponse(result)               // POST /poll response
        }
    }
}
```

### Setup

Configure the server URL via a user-defined build setting so it can differ per scheme (simulator vs device):

```
// Xcode → Build Settings → User-Defined
AGENTSDK_URL = http://localhost:9876          // simulator scheme
AGENTSDK_URL = http://192.168.1.100:9876     // device scheme
```

Reference in Info.plist:

```xml
<key>SwiftAgentSDKURL</key>
<string>$(AGENTSDK_URL)</string>
```

Or override from command line:

```bash
xcodebuild -scheme MyApp AGENTSDK_URL="http://192.168.1.100:9876"
```

App reads it at launch:

```swift
@main
struct MyApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
        }
    }

    init() {
        #if DEBUG
        if let url = Bundle.main.infoDictionary?["SwiftAgentSDKURL"] as? String {
            SwiftAgentSDK.poll(state: appState, server: url)
        }
        #endif
    }
}
```

---

## Design Decisions

### Why `@objc dynamic` + KVC

Pure Swift `@Observable` has no runtime string→property dispatch — Swift keypaths are typed at compile time. `NSObject` + `@objc dynamic` brings back the full ObjC runtime:

- `setValue(_:forKeyPath:)` walks dot paths, handles array indices, coerces types
- `value(forKeyPath:)` reads any nested property
- `class_copyPropertyList` enumerates properties for introspection
- Zero per-property boilerplate

**Trade-off**: Properties must be ObjC-representable types (`Int`, `Double`, `Bool`, `String`, `NSMutableArray`, `NSObject` subclasses). Swift enums, structs, and generics need wrapper properties.

### Why NSInvocation for Method Dispatch

- Methods look normal — typed Swift args, callable internally without overhead
- No registry, no `AgentMethod` wrappers, no result builders
- Adding a new agent method = just add `@objc func`
- The SDK auto-discovers callable methods via `class_copyMethodList`
- One small ObjC file handles all the bridging

### Concurrency: All Dispatch on MainActor

The TCP connection (`NWConnection`) delivers data on a background queue, but all state reads/writes and method calls must happen on the main thread (SwiftUI `@Observable`, `@objc dynamic` properties). The SDK dispatches every incoming message onto `MainActor` before touching the state tree:

```swift
// TCP receive callback (background queue)
func handleMessage(_ msg: AgentMessage) {
    Task { @MainActor in
        let result = dispatch(msg)  // get/set/call — all on main thread
        send(response: result)
    }
}
```

Agent methods are **sync**. If a method needs async work, it kicks off a `Task` and returns immediately — the agent observes completion by polling state via `get`:

```swift
@objc func loadBook(url: String) -> NSDictionary? {
    Task { @MainActor in
        let data = try await fetchBook(url)
        self.currentBook = parseBook(data)  // state updates when done
    }
    return ["status": "loading"]
}
```

Rapid-fire commands are safe — `MainActor` is a serial executor, so messages are processed one at a time with no concurrent state mutations.

### Why Just Three Operations

`get`, `set`, `call` cover everything. Screenshots, introspection, presets — these are all just methods. No need for dedicated message types.

### Why HTTP Long-Poll

- **No server on phone** — the app is a client, avoids iOS sandbox/firewall issues
- **No CLI needed** — just `curl`
- **No client library needed** — any language, any tool that speaks HTTP
- **Simple server** — ~50 lines, pairs requests with polls
- **Works on-device** — phone polls a server on the dev machine, same as simulator

---

## Alternative: Swift Macro (`@Agent`)

A pure-Swift approach is possible via Swift 5.9+ macros. An `@Agent` attached macro would inspect the class at compile time and generate an extension with a dispatch table:

```swift
@Agent
@Observable
final class AppState {  // no NSObject needed
    var counter: Int = 0
    func openBook(bookID: String, chapter: Int) -> OpenBookResult { ... }
}

// Macro generates:
extension AppState: AgentDispatchable {
    func agentGet(_ path: String) -> Any? {
        switch path {
        case "counter": return counter
        default: return nil
        }
    }
    func agentSet(_ path: String, value: Any) {
        switch path {
        case "counter": counter = value as! Int
        default: break
        }
    }
    func agentCall(_ method: String, params: [String: Any]) throws -> Encodable? {
        switch method {
        case "openBook":
            return openBook(bookID: params["bookID"] as! String,
                            chapter: params["chapter"] as! Int)
        default: throw AgentError.unknownMethod(method)
        }
    }
}
```

This gives you pure Swift types everywhere — `Encodable` returns, no NSObject inheritance, no ObjC type constraints. But it's a real macro to write, and the generated switch tables are just a verbose version of what the ObjC runtime gives you for free. Nested dot-paths like `settings.darkMode` require recursive codegen across `@Agent`-annotated child types, which gets hairy.

**Verdict**: probably not worth the ceremony. The ObjC runtime approach works today with less code. The macro becomes worthwhile if you have a project that can't inherit from NSObject (e.g., pure SwiftUI with no UIKit dependency, or a cross-platform Swift project). For typical iOS apps, `@objc dynamic` is the pragmatic choice.

---

## ObjC-Incompatible Types: Bridging Strategies

### Swift Enums

```swift
enum ViewMode: String { case list, grid, detail }

var viewMode: ViewMode = .list

@objc dynamic var viewModeRaw: String {
    get { viewMode.rawValue }
    set { viewMode = ViewMode(rawValue: newValue) ?? .list }
}
```

### Typed Arrays

KVC requires `NSMutableArray`. Maintain a typed array alongside, or use `NSMutableArray` directly.

---

## Packaging

Two deliverables: a Swift package for the app side, and a TypeScript server.

### Swift Package (SPM)

The SDK ships as a Swift package. Apps add it as a dependency:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/hayeah/SwiftAgentSDK.git", from: "0.1.0")
]
```

Package contents:

```
SwiftAgentSDK/
├── Package.swift
├── Sources/
│   └── SwiftAgentSDK/
│       ├── SwiftAgentSDK.swift          # Public API: SwiftAgentSDK.poll(state:server:)
│       ├── Poller.swift            # URLSession long-poll loop
│       ├── Dispatcher.swift        # get/set/call routing, KVC + NSInvocation
│       └── ObjC/
│           ├── AgentDispatch.h     # NSInvocation bridge header
│           └── AgentDispatch.m     # NSInvocation-based method dispatch
└── Tests/
    └── SwiftAgentSDKTests/
```

The ObjC file (`AgentDispatch.m`) is the only non-Swift code — handles `NSInvocation` which isn't available in Swift.

### Server (TypeScript + Bun)

A minimal HTTP server that pairs agent requests with app polls. Runs via `bunx`:

```bash
bunx agentsdk-server --port 9876
```

The server is ~50 lines:

```typescript
const pending: {
    resolve: (body: any) => void
    request: any
}[] = []

let appPoll: ((request: any) => Promise<any>) | null = null

Bun.serve({
    port: parseInt(Bun.argv[Bun.argv.indexOf("--port") + 1] || "9876"),

    async fetch(req) {
        const url = new URL(req.url)

        if (url.pathname === "/poll" && req.method === "POST") {
            // App long-polls here. If there's a queued request, return it.
            // When the app responds, forward to the waiting agent.
            const body = await req.json().catch(() => null)

            // If body has a response, resolve the pending agent request
            if (body?.id && pending.length) {
                const idx = pending.findIndex(p => p.request.id === body.id)
                if (idx >= 0) pending.splice(idx, 1)[0].resolve(body)
            }

            // Wait for next agent request
            return new Promise<Response>(resolve => {
                appPoll = async (request) => {
                    resolve(Response.json(request))
                    return new Promise(r => {
                        pending.push({ resolve: r, request })
                    })
                }
            })
        }

        if (url.pathname === "/request" && req.method === "POST") {
            // Agent sends a command, blocks until app responds
            const request = await req.json()
            if (!appPoll) return Response.json({ error: "no app connected" }, { status: 503 })
            const result = await appPoll(request)
            return Response.json(result)
        }

        return new Response("not found", { status: 404 })
    }
})
```

Publish as an npm package (`agentsdk-server`) so it's runnable via `bunx` with no install step.

---

## Integration Checklist

- **App side**: add `SwiftAgentSDK` SPM dependency
- Make root state class inherit `NSObject`
- Mark exposed properties `@objc dynamic`
- Add a `__doc__` computed property
- Write agent-callable methods as `@objc func` with ObjC-compatible arg types
- Set `AGENTSDK_URL` build setting per scheme
- **Server side**: `bunx agentsdk-server --port 9876`

No registry, no protocols, no custom serialization. Just ObjC runtime doing what it was built for.
