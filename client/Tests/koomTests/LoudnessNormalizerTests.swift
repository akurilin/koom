import XCTest

@testable import koom

final class LoudnessNormalizerTests: XCTestCase {
    func testParsesMeasurementFromRealisticStderr() {
        let stderr = """
            Output #0, null, to 'pipe:':
              Metadata:
                encoder         : Lavf61.7.100
            [Parsed_loudnorm_0 @ 0x600002bb8160]
            {
            \t"input_i" : "-31.27",
            \t"input_tp" : "-12.35",
            \t"input_lra" : "6.50",
            \t"input_thresh" : "-41.53",
            \t"output_i" : "-16.02",
            \t"output_tp" : "-1.50",
            \t"output_lra" : "5.10",
            \t"output_thresh" : "-26.27",
            \t"normalization_type" : "dynamic",
            \t"target_offset" : "0.02"
            }
            """

        let measurement = LoudnessNormalizer.parseLoudnessMeasurement(
            fromFFmpegStderr: stderr
        )

        XCTAssertEqual(
            measurement,
            LoudnessNormalizer.LoudnessMeasurement(
                integratedLoudness: -31.27,
                truePeak: -12.35,
                loudnessRange: 6.50
            )
        )
    }

    func testParsesSilentAudioAsNonFiniteLoudness() {
        let stderr = """
            [Parsed_loudnorm_0 @ 0x600002bb8160]
            {
            \t"input_i" : "-inf",
            \t"input_tp" : "-inf",
            \t"input_lra" : "0.00",
            \t"input_thresh" : "-inf",
            \t"output_i" : "-16.00",
            \t"output_tp" : "-1.50",
            \t"output_lra" : "0.00",
            \t"output_thresh" : "-26.00",
            \t"normalization_type" : "dynamic",
            \t"target_offset" : "0.00"
            }
            """

        let measurement = LoudnessNormalizer.parseLoudnessMeasurement(
            fromFFmpegStderr: stderr
        )

        XCTAssertNotNil(measurement)
        XCTAssertFalse(measurement!.integratedLoudness.isFinite)
    }

    func testReturnsNilWhenNoJSONPresent() {
        XCTAssertNil(
            LoudnessNormalizer.parseLoudnessMeasurement(
                fromFFmpegStderr: "Error opening input file missing.mp4."
            )
        )
    }
}
