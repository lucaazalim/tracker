import CoreImage.CIFilterBuiltins
import SwiftUI
import TrackerKit
import UniformTypeIdentifiers

/// Export the configuration as JSON, link or QR code, and import it on another device.
struct TransferView: View {
    @Environment(ConfigurationStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var includeSecrets = false
    @State private var importingFile = false

    var body: some View {
        List {
            Section {
                Toggle("Include Credentials", isOn: $includeSecrets)
            } footer: {
                Text("Credentials are the access token, password and header values. Leave this off when sharing publicly.")
            }

            Section("Export") {
                if let document = jsonDocument {
                    ShareLink(item: document, preview: SharePreview("Tracker configuration", image: Image(systemName: "doc.text"))) {
                        Label("Export JSON File", systemImage: "square.and.arrow.up")
                    }
                }
                if let link {
                    ShareLink(item: link) {
                        Label("Share Setup Link", systemImage: "link")
                    }
                }
            }

            if let link, let qrCode = QRCode.image(for: link.absoluteString) {
                Section {
                    qrCode
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(maxWidth: 280)
                        .padding()
                        .background(.white, in: .rect(cornerRadius: 16))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("QR code containing the configuration")
                } header: {
                    Text("QR Code")
                } footer: {
                    Text("Scan with the Camera app on another iPhone with Tracker installed. You’ll be asked to review the configuration before it’s applied.")
                }
            }

            Section {
                Button("Import JSON File…", systemImage: "doc.badge.plus") { importingFile = true }
                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first else { return }
                    importText(text)
                }
            } header: {
                Text("Import")
            } footer: {
                Text("Paste a JSON configuration, a tracker://import link, or an Overland-style tracker://setup?url=…&token=…&device_id=… link.")
            }
        }
        .navigationTitle("Import & Export")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.json, .plainText]) { result in
            switch result {
            case .success(let url):
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    router.pendingImport = PendingImport(value: .configuration(try ConfigurationTransfer.importJSON(data)))
                } catch {
                    router.importError = error.localizedDescription
                }
            case .failure(let error):
                router.importError = error.localizedDescription
            }
        }
    }

    private var jsonDocument: ConfigurationDocument? {
        (try? ConfigurationTransfer.exportJSON(store.configuration, includeSecrets: includeSecrets)).map(ConfigurationDocument.init)
    }

    private var link: URL? {
        try? ConfigurationTransfer.importLink(for: store.configuration, includeSecrets: includeSecrets)
    }

    private func importText(_ text: String) {
        do {
            router.pendingImport = PendingImport(value: try ConfigurationTransfer.parse(text: text))
        } catch {
            router.importError = error.localizedDescription
        }
    }
}

struct ConfigurationDocument: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { $0.data }
            .suggestedFileName("tracker-configuration.json")
    }
}

enum QRCode {
    static func image(for string: String) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "L"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return Image(decorative: cgImage, scale: 1)
    }
}
