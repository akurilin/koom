@preconcurrency import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Best-effort local thumbnail generator for finalized recordings.
///
/// The JPEG serves the recordings grid and chat previews.
enum ThumbnailGenerator {
    private static let captureTimes: [CMTime] = [
        CMTime(seconds: 0.1, preferredTimescale: 600),
        .zero,
    ]
    private static let previewSize = CGSize(width: 1200, height: 675)
    private static let whatsappImageByteLimit = 600_000
    private static let compressionQualities = [0.8, 0.6, 0.4]

    static func generateJPEGData(from fileURL: URL) async -> Data? {
        let filename = fileURL.lastPathComponent

        for time in captureTimes {
            do {
                let image = try await generateCGImage(from: fileURL, at: time)
                guard let preview = makePreview(from: image),
                    let jpegData = encodePreview(preview)
                else {
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
        generator.maximumSize = previewSize

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

    private static func makePreview(from image: CGImage) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        if width == previewSize.width, height == previewSize.height {
            return image
        }

        guard
            let context = CGContext(
                data: nil,
                width: Int(previewSize.width),
                height: Int(previewSize.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else {
            return nil
        }

        // Fit the full frame so narrow and wide recordings meet the preview size.
        let scale = min(previewSize.width / width, previewSize.height / height)
        let fittedSize = CGSize(width: width * scale, height: height * scale)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: previewSize))
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(
                x: (previewSize.width - fittedSize.width) / 2,
                y: (previewSize.height - fittedSize.height) / 2,
                width: fittedSize.width,
                height: fittedSize.height
            ))
        return context.makeImage()
    }

    private static func encodePreview(_ image: CGImage) -> Data? {
        // Lower JPEG quality only if the preview exceeds WhatsApp's size limit.
        for quality in compressionQualities {
            if let data = encodeJPEG(image: image, quality: quality),
                data.count < whatsappImageByteLimit
            {
                return data
            }
        }
        return nil
    }

    private static func encodeJPEG(image: CGImage, quality: Double) -> Data? {
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
                kCGImageDestinationLossyCompressionQuality: quality
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
