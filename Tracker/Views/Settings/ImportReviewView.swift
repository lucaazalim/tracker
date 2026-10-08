import SwiftUI
import TrackerKit

/// Every incoming configuration (deep link, QR code, file, paste) is reviewed before it's applied,
/// so a malicious link can't silently redirect location data to another server.
struct ImportReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ConfigurationStore.self) private var store
    let pending: PendingImport
    @State private var keepCredentials = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        Text("Location data will be sent to the endpoint below. Only continue if you trust the source of this configuration.")
                    } icon: {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.callout)
                }

                switch pending.value {
                case .setup(let parameters):
                    setupSummary(parameters)
                case .configuration(let configuration):
                    configurationSummary(configuration)
                }
            }
            .navigationTitle("Review Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply", role: .confirm) {
                        apply()
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled()
        .tint(.brand)
    }

    @ViewBuilder
    private func setupSummary(_ parameters: SetupParameters) -> some View {
        Section("Changes") {
            if let endpoint = parameters.endpoint {
                LabeledContent("Endpoint") {
                    Text(endpoint).font(.callout.monospaced()).textSelection(.enabled)
                }
            }
            if let token = parameters.token {
                LabeledContent("Access Token", value: token.isEmpty ? "(empty)" : "••••••")
            }
            if let deviceID = parameters.deviceID {
                LabeledContent("Device ID", value: deviceID)
            }
            if let includeUniqueID = parameters.includeUniqueID {
                LabeledContent("Include Unique ID", value: includeUniqueID ? "Yes" : "No")
            }
        }
    }

    @ViewBuilder
    private func configurationSummary(_ configuration: TrackerConfiguration) -> some View {
        Section("Server") {
            LabeledContent("Endpoint") {
                Text(configuration.server.endpoint.isEmpty ? "(none)" : configuration.server.endpoint)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
            LabeledContent("Format", value: configuration.server.format.title)
            LabeledContent("Authentication", value: configuration.server.authentication.title)
            LabeledContent("Custom Headers", value: configuration.server.headers.count.formatted())
            LabeledContent("Remote Configuration", value: configuration.server.allowRemoteConfiguration ? "Allowed" : "Off")
        }

        Section("Profiles") {
            ForEach(configuration.profiles) { profile in
                Label {
                    HStack {
                        Text(profile.name)
                        if profile.id == configuration.activeProfileID {
                            Spacer()
                            Text("Active").foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: profile.symbol)
                }
            }
        }

        Section {
            LabeledContent("Wi-Fi Zones", value: configuration.wifiZones.count.formatted())
        } footer: {
            Text("This replaces your entire configuration. Queued records are kept.")
        }

        if hasMissingCredentials(configuration) {
            Section {
                Toggle("Keep My Current Credentials", isOn: $keepCredentials)
            } footer: {
                Text("The imported configuration doesn’t include credentials.")
            }
        }
    }

    private func hasMissingCredentials(_ configuration: TrackerConfiguration) -> Bool {
        let current = store.configuration.server
        let incoming = configuration.server
        return (incoming.accessToken.isEmpty && !current.accessToken.isEmpty)
            || (incoming.password.isEmpty && !current.password.isEmpty)
    }

    private func apply() {
        switch pending.value {
        case .setup(let parameters):
            store.configuration = parameters.apply(to: store.configuration)
        case .configuration(var configuration):
            if keepCredentials, hasMissingCredentials(configuration) {
                let current = store.configuration.server
                if configuration.server.accessToken.isEmpty { configuration.server.accessToken = current.accessToken }
                if configuration.server.password.isEmpty { configuration.server.password = current.password }
            }
            store.configuration = configuration
        }
    }
}
