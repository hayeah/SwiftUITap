# TodoListiOS Example

SwiftUITap demo app for iOS simulator.

## Prerequisites

- Start the relay server: `swiftui-tap server --port 9876`
- Boot a simulator: `xcrun simctl boot "iPhone 17 Pro"` (or use one already booted)

## Build

```bash
cd Examples/TodoListiOS

xcodebuild \
  -scheme TodoListiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build
```

## Install & Launch

```bash
# Find the .app in DerivedData
APP=$(find ~/Library/Developer/Xcode/DerivedData/TodoListiOS-*/Build/Products/Debug-iphonesimulator/TodoListiOS.app -maxdepth 0 2>/dev/null | head -1)

xcrun simctl install booted "$APP"
xcrun simctl launch booted com.hayeah.TodoListiOS
```

You should see `[SwiftUITap] Polling http://localhost:9876` in the server output.

On simulator, the app automatically identifies itself with `SIMULATOR_UDID` when polling the relay. For on-device builds, set `SWIFTUI_TAP_UDID` at launch if you want the device to have a stable routing key.

## Verify

```bash
# Health check
curl localhost:9876/health

# Screenshot
swiftui-tap view screenshot -o screenshot.png

# View tree
swiftui-tap view tree

# State
swiftui-tap state get .
swiftui-tap state call addTodo title="Buy milk"

# Target one simulator/device explicitly
swiftui-tap --udid <simulator-udid> state call addTodo '{"title":"Only on this simulator"}'
```

## App Structure

```
TodoListiOS/
├── Package.swift
└── TodoListiOS/
    ├── TodoListiOSApp.swift      # App entry, .tapInspectable() + SwiftUITap.poll()
    ├── State/
    │   ├── AppState.swift        # Root state with @SwiftUITap macro
    │   └── TodoItem.swift        # Todo model with @SwiftUITap macro
    └── Views/
        └── ContentView.swift     # UI with .tapID() tags
```

## Notes

- The app is a pure SPM executable — no `.xcodeproj`. Xcode treats the `Package.swift` as a workspace when using `xcodebuild -scheme`.
- `swift build` won't work for iOS targets — use `xcodebuild` with a simulator destination.
- The `AGENTSDK_URL` env var overrides the default server URL (`http://localhost:9876`).
- The relay routes commands by UDID. `swiftui-tap --udid <udid>` and `SWIFTUI_TAP_UDID` target a specific app instance.
