import AppKit
import Foundation
import SwiftUI

/// Notification posted by the "Recordings → Sync Unsent Recordings…"
/// menu command. `AppModel` observes this in its initializer to
/// kick off `catchUpRecordings()`. Using a notification (instead of
/// giving the command block a direct reference to `AppModel`) keeps
/// the SwiftUI commands declarative while still reaching the
/// `@MainActor` model that lives inside `AppDelegate`.
extension Notification.Name {
    static let koomCatchUpRequested = Notification.Name(
        "com.koom.local.catchUpRequested"
    )
}

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
        .commands {
            // "Recordings" menu lives next to the default menus and
            // is where recording-related commands live. For now
            // there is just one, but this is where future items
            // like "Reveal Recordings Folder" or "Clear Local
            // Recordings" would go.
            CommandMenu("Recordings") {
                Button("Sync Unsent Recordings…") {
                    NotificationCenter.default.post(
                        name: .koomCatchUpRequested,
                        object: nil
                    )
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            }

            CommandMenu("Troubleshooting") {
                Button("Reveal Logs in Finder") {
                    AppLog.revealLogsInFinder()
                }
            }
        }
    }
}
