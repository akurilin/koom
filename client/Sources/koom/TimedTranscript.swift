import Foundation

/// A word-level timed transcript produced by WhisperKit and
/// serialized to JSON for upload to the web backend. The web UI
/// renders clickable words that seek the video player to the exact
/// moment each word was spoken.
///
/// The JSON layout mirrors this struct hierarchy verbatim —
/// `JSONEncoder` with default settings produces the camelCase keys
/// the web frontend expects.
struct TimedTranscript: Codable, Sendable {
    let segments: [Segment]

    struct Segment: Codable, Sendable {
        let start: Float
        let end: Float
        let text: String
        let words: [Word]
    }

    struct Word: Codable, Sendable {
        let word: String
        let start: Float
        let end: Float
    }

    /// Plain-text rendering of the entire transcript — equivalent to
    /// joining every segment's text. Used by the auto-titler to feed
    /// Ollama without needing to know about timestamps.
    var plainText: String {
        segments
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
