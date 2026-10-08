import Foundation
import Observation
import OSLog
import TrackerKit

/// Owns the persisted `TrackerConfiguration` and publishes changes to the UI and the engine.
@Observable
final class ConfigurationStore {
    var configuration: TrackerConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            scheduleSave()
            for observer in observers { observer(oldValue, configuration) }
        }
    }

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [(TrackerConfiguration, TrackerConfiguration) -> Void] = []

    private static let logger = Logger(subsystem: Logger.subsystem, category: "Configuration")

    init(fileURL: URL) {
        self.fileURL = fileURL
        do {
            let data = try Data(contentsOf: fileURL)
            configuration = try JSONDecoder().decode(TrackerConfiguration.self, from: data)
        } catch CocoaError.fileReadNoSuchFile {
            configuration = .makeDefault()
        } catch {
            Self.logger.error("Could not load configuration, using defaults: \(error)")
            configuration = .makeDefault()
        }
    }

    /// In-memory store for SwiftUI previews.
    static func preview() -> ConfigurationStore {
        ConfigurationStore(fileURL: URL.temporaryDirectory.appending(path: "preview-\(UUID().uuidString).json"))
    }

    var activeProfile: Profile { configuration.activeProfile }

    /// Called with `(old, new)` after every change.
    func observe(_ observer: @escaping (TrackerConfiguration, TrackerConfiguration) -> Void) {
        observers.append(observer)
    }

    func update(_ change: (inout TrackerConfiguration) -> Void) {
        var copy = configuration
        change(&copy)
        configuration = copy
    }

    // MARK: Profiles

    func profile(id: UUID) -> Profile? {
        configuration.profiles.first { $0.id == id }
    }

    func updateProfile(_ profile: Profile) {
        update { config in
            if let index = config.profiles.firstIndex(where: { $0.id == profile.id }) {
                config.profiles[index] = profile
            }
        }
    }

    @discardableResult
    func addProfile(basedOn source: Profile? = nil) -> Profile {
        var profile = source ?? Profile.balanced()
        profile.id = UUID()
        profile.name = uniqueName(source.map { "\($0.name) copy" } ?? "New profile")
        update { $0.profiles.append(profile) }
        return profile
    }

    func deleteProfile(id: UUID) {
        update { config in
            guard config.profiles.count > 1 else { return }
            config.profiles.removeAll { $0.id == id }
            if config.activeProfileID == id { config.activeProfileID = config.profiles[0].id }
        }
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(configuration.profiles.map(\.name))
        guard names.contains(base) else { return base }
        var counter = 2
        while names.contains("\(base) \(counter)") { counter += 1 }
        return "\(base) \(counter)"
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            // Coalesce bursts of edits (e.g. typing in a text field) into a single write.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    func save() {
        saveTask?.cancel()
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // Readable after first unlock, so background launches can load it while the device is locked.
            try encoder.encode(configuration).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Self.logger.error("Could not save configuration: \(error)")
        }
    }
}

extension Logger {
    nonisolated static let subsystem = Bundle.main.bundleIdentifier ?? "Tracker"
}
