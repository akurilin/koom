import AppKit
import QuartzCore

/// Briefly outlines a physical display in yellow so the user can see
/// which screen they just picked in the display menu. One window is
/// reused, so picking again restarts the flash instead of stacking.
@MainActor
final class DisplayFlashController {
    private static let holdSeconds = 1.4
    private static let fadeSeconds = 0.6
    private static let borderWidth: CGFloat = 8

    private let window: NSWindow
    private let borderLayer = CALayer()
    private var hideTask: Task<Void, Never>?

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
        // Recording can start while the flash is still fading.
        window.sharingType = .none

        let contentView = NSView()
        contentView.wantsLayer = true
        borderLayer.borderColor = NSColor.systemYellow.cgColor
        borderLayer.borderWidth = Self.borderWidth
        borderLayer.opacity = 0
        contentView.layer?.addSublayer(borderLayer)
        window.contentView = contentView

        self.window = window
    }

    func flash(displayID: CGDirectDisplayID) {
        guard let screen = NSScreen.screen(displayID: displayID) else { return }

        hideTask?.cancel()
        window.setFrame(screen.frame, display: false)
        // Without this, re-picking mid-flash on a screen of another size
        // would visibly animate the border to its new size.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        borderLayer.frame = window.contentView?.bounds ?? .zero
        CATransaction.commit()

        let total = Self.holdSeconds + Self.fadeSeconds
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, NSNumber(value: Self.holdSeconds / total), 1]
        fade.duration = total
        borderLayer.removeAllAnimations()
        borderLayer.add(fade, forKey: "flash")
        window.orderFrontRegardless()

        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(total))
            guard !Task.isCancelled else { return }
            self?.window.orderOut(nil)
        }
    }
}
