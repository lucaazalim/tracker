import Foundation

/// The complete, exportable app configuration.
///
/// Runtime state (whether tracking is on, last upload time, …) is deliberately not part of it,
/// so a configuration can be shared between devices.
public struct TrackerConfiguration: Codable, Sendable, Hashable {
    public static let currentVersion = 1

    public var version: Int = TrackerConfiguration.currentVersion
    public var server = ServerSettings()
    public var profiles: [Profile]
    public var activeProfileID: UUID
    public var wifiZones: [WifiZone] = []
    public var notifications = NotificationSettings()
    public var retention = QueueRetention()

    public init(profiles: [Profile], activeProfileID: UUID? = nil) {
        precondition(!profiles.isEmpty, "A configuration needs at least one profile")
        self.profiles = profiles
        self.activeProfileID = activeProfileID ?? profiles[0].id
    }

    /// A fresh install: three built-in profiles with "Balanced" active.
    public static func makeDefault() -> TrackerConfiguration {
        TrackerConfiguration(profiles: [.balanced(), .highResolution(), .batterySaver()])
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.value(.version, default: TrackerConfiguration.currentVersion)
        server = try c.value(.server, default: ServerSettings())
        let decodedProfiles = try c.value(.profiles, default: [Profile]())
        let profiles = decodedProfiles.isEmpty ? [Profile.balanced()] : decodedProfiles
        self.profiles = profiles
        let activeID = try c.decodeIfPresent(UUID.self, forKey: .activeProfileID)
        activeProfileID = activeID.flatMap { id in profiles.contains { $0.id == id } ? id : nil } ?? profiles[0].id
        wifiZones = try c.value(.wifiZones, default: [])
        notifications = try c.value(.notifications, default: NotificationSettings())
        retention = try c.value(.retention, default: QueueRetention())
    }
}

extension TrackerConfiguration {
    public var activeProfile: Profile {
        get { profiles.first { $0.id == activeProfileID } ?? profiles[0] }
        set {
            if let index = profiles.firstIndex(where: { $0.id == newValue.id }) {
                profiles[index] = newValue
            }
        }
    }

    public func profile(named nameOrID: String) -> Profile? {
        if let id = UUID(uuidString: nameOrID), let match = profiles.first(where: { $0.id == id }) {
            return match
        }
        return profiles.first { $0.name.compare(nameOrID, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    /// A copy with credentials removed, suitable for sharing publicly.
    public func redacted() -> TrackerConfiguration {
        var copy = self
        copy.server.accessToken = ""
        copy.server.password = ""
        copy.server.headers = copy.server.headers.map { header in
            var header = header
            header.value = ""
            return header
        }
        return copy
    }
}

// MARK: - Server

public struct ServerSettings: Codable, Sendable, Hashable {
    /// Receiver URL. May contain template placeholders such as `%LAT`. Empty means "not configured".
    public var endpoint = ""
    public var format: PayloadFormat = .geojson
    public var authentication: AuthenticationMethod = .bearer
    public var accessToken = ""
    public var username = ""
    public var password = ""
    public var headers: [HTTPHeader] = []
    /// Free-form identifier included as `device_id` (and used as the OwnTracks topic suffix).
    public var deviceID = ""
    /// Include the vendor identifier (`identifierForVendor`) as `unique_id`.
    public var includeUniqueID = false
    public var acknowledgement: AcknowledgementMode = .resultOK
    /// Attach the newest location as `current` when the backlog spans more than one batch.
    public var includeCurrentLocation = true
    /// Let the server change settings through a `set` object in its response.
    public var allowRemoteConfiguration = true
    public var timeout: Double = 30

    public init() {}

    public var endpointURLIsValid: Bool {
        guard let url = URL(string: Self.sanitizedForValidation(endpoint)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil
        else { return false }
        return true
    }

    public var isConfigured: Bool { endpointURLIsValid }

    /// Template placeholders contain `%`, which `URL(string:)` rejects. Substitute them before validating.
    private static func sanitizedForValidation(_ string: String) -> String {
        URLTemplate.placeholders.reduce(string.trimmingCharacters(in: .whitespaces)) { $0.replacingOccurrences(of: $1, with: "0") }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ServerSettings()
        endpoint = try c.value(.endpoint, default: d.endpoint)
        format = try c.value(.format, default: d.format)
        authentication = try c.value(.authentication, default: d.authentication)
        accessToken = try c.value(.accessToken, default: d.accessToken)
        username = try c.value(.username, default: d.username)
        password = try c.value(.password, default: d.password)
        headers = try c.value(.headers, default: d.headers)
        deviceID = try c.value(.deviceID, default: d.deviceID)
        includeUniqueID = try c.value(.includeUniqueID, default: d.includeUniqueID)
        acknowledgement = try c.value(.acknowledgement, default: d.acknowledgement)
        includeCurrentLocation = try c.value(.includeCurrentLocation, default: d.includeCurrentLocation)
        allowRemoteConfiguration = try c.value(.allowRemoteConfiguration, default: d.allowRemoteConfiguration)
        timeout = try c.value(.timeout, default: d.timeout)
    }
}

public struct HTTPHeader: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var value: String

    public init(id: UUID = UUID(), name: String = "", value: String = "") {
        self.id = id
        self.name = name
        self.value = value
    }
}

// MARK: - Wi-Fi zones

public struct WifiZone: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var ssid: String
    public var latitude: Double
    public var longitude: Double
    public var action: WifiZoneAction

    public init(id: UUID = UUID(), ssid: String, latitude: Double, longitude: Double, action: WifiZoneAction = .overrideLocation) {
        self.id = id
        self.ssid = ssid
        self.latitude = latitude
        self.longitude = longitude
        self.action = action
    }
}

// MARK: - Notifications

public struct NotificationSettings: Codable, Sendable, Hashable {
    public var trackingPaused = false
    public var trackingResumed = false
    public var uploadFailed = false
    public var remoteConfigurationApplied = false
    /// Warn when no location has been received for `watchdogMinutes` while tracking is on.
    public var watchdog = true
    public var watchdogMinutes = 10

    public init() {}

    public var anyEnabled: Bool {
        trackingPaused || trackingResumed || uploadFailed || remoteConfigurationApplied || watchdog
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NotificationSettings()
        trackingPaused = try c.value(.trackingPaused, default: d.trackingPaused)
        trackingResumed = try c.value(.trackingResumed, default: d.trackingResumed)
        uploadFailed = try c.value(.uploadFailed, default: d.uploadFailed)
        remoteConfigurationApplied = try c.value(.remoteConfigurationApplied, default: d.remoteConfigurationApplied)
        watchdog = try c.value(.watchdog, default: d.watchdog)
        watchdogMinutes = try c.value(.watchdogMinutes, default: d.watchdogMinutes)
    }
}

// MARK: - Retention

/// Bounds on the local queue so an unreachable server can't grow it forever. Oldest records go first.
public struct QueueRetention: Codable, Sendable, Hashable {
    /// Maximum number of queued records. `nil` means unlimited.
    public var maxRecords: Int? = 100_000
    /// Maximum age of queued records in days. `nil` means unlimited.
    public var maxAgeDays: Int? = nil

    private enum CodingKeys: String, CodingKey {
        case maxRecords, maxAgeDays
    }

    public init() {}

    public init(maxRecords: Int?, maxAgeDays: Int?) {
        self.maxRecords = maxRecords
        self.maxAgeDays = maxAgeDays
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxRecords = c.contains(.maxRecords) ? try c.decodeIfPresent(Int.self, forKey: .maxRecords) : QueueRetention().maxRecords
        maxAgeDays = try c.decodeIfPresent(Int.self, forKey: .maxAgeDays)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Encode `nil` explicitly: a missing key decodes to the default, not to "unlimited".
        try c.encode(maxRecords, forKey: .maxRecords)
        try c.encode(maxAgeDays, forKey: .maxAgeDays)
    }
}

// MARK: - Decoding helper

extension KeyedDecodingContainer {
    /// Decodes a value, falling back to a default when the key is missing or `null`.
    /// Keeps imported and persisted configurations forward/backward compatible.
    func value<T: Decodable>(_ key: Key, default defaultValue: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? defaultValue()
    }
}
