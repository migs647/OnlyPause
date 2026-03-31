import AppKit

// MARK: - Bundle ID Constants

let musicAppBundleIDs: Set<String> = [
    "com.apple.Music",
    "com.spotify.client"
]

let browserBundleIDs: Set<String> = [
    "com.apple.Safari",
    "com.apple.SafariTechnologyPreview",
    "com.google.Chrome",
    "com.google.Chrome.canary",
    "org.mozilla.firefox",
    "company.thebrowser.Browser",   // Arc
    "com.microsoft.edgemac",
    "com.operasoftware.Opera",
    "com.brave.Browser"
]

// MARK: - NSWorkspace Extension

extension NSWorkspace {

    func isAppRunning(bundleID: String) -> Bool {
        runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    func runningApp(bundleID: String) -> NSRunningApplication? {
        runningApplications.first { $0.bundleIdentifier == bundleID }
    }

    var frontmostBrowser: NSRunningApplication? {
        guard let frontmost = frontmostApplication,
              browserBundleIDs.contains(frontmost.bundleIdentifier ?? "") else {
            return nil
        }
        return frontmost
    }

    var anyRunningBrowser: NSRunningApplication? {
        runningApplications.first { browserBundleIDs.contains($0.bundleIdentifier ?? "") }
    }

    var anyRunningMusicApp: NSRunningApplication? {
        runningApplications.first { musicAppBundleIDs.contains($0.bundleIdentifier ?? "") }
    }
}
