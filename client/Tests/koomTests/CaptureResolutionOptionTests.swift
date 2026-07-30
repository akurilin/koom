import XCTest

@testable import koom

final class CaptureResolutionOptionTests: XCTestCase {
    func testHighDensityLandscapeDisplayResolvesStandardOutputSizes() {
        let sourcePointWidth = 3_008
        let sourcePointHeight = 1_692
        let pointPixelScale = 2.0

        XCTAssertEqual(
            CaptureResolutionOption.hd720.captureDimensions(
                displayPointWidth: sourcePointWidth,
                displayPointHeight: sourcePointHeight,
                pointPixelScale: pointPixelScale
            ),
            CaptureDimensions(width: 1_280, height: 720)
        )
        XCTAssertEqual(
            CaptureResolutionOption.fullHD1080.captureDimensions(
                displayPointWidth: sourcePointWidth,
                displayPointHeight: sourcePointHeight,
                pointPixelScale: pointPixelScale
            ),
            CaptureDimensions(width: 1_920, height: 1_080)
        )
        XCTAssertEqual(
            CaptureResolutionOption.ultraHD4K.captureDimensions(
                displayPointWidth: sourcePointWidth,
                displayPointHeight: sourcePointHeight,
                pointPixelScale: pointPixelScale
            ),
            CaptureDimensions(width: 3_840, height: 2_160)
        )
    }

    func testPortraitDisplaySwapsResolutionBounds() {
        XCTAssertEqual(
            CaptureResolutionOption.ultraHD4K.captureDimensions(
                displayPointWidth: 1_080,
                displayPointHeight: 1_920,
                pointPixelScale: 2
            ),
            CaptureDimensions(width: 2_160, height: 3_840)
        )
    }

    func testResolutionDoesNotUpscaleLowDensitySource() {
        XCTAssertEqual(
            CaptureResolutionOption.ultraHD4K.captureDimensions(
                displayPointWidth: 1_366,
                displayPointHeight: 768,
                pointPixelScale: 1
            ),
            CaptureDimensions(width: 1_366, height: 768)
        )
    }

    func testNonstandardAspectRatioIsPreservedWithinEvenPixelBounds() {
        let dimensions = CaptureResolutionOption.fullHD1080.captureDimensions(
            displayPointWidth: 1_728,
            displayPointHeight: 1_117,
            pointPixelScale: 2
        )

        XCTAssertLessThanOrEqual(dimensions.width, 1_920)
        XCTAssertLessThanOrEqual(dimensions.height, 1_080)
        XCTAssertEqual(dimensions.width % 2, 0)
        XCTAssertEqual(dimensions.height % 2, 0)

        let sourceAspectRatio = Double(1_728 * 2) / Double(1_117 * 2)
        let outputAspectRatio = Double(dimensions.width) / Double(dimensions.height)
        XCTAssertEqual(outputAspectRatio, sourceAspectRatio, accuracy: 0.001)
    }
}
