import Foundation

/// A named set of capture, upload and payload settings. Exactly one profile is active at a time.
public struct Profile: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// SF Symbol shown next to the profile.
    public var symbol: String
    public var capture: CaptureSettings
    public var upload: UploadSettings
    public var fields: PayloadFields

    public init(
        id: UUID = UUID(),
        name: String,
        symbol: String = "location",
        capture: CaptureSettings = CaptureSettings(),
        upload: UploadSettings = UploadSettings(),
        fields: PayloadFields = PayloadFields()
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.capture = capture
        self.upload = upload
        self.fields = fields
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        symbol = try c.value(.symbol, default: "location")
        capture = try c.value(.capture, default: CaptureSettings())
        upload = try c.value(.upload, default: UploadSettings())
        fields = try c.value(.fields, default: PayloadFields())
    }
}

/// Settings applied to `CLLocationManager` plus in-app filtering.
public struct CaptureSettings: Codable, Sendable, Hashable {
    public var trackingMode: TrackingMode = .standard
    public var visits: Bool = false
    public var desiredAccuracy: DesiredAccuracy = .hundredMeters
    public var activityType: ActivityType = .other
    /// `CLLocationManager.distanceFilter` in meters. `0` means none. Unlike `minDistance`, this saves battery.
    public var systemDistanceFilter: Double = 0
    public var pausesAutomatically: Bool = false
    /// Radius of the exit geofence registered when iOS pauses updates. `nil` disables it.
    public var resumeGeofenceRadius: Double? = nil
    public var showsBackgroundIndicator: Bool = false
    /// Discard points closer than this many meters to the previous recorded point. `0` disables.
    public var minDistance: Double = 0
    /// Discard points received within this many seconds of the previous recorded point. `0` disables.
    public var minInterval: Double = 0

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CaptureSettings()
        trackingMode = try c.value(.trackingMode, default: d.trackingMode)
        visits = try c.value(.visits, default: d.visits)
        desiredAccuracy = try c.value(.desiredAccuracy, default: d.desiredAccuracy)
        activityType = try c.value(.activityType, default: d.activityType)
        systemDistanceFilter = try c.value(.systemDistanceFilter, default: d.systemDistanceFilter)
        pausesAutomatically = try c.value(.pausesAutomatically, default: d.pausesAutomatically)
        resumeGeofenceRadius = try c.decodeIfPresent(Double.self, forKey: .resumeGeofenceRadius)
        showsBackgroundIndicator = try c.value(.showsBackgroundIndicator, default: d.showsBackgroundIndicator)
        minDistance = try c.value(.minDistance, default: d.minDistance)
        minInterval = try c.value(.minInterval, default: d.minInterval)
    }
}

/// When and how much to upload.
public struct UploadSettings: Codable, Sendable, Hashable {
    /// Seconds between automatic uploads. `nil` disables automatic uploads (manual "Send now" only).
    public var sendInterval: Int? = 300
    /// Maximum number of records per request (GeoJSON format).
    public var batchSize: Int = 200
    public var queueStrategy: QueueStrategy = .all

    private enum CodingKeys: String, CodingKey {
        case sendInterval, batchSize, queueStrategy
    }

    public init() {}

    public init(sendInterval: Int?, batchSize: Int = 200, queueStrategy: QueueStrategy = .all) {
        self.sendInterval = sendInterval
        self.batchSize = batchSize
        self.queueStrategy = queueStrategy
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = UploadSettings()
        // `sendInterval` is optional on purpose (nil = off), so a missing key must not mean "off".
        sendInterval = c.contains(.sendInterval) ? try c.decodeIfPresent(Int.self, forKey: .sendInterval) : d.sendInterval
        batchSize = try c.value(.batchSize, default: d.batchSize)
        queueStrategy = try c.value(.queueStrategy, default: d.queueStrategy)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Encode `nil` explicitly: a missing key decodes to the default interval, not to "off".
        try c.encode(sendInterval, forKey: .sendInterval)
        try c.encode(batchSize, forKey: .batchSize)
        try c.encode(queueStrategy, forKey: .queueStrategy)
    }
}

/// Per-field toggles controlling which properties are included in each record.
///
/// Coordinates and timestamps are always included.
public struct PayloadFields: Codable, Sendable, Hashable {
    public var altitude = true
    public var speed = true
    public var course = true
    public var horizontalAccuracy = true
    public var verticalAccuracy = true
    public var speedAccuracy = true
    public var courseAccuracy = true
    public var floor = false
    public var motion = true
    public var batteryLevel = true
    public var batteryState = true
    public var wifi = true
    /// Adds the name of the active profile as `profile`.
    public var profileName = false
    /// Adds `pauses`, `activity`, `desired_accuracy`, `tracking_mode` and `locations_in_payload`.
    public var trackingStats = false
    /// Records lifecycle events (paused, resumed, launched, ...) as separate records.
    public var lifecycleEvents = false

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PayloadFields()
        altitude = try c.value(.altitude, default: d.altitude)
        speed = try c.value(.speed, default: d.speed)
        course = try c.value(.course, default: d.course)
        horizontalAccuracy = try c.value(.horizontalAccuracy, default: d.horizontalAccuracy)
        verticalAccuracy = try c.value(.verticalAccuracy, default: d.verticalAccuracy)
        speedAccuracy = try c.value(.speedAccuracy, default: d.speedAccuracy)
        courseAccuracy = try c.value(.courseAccuracy, default: d.courseAccuracy)
        floor = try c.value(.floor, default: d.floor)
        motion = try c.value(.motion, default: d.motion)
        batteryLevel = try c.value(.batteryLevel, default: d.batteryLevel)
        batteryState = try c.value(.batteryState, default: d.batteryState)
        wifi = try c.value(.wifi, default: d.wifi)
        profileName = try c.value(.profileName, default: d.profileName)
        trackingStats = try c.value(.trackingStats, default: d.trackingStats)
        lifecycleEvents = try c.value(.lifecycleEvents, default: d.lifecycleEvents)
    }
}

// MARK: - Built-in profiles

extension Profile {
    /// Overland's defaults: continuous updates at 100 m accuracy, uploaded every 5 minutes.
    public static func balanced() -> Profile {
        Profile(name: "Balanced", symbol: "gauge.with.dots.needle.50percent")
    }

    /// Up to one point per second while moving. Uses a lot of battery.
    public static func highResolution() -> Profile {
        var capture = CaptureSettings()
        capture.desiredAccuracy = .best
        capture.showsBackgroundIndicator = true
        return Profile(
            name: "High resolution",
            symbol: "scope",
            capture: capture,
            upload: UploadSettings(sendInterval: 60, batchSize: 500)
        )
    }

    /// Neighbourhood-level tracking with almost no battery impact.
    public static func batterySaver() -> Profile {
        var capture = CaptureSettings()
        capture.trackingMode = .significant
        capture.visits = true
        capture.pausesAutomatically = true
        capture.resumeGeofenceRadius = 500
        return Profile(
            name: "Battery saver",
            symbol: "leaf",
            capture: capture,
            upload: UploadSettings(sendInterval: 1800)
        )
    }
}
