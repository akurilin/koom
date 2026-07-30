import Foundation

struct LocalTitleModel: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let summary: String
    let parameterCount: String
    let quantization: String
    let filename: String
    let downloadURL: URL
    let byteCount: Int64
    let sha256: String
    let license: String
    let sourceURL: URL

    var formattedDownloadSize: String {
        ByteCountFormatter.string(
            fromByteCount: byteCount,
            countStyle: .file
        )
    }
}

struct LocalTitleModelCatalog: Codable, Equatable, Sendable {
    enum CatalogError: LocalizedError {
        case missingResource
        case unsupportedVersion(Int)
        case missingDefaultModel(String)
        case duplicateModelID(String)
        case duplicateFilename(String)
        case invalidHash(modelID: String)
        case invalidModel(modelID: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .missingResource:
                return "The bundled local title model catalog is missing."
            case .unsupportedVersion(let version):
                return "Local title model catalog version \(version) is not supported."
            case .missingDefaultModel(let modelID):
                return "The default local title model '\(modelID)' is not in the catalog."
            case .duplicateModelID(let modelID):
                return "The local title model catalog contains duplicate id '\(modelID)'."
            case .duplicateFilename(let filename):
                return "The local title model catalog contains duplicate filename '\(filename)'."
            case .invalidHash(let modelID):
                return "The local title model '\(modelID)' has an invalid SHA-256 hash."
            case .invalidModel(let modelID, let reason):
                return "The local title model '\(modelID)' is invalid: \(reason)"
            }
        }
    }

    let version: Int
    let defaultModelID: String
    let models: [LocalTitleModel]

    static func load() throws -> LocalTitleModelCatalog {
        let fileManager = FileManager.default
        let sourceFallback = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/local-title-models.json")
        let candidates = [
            Bundle.main.url(
                forResource: "local-title-models",
                withExtension: "json"
            ),
            sourceFallback,
        ].compactMap { $0 }

        guard
            let resourceURL = candidates.first(where: {
                fileManager.fileExists(atPath: $0.path)
            })
        else {
            throw CatalogError.missingResource
        }

        return try decode(Data(contentsOf: resourceURL))
    }

    static func decode(_ data: Data) throws -> LocalTitleModelCatalog {
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        try catalog.validate()
        return catalog
    }

    func validate() throws {
        guard version == 1 else {
            throw CatalogError.unsupportedVersion(version)
        }
        guard models.contains(where: { $0.id == defaultModelID }) else {
            throw CatalogError.missingDefaultModel(defaultModelID)
        }

        var modelIDs = Set<String>()
        var filenames = Set<String>()
        for model in models {
            guard modelIDs.insert(model.id).inserted else {
                throw CatalogError.duplicateModelID(model.id)
            }
            guard filenames.insert(model.filename).inserted else {
                throw CatalogError.duplicateFilename(model.filename)
            }
            guard !model.id.isEmpty, !model.displayName.isEmpty else {
                throw CatalogError.invalidModel(
                    modelID: model.id,
                    reason: "id and display name are required"
                )
            }
            guard
                model.filename == (model.filename as NSString).lastPathComponent,
                !model.filename.hasSuffix(".part")
            else {
                throw CatalogError.invalidModel(
                    modelID: model.id,
                    reason: "filename must be a safe basename"
                )
            }
            guard
                model.downloadURL.scheme == "https",
                model.downloadURL.host != nil,
                model.sourceURL.scheme == "https",
                model.sourceURL.host != nil,
                model.byteCount > 0
            else {
                throw CatalogError.invalidModel(
                    modelID: model.id,
                    reason: "HTTPS URLs and a positive byte count are required"
                )
            }
            guard
                model.sha256.count == 64,
                model.sha256.allSatisfy(\.isHexDigit)
            else {
                throw CatalogError.invalidHash(modelID: model.id)
            }
        }
    }
}
