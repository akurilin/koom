import Foundation

/// Coordinates the local auto-titling pipeline that runs after each
/// recording finishes:
///
///     mp4 → AudioExtractor → Transcriber → OllamaClient → title
///
/// Every stage is best-effort. Any failure (no audio track, Whisper
/// model still downloading, Ollama not running, empty transcript,
/// LLM refused to answer) logs and returns `nil`, leaving the
/// recording's `title` column untouched in the database. The user
/// can always rename a recording later in the admin UI, so failures
/// remain best-effort and non-blocking. The client does, however,
/// surface coarse progress messages so the user can see when the
/// post-upload title pipeline is transcribing narration or asking
/// the local Ollama model for a summary/title.
///
/// One `Autotitler` is safe to share across recordings and across
/// concurrent tasks because the only stateful piece (the
/// `Transcriber` actor) already serializes access internally.
struct Autotitler: Sendable {
    let whisperModelName: String
    let ollamaModelName: String
    let transcriber: Transcriber
    let ollamaClient: OllamaClient

    /// Reads `KOOM_AUTOTITLE_ENABLED`, `KOOM_WHISPER_MODEL`,
    /// `KOOM_OLLAMA_URL`, and `KOOM_OLLAMA_MODEL` from the process
    /// environment and returns a ready-to-use `Autotitler`, or
    /// `nil` if the feature is explicitly disabled or the Ollama
    /// URL is malformed (both are operator-configurable knobs, so
    /// a bad value is a quiet no-op rather than a crash).
    static func makeFromEnvironment() -> Autotitler? {
        let env = ProcessInfo.processInfo.environment

        let enabledRaw = env["KOOM_AUTOTITLE_ENABLED"] ?? "true"
        let enabled = !["false", "0", "no", "off"].contains(enabledRaw.lowercased())
        guard enabled else {
            AppLog.info("Autotitle: disabled via KOOM_AUTOTITLE_ENABLED=\(enabledRaw).")
            return nil
        }

        let whisperModel = env["KOOM_WHISPER_MODEL"] ?? "openai_whisper-small.en"
        let ollamaURLString = env["KOOM_OLLAMA_URL"] ?? "http://localhost:11434"
        guard let ollamaURL = URL(string: ollamaURLString) else {
            AppLog.error("Autotitle: KOOM_OLLAMA_URL is not a valid URL: \(ollamaURLString). Disabling auto-titling.")
            return nil
        }
        let ollamaModel = env["KOOM_OLLAMA_MODEL"] ?? "gemma4:e4b"

        AppLog.info(
            "Autotitle: configured whisper=\(whisperModel) ollama=\(ollamaURLString) model=\(ollamaModel)"
        )

        return Autotitler(
            whisperModelName: whisperModel,
            ollamaModelName: ollamaModel,
            transcriber: Transcriber(modelName: whisperModel),
            ollamaClient: OllamaClient(baseURL: ollamaURL, model: ollamaModel)
        )
    }

    /// Runs the full pipeline on the finalized recording at
    /// `fileURL` and returns a short title, or `nil` if any stage
    /// failed or produced nothing usable. Never throws.
    func generateTitle(
        for fileURL: URL,
        onProgress: @Sendable (AutoTitleStage) async -> Void
    ) async -> String? {
        let filename = fileURL.lastPathComponent

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
            let title = try await ollamaClient.generateTitle(from: trimmedTranscript)
            AppLog.info("Autotitle: generated title for \(filename): \(title)")
            return title
        } catch {
            AppLog.error("Autotitle: Ollama summarization failed for \(filename): \(error.localizedDescription)")
            return nil
        }
    }
}
