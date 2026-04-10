import Foundation

/// Coordinates the local auto-titling pipeline that runs after each
/// recording finishes:
///
///     mp4 → AudioExtractor → Transcriber → OllamaRuntime → title
///
/// Every stage is best-effort. Any failure (no audio track, Whisper
/// model still downloading, Ollama not running, empty transcript,
/// LLM refused to answer) logs and returns `nil`, leaving the
/// recording's `title` column untouched in the database. The user
/// can always rename a recording later in the admin UI, so failures
/// remain best-effort and non-blocking. The client does, however,
/// surface coarse progress messages so the user can see when the
/// post-upload title pipeline is preparing Ollama, transcribing
/// narration, or asking the local model for a summary/title.
///
/// One `Autotitler` is safe to share across recordings and across
/// concurrent tasks because its two stateful collaborators already
/// serialize their own work (`Transcriber` as an actor and
/// `OllamaRuntime` as an actor).
struct Autotitler: Sendable {
    let configuration: AutotitleConfiguration
    let transcriber: Transcriber
    let ollamaRuntime: OllamaRuntime

    var whisperModelName: String { configuration.whisperModelName }
    var ollamaModelName: String { configuration.ollamaModelName }

    init(configuration: AutotitleConfiguration) {
        self.configuration = configuration
        self.transcriber = Transcriber(modelName: configuration.whisperModelName)
        self.ollamaRuntime = OllamaRuntime(
            client: OllamaClient(
                baseURL: configuration.ollamaBaseURL,
                model: configuration.ollamaModelName
            )
        )
    }

    static func shippedDefault() -> Autotitler? {
        let configuration = AutotitleConfiguration.shippedDefault
        guard configuration.isEnabled else {
            AppLog.info("Autotitle: disabled in the shipped client configuration.")
            return nil
        }
        return Autotitler(configuration: configuration)
    }

    func preflightForLaunch() async -> String? {
        await ollamaRuntime.prepareForLaunch()
    }

    /// Runs the full pipeline on the finalized recording at
    /// `fileURL` and returns a short title, or `nil` if any stage
    /// failed or produced nothing usable. Never throws.
    func generateTitle(
        for fileURL: URL,
        onProgress: @Sendable (PostUploadStage) async -> Void
    ) async -> String? {
        let filename = fileURL.lastPathComponent

        await onProgress(.preparingOllama(modelName: ollamaModelName))
        do {
            try await ollamaRuntime.ensureReady()
        } catch {
            AppLog.error("Autotitle: Ollama is not ready for \(filename): \(error.localizedDescription)")
            return nil
        }

        // Stage 1: pull mic audio into 16 kHz mono float PCM.
        await onProgress(.extractingAudio)
        AppLog.info("Autotitle: extracting audio from \(filename).")
        guard let pcm = await AudioExtractor.extractMono16kFloatPCM(from: fileURL) else {
            AppLog.info("Autotitle: no usable audio track in \(filename); skipping.")
            return nil
        }
        guard !pcm.isEmpty else {
            AppLog.info("Autotitle: audio track in \(filename) was empty; skipping.")
            return nil
        }
        let approximateSeconds = pcm.count / 16_000
        AppLog.info("Autotitle: extracted ~\(approximateSeconds)s of audio from \(filename).")

        // Stage 2: Whisper transcription.
        let transcript: String
        do {
            await onProgress(.transcribing(modelName: whisperModelName))
            AppLog.info("Autotitle: transcribing \(filename).")
            transcript = try await transcriber.transcribe(audioArray: pcm)
        } catch {
            AppLog.error("Autotitle: transcription failed for \(filename): \(error.localizedDescription)")
            return nil
        }

        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            AppLog.info("Autotitle: transcript for \(filename) was empty; skipping.")
            return nil
        }
        AppLog.info("Autotitle: transcript for \(filename) has \(trimmedTranscript.count) chars.")

        // Stage 3: Ollama summarization.
        do {
            await onProgress(.generatingTitle(modelName: ollamaModelName))
            AppLog.info("Autotitle: summarizing transcript for \(filename) via Ollama.")
            let title = try await ollamaRuntime.generateTitle(
                from: trimmedTranscript
            )
            AppLog.info("Autotitle: generated title for \(filename): \(title)")
            return title
        } catch {
            AppLog.error("Autotitle: Ollama summarization failed for \(filename): \(error.localizedDescription)")
            return nil
        }
    }
}
