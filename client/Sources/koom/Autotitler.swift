import Foundation

/// The combined output of the local post-processing pipeline:
/// a short LLM-generated title and the full word-level transcript.
/// Both are optional — any stage can fail independently.
struct AutotitleResult: Sendable {
    let title: String?
    let transcript: TimedTranscript?
}

/// Coordinates the best-effort local processing pipeline:
///
///     mp4 → AudioExtractor → Transcriber → bundled llama.cpp → title
///
/// Transcription is independent from local title generation. If the
/// selected title model is not ready when transcription finishes, the
/// recording keeps its transcript and simply skips its generated title.
/// There is deliberately no pending-title queue or later retry state.
struct Autotitler: Sendable {
    let configuration: AutotitleConfiguration
    let transcriber: Transcriber
    let localTitleModelManager: LocalTitleModelManager

    var whisperModelName: String { configuration.whisperModelName }

    @MainActor
    init(
        configuration: AutotitleConfiguration,
        localTitleModelManager: LocalTitleModelManager
    ) {
        self.configuration = configuration
        self.transcriber = Transcriber(
            modelName: configuration.whisperModelName
        )
        self.localTitleModelManager = localTitleModelManager
    }

    @MainActor
    static func shippedDefault(
        localTitleModelManager: LocalTitleModelManager
    ) -> Autotitler? {
        let configuration = AutotitleConfiguration.shippedDefault
        guard configuration.isEnabled else {
            AppLog.info(
                "Autotitle: disabled in the shipped client configuration."
            )
            return nil
        }
        return Autotitler(
            configuration: configuration,
            localTitleModelManager: localTitleModelManager
        )
    }

    /// Runs the full pipeline on a finalized recording. Never throws.
    func process(
        for fileURL: URL,
        onProgress: @Sendable (PostUploadStage) async -> Void
    ) async -> AutotitleResult {
        let filename = fileURL.lastPathComponent

        await onProgress(.extractingAudio)
        AppLog.info("Autotitle: extracting audio from \(filename).")
        guard
            let pcm = await AudioExtractor.extractMono16kFloatPCM(
                from: fileURL
            ),
            !pcm.isEmpty
        else {
            AppLog.info(
                "Autotitle: no usable microphone audio in \(filename); skipping."
            )
            return AutotitleResult(title: nil, transcript: nil)
        }
        AppLog.info(
            "Autotitle: extracted ~\(pcm.count / 16_000)s of audio from \(filename)."
        )

        let transcript: TimedTranscript
        do {
            await onProgress(.transcribing(modelName: whisperModelName))
            AppLog.info("Autotitle: transcribing \(filename).")
            transcript = try await transcriber.transcribe(audioArray: pcm)
        } catch {
            AppLog.error(
                "Autotitle: transcription failed for \(filename): \(error.localizedDescription)"
            )
            return AutotitleResult(title: nil, transcript: nil)
        }

        let plainText = transcript.plainText
        guard !plainText.isEmpty else {
            AppLog.info(
                "Autotitle: transcript for \(filename) was empty; skipping."
            )
            return AutotitleResult(title: nil, transcript: nil)
        }
        AppLog.info(
            "Autotitle: transcript for \(filename) has \(plainText.count) chars."
        )

        guard
            let model = await localTitleModelManager.selectedModel,
            await localTitleModelManager.state(for: model) == .ready
        else {
            AppLog.info(
                "Autotitle: local title model is not ready for \(filename); preserving the transcript and skipping this recording's title."
            )
            return AutotitleResult(title: nil, transcript: transcript)
        }

        do {
            await onProgress(
                .generatingLocalTitle(modelName: model.displayName)
            )
            AppLog.info(
                "Autotitle: generating a title for \(filename) with \(model.displayName)."
            )
            guard
                let title =
                    try await localTitleModelManager
                    .generateTitleIfReady(for: plainText)
            else {
                AppLog.info(
                    "Autotitle: the selected model stopped being ready; skipping the title for \(filename)."
                )
                return AutotitleResult(title: nil, transcript: transcript)
            }
            AppLog.info(
                "Autotitle: generated title for \(filename): \(title)"
            )
            return AutotitleResult(title: title, transcript: transcript)
        } catch {
            AppLog.error(
                "Autotitle: local title generation failed for \(filename): \(error.localizedDescription)"
            )
            return AutotitleResult(title: nil, transcript: transcript)
        }
    }
}
