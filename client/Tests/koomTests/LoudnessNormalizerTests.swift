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

    func testNormalizationGainUsesTargetBoostWhenPeakHeadroomAllows() {
        let gain = LoudnessNormalizer.normalizationGain(
            for: LoudnessNormalizer.LoudnessMeasurement(
                integratedLoudness: -22.0,
                truePeak: -12.0,
                loudnessRange: 4.0
            )
        )

        XCTAssertEqual(gain, 6.0)
    }

    func testNormalizationGainCapsBoostToPeakHeadroom() {
        let gain = LoudnessNormalizer.normalizationGain(
            for: LoudnessNormalizer.LoudnessMeasurement(
                integratedLoudness: -31.27,
                truePeak: -12.35,
                loudnessRange: 6.5
            )
        )

        XCTAssertEqual(gain, 10.85, accuracy: 0.001)
    }

    func testNormalizationGainDoesNotAttenuateQuietClipToSatisfyPeakCeiling() {
        let gain = LoudnessNormalizer.normalizationGain(
            for: LoudnessNormalizer.LoudnessMeasurement(
                integratedLoudness: -30.0,
                truePeak: -1.0,
                loudnessRange: 8.0
            )
        )

        XCTAssertEqual(gain, 0.0)
    }

    func testNormalizationGainAllowsStaticReductionForLoudClip() {
        let gain = LoudnessNormalizer.normalizationGain(
            for: LoudnessNormalizer.LoudnessMeasurement(
                integratedLoudness: -12.0,
                truePeak: -1.0,
                loudnessRange: 3.0
            )
        )

        XCTAssertEqual(gain, -4.0)
    }

    func testApplyFilterUsesOnlyStaticVolume() {
        XCTAssertEqual(
            LoudnessNormalizer.applyFilter(gain: 6.25),
            "volume=6.25dB"
        )
    }
}
