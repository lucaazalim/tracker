import SwiftUI
import TrackerKit

struct PayloadFieldsView: View {
    @Binding var fields: PayloadFields

    struct Field: Identifiable {
        let title: LocalizedStringKey
        let key: String
        let keyPath: WritableKeyPath<PayloadFields, Bool>
        var id: String { key }
    }

    struct FieldGroup: Identifiable {
        let title: LocalizedStringKey
        let footer: LocalizedStringKey?
        let fields: [Field]
        var id: String { fields.map(\.key).joined() }
    }

    static let groups: [FieldGroup] = [
        FieldGroup(title: "Position", footer: nil, fields: [
            Field(title: "Altitude", key: "altitude", keyPath: \.altitude),
            Field(title: "Floor", key: "floor", keyPath: \.floor),
        ]),
        FieldGroup(title: "Movement", footer: "Motion comes from the motion coprocessor, e.g. [\"driving\", \"stationary\"].", fields: [
            Field(title: "Speed", key: "speed", keyPath: \.speed),
            Field(title: "Course", key: "course", keyPath: \.course),
            Field(title: "Motion Activity", key: "motion", keyPath: \.motion),
        ]),
        FieldGroup(title: "Accuracy", footer: nil, fields: [
            Field(title: "Horizontal Accuracy", key: "horizontal_accuracy", keyPath: \.horizontalAccuracy),
            Field(title: "Vertical Accuracy", key: "vertical_accuracy", keyPath: \.verticalAccuracy),
            Field(title: "Speed Accuracy", key: "speed_accuracy", keyPath: \.speedAccuracy),
            Field(title: "Course Accuracy", key: "course_accuracy", keyPath: \.courseAccuracy),
        ]),
        FieldGroup(title: "Device", footer: "Device ID and unique ID are configured on the Server tab.", fields: [
            Field(title: "Battery Level", key: "battery_level", keyPath: \.batteryLevel),
            Field(title: "Battery State", key: "battery_state", keyPath: \.batteryState),
            Field(title: "Wi-Fi Network", key: "wifi", keyPath: \.wifi),
        ]),
        FieldGroup(title: "Diagnostics", footer: "Tracking stats add pauses, activity, desired_accuracy, tracking_mode and locations_in_payload. Lifecycle events are separate records (paused, resumed, tracking started, …) and are only sent in GeoJSON format.", fields: [
            Field(title: "Profile Name", key: "profile", keyPath: \.profileName),
            Field(title: "Tracking Stats", key: "pauses, activity, …", keyPath: \.trackingStats),
            Field(title: "Lifecycle Events", key: "action", keyPath: \.lifecycleEvents),
        ]),
    ]

    static var allFields: [Field] { groups.flatMap(\.fields) }

    var body: some View {
        Form {
            Section {
                FieldLabel(title: "Coordinates", key: "geometry.coordinates")
                FieldLabel(title: "Timestamp", key: "timestamp")
            } header: {
                Text("Always Included")
            }

            ForEach(Self.groups) { group in
                Section {
                    ForEach(group.fields) { field in
                        Toggle(isOn: $fields[dynamicMember: field.keyPath]) {
                            FieldLabel(title: field.title, key: field.key)
                        }
                    }
                } header: {
                    Text(group.title)
                } footer: {
                    if let footer = group.footer { Text(footer) }
                }
            }
        }
        .navigationTitle("Payload Fields")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Presets", systemImage: "wand.and.stars") {
                    Button("Defaults") { fields = PayloadFields() }
                    Button("Everything") { setAll(true) }
                    Button("Coordinates Only") { setAll(false) }
                }
            }
        }
    }

    private func setAll(_ value: Bool) {
        for field in Self.allFields {
            fields[keyPath: field.keyPath] = value
        }
    }
}

/// Shows a realistic sample record for the profile's current field selection and the configured format.
struct PayloadPreviewView: View {
    @Environment(ConfigurationStore.self) private var store
    let profile: Profile

    var body: some View {
        List {
            Section {
                CodeBlock(text: preview)
            } header: {
                Text(store.configuration.server.format.title)
            } footer: {
                Text("Sample values. Records are batched as {\"locations\": [...]} in GeoJSON format; OwnTracks sends one object per request.")
            }
        }
        .navigationTitle("Payload Preview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: preview)
            }
        }
    }

    private var preview: String {
        let server = store.configuration.server
        let sample = LocationSample(
            latitude: 45.5230622, longitude: -122.6764816, timestamp: .now, altitude: 15, speed: 1.42, course: 87,
            horizontalAccuracy: 5, verticalAccuracy: 3, speedAccuracy: 0.3, courseAccuracy: 12, floor: 2
        )
        let device = DeviceSnapshot(
            batteryLevel: 0.82, batteryState: .unplugged, wifiSSID: "HomeNetwork", motion: ["walking"],
            deviceID: server.deviceID, uniqueID: server.includeUniqueID ? "8C2A1E0B-5F7D-4C11-9C5B-2D3E4F5A6B7C" : nil
        )
        let record = PayloadBuilder.location(
            sample, device: device, context: CaptureContext(profile: profile, locationsInPayload: 1),
            fields: profile.fields, format: server.format
        )
        return record.encodedString(pretty: true)
    }
}
