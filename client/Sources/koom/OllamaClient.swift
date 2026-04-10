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
        let keepAlive: String?
        let options: Options

        enum CodingKeys: String, CodingKey {
            case model
            case prompt
            case stream
            case think
            case keepAlive = "keep_alive"
            case options
        }

        struct Options: Encodable {
            let temperature: Double
            /// Swift-side name stays lowerCamelCase; serialized to
            /// Ollama's `num_predict` key via `CodingKeys` below.
            let numPredict: Int

            enum CodingKeys: String, CodingKey {
                case temperature
                case numPredict = "num_predict"
            }
        }
    }

    private struct GenerateResponse: Decodable {
        let response: String
        // Decoded defensively so we can surface it in logs when
        // `response` comes back empty — that turns "summarization
        // failed" into a useful diagnostic instead of a dead end.
        let thinking: String?
    }

    private struct TagsResponse: Decodable {
        let models: [ModelSummary]?
    }

    private struct ModelSummary: Decodable {
        let name: String
    }

    var canAutoStartLocalService: Bool {
        baseURL.scheme?.lowercased() == "http" && isLoopbackHost
    }

    var serveHostBinding: String {
        guard let host = baseURL.host else {
            return "localhost:11434"
        }
        guard let port = baseURL.port else {
            return host
        }
        return "\(host):\(port)"
    }

    /// Asks the configured Ollama model for a short title that
    /// summarizes the given transcript. Trims quotes/whitespace and
    /// clamps to 10 words on the client side so the rest of the app
    /// can treat the returned value as a clean display name.
    func generateTitle(from transcript: String) async throws -> String {
        let prompt = Self.buildTitlePrompt(transcript: transcript)
        let decoded = try await performGenerateRequest(
            prompt: prompt,
            temperature: 0.2,
            numPredict: 120,
            keepAlive: nil
        )

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

    func isReachable() async -> Bool {
        var request = URLRequest(url: tagsURL)
        request.timeoutInterval = 2

        do {
            let (_, http) = try await httpData(for: request)
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }

    func isModelPresent() async throws -> Bool {
        var request = URLRequest(url: tagsURL)
        request.timeoutInterval = 3

        let (data, _) = try await httpData(for: request)
        let decoded: TagsResponse
        do {
            decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
        } catch {
            throw OllamaError.invalidResponse
        }

        let availableModels = Set(decoded.models?.map(\.name) ?? [])
        if availableModels.contains(model) || availableModels.contains("\(model):latest") {
            return true
        }

        if model.hasSuffix(":latest") {
            let withoutLatest = String(model.dropLast(":latest".count))
            return availableModels.contains(withoutLatest)
        }

        return false
    }

    func warmModel() async throws {
        let decoded = try await performGenerateRequest(
            prompt: "Reply with exactly OK",
            temperature: 0,
            numPredict: 8,
            keepAlive: "15m"
        )
        guard !decoded.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OllamaError.emptyCompletion
        }
    }

    private var tagsURL: URL {
        baseURL.appendingPathComponent("api/tags")
    }

    private var generateURL: URL {
        baseURL.appendingPathComponent("api/generate")
    }

    private var isLoopbackHost: Bool {
        guard let host = baseURL.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1"
    }

    private func performGenerateRequest(
        prompt: String,
        temperature: Double,
        numPredict: Int,
        keepAlive: String?
    ) async throws -> GenerateResponse {
        let body = GenerateRequest(
            model: model,
            prompt: prompt,
            stream: false,
            think: false,
            keepAlive: keepAlive,
            options: .init(
                temperature: temperature,
                numPredict: numPredict
            )
        )

        var request = URLRequest(url: generateURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, _) = try await httpData(for: request)
        do {
            return try JSONDecoder().decode(GenerateResponse.self, from: data)
        } catch {
            throw OllamaError.invalidResponse
        }
    }

    private func httpData(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
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

        return (data, http)
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
