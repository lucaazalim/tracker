import Foundation

public enum ConfigurationTransferError: Error, LocalizedError, Sendable {
    case unsupportedLink
    case missingPayload
    case invalidPayload(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedLink: "This link is not a Tracker setup or import link."
        case .missingPayload: "The link does not contain a configuration."
        case .invalidPayload(let reason): "The configuration could not be read: \(reason)"
        }
    }
}

/// A link or pasted text that changes the configuration. Always confirmed by the user before applying.
public enum ConfigurationImport: Sendable, Equatable {
    /// Overland-style quick setup: `tracker://setup?url=…&token=…&device_id=…&unique_id=yes`
    case setup(SetupParameters)
    /// A complete configuration: `tracker://import?config=…` or a JSON document.
    case configuration(TrackerConfiguration)
}

public struct SetupParameters: Sendable, Equatable {
    public var endpoint: String?
    public var token: String?
    public var deviceID: String?
    public var includeUniqueID: Bool?

    public init(endpoint: String? = nil, token: String? = nil, deviceID: String? = nil, includeUniqueID: Bool? = nil) {
        self.endpoint = endpoint
        self.token = token
        self.deviceID = deviceID
        self.includeUniqueID = includeUniqueID
    }

    public func apply(to configuration: TrackerConfiguration) -> TrackerConfiguration {
        var config = configuration
        if let endpoint { config.server.endpoint = endpoint }
        if let token {
            config.server.accessToken = token
            if !token.isEmpty { config.server.authentication = .bearer }
        }
        if let deviceID { config.server.deviceID = deviceID }
        if let includeUniqueID { config.server.includeUniqueID = includeUniqueID }
        return config
    }
}

/// Export and import of configurations as JSON files, links and QR codes.
public enum ConfigurationTransfer {
    /// URL scheme registered by the app.
    public static let scheme = "tracker"

    // MARK: JSON

    public static func exportJSON(_ configuration: TrackerConfiguration, includeSecrets: Bool) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(includeSecrets ? configuration : configuration.redacted())
    }

    public static func importJSON(_ data: Data) throws -> TrackerConfiguration {
        do {
            return try JSONDecoder().decode(TrackerConfiguration.self, from: data)
        } catch let error as DecodingError {
            throw ConfigurationTransferError.invalidPayload(describe(error))
        }
    }

    // MARK: Links

    /// A compact `tracker://import?config=…` link (zlib + base64url). Suitable for QR codes.
    public static func importLink(for configuration: TrackerConfiguration, includeSecrets: Bool) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(includeSecrets ? configuration : configuration.redacted())
        let compressed = try (json as NSData).compressed(using: .zlib) as Data
        var components = URLComponents()
        components.scheme = scheme
        components.host = "import"
        components.queryItems = [URLQueryItem(name: "config", value: base64URLEncode(compressed))]
        guard let url = components.url else { throw ConfigurationTransferError.invalidPayload("Could not build link") }
        return url
    }

    /// Parses a deep link. Accepts the `tracker` scheme as well as Overland's `overland` scheme for setup links.
    public static func parse(url: URL) throws -> ConfigurationImport {
        guard let scheme = url.scheme?.lowercased(), scheme == Self.scheme || scheme == "overland" else {
            throw ConfigurationTransferError.unsupportedLink
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        switch url.host()?.lowercased() {
        case "setup":
            let uniqueID = value("unique_id").map { ["yes", "true", "1"].contains($0.lowercased()) }
            return .setup(SetupParameters(endpoint: value("url"), token: value("token"), deviceID: value("device_id"), includeUniqueID: uniqueID))
        case "import":
            guard let payload = value("config"), !payload.isEmpty else { throw ConfigurationTransferError.missingPayload }
            guard let compressed = base64URLDecode(payload) else { throw ConfigurationTransferError.invalidPayload("Not valid base64url") }
            let json: Data
            do {
                json = try (compressed as NSData).decompressed(using: .zlib) as Data
            } catch {
                throw ConfigurationTransferError.invalidPayload("Not valid zlib data")
            }
            return .configuration(try importJSON(json))
        default:
            throw ConfigurationTransferError.unsupportedLink
        }
    }

    /// Parses pasted text: a deep link or a JSON configuration document.
    public static func parse(text: String) throws -> ConfigurationImport {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            return .configuration(try importJSON(Data(trimmed.utf8)))
        }
        guard let url = URL(string: trimmed) else { throw ConfigurationTransferError.unsupportedLink }
        return try parse(url: url)
    }

    // MARK: Helpers

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            "Missing “\(key.stringValue)” at \(path(context))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            "Unexpected value at \(path(context)): \(context.debugDescription)"
        case .dataCorrupted(let context):
            context.debugDescription
        @unknown default:
            error.localizedDescription
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        let path = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        return path.isEmpty ? "the top level" : path
    }
}
