---
name: swift-agent-sdk
description: Make SwiftUI apps agent-drivable via get/set/call over HTTP. Use when building iOS/macOS apps that AI agents can inspect and control programmatically.
---

# SwiftAgentSDK

A Swift package that makes any SwiftUI app agent-drivable. An AI agent can read state, set properties, and call methods — all over HTTP with `curl`.

Add `@AgentSDK` to your `@Observable` classes. The macro generates all the dispatch code. No NSObject, no KVC, no runtime reflection.

## Quick Start

Add the SPM dependency, then mark your state classes:

```swift
import SwiftAgentSDK

#if DEBUG
@AgentSDK
#endif
@Observable
final class AppState {
    var counter: Int = 0
    var label: String = "hello"
    var settings: SettingsState = SettingsState()
    var todos: [TodoItem] = []

    var __doc__: String {
        """
        AppState — root state tree.

        Properties:
          counter (Int), label (String)
          settings.darkMode (Bool), settings.fontSize (Int)
          todos.N.title (String), todos.N.isCompleted (Bool)

        Methods:
          addTodo(title: String) → {"index": N}
          toggleTodo(index: Int)
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

#if DEBUG
@AgentSDK
#endif
@Observable
final class SettingsState {
    var darkMode: Bool = false
    var fontSize: Int = 16
}

#if DEBUG
@AgentSDK
#endif
@Observable
final class TodoItem: Identifiable {
    let id: String = UUID().uuidString
    var title: String
    var isCompleted: Bool = false

    init(title: String) {
        self.title = title
    }
}
```

Wire it up in your App (with view inspection):

```swift
private let sharedAppState = AppState()

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(sharedAppState)
                .agentInspectable()  // enables view tree + screenshots
                .onAppear {
                    #if DEBUG
                    SwiftAgentSDK.poll(state: sharedAppState, server: "http://localhost:9876")
                    #endif
                }
        }
    }
}
```

Tag views for inspection:

```swift
struct ContentView: View {
    var body: some View {
        VStack {
            TextField("Search", text: $query)
                .agentID("searchField")
            List { ... }
                .agentID("todoList")
            Button("Add") { ... }
                .agentID("addButton")
        }
        .agentID("root")
    }
}
```

## CLI: `swiftui-tap`

Install the CLI (requires [Bun](https://bun.sh)):

```bash
cd server && bun link && bun link swiftui-tap
```

Start the server:

```bash
swiftui-tap server --port 9876
```

### State control

```bash
# Read the doc string
swiftui-tap state get __doc__

# Read a property
swiftui-tap state get counter

# Snapshot the whole state tree
swiftui-tap state get .

# Set a property
swiftui-tap state set counter 42

# Call a method
swiftui-tap state call addTodo title="Buy milk"

# Call with multiple params
swiftui-tap state call openBook bookID="abc" chapter=0
```

### View inspection

```bash
# Dump the view hierarchy (text)
swiftui-tap view tree

# Dump as JSON
swiftui-tap view tree --json

# Scope to a subtree
swiftui-tap view tree ContentView.todoList

# Full app screenshot
swiftui-tap view screenshot

# Screenshot cropped to a tagged view
swiftui-tap view screenshot ContentView.todoList -o todolist.png

# JPEG with quality
swiftui-tap view screenshot -f jpg -q 0.8 -o screen.jpg
```

### Example tree output

```
ContentView.root  (0,168 402x672)
     proposed=402x672  reported=402x672
   ├─ ContentView.inputBar  (0,168 402x66)
   │    rel=(0,0)  proposed=402x224  reported=402x66
   │  ├─ ContentView.input  (16,184 336x34)
   │  │    rel=(16,16)  proposed=336x192  reported=336x34
   │  └─ ContentView.addButton  (360,188 26x25)
   │       rel=(360,20)  proposed=181x192  reported=26x25
   ├─ ContentView.todoList  (0,234 402x574)
   │    rel=(0,66)  proposed=402x574  reported=402x574
   └─ ContentView.footer  (0,808 402x32)
        rel=(0,640)  proposed=402x303  reported=402x32
      └─ ContentView.clearButton  (286,816 100x16)
           rel=(286,8)  proposed=303x287  reported=100x16
```

Each node shows:
- `frame` — absolute position from screenshot origin (matches pixel coordinates for cropping)
- `rel` — position relative to parent (shows padding/spacing)
- `proposed` — what the parent offered in the layout negotiation
- `reported` — what the view claimed to need

### Environment variable

Set `SWIFTUI_TAP_URL` to point to a different server:

```bash
export SWIFTUI_TAP_URL=http://192.168.1.5:9876
swiftui-tap state get .
```

### curl (without the CLI)

```bash
# State: get/set/call via POST /request
curl localhost:9876/request -d '{"type":"get","path":"counter"}'
curl localhost:9876/request -d '{"type":"set","path":"counter","value":42}'
curl localhost:9876/request -d '{"type":"call","method":"addTodo","params":{"title":"Buy milk"}}'

# View: tree/screenshot via POST /view
curl localhost:9876/view -d '{"type":"tree"}'
curl localhost:9876/view -d '{"type":"screenshot","id":"ContentView.todoList"}' | jq -r .data.image | base64 -d > todo.png
```

## Coding Convention

The macro generates dispatch code by parsing your class syntax. It needs **explicit type annotations** on everything it should expose.

### Properties

```swift
#if DEBUG
@AgentSDK
#endif
@Observable
final class AppState {
    // SUPPORTED — explicit type annotation
    var counter: Int = 0
    var label: String = "hello"
    var darkMode: Bool = false
    var ratio: Double = 1.0
    var name: String? = nil
    var todos: [TodoItem] = []
    var tags: [String] = []
    var settings: SettingsState = SettingsState()

    // SKIPPED — no type annotation
    var settings = SettingsState()
    var count = 0

    // SKIPPED — complex generic types
    var lookup: [String: TodoItem] = [:]
    var callback: (() -> Void)? = nil
}
```

| Type annotation | Get | Set | Notes |
|---|---|---|---|
| `String`, `Int`, `Double`, `Bool` | yes | yes | Direct JSON mapping |
| `String?`, `Int?`, etc. | yes | yes | nil ↔ JSON null |
| `[T]` | yes | no | Index traversal: `todos.0.title` |
| Any other identifier | yes | delegate | Runtime `as? AgentDispatchable` check |
| `let` properties | yes | no | Read-only |
| Computed properties | yes | no | Read-only |
| No type annotation | skipped | skipped | Invisible to agent |

### Methods

```swift
#if DEBUG
@AgentSDK
#endif
@Observable
final class AppState {
    // SUPPORTED — labeled params, any type
    func addTodo(title: String) -> [String: Any]? { ... }
    func toggleTodo(index: Int) { ... }
    func reset() { ... }

    // SUPPORTED — Codable params and returns
    func moveTo(point: Point) -> MoveResult { ... }

    // SKIPPED — unlabeled param
    func process(_ items: [TodoItem]) { ... }

    // SKIPPED — private
    private func internalHelper() { ... }
}
```

**Parameter types:**
- `String`, `Int`, `Double`, `Bool` → direct JSON cast
- Any other type → `__agentDecode<T>()` — must conform to `Decodable`

**Return types:**
- `Void` → `.value(nil)`
- Primitives, `[String: Any]?` → passed through
- Any other type → `__agentEncode(result)` — must conform to `Encodable`

If a type isn't Codable, you get a clear compile error:
```
error: global function '__agentEncode' requires that 'MyType' conform to 'Encodable'
```

### Skipping Is Silent

The macro skips anything it can't handle — no errors, no warnings. The property or method just won't be agent-accessible. Use `get "__doc__"` to verify what's exposed.

## Protocol: Three Operations

### get — Read State

```bash
# Primitive property
curl localhost:9876/request -d '{"type":"get","path":"counter"}'
# → {"data": 0}

# Nested property
curl localhost:9876/request -d '{"type":"get","path":"settings.darkMode"}'
# → {"data": false}

# Array element
curl localhost:9876/request -d '{"type":"get","path":"todos.0.title"}'
# → {"data": "Buy milk"}

# Whole array (snapshot)
curl localhost:9876/request -d '{"type":"get","path":"todos"}'
# → {"data": [{"title": "Buy milk", "isCompleted": false}, ...]}

# Whole object (snapshot)
curl localhost:9876/request -d '{"type":"get","path":"todos.0"}'
# → {"data": {"title": "Buy milk", "isCompleted": false, "id": "..."}}

# Root snapshot
curl localhost:9876/request -d '{"type":"get","path":"."}'
# → {"data": {"counter": 0, "todos": [...], ...}}
```

### set — Write State

```bash
# Set a primitive
curl localhost:9876/request -d '{"type":"set","path":"counter","value":42}'
# → {"data": null}

# Set nested property
curl localhost:9876/request -d '{"type":"set","path":"settings.fontSize","value":20}'

# Set array element property
curl localhost:9876/request -d '{"type":"set","path":"todos.0.title","value":"Buy oat milk"}'
```

### call — Invoke Methods

```bash
# Method with primitive params
curl localhost:9876/request -d '{"type":"call","method":"addTodo","params":{"title":"Ship it"}}'
# → {"data": {"index": 0}}

# Void method
curl localhost:9876/request -d '{"type":"call","method":"clearCompleted"}'
# → {"data": null}

# Method returning Codable struct
curl localhost:9876/request -d '{"type":"call","method":"getStats"}'
# → {"data": {"total": 3, "active": 2, "completed": 1}}

# Method with Codable param
curl localhost:9876/request -d '{"type":"call","method":"moveTo","params":{"point":{"x":10,"y":20}}}'
```

### Errors

```json
{"error": "unknown property: foo"}
{"error": "unknown method: bar"}
{"error": "index out of bounds: 5 (count: 2)"}
{"error": "missing param: title (String)"}
{"error": "cannot decode param: point (Point)"}
```

## `__doc__` Convention

The root state class should have a computed `var __doc__: String` that documents the entire state tree — every property path, every method, workflows, and notes. The agent reads one string and knows how to interact with the whole app.

```swift
var __doc__: String {
    """
    AppState — EPUB Reader

    ## State Tree

    library.searchQuery (String) — set to filter books
    library.books (array) — BookEntry objects
    sessions.N.currentChapterIndex (Int) — zero-based chapter
    sessions.N.scrollFraction (Double) — 0.0–1.0

    ## Methods

    openBook(bookID: String, chapter: Int) → {"sessionIndex": N}
    closeSession(sessionID: String)

    ## Workflows

    Open a book: call openBook {"bookID": "abc", "chapter": 0}
    Search: set library.searchQuery "alice"
    """
}
```

## Architecture

```
┌──────────┐  POST /poll    ┌────────────┐  POST /request    ┌───────────┐
│  App     │ ─────────────→ │   Server   │ ←──────────────── │ Agent     │
│ (client) │ ←── request ── │ (Bun/TS)   │ ── response ───→ │ (CLI/curl)│
└──────────┘ ── response ─→ │            │ ←─ POST /view ─── │           │
                             └────────────┘ ── tree/screenshot→└───────────┘
```

The app is an HTTP **client** that long-polls the server. The agent sends commands via `POST /request` (state) or `POST /view` (view inspection). The server pairs them.

- `POST /request` — state operations: get/set/call on `@AgentSDK` properties
- `POST /view` — view inspection: tree hierarchy dump, screenshots (full or cropped)
- No server on the phone — avoids iOS sandbox issues
- Works with simulator and on-device (phone polls dev machine)

## App Setup

**Do NOT call `SwiftAgentSDK.poll()` in `init()`.** SwiftUI's `@State` isn't wired up during `init()`, so you'd be polling on a throwaway instance. Use a global instance or `.onAppear`:

```swift
private let sharedState = AppState()

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(sharedState)
                .onAppear {
                    #if DEBUG
                    let url = ProcessInfo.processInfo.environment["AGENTSDK_URL"]
                        ?? "http://localhost:9876"
                    SwiftAgentSDK.poll(state: sharedState, server: url)
                    #endif
                }
        }
    }
}
```

## Disabling for Production

Wrap `@AgentSDK` in `#if DEBUG` so release builds have zero agent overhead — no dispatch code, no protocol conformance:

```swift
#if DEBUG
@AgentSDK
#endif
@Observable
final class AppState {
    ...
}
```

The `poll()` call should also be behind `#if DEBUG` (see App Setup above). In release builds, the macro is stripped entirely and the classes are plain `@Observable` with no agent code.

## Server

The relay server is built into the `swiftui-tap` CLI:

```bash
swiftui-tap server --port 9876

# With debug logging
swiftui-tap server --port 9876 --debug

# Health check
curl localhost:9876/health
# → {"status": "ok", "appConnected": true, "pendingRequests": 0}
```

## What the Macro Generates

`@AgentSDK` is an extension macro. For each class it generates:

- `__agentGet(_ path:)` — switch table for property reads, recursive traversal
- `__agentSet(_ path:, value:)` — switch table for property writes
- `__agentCall(_ method:, params:)` — switch table for method dispatch
- `__agentSnapshot()` — dictionary of all properties for whole-object reads

All methods use the `__` prefix to avoid collisions with your own code.

The macro uses runtime `as? AgentDispatchable` checks for child state traversal — no cross-file type resolution needed. If a child class has `@AgentSDK`, traversal works. If not, it returns nil.

## Package Structure

```
SwiftAgentSDK/
├── Package.swift
├── Sources/
│   ├── SwiftAgentSDK/
│   │   ├── SwiftAgentSDK.swift         # Public API: poll(state:server:)
│   │   ├── AgentDispatchable.swift      # Protocol, AgentResult, @AgentSDK macro decl
│   │   ├── AgentPath.swift              # Dot-path splitting
│   │   ├── Poller.swift                 # URLSession long-poll loop
│   │   ├── Dispatcher.swift             # Routes get/set/call
│   │   ├── AgentID.swift                # .agentID() view modifier
│   │   ├── AgentInspectable.swift       # .agentInspectable() root modifier
│   │   ├── AgentViewStore.swift         # View tree + screenshot dispatch
│   │   └── AgentViewFrameKey.swift      # PreferenceKey for anchor frames
│   └── SwiftAgentSDKMacros/
│       ├── AgentSDKMacro.swift          # ExtensionMacro (SwiftSyntax)
│       └── Plugin.swift                 # CompilerPlugin entry point
├── server/
│   ├── index.ts                         # Bun HTTP relay server
│   ├── cli.ts                           # swiftui-tap CLI
│   └── package.json
└── Examples/
    ├── TodoList/                        # macOS example app
    └── TodoListiOS/                     # iOS example app
```
