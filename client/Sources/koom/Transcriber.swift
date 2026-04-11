import Foundation
@preconcurrency import WhisperKit

/// Actor-isolated wrapper around a single long-lived `WhisperKit`
/// instance.
///
/// WhisperKit's init loads the CoreML model into memory (and, on the
/// very first run for a given model, downloads it from
/// `argmaxinc/whisperkit-coreml` on HuggingFace into the default
/// Hub cache at `~/.cache/huggingface/hub/`). Both operations are
/// expensive enough that we absolutely do not want to redo them
/// once per recording — hence the lazy `ensureKit()` that memoizes
/// the instance for the lifetime of the process.
///
/// The actor serializes access to that single instance because
/// `WhisperKit` is a reference-typed class whose docs explicitly
/// warn against sharing one instance across concurrent tasks
/// without external synchronization.
actor Transcriber {
    private let modelName: String
    private var kit: WhisperKit?

    init(modelName: String) {
        self.modelName = modelName
    }

    /// Transcribes a 16 kHz mono float PCM buffer (the format
    /// `AudioExtractor` returns) into a `TimedTranscript` with
    /// word-level timestamps. Each word carries the start/end time
    /// (in seconds) so the web player can seek to the exact moment
    /// a word was spoken.
    ///
    /// Throws any error WhisperKit surfaces; the caller (Autotitler)
    /// converts those into "skip this recording" outcomes.
    func transcribe(audioArray: [Float]) async throws -> TimedTranscript {
        let kit = try await ensureKit()
        let options = DecodingOptions(wordTimestamps: true)
        let results = try await kit.transcribe(
            audioArray: audioArray,
            decodeOptions: options
        )

        let segments: [TimedTranscript.Segment] =
            results
            .flatMap(\.segments)
            .map { seg in
                let words = (seg.words ?? []).map { w in
                    TimedTranscript.Word(
                        word: w.word,
                        start: w.start,
                        end: w.end
                    )
                }
                return TimedTranscript.Segment(
                    start: seg.start,
                    end: seg.end,
                    text: seg.text.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
                    words: words
                )
            }

        return TimedTranscript(segments: segments)
    }

    private func ensureKit() async throws -> WhisperKit {
        if let kit {
            return kit
        }
        AppLog.info("Transcriber: loading WhisperKit model '\(modelName)' (first call will download if the cache is cold).")
        let config = WhisperKitConfig(model: modelName)
        let created = try await WhisperKit(config)
        self.kit = created
        AppLog.info("Transcriber: WhisperKit ready.")
        return created
    }
}
