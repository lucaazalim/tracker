import SwiftUI
import TrackerKit

struct RootView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router

        TabView(selection: $router.selectedTab) {
            Tab("Status", systemImage: "location.circle", value: AppTab.status) {
                StatusView()
            }
            Tab("Profiles", systemImage: "slider.horizontal.3", value: AppTab.profiles) {
                ProfilesView()
            }
            Tab("Server", systemImage: "server.rack", value: AppTab.server) {
                ServerView()
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
        }
        .tint(.brand)
        .sheet(item: $router.pendingImport) { pending in
            ImportReviewView(pending: pending)
        }
        .alert("Couldn’t Import", isPresented: Binding(
            get: { router.importError != nil },
            set: { if !$0 { router.importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(router.importError ?? "")
        }
        .alert("Storage Problem", isPresented: Binding(
            get: { router.startupError != nil },
            set: { if !$0 { router.startupError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(router.startupError ?? "")
        }
    }
}

#Preview {
    RootView()
        .environment(TrackerServices.shared.configuration)
        .environment(TrackerServices.shared.engine)
        .environment(TrackerServices.shared.router)
}
