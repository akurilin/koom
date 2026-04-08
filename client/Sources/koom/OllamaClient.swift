import Foundation

/// Thin async wrapper around the Ollama local HTTP API.
///
/// koom only needs one Ollama endpoint for now: `/api/generate` to
/// turn a recording transcript into a short auto-generated title.
/// The server runs on `localhost:11434` by default and is reachable
/// from the non-sandboxed koom process without any entitlement
/// dance, so this client is deliberately small and dependency-free.
///
/// All calls are best-effort and throw `OllamaError` on any failure;
/// the caller (Autotitler) swallows those errors and leaves the
/// recording title `nil`.
struct OllamaClient: Sendable {
    let baseURL: URL
    let model: String

    enum OllamaError: LocalizedError {
        case badStatus(code: Int, body: String)
        case invalidResponse
        case emptyCompletion
        case network(Error)

        var errorDescription: String? {
            switch self {
            case .badStatus(let code, let body):
                return "Ollama returned HTTP \(code). \(body.isEmpty ? "" : "Body: \(body)")"
            case .invalidResponse:
                return "Ollama returned an unexpected response shape."
            case .emptyCompletion:
                return "Ollama completion was empty."
            case .network(let err):
                return "Ollama network error: \(err.localizedDescription)"
            }
        }
    }

    private struct GenerateRequest: Encodable {
        let model: String
        let prompt: String
        let stream: Bool
        // Top-level switch that disables chain-of-thought output on
        // reasoning-capable models in recent Ollama releases
        // (Gemma 3/4, DeepSeek-R1, etc). When `think` is left unset,
        // Ollama defaults to letting those models route their
        // content into a separate `thinking` field and return an
        // empty `response`, which is exactly the failure mode we
        // observed on gemma4:e4b in the first end-to-end run.
        // Non-reasoning models simply ignore this field.
        let think: Bool
        let options: Options

        struct Options: Encodable {
            let temperature: Double
            // Ollama uses snake_case for some option keys.
            let num_predict: Int
        }
    }

    private struct GenerateResponse: Decodable {
        let response: String
        // Decoded defensively so we can surface it in logs when
        // `response` comes back empty — that turns "summarization
        // failed" into a useful diagnostic instead of a dead end.
        let thinking: String?
    }

    /// Asks the configured Ollama model for a short title that
    /// summarizes the given transcript. Trims quotes/whitespace and
    /// clamps to 10 words on the client side so the rest of the app
    /// can treat the returned value as a clean display name.
    func generateTitle(from transcript: String) async throws -> String {
        let prompt = Self.buildTitlePrompt(transcript: transcript)
        let body = GenerateRequest(
            model: model,
            prompt: prompt,
            stream: false,
            think: false,
            // 120 tokens is plenty for a 4–10 word title plus any
            // preamble the model insists on emitting before we
            // sanitize it. 40 turned out to be too tight on
            // gemma4:e4b when a short transcript tempted the model
            // to narrate before writing the title.
            options: .init(temperature: 0.2, num_predict: 120)
        )

        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OllamaError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw OllamaError.badStatus(code: http.statusCode, body: bodyText)
        }

        let decoded: GenerateResponse
        do {
            decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
        } catch {
            throw OllamaError.invalidResponse
        }

        let cleaned = Self.sanitizeTitle(decoded.response)
        if cleaned.isEmpty {
            // Log the raw payload so we can see whether the model
            // returned nothing at all, returned its content in the
            // `thinking` channel, or returned something we
            // aggressively stripped in `sanitizeTitle`. Truncated to
            // keep the log lines manageable for long outputs.
            AppLog.error(
                "Ollama: empty title after sanitize. response=\(Self.truncateForLog(decoded.response)) thinking=\(Self.truncateForLog(decoded.thinking ?? "<none>"))"
            )
            throw OllamaError.emptyCompletion
        }
        return cleaned
    }

    private static func truncateForLog(_ s: String) -> String {
        let max = 300
        let collapsed = s.replacingOccurrences(of: "\n", with: "⏎")
        if collapsed.count <= max { return "\"\(collapsed)\"" }
        return "\"\(collapsed.prefix(max))…\" (truncated from \(collapsed.count) chars)"
    }

    // MARK: - Prompt and sanitization

    private static func buildTitlePrompt(transcript: String) -> String {
        // A tight instruction plus the transcript. We ask for plain
        // text because small local models sometimes wrap titles in
        // quotes, trailing punctuation, or a "Title:" prefix even
        // when told not to — sanitizeTitle handles the leftovers.
        """
        You write short titles for screen-recording transcripts.

        Write a title for the following transcript. Requirements:
        - Between 4 and 10 words.
        - Sentence case (capitalize the first word and proper nouns only).
        - No quotes, no trailing period, no "Title:" prefix.
        - Describe what the recording is about, not "A recording of...".
        - Output only the title, nothing else.

        Transcript:
        \(transcript)
        """
    }

    /// Strips common LLM output artifacts (surrounding quotes, a
    /// leading `Title:` prefix, trailing punctuation, stray
    /// newlines) and clamps to 10 words. Returns an empty string if
    /// nothing usable survives.
    static func sanitizeTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Drop a leading "Title:" / "title -" style prefix if the
        // model ignored our "no prefix" instruction.
        let lowered = title.lowercased()
        for prefix in ["title:", "title -", "title —", "title"] {
            if lowered.hasPrefix(prefix) {
                title = String(title.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        // Strip surrounding quotes (straight or smart).
        let quoteChars: Set<Character> = ["\"", "'", "“", "”", "‘", "’"]
        while let first = title.first, quoteChars.contains(first) {
            title.removeFirst()
        }
        while let last = title.last, quoteChars.contains(last) {
            title.removeLast()
        }

        // Take only the first line — models sometimes follow the
        // title with an explanation on the next line.
        if let newline = title.firstIndex(where: { $0.isNewline }) {
            title = String(title[..<newline])
        }

        // Drop trailing punctuation that would look odd in a title.
        while let last = title.last, ".!?;,".contains(last) {
            title.removeLast()
        }

        title = title.trimmingCharacters(in: .whitespacesAndNewlines)

        // Clamp to 10 words as a last-resort guard against models
        // that write an entire sentence instead of a title.
        let words = title.split(whereSeparator: { $0.isWhitespace })
        if words.count > 10 {
            title = words.prefix(10).joined(separator: " ")
        }

        return title
    }
}
