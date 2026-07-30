import CoreMedia
import Foundation

struct CaptureDimensions: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
}

enum CaptureResolutionOption: String, CaseIterable, Codable, Identifiable, Sendable {
    case hd720 = "720p"
    case fullHD1080 = "1080p"
    case ultraHD4K = "4k"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hd720:
            return "720p"
        case .fullHD1080:
            return "1080p (Recommended)"
        case .ultraHD4K:
            return "4K"
        }
    }

    private var landscapeBounds: CaptureDimensions {
        switch self {
        case .hd720:
            return CaptureDimensions(width: 1_280, height: 720)
        case .fullHD1080:
            return CaptureDimensions(width: 1_920, height: 1_080)
        case .ultraHD4K:
            return CaptureDimensions(width: 3_840, height: 2_160)
        }
    }

    /// Resolves the recording's pixel dimensions from the display's logical
    /// point size and backing scale. Presets are upper bounds rather than
    /// forced canvases: unusual aspect ratios are preserved, portrait displays
    /// swap the bounds, and low-resolution sources are never enlarged.
    func captureDimensions(
        displayPointWidth: Int,
        displayPointHeight: Int,
        pointPixelScale: Double
    ) -> CaptureDimensions {
        let sourceWidth = max(Double(displayPointWidth) * pointPixelScale, 2)
        let sourceHeight = max(Double(displayPointHeight) * pointPixelScale, 2)
        let isPortrait = sourceHeight > sourceWidth
        let bounds = landscapeBounds
        let maximumWidth = Double(isPortrait ? bounds.height : bounds.width)
        let maximumHeight = Double(isPortrait ? bounds.width : bounds.height)
        let scale = min(
            1,
            maximumWidth / sourceWidth,
            maximumHeight / sourceHeight
        )

        return CaptureDimensions(
            width: Self.evenPixelCount(sourceWidth * scale),
            height: Self.evenPixelCount(sourceHeight * scale)
        )
    }

    private static func evenPixelCount(_ value: Double) -> Int {
        max(2, Int(value.rounded(.down)) / 2 * 2)
    }
}

enum CaptureFrameRateOption: Int, CaseIterable, Codable, Identifiable, Sendable {
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
    let captureResolution: CaptureResolutionOption
    let captureFrameRate: CaptureFrameRateOption
    let uploadRecordings: Bool
    let optimizeRecordings: Bool

    static let `default` = CompressionSettings(
        captureResolution: .fullHD1080,
        captureFrameRate: .standard30,
        uploadRecordings: true,
        optimizeRecordings: true
    )

    var logDescription: String {
        "\(captureResolution.label), \(captureFrameRate.framesPerSecond) fps capture, recording optimization \(optimizeRecordings ? "enabled" : "disabled"), backend upload \(uploadRecordings ? "enabled" : "disabled")"
    }
}
