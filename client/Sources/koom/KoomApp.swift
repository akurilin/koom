import SwiftUI

@main
struct KoomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // SwiftUI's Settings scene wires the settings window up for
        // free: the view below is reachable via Cmd+, and the
        // "koom → Settings…" menu item without any extra glue. On
        // first launch with missing credentials, AppDelegate pops
        // the window programmatically via NSApplication's
        // showSettingsWindow(_:) action.
        Settings {
            SettingsView()
        }
    }
}
