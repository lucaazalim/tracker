import CoreLocation
import TrackerKit

extension LocationSample {
    nonisolated init(_ location: CLLocation) {
        self.init(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            timestamp: location.timestamp,
            altitude: location.altitude,
            speed: location.speed,
            course: location.course,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            speedAccuracy: location.speedAccuracy,
            courseAccuracy: location.courseAccuracy,
            floor: location.floor?.level
        )
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension VisitSample {
    nonisolated init(_ visit: CLVisit) {
        self.init(
            latitude: visit.coordinate.latitude,
            longitude: visit.coordinate.longitude,
            horizontalAccuracy: visit.horizontalAccuracy,
            arrival: visit.arrivalDate == .distantPast ? nil : visit.arrivalDate,
            departure: visit.departureDate == .distantFuture ? nil : visit.departureDate
        )
    }
}

extension DesiredAccuracy {
    var clAccuracy: CLLocationAccuracy {
        switch self {
        case .bestForNavigation: kCLLocationAccuracyBestForNavigation
        case .best: kCLLocationAccuracyBest
        case .tenMeters: kCLLocationAccuracyNearestTenMeters
        case .hundredMeters: kCLLocationAccuracyHundredMeters
        case .kilometer: kCLLocationAccuracyKilometer
        case .threeKilometers: kCLLocationAccuracyThreeKilometers
        case .reduced: kCLLocationAccuracyReduced
        }
    }
}

extension ActivityType {
    var clActivityType: CLActivityType {
        switch self {
        case .other: .other
        case .automotiveNavigation: .automotiveNavigation
        case .fitness: .fitness
        case .otherNavigation: .otherNavigation
        case .airborne: .airborne
        }
    }
}

extension CLAuthorizationStatus {
    var title: String {
        switch self {
        case .notDetermined: "Not requested"
        case .restricted: "Restricted"
        case .denied: "Denied"
        case .authorizedAlways: "Always"
        case .authorizedWhenInUse: "While using the app"
        @unknown default: "Unknown"
        }
    }
}
