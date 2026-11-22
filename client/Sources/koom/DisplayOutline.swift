import AppKit

/// Reuses one window to mark the display selected for recording.
@MainActor
final class DisplayOutlineController {
    private static let borderWidth: CGFloat = 8

    private let window: NSWindow

    init() {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // Above the menu bar and Dock, so the outline traces the whole
        // screen edge.
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.sharingType = .none

        let contentView = NSView()
        contentView.wantsLayer = true
        contentView.layer?.borderColor = NSColor.systemYellow.cgColor
        contentView.layer?.borderWidth = Self.borderWidth
        window.contentView = contentView

        self.window = window
    }

    func update(displayID: CGDirectDisplayID?) {
        guard let displayID, let screen = NSScreen.screen(displayID: displayID) else {
            window.orderOut(nil)
            return
        }

        if window.frame != screen.frame {
            window.setFrame(screen.frame, display: true)
        }
        if !window.isVisible {
            window.orderFrontRegardless()
        }
    }
}
