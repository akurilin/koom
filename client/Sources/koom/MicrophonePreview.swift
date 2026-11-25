@preconcurrency import AVFoundation

final class MicrophonePreview: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let spectrum = MicrophoneSpectrum()

    private let sessionQueue = DispatchQueue(label: "koom.microphone.preview")
    private let sampleQueue = DispatchQueue(label: "koom.microphone.preview.samples")
    private var capture: (deviceID: String, session: AVCaptureSession)?
    private var receivedSamples = false

    func setMicrophone(uniqueID: String?) {
        sessionQueue.async {
            self.configureCapture(for: uniqueID)
        }
    }

    // Release the device before ScreenCaptureKit opens it.
    func stop() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                self.configureCapture(for: nil)
                continuation.resume()
            }
        }
    }

    private func configureCapture(for deviceID: String?) {
        guard capture?.deviceID != deviceID else { return }

        capture?.session.stopRunning()
        capture = nil
        sampleQueue.sync {
            spectrum?.reset()
            receivedSamples = false
        }

        let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
        guard
            let deviceID, spectrum != nil,
            authorization == .authorized || authorization == .notDetermined,
            let device = CaptureDeviceCatalog.microphones().first(where: { $0.uniqueID == deviceID }),
            let input = try? AVCaptureDeviceInput(device: device)
        else { return }

        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        guard session.canAddInput(input) else { return }
        session.addInput(input)
        guard session.canAddOutput(output) else { return }
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        session.addOutput(output)

        session.startRunning()
        if session.isRunning {
            capture = (deviceID, session)
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if !receivedSamples {
            receivedSamples = true
            AppLog.info("Microphone preview received audio.")
        }
        spectrum?.consume(sampleBuffer)
    }
}
