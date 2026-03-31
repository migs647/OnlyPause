import SwiftUI
import AppKit

@main
struct OnlyPauseApp: App {

    @State private var priorityManager = PriorityManager()
    @State private var mediaKeyMonitor = MediaKeyMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(priorityManager)
                .environment(mediaKeyMonitor)
                .task { mediaKeyMonitor.start(priorityManager: priorityManager) }
        } label: {
            Label("OnlyPause", systemImage: priorityManager.currentMode.menuBarIconName)
        }
        .menuBarExtraStyle(.menu)
    }

    init() {
        // Terminate if another instance is already running (e.g., one in /Applications
        // and another from Downloads).
        let runningInstances = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        )
        if runningInstances.count > 1 {
            NSApplication.shared.terminate(nil)
        }
    }
}
