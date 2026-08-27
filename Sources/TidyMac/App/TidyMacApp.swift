import SwiftUI

/// Returns fans to firmware control if the app quits while it is driving them,
/// so a closed app can never leave fans pinned at a fixed speed.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var state: AppState?

    func applicationWillTerminate(_ notification: Notification) {
        if let state = Self.state, state.fanControl.hasOverrides {
            try? state.fanController.resetAllDirect()
        }
    }
}

@main
struct TidyMacApp: App {
    @StateObject private var state = AppState()
    @StateObject private var nav = Navigation()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        AppearanceMode.applyStored()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environmentObject(state)
                .environmentObject(nav)
                .frame(minWidth: 860, minHeight: 580)
                .onAppear {
                    // Give the background scan somewhere to park its results
                    // before anything can start one.
                    state.navigation = nav
                    state.start()
                    AppDelegate.state = state
                    NotificationService.shared.requestAuthorizationIfNeeded()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 680)
        .commands { CommandGroup(replacing: .newItem) {} }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
                .environmentObject(nav)
                .tint(Theme.accent)
        } label: {
            MenuBarLabel()
                .environmentObject(state)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}
