import Foundation
import Testing
@testable import TrackerKit

@Suite("Payloads")
struct PayloadTests {
    let sample = LocationSample(
        latitude: 37.33180012345,
        longitude: -122.03058098765,
        timestamp: Date(timeIntervalSince1970: 1_443_711_600),
        altitude: 12.4,
        speed: 4.256,
        course: 181.6,
        horizontalAccuracy: 30.2,
        verticalAccuracy: 4,
        speedAccuracy: 0.5,
        courseAccuracy: 12.25,
        floor: 3
    )

    let device = DeviceSnapshot(batteryLevel: 0.8, batteryState: .charging, wifiSSID: "Home", motion: ["driving", "stationary"], deviceID: "phone")

    var context: CaptureContext {
        CaptureContext(profile: .balanced(), locationsInPayload: 1)
    }

    @Test func geoJSONMatchesOverlandShape() throws {
        let record = PayloadBuilder.location(sample, device: device, context: context, fields: PayloadFields(), format: .geojson)
        #expect(record["type"] == "Feature")
        #expect(record["geometry"]?["coordinates"] == [-122.030581, 37.3318001])

        let properties = try #require(record["properties"]?.objectValue)
        #expect(properties["timestamp"] == "2015-10-01T15:00:00Z")
        #expect(properties["altitude"] == 12)
        #expect(properties["speed"] == 4.26)
        #expect(properties["course"] == 182)
        #expect(properties["horizontal_accuracy"] == 30)
        #expect(properties["vertical_accuracy"] == 4)
        #expect(properties["speed_accuracy"] == 0.5)
        #expect(properties["course_accuracy"] == 12.25)
        #expect(properties["motion"] == ["driving", "stationary"])
        #expect(properties["battery_level"] == 0.8)
        #expect(properties["battery_state"] == "charging")
        #expect(properties["wifi"] == "Home")
        #expect(properties["device_id"] == "phone")
        // Off by default.
        #expect(properties["floor"] == nil)
        #expect(properties["pauses"] == nil)
        #expect(properties["profile"] == nil)
        #expect(properties["unique_id"] == nil)
    }

    @Test func fieldTogglesControlProperties() throws {
        var fields = PayloadFields()
        fields.altitude = false
        fields.motion = false
        fields.wifi = false
        fields.floor = true
        fields.trackingStats = true
        fields.profileName = true

        let record = PayloadBuilder.location(sample, device: device, context: context, fields: fields, format: .geojson)
        let properties = try #require(record["properties"]?.objectValue)
        #expect(properties["altitude"] == nil)
        #expect(properties["motion"] == nil)
        #expect(properties["wifi"] == nil)
        #expect(properties["floor"] == 3)
        #expect(properties["profile"] == "Balanced")
        #expect(properties["pauses"] == false)
        #expect(properties["activity"] == "other")
        #expect(properties["desired_accuracy"] == 100)
        #expect(properties["tracking_mode"] == "standard")
        #expect(properties["locations_in_payload"] == 1)
    }

    @Test func minimalPayloadKeepsCoordinatesAndTimestamp() throws {
        var fields = PayloadFields()
        for keyPath: WritableKeyPath<PayloadFields, Bool> in [
            \.altitude, \.speed, \.course, \.horizontalAccuracy, \.verticalAccuracy, \.speedAccuracy,
            \.courseAccuracy, \.motion, \.batteryLevel, \.batteryState, \.wifi,
        ] {
            fields[keyPath: keyPath] = false
        }
        let record = PayloadBuilder.location(sample, device: DeviceSnapshot(), context: context, fields: fields, format: .geojson)
        #expect(record["properties"]?.objectValue?.keys.sorted() == ["timestamp"])
        #expect(record["geometry"] != nil)
    }

    @Test func uniqueIDIsIncludedWhenProvided() {
        var device = device
        device.uniqueID = "ABC"
        let record = PayloadBuilder.location(sample, device: device, context: context, fields: PayloadFields(), format: .geojson)
        #expect(record["properties"]?["unique_id"] == "ABC")
    }

    @Test func ownTracksLocation() throws {
        let record = PayloadBuilder.location(sample, device: device, context: context, fields: PayloadFields(), format: .owntracks)
        let object = try #require(record.objectValue)
        #expect(object["_type"] == "location")
        #expect(object["lat"] == 37.3318001)
        #expect(object["lon"] == -122.030581)
        // Unix epoch seconds (Overland mistakenly used the 2001 reference date).
        #expect(object["tst"] == 1_443_711_600)
        #expect(object["acc"] == 30)
        #expect(object["alt"] == 12)
        #expect(object["vel"] == 15)
        #expect(object["cog"] == 182)
        #expect(object["batt"] == 80)
        #expect(object["bs"] == 2)
        #expect(object["SSID"] == "Home")
        #expect(object["conn"] == "w")
        #expect(object["topic"] == "owntracks/phone")
        #expect(object["tid"] == "ne")
    }

    @Test func ownTracksOmitsInvalidSpeedAndCourse() throws {
        var sample = sample
        sample.speed = -1
        sample.course = -1
        let record = PayloadBuilder.location(sample, device: device, context: context, fields: PayloadFields(), format: .owntracks)
        #expect(record["vel"] == nil)
        #expect(record["cog"] == nil)
    }

    @Test func visitRecord() throws {
        let visit = VisitSample(latitude: 1, longitude: 2, horizontalAccuracy: 25, arrival: Date(timeIntervalSince1970: 0), departure: nil)
        let record = PayloadBuilder.visit(visit, recordedAt: Date(timeIntervalSince1970: 60), device: device, fields: PayloadFields())
        let properties = try #require(record["properties"]?.objectValue)
        #expect(properties["action"] == "visit")
        #expect(properties["arrival_date"] == "1970-01-01T00:00:00Z")
        #expect(properties["departure_date"] == .null)
        #expect(properties["horizontal_accuracy"] == 25)
        #expect(record["geometry"]?["coordinates"] == [2, 1])
    }

    @Test func lifecycleEventWithoutLocationHasNoGeometry() {
        let record = PayloadBuilder.event(.trackingStarted, at: .now, location: nil, device: device, fields: PayloadFields())
        #expect(record["geometry"] == nil)
        #expect(record["properties"]?["action"] == "tracking_started")
    }

    @Test func batchBodyIsValidJSON() throws {
        let records = try (0..<3).map { index in
            try JSONValue.object(["n": .int(index)]).encoded()
        }
        let current = try JSONValue.object(["current": true]).encoded()

        let body = try JSONValue.decode(PayloadBuilder.batchBody(records: records, current: current, format: .geojson))
        #expect(body["locations"]?.arrayValue?.count == 3)
        #expect(body["locations"]?.arrayValue?.last?["n"] == 2)
        #expect(body["current"]?["current"] == true)

        let empty = try JSONValue.decode(PayloadBuilder.batchBody(records: [], current: nil, format: .geojson))
        #expect(empty == ["locations": []])

        let owntracks = PayloadBuilder.batchBody(records: records, current: current, format: .owntracks)
        #expect(owntracks == records[0])
    }

    @Test func urlTemplateExpansion() {
        let template = "https://example.com/in?ts=%TS&lat=%LAT&lon=%LON&acc=%ACC&spd=%SPD&alt=%ALT&bat=%BAT&id=%DID"
        let expanded = URLTemplate.expand(template, location: sample, batteryLevel: 0.8, deviceID: "my phone")
        #expect(expanded == "https://example.com/in?ts=2015-10-01T15:00:00Z&lat=37.3318001&lon=-122.030581&acc=30&spd=4&alt=12&bat=0.8&id=my%20phone")
        #expect(URLTemplate.expand("https://plain.example", location: nil, batteryLevel: nil, deviceID: "") == "https://plain.example")
    }

    @Test func distanceIsHaversine() {
        let a = LocationSample(latitude: 0, longitude: 0, timestamp: .now)
        let b = LocationSample(latitude: 0, longitude: 1, timestamp: .now)
        #expect(abs(a.distance(to: b) - 111_195) < 10)
    }

    @Test func jsonValueDecodesNumbersAndBooleansDistinctly() throws {
        let value = try JSONValue.decode(Data(#"{"a":1,"b":1.5,"c":true,"d":null,"e":"x"}"#.utf8))
        #expect(value["a"] == .int(1))
        #expect(value["b"] == .double(1.5))
        #expect(value["c"] == .bool(true))
        #expect(value["d"] == .null)
        #expect(value["e"] == .string("x"))
    }
}
