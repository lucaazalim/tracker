import Foundation

/// A platform-independent snapshot of a `CLLocation`.
public struct LocationSample: Codable, Sendable, Hashable {
    public var latitude: Double
    public var longitude: Double
    public var timestamp: Date
    /// Meters above sea level.
    public var altitude: Double
    /// Meters per second. Negative when invalid.
    public var speed: Double
    /// Degrees from true north. Negative when invalid.
    public var course: Double
    public var horizontalAccuracy: Double
    public var verticalAccuracy: Double
    public var speedAccuracy: Double
    public var courseAccuracy: Double
    public var floor: Int?

    public init(
        latitude: Double,
        longitude: Double,
        timestamp: Date,
        altitude: Double = 0,
        speed: Double = -1,
        course: Double = -1,
        horizontalAccuracy: Double = 0,
        verticalAccuracy: Double = -1,
        speedAccuracy: Double = -1,
        courseAccuracy: Double = -1,
        floor: Int? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.altitude = altitude
        self.speed = speed
        self.course = course
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.speedAccuracy = speedAccuracy
        self.courseAccuracy = courseAccuracy
        self.floor = floor
    }

    /// Great-circle distance in meters (haversine).
    public func distance(to other: LocationSample) -> Double {
        let earthRadius = 6_371_008.8
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * atan2(sqrt(a), sqrt(1 - a))
    }
}

/// Device state captured alongside a location.
public struct DeviceSnapshot: Sendable, Hashable {
    /// 0...1, or `nil` when unknown.
    public var batteryLevel: Double?
    public var batteryState: BatteryState
    public var wifiSSID: String?
    /// Motion activities from the motion coprocessor, e.g. `["driving", "stationary"]`.
    public var motion: [String]
    public var deviceID: String
    /// `identifierForVendor`, only set when the user opted in.
    public var uniqueID: String?

    public init(
        batteryLevel: Double? = nil,
        batteryState: BatteryState = .unknown,
        wifiSSID: String? = nil,
        motion: [String] = [],
        deviceID: String = "",
        uniqueID: String? = nil
    ) {
        self.batteryLevel = batteryLevel
        self.batteryState = batteryState
        self.wifiSSID = wifiSSID
        self.motion = motion
        self.deviceID = deviceID
        self.uniqueID = uniqueID
    }
}

/// How the location was obtained, reported when "tracking stats" are enabled.
public struct CaptureContext: Sendable, Hashable {
    public var profileName: String
    public var pausesAutomatically: Bool
    public var activityType: ActivityType
    public var desiredAccuracy: DesiredAccuracy
    public var trackingMode: TrackingMode
    public var locationsInPayload: Int

    public init(
        profileName: String,
        pausesAutomatically: Bool,
        activityType: ActivityType,
        desiredAccuracy: DesiredAccuracy,
        trackingMode: TrackingMode,
        locationsInPayload: Int
    ) {
        self.profileName = profileName
        self.pausesAutomatically = pausesAutomatically
        self.activityType = activityType
        self.desiredAccuracy = desiredAccuracy
        self.trackingMode = trackingMode
        self.locationsInPayload = locationsInPayload
    }

    public init(profile: Profile, locationsInPayload: Int) {
        self.init(
            profileName: profile.name,
            pausesAutomatically: profile.capture.pausesAutomatically,
            activityType: profile.capture.activityType,
            desiredAccuracy: profile.capture.desiredAccuracy,
            trackingMode: profile.capture.trackingMode,
            locationsInPayload: locationsInPayload
        )
    }
}

/// A `CLVisit` snapshot.
public struct VisitSample: Sendable, Hashable {
    public var latitude: Double
    public var longitude: Double
    public var horizontalAccuracy: Double
    /// `nil` when unknown (Core Location reports `distantPast`).
    public var arrival: Date?
    /// `nil` while the visit is ongoing (Core Location reports `distantFuture`).
    public var departure: Date?

    public init(latitude: Double, longitude: Double, horizontalAccuracy: Double, arrival: Date?, departure: Date?) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.arrival = arrival
        self.departure = departure
    }
}
