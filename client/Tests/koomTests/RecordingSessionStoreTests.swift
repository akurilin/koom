import Foundation
import XCTest

@testable import koom

final class RecordingSessionStoreTests: XCTestCase {
    func testLegacyManifestWithoutCaptureConfigurationStillDecodes() throws {
        let data = Data(
            """
            {
              "manifestVersion": 2,
              "sessionID": "legacy-session",
              "createdAt": 0,
              "updatedAt": 0,
              "state": "recording",
              "finalFilename": "legacy.mp4",
              "display": {
                "id": 1,
                "name": "Display",
                "width": 3008,
                "height": 1692
              },
              "segments": []
            }
            """.utf8
        )

        let session = try JSONDecoder().decode(
            RecordingSessionStore.RecordingSession.self,
            from: data
        )

        XCTAssertNil(session.captureConfiguration)
    }
}
