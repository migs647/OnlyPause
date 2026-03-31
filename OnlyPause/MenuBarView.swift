import SwiftUI
import AppKit

struct MenuBarView: View {

    @Environment(PriorityManager.self) private var priorityManager
    @Environment(MediaKeyMonitor.self) private var mediaKeyMonitor

    var body: some View {
        @Bindable var priorityManager = priorityManager

        // Accessibility permission warning
        if mediaKeyMonitor.needsAccessibilityPermission {
            accessibilityWarningSection
            Divider()
        }

        // Priority mode selection
        Section("Priority Mode") {
            ForEach(PriorityMode.allCases) { mode in
                Button {
                    priorityManager.currentMode = mode
                } label: {
                    HStack {
                        Text(mode.menuDescription)
                        Spacer()
                        if priorityManager.currentMode == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }

        Divider()

        Toggle("Launch at Login", isOn: $priorityManager.launchAtLogin)

        Divider()

        Button("Quit OnlyPause") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    // MARK: - Subviews

    @ViewBuilder
    private var accessibilityWarningSection: some View {
        Section {
            Label(
                "Accessibility access required",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)

            Button("Open Privacy Settings…") {
                openAccessibilitySettings()
            }
        }
    }

    // MARK: - Actions

    private func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security"
                + "?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
