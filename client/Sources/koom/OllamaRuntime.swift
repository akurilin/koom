import Foundation

actor OllamaRuntime {
    enum ReadinessError: LocalizedError {
        case unreachable(URL)
        case automaticStartupUnavailable(URL)
        case automaticStartupFailed(URL, String)
        case missingModel(String)
        case warmupFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreachable(let baseURL):
                return "Ollama is not reachable at \(baseURL.absoluteString). Start it with 'ollama serve'."
            case .automaticStartupUnavailable(let baseURL):
                return "Ollama is not reachable at \(baseURL.absoluteString), and koom could not find an 'ollama' executable to start automatically."
            case .automaticStartupFailed(let baseURL, let logPath):
                return "Ollama is not reachable at \(baseURL.absoluteString), and automatic startup failed. See \(logPath)."
            case .missingModel(let model):
                return "Ollama model '\(model)' is not pulled. Run 'ollama pull \(model)'."
            case .warmupFailed(let message):
                return "Ollama warmup failed. \(message)"
            }
        }
    }

    private let client: OllamaClient
    private var hasWarmedModel = false
    private var readinessTask: Task<Void, Error>?
    private var autoStartedProcess: Process?
    private var autoStartedLogHandle: FileHandle?
    private let ollamaLogURL =
        AppLog.logsDirectoryURL.appendingPathComponent("ollama-serve.log")

    init(client: OllamaClient) {
        self.client = client
    }

    func prepareForLaunch() async -> String? {
        do {
            try await ensureReady()
            return nil
        } catch {
            AppLog.error("Autotitle: Ollama preflight failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    func generateTitle(from transcript: String) async throws -> String {
        try await ensureReady()
        return try await client.generateTitle(from: transcript)
    }

    func ensureReady() async throws {
        if hasWarmedModel {
            return
        }
        if let readinessTask {
            try await readinessTask.value
            return
        }

        let task = Task<Void, Error> {
            try await self.performReadinessCheck()
        }
        readinessTask = task

        do {
            try await task.value
            hasWarmedModel = true
            readinessTask = nil
        } catch {
            readinessTask = nil
            throw error
        }
    }

    private func performReadinessCheck() async throws {
        if !(await client.isReachable()) {
            try await startLocalServiceIfPossible()
        }

        guard await client.isReachable() else {
            throw ReadinessError.unreachable(client.baseURL)
        }

        guard try await client.isModelPresent() else {
            throw ReadinessError.missingModel(client.model)
        }

        do {
            try await client.warmModel()
        } catch {
            if autoStartedProcess != nil {
                AppLog.info(
                    "Autotitle: Ollama warmup failed once; restarting the auto-started local service and retrying."
                )
                try await restartAutoStartedLocalService()
                try await client.warmModel()
                return
            }
            throw ReadinessError.warmupFailed(error.localizedDescription)
        }
    }

    private func startLocalServiceIfPossible() async throws {
        guard client.canAutoStartLocalService else {
            return
        }

        if let autoStartedProcess, autoStartedProcess.isRunning {
            return
        }

        guard let executableURL = Self.findOllamaExecutable() else {
            throw ReadinessError.automaticStartupUnavailable(client.baseURL)
        }

        AppLog.info(
            "Autotitle: Ollama not reachable at \(client.baseURL.absoluteString). Starting local service from \(executableURL.path)."
        )

        try FileManager.default.createDirectory(
            at: AppLog.logsDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        if !FileManager.default.fileExists(atPath: ollamaLogURL.path) {
            FileManager.default.createFile(atPath: ollamaLogURL.path, contents: nil)
        }

        let logHandle = try FileHandle(forWritingTo: ollamaLogURL)
        try logHandle.seekToEnd()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["serve"]
        var environment = ProcessInfo.processInfo.environment
        environment["OLLAMA_HOST"] = client.serveHostBinding
        process.environment = environment
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw ReadinessError.automaticStartupFailed(
                client.baseURL,
                ollamaLogURL.path
            )
        }

        autoStartedProcess = process
        autoStartedLogHandle = logHandle

        for _ in 1...20 {
            if await client.isReachable() {
                AppLog.info(
                    "Autotitle: local Ollama is reachable at \(client.baseURL.absoluteString)."
                )
                return
            }
            if !process.isRunning {
                break
            }
            try? await Task.sleep(for: .milliseconds(500))
        }

        if process.isRunning {
            process.terminate()
            for _ in 1...20 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        autoStartedProcess = nil
        try? autoStartedLogHandle?.close()
        autoStartedLogHandle = nil

        throw ReadinessError.automaticStartupFailed(
            client.baseURL,
            ollamaLogURL.path
        )
    }

    private func restartAutoStartedLocalService() async throws {
        if let autoStartedProcess, autoStartedProcess.isRunning {
            autoStartedProcess.terminate()
            for _ in 1...20 where autoStartedProcess.isRunning {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        autoStartedProcess = nil
        try? autoStartedLogHandle?.close()
        autoStartedLogHandle = nil
        hasWarmedModel = false

        try await startLocalServiceIfPossible()
    }

    private static func findOllamaExecutable() -> URL? {
        let configuredPATH = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidateDirectories =
            [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/opt/local/bin",
            ] + configuredPATH.split(separator: ":").map(String.init)

        var seen = Set<String>()
        for directory in candidateDirectories where seen.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent("ollama")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }
}
