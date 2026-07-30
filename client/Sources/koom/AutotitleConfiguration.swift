struct AutotitleConfiguration: Sendable {
    let isEnabled: Bool
    let whisperModelName: String

    static let shippedDefault = AutotitleConfiguration(
        isEnabled: true,
        whisperModelName: "openai_whisper-small.en"
    )
}
