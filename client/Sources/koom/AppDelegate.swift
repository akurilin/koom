import AppKit
import SwiftUI

/// Borderless windows refuse key status by default, which would make
/// the Settings tab's text fields untypeable.
private final class BorderlessPanelWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum TerminationDecision {
        case stopAndSave
        case discard
        case keepRecording
    }

    private let model = AppModel()
    private var controlPanelWindow: NSWindow?
    private var recorderRemoteController: RecorderRemoteWindowController?
    private var panelSizeObservation: NSKeyValueObservation?
    private var isResolvingTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.info("koom launched.")
        AppLog.info("Persistent logs: \(AppLog.currentLogURL.path)")
        NSApp.setActivationPolicy(.regular)
        showControlPanel()
        showRecorderRemote()
        selectInitialTab()
        model.warmBackgroundServices()
    }

    /// Picks which tab the panel opens on: Settings when the active
    /// environment is missing credentials (a recording would have no
    /// upload path), Recovery when interrupted sessions are waiting,
    /// and Record otherwise.
    private func selectInitialTab() {
        model.refreshRecoverableSessions()

        let activeEnvironment = KoomConfig.activeEnvironment
        if !KoomConfig.isFullyConfigured(for: activeEnvironment) {
            AppLog.info(
                "koom is not fully configured for \(activeEnvironment.displayName); opening the Settings tab."
            )
            model.selectedTab = .settings
        } else if !model.recoverableSessions.isEmpty {
            AppLog.info(
                "Found \(model.recoverableSessions.count) interrupted session(s); opening the Recovery tab."
            )
            model.selectedTab = .recovery
        }
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

        // Borderless, Loom-style: the panel draws its own rounded
        // chrome and close button, so there is no titlebar and no
        // traffic lights. The in-panel X quits the app (going through
        // the usual recording-in-progress termination guard).
        let window = BorderlessPanelWindow(
            contentRect: NSRect(
                origin: .zero,
                size: NSSize(width: AppModel.panelWidth, height: 400)
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // The panel sizes itself to its content: the hosting
        // controller publishes SwiftUI's ideal size through
        // preferredContentSize, and the window follows it, keeping
        // the top edge anchored so growth extends downward.
        let hostingController = NSHostingController(rootView: contentView)
        hostingController.sizingOptions = .preferredContentSize
        window.contentViewController = hostingController

        panelSizeObservation = hostingController.observe(
            \.preferredContentSize,
            options: [.initial, .new]
        ) { [weak window] _, change in
            guard let window, let size = change.newValue, size.height > 1 else { return }
            Task { @MainActor in
                let frame = window.frame
                guard abs(frame.height - size.height) > 0.5 else { return }
                window.setFrame(
                    NSRect(
                        x: frame.minX,
                        y: frame.maxY - size.height,
                        width: frame.width,
                        height: size.height
                    ),
                    display: true,
                    animate: true
                )
            }
        }

        window.isReleasedWhenClosed = false
        return window
    }

    private func showRecorderRemote() {
        let controller = recorderRemoteController ?? RecorderRemoteWindowController(model: model)
        recorderRemoteController = controller
        controller.show()
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
