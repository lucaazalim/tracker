import SwiftUI
import TrackerKit

struct ProfileEditorView: View {
    @Environment(ConfigurationStore.self) private var store
    @Environment(TrackerEngine.self) private var engine
    let profileID: UUID

    var body: some View {
        if let profile = store.profile(id: profileID) {
            ProfileForm(
                profile: Binding(get: { store.profile(id: profileID) ?? profile }, set: { store.updateProfile($0) }),
                isActive: store.configuration.activeProfileID == profileID,
                activate: { engine.activateProfile(id: profileID) }
            )
        } else {
            ContentUnavailableView("Profile Deleted", systemImage: "trash", description: Text("This profile no longer exists."))
        }
    }
}

private struct ProfileForm: View {
    @Binding var profile: Profile
    let isActive: Bool
    let activate: () -> Void

    var body: some View {
        Form {
            Section {
                LabeledContent("Name") {
                    TextField("Name", text: $profile.name)
                        .multilineTextAlignment(.trailing)
                }
                SymbolGrid(selection: $profile.symbol)
                if !isActive {
                    Button("Make Active", systemImage: "checkmark.circle", action: activate)
                }
            }

            locationSection
            backgroundSection
            filterSection
            uploadSection

            Section {
                NavigationLink {
                    PayloadFieldsView(fields: $profile.fields)
                } label: {
                    LabeledContent("Fields", value: "\(enabledFieldCount) enabled")
                }
                NavigationLink("Preview Payload") {
                    PayloadPreviewView(profile: profile)
                }
            } header: {
                Text("Payload")
            } footer: {
                Text("Choose exactly which properties each record contains. Coordinates and timestamp are always included.")
            }
        }
        .navigationTitle(profile.name.isEmpty ? "Profile" : profile.name)
        .scrollDismissesKeyboard(.interactively)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Sections

    private var locationSection: some View {
        Section {
            Picker("Updates", selection: $profile.capture.trackingMode) {
                ForEach(TrackingMode.allCases) { Text($0.title).tag($0) }
            }
            Picker("Desired Accuracy", selection: $profile.capture.desiredAccuracy) {
                ForEach(DesiredAccuracy.allCases) { Text($0.title).tag($0) }
            }
            Picker("Activity Type", selection: $profile.capture.activityType) {
                ForEach(ActivityType.allCases) { Text($0.title).tag($0) }
            }
            OptionPicker("System Distance Filter", selection: $profile.capture.systemDistanceFilter, options: [0, 5, 10, 25, 50, 100, 250, 500, 1000]) {
                $0 <= 0 ? "None" : Format.distance($0)
            }
            Toggle("Record Visits", isOn: $profile.capture.visits)
        } header: {
            Text("Location")
        } footer: {
            Text("Standard updates give detailed tracks; significant changes use almost no battery but arrive only every few hundred meters. The system distance filter is applied by iOS and saves battery. Visits are recorded when you arrive at or leave a place.")
        }
    }

    private var backgroundSection: some View {
        Section {
            Toggle("Pause Automatically", isOn: $profile.capture.pausesAutomatically.animation())
            if profile.capture.pausesAutomatically {
                OptionPicker("Resume With Geofence", selection: $profile.capture.resumeGeofenceRadius, options: [nil, 100, 200, 500, 1000, 2000]) {
                    Format.optionalDistance($0)
                }
            }
            Toggle("Background Indicator", isOn: $profile.capture.showsBackgroundIndicator)
        } header: {
            Text("Background")
        } footer: {
            Text("When iOS pauses updates because you stopped moving, an exit geofence of the chosen radius wakes Tracker again when you leave. The blue status bar indicator helps iOS keep tracking alive.")
        }
    }

    private var filterSection: some View {
        Section {
            OptionPicker("Min Distance", selection: $profile.capture.minDistance, options: [0, 1, 5, 10, 25, 50, 100, 250, 500]) {
                Format.distance($0)
            }
            OptionPicker("Min Interval", selection: $profile.capture.minInterval, options: [0, 1, 5, 10, 15, 30, 60, 120, 300]) {
                Format.duration(seconds: $0)
            }
        } header: {
            Text("Filters")
        } footer: {
            Text("Points closer in distance or time to the previous recorded point are dropped before they are queued. This reduces data, not battery use.")
        }
    }

    private var uploadSection: some View {
        Section {
            OptionPicker("Send Interval", selection: $profile.upload.sendInterval, options: [nil, 1, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]) {
                $0.map { Format.duration(seconds: Double($0)) } ?? "Manual only"
            }
            OptionPicker("Batch Size", selection: $profile.upload.batchSize, options: [10, 50, 100, 200, 500, 1000]) {
                "\($0) records"
            }
            Picker("Queue", selection: $profile.upload.queueStrategy) {
                ForEach(QueueStrategy.allCases) { Text($0.title).tag($0) }
            }
        } header: {
            Text("Upload")
        } footer: {
            Text("Uploads run when a location arrives and the interval has passed, and periodically in the background. “Latest only” keeps just the newest location in the queue.")
        }
    }

    private var enabledFieldCount: Int {
        PayloadFieldsView.allFields.filter { profile.fields[keyPath: $0.keyPath] }.count
    }
}

/// Inline grid of profile symbols; the selection is highlighted with tinted glass.
private struct SymbolGrid: View {
    @Binding var selection: String

    private var symbols: [String] {
        ProfileSymbols.all.contains(selection) ? ProfileSymbols.all : [selection] + ProfileSymbols.all
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 8)], spacing: 8) {
            ForEach(symbols, id: \.self) { symbol in
                let isSelected = symbol == selection
                Button {
                    selection = symbol
                } label: {
                    Image(systemName: symbol)
                        .font(.body)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .frame(width: 40, height: 40)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(isSelected ? .regular.tint(.brand).interactive() : .identity, in: .circle)
                .accessibilityLabel(symbol)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}
