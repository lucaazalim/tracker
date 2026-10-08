import Foundation

/// Replaces placeholders in the endpoint URL with values from the most recent location.
///
/// | Placeholder | Value |
/// |---|---|
/// | `%TS`  | ISO 8601 timestamp |
/// | `%LAT` | Latitude |
/// | `%LON` | Longitude |
/// | `%SPD` | Speed in m/s (negative means invalid) |
/// | `%ACC` | Horizontal accuracy in meters |
/// | `%ALT` | Altitude in meters |
/// | `%BAT` | Battery level, 0–1 |
/// | `%DID` | Device ID |
public enum URLTemplate {
    public static let placeholders = ["%TS", "%LAT", "%LON", "%SPD", "%ACC", "%ALT", "%BAT", "%DID"]

    public static func containsPlaceholders(_ template: String) -> Bool {
        placeholders.contains { template.contains($0) }
    }

    public static func expand(_ template: String, location: LocationSample?, batteryLevel: Double?, deviceID: String) -> String {
        guard containsPlaceholders(template) else { return template }
        let values: [String: String] = [
            "%TS": location.map { PayloadBuilder.timestamp($0.timestamp) } ?? "",
            "%LAT": location.map { format(PayloadBuilder.round($0.latitude, places: 7)) } ?? "",
            "%LON": location.map { format(PayloadBuilder.round($0.longitude, places: 7)) } ?? "",
            "%SPD": location.map { String(PayloadBuilder.rounded($0.speed)) } ?? "",
            "%ACC": location.map { String(PayloadBuilder.rounded($0.horizontalAccuracy)) } ?? "",
            "%ALT": location.map { String(PayloadBuilder.rounded($0.altitude)) } ?? "",
            "%BAT": batteryLevel.map { format(PayloadBuilder.round($0, places: 2)) } ?? "",
            "%DID": deviceID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "",
        ]
        return placeholders.reduce(template) { result, placeholder in
            result.replacingOccurrences(of: placeholder, with: values[placeholder] ?? "")
        }
    }

    private static func format(_ value: Double) -> String {
        // `description` gives the shortest round-trippable representation without exponent for typical values.
        value == value.rounded() ? String(Int(value)) : value.description
    }
}
