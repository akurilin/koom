@preconcurrency import AVFoundation
@preconcurrency import AppKit
import SwiftUI

enum CameraBubbleSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    static let defaultValue: Self = .medium

    var id: Self { self }

    var diameter: CGFloat {
        switch self {
        case .small: 176
        case .medium: 352
        case .large: 528
        }
    }

    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    var indicatorDiameter: CGFloat {
        switch self {
        case .small: 8
        case .medium: 13
        case .large: 18
        }
    }
}

final class CameraPreviewManager: @unchecked Sendable {
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "koom.camera.preview")
    private var activeInput: AVCaptureDeviceInput?

    init() {
        session.sessionPreset = .high
    }

    func setCamera(uniqueID: String?) {
        sessionQueue.async {
            if let uniqueID, self.activeInput?.device.uniqueID == uniqueID {
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                return
            }

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

private final class CameraOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class CameraOverlayState: ObservableObject {
    @Published private(set) var selectedSize: CameraBubbleSize
    @Published var microphoneSpectrum: MicrophoneSpectrum?

    private let onSizeChange: (CameraBubbleSize) -> Void

    init(
        selectedSize: CameraBubbleSize,
        onSizeChange: @escaping (CameraBubbleSize) -> Void
    ) {
        self.selectedSize = selectedSize
        self.onSizeChange = onSizeChange
    }

    func select(_ size: CameraBubbleSize) {
        guard size != selectedSize else { return }
        selectedSize = size
        onSizeChange(size)
    }

    func synchronize(_ size: CameraBubbleSize) {
        guard size != selectedSize else { return }
        selectedSize = size
    }
}

@MainActor
final class CameraOverlayWindowController: NSWindowController {
    private static let shadowInset: CGFloat = 18
    private let state: CameraOverlayState
    private let hostingView: NSHostingView<CameraOverlayContent>

    init(
        session: AVCaptureSession,
        initialSize: CameraBubbleSize,
        onSizeChange: @escaping (CameraBubbleSize) -> Void
    ) {
        let state = CameraOverlayState(
            selectedSize: initialSize,
            onSizeChange: onSizeChange
        )
        self.state = state
        hostingView = NSHostingView(
            rootView: CameraOverlayContent(
                session: session,
                state: state,
                shadowInset: Self.shadowInset
            )
        )

        let panel = CameraOverlayPanel(
            contentRect: NSRect(
                origin: .zero,
                size: Self.overlaySize(for: initialSize)
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        super.init(window: panel)

        panel.contentView = hostingView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        displayID: CGDirectDisplayID,
        isVisible: Bool,
        size: CameraBubbleSize
    ) {
        state.synchronize(size)

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
            x: frame.minX + AppModel.windowEdgePadding - Self.shadowInset,
            y: frame.minY + AppModel.windowEdgePadding - Self.shadowInset
        )
        window.setFrame(
            NSRect(origin: origin, size: Self.overlaySize(for: size)),
            display: true
        )
        window.orderFrontRegardless()
    }

    func setSize(_ size: CameraBubbleSize) {
        state.synchronize(size)

        guard let window else { return }
        let targetFrame = NSRect(
            origin: window.frame.origin,
            size: Self.overlaySize(for: size)
        )
        guard targetFrame != window.frame else { return }
        window.setFrame(targetFrame, display: true)
    }

    func setMicrophoneSpectrum(_ spectrum: MicrophoneSpectrum?) {
        state.microphoneSpectrum = spectrum
    }

    private static func overlaySize(for size: CameraBubbleSize) -> CGSize {
        CGSize(
            width: size.diameter + (shadowInset * 2),
            height: size.diameter + (shadowInset * 2)
        )
    }
}

private struct CameraOverlayContent: View {
    let session: AVCaptureSession
    @ObservedObject var state: CameraOverlayState
    let shadowInset: CGFloat

    @State private var isHovering = false

    private var previewDiameter: CGFloat {
        state.selectedSize.diameter
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraPreviewView(session: session)
                .frame(width: previewDiameter, height: previewDiameter)
                // Mirroring is a presentation invariant, independent of
                // when AVFoundation creates or replaces its connection.
                .scaleEffect(x: -1, y: 1)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.9), lineWidth: 3)
                }
                .shadow(color: .black.opacity(0.2), radius: 7, x: 0, y: 4)
                .overlay {
                    if let spectrum = state.microphoneSpectrum {
                        microphoneIndicator(spectrum)
                    }
                }
                .padding(shadowInset)

            if isHovering {
                sizeControls
                    .padding(.bottom, shadowInset + 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(
            width: previewDiameter + (shadowInset * 2),
            height: previewDiameter + (shadowInset * 2)
        )
        .contentShape(Rectangle())
        .onHover { isHovering in
            withAnimation(.easeInOut(duration: 0.22)) {
                self.isHovering = isHovering
            }
        }
        .background(.clear)
    }

    private func microphoneIndicator(_ spectrum: MicrophoneSpectrum) -> some View {
        let height = min(30, max(18, previewDiameter * 0.08))
        // Use the same inset from both edges so the capsule stays inside the circle.
        let travel = previewDiameter * 0.41 - height / 2
        return MicrophoneSpectrumView(spectrum: spectrum)
            .frame(width: previewDiameter * 0.46, height: height)
            .offset(y: isHovering ? -travel : travel)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var sizeControls: some View {
        HStack(spacing: 4) {
            ForEach(CameraBubbleSize.allCases) { size in
                sizeButton(for: size)
            }
        }
        .padding(6)
        .background {
            Capsule()
                .fill(Color.black.opacity(0.82))
        }
        .overlay {
            Capsule()
                .strokeBorder(Color.white.opacity(0.12))
        }
        .shadow(color: .black.opacity(0.28), radius: 8, x: 0, y: 3)
    }

    private func sizeButton(for size: CameraBubbleSize) -> some View {
        let isSelected = state.selectedSize == size

        return Button {
            state.select(size)
        } label: {
            Circle()
                .fill(Color.white.opacity(isSelected ? 1 : 0.72))
                .frame(width: size.indicatorDiameter, height: size.indicatorDiameter)
                .frame(width: 34, height: 34)
                .background {
                    Circle()
                        .fill(isSelected ? Color.white.opacity(0.16) : Color.clear)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Use a \(size.title.lowercased()) camera bubble")
        .accessibilityLabel("\(size.title) camera bubble")
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}

private struct MicrophoneSpectrumView: View {
    let spectrum: MicrophoneSpectrum

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            let levels = spectrum.currentLevels
            Canvas { context, size in
                let step = size.width / CGFloat(levels.count)
                let width = step * 0.55
                let restingHeight: CGFloat = 2
                for (index, level) in levels.enumerated() {
                    let height = restingHeight + (size.height - restingHeight) * CGFloat(level)
                    let bar = CGRect(
                        x: (CGFloat(index) + 0.5) * step - width / 2,
                        y: (size.height - height) / 2,
                        width: width,
                        height: height
                    )
                    context.fill(
                        Path(roundedRect: bar, cornerRadius: min(width, height) / 2),
                        with: .color(.white.opacity(0.35 + Double(level) * 0.6))
                    )
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.6), in: Capsule())
    }
}

private struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewHostView {
        let view = CameraPreviewHostView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ nsView: CameraPreviewHostView, context: Context) {
        guard nsView.previewLayer.session !== session else { return }
        nsView.previewLayer.session = session
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

    override func layout() {
        super.layout()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        previewLayer.cornerRadius = bounds.width / 2
        previewLayer.masksToBounds = true
        CATransaction.commit()
    }
}

extension NSScreen {
    static func screen(displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }

            return CGDirectDisplayID(number.uint32Value) == displayID
        }
    }
}
