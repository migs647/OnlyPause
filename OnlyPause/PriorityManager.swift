import AppKit
import ServiceManagement
import Observation

// MARK: - Priority Mode

enum PriorityMode: String, CaseIterable, Identifiable {
    case allApps     = "All Apps"
    case musicOnly   = "Music Only"
    case browserOnly = "Browser Only"
    case smart       = "Smart"

    var id: String { rawValue }

    var menuBarIconName: String {
        switch self {
        case .allApps:     return "pause.circle"
        case .musicOnly:   return "music.note"
        case .browserOnly: return "safari"
        case .smart:       return "wand.and.stars"
        }
    }

    var menuDescription: String {
        switch self {
        case .allApps:     return "All Apps (Default)"
        case .musicOnly:   return "Music Only"
        case .browserOnly: return "Browser Only"
        case .smart:       return "Smart — Music if playing, else browser"
        }
    }
}

// MARK: - Priority Manager

@Observable
final class PriorityManager {

    // MARK: - Stored State

    var currentMode: PriorityMode {
        didSet {
            UserDefaults.standard.set(currentMode.rawValue, forKey: "priorityMode")
        }
    }

    /// Cached result of whether a music app is currently playing.
    /// Refreshed on a background timer to avoid blocking the event tap callback.
    private(set) var cachedMusicIsPlaying: Bool = false

    // MARK: - Computed State

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // SMAppService requires the app to be in /Applications.
                // Silently ignore failures during development.
            }
        }
    }

    // MARK: - Private

    private var musicStatePollingTimer: Timer?

    // MARK: - Init

    init() {
        let savedRawValue = UserDefaults.standard.string(forKey: "priorityMode") ?? ""
        self.currentMode = PriorityMode(rawValue: savedRawValue) ?? .allApps
        startMusicStatePolling()
    }

    deinit {
        musicStatePollingTimer?.invalidate()
    }

    // MARK: - Music State Polling

    private func startMusicStatePolling() {
        // Poll every 500ms so the event tap callback can read cachedMusicIsPlaying
        // synchronously without blocking. AppleScript runs on a background queue.
        musicStatePollingTimer = Timer.scheduledTimer(
            withTimeInterval: 0.5,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            // Only poll when smart mode is active — saves unnecessary work.
            guard self.currentMode == .smart else { return }

            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let isPlaying = self.checkMusicPlayingViaAppleScript()
                DispatchQueue.main.async { self.cachedMusicIsPlaying = isPlaying }
            }
        }
    }

    private func checkMusicPlayingViaAppleScript() -> Bool {
        guard NSWorkspace.shared.anyRunningMusicApp != nil else { return false }

        // Try Music.app first, fall back to Spotify
        if NSWorkspace.shared.isAppRunning(bundleID: "com.apple.Music") {
            let script = "tell application \"Music\" to return player state as string"
            var error: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
            return result?.stringValue == "playing"
        }

        if NSWorkspace.shared.isAppRunning(bundleID: "com.spotify.client") {
            let script = "tell application \"Spotify\" to return player state as string"
            var error: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
            return result?.stringValue == "playing"
        }

        return false
    }
}
