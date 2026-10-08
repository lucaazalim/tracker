import SwiftUI
import TrackerKit

struct ProfilesView: View {
    @Environment(ConfigurationStore.self) private var store
    @Environment(TrackerEngine.self) private var engine
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(store.configuration.profiles) { profile in
                        NavigationLink(value: profile.id) {
                            ProfileRow(profile: profile, isActive: profile.id == store.configuration.activeProfileID)
                        }
                        .swipeActions(edge: .leading) {
                            if profile.id != store.configuration.activeProfileID {
                                Button("Activate", systemImage: "checkmark") { engine.activateProfile(id: profile.id) }
                                    .tint(.brand)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            if store.configuration.profiles.count > 1 {
                                Button("Delete", systemImage: "trash", role: .destructive) { store.deleteProfile(id: profile.id) }
                            }
                            Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(profile) }
                        }
                        .contextMenu {
                            Button("Activate", systemImage: "checkmark") { engine.activateProfile(id: profile.id) }
                                .disabled(profile.id == store.configuration.activeProfileID)
                            Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(profile) }
                            Button("Delete", systemImage: "trash", role: .destructive) { store.deleteProfile(id: profile.id) }
                                .disabled(store.configuration.profiles.count <= 1)
                        }
                    }
                    .onMove { source, destination in
                        store.update { $0.profiles.move(fromOffsets: source, toOffset: destination) }
                    }
                } footer: {
                    Text("A profile bundles capture, upload and payload settings. Switch profiles here, from the Status tab, with Shortcuts, or let your server switch them via remote configuration.")
                }
            }
            .navigationTitle("Profiles")
            .navigationDestination(for: UUID.self) { id in
                ProfileEditorView(profileID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Profile", systemImage: "plus") {
                        path.append(store.addProfile().id)
                    }
                }
            }
        }
    }

    private func duplicate(_ profile: Profile) {
        path.append(store.addProfile(basedOn: profile).id)
    }
}

private struct ProfileRow: View {
    let profile: Profile
    let isActive: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: profile.symbol)
                .font(.title3)
                .foregroundStyle(isActive ? Color.brand : .secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.headline)
                    if isActive {
                        Text("Active")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.brand.opacity(0.15), in: .capsule)
                            .foregroundStyle(Color.brand)
                    }
                }
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        let capture = profile.capture
        var parts = [capture.trackingMode.title, capture.desiredAccuracy.title]
        if capture.visits { parts.append("visits") }
        parts.append(Format.sendInterval(profile.upload.sendInterval).lowercased())
        return parts.joined(separator: " · ")
    }
}
