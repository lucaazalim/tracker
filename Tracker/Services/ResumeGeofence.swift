import CoreLocation
import OSLog

/// Registers an exit geofence when iOS pauses location updates, so tracking can resume when the user leaves.
///
/// Uses `CLMonitor`, which replaced region monitoring on `CLLocationManager`. The monitor must be
/// re-created on every launch so events that relaunched the app in the background are delivered.
final class ResumeGeofence {
    private static let monitorName = "TrackerResume"
    private static let identifier = "resume-from-pause"
    private static let logger = Logger(subsystem: Logger.subsystem, category: "ResumeGeofence")

    /// Only one `CLMonitor` per name may exist, so every caller shares this one.
    private lazy var monitor = Task { await CLMonitor(Self.monitorName) }
    private var listener: Task<Void, Never>?

    /// Called when the device leaves the geofence.
    var onExit: (() -> Void)?

    func start() {
        guard listener == nil else { return }
        let monitorTask = monitor
        listener = Task { [weak self] in
            let monitor = await monitorTask.value
            do {
                for try await event in await monitor.events where event.identifier == Self.identifier {
                    guard event.state == .unsatisfied else { continue }
                    await monitor.remove(Self.identifier)
                    self?.onExit?()
                }
            } catch {
                Self.logger.error("Geofence monitoring ended: \(error)")
            }
        }
    }

    func arm(at coordinate: CLLocationCoordinate2D, radius: CLLocationDistance) {
        Task {
            let monitor = await monitor.value
            let condition = CLMonitor.CircularGeographicCondition(center: coordinate, radius: radius)
            // Assume we're inside: we only care about the transition out.
            await monitor.add(condition, identifier: Self.identifier, assuming: .satisfied)
        }
    }

    func disarm() {
        Task {
            await monitor.value.remove(Self.identifier)
        }
    }
}
