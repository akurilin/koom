import Foundation

enum KoomEnvironment: String, CaseIterable, Codable, Identifiable, Sendable {
    case dev
    case prod

    var id: Self { self }

    var displayName: String {
        switch self {
        case .dev:
            "Dev"
        case .prod:
            "Prod"
        }
    }

    var recordingsSubdirectoryName: String {
        rawValue
    }

    var defaultBackendURL: URL? {
        switch self {
        case .dev:
            URL(string: "http://localhost:3000")
        case .prod:
            nil
        }
    }

    var backendURLPrompt: String {
        switch self {
        case .dev:
            "http://localhost:3000"
        case .prod:
            "https://koom.example.com"
        }
    }

    static func infer(from backendURL: URL?) -> KoomEnvironment? {
        guard let backendURL,
            let host = backendURL.host?.lowercased()
        else {
            return nil
        }

        switch host {
        case "localhost", "127.0.0.1":
            return .dev
        default:
            return .prod
        }
    }
}
