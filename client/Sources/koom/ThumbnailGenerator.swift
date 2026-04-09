@preconcurrency import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Best-effort local thumbnail generator for finalized recordings.
///
/// The output is a small JPEG sidecar that the web app can display in
/// the recordings grid without poking the MP4 at all. Any failure is a
/// quiet no-op: upload continues and the web UI falls back to the
/// video's first-frame preview.
enum ThumbnailGenerator {
    private static let captureTimes: [CMTime] = [
        CMTime(seconds: 0.1, preferredTimescale: 600),
        .zero,
    ]
    private static let maximumSize = CGSize(width: 640, height: 360)
    private static let compressionQuality = 0.8

    static func generateJPEGData(from fileURL: URL) async -> Data? {
        let filename = fileURL.lastPathComponent

        for time in captureTimes {
            do {
                let image = try await generateCGImage(from: fileURL, at: time)
                guard let jpegData = encodeJPEG(image: image) else {
                    AppLog.error("Thumbnail: failed to encode JPEG for \(filename).")
                    return nil
                }

                AppLog.info(
                    "Thumbnail: generated \(jpegData.count)-byte JPEG for \(filename)."
                )
                return jpegData
            } catch {
                AppLog.info(
                    "Thumbnail: frame extraction at \(CMTimeGetSeconds(time))s failed for \(filename): \(error.localizedDescription)"
                )
            }
        }

        AppLog.error("Thumbnail: no usable frame found for \(filename).")
        return nil
    }

    private static func generateCGImage(
        from fileURL: URL,
        at time: CMTime
    ) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize

        return try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImagesAsynchronously(
                forTimes: [NSValue(time: time)]
            ) { _, image, _, result, error in
                switch result {
                case .succeeded:
                    if let image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(
                            throwing: ThumbnailGeneratorError.missingImage
                        )
                    }
                case .failed:
                    continuation.resume(
                        throwing: error ?? ThumbnailGeneratorError.generationFailed
                    )
                case .cancelled:
                    continuation.resume(
                        throwing: ThumbnailGeneratorError.generationCancelled
                    )
                @unknown default:
                    continuation.resume(
                        throwing: ThumbnailGeneratorError.generationFailed
                    )
                }
            }
        }
    }

    private static func encodeJPEG(image: CGImage) -> Data? {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        else {
            return nil
        }

        let properties =
            [
                kCGImageDestinationLossyCompressionQuality: compressionQuality
            ] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }
}

private enum ThumbnailGeneratorError: LocalizedError {
    case missingImage
    case generationCancelled
    case generationFailed

    var errorDescription: String? {
        switch self {
        case .missingImage:
            return "AVAssetImageGenerator returned success without an image."
        case .generationCancelled:
            return "AVAssetImageGenerator cancelled the thumbnail request."
        case .generationFailed:
            return "AVAssetImageGenerator could not extract a thumbnail."
        }
    }
}
