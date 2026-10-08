import SwiftUI
import TrackerKit

struct SettingsView: View {
    @Environment(ConfigurationStore.self) private var store
    @Environment(TrackerEngine.self) private var engine

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        WifiZonesView()
                    } label: {
                        LabeledContent {
                            Text(store.configuration.wifiZones.count, format: .number)
                        } label: {
                            Label("Wi-Fi Zones", systemImage: "wifi")
                        }
                    }
                    NavigationLink {
                        NotificationSettingsView()
                    } label: {
                        Label("Notifications", systemImage: "bell.badge")
                    }
                    NavigationLink {
                        QueueSettingsView()
                    } label: {
                        LabeledContent {
                            Text(engine.queueCounts.total, format: .number)
                        } label: {
                            Label("Queue & Retention", systemImage: "tray.full")
                        }
                    }
                }

                Section {
                    NavigationLink {
                        RequestInspectorView()
                    } label: {
                        Label("Request Inspector", systemImage: "network")
                    }
                    NavigationLink {
                        TransferView()
                    } label: {
                        Label("Import & Export", systemImage: "arrow.up.arrow.down.square")
                    }
                }

                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("About Tracker", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "location.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.tint)
                    Text("Tracker")
                        .font(.title.bold())
                    Text("Your location, delivered to your own server.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent("Version", value: version)
                LabeledContent("License", value: "MIT")
            }

            Section {
                Text("Tracker is open source and sends data only to the server you configure. There is no analytics, no account and no third-party service.")
                Text("Inspired by Overland by Aaron Parecki. The GeoJSON format is compatible with Overland receivers such as Dawarich, Compass and Wayfinder.")
            }
            .font(.callout)
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
