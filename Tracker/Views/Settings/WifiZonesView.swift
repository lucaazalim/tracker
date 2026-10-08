import SwiftUI
import TrackerKit

struct WifiZonesView: View {
    @Environment(ConfigurationStore.self) private var store
    @Environment(TrackerEngine.self) private var engine
    @State private var editing: WifiZone?

    var body: some View {
        List {
            Section {
                ForEach(store.configuration.wifiZones) { zone in
                    Button {
                        editing = zone
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(zone.ssid).font(.headline)
                                if zone.ssid == engine.currentSSID {
                                    Text("Connected")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.green)
                                }
                            }
                            Text("\(zone.action.title) · \(String(format: "%.5f, %.5f", zone.latitude, zone.longitude))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(.primary)
                }
                .onDelete { store.configuration.wifiZones.remove(atOffsets: $0) }
            } footer: {
                Text("While connected to one of these networks, Tracker either records the zone’s fixed coordinate (no GPS drift at home) or records nothing. Requires location access and the Access Wi-Fi Information entitlement.")
            }

            Section {
                LabeledContent("Current Network", value: engine.currentSSID ?? "Not connected")
            }
        }
        .navigationTitle("Wi-Fi Zones")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add Zone", systemImage: "plus") {
                    editing = WifiZone(
                        ssid: engine.currentSSID ?? "",
                        latitude: engine.lastLocation?.latitude ?? 0,
                        longitude: engine.lastLocation?.longitude ?? 0
                    )
                }
            }
        }
        .sheet(item: $editing) { zone in
            WifiZoneEditor(zone: zone) { saved in
                store.update { config in
                    if let index = config.wifiZones.firstIndex(where: { $0.id == saved.id }) {
                        config.wifiZones[index] = saved
                    } else {
                        config.wifiZones.append(saved)
                    }
                }
            }
            .tint(.brand)
        }
        .task { await engine.refreshSSID(force: true) }
    }
}

private struct WifiZoneEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TrackerEngine.self) private var engine
    @State var zone: WifiZone
    let onSave: (WifiZone) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Network") {
                    TextField("SSID", text: $zone.ssid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("While Connected", selection: $zone.action) {
                        ForEach(WifiZoneAction.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section {
                    LabeledContent("Latitude") {
                        TextField("Latitude", value: $zone.latitude, format: .number.precision(.fractionLength(0...7)))
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Longitude") {
                        TextField("Longitude", value: $zone.longitude, format: .number.precision(.fractionLength(0...7)))
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                    }
                    if let location = engine.lastLocation {
                        Button("Use Last Location", systemImage: "location") {
                            zone.latitude = location.latitude
                            zone.longitude = location.longitude
                        }
                    }
                } header: {
                    Text("Fixed Location")
                } footer: {
                    Text("Recorded instead of the reported location when “Use fixed location” is selected.")
                }
            }
            .navigationTitle("Wi-Fi Zone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", role: .confirm) {
                        onSave(zone)
                        dismiss()
                    }
                    .disabled(zone.ssid.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
