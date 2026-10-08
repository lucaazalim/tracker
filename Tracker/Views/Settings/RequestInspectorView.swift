import SwiftUI
import TrackerKit

/// The last requests sent to the receiver, with headers and bodies, for debugging integrations.
struct RequestInspectorView: View {
    @Environment(TrackerEngine.self) private var engine
    @State private var entries: [RequestLogEntry] = []
    @State private var confirmingClear = false

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView("No Requests Yet", systemImage: "network", description: Text("Uploads and connection tests appear here."))
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(entries) { entry in
                        NavigationLink {
                            RequestDetailView(entry: entry)
                        } label: {
                            RequestRow(entry: entry)
                        }
                    }
                } footer: {
                    Text("The last \(QueueStore.maxLogEntries) requests. Bodies are truncated to 4 KB and credentials are masked.")
                }
            }
        }
        .navigationTitle("Request Inspector")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear", systemImage: "trash") { confirmingClear = true }
                    .disabled(entries.isEmpty)
            }
        }
        .confirmationDialog("Clear the request log?", isPresented: $confirmingClear) {
            Button("Clear Log", role: .destructive) {
                Task {
                    await engine.clearRequestLogs()
                    entries = []
                }
            }
        }
        .refreshable { entries = await engine.requestLogs() }
        .task(id: engine.lastUploadDate) { entries = await engine.requestLogs() }
    }
}

struct RequestRow: View {
    let entry: RequestLogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(entry.statusCode.map(String.init) ?? "ERR")
                .font(.caption.monospaced().bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(statusColor.opacity(0.15), in: .rect(cornerRadius: 6))
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(path)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(entry.date.formatted(date: .omitted, time: .standard)) · \(Format.records(entry.recordCount)) · \(Format.bytes(entry.requestBytes)) · \(entry.duration.formatted(.number.precision(.fractionLength(2)))) s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = entry.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
    }

    private var path: String {
        guard let url = URL(string: entry.url) else { return entry.url }
        return "\(entry.method) \(url.host() ?? "")\(url.path())"
    }

    private var statusColor: Color {
        entry.success ? .green : .red
    }
}

struct RequestDetailView: View {
    let entry: RequestLogEntry

    var body: some View {
        List {
            Section("Summary") {
                LabeledContent("Result", value: entry.success ? "Acknowledged" : "Failed")
                LabeledContent("Status", value: entry.statusCode.map(String.init) ?? "No response")
                LabeledContent("Date", value: entry.date.formatted(date: .abbreviated, time: .standard))
                LabeledContent("Duration", value: "\(entry.duration.formatted(.number.precision(.fractionLength(3)))) s")
                LabeledContent("Records", value: entry.recordCount.formatted())
                LabeledContent("Size", value: Format.bytes(entry.requestBytes))
                if let error = entry.error {
                    Text(error)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            Section("Request") {
                CodeBlock(text: "\(entry.method) \(entry.url)")
                CodeBlock(text: entry.requestHeaders)
                CodeBlock(text: prettified(entry.requestPreview))
            }
            Section("Response") {
                CodeBlock(text: prettified(entry.responsePreview))
            }
        }
        .navigationTitle("Request")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: shareText)
            }
        }
    }

    private var shareText: String {
        """
        \(entry.method) \(entry.url)
        \(entry.requestHeaders)

        \(entry.requestPreview)

        → \(entry.statusCode.map(String.init) ?? "no response") \(entry.error ?? "")
        \(entry.responsePreview)
        """
    }

    private func prettified(_ text: String) -> String {
        guard let value = try? JSONValue.decode(Data(text.utf8)) else { return text }
        return value.encodedString(pretty: true)
    }
}
