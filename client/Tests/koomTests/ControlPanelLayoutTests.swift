import AppKit
import XCTest

@testable import koom

final class ControlPanelLayoutTests: XCTestCase {
    func testResizeKeepsPaddedTopRightCornerAnchored() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_920, height: 1_050)
        let currentFrame = NSRect(x: 1_466, y: 626, width: 430, height: 400)

        let resizedFrame = ControlPanelLayout.resizedFrame(
            currentFrame: currentFrame,
            preferredContentSize: NSSize(width: 860, height: 900),
            visibleFrame: visibleFrame,
            edgePadding: 24,
            anchorAtTopRight: false
        )

        XCTAssertEqual(resizedFrame.size, NSSize(width: 860, height: 900))
        XCTAssertEqual(resizedFrame.maxX, visibleFrame.maxX - 24)
        XCTAssertEqual(resizedFrame.maxY, visibleFrame.maxY - 24)
    }

    func testResizePreservesMovedPanelsTopLeftCorner() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_920, height: 1_050)
        let currentFrame = NSRect(x: 300, y: 400, width: 430, height: 400)

        let resizedFrame = ControlPanelLayout.resizedFrame(
            currentFrame: currentFrame,
            preferredContentSize: NSSize(width: 860, height: 700),
            visibleFrame: visibleFrame,
            edgePadding: 24,
            anchorAtTopRight: false
        )

        XCTAssertEqual(resizedFrame.minX, currentFrame.minX)
        XCTAssertEqual(resizedFrame.maxY, currentFrame.maxY)
    }

    func testInitialPlacementUsesActualPreferredSize() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 3_008, height: 1_662)
        let zeroSizedFrame = NSRect(x: 2_984, y: 1_638, width: 0, height: 0)

        let resizedFrame = ControlPanelLayout.resizedFrame(
            currentFrame: zeroSizedFrame,
            preferredContentSize: NSSize(width: 430, height: 900),
            visibleFrame: visibleFrame,
            edgePadding: 24,
            anchorAtTopRight: true
        )

        XCTAssertEqual(resizedFrame.size, NSSize(width: 430, height: 900))
        XCTAssertEqual(resizedFrame.maxX, visibleFrame.maxX - 24)
        XCTAssertEqual(resizedFrame.maxY, visibleFrame.maxY - 24)
    }
}
