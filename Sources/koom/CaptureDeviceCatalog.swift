@preconcurrency import AVFoundation

enum CaptureDeviceCatalog {
    static func cameras() -> [AVCaptureDevice] {
        var deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .externalUnknown,
        ]

        if #available(macOS 14.0, *) {
            deviceTypes.insert(.continuityCamera, at: 1)
        }

        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    static func microphones() -> [AVCaptureDevice] {
        var deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInMicrophone,
            .externalUnknown,
        ]

        if #available(macOS 14.0, *) {
            deviceTypes.insert(.microphone, at: 0)
        }

        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        ).devices
    }
}
