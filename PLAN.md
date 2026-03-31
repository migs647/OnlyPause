# OnlyPause — Implementation Plan

## Context
This is a greenfield macOS menubar-only app. The problem: the media play/pause key on macOS
conflicts between Music.app and web browsers (Safari, Chrome, etc.) when a browser tab has
video playing. Users want to control which app "owns" the media key. The solution is a
menubar app that intercepts the global play/pause key and routes it based on a user-selected
priority mode.

---

## Phase 0 — Xcode Project Creation (Manual Step)

Before writing any code, the Xcode project must be created by the user:

1. Open Xcode → File → New → Project → macOS → App
2. Product Name: `OnlyPause`, Bundle ID: `com.yourname.OnlyPause`
3. Interface: SwiftUI, Language: Swift
4. **Deployment Target**: macOS 26.4 (Tahoe)
5. In Signing & Capabilities: **remove App Sandbox** entitlement
6. In Signing & Capabilities: **add Automation (Apple Events)** capability

Xcode 26 manages entitlements directly through Signing & Capabilities — no separate
`.entitlements` file is needed.

---

## File Structure

```
OnlyPause/
├── OnlyPauseApp.swift              # @main App, MenuBarExtra, startup sequencing
├── PriorityManager.swift           # Mode enum, persistence, Music state cache, SMAppService
├── MediaKeyMonitor.swift           # CGEventTap, C callback, routing logic
├── MenuBarView.swift               # SwiftUI menu UI
├── Extensions/
│   ├── NSWorkspace+Apps.swift      # Helpers + bundle ID constants
│   └── NSEvent+MediaKey.swift      # Decode media key data1 field
└── (Info.plist generated from build settings)
```

---

## 1. Info.plist (via Build Settings)

Set in `project.pbxproj` under `INFOPLIST_KEY_*`:
- `INFOPLIST_KEY_LSUIElement = YES` — suppresses Dock icon and App Switcher entry
- `INFOPLIST_KEY_NSAccessibilityUsageDescription` — required for Accessibility permission prompt
- `INFOPLIST_KEY_NSAppleEventsUsageDescription` — required for AppleScript to Music/Spotify
- `AUTOMATION_APPLE_EVENTS = YES` — enables the apple-events entitlement

---

## 2. Entitlements

Applied via Signing & Capabilities in Xcode:
- **App Sandbox**: removed/disabled — `CGEvent.tapCreate` at `.cgSessionEventTap` is blocked
  by sandbox with no entitlement workaround. App Store distribution is not possible;
  distribute via notarized DMG with Developer ID.
- **Automation (Apple Events)**: added — required for AppleScript calls to Music/Spotify

Verify after building: `codesign -d --entitlements :- OnlyPause.app`

---

## 3. PriorityMode + PriorityManager

`PriorityMode` enum (rawValue = String for UserDefaults):
- `.allApps` — pass event through unchanged (default macOS behavior)
- `.musicOnly` — route to Music.app or Spotify via AppleScript
- `.browserOnly` — route to frontmost/running browser via `CGEvent.postToPid`
- `.smart` — Music if Music is playing (cached), else browser

`PriorityManager` (`@Observable`):
- Persists mode to `UserDefaults`
- Owns `cachedMusicIsPlaying: Bool` refreshed every 0.5s on background queue
- `launchAtLogin` computed property via `SMAppService.mainApp` (register/unregister)
- Starts music state polling timer on init; polling only executes in `.smart` mode

---

## 4. MediaKeyMonitor (Core Engine)

`@Observable` class. All setup on main thread — `CGEventTap` requires the main `RunLoop`.

### Media Key Mechanics
Media keys arrive as `NSEvent.type == .systemDefined` (raw value 14), subtype 8.
Play/pause key code: `NX_KEYTYPE_PLAY = 16`, encoded in `NSEvent.data1` bits 16–31.
Key-down flag: bits 8–15 == `0x0A`.

### CGEventTap Setup (macOS Tahoe APIs)
```swift
let eventMask = CGEventMask(1 << 14)  // NX_SYSDEFINED
CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                  options: .defaultTap, eventsOfInterest: eventMask,
                  callback: mediaKeyEventTapCallback, userInfo: selfPtr)
CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
```

Use `.defaultTap` (not `.listenOnly`) — must be able to suppress events by returning `nil`.
Use `Unmanaged.passRetained(self)` to bridge self into the C callback.

### C Callback (free function, not method)
```swift
private nonisolated func mediaKeyEventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType,
    event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>?
```
- Handles `.tapDisabledByTimeout` / `.tapDisabledByUserInput` by calling
  `CGEvent.tapEnable(tap:enable:)` via `MainActor.assumeIsolated`
- Delegates to `monitor.handleEvent(event)` via `MainActor.assumeIsolated`
  (safe because the tap fires on the main RunLoop)

### Routing Logic (in handleEvent)
- `.allApps`: return event (pass through — do not suppress)
- `.musicOnly`: suppress + `sendPlayPauseToMusicApp()`
- `.browserOnly`: suppress + `sendPlayPauseToBrowser()`
- `.smart`: suppress + check `priorityManager.cachedMusicIsPlaying` + route accordingly

### Sending to Music
AppleScript on `DispatchQueue.global(.userInitiated)` to avoid blocking the tap callback:
- Music: `tell application "Music" to playpause`
- Spotify: `tell application "Spotify" to playpause`

Guard with `NSWorkspace.shared.isAppRunning(bundleID:)` before scripting to avoid
cold-launching the music app unintentionally.

### Sending to Browser
Build a synthetic `NSSystemDefined` event with `NX_KEYTYPE_PLAY` data1 encoding,
then call `syntheticEvent.postToPid(pid)` for both key-down and key-up.
Target: `NSWorkspace.shared.frontmostBrowser ?? NSWorkspace.shared.anyRunningBrowser`.
Re-fetch `NSRunningApplication` at time of posting — never cache PIDs.

### Accessibility Permission Flow
1. `AXIsProcessTrusted()` on `start()`
2. If false: call `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`
   — shows system dialog and opens System Settings > Privacy > Accessibility automatically
3. Poll every 2s until `AXIsProcessTrusted()` returns true, then call `installEventTap()`
4. Handle revocation via `.tapDisabledByUserInput` in the callback + re-check trust

---

## 5. MenuBarView

`MenuBarExtra` with `.menuBarExtraStyle(.menu)` (native NSMenu dropdown, not popover).
Dynamic icon in the label closure reacts to `priorityManager.currentMode` changes via
`@Observable`.

Menu contents:
- Warning section (orange) + "Open Privacy Settings…" button if `needsAccessibilityPermission`
- Section "Priority Mode": `ForEach(PriorityMode.allCases)` with checkmark on active mode
- `Toggle("Launch at Login", isOn: $manager.launchAtLogin)`
- `Button("Quit OnlyPause")` with `.keyboardShortcut("q")`

Monitor is started via `.task` on the `MenuBarExtra` content view, wiring
`MediaKeyMonitor` to `PriorityManager` after both `@State` values are initialized.

---

## 6. Extensions

**NSWorkspace+Apps.swift**
- `musicAppBundleIDs: Set<String>` — Music.app, Spotify
- `browserBundleIDs: Set<String>` — Safari, Chrome, Firefox, Arc, Edge, Opera, Brave
- `isAppRunning(bundleID:)`, `runningApp(bundleID:)`, `frontmostBrowser`, `anyRunningBrowser`,
  `anyRunningMusicApp`

**NSEvent+MediaKey.swift**
- `isPlayPauseKey` — checks type `.systemDefined`, subtype 8, keyCode == 16
- `isMediaKeyDown` — checks flags byte == `0x0A`

---

## 7. Critical Gotchas

| Risk | Mitigation |
|---|---|
| CGEventTap timeout (~1–2s limit) | AppleScript runs on background queue; tap callback reads `cachedMusicIsPlaying` synchronously |
| Duplicate instances | Check `NSRunningApplication.runningApplications(withBundleIdentifier:)` on startup |
| Stale browser PID | Re-fetch `NSRunningApplication` at time of posting, never cache PIDs |
| Music.app cold launch | Guard with `isAppRunning` before every AppleScript call |
| Permission revocation | Handle `.tapDisabledByUserInput` + re-check `AXIsProcessTrusted()` |
| Universal Binary | Verify with `lipo -archs` after building; both `x86_64` and `arm64` required |
| Sendable in C callback | Use `MainActor.assumeIsolated` instead of `DispatchQueue.main.async` |
| SWIFT_DEFAULT_ACTOR_ISOLATION | C callback must be `nonisolated`; bridge to MainActor explicitly |

---

## 8. Threading Model

- **Main thread**: SwiftUI views, CFRunLoop (CGEventTap callback), all `@Observable` mutations
- **Background (`DispatchQueue.global(.userInitiated)`)**: AppleScript `playpause` calls
- **Background (`DispatchQueue.global(.utility)`)**: Music state polling for Smart mode
- **Result dispatch**: `DispatchQueue.main.async` to update `cachedMusicIsPlaying`

---

## Verification

1. Build → confirm `BUILD SUCCEEDED` with no errors
2. First launch → Accessibility permission dialog appears automatically
3. Grant permission → tap installs without relaunch (via 2s polling loop)
4. Set **Music Only** → play/pause toggles Music, does not affect Safari video
5. Set **Browser Only** → Safari video pauses, Music is unaffected
6. Set **Smart** → Music if playing, browser if not
7. Set **All Apps** → default macOS behavior restored
8. Toggle **Launch at Login** → verify in System Settings > General > Login Items
9. `lipo -archs OnlyPause.app/Contents/MacOS/OnlyPause` → shows `x86_64 arm64`
10. Test with Spotify running as the music source
