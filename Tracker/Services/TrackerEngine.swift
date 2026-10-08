import AppIntents
import BackgroundTasks
import CoreLocation
import CoreMotion
import NetworkExtension
import OSLog
import TrackerKit
import UIKit

/// Captures locations, queues records and uploads them according to the active profile.
@Observable
final class TrackerEngine: NSObject {
    // MARK: Observable state

    private(set) var isTrackingEnabled: Bool
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    private(set) var accuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy
    private(set) var motionAuthorization: CMAuthorizationStatus = CMMotionActivityManager.authorizationStatus()
    private(set) var backgroundRefreshStatus: UIBackgroundRefreshStatus = .available
    private(set) var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    private(set) var notificationAuthorization: UNAuthorizationStatus = .notDetermined

    private(set) var lastLocation: LocationSample?
    private(set) var queueCounts = QueueCounts()
    private(set) var lastUploadDate: Date?
    private(set) var lastUploadError: String?
    private(set) var isUploading = false
    /// iOS paused updates (`pausesLocationUpdatesAutomatically`); cleared on the next location.
    private(set) var isPausedBySystem = false
    private(set) var currentSSID: String?

    // MARK: Dependencies

    let configuration: ConfigurationStore
    let store: QueueStore
    let uploader: Uploader
    let notifier = Notifier()

    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private lazy var motionManager = CMMotionActivityManager()
    @ObservationIgnored private let resumeGeofence = ResumeGeofence()
    @ObservationIgnored private var serviceSession: CLServiceSession?

    // MARK: Internal state

    @ObservationIgnored private var lastRecorded: LocationSample?
    @ObservationIgnored private var lastLocationPayload: Data?
    @ObservationIgnored private var lastMotion: [String] = []
    /// Any call into `CMMotionActivityManager` can trigger the permission prompt, so only stop what was started.
    @ObservationIgnored private var isReceivingMotion = false
    @ObservationIgnored private var lastUploadAttempt: Date?
    @ObservationIgnored private var lastSSIDRefresh: Date?
    @ObservationIgnored private var writesSincePrune = 0
    @ObservationIgnored private let writes: AsyncStream<QueueWrite>.Continuation

    nonisolated private static let logger = Logger(subsystem: Logger.subsystem, category: "Engine")
    static let refreshTaskIdentifier = "\(Bundle.main.bundleIdentifier ?? "tracker").upload"

    private enum DefaultsKey {
        static let trackingEnabled = "trackingEnabled"
        static let lastUploadDate = "lastUploadDate"
    }

    private enum QueueWrite {
        case append(Data, RecordKind, Date)
        case replaceLocation(Data, Date)
    }

    // MARK: Lifecycle

    init(configuration: ConfigurationStore, store: QueueStore) {
        self.configuration = configuration
        self.store = store
        self.uploader = Uploader(store: store)
        self.isTrackingEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.trackingEnabled)
        self.lastUploadDate = UserDefaults.standard.object(forKey: DefaultsKey.lastUploadDate) as? Date

        let (stream, continuation) = AsyncStream.makeStream(of: QueueWrite.self)
        self.writes = continuation
        super.init()

        // A single consumer keeps queue writes in capture order.
        Task { [weak self, store] in
            for await write in stream {
                do {
                    switch write {
                    case .append(let data, let kind, let date): try await store.append(data, kind: kind, at: date)
                    case .replaceLocation(let data, let date): try await store.replaceLocations(with: data, at: date)
                    }
                } catch {
                    Self.logger.error("Queue write failed: \(error)")
                }
                await self?.didWrite()
            }
        }

        locationManager.delegate = self
        authorizationStatus = locationManager.authorizationStatus
        accuracyAuthorization = locationManager.accuracyAuthorization

        resumeGeofence.onExit = { [weak self] in self?.handleGeofenceExit() }
        resumeGeofence.start()

        configuration.observe { [weak self] old, new in self?.configurationDidChange(from: old, to: new) }

        applyLocationSettings()
        Task {
            _ = try? await store.prune(configuration.configuration.retention)
            await refreshCounts()
        }
    }

    // MARK: Public API

    func setTrackingEnabled(_ enabled: Bool) {
        guard enabled != isTrackingEnabled else { return }
        if !enabled { recordEvent(.trackingStopped) }
        isTrackingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.trackingEnabled)
        if enabled {
            if authorizationStatus == .notDetermined { requestLocationAuthorization() }
            if configuration.configuration.notifications.anyEnabled {
                // The watchdog is on by default; ask once so it can actually alert.
                Task {
                    await notifier.requestAuthorization()
                    notificationAuthorization = await notifier.authorizationStatus
                }
            }
            recordEvent(.trackingStarted)
        }
        applyLocationSettings()
    }

    func activateProfile(id: UUID) {
        guard id != configuration.configuration.activeProfileID else { return }
        configuration.update { $0.activeProfileID = id }
    }

    /// Requests "When In Use" first, then upgrades to "Always", which background tracking needs.
    func requestLocationAuthorization() {
        switch authorizationStatus {
        case .notDetermined: locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: locationManager.requestAlwaysAuthorization()
        default: openSystemSettings()
        }
    }

    func requestMotionAuthorization() {
        // There is no explicit request API: querying activity triggers the prompt.
        motionManager.queryActivityStarting(from: .now.addingTimeInterval(-60), to: .now, to: .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.motionAuthorization = CMMotionActivityManager.authorizationStatus() }
        }
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Uploads everything now, regardless of the send interval.
    @discardableResult
    func sendNow() async -> FlushReport {
        await flush()
    }

    func deleteQueue() async {
        try? await store.removeAll()
        await refreshCounts()
    }

    func testConnection() async -> RequestLogEntry? {
        await uploader.testConnection(configuration.configuration.server)
    }

    func requestLogs() async -> [RequestLogEntry] {
        (try? await store.recentLogs()) ?? []
    }

    func clearRequestLogs() async {
        try? await store.clearLogs()
    }

    /// Refreshes permission and system state shown in the health checks.
    func refreshSystemStatus() async {
        authorizationStatus = locationManager.authorizationStatus
        accuracyAuthorization = locationManager.accuracyAuthorization
        motionAuthorization = CMMotionActivityManager.authorizationStatus()
        backgroundRefreshStatus = UIApplication.shared.backgroundRefreshStatus
        isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        notificationAuthorization = await notifier.authorizationStatus
        await refreshSSID(force: true)
        await refreshCounts()
    }

    // MARK: App lifecycle

    func sceneDidBecomeActive() {
        Task {
            await refreshSystemStatus()
            await flushIfDue()
        }
    }

    func sceneDidEnterBackground() {
        configuration.save()
        scheduleBackgroundRefresh()
    }

    func applicationWillTerminate() {
        recordEvent(.willTerminate)
        configuration.save()
    }

    /// Runs from a `BGAppRefreshTask`: uploads if due and schedules the next refresh.
    func performBackgroundRefresh() async {
        scheduleBackgroundRefresh()
        await flushIfDue()
    }

    func scheduleBackgroundRefresh() {
        guard isTrackingEnabled, let interval = configuration.activeProfile.upload.sendInterval else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        // iOS decides the actual time; it rarely runs more often than every 15 minutes.
        request.earliestBeginDate = .now.addingTimeInterval(TimeInterval(max(interval, 15 * 60)))
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Self.logger.notice("Could not schedule background refresh: \(error)")
        }
    }

    // MARK: Location settings

    /// Applies the active profile to Core Location and the sensors. Safe to call repeatedly.
    private func applyLocationSettings() {
        let profile = configuration.activeProfile
        let capture = profile.capture

        guard isTrackingEnabled else {
            locationManager.stopUpdatingLocation()
            locationManager.stopMonitoringSignificantLocationChanges()
            locationManager.stopMonitoringVisits()
            stopMotionUpdates()
            UIDevice.current.isBatteryMonitoringEnabled = false
            resumeGeofence.disarm()
            notifier.disarmWatchdog()
            serviceSession?.invalidate()
            serviceSession = nil
            isPausedBySystem = false
            return
        }

        // Declares that the app needs "Always" authorization while tracking; keeps background delivery alive.
        if serviceSession == nil, authorizationStatus != .notDetermined {
            serviceSession = CLServiceSession(authorization: .always)
        }

        locationManager.activityType = capture.activityType.clActivityType
        locationManager.desiredAccuracy = capture.desiredAccuracy.clAccuracy
        locationManager.distanceFilter = capture.systemDistanceFilter > 0 ? capture.systemDistanceFilter : kCLDistanceFilterNone
        locationManager.pausesLocationUpdatesAutomatically = capture.pausesAutomatically
        locationManager.showsBackgroundLocationIndicator = capture.showsBackgroundIndicator
        locationManager.allowsBackgroundLocationUpdates = true

        if capture.trackingMode.usesStandardUpdates {
            locationManager.startUpdatingLocation()
        } else {
            locationManager.stopUpdatingLocation()
        }

        if capture.trackingMode.usesSignificantChanges, CLLocationManager.significantLocationChangeMonitoringAvailable() {
            locationManager.startMonitoringSignificantLocationChanges()
        } else {
            locationManager.stopMonitoringSignificantLocationChanges()
        }

        if capture.visits {
            locationManager.startMonitoringVisits()
        } else {
            locationManager.stopMonitoringVisits()
        }

        if profile.fields.motion, CMMotionActivityManager.isActivityAvailable() {
            startMotionUpdates()
        } else {
            stopMotionUpdates()
        }

        UIDevice.current.isBatteryMonitoringEnabled = profile.fields.batteryLevel || profile.fields.batteryState

        if !capture.pausesAutomatically || capture.resumeGeofenceRadius == nil {
            resumeGeofence.disarm()
        }
        if !capture.trackingMode.usesStandardUpdates || !configuration.configuration.notifications.watchdog {
            notifier.disarmWatchdog()
        }
    }

    private func startMotionUpdates() {
        guard !isReceivingMotion else { return }
        isReceivingMotion = true
        motionManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            let motion = Self.motionNames(activity)
            MainActor.assumeIsolated { self?.lastMotion = motion }
        }
    }

    private func stopMotionUpdates() {
        guard isReceivingMotion else { return }
        isReceivingMotion = false
        motionManager.stopActivityUpdates()
        lastMotion = []
    }

    private func configurationDidChange(from old: TrackerConfiguration, to new: TrackerConfiguration) {
        let oldProfile = old.activeProfile
        let newProfile = new.activeProfile
        if old.activeProfileID != new.activeProfileID {
            recordEvent(.profileChanged, extra: ["profile": .string(newProfile.name)])
            TrackerShortcuts.updateAppShortcutParameters()
        }
        if oldProfile.capture != newProfile.capture || oldProfile.fields != newProfile.fields || old.notifications != new.notifications {
            applyLocationSettings()
        }
        if old.profiles.map(\.name) != new.profiles.map(\.name) {
            TrackerShortcuts.updateAppShortcutParameters()
        }
    }

    // MARK: Recording

    private func handle(_ locations: [LocationSample]) {
        guard isTrackingEnabled, !locations.isEmpty else { return }
        isPausedBySystem = false

        let config = configuration.configuration
        let profile = config.activeProfile
        var samples = profile.upload.queueStrategy == .latest ? [locations[locations.count - 1]] : locations

        refreshSSIDIfStale()
        if let ssid = currentSSID, let zone = config.wifiZones.first(where: { $0.ssid == ssid }) {
            switch zone.action {
            case .skipRecording:
                lastLocation = samples.last
                return
            case .overrideLocation:
                let timestamp = samples.last?.timestamp ?? .now
                samples = [LocationSample(latitude: zone.latitude, longitude: zone.longitude, timestamp: timestamp, horizontalAccuracy: 0)]
            }
        }

        let device = deviceSnapshot(for: profile)
        let context = CaptureContext(profile: profile, locationsInPayload: samples.count)

        for sample in samples {
            lastLocation = sample
            if let previous = lastRecorded {
                if profile.capture.minDistance > 0, sample.distance(to: previous) < profile.capture.minDistance { continue }
                if profile.capture.minInterval > 0, sample.timestamp.timeIntervalSince(previous.timestamp) < profile.capture.minInterval { continue }
            }

            let record = PayloadBuilder.location(sample, device: device, context: context, fields: profile.fields, format: config.server.format)
            guard let data = try? record.encoded() else { continue }
            lastRecorded = sample
            lastLocationPayload = data
            switch profile.upload.queueStrategy {
            case .all: writes.yield(.append(data, .location, sample.timestamp))
            case .latest: writes.yield(.replaceLocation(data, sample.timestamp))
            }
        }

        if profile.capture.trackingMode.usesStandardUpdates, config.notifications.watchdog {
            notifier.armWatchdog(minutes: config.notifications.watchdogMinutes)
        }
    }

    private func handle(_ visit: VisitSample) {
        let config = configuration.configuration
        let profile = config.activeProfile
        guard isTrackingEnabled, profile.capture.visits, config.server.format == .geojson else { return }
        let record = PayloadBuilder.visit(visit, recordedAt: .now, device: deviceSnapshot(for: profile), fields: profile.fields)
        if let data = try? record.encoded() {
            writes.yield(.append(data, .event, .now))
        }
    }

    /// Records a lifecycle event if the active profile asks for them (GeoJSON only).
    private func recordEvent(_ event: LifecycleEvent, extra: [String: JSONValue] = [:]) {
        let config = configuration.configuration
        let profile = config.activeProfile
        guard profile.fields.lifecycleEvents, config.server.format == .geojson else { return }
        let record = PayloadBuilder.event(event, at: .now, location: lastLocation, device: deviceSnapshot(for: profile), fields: profile.fields, extra: extra)
        if let data = try? record.encoded() {
            writes.yield(.append(data, .event, .now))
        }
    }

    private func didWrite() async {
        writesSincePrune += 1
        if writesSincePrune >= 100 {
            writesSincePrune = 0
            _ = try? await store.prune(configuration.configuration.retention)
        }
        await refreshCounts()
        await flushIfDue()
    }

    private func refreshCounts() async {
        if let counts = try? await store.counts() {
            queueCounts = counts
        }
    }

    // MARK: Pause / resume

    private func handlePause() {
        isPausedBySystem = true
        recordEvent(.pausedLocationUpdates)
        notifier.disarmWatchdog()
        let config = configuration.configuration
        if config.notifications.trackingPaused {
            notifier.post(title: "Tracking paused", body: "iOS paused location updates because you stopped moving.")
        }
        if let radius = config.activeProfile.capture.resumeGeofenceRadius, let location = lastLocation {
            resumeGeofence.arm(at: location.coordinate, radius: radius)
        }
        Task { await flush() }
    }

    private func handleResume() {
        isPausedBySystem = false
        recordEvent(.resumedLocationUpdates)
        if configuration.configuration.notifications.trackingResumed {
            notifier.post(title: "Tracking resumed", body: "Location updates resumed.")
        }
    }

    private func handleGeofenceExit() {
        guard isTrackingEnabled else { return }
        recordEvent(.exitedPauseRegion)
        if configuration.configuration.notifications.trackingResumed {
            notifier.post(title: "Tracking resumed", body: "You left the area where tracking paused.")
        }
        // Restarting updates is what un-pauses them.
        locationManager.stopUpdatingLocation()
        applyLocationSettings()
    }

    // MARK: Upload

    private func flushIfDue() async {
        guard let interval = configuration.activeProfile.upload.sendInterval, queueCounts.total > 0 else { return }
        // After a relaunch the in-memory attempt time is gone; fall back to the persisted upload date.
        if let lastAttempt = lastUploadAttempt ?? lastUploadDate, Date.now.timeIntervalSince(lastAttempt) < TimeInterval(interval) { return }
        await flush()
    }

    @discardableResult
    private func flush() async -> FlushReport {
        let config = configuration.configuration
        guard config.server.isConfigured else {
            lastUploadError = UploadError.endpointNotConfigured.localizedDescription
            var report = FlushReport()
            report.failure = lastUploadError
            return report
        }
        guard !isUploading else {
            var report = FlushReport()
            report.skipped = true
            return report
        }

        isUploading = true
        lastUploadAttempt = .now
        let backgroundTask = BackgroundTaskAssertion(name: "Upload")
        defer {
            backgroundTask.end()
            isUploading = false
        }

        let context = UploadContext(
            server: config.server,
            batchSize: config.activeProfile.upload.batchSize,
            currentLocation: lastLocationPayload,
            lastLocation: lastLocation,
            batteryLevel: batteryLevel
        )
        let report = await uploader.flush(context)

        if report.recordsSent > 0 || (report.succeeded && report.requests > 0) {
            lastUploadDate = .now
            UserDefaults.standard.set(lastUploadDate, forKey: DefaultsKey.lastUploadDate)
        }
        if let failure = report.failure {
            lastUploadError = failure
            if config.notifications.uploadFailed { notifier.postUploadFailure(failure) }
        } else if !report.skipped {
            lastUploadError = nil
            notifier.clearUploadFailure()
        }

        for set in report.remoteSettings {
            applyRemoteSettings(set)
        }
        await refreshCounts()
        return report
    }

    private func applyRemoteSettings(_ set: JSONValue) {
        guard configuration.configuration.server.allowRemoteConfiguration else { return }
        let result = RemoteConfiguration.apply(set, to: configuration.configuration)
        guard !result.changes.isEmpty else { return }
        configuration.configuration = result.configuration
        recordEvent(.remoteConfigurationApplied, extra: ["changes": .array(result.changes.map(JSONValue.string))])
        if configuration.configuration.notifications.remoteConfigurationApplied {
            notifier.post(title: "Settings updated by server", body: result.changes.joined(separator: "\n"))
        }
    }

    // MARK: Device state

    private var batteryLevel: Double? {
        let level = UIDevice.current.batteryLevel
        return level < 0 ? nil : Double(level)
    }

    private func deviceSnapshot(for profile: Profile) -> DeviceSnapshot {
        let server = configuration.configuration.server
        let batteryState: BatteryState = switch UIDevice.current.batteryState {
        case .unplugged: .unplugged
        case .charging: .charging
        case .full: .full
        default: .unknown
        }
        return DeviceSnapshot(
            batteryLevel: batteryLevel,
            batteryState: batteryState,
            wifiSSID: currentSSID,
            motion: lastMotion,
            deviceID: server.deviceID,
            uniqueID: server.includeUniqueID ? UIDevice.current.identifierForVendor?.uuidString : nil
        )
    }

    private var needsSSID: Bool {
        let config = configuration.configuration
        return config.activeProfile.fields.wifi || !config.wifiZones.isEmpty
    }

    private func refreshSSIDIfStale() {
        guard needsSSID else { return }
        if let last = lastSSIDRefresh, Date.now.timeIntervalSince(last) < 15 { return }
        Task { await refreshSSID(force: false) }
    }

    /// Requires the "Access Wi-Fi Information" entitlement and location authorization.
    func refreshSSID(force: Bool) async {
        guard force || needsSSID else { return }
        lastSSIDRefresh = .now
        currentSSID = await NEHotspotNetwork.fetchCurrent()?.ssid
    }

    nonisolated private static func motionNames(_ activity: CMMotionActivity) -> [String] {
        var names: [String] = []
        if activity.walking { names.append("walking") }
        if activity.running { names.append("running") }
        if activity.cycling { names.append("cycling") }
        if activity.automotive { names.append("driving") }
        if activity.stationary { names.append("stationary") }
        return names
    }
}

// MARK: - CLLocationManagerDelegate

extension TrackerEngine: CLLocationManagerDelegate {
    // The manager is created on the main thread, so Core Location calls back on the main thread.

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let samples = locations.map(LocationSample.init)
        MainActor.assumeIsolated { handle(samples) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let sample = VisitSample(visit)
        MainActor.assumeIsolated { handle(sample) }
    }

    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { handlePause() }
    }

    nonisolated func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { handleResume() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let accuracy = manager.accuracyAuthorization
        MainActor.assumeIsolated {
            authorizationStatus = status
            accuracyAuthorization = accuracy
            applyLocationSettings()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        if (error as? CLError)?.code == .locationUnknown { return }
        Self.logger.error("Location error: \(error)")
    }
}

// MARK: - Background task assertion

/// Keeps the app alive long enough to finish an upload after it moves to the background.
private final class BackgroundTaskAssertion {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
