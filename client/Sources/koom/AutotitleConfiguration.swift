import Foundation

struct AutotitleConfiguration: Sendable {
    let isEnabled: Bool
    let whisperModelName: String
    let ollamaBaseURL: URL
    let ollamaModelName: String

    static let shippedDefault = AutotitleConfiguration(
        isEnabled: true,
        whisperModelName: "openai_whisper-small.en",
        ollamaBaseURL: URL(string: "http://localhost:11434")!,
        ollamaModelName: "gemma4:e4b"
    )
}
