import CoreLocation
import CoreMotion
import SwiftUI
import TrackerKit

/// The only "dashboard": is tracking healthy, and is data reaching the server?
struct StatusView: View {
    @Environment(TrackerEngine.self) private var engine
    @Environment(ConfigurationStore.self) private var store
    @Environment(AppRouter.self) private var router

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TrackingHero()
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }

                Section("Health") {
                    ForEach(healthChecks) { check in
                        HealthCheckRow(check: check)
                    }
                }

                Section("Queue") {
                    LabeledContent("Queued records") {
                        Text(engine.queueCounts.total, format: .number)
                            .contentTransition(.numericText())
                            .monospacedDigit()
                    }
                    if engine.queueCounts.events > 0 {
                        LabeledContent("Locations · Events", value: "\(engine.queueCounts.locations) · \(engine.queueCounts.events)")
                    }
                    LabeledContent("Last location") {
                        if let location = engine.lastLocation {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(location.timestamp, format: .relative(presentation: .named))
                                Text(Format.coordinate(location))
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        } else {
                            Text("None yet")
                        }
                    }
                    LabeledContent("Last upload") {
                        if let date = engine.lastUploadDate {
                            Text(date, format: .relative(presentation: .named))
                        } else {
                            Text("Never")
                        }
                    }
                    LabeledContent("Schedule", value: Format.sendInterval(store.activeProfile.upload.sendInterval))
                    if let error = engine.lastUploadError {
                        Label {
                            Text(error)
                                .font(.callout)
                                .textSelection(.enabled)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .navigationTitle("Tracker")
            .animation(.default, value: engine.queueCounts)
            .refreshable { await engine.refreshSystemStatus() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await engine.sendNow() }
                    } label: {
                        if engine.isUploading {
                            ProgressView()
                        } else {
                            Label("Send Now", systemImage: "arrow.up")
                        }
                    }
                    .disabled(engine.isUploading || !store.configuration.server.isConfigured)
                }
            }
        }
    }

    // MARK: Health checks

    private var healthChecks: [HealthCheck] {
        var checks: [HealthCheck] = []
        let server = store.configuration.server
        let profile = store.activeProfile

        checks.append(server.isConfigured
            ? HealthCheck(id: "endpoint", title: "Receiver", detail: URL(string: server.endpoint)?.host() ?? server.endpoint, level: .ok)
            : HealthCheck(id: "endpoint", title: "Receiver", detail: "No endpoint configured", level: .error, actionTitle: "Configure") {
                router.selectedTab = .server
            })

        switch engine.authorizationStatus {
        case .authorizedAlways:
            checks.append(HealthCheck(id: "location", title: "Location access", detail: "Always", level: .ok))
        case .authorizedWhenInUse:
            checks.append(HealthCheck(id: "location", title: "Location access", detail: "Only while using the app. Background tracking needs “Always”.", level: .warning, actionTitle: "Allow Always") {
                engine.requestLocationAuthorization()
            })
        case .notDetermined:
            checks.append(HealthCheck(id: "location", title: "Location access", detail: "Not requested yet", level: .warning, actionTitle: "Allow") {
                engine.requestLocationAuthorization()
            })
        default:
            checks.append(HealthCheck(id: "location", title: "Location access", detail: "Denied. Enable it in Settings.", level: .error, actionTitle: "Settings") {
                engine.openSystemSettings()
            })
        }

        if engine.accuracyAuthorization == .reducedAccuracy {
            checks.append(HealthCheck(id: "accuracy", title: "Precise location", detail: "Off. Locations are approximate.", level: .warning, actionTitle: "Settings") {
                engine.openSystemSettings()
            })
        }

        if profile.fields.motion {
            switch engine.motionAuthorization {
            case .authorized:
                break
            case .notDetermined:
                checks.append(HealthCheck(id: "motion", title: "Motion & Fitness", detail: "Needed for the motion field", level: .warning, actionTitle: "Allow") {
                    engine.requestMotionAuthorization()
                })
            default:
                checks.append(HealthCheck(id: "motion", title: "Motion & Fitness", detail: "Denied. Motion will be empty.", level: .warning, actionTitle: "Settings") {
                    engine.openSystemSettings()
                })
            }
        }

        if engine.backgroundRefreshStatus != .available {
            checks.append(HealthCheck(id: "refresh", title: "Background App Refresh", detail: "Off. Uploads only happen when locations arrive.", level: .warning, actionTitle: "Settings") {
                engine.openSystemSettings()
            })
        }

        if engine.isLowPowerModeEnabled {
            checks.append(HealthCheck(id: "power", title: "Low Power Mode", detail: "iOS may deliver fewer locations", level: .warning))
        }

        if store.configuration.notifications.anyEnabled, engine.notificationAuthorization == .denied {
            checks.append(HealthCheck(id: "notifications", title: "Notifications", detail: "Denied, so alerts like the watchdog can’t be shown", level: .warning, actionTitle: "Settings") {
                engine.openSystemSettings()
            })
        }

        return checks
    }
}

// MARK: - Hero

private struct TrackingHero: View {
    @Environment(TrackerEngine.self) private var engine
    @Environment(ConfigurationStore.self) private var store

    var body: some View {
        let isOn = engine.isTrackingEnabled

        GlassEffectContainer(spacing: 24) {
            VStack(spacing: 20) {
                Button {
                    engine.setTrackingEnabled(!isOn)
                } label: {
                    Image(systemName: isOn ? "location.fill" : "location.slash")
                        .font(.system(size: 44, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(isOn ? Color.white : Color.secondary)
                        .frame(width: 120, height: 120)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(isOn ? .regular.tint(.brand).interactive() : .regular.interactive(), in: .circle)
                .accessibilityLabel(isOn ? "Stop tracking" : "Start tracking")
                .sensoryFeedback(.impact(weight: .medium), trigger: isOn)

                VStack(spacing: 4) {
                    Text(title)
                        .font(.title2.bold())
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Menu {
                    Picker("Profile", selection: Binding(
                        get: { store.configuration.activeProfileID },
                        set: { engine.activateProfile(id: $0) }
                    )) {
                        ForEach(store.configuration.profiles) { profile in
                            Label(profile.name, systemImage: profile.symbol).tag(profile.id)
                        }
                    }
                } label: {
                    Label(store.activeProfile.name, systemImage: store.activeProfile.symbol)
                        .font(.headline)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.glass)
            }
            .padding(.vertical, 12)
        }
        .animation(.smooth, value: isOn)
    }

    private var title: String {
        guard engine.isTrackingEnabled else { return "Tracking off" }
        return engine.isPausedBySystem ? "Paused by iOS" : "Tracking"
    }

    private var subtitle: String {
        let capture = store.activeProfile.capture
        guard engine.isTrackingEnabled else { return "Tap to start recording with \(store.activeProfile.name)" }
        if engine.isPausedBySystem {
            return capture.resumeGeofenceRadius == nil
                ? "Resumes when iOS detects movement"
                : "Resumes after leaving a \(Format.distance(capture.resumeGeofenceRadius ?? 0)) radius"
        }
        if capture.trackingMode == .off {
            return capture.visits ? "Recording visits only" : "Location updates are off in this profile"
        }
        return "\(capture.trackingMode.title) · \(capture.desiredAccuracy.title)"
    }
}

// MARK: - Health check row

struct HealthCheck: Identifiable {
    enum Level { case ok, warning, error }

    let id: String
    let title: String
    let detail: String
    let level: Level
    var actionTitle: String?
    var action: (() -> Void)?
}

private struct HealthCheckRow: View {
    let check: HealthCheck

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                Text(check.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let actionTitle = check.actionTitle, let action = check.action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
    }

    private var symbol: String {
        switch check.level {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch check.level {
        case .ok: .green
        case .warning: .orange
        case .error: .red
        }
    }
}
