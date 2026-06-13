import CoreMedia
import Foundation

enum CaptureFrameRateOption: Int, CaseIterable, Identifiable, Sendable {
    case reduced15 = 15
    case standard30 = 30

    var id: Int { rawValue }

    var framesPerSecond: Int { rawValue }

    var minimumFrameInterval: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(rawValue))
    }

    var keyFrameInterval: Int { rawValue * 2 }

    var label: String {
        switch self {
        case .reduced15:
            return "Reduced motion (15 fps)"
        case .standard30:
            return "Standard motion (30 fps)"
        }
    }
}

struct CompressionSettings: Equatable, Sendable {
    let captureFrameRate: CaptureFrameRateOption
    let uploadRecordings: Bool
    let optimizeRecordings: Bool

    static let `default` = CompressionSettings(
        captureFrameRate: .standard30,
        uploadRecordings: true,
        optimizeRecordings: true
    )

    var logDescription: String {
        "\(captureFrameRate.framesPerSecond) fps capture, recording optimization \(optimizeRecordings ? "enabled" : "disabled"), backend upload \(uploadRecordings ? "enabled" : "disabled")"
    }
}
