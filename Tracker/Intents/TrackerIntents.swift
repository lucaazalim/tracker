import AppIntents
import TrackerKit

// Shortcuts actions for automating Tracker, e.g. "When I arrive at work, switch to Battery saver".

struct StartTrackingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Tracking"
    static let description = IntentDescription("Turns location tracking on with the active profile.")

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        TrackerServices.shared.engine.setTrackingEnabled(true)
        return .result(dialog: "Tracking is on.")
    }
}

struct StopTrackingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Tracking"
    static let description = IntentDescription("Turns location tracking off. Queued records are kept.")

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        TrackerServices.shared.engine.setTrackingEnabled(false)
        return .result(dialog: "Tracking is off.")
    }
}

struct SwitchProfileIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch Profile"
    static let description = IntentDescription("Makes a profile active. Its capture and upload settings apply immediately.")

    @Parameter(title: "Profile")
    var profile: ProfileEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Switch to \(\.$profile)")
    }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard TrackerServices.shared.configuration.profile(id: profile.id) != nil else {
            throw $profile.needsValueError("That profile no longer exists. Which profile?")
        }
        TrackerServices.shared.engine.activateProfile(id: profile.id)
        return .result(dialog: "Switched to \(profile.name).")
    }
}

struct SendNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Upload Queued Records"
    static let description = IntentDescription("Uploads all queued records now, ignoring the send interval. Returns the number of records sent.")

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let report = await TrackerServices.shared.engine.sendNow()
        if let failure = report.failure {
            return .result(value: report.recordsSent, dialog: "Upload failed: \(failure)")
        }
        return .result(value: report.recordsSent, dialog: "Uploaded \(report.recordsSent) records.")
    }
}

struct QueueSizeIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Queue Size"
    static let description = IntentDescription("Returns the number of records waiting to be uploaded.")

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let engine = TrackerServices.shared.engine
        await engine.refreshSystemStatus()
        return .result(value: engine.queueCounts.total)
    }
}

// MARK: - Profile entity

struct ProfileEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Profile"
    static let defaultQuery = ProfileQuery()

    let id: UUID
    let name: String
    let symbol: String

    init(_ profile: Profile) {
        id = profile.id
        name = profile.name
        symbol = profile.symbol
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: symbol))
    }
}

struct ProfileQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [ProfileEntity] {
        TrackerServices.shared.configuration.configuration.profiles
            .filter { identifiers.contains($0.id) }
            .map(ProfileEntity.init)
    }

    @MainActor func entities(matching string: String) async throws -> [ProfileEntity] {
        TrackerServices.shared.configuration.configuration.profiles
            .filter { $0.name.localizedStandardContains(string) }
            .map(ProfileEntity.init)
    }

    @MainActor func suggestedEntities() async throws -> [ProfileEntity] {
        TrackerServices.shared.configuration.configuration.profiles.map(ProfileEntity.init)
    }
}

// MARK: - App Shortcuts

struct TrackerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartTrackingIntent(),
            phrases: ["Start tracking with \(.applicationName)", "Turn on \(.applicationName)"],
            shortTitle: "Start Tracking",
            systemImageName: "location.fill"
        )
        AppShortcut(
            intent: StopTrackingIntent(),
            phrases: ["Stop tracking with \(.applicationName)", "Turn off \(.applicationName)"],
            shortTitle: "Stop Tracking",
            systemImageName: "location.slash"
        )
        AppShortcut(
            intent: SwitchProfileIntent(),
            phrases: ["Switch \(.applicationName) to \(\.$profile)", "Use \(\.$profile) in \(.applicationName)"],
            shortTitle: "Switch Profile",
            systemImageName: "slider.horizontal.3"
        )
        AppShortcut(
            intent: SendNowIntent(),
            phrases: ["Upload \(.applicationName) data"],
            shortTitle: "Upload Now",
            systemImageName: "arrow.up.circle"
        )
    }
}
