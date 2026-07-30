import Foundation

struct LocalTitleClient: Sendable {
    enum ClientError: LocalizedError {
        case badStatus(code: Int, body: String)
        case invalidResponse
        case emptyCompletion
        case network(String)

        var errorDescription: String? {
            switch self {
            case .badStatus(let code, let body):
                return
                    "Local title server returned HTTP \(code).\(body.isEmpty ? "" : " \(body)")"
            case .invalidResponse:
                return "Local title server returned an unexpected response."
            case .emptyCompletion:
                return "Local title server returned an empty title."
            case .network(let message):
                return "Local title server request failed: \(message)"
            }
        }
    }

    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        struct ChatTemplateOptions: Encodable {
            let enableThinking = false

            enum CodingKeys: String, CodingKey {
                case enableThinking = "enable_thinking"
            }
        }

        let model: String
        let messages: [Message]
        let temperature = 0.0
        let maxTokens = 30
        let stream = false
        let reasoningEffort = "none"
        let chatTemplateKwargs = ChatTemplateOptions()

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case temperature
            case maxTokens = "max_tokens"
            case stream
            case reasoningEffort = "reasoning_effort"
            case chatTemplateKwargs = "chat_template_kwargs"
        }
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let message: Message
        }

        let choices: [Choice]
    }

    let baseURL: URL
    let apiKey: String
    let modelID: String

    func generateTitle(transcript: String) async throws -> String {
        // The title model uses a deliberately small 2K context. English
        // transcripts are capped before encoding so long recordings
        // still leave room for the prompt and completion.
        let titleInput = String(transcript.prefix(6_000))
        let prompt = """
            Generate an English title for a screen recording transcript.
            Return only the title: 4–10 words, sentence case, no quotes, no "Title:" prefix, and no trailing period.

            Examples:
            Transcript: I'm going to test the microphone and make sure the audio normalization is working correctly.
            Title: Testing microphone audio normalization

            Transcript: Now I will update the database migration so the access grants work for the new table.
            Title: Fixing database migration access grants
            """
        let payload = ChatRequest(
            model: modelID,
            messages: [
                .init(role: "system", content: prompt),
                .init(role: "user", content: titleInput),
            ]
        )
        var request = URLRequest(
            url: baseURL.appendingPathComponent("v1/chat/completions")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(apiKey)",
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try JSONEncoder().encode(payload)
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClientError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.badStatus(
                code: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        guard
            let content = try JSONDecoder().decode(ChatResponse.self, from: data)
                .choices.first?.message.content
        else {
            throw ClientError.invalidResponse
        }

        let title = Self.sanitizeTitle(content)
        guard !title.isEmpty else {
            throw ClientError.emptyCompletion
        }
        return title
    }

    static func sanitizeTitle(_ rawValue: String) -> String {
        var title = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if title.lowercased().hasPrefix("title:") {
            title.removeFirst("title:".count)
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let quoteCharacters = CharacterSet(
            charactersIn: "\"'“”‘’`"
        )
        title = title.trimmingCharacters(in: quoteCharacters)
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.trimmingCharacters(
            in: CharacterSet(charactersIn: ".!?;:,")
        )
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)

        let words = title.split(whereSeparator: \.isWhitespace)
        if words.count > 10 {
            title = words.prefix(10).joined(separator: " ")
        }
        return title
    }
}
