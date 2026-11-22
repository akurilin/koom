import XCTest

@testable import koom

final class AudioCleanupTests: XCTestCase {
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

        XCTAssertEqual(
            AudioCleanup.parseLoudnessMeasurement(fromFFmpegStderr: stderr),
            AudioCleanup.LoudnessMeasurement(
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

        let measurement = AudioCleanup.parseLoudnessMeasurement(
            fromFFmpegStderr: stderr
        )

        XCTAssertNotNil(measurement)
        XCTAssertFalse(measurement!.integratedLoudness.isFinite)
    }

    func testReturnsNilWhenNoJSONPresent() {
        XCTAssertNil(
            AudioCleanup.parseLoudnessMeasurement(
                fromFFmpegStderr: "Error opening input file missing.mp4."
            )
        )
    }

    /// End to end through ffmpeg: a quiet recording with one loud click,
    /// whose audio track starts 0.2 s after the video (as real recordings
    /// often do). The cleaned file must keep the click at the same moment
    /// on the video timeline and reach the loudness target, which the
    /// click's peak would block without the limiter.
    func testCleaningSavesStagesAndKeepsAudioInSync() async throws {
        guard let ffmpegURL = RecordingOptimizer.findFFmpegExecutable() else {
            throw XCTSkip("ffmpeg is not installed.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("koom-audio-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let recordingURL = directory.appendingPathComponent("recording.mp4")

        // Tone at about -23 LUFS with a 1 ms full-scale click at audio
        // time 1.0 s (1.2 s on the video timeline). The click's peak leaves
        // no headroom for a plain fixed gain, but carries too little energy
        // to move the loudness, like a mouth click or a desk tap.
        _ = try await ProcessRunner.run(
            ffmpegURL,
            arguments: [
                "-nostdin", "-loglevel", "error",
                "-f", "lavfi", "-i", "color=size=64x64:rate=30:duration=3",
                "-itsoffset", "0.2",
                "-f", "lavfi", "-i",
                "aevalsrc=0.1*sin(2*PI*440*t)+between(t\\,1\\,1.001)*0.99:s=48000:d=2.5",
                "-c:v", "libx264", "-c:a", "aac", "-b:a", "192k",
                recordingURL.path,
            ]
        )

        // Use a known level change to distinguish the two saved inputs.
        let helper = directory.appendingPathComponent("test-denoiser.sh")
        try """
        exec "$KOOM_TEST_FFMPEG" -nostdin -v error -i "$1" -af volume=-3dB -c:a pcm_f32le "$2"
        """.write(to: helper, atomically: true, encoding: .utf8)
        let noiseRemoval = NoiseRemovalPlan.helper(
            NoiseRemovalHelperRuntime(
                displayName: "Test denoiser",
                pythonURL: URL(fileURLWithPath: "/bin/sh"),
                scriptURL: helper,
                workingDirectoryURL: directory,
                environment: ["KOOM_TEST_FFMPEG": ffmpegURL.path]
            )
        )
        let replaced = await AudioCleanup.cleanRecording(at: recordingURL, noiseRemoval: noiseRemoval)
        XCTAssertTrue(replaced)

        let stages = directory.appendingPathComponent("recording-audio", isDirectory: true)
        let extracted = try await AudioCleanup.measureLoudness(
            of: stages.appendingPathComponent("01-extracted.wav"),
            ffmpegURL: ffmpegURL
        )
        let denoised = try await AudioCleanup.measureLoudness(
            of: stages.appendingPathComponent("02-denoised.wav"),
            ffmpegURL: ffmpegURL
        )
        let leveled = try await AudioCleanup.measureLoudness(
            of: stages.appendingPathComponent("03-leveled.wav"),
            ffmpegURL: ffmpegURL
        )
        XCTAssertEqual(extracted.integratedLoudness - denoised.integratedLoudness, 3, accuracy: 0.15)
        XCTAssertGreaterThan(leveled.integratedLoudness - denoised.integratedLoudness, 5)

        let loudness = try await AudioCleanup.measureLoudness(
            of: recordingURL,
            ffmpegURL: ffmpegURL
        )
        XCTAssertEqual(loudness.integratedLoudness, leveled.integratedLoudness, accuracy: 0.3)
        XCTAssertEqual(
            loudness.integratedLoudness,
            AudioCleanup.targetIntegratedLoudness,
            accuracy: 0.5
        )
        XCTAssertLessThanOrEqual(loudness.truePeak, -1.0)

        // Decode on the video timeline and find the click.
        let rawURL = directory.appendingPathComponent("decoded.f32")
        _ = try await ProcessRunner.run(
            ffmpegURL,
            arguments: [
                "-nostdin", "-loglevel", "error",
                "-i", recordingURL.path,
                "-map", "0:a:0",
                "-af", "aresample=async=1:first_pts=0",
                "-ac", "1", "-ar", "48000", "-f", "f32le",
                rawURL.path,
            ]
        )
        let samples = try Data(contentsOf: rawURL).withUnsafeBytes {
            Array($0.bindMemory(to: Float.self))
        }
        let clickIndex = samples.indices.max {
            abs(samples[$0]) < abs(samples[$1])
        }!
        XCTAssertEqual(Double(clickIndex) / 48_000, 1.2, accuracy: 0.01)

        // Rerun from the extracted WAV and verify the original video stays intact.
        let originalVideo = try Data(contentsOf: recordingURL)
        let rerun = try await AudioCleanup.reprocessRecording(at: recordingURL, noiseRemoval: noiseRemoval)
        let rerunStages = rerun.deletingPathExtension().path + "-audio"
        let rerunDenoised = URL(fileURLWithPath: rerunStages).appendingPathComponent("02-denoised.wav")
        XCTAssertEqual(try Data(contentsOf: recordingURL), originalVideo)
        XCTAssertEqual(
            try Data(contentsOf: rerunDenoised),
            try Data(contentsOf: stages.appendingPathComponent("02-denoised.wav"))
        )
        let rerunLoudness = try await AudioCleanup.measureLoudness(of: rerun, ffmpegURL: ffmpegURL)
        XCTAssertEqual(rerunLoudness.integratedLoudness, loudness.integratedLoudness, accuracy: 0.05)
    }
}
