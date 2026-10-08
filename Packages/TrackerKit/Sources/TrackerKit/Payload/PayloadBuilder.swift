import Foundation

/// Lifecycle events recorded when `PayloadFields.lifecycleEvents` is enabled.
public enum LifecycleEvent: String, Sendable, CaseIterable {
    case trackingStarted = "tracking_started"
    case trackingStopped = "tracking_stopped"
    case profileChanged = "profile_changed"
    case pausedLocationUpdates = "paused_location_updates"
    case resumedLocationUpdates = "resumed_location_updates"
    case exitedPauseRegion = "exited_pause_region"
    case willTerminate = "will_terminate"
    case remoteConfigurationApplied = "remote_configuration_applied"
}

/// Builds the JSON records that are queued and uploaded.
///
/// GeoJSON records use the `{"locations": [Feature, …]}` batch format understood by
/// self-hosted receivers such as Dawarich, Compass and Wayfinder.
public enum PayloadBuilder {
    // MARK: Locations

    public static func location(
        _ sample: LocationSample,
        device: DeviceSnapshot,
        context: CaptureContext,
        fields: PayloadFields,
        format: PayloadFormat
    ) -> JSONValue {
        switch format {
        case .geojson: geoJSONLocation(sample, device: device, context: context, fields: fields)
        case .owntracks: ownTracksLocation(sample, device: device, fields: fields)
        }
    }

    static func geoJSONLocation(
        _ sample: LocationSample,
        device: DeviceSnapshot,
        context: CaptureContext,
        fields: PayloadFields
    ) -> JSONValue {
        var properties: [String: JSONValue] = ["timestamp": .string(timestamp(sample.timestamp))]

        if fields.altitude { properties["altitude"] = .int(rounded(sample.altitude)) }
        if fields.speed { properties["speed"] = .double(round(sample.speed, places: 2)) }
        if fields.course { properties["course"] = .int(rounded(sample.course)) }
        if fields.horizontalAccuracy { properties["horizontal_accuracy"] = .int(rounded(sample.horizontalAccuracy)) }
        if fields.verticalAccuracy { properties["vertical_accuracy"] = .int(rounded(sample.verticalAccuracy)) }
        if fields.speedAccuracy { properties["speed_accuracy"] = .double(round(sample.speedAccuracy, places: 2)) }
        if fields.courseAccuracy { properties["course_accuracy"] = .double(round(sample.courseAccuracy, places: 2)) }
        if fields.floor, let floor = sample.floor { properties["floor"] = .int(floor) }
        if fields.motion { properties["motion"] = .array(device.motion.map(JSONValue.string)) }

        if fields.trackingStats {
            properties["pauses"] = .bool(context.pausesAutomatically)
            properties["activity"] = .string(context.activityType.payloadName)
            properties["desired_accuracy"] = .double(context.desiredAccuracy.meters)
            properties["tracking_mode"] = .string(context.trackingMode.rawValue)
            properties["locations_in_payload"] = .int(context.locationsInPayload)
        }
        if fields.profileName { properties["profile"] = .string(context.profileName) }

        addDeviceProperties(device, fields: fields, to: &properties)
        return feature(latitude: sample.latitude, longitude: sample.longitude, properties: properties)
    }

    /// See https://owntracks.org/booklet/tech/json/#_typelocation
    static func ownTracksLocation(_ sample: LocationSample, device: DeviceSnapshot, fields: PayloadFields) -> JSONValue {
        var object: [String: JSONValue] = [
            "_type": "location",
            "lat": .double(round(sample.latitude, places: 7)),
            "lon": .double(round(sample.longitude, places: 7)),
            "tst": .int(Int(sample.timestamp.timeIntervalSince1970)),
            "t": "p",
        ]
        if fields.horizontalAccuracy { object["acc"] = .int(rounded(sample.horizontalAccuracy)) }
        if fields.altitude { object["alt"] = .int(rounded(sample.altitude)) }
        if fields.verticalAccuracy { object["vac"] = .int(rounded(sample.verticalAccuracy)) }
        if fields.speed, sample.speed >= 0 { object["vel"] = .int(rounded(sample.speed * 3.6)) }
        if fields.course, sample.course >= 0 { object["cog"] = .int(rounded(sample.course)) }
        if fields.batteryLevel, let level = device.batteryLevel { object["batt"] = .int(rounded(level * 100)) }
        if fields.batteryState { object["bs"] = .int(device.batteryState.owntracksCode) }
        if fields.wifi, let ssid = device.wifiSSID, !ssid.isEmpty {
            object["SSID"] = .string(ssid)
            object["conn"] = "w"
        }
        if !device.deviceID.isEmpty {
            object["topic"] = .string("owntracks/\(device.deviceID)")
            object["tid"] = .string(String(device.deviceID.suffix(2)))
        }
        return .object(object)
    }

    // MARK: Events (GeoJSON only)

    public static func visit(_ visit: VisitSample, recordedAt date: Date, device: DeviceSnapshot, fields: PayloadFields) -> JSONValue {
        var properties: [String: JSONValue] = [
            "timestamp": .string(timestamp(date)),
            "action": "visit",
            "arrival_date": visit.arrival.map { .string(timestamp($0)) } ?? .null,
            "departure_date": visit.departure.map { .string(timestamp($0)) } ?? .null,
            "horizontal_accuracy": .int(rounded(visit.horizontalAccuracy)),
        ]
        addDeviceProperties(device, fields: fields, to: &properties)
        return feature(latitude: visit.latitude, longitude: visit.longitude, properties: properties)
    }

    public static func event(
        _ event: LifecycleEvent,
        at date: Date,
        location: LocationSample?,
        device: DeviceSnapshot,
        fields: PayloadFields,
        extra: [String: JSONValue] = [:]
    ) -> JSONValue {
        var properties = extra
        properties["timestamp"] = .string(timestamp(date))
        properties["action"] = .string(event.rawValue)
        addDeviceProperties(device, fields: fields, to: &properties)

        var feature: [String: JSONValue] = ["type": "Feature", "properties": .object(properties)]
        if let location {
            feature["geometry"] = point(latitude: location.latitude, longitude: location.longitude)
        }
        return .object(feature)
    }

    // MARK: Batches

    /// Assembles a request body from already-serialized records, avoiding a decode/re-encode round trip.
    public static func batchBody(records: [Data], current: Data?, format: PayloadFormat) -> Data {
        switch format {
        case .owntracks:
            // OwnTracks receivers expect a single object per request.
            return records.first ?? Data("{}".utf8)
        case .geojson:
            var body = Data(#"{"locations":["#.utf8)
            for (index, record) in records.enumerated() {
                if index > 0 { body.append(UInt8(ascii: ",")) }
                body.append(record)
            }
            body.append(UInt8(ascii: "]"))
            if let current {
                body.append(contentsOf: Data(#","current":"#.utf8))
                body.append(current)
            }
            body.append(UInt8(ascii: "}"))
            return body
        }
    }

    // MARK: Helpers

    /// ISO 8601 in UTC with second precision, e.g. `2026-10-08T12:34:56Z`.
    public static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    private static func addDeviceProperties(_ device: DeviceSnapshot, fields: PayloadFields, to properties: inout [String: JSONValue]) {
        if !device.deviceID.isEmpty { properties["device_id"] = .string(device.deviceID) }
        if let uniqueID = device.uniqueID { properties["unique_id"] = .string(uniqueID) }
        if fields.wifi { properties["wifi"] = .string(device.wifiSSID ?? "") }
        if fields.batteryState { properties["battery_state"] = .string(device.batteryState.rawValue) }
        if fields.batteryLevel { properties["battery_level"] = device.batteryLevel.map { .double(round($0, places: 2)) } ?? .null }
    }

    private static func feature(latitude: Double, longitude: Double, properties: [String: JSONValue]) -> JSONValue {
        [
            "type": "Feature",
            "geometry": point(latitude: latitude, longitude: longitude),
            "properties": .object(properties),
        ]
    }

    private static func point(latitude: Double, longitude: Double) -> JSONValue {
        [
            "type": "Point",
            "coordinates": [.double(round(longitude, places: 7)), .double(round(latitude, places: 7))],
        ]
    }

    static func round(_ value: Double, places: Int) -> Double {
        guard value.isFinite else { return -1 }
        let factor = pow(10, Double(places))
        return (value * factor).rounded() / factor
    }

    static func rounded(_ value: Double) -> Int {
        guard value.isFinite else { return -1 }
        return Int(value.rounded())
    }
}
