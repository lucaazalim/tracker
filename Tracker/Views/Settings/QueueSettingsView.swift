import SwiftUI
import TrackerKit

struct QueueSettingsView: View {
    @Environment(ConfigurationStore.self) private var store
    @Environment(TrackerEngine.self) private var engine
    @State private var confirmingDelete = false

    var body: some View {
        @Bindable var store = store
        let retention = $store.configuration.retention

        Form {
            Section("Queued") {
                LabeledContent("Locations", value: engine.queueCounts.locations.formatted())
                LabeledContent("Events", value: engine.queueCounts.events.formatted())
                Button("Upload Now", systemImage: "arrow.up.circle") {
                    Task { await engine.sendNow() }
                }
                .disabled(engine.isUploading || engine.queueCounts.total == 0 || !store.configuration.server.isConfigured)
            }

            Section {
                OptionPicker("Max Records", selection: retention.maxRecords, options: [nil, 10_000, 50_000, 100_000, 250_000, 500_000, 1_000_000]) {
                    $0.map { $0.formatted() } ?? "Unlimited"
                }
                OptionPicker("Max Age", selection: retention.maxAgeDays, options: [nil, 1, 3, 7, 14, 30, 90, 365]) {
                    $0.map { "\($0) days" } ?? "Unlimited"
                }
            } header: {
                Text("Retention")
            } footer: {
                Text("If the server is unreachable for a long time, the oldest records are dropped first so the queue can’t fill up your device. Each record is roughly 400–600 bytes.")
            }

            Section {
                Button("Delete All Queued Records", role: .destructive) {
                    confirmingDelete = true
                }
                .disabled(engine.queueCounts.total == 0)
            }
        }
        .navigationTitle("Queue & Retention")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete \(engine.queueCounts.total.formatted()) records that haven’t been uploaded?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await engine.deleteQueue() }
            }
        }
    }
}
