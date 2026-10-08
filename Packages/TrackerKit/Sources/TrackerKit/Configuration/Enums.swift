import Foundation

/// Which Core Location services feed the tracker.
public enum TrackingMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// No continuous updates. Visits (if enabled) are still recorded.
    case off
    /// Continuous standard location updates. Detailed tracks, highest battery use.
    case standard
    /// Significant-change updates only (cell tower / Wi-Fi changes). Very low battery use.
    case significant
    /// Standard and significant-change updates together.
    case both

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: "Off"
        case .standard: "Standard"
        case .significant: "Significant changes"
        case .both: "Standard + significant"
        }
    }

    public var usesStandardUpdates: Bool { self == .standard || self == .both }
    public var usesSignificantChanges: Bool { self == .significant || self == .both }
}

/// Maps to `CLLocationManager.desiredAccuracy`.
public enum DesiredAccuracy: String, Codable, Sendable, CaseIterable, Identifiable {
    case bestForNavigation = "nav"
    case best
    case tenMeters = "10m"
    case hundredMeters = "100m"
    case kilometer = "1km"
    case threeKilometers = "3km"
    case reduced

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bestForNavigation: "Best for navigation"
        case .best: "Best"
        case .tenMeters: "10 m"
        case .hundredMeters: "100 m"
        case .kilometer: "1 km"
        case .threeKilometers: "3 km"
        case .reduced: "Reduced (approximate)"
        }
    }

    /// The nominal accuracy in meters, as reported in `desired_accuracy`. Mirrors Core Location's constants.
    public var meters: Double {
        switch self {
        case .bestForNavigation: -2
        case .best: -1
        case .tenMeters: 10
        case .hundredMeters: 100
        case .kilometer: 1000
        case .threeKilometers: 3000
        case .reduced: 3000
        }
    }
}

/// Maps to `CLLocationManager.activityType`, a hint the OS uses to decide when to pause updates.
public enum ActivityType: String, Codable, Sendable, CaseIterable, Identifiable {
    case other
    case automotiveNavigation = "car"
    case fitness
    case otherNavigation = "nav"
    case airborne = "air"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .other: "Other"
        case .automotiveNavigation: "Automotive"
        case .fitness: "Fitness"
        case .otherNavigation: "Other navigation"
        case .airborne: "Airborne"
        }
    }

    /// Value emitted in the `activity` payload property.
    public var payloadName: String {
        switch self {
        case .other: "other"
        case .automotiveNavigation: "automotive_navigation"
        case .fitness: "fitness"
        case .otherNavigation: "other_navigation"
        case .airborne: "airborne"
        }
    }
}

/// How captured records accumulate before upload.
public enum QueueStrategy: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Keep every record and upload them in batches.
    case all
    /// Keep only the most recent location; older unsent points are replaced.
    case latest

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "All points"
        case .latest: "Latest only"
        }
    }
}

/// Wire format of uploaded records.
public enum PayloadFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Batches of GeoJSON Features: `{"locations": [Feature, …]}`.
    case geojson
    /// One OwnTracks `_type: location` object per request (Home Assistant, OwnTracks Recorder).
    case owntracks

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .geojson: "GeoJSON"
        case .owntracks: "OwnTracks"
        }
    }
}

/// How the server acknowledges that a batch was stored.
public enum AcknowledgementMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// The response body must be JSON containing `"result": "ok"`.
    case resultOK
    /// Any 2xx status code counts as success.
    case anySuccessStatus

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .resultOK: #""result": "ok""#
        case .anySuccessStatus: "Any 2xx"
        }
    }
}

public enum AuthenticationMethod: String, Codable, Sendable, CaseIterable, Identifiable {
    case none
    case bearer
    case basic

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: "None"
        case .bearer: "Bearer token"
        case .basic: "Basic (username/password)"
        }
    }
}

public enum BatteryState: String, Codable, Sendable {
    case unknown
    case unplugged
    case charging
    case full

    /// OwnTracks `bs` code.
    var owntracksCode: Int {
        switch self {
        case .unknown: 0
        case .unplugged: 1
        case .charging: 2
        case .full: 3
        }
    }
}

/// What happens while the phone is connected to a configured Wi-Fi network.
public enum WifiZoneAction: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Record the zone's fixed coordinate instead of the (noisy) reported location.
    case overrideLocation
    /// Don't record locations at all while connected.
    case skipRecording

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overrideLocation: "Use fixed location"
        case .skipRecording: "Don't record"
        }
    }
}
