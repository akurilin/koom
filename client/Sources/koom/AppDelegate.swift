import AppKit
import SwiftUI

/// Borderless windows refuse key status by default, which would make
/// the Settings tab's text fields untypeable.
private final class BorderlessPanelWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

enum ControlPanelLayout {
    static func resizedFrame(
        currentFrame: NSRect,
        preferredContentSize: NSSize,
        visibleFrame: NSRect?,
        edgePadding: CGFloat,
        anchorAtTopRight: Bool
    ) -> NSRect {
        let fallbackOrigin = NSPoint(
            x: currentFrame.minX,
            y: currentFrame.maxY - preferredContentSize.height
        )

        guard let visibleFrame else {
            return NSRect(
                origin: fallbackOrigin,
                size: preferredContentSize
            )
        }

        let paddedMaxX = visibleFrame.maxX - edgePadding
        let paddedMaxY = visibleFrame.maxY - edgePadding
        let isAnchoredAtTopRight =
            anchorAtTopRight
            || (abs(currentFrame.maxX - paddedMaxX) < 1
                && abs(currentFrame.maxY - paddedMaxY) < 1)

        let origin =
            if isAnchoredAtTopRight {
                NSPoint(
                    x: paddedMaxX - preferredContentSize.width,
                    y: paddedMaxY - preferredContentSize.height
                )
            } else {
                fallbackOrigin
            }

        return NSRect(
            origin: origin,
            size: preferredContentSize
        )
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private enum TerminationDecision {
        case stopAndSave
        case discard
        case keepRecording
    }

    private let model = AppModel()
    private var controlPanelWindow: NSWindow?
    private var recorderRemoteController: RecorderRemoteWindowController?
    private var panelSizeObservation: NSKeyValueObservation?
    private var hasPositionedControlPanel = false
    private var isResolvingTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.info("koom launched.")
        AppLog.info("Persistent logs: \(AppLog.currentLogURL.path)")
        NSApp.setActivationPolicy(.regular)
        showControlPanel()
        showRecorderRemote()
        selectInitialTab()
        model.warmBackgroundServices()
        model.runRecordingSoakIfRequested()
    }

    /// Recording is the app's primary job, so every launch begins on
    /// Record. Missing upload configuration remains visible in
    /// Settings but does not block making a local recording.
    private func selectInitialTab() {
        model.refreshRecoverableSessions()
        model.selectedTab = .record
        AppLog.info("Opening the Record tab.")
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopBackgroundServices()
        AppLog.info("koom terminating.")
    }

    func applicationDidHide(_ notification: Notification) {
        model.updateDisplayOutline()
    }

    func applicationDidUnhide(_ notification: Notification) {
        model.updateDisplayOutline()
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

    func windowDidChangeOcclusionState(_ notification: Notification) {
        model.updateDisplayOutline()
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
        ) { [weak self, weak window] _, change in
            guard
                let self,
                let window,
                let size = change.newValue,
                size.width > 1,
                size.height > 1
            else { return }
            Task { @MainActor in
                let frame = window.frame
                let isInitialPlacement = !self.hasPositionedControlPanel
                guard
                    isInitialPlacement
                        || abs(frame.width - size.width) > 0.5
                        || abs(frame.height - size.height) > 0.5
                else { return }

                let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
                let resizedFrame = ControlPanelLayout.resizedFrame(
                    currentFrame: frame,
                    preferredContentSize: size,
                    visibleFrame: screen?.visibleFrame,
                    edgePadding: AppModel.windowEdgePadding,
                    anchorAtTopRight: isInitialPlacement
                )
                window.setFrame(
                    resizedFrame,
                    display: true,
                    animate: !isInitialPlacement
                )
                self.hasPositionedControlPanel = true

                if isInitialPlacement, let screen {
                    AppLog.info(
                        "Placed control panel at the top-right of \(screen.localizedName), frame \(Int(resizedFrame.width))x\(Int(resizedFrame.height)) at (\(Int(resizedFrame.minX)), \(Int(resizedFrame.minY)))."
                    )
                }
            }
        }

        window.delegate = self
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
