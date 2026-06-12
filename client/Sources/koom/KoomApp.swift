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

    /// Posted by the rewired Cmd+, / "koom → Settings…" menu item.
    /// `AppModel` observes this and switches the main panel to the
    /// Settings tab (settings live in a tab now, not a window).
    static let koomShowSettingsTab = Notification.Name(
        "com.koom.local.showSettingsTab"
    )
}

@main
struct KoomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // SwiftUI requires at least one Scene, but all real windows
        // are created in AppDelegate. The Settings scene is inert:
        // the standard "Settings…" command that would open it is
        // replaced below with one that switches the main panel to
        // its Settings tab instead.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(
                        name: .koomShowSettingsTab,
                        object: nil
                    )
                }
                .keyboardShortcut(",", modifiers: .command)
            }

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
