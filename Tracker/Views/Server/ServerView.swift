import SwiftUI
import TrackerKit
import UIKit

struct ServerView: View {
    @Environment(ConfigurationStore.self) private var store
    @Environment(TrackerEngine.self) private var engine
    @State private var testResult: RequestLogEntry?
    @State private var isTesting = false

    var body: some View {
        @Bindable var store = store
        let server = $store.configuration.server

        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/api/locations", text: server.endpoint, axis: .vertical)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: {
                    Text("Endpoint")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if !store.configuration.server.endpoint.isEmpty, !store.configuration.server.endpointURLIsValid {
                            Label("Enter a valid http or https URL.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        Text("Records are sent with POST. Placeholders are replaced with the latest values: \(URLTemplate.placeholders.joined(separator: " ")).")
                    }
                }

                Section {
                    Picker("Format", selection: server.format) {
                        ForEach(PayloadFormat.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Success When", selection: server.acknowledgement) {
                        ForEach(AcknowledgementMode.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(store.configuration.server.format == .owntracks)
                } header: {
                    Text("Protocol")
                } footer: {
                    Text(store.configuration.server.format == .owntracks
                        ? "OwnTracks receivers (Home Assistant, OwnTracks Recorder) get one object per request; any 2xx response counts as success. The device ID becomes the topic, owntracks/<device id>."
                        : "Batches of GeoJSON Features under \"locations\". Records are only removed from the queue once the server acknowledges them.")
                }

                Section("Authentication") {
                    Picker("Method", selection: server.authentication) {
                        ForEach(AuthenticationMethod.allCases) { Text($0.title).tag($0) }
                    }
                    switch store.configuration.server.authentication {
                    case .none:
                        EmptyView()
                    case .bearer:
                        SecureField("Access token", text: server.accessToken)
                            .textContentType(.password)
                            .font(.body.monospaced())
                    case .basic:
                        TextField("Username", text: server.username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: server.password)
                            .textContentType(.password)
                    }
                }

                Section {
                    ForEach(server.headers) { $header in
                        HStack {
                            TextField("Name", text: $header.name)
                                .font(.callout.monospaced())
                            Divider()
                            TextField("Value", text: $header.value)
                                .font(.callout.monospaced())
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }
                    .onDelete { store.configuration.server.headers.remove(atOffsets: $0) }
                    Button("Add Header", systemImage: "plus") {
                        store.configuration.server.headers.append(HTTPHeader())
                    }
                } header: {
                    Text("Custom Headers")
                } footer: {
                    Text("Sent with every request. Custom headers override the authentication header.")
                }

                Section {
                    TextField("Device ID", text: server.deviceID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle(isOn: server.includeUniqueID) {
                        FieldLabel(title: "Include Unique ID", key: "unique_id")
                    }
                } header: {
                    Text("Identity")
                } footer: {
                    Text("The device ID is included as device_id. The unique ID is the vendor identifier iOS assigns to this app on this device: \(UIDevice.current.identifierForVendor?.uuidString ?? "unavailable").")
                }

                Section {
                    Toggle(isOn: server.includeCurrentLocation) {
                        FieldLabel(title: "Attach Current Location", key: "current")
                    }
                    Toggle("Allow Remote Configuration", isOn: server.allowRemoteConfiguration)
                    OptionPicker("Timeout", selection: server.timeout, options: [10, 30, 60, 120]) {
                        Format.duration(seconds: $0)
                    }
                } header: {
                    Text("Behavior")
                } footer: {
                    Text("When the backlog is larger than one batch, the newest location is attached as current so the server knows where you are right away. Remote configuration lets the server change settings through a \"set\" object in its response.")
                }

                Section {
                    Button {
                        Task { await runTest() }
                    } label: {
                        HStack {
                            Label("Test Connection", systemImage: "bolt.horizontal")
                            Spacer()
                            if isTesting { ProgressView() }
                        }
                    }
                    .disabled(isTesting || !store.configuration.server.isConfigured)

                    if let testResult {
                        NavigationLink {
                            RequestDetailView(entry: testResult)
                        } label: {
                            RequestRow(entry: testResult)
                        }
                    }
                } footer: {
                    Text("Sends an empty batch and shows the response. Nothing is removed from the queue.")
                }
            }
            .navigationTitle("Server")
        }
    }

    private func runTest() async {
        isTesting = true
        defer { isTesting = false }
        testResult = await engine.testConnection()
    }
}
