import Foundation

/// Applies settings pushed by the server in the `set` object of an upload response.
///
/// `send_interval` and the keys in `main` apply to the active profile. `profile` switches the
/// active profile by name or id. Unknown keys and values are ignored.
///
/// ```json
/// {
///   "result": "ok",
///   "set": {
///     "profile": "Battery saver",
///     "send_interval": "5m",
///     "main": { "desired_accuracy": "100m", "min_distance": "50m" }
///   }
/// }
/// ```
public enum RemoteConfiguration {
    public struct Result: Sendable {
        public var configuration: TrackerConfiguration
        /// Human-readable descriptions of what changed.
        public var changes: [String]
        public var profileChanged: Bool
    }

    public static func apply(_ set: JSONValue, to configuration: TrackerConfiguration) -> Result {
        var config = configuration
        var changes: [String] = []
        var profileChanged = false

        // Switch profile first so the remaining keys target the newly active profile.
        if let reference = set["profile"]?.stringValue, let profile = config.profile(named: reference), profile.id != config.activeProfileID {
            config.activeProfileID = profile.id
            changes.append("Active profile → \(profile.name)")
            profileChanged = true
        }

        var profile = config.activeProfile

        if let value = set["send_interval"] {
            if let seconds = parseOptionalDuration(value) {
                profile.upload.sendInterval = seconds.map { Int($0) }
                changes.append("Send interval → \(value.displayString)")
            }
        }

        if let main = set["main"]?.objectValue {
            applyMain(main, to: &profile, changes: &changes)
        }

        config.activeProfile = profile
        return Result(configuration: config, changes: changes, profileChanged: profileChanged)
    }

    private static func applyMain(_ main: [String: JSONValue], to profile: inout Profile, changes: inout [String]) {
        func record(_ key: String, _ value: JSONValue) { changes.append("\(key) → \(value.displayString)") }

        if let value = main["tracking_mode"], let mode = value.stringValue.flatMap(TrackingMode.init(rawValue:)) {
            profile.capture.trackingMode = mode
            record("tracking_mode", value)
        }
        if let value = main["visit_tracking"], let enabled = value.boolValue {
            profile.capture.visits = enabled
            record("visit_tracking", value)
        }
        if let value = main["desired_accuracy"], let accuracy = value.stringValue.flatMap(DesiredAccuracy.init(rawValue:)) {
            profile.capture.desiredAccuracy = accuracy
            record("desired_accuracy", value)
        }
        if let value = main["activity_type"], let type = value.stringValue.flatMap(ActivityType.init(rawValue:)) {
            profile.capture.activityType = type
            record("activity_type", value)
        }
        if let value = main["background_indicator"], let enabled = value.boolValue {
            profile.capture.showsBackgroundIndicator = enabled
            record("background_indicator", value)
        }
        if let value = main["pause_automatically"], let enabled = value.boolValue {
            profile.capture.pausesAutomatically = enabled
            record("pause_automatically", value)
        }
        if let value = main["logging_mode"], let mode = value.stringValue {
            // Only controls queueing; the payload format is a server setting.
            switch mode {
            case "all": profile.upload.queueStrategy = .all
            case "latest", "owntracks": profile.upload.queueStrategy = .latest
            default: break
            }
            record("logging_mode", value)
        }
        if let value = main["batch_size"], let size = value.doubleValue ?? value.stringValue.flatMap(Double.init), size >= 1 {
            profile.upload.batchSize = Int(size)
            record("batch_size", value)
        }
        if let value = main["resume_with_geofence"], let radius = parseOptionalDistance(value) {
            profile.capture.resumeGeofenceRadius = radius
            if radius != nil { profile.capture.pausesAutomatically = true }
            record("resume_with_geofence", value)
        }
        if let value = main["min_distance"], let distance = parseOptionalDistance(value) {
            profile.capture.minDistance = distance ?? 0
            record("min_distance", value)
        }
        if let value = main["min_time"], let seconds = parseOptionalDuration(value) {
            profile.capture.minInterval = seconds ?? 0
            record("min_time", value)
        }
    }

    // MARK: Value parsing

    /// Parses `"off"`, `"500m"`, `"2km"` or a number of meters.
    /// Returns `.some(nil)` for "off", `nil` when the value is not understood.
    static func parseOptionalDistance(_ value: JSONValue) -> Double?? {
        if let number = value.doubleValue { return number <= 0 ? .some(nil) : .some(number) }
        guard let string = value.stringValue?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        if string == "off" { return .some(nil) }
        if string.hasSuffix("km"), let number = Double(string.dropLast(2)) { return .some(number * 1000) }
        if string.hasSuffix("m"), let number = Double(string.dropLast()) { return .some(number) }
        if let number = Double(string) { return .some(number) }
        return nil
    }

    /// Parses `"off"`, `"30s"`, `"5m"`, `"1h"` or a number of seconds.
    /// Returns `.some(nil)` for "off", `nil` when the value is not understood.
    static func parseOptionalDuration(_ value: JSONValue) -> Double?? {
        if let number = value.doubleValue { return number <= 0 ? .some(nil) : .some(number) }
        guard let string = value.stringValue?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        if string == "off" { return .some(nil) }
        let units: [(suffix: String, multiplier: Double)] = [("s", 1), ("m", 60), ("h", 3600)]
        for unit in units where string.hasSuffix(unit.suffix) {
            if let number = Double(string.dropLast(unit.suffix.count)) { return .some(number * unit.multiplier) }
        }
        if let number = Double(string) { return .some(number) }
        return nil
    }
}

extension JSONValue {
    /// Short human-readable rendering for change descriptions.
    var displayString: String {
        switch self {
        case .string(let value): value
        case .null: "null"
        default: encodedString()
        }
    }
}
