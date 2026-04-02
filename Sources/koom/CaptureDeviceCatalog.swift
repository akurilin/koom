@preconcurrency import AVFoundation

enum CaptureDeviceCatalog {
    static func cameras() -> [AVCaptureDevice] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [
                .builtInWideAngleCamera,
                .continuityCamera,
                .external,
            ]
        } else {
            deviceTypes = [
                .builtInWideAngleCamera,
                .externalUnknown,
            ]
        }

        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    static func microphones() -> [AVCaptureDevice] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [
                .microphone,
                .external,
            ]
        } else {
            deviceTypes = [
                .builtInMicrophone,
                .externalUnknown,
            ]
        }

        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        ).devices
    }
}
