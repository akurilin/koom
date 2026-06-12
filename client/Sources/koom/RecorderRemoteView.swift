import AppKit
import SwiftUI

/// The Loom-style recording remote: a small dark strip that floats on
/// every Space from app launch. Its window is permanently excluded
/// from screen capture (`sharingType = .none`), so it never shows up
/// in recordings even though the user always sees it.
struct RecorderRemoteView: View {
    @EnvironmentObject private var model: AppModel

    static let stripWidth: CGFloat = 76

    private let accentRed = Color(red: 0.93, green: 0.26, blue: 0.23)

    private var isRecordingActive: Bool {
        model.recordingState != .idle
    }

    private var canUseRecordingControls: Bool {
        isRecordingActive && !model.isBusy
    }

    private var elapsedText: String {
        let totalSeconds = model.recordingElapsedSeconds
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    var body: some View {
        VStack(spacing: 12) {
            // Stop
            Button {
                if model.isDrawingModeActive { model.toggleDrawingMode() }
                model.stopRecording()
            } label: {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(canUseRecordingControls ? accentRed : Color.white.opacity(0.14))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canUseRecordingControls)
            .help("Stop recording")

            Text(elapsedText)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(isRecordingActive ? 0.95 : 0.45))

            // Pause / Resume
            remoteButton(
                symbol: model.recordingState == .paused ? "play.fill" : "pause.fill",
                help: model.recordingState == .paused ? "Resume" : "Pause",
                isEnabled: canUseRecordingControls
            ) {
                model.togglePause()
            }

            // Restart
            remoteButton(
                symbol: "arrow.counterclockwise",
                help: "Restart recording",
                isEnabled: canUseRecordingControls
            ) {
                if model.isDrawingModeActive { model.toggleDrawingMode() }
                model.restartRecording()
            }

            // Trash
            remoteButton(
                symbol: "trash",
                help: "Discard recording",
                isEnabled: canUseRecordingControls
            ) {
                if model.isDrawingModeActive { model.toggleDrawingMode() }
                model.discardRecording()
            }

            Divider()
                .overlay(Color.white.opacity(0.25))
                .frame(width: 30)

            // Pencil — works outside recordings too.
            remoteButton(
                symbol: "pencil.tip",
                help: model.isDrawingModeActive ? "Exit drawing mode" : "Draw on screen",
                isEnabled: true,
                isActive: model.isDrawingModeActive
            ) {
                model.toggleDrawingMode()
            }
        }
        .padding(.vertical, 18)
        .frame(width: Self.stripWidth)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color(red: 0.12, green: 0.12, blue: 0.13))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1))
        }
        .padding(10)
    }

    private func remoteButton(
        symbol: String,
        help: String,
        isEnabled: Bool,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(isEnabled ? 0.92 : 0.35))
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isActive ? Color.accentColor : Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
    }
}

/// Borderless panel that can take key clicks without activating koom,
/// so pressing pause/draw never steals focus from the app being
/// recorded.
private final class RecorderRemotePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class RecorderRemoteWindowController: NSWindowController {
    init(model: AppModel) {
        let hostingController = NSHostingController(
            rootView: RecorderRemoteView().environmentObject(model)
        )

        let panel = RecorderRemotePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hostingController
        panel.setContentSize(hostingController.view.fittingSize)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        // Never capture the remote in the recording itself.
        panel.sharingType = .none

        super.init(window: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows the remote pinned near the left edge of the main screen,
    /// vertically centered, mirroring where Loom puts it.
    func show() {
        guard let panel = window else { return }

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let origin = NSPoint(
                x: screen.visibleFrame.minX + 16,
                y: screen.visibleFrame.midY - (panel.frame.height / 2)
            )
            panel.setFrameOrigin(origin)
        }

        panel.orderFrontRegardless()
    }
}
