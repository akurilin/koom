import XCTest

@testable import koom

final class LocalTitleTests: XCTestCase {
    func testSanitizerNormalizesCommonModelFormattingAndClampsWordCount() {
        let raw =
            #"  Title: “Fixing the database migration access grants for every new public table today.”  "#

        XCTAssertEqual(
            LocalTitleClient.sanitizeTitle(raw),
            "Fixing the database migration access grants for every new public"
        )
    }

    func testCatalogRejectsDuplicateModelIDs() throws {
        let data = Data(
            """
            {
              "version": 1,
              "defaultModelID": "same",
              "models": [
                {
                  "id": "same",
                  "displayName": "One",
                  "summary": "One",
                  "parameterCount": "1B",
                  "quantization": "Q4_0",
                  "filename": "one.gguf",
                  "downloadURL": "https://example.com/one.gguf",
                  "byteCount": 1,
                  "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                  "license": "Apache-2.0",
                  "sourceURL": "https://example.com/one"
                },
                {
                  "id": "same",
                  "displayName": "Two",
                  "summary": "Two",
                  "parameterCount": "2B",
                  "quantization": "Q4_0",
                  "filename": "two.gguf",
                  "downloadURL": "https://example.com/two.gguf",
                  "byteCount": 2,
                  "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                  "license": "Apache-2.0",
                  "sourceURL": "https://example.com/two"
                }
              ]
            }
            """.utf8
        )

        XCTAssertThrowsError(try LocalTitleModelCatalog.decode(data)) { error in
            guard
                case LocalTitleModelCatalog.CatalogError.duplicateModelID(
                    "same"
                ) = error
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testShippedCatalogPassesRuntimeValidation() throws {
        let catalog = try LocalTitleModelCatalog.load()

        XCTAssertTrue(
            catalog.models.contains(where: {
                $0.id == catalog.defaultModelID
            })
        )
        XCTAssertTrue(
            catalog.models.allSatisfy {
                $0.downloadURL.scheme == "https"
                    && $0.byteCount > 0
                    && $0.sha256.count == 64
            }
        )
    }
}
