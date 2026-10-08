import Foundation
import Testing
@testable import TrackerKit

@Suite("Configuration")
struct ConfigurationTests {
    @Test func defaultConfigurationHasBuiltInProfiles() {
        let config = TrackerConfiguration.makeDefault()
        #expect(config.profiles.map(\.name) == ["Balanced", "High resolution", "Battery saver"])
        #expect(config.activeProfile.name == "Balanced")
        #expect(config.activeProfile.upload.sendInterval == 300)
    }

    @Test func roundTripsThroughJSON() throws {
        var config = TrackerConfiguration.makeDefault()
        config.server.endpoint = "https://example.com/api"
        config.server.headers = [HTTPHeader(name: "X-Key", value: "secret")]
        config.profiles[0].upload.sendInterval = nil
        config.retention.maxRecords = nil
        config.wifiZones = [WifiZone(ssid: "Home", latitude: 1, longitude: 2)]

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(TrackerConfiguration.self, from: data)
        #expect(decoded == config)
        // `nil` means "off"/"unlimited" and must survive the round trip.
        #expect(decoded.profiles[0].upload.sendInterval == nil)
        #expect(decoded.retention.maxRecords == nil)
    }

    @Test func missingKeysFallBackToDefaults() throws {
        let id = UUID()
        let json = """
            {"profiles": [{"id": "\(id.uuidString)", "name": "Minimal"}], "server": {"endpoint": "https://x.test"}}
            """
        let config = try JSONDecoder().decode(TrackerConfiguration.self, from: Data(json.utf8))
        #expect(config.activeProfileID == id)
        #expect(config.activeProfile.capture == CaptureSettings())
        #expect(config.activeProfile.upload.sendInterval == 300)
        #expect(config.server.acknowledgement == .resultOK)
        #expect(config.retention.maxRecords == 100_000)
    }

    @Test func unknownActiveProfileFallsBackToFirst() throws {
        let json = #"{"activeProfileID": "00000000-0000-0000-0000-000000000000", "profiles": []}"#
        let config = try JSONDecoder().decode(TrackerConfiguration.self, from: Data(json.utf8))
        #expect(config.profiles.count == 1)
        #expect(config.activeProfileID == config.profiles[0].id)
    }

    @Test func profileLookupByNameIsCaseInsensitive() {
        let config = TrackerConfiguration.makeDefault()
        #expect(config.profile(named: "battery SAVER")?.name == "Battery saver")
        #expect(config.profile(named: config.profiles[1].id.uuidString)?.name == "High resolution")
        #expect(config.profile(named: "nope") == nil)
    }

    @Test func redactionRemovesSecrets() {
        var config = TrackerConfiguration.makeDefault()
        config.server.accessToken = "token"
        config.server.password = "password"
        config.server.headers = [HTTPHeader(name: "X-Key", value: "secret")]
        let redacted = config.redacted()
        #expect(redacted.server.accessToken.isEmpty)
        #expect(redacted.server.password.isEmpty)
        #expect(redacted.server.headers.first?.name == "X-Key")
        #expect(redacted.server.headers.first?.value == "")
    }

    @Test(arguments: [
        ("https://example.com/api", true),
        ("http://192.168.1.10:8080/overland", true),
        ("https://example.com/in?lat=%LAT&lon=%LON", true),
        ("ftp://example.com", false),
        ("not a url", false),
        ("", false),
    ])
    func endpointValidation(endpoint: String, valid: Bool) {
        var server = ServerSettings()
        server.endpoint = endpoint
        #expect(server.endpointURLIsValid == valid)
    }
}

@Suite("Remote configuration")
struct RemoteConfigurationTests {
    @Test func appliesOverlandMainKeysToActiveProfile() throws {
        let set: JSONValue = [
            "send_interval": "1m",
            "main": [
                "tracking_mode": "both",
                "visit_tracking": true,
                "desired_accuracy": "best",
                "activity_type": "fitness",
                "background_indicator": true,
                "pause_automatically": false,
                "logging_mode": "latest",
                "batch_size": 50,
                "min_distance": "10m",
                "min_time": "30s",
                "resume_with_geofence": "1km",
            ],
        ]
        let result = RemoteConfiguration.apply(set, to: .makeDefault())
        let profile = result.configuration.activeProfile
        #expect(profile.upload.sendInterval == 60)
        #expect(profile.capture.trackingMode == .both)
        #expect(profile.capture.visits)
        #expect(profile.capture.desiredAccuracy == .best)
        #expect(profile.capture.activityType == .fitness)
        #expect(profile.capture.showsBackgroundIndicator)
        #expect(profile.upload.queueStrategy == .latest)
        #expect(profile.upload.batchSize == 50)
        #expect(profile.capture.minDistance == 10)
        #expect(profile.capture.minInterval == 30)
        #expect(profile.capture.resumeGeofenceRadius == 1000)
        // A resume geofence only makes sense with automatic pausing.
        #expect(profile.capture.pausesAutomatically)
        #expect(result.changes.count == 12)
    }

    @Test func switchesProfileBeforeApplyingSettings() {
        let set: JSONValue = ["profile": "Battery saver", "send_interval": "off"]
        let result = RemoteConfiguration.apply(set, to: .makeDefault())
        #expect(result.profileChanged)
        #expect(result.configuration.activeProfile.name == "Battery saver")
        #expect(result.configuration.activeProfile.upload.sendInterval == nil)
        // Other profiles are untouched.
        #expect(result.configuration.profiles[0].upload.sendInterval == 300)
    }

    @Test func ignoresUnknownValues() {
        let set: JSONValue = ["main": ["desired_accuracy": "potato", "batch_size": "lots"], "trip": ["prevent_screen_lock": true]]
        let original = TrackerConfiguration.makeDefault()
        let result = RemoteConfiguration.apply(set, to: original)
        #expect(result.configuration == original)
        #expect(result.changes.isEmpty)
    }

    @Test(arguments: [
        (JSONValue.string("500m"), Double?.some(500)),
        (.string("2km"), 2000),
        (.string("off"), nil),
        (.int(25), 25),
        (.int(0), nil),
    ])
    func parsesDistances(value: JSONValue, expected: Double?) throws {
        let parsed = try #require(RemoteConfiguration.parseOptionalDistance(value))
        #expect(parsed == expected)
    }

    @Test(arguments: [
        (JSONValue.string("30s"), Double?.some(30)),
        (.string("5m"), 300),
        (.string("1h"), 3600),
        (.string("off"), nil),
        (.double(1.5), 1.5),
    ])
    func parsesDurations(value: JSONValue, expected: Double?) throws {
        let parsed = try #require(RemoteConfiguration.parseOptionalDuration(value))
        #expect(parsed == expected)
    }

    @Test func rejectsGarbageDurations() {
        #expect(RemoteConfiguration.parseOptionalDuration("soon") == nil)
        #expect(RemoteConfiguration.parseOptionalDistance(true) == nil)
    }
}

@Suite("Configuration transfer")
struct ConfigurationTransferTests {
    @Test func importLinkRoundTrips() throws {
        var config = TrackerConfiguration.makeDefault()
        config.server.endpoint = "https://example.com/api"
        config.server.accessToken = "secret"

        let link = try ConfigurationTransfer.importLink(for: config, includeSecrets: true)
        #expect(link.scheme == "tracker")
        #expect(link.host() == "import")
        guard case .configuration(let imported) = try ConfigurationTransfer.parse(url: link) else {
            Issue.record("Expected a configuration import")
            return
        }
        #expect(imported == config)
    }

    @Test func importLinkWithoutSecretsIsRedacted() throws {
        var config = TrackerConfiguration.makeDefault()
        config.server.accessToken = "secret"
        let link = try ConfigurationTransfer.importLink(for: config, includeSecrets: false)
        guard case .configuration(let imported) = try ConfigurationTransfer.parse(url: link) else {
            Issue.record("Expected a configuration import")
            return
        }
        #expect(imported.server.accessToken.isEmpty)
    }

    @Test func linkIsCompactEnoughForAQRCode() throws {
        let link = try ConfigurationTransfer.importLink(for: .makeDefault(), includeSecrets: true)
        // A version 40 QR code holds ~2,900 bytes at the lowest error correction level.
        #expect(link.absoluteString.utf8.count < 2_000)
    }

    @Test func parsesOverlandStyleSetupLinks() throws {
        let url = try #require(URL(string: "overland://setup?url=https%3A%2F%2Fexample.com%2Fapi&token=1234&device_id=phone&unique_id=yes"))
        guard case .setup(let parameters) = try ConfigurationTransfer.parse(url: url) else {
            Issue.record("Expected setup parameters")
            return
        }
        #expect(parameters == SetupParameters(endpoint: "https://example.com/api", token: "1234", deviceID: "phone", includeUniqueID: true))

        let applied = parameters.apply(to: .makeDefault())
        #expect(applied.server.endpoint == "https://example.com/api")
        #expect(applied.server.accessToken == "1234")
        #expect(applied.server.authentication == .bearer)
        #expect(applied.server.deviceID == "phone")
        #expect(applied.server.includeUniqueID)
    }

    @Test func parsesPastedJSON() throws {
        let data = try ConfigurationTransfer.exportJSON(.makeDefault(), includeSecrets: true)
        guard case .configuration(let config) = try ConfigurationTransfer.parse(text: "  " + String(decoding: data, as: UTF8.self)) else {
            Issue.record("Expected a configuration import")
            return
        }
        #expect(config.profiles.count == 3)
    }

    @Test func rejectsForeignLinks() throws {
        #expect(throws: ConfigurationTransferError.self) {
            try ConfigurationTransfer.parse(url: URL(string: "https://example.com/setup")!)
        }
        #expect(throws: ConfigurationTransferError.self) {
            try ConfigurationTransfer.parse(url: URL(string: "tracker://import?config=%%%")!)
        }
    }

    @Test func base64URLRoundTrips() {
        let data = Data((0..<255).map(UInt8.init))
        let encoded = ConfigurationTransfer.base64URLEncode(data)
        #expect(!encoded.contains("+") && !encoded.contains("/") && !encoded.contains("="))
        #expect(ConfigurationTransfer.base64URLDecode(encoded) == data)
    }
}
