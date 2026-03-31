import AppKit
import CoreGraphics
import Observation

// CGEventType raw value 14 = NX_SYSDEFINED (system-defined events, including media keys)
private let cgEventTypeSystemDefined = CGEventType(rawValue: 14)!

// MARK: - Media Key Monitor

@Observable
final class MediaKeyMonitor {

    // MARK: - Observable State

    var isRunning: Bool = false
    var needsAccessibilityPermission: Bool = false

    // MARK: - Dependencies

    var priorityManager: PriorityManager?

    // MARK: - Private

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var accessibilityPollingTimer: Timer?

    // MARK: - Lifecycle

    func start(priorityManager: PriorityManager) {
        self.priorityManager = priorityManager

        guard AXIsProcessTrusted() else {
            needsAccessibilityPermission = true
            requestAccessibilityPermission()
            startAccessibilityPolling()
            return
        }

        needsAccessibilityPermission = false
        installEventTap()
    }

    func stop() {
        accessibilityPollingTimer?.invalidate()
        accessibilityPollingTimer = nil

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isRunning = false
    }

    // MARK: - Accessibility Permission

    private func requestAccessibilityPermission() {
        // Passing kAXTrustedCheckOptionPrompt = true shows the system dialog
        // and opens System Settings > Privacy > Accessibility automatically.
        let options = [
            kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true
        ] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private func startAccessibilityPolling() {
        // Poll every 2 seconds until the user grants access.
        // There is no system notification for this — polling is the standard approach.
        accessibilityPollingTimer = Timer.scheduledTimer(
            withTimeInterval: 2.0,
            repeats: true
        ) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if AXIsProcessTrusted() {
                timer.invalidate()
                self.accessibilityPollingTimer = nil
                self.needsAccessibilityPermission = false
                self.installEventTap()
            }
        }
    }

    // MARK: - Event Tap Installation

    private func installEventTap() {
        // Intercept NX_SYSDEFINED events (raw type 14) which carry media key data.
        let eventMask = CGEventMask(1 << cgEventTypeSystemDefined.rawValue)

        // Bridge self into the C callback via Unmanaged. The tap retains it via userInfo.
        let selfPointer = Unmanaged.passRetained(self).toOpaque()

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,   // Must be .defaultTap to suppress events
            eventsOfInterest: eventMask,
            callback: mediaKeyEventTapCallback,
            userInfo: selfPointer
        )

        guard let tap else {
            // Fails silently if accessibility permission is not granted.
            needsAccessibilityPermission = true
            startAccessibilityPolling()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        self.isRunning = true
    }

    // MARK: - Event Handling (called from C callback)

    fileprivate func handleEvent(_ cgEvent: CGEvent) -> CGEvent? {
        guard let nsEvent = NSEvent(cgEvent: cgEvent),
              nsEvent.isPlayPauseKey,
              nsEvent.isMediaKeyDown else {
            return cgEvent   // Not a play/pause key-down — pass through unchanged
        }

        guard let manager = priorityManager else { return cgEvent }

        switch manager.currentMode {
        case .allApps:
            return cgEvent   // Let the OS deliver it normally

        case .musicOnly:
            sendPlayPauseToMusicApp()
            return nil       // Suppress original event

        case .browserOnly:
            sendPlayPauseToBrowser()
            return nil

        case .smart:
            if manager.cachedMusicIsPlaying {
                sendPlayPauseToMusicApp()
            } else {
                sendPlayPauseToBrowser()
            }
            return nil
        }
    }

    // MARK: - Tap Re-enable (called from C callback)

    fileprivate func reEnableEventTap() {
        // The OS disables the tap on timeout (~1–2s) or user input event.
        // We must re-enable it immediately or media keys stop working.
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        // Re-check permission in case the tap was disabled due to revocation.
        if !AXIsProcessTrusted() {
            needsAccessibilityPermission = true
            startAccessibilityPolling()
        }
    }

    // MARK: - Routing: Music

    private func sendPlayPauseToMusicApp() {
        // Guard against cold-launching the music app unintentionally.
        guard NSWorkspace.shared.anyRunningMusicApp != nil else { return }

        if NSWorkspace.shared.isAppRunning(bundleID: "com.apple.Music") {
            executeAppleScript("tell application \"Music\" to playpause")
        } else if NSWorkspace.shared.isAppRunning(bundleID: "com.spotify.client") {
            executeAppleScript("tell application \"Spotify\" to playpause")
        }
    }

    private func executeAppleScript(_ source: String) {
        // AppleScript can block up to ~500ms on a slow system. Run on background queue
        // so we don't block the main RunLoop (and risk timing out the event tap).
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }

    // MARK: - Routing: Browser

    private func sendPlayPauseToBrowser() {
        // Re-fetch the running application at time of posting — never cache PIDs.
        guard let browser = NSWorkspace.shared.frontmostBrowser
                          ?? NSWorkspace.shared.anyRunningBrowser else { return }

        let pid = browser.processIdentifier
        postSyntheticMediaKeyEvent(toPID: pid, keyDown: true)
        postSyntheticMediaKeyEvent(toPID: pid, keyDown: false)
    }

    private func postSyntheticMediaKeyEvent(toPID pid: pid_t, keyDown: Bool) {
        // Encode data1: (keyCode << 16) | (flags << 8) | keyState
        // flags: 0x0A = key down, 0x0B = key up
        // keyState: 0 = down, 1 = up
        let keyFlags: Int32 = keyDown ? 0x0A : 0x0B
        let keyState: Int32 = keyDown ? 0 : 1
        let data1 = Int((nxKeyTypePlay << 16) | (keyFlags << 8) | keyState)

        guard let syntheticEvent = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: nxSystemDefinedSubtype,
            data1: data1,
            data2: -1
        )?.cgEvent else { return }

        syntheticEvent.postToPid(pid)
    }
}

// MARK: - C Event Tap Callback

/// Must be a free function (not a method) to be used as a C function pointer.
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is set project-wide, so mark nonisolated.
private nonisolated func mediaKeyEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    guard let userInfo else { return Unmanaged.passRetained(event) }
    let monitor = Unmanaged<MediaKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    // The OS disables the tap if the callback is too slow or on certain system events.
    // The tap fires on the main RunLoop, so MainActor.assumeIsolated is safe here.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { monitor.reEnableEventTap() }
        return Unmanaged.passRetained(event)
    }

    // handleEvent must run on the main actor since MediaKeyMonitor is @MainActor.
    // CGEventTap callbacks fire on the main RunLoop — assumeIsolated is safe.
    let result = MainActor.assumeIsolated { monitor.handleEvent(event) }

    if let result {
        return Unmanaged.passRetained(result)
    }
    return nil   // nil = suppress the event
}
