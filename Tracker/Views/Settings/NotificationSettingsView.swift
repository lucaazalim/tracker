import SwiftUI
import TrackerKit

struct NotificationSettingsView: View {
    @Environment(ConfigurationStore.self) private var store
    @Environment(TrackerEngine.self) private var engine

    var body: some View {
        @Bindable var store = store
        let notifications = $store.configuration.notifications

        Form {
            if engine.notificationAuthorization == .denied {
                Section {
                    Label("Notifications are turned off for Tracker in Settings.", systemImage: "bell.slash")
                    Button("Open Settings") { engine.openSystemSettings() }
                }
            }

            Section {
                Toggle("Tracking Stopped", isOn: notifications.watchdog)
                if store.configuration.notifications.watchdog {
                    OptionPicker("After", selection: notifications.watchdogMinutes, options: [5, 10, 15, 30, 60, 120, 240]) {
                        Format.duration(seconds: Double($0 * 60))
                    }
                }
            } header: {
                Text("Watchdog")
            } footer: {
                Text("Alerts you when continuous tracking hasn’t delivered a location for this long, for example because iOS terminated the app. It’s not armed while iOS has paused updates or in significant-change-only profiles.")
            }

            Section("Events") {
                Toggle("Tracking Paused by iOS", isOn: notifications.trackingPaused)
                Toggle("Tracking Resumed", isOn: notifications.trackingResumed)
                Toggle("Upload Failed", isOn: notifications.uploadFailed)
                Toggle("Settings Changed by Server", isOn: notifications.remoteConfigurationApplied)
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: store.configuration.notifications) { _, settings in
            guard settings.anyEnabled, engine.notificationAuthorization == .notDetermined else { return }
            Task {
                await engine.notifier.requestAuthorization()
                await engine.refreshSystemStatus()
            }
        }
        .task { await engine.refreshSystemStatus() }
    }
}
