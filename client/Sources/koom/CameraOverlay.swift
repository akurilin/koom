@preconcurrency import AVFoundation
@preconcurrency import AppKit
import SwiftUI

final class CameraPreviewManager: @unchecked Sendable {
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "koom.camera.preview")
    private var activeInput: AVCaptureDeviceInput?

    init() {
        session.sessionPreset = .high
    }

    func setCamera(uniqueID: String?) {
        sessionQueue.async {
            self.session.beginConfiguration()

            if let activeInput = self.activeInput {
                self.session.removeInput(activeInput)
                self.activeInput = nil
            }

            guard
                let uniqueID,
                let device = CaptureDeviceCatalog.cameras().first(where: { $0.uniqueID == uniqueID }),
                let input = try? AVCaptureDeviceInput(device: device),
                self.session.canAddInput(input)
            else {
                self.session.commitConfiguration()
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                return
            }

            self.session.addInput(input)
            self.activeInput = input
            self.session.commitConfiguration()

            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }
}

final class CameraOverlayWindowController: NSWindowController {
    private static let previewDiameter: CGFloat = 176
    private static let shadowInset: CGFloat = 18
    private static let overlaySize = CGSize(
        width: previewDiameter + (shadowInset * 2),
        height: previewDiameter + (shadowInset * 2)
    )
    private lazy var hostingView = NSHostingView(
        rootView: CameraOverlayContent(
            session: AVCaptureSession(),
            previewDiameter: Self.previewDiameter,
            shadowInset: Self.shadowInset
        )
    )

    init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.overlaySize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true

        super.init(window: window)

        window.contentView = hostingView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(session: AVCaptureSession, displayID: CGDirectDisplayID, isVisible: Bool) {
        hostingView.rootView = CameraOverlayContent(
            session: session,
            previewDiameter: Self.previewDiameter,
            shadowInset: Self.shadowInset
        )

        guard isVisible, let window = window else {
            window?.orderOut(nil)
            return
        }

        guard let screen = NSScreen.screen(displayID: displayID) ?? NSScreen.main else {
            window.orderOut(nil)
            return
        }

        let frame = screen.frame
        let origin = NSPoint(
            x: frame.minX + 24 - Self.shadowInset,
            y: frame.minY + 24 - Self.shadowInset
        )
        window.setFrame(NSRect(origin: origin, size: Self.overlaySize), display: true)
        window.orderFrontRegardless()
    }
}

private struct CameraOverlayContent: View {
    let session: AVCaptureSession
    let previewDiameter: CGFloat
    let shadowInset: CGFloat

    var body: some View {
        CameraPreviewView(session: session)
            .frame(width: previewDiameter, height: previewDiameter)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .stroke(.white.opacity(0.9), lineWidth: 3)
            }
            .shadow(color: .black.opacity(0.2), radius: 7, x: 0, y: 4)
            .padding(shadowInset)
            .background(.clear)
    }
}

private struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewHostView {
        let view = CameraPreviewHostView()
        view.previewLayer.session = session
        view.applyMirroring()
        return view
    }

    func updateNSView(_ nsView: CameraPreviewHostView, context: Context) {
        nsView.previewLayer.session = session
        nsView.applyMirroring()
    }
}

private final class CameraPreviewHostView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = AVCaptureVideoPreviewLayer()
        previewLayer.videoGravity = .resizeAspectFill
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    func applyMirroring() {
        guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else {
            return
        }

        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        previewLayer.cornerRadius = bounds.width / 2
        previewLayer.masksToBounds = true
        applyMirroring()
    }
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
