import AppKit
import QuartzCore

// MARK: - Stroke

/// A completed pen stroke and the moment it was finished. The canvas
/// fades it linearly over `DrawingCanvasView.decaySeconds` and then
/// removes it.
private final class Stroke {
    let shapeLayer: CAShapeLayer
    let completedAt: CFTimeInterval

    init(shapeLayer: CAShapeLayer, completedAt: CFTimeInterval) {
        self.shapeLayer = shapeLayer
        self.completedAt = completedAt
    }
}

// MARK: - Canvas view

/// The full-screen drawing surface. Captures mouse-down / drag / up
/// to build `CAShapeLayer` strokes that decay after a fixed interval.
final class DrawingCanvasView: NSView {
    static let decaySeconds: CFTimeInterval = 5.0

    private let strokeColor: CGColor = NSColor.systemRed.cgColor
    private let strokeWidth: CGFloat = 3.0

    private var completedStrokes: [Stroke] = []
    private var activePath: CGMutablePath?
    private var activeLayer: CAShapeLayer?
    private var decayTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func activate() {
        decayTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / 30.0,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
    }

    func deactivate() {
        decayTimer?.invalidate()
        decayTimer = nil
        removeAllStrokes()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        let path = CGMutablePath()
        path.move(to: point)

        let layer = makeStrokeLayer()
        layer.path = path
        self.layer?.addSublayer(layer)

        activePath = path
        activeLayer = layer
    }

    override func mouseDragged(with event: NSEvent) {
        guard let path = activePath, let layer = activeLayer else { return }
        let point = convert(event.locationInWindow, from: nil)
        path.addLine(to: point)
        layer.path = path
    }

    override func mouseUp(with event: NSEvent) {
        guard let layer = activeLayer else { return }

        // A click without drag produces a visible dot.
        if let path = activePath, path.boundingBoxOfPath.width < 1, path.boundingBoxOfPath.height < 1 {
            let point = convert(event.locationInWindow, from: nil)
            activePath?.addLine(to: CGPoint(x: point.x + 0.5, y: point.y + 0.5))
            layer.path = activePath
        }

        completedStrokes.append(Stroke(shapeLayer: layer, completedAt: CACurrentMediaTime()))
        activePath = nil
        activeLayer = nil
    }

    // MARK: Cursor

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: Private

    private func tick() {
        let now = CACurrentMediaTime()
        let decay = Self.decaySeconds

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        completedStrokes.removeAll { stroke in
            let age = now - stroke.completedAt
            if age >= decay {
                stroke.shapeLayer.removeFromSuperlayer()
                return true
            }
            stroke.shapeLayer.opacity = Float(1.0 - age / decay)
            return false
        }

        CATransaction.commit()
    }

    private func removeAllStrokes() {
        for stroke in completedStrokes {
            stroke.shapeLayer.removeFromSuperlayer()
        }
        completedStrokes.removeAll()
        activeLayer?.removeFromSuperlayer()
        activePath = nil
        activeLayer = nil
    }

    private func makeStrokeLayer() -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.strokeColor = strokeColor
        layer.fillColor = nil
        layer.lineWidth = strokeWidth
        layer.lineCap = .round
        layer.lineJoin = .round
        return layer
    }
}

// MARK: - Overlay window

/// A non-activating panel that sits just below `.floating` so the
/// control panel and camera overlay stay clickable above it. Clicks
/// pass through when `ignoresMouseEvents` is `true` (the default);
/// flipping it to `false` turns the panel into the drawing surface.
private final class DrawingOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Window controller

final class DrawingOverlayWindowController: NSWindowController {
    private let canvasView = DrawingCanvasView(frame: .zero)
    private var escapeMonitor: Any?

    init() {
        let window = DrawingOverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // One level below .floating so the control panel and camera
        // overlay (both .floating) stay above the drawing surface.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = true

        super.init(window: window)

        window.contentView = canvasView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func activate(displayID: CGDirectDisplayID) {
        guard let window = window else { return }
        guard let screen = NSScreen.screen(displayID: displayID) ?? NSScreen.main else { return }

        window.setFrame(screen.frame, display: true)
        window.ignoresMouseEvents = false
        window.orderFrontRegardless()
        canvasView.activate()
        installEscapeMonitor()
    }

    func deactivate() {
        removeEscapeMonitor()
        canvasView.deactivate()
        window?.ignoresMouseEvents = true
        window?.orderOut(nil)
    }

    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                NotificationCenter.default.post(name: .koomToggleDrawingMode, object: nil)
                return nil
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }
}

extension Notification.Name {
    static let koomToggleDrawingMode = Notification.Name("com.koom.local.toggleDrawingMode")
}

private extension NSScreen {
    static func screen(displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(number.uint32Value) == displayID
        }
    }
}
