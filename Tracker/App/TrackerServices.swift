import Foundation
import Observation
import TrackerKit

/// Composition root. Created once at launch, including background launches caused by location events.
final class TrackerServices {
    static let shared = TrackerServices()

    let configuration: ConfigurationStore
    let engine: TrackerEngine
    let router = AppRouter()

    private init() {
        let directory = URL.applicationSupportDirectory.appending(path: "Tracker", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Background launches can happen while the device is locked (after first unlock).
        try? (directory as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication,
            forKey: .fileProtectionKey
        )

        configuration = ConfigurationStore(fileURL: directory.appending(path: "configuration.json"))

        let store: QueueStore
        do {
            store = try QueueStore(url: directory.appending(path: "queue.sqlite"))
        } catch {
            // Never lose the ability to run: fall back to an in-memory queue and surface the problem.
            store = try! QueueStore()
            router.startupError = "The queue database could not be opened (\(error.localizedDescription)). Records are kept in memory until the app restarts."
        }
        engine = TrackerEngine(configuration: configuration, store: store)
    }
}

enum AppTab: Hashable {
    case status
    case profiles
    case server
    case settings
}

/// A configuration change waiting for the user's confirmation.
struct PendingImport: Identifiable {
    let id = UUID()
    let value: ConfigurationImport
}

/// UI navigation state shared across the app.
@Observable
final class AppRouter {
    var selectedTab: AppTab = .status
    var pendingImport: PendingImport?
    var importError: String?
    var startupError: String?

    func handle(url: URL) {
        do {
            pendingImport = PendingImport(value: try ConfigurationTransfer.parse(url: url))
        } catch {
            importError = error.localizedDescription
        }
    }
}
