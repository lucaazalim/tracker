import SwiftUI
import UIKit

@main
struct TrackerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    private let services = TrackerServices.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(services.configuration)
                .environment(services.engine)
                .environment(services.router)
                .onOpenURL { services.router.handle(url: $0) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: services.engine.sceneDidBecomeActive()
            case .background: services.engine.sceneDidEnterBackground()
            default: break
            }
        }
        .backgroundTask(.appRefresh(TrackerEngine.refreshTaskIdentifier)) {
            await TrackerServices.shared.engine.performBackgroundRefresh()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Instantiating the services starts Core Location, which then delivers the event that launched us
        // (location, visit or geofence) through its delegate.
        _ = TrackerServices.shared
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        TrackerServices.shared.engine.applicationWillTerminate()
    }
}
