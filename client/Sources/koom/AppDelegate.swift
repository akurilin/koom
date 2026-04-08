import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var controlPanelWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.info("koom launched.")
        NSApp.setActivationPolicy(.regular)
        showControlPanel()
        maybePromptForSettings()
    }

    /// If either the backend URL or the admin secret is missing on
    /// launch, automatically open the Settings window so the user
    /// isn't stuck staring at a broken upload path the first time
    /// they try to record. Runs after a small delay so the control
    /// panel is already on screen when the settings window slides
    /// in — otherwise the settings window opens first and the
    /// control panel ends up behind it.
    private func maybePromptForSettings() {
        guard !KoomConfig.isFullyConfigured else {
            AppLog.info("koom configuration present; skipping first-run prompt.")
            return
        }

        AppLog.info("koom is not fully configured; opening Settings window.")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            NSApp.sendAction(
                Selector(("showSettingsWindow:")),
                to: nil,
                from: nil
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.info("koom terminating.")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showControlPanel()
        } else {
            focusControlPanel()
        }

        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func showControlPanel() {
        let window = controlPanelWindow ?? makeControlPanelWindow()
        controlPanelWindow = window

        AppLog.info("Showing control panel.")
        model.refreshHardware()
        model.configureControlWindow(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func focusControlPanel() {
        guard let controlPanelWindow else {
            showControlPanel()
            return
        }

        AppLog.info("Focusing control panel.")
        controlPanelWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeControlPanelWindow() -> NSWindow {
        let contentView = ControlPanelView()
            .environmentObject(model)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 380),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.contentViewController = NSHostingController(rootView: contentView)
        window.isReleasedWhenClosed = false
        return window
    }
}
