import CryptoKit
import Foundation

enum LocalTitleModelState: Equatable, Sendable {
    case notDownloaded
    case downloaded
    case downloading
    case verifying
    case starting
    case ready
    case failed(String)
}

@MainActor
final class LocalTitleModelManager: ObservableObject {
    enum ManagerError: LocalizedError {
        case runtimeMissing(String)
        case invalidDownloadResponse(Int)
        case unexpectedFileSize(expected: Int64, actual: Int64)
        case checksumMismatch
        case serverExited
        case serverTimedOut

        var errorDescription: String? {
            switch self {
            case .runtimeMissing(let path):
                return "The bundled llama.cpp runtime is missing at \(path)."
            case .invalidDownloadResponse(let statusCode):
                return "The model download returned HTTP \(statusCode)."
            case .unexpectedFileSize(let expected, let actual):
                return
                    "The downloaded model has the wrong size (expected \(expected) bytes, received \(actual))."
            case .checksumMismatch:
                return "The downloaded model failed its SHA-256 integrity check."
            case .serverExited:
                return
                    "The local title server exited while starting. See the local-title-server log."
            case .serverTimedOut:
                return
                    "The local title server did not become ready. See the local-title-server log."
            }
        }
    }

    @Published private(set) var models: [LocalTitleModel] = []
    @Published private(set) var isEnabled: Bool
    @Published private(set) var selectedModelID = ""
    @Published private(set) var states: [String: LocalTitleModelState] = [:]
    @Published private(set) var catalogIssue: String?

    private static let selectedModelDefaultsKey =
        "koom.localTitle.selectedModelID"
    private static let enabledDefaultsKey = "koom.localTitle.isEnabled"

    private let fileManager: FileManager
    private let userDefaults: UserDefaults
    private var operationTask: Task<Void, Never>?
    private var operationID: UUID?
    private var operationModelID: String?
    private var serverProcess: Process?
    private var serverPort: Int?
    private var readyModelID: String?
    private var serverAPIKey: String?

    init(
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard
    ) {
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        isEnabled =
            userDefaults.object(forKey: Self.enabledDefaultsKey) as? Bool
            ?? true

        do {
            let catalog = try LocalTitleModelCatalog.load()
            models = catalog.models
            let savedModelID = userDefaults.string(
                forKey: Self.selectedModelDefaultsKey
            )
            if let savedModelID,
                catalog.models.contains(where: { $0.id == savedModelID })
            {
                selectedModelID = savedModelID
            } else {
                selectedModelID = catalog.defaultModelID
            }
            states = Dictionary(
                uniqueKeysWithValues: catalog.models.map {
                    (
                        $0.id,
                        Self.hasCompleteFile(for: $0, fileManager: fileManager)
                            ? .downloaded : .notDownloaded
                    )
                }
            )
        } catch {
            catalogIssue = error.localizedDescription
            AppLog.error("Local titles: \(error.localizedDescription)")
        }
    }

    deinit {
        operationTask?.cancel()
        if serverProcess?.isRunning == true {
            serverProcess?.terminate()
        }
    }

    var selectedModel: LocalTitleModel? {
        models.first(where: { $0.id == selectedModelID })
    }

    func state(for model: LocalTitleModel) -> LocalTitleModelState {
        states[model.id] ?? .notDownloaded
    }

    func prepareSelectedModel() {
        guard isEnabled, let selectedModel else { return }
        startOperation(for: selectedModel, redownload: false)
    }

    func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
        userDefaults.set(isEnabled, forKey: Self.enabledDefaultsKey)
        if isEnabled {
            prepareSelectedModel()
        } else {
            stop()
        }
    }

    func use(_ model: LocalTitleModel) {
        if !isEnabled {
            isEnabled = true
            userDefaults.set(true, forKey: Self.enabledDefaultsKey)
        }
        selectedModelID = model.id
        userDefaults.set(
            model.id,
            forKey: Self.selectedModelDefaultsKey
        )
        startOperation(for: model, redownload: false)
    }

    func redownload(_ model: LocalTitleModel) {
        startOperation(for: model, redownload: true)
    }

    func delete(_ model: LocalTitleModel) {
        if operationModelID == model.id {
            cancelCurrentOperation()
        }
        if readyModelID == model.id {
            stopServer()
        }
        if selectedModelID == model.id {
            isEnabled = false
            userDefaults.set(false, forKey: Self.enabledDefaultsKey)
        }

        do {
            for url in [modelFileURL(for: model), partialModelFileURL(for: model)]
            where fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            states[model.id] = .notDownloaded
            AppLog.info("Local titles: deleted \(model.displayName).")
        } catch {
            states[model.id] = .failed(error.localizedDescription)
            AppLog.error(
                "Local titles: could not delete \(model.displayName): \(error.localizedDescription)"
            )
        }
    }

    func generateTitleIfReady(for transcript: String) async throws -> String? {
        guard
            let readyModelID,
            readyModelID == selectedModelID,
            serverProcess?.isRunning == true,
            let serverAPIKey,
            let serverPort
        else {
            return nil
        }

        let client = LocalTitleClient(
            baseURL: Self.serverBaseURL(port: serverPort),
            apiKey: serverAPIKey,
            modelID: readyModelID
        )
        return try await client.generateTitle(transcript: transcript)
    }

    func stop() {
        cancelCurrentOperation()
        stopServer()
    }

    private func startOperation(
        for model: LocalTitleModel,
        redownload: Bool
    ) {
        cancelCurrentOperation()
        let operationID = UUID()
        self.operationID = operationID
        operationModelID = model.id
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.operationID == operationID {
                    self.operationID = nil
                    self.operationModelID = nil
                    self.operationTask = nil
                }
            }
            do {
                if redownload {
                    if readyModelID == model.id {
                        stopServer()
                    }
                    let partialURL = partialModelFileURL(for: model)
                    if fileManager.fileExists(atPath: partialURL.path) {
                        try fileManager.removeItem(at: partialURL)
                    }
                }
                try await prepare(model, forceDownload: redownload)
            } catch is CancellationError {
                guard self.operationID == operationID else { return }
                self.refreshFileState(for: model)
            } catch {
                guard self.operationID == operationID else { return }
                self.states[model.id] = .failed(error.localizedDescription)
                AppLog.error(
                    "Local titles: \(model.displayName) setup failed: \(error.localizedDescription)"
                )
            }
        }
    }

    private func cancelCurrentOperation() {
        operationTask?.cancel()
        operationTask = nil
        operationID = nil
        guard let operationModelID else { return }
        self.operationModelID = nil

        if case .starting = states[operationModelID] {
            stopServer()
        }
        refreshFileState(for: model(withID: operationModelID))
    }

    private func prepare(
        _ model: LocalTitleModel,
        forceDownload: Bool
    ) async throws {
        let modelURL = modelFileURL(for: model)
        if forceDownload
            || !Self.hasCompleteFile(for: model, fileManager: fileManager)
        {
            try await download(model, to: modelURL)
        }
        try Task.checkCancellation()

        guard isEnabled, selectedModelID == model.id else {
            states[model.id] = .downloaded
            return
        }

        states[model.id] = .starting
        try await startServer(for: model, modelURL: modelURL)
        states[model.id] = .ready
        AppLog.info("Local titles: \(model.displayName) is ready.")
    }

    private func download(
        _ model: LocalTitleModel,
        to destinationURL: URL
    ) async throws {
        states[model.id] = .downloading
        AppLog.info(
            "Local titles: downloading \(model.displayName) (\(model.formattedDownloadSize)) from \(model.downloadURL.absoluteString)."
        )

        let modelsDirectory = Self.modelsDirectoryURL
        try fileManager.createDirectory(
            at: modelsDirectory,
            withIntermediateDirectories: true
        )
        let partialURL = partialModelFileURL(for: model)
        if fileManager.fileExists(atPath: partialURL.path) {
            try fileManager.removeItem(at: partialURL)
        }

        var request = URLRequest(url: model.downloadURL)
        request.timeoutInterval = 60 * 30
        let (temporaryURL, response) = try await URLSession.shared.download(
            for: request
        )
        try Task.checkCancellation()

        guard
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode)
        else {
            throw ManagerError.invalidDownloadResponse(
                (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        }

        try fileManager.moveItem(at: temporaryURL, to: partialURL)
        states[model.id] = .verifying

        let actualSize = try Self.fileSize(at: partialURL)
        guard actualSize == model.byteCount else {
            try? fileManager.removeItem(at: partialURL)
            throw ManagerError.unexpectedFileSize(
                expected: model.byteCount,
                actual: actualSize
            )
        }
        let actualHash = try Self.sha256(at: partialURL)
        guard actualHash == model.sha256.lowercased() else {
            try? fileManager.removeItem(at: partialURL)
            throw ManagerError.checksumMismatch
        }
        try Task.checkCancellation()

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: partialURL, to: destinationURL)
        states[model.id] = .downloaded
        AppLog.info(
            "Local titles: downloaded and verified \(model.displayName)."
        )
    }

    private func startServer(
        for model: LocalTitleModel,
        modelURL: URL
    ) async throws {
        if readyModelID == model.id, serverProcess?.isRunning == true {
            return
        }
        stopServer()

        let runtimeURL = Self.runtimeExecutableURL
        guard fileManager.isExecutableFile(atPath: runtimeURL.path) else {
            throw ManagerError.runtimeMissing(runtimeURL.path)
        }

        let apiKey = UUID().uuidString + UUID().uuidString
        let port = Int.random(in: 49_152...60_000)
        let process = Process()
        process.executableURL = runtimeURL
        process.arguments = [
            "--host", "127.0.0.1",
            "--port", String(port),
            "--model", modelURL.path,
            "--alias", model.id,
            "--api-key", apiKey,
            "--ctx-size", "2048",
            "--parallel", "1",
            "--jinja",
            "--no-webui",
            "--no-slots",
        ]

        try fileManager.createDirectory(
            at: AppLog.logsDirectoryURL,
            withIntermediateDirectories: true
        )
        let logURL = AppLog.logsDirectoryURL.appendingPathComponent(
            "local-title-server.log"
        )
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle.seekToEnd()
        process.standardOutput = logHandle
        process.standardError = logHandle

        AppLog.info(
            "Local titles: starting bundled llama.cpp for \(model.displayName). Server output: \(logURL.path)"
        )
        try process.run()
        serverProcess = process
        serverAPIKey = apiKey
        serverPort = port

        for _ in 0..<120 {
            try Task.checkCancellation()
            guard process.isRunning else {
                stopServer()
                throw ManagerError.serverExited
            }
            if await serverIsHealthy(apiKey: apiKey, port: port) {
                readyModelID = model.id
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }

        stopServer()
        throw ManagerError.serverTimedOut
    }

    private func serverIsHealthy(apiKey: String, port: Int) async -> Bool {
        var request = URLRequest(
            url: Self.serverBaseURL(port: port).appendingPathComponent("health")
        )
        request.setValue(
            "Bearer \(apiKey)",
            forHTTPHeaderField: "Authorization"
        )
        request.timeoutInterval = 1
        guard
            let (_, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse
        else {
            return false
        }
        return (200..<300).contains(http.statusCode)
    }

    private func stopServer() {
        if serverProcess?.isRunning == true {
            serverProcess?.terminate()
            serverProcess?.waitUntilExit()
        }
        serverProcess = nil
        serverAPIKey = nil
        serverPort = nil
        if let readyModelID {
            refreshFileState(for: model(withID: readyModelID))
        }
        readyModelID = nil
    }

    private func refreshFileState(for model: LocalTitleModel?) {
        guard let model else { return }
        states[model.id] =
            Self.hasCompleteFile(for: model, fileManager: fileManager)
            ? .downloaded : .notDownloaded
    }

    private func model(withID id: String) -> LocalTitleModel? {
        models.first(where: { $0.id == id })
    }

    private func modelFileURL(for model: LocalTitleModel) -> URL {
        Self.modelsDirectoryURL.appendingPathComponent(model.filename)
    }

    private func partialModelFileURL(for model: LocalTitleModel) -> URL {
        modelFileURL(for: model).appendingPathExtension("part")
    }

    private static var modelsDirectoryURL: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("koom/models", isDirectory: true)
    }

    private static var runtimeExecutableURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/llama-runtime")
            .appendingPathComponent("llama-server")
    }

    private static func serverBaseURL(port: Int) -> URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    private static func hasCompleteFile(
        for model: LocalTitleModel,
        fileManager: FileManager
    ) -> Bool {
        let url = modelsDirectoryURL.appendingPathComponent(model.filename)
        return fileManager.fileExists(atPath: url.path)
            && (try? fileSize(at: url)) == model.byteCount
    }

    private static func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private static func sha256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard
                let data = try handle.read(upToCount: 4 * 1_024 * 1_024),
                !data.isEmpty
            else {
                break
            }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
