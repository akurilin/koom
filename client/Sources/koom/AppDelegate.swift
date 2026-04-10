import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private enum TerminationDecision {
        case stopAndSave
        case discard
        case keepRecording
    }

    private let model = AppModel()
    private var controlPanelWindow: NSWindow?
    private var isResolvingTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.info("koom launched.")
        AppLog.info("Persistent logs: \(AppLog.currentLogURL.path)")
        NSApp.setActivationPolicy(.regular)
        showControlPanel()
        maybePromptForSettings()
        model.warmBackgroundServices()
        maybeRecoverInterruptedRecording()
    }

    /// If either the backend URL or the admin secret is missing on
    /// launch, automatically open the Settings window so the user
    /// isn't stuck staring at a broken upload path the first time
    /// they try to record. Runs after a small delay so the control
    /// panel is already on screen when the settings window slides
    /// in — otherwise the settings window opens first and the
    /// control panel ends up behind it.
    private func maybePromptForSettings() {
        let activeEnvironment = KoomConfig.activeEnvironment
        guard KoomConfig.isFullyConfigured(for: activeEnvironment) else {
            AppLog.info(
                "koom is not fully configured for \(activeEnvironment.displayName); opening Settings window."
            )
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                NSApp.sendAction(
                    Selector(("showSettingsWindow:")),
                    to: nil,
                    from: nil
                )
            }
            return
        }

        AppLog.info(
            "koom configuration present for \(activeEnvironment.displayName); skipping first-run prompt."
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.info("koom terminating.")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isResolvingTermination else {
            return .terminateCancel
        }

        guard model.isRecordingInProgress else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Recording in progress"
        alert.informativeText =
            "Choose how koom should handle the current recording before quitting."
        alert.addButton(withTitle: "Stop and Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Keep Recording")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return resolveTermination(discardOutput: false)
        case .alertSecondButtonReturn:
            return resolveTermination(discardOutput: true)
        default:
            return .terminateCancel
        }
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
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.contentViewController = NSHostingController(rootView: contentView)
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.isRecordingInProgress else {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Recording in progress"
        alert.informativeText =
            "Stop or discard the current recording before closing the control panel."
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: sender)
        return false
    }

    private func maybeRecoverInterruptedRecording() {
        guard let controlPanelWindow else { return }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            await model.recoverInterruptedSessionsIfNeeded(
                attachedTo: controlPanelWindow
            )
        }
    }

    private func resolveTermination(discardOutput: Bool) -> NSApplication.TerminateReply {
        isResolvingTermination = true

        Task { @MainActor in
            let success = await model.resolveRecordingForTermination(
                discardOutput: discardOutput
            )

            if !success {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText =
                    discardOutput
                    ? "Could not discard recording"
                    : "Could not save recording"
                alert.informativeText =
                    "koom kept the app open because the current recording could not be finalized safely."
                alert.runModal()
            }

            isResolvingTermination = false
            NSApp.reply(toApplicationShouldTerminate: success)
        }

        return .terminateLater
    }
}
