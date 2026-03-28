---
overview: SKILL guide for writing SwiftUI apps with a single global state tree pattern. State classes use NSObject + @objc dynamic so agents can inspect and manipulate state programmatically via string paths (KVC). Covers state tree design, view binding, data modeling, and agent-compatibility conventions.
tags:
  - skill
  - swift
---

# SwiftUI Global State Tree — SKILL Guide

## Overview

This skill guides you to write SwiftUI apps with a **single global state tree** rooted in one `@Observable` object. All views bind to paths within this tree. State classes inherit from `NSObject` with `@objc dynamic` properties so that agents can read, write, and call methods programmatically via string paths.

## Why This Pattern

- **One source of truth** — no scattered stores, no DI containers, no ambient singletons
- **Agent-drivable** — every property is addressable by dot-path string (e.g., `library.searchQuery`), every method callable by name
- **Easy to stub** — set any state for previews, tests, or screenshots without mocks
- **Transparent data flow** — each view declares which path in the tree it binds to

---

## State Tree Structure

### Root State

One `@Observable` class inheriting `NSObject`. This is the entire app's state:

```swift
@Observable
final class AppState: NSObject {
    @objc dynamic var __doc__: String {
        """
        AppState — EPUB Reader state tree.

        Single source of truth for the entire app. All views bind to
        paths within this tree. All state is reachable from here.

        ## State Tree

        library (LibraryState) — book library and browsing
          .searchQuery (String)         — set to filter the book list, "" = no filter
          .books (NSMutableArray)       — all BookEntry objects {id, title, author, filename}
          .activeLibraryID (String?)    — selected library folder, nil = show all
          .filteredBooks                — computed: books filtered by searchQuery (read-only)

        sessions (NSMutableArray) — open reading sessions, one per book
          sessions.N (ReadingSession):
            .bookID (String)                  — ID of the open book
            .currentChapterIndex (Int)        — zero-based chapter index
            .scrollFraction (Double)          — scroll position within chapter, 0.0–1.0
            .isChapterSwitcherVisible (Bool)  — TOC overlay
            .isBottomBarVisible (Bool)        — bottom navigation bar
            .nextChapter()                    — advance one chapter
            .previousChapter()                — go back one chapter (clamped to 0)

        ## Methods

        openBook(bookID: String, chapter: Int) → {"sessionIndex": N}
          Opens a book. Creates a new ReadingSession and appends it to
          `sessions`. Returns the index of the new session.

        closeSession(sessionID: String)
          Removes the session with the given UUID string from `sessions`.

        ## Common Workflows

        Open a book and jump to chapter 5:
          call openBook {"bookID": "alice-123", "chapter": 5}

        Search the library:
          set library.searchQuery "alice"
          get library  → includes filtered books in response

        Clear search:
          set library.searchQuery ""

        Inspect all open sessions:
          get sessions  → array of ReadingSession snapshots

        Navigate an open book:
          set sessions.0.currentChapterIndex 8
          set sessions.0.scrollFraction 0.0

        Scroll to middle of current chapter:
          set sessions.0.scrollFraction 0.5

        Show the chapter switcher overlay:
          set sessions.0.isChapterSwitcherVisible true

        Hide bottom bar (full-screen reading):
          set sessions.0.isBottomBarVisible false

        ## Notes

        - Changing currentChapterIndex resets scrollFraction to 0.
          The view auto-loads chapter content when the index changes.
        - library.books is read-only from the agent's perspective —
          books come from scanning library folders. Use openBook() to
          read one.
        - Direct property sets are fine for simple values (toggles,
          text, numbers). Use methods for multi-step operations.
        """
    }

    @objc dynamic var library = LibraryState()
    @objc dynamic var sessions: NSMutableArray = []  // [ReadingSession]

    // Derived — computed, not stored
    var openBookIDs: Set<String> { Set((sessions as! [ReadingSession]).map { $0.book.id }) }

    // Actions
    @objc func openBook(bookID: String, chapter: Int) -> NSDictionary? {
        let session = ReadingSession(bookID: bookID, chapter: chapter)
        sessions.add(session)
        return ["sessionIndex": sessions.count - 1]
    }

    @objc func closeSession(sessionID: String) {
        let id = UUID(uuidString: sessionID)!
        sessions.removeObject(at: (sessions as! [ReadingSession]).firstIndex { $0.id == id }!)
    }
}
```

### Child State Classes

Each logical domain gets its own `@Observable` + `NSObject` class:

```swift
@Observable
final class LibraryState: NSObject {
    @objc dynamic var searchQuery: String = ""
    @objc dynamic var activeLibraryID: String? = nil
    @objc dynamic var books: NSMutableArray = []  // [BookEntry]

    // Derived
    var filteredBooks: [BookEntry] {
        let allBooks = books as! [BookEntry]
        guard !searchQuery.isEmpty else { return allBooks }
        return allBooks.filter { $0.matches(searchQuery) }
    }
}

@Observable
final class ReadingSession: NSObject, Identifiable {
    let id = UUID()

    @objc dynamic var bookID: String = ""
    @objc dynamic var currentChapterIndex: Int = 0
    @objc dynamic var scrollFraction: Double = 0.0
    @objc dynamic var isChapterSwitcherVisible = false
    @objc dynamic var isBottomBarVisible = true

    // Actions
    @objc func nextChapter() { currentChapterIndex += 1 }
    @objc func previousChapter() { currentChapterIndex = max(0, currentChapterIndex - 1) }
}
```

### Data Models (plain structs)

Leaf data — things that don't need to be individually addressable by agents — are plain structs:

```swift
struct BookEntry: Identifiable, Codable {
    let id: String
    let title: String
    let author: String
    let filename: String
}

struct Chapter: Identifiable {
    let id: String
    let index: Int
    let title: String
}
```

**Rule of thumb**: if an agent needs to get/set properties on it by path, make it an `NSObject` class. If it's just data passed around, use a struct.

---

## Rules

### Property Declarations

- All agent-visible properties: `@objc dynamic var`
- Derived/computed properties: plain `var` (no `@objc dynamic` needed, agents read parent and compute)
- Constants: `let` (not agent-writable, that's fine)
- Arrays that agents index into: `NSMutableArray` (KVC requires it for indexed access like `sessions.0.currentChapterIndex`)
- Arrays that are just data: plain `[SomeStruct]`

### `__doc__` on the Root State Class

One `__doc__` on `AppState` that covers the **entire** state tree — every property, every method, every child class's fields, with workflows and notes. The agent reads one string and knows how to interact with the whole app.

No per-class `__doc__`. Child state classes don't need their own — the root doc covers them by path. The agent reads one string and knows how to interact with the whole app.

### Direct Set vs Action Methods

Views (and agents) can mutate state in two ways: set a property directly, or call a method. Use whichever fits:

**Direct set** — for single-property writes with no side effects:

```swift
// View
Button("Show Chapters") {
    session.isChapterSwitcherVisible = true
}

// Agent
// set sessions.0.isChapterSwitcherVisible true
```

This covers UI toggles (`isBottomBarVisible`, `isChapterSwitcherVisible`), text fields (`searchQuery`), numeric values (`currentChapterIndex`, `scrollFraction`). No method wrapper needed — adding `setSearchQuery(_ q: String)` for a single property write is just ceremony.

**Action method** — when the operation touches multiple properties, has invariants, or produces a result:

```swift
// Opening a book creates a session, appends to array, returns index — not a single set
@objc func openBook(bookID: String, chapter: Int) -> NSDictionary? {
    let session = ReadingSession(bookID: bookID, chapter: chapter)
    sessions.add(session)
    return ["sessionIndex": sessions.count - 1]
}

// Closing a session needs to find + remove — not just a property write
@objc func closeSession(sessionID: String) {
    // cleanup, remove from array, persist...
}
```

**The rule**: if setting a property has side effects or touches multiple properties, make it a method. If it's a single-property write, just set it directly.

Both are equally testable — the state tree is a plain object, no mocks needed:

```swift
// Testing a direct set
func testSearchFilters() {
    let state = LibraryState()
    state.books = NSMutableArray(array: [BookEntry(title: "Alice"), BookEntry(title: "Moby Dick")])
    state.searchQuery = "alice"
    XCTAssertEqual(state.filteredBooks.count, 1)
}

// Testing an action method
func testOpenBook() {
    let state = AppState()
    let result = state.openBook(bookID: "abc", chapter: 3)
    XCTAssertEqual(state.sessions.count, 1)
    XCTAssertEqual(result?["sessionIndex"] as? Int, 0)
}
```

### Agent-Callable Methods

Methods that agents can call are `@objc func` with ObjC-compatible arg types:

- Supported: `String`, `Int`, `Double`, `Bool`, `NSDictionary`, `NSArray`
- Return `NSDictionary?` for results, `nil` (void) for fire-and-forget
- Internal callers can call these directly — typed args work normally in Swift
- For complex args, use a single `NSDictionary` param and destructure

### View Binding

Views receive a reference to the state subtree they need. Declare which path each view binds to:

```swift
// Binds to a single session
struct ReadingView: View {
    let session: ReadingSession

    var body: some View {
        Text(session.chapterTitle)
    }
}

// Binds to the full app state (needs multiple subtrees)
struct LibraryView: View {
    let appState: AppState

    var body: some View {
        List(appState.library.filteredBooks) { book in
            BookRow(book: book)
        }
    }
}
```

Pass state via SwiftUI environment from the root:

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
}
```

### State Organization

```
AppState                          ← root, one per app
├── library: LibraryState         ← domain subtree
│   ├── searchQuery: String
│   ├── books: NSMutableArray
│   └── activeLibraryID: String?
├── sessions: NSMutableArray      ← array of domain objects
│   ├── [0]: ReadingSession
│   │   ├── currentChapterIndex: Int
│   │   ├── scrollFraction: Double
│   │   └── isChapterSwitcherVisible: Bool
│   └── [1]: ReadingSession
│       └── ...
└── router: RouterState           ← navigation state (if needed)
    └── currentRoute: String
```

Every node in this tree is addressable by dot-path:
- `library.searchQuery`
- `sessions.0.currentChapterIndex`
- `sessions.1.isChapterSwitcherVisible`

---

## ObjC Type Bridging

Not everything fits `@objc dynamic`. Bridging strategies:

### Enums → raw value wrapper

```swift
enum ViewMode: String { case list, grid, detail }

var viewMode: ViewMode = .list

@objc dynamic var viewModeRaw: String {
    get { viewMode.rawValue }
    set { viewMode = ViewMode(rawValue: newValue) ?? .list }
}
```

### Typed arrays → NSMutableArray

For arrays that agents need to index into:

```swift
// Agent can do: sessions.0.currentChapterIndex
@objc dynamic var sessions: NSMutableArray = []

// Internal convenience
var typedSessions: [ReadingSession] {
    sessions as! [ReadingSession]
}
```

For arrays that are just data (no agent indexing), use plain `[SomeStruct]`.

---

## Anti-Patterns

- **Scattered ObservableObjects** — don't use multiple `@StateObject` / `@EnvironmentObject` scattered across views. One tree.
- **ViewModels per screen** — no `LibraryViewModel`, `ReaderViewModel`. The state tree IS the view model.
- **State in views** — `@State` is fine for ephemeral view-local state (animation, sheet presentation). Anything an agent might care about goes in the tree.
- **Protocols on state classes** — no `AgentExposable` or similar. Just `NSObject` + `@objc dynamic` by convention.
- **Registries for methods** — no method registry. Just `@objc func`.
- **Private state** — don't hide state behind private access. The tree should be fully inspectable. If a property exists, it's readable.

---

## File Organization

```
State/
├── AppState.swift           # Root @Observable, top-level actions
├── LibraryState.swift       # Library domain
├── ReadingSession.swift     # Per-session domain
├── RouterState.swift        # Navigation (if needed)
└── Models/                  # Plain structs (Codable, Identifiable)
    ├── BookEntry.swift
    ├── Chapter.swift
    └── TOCItem.swift
```

State classes go in `State/`. Plain data models go in `State/Models/`. Views never define state classes — they only receive references.
