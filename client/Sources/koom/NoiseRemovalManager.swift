import CryptoKit
import Foundation

/// One choice in Settings > Noise removal. The models were picked and
/// ranked by blind listening tests in scripts/audio-lab.
struct NoiseRemovalOption: Identifiable, Equatable, Sendable {
    enum Method: Equatable, Sendable {
        case off
        case appleVoiceIsolation
        /// A Python helper in Resources/denoisers/<name>, installed on
        /// demand into its own pinned environment.
        case helper(String)
    }

    let id: String
    let displayName: String
    let summary: String
    /// Approximate disk use once installed; nil when nothing downloads.
    let downloadSize: String?
    let sourceURL: URL?
    let method: Method

    var needsInstall: Bool {
        if case .helper = method { return true }
        return false
    }

    static let all: [NoiseRemovalOption] = [
        NoiseRemovalOption(
            id: "sidon",
            displayName: "Sidon",
            summary:
                "Strongest noise removal in testing. Regenerates the voice, which can add a slight wobble to already-clean recordings. CPU only.",
            downloadSize: "1.5 GB",
            sourceURL: URL(
                string: "https://huggingface.co/sarulab-speech/sidon-v0.1"
            ),
            method: .helper("sidon")
        ),
        NoiseRemovalOption(
            id: "clearvoice",
            displayName: "ClearerVoice",
            summary:
                "MossFormer2 by Alibaba. Leaves clean recordings intact. Uses the GPU.",
            downloadSize: "1.1 GB",
            sourceURL: URL(
                string: "https://github.com/modelscope/ClearerVoice-Studio"
            ),
            method: .helper("clearvoice")
        ),
        NoiseRemovalOption(
            id: "dpdfnet",
            displayName: "DPDFNet",
            summary: "Lightweight model. Leaves clean recordings intact.",
            downloadSize: "0.4 GB",
            sourceURL: URL(string: "https://pypi.org/project/dpdfnet/"),
            method: .helper("dpdfnet")
        ),
        NoiseRemovalOption(
            id: appleVoiceIsolationID,
            displayName: "Apple Voice Isolation",
            summary:
                "Built into macOS and fast, with nothing to download. Used whenever the selected model isn't ready.",
            downloadSize: nil,
            sourceURL: nil,
            method: .appleVoiceIsolation
        ),
        NoiseRemovalOption(
            id: "off",
            displayName: "Off",
            summary: "Keeps background noise; only evens out the volume.",
            downloadSize: nil,
            sourceURL: nil,
            method: .off
        ),
    ]

    static let defaultID = "sidon"
    static let appleVoiceIsolationID = "apple-voice-isolation"

    static func withID(_ id: String) -> NoiseRemovalOption? {
        all.first { $0.id == id }
    }
}

enum NoiseRemovalInstallState: Equatable, Sendable {
    case notInstalled
    case installing(String)
    case installed
    case failed(String)
}

/// What to run on one recording's audio, resolved on the main actor when
/// the recording finishes so the work itself can run anywhere.
enum NoiseRemovalPlan: Sendable {
    case off
    case appleVoiceIsolation
    case helper(NoiseRemovalHelperRuntime)

    var logDescription: String {
        switch self {
        case .off: "off"
        case .appleVoiceIsolation: "Apple Voice Isolation"
        case .helper(let runtime): runtime.displayName
        }
    }
}

struct NoiseRemovalHelperRuntime: Sendable {
    let displayName: String
    let pythonURL: URL
    let scriptURL: URL
    let workingDirectoryURL: URL
    let environment: [String: String]
}

/// Installs, removes, and selects noise removal models. Mirrors
/// LocalTitleModelManager: the selected model installs in the background at
/// launch, recordings made before it's ready fall back to Apple Voice
/// Isolation, and each model lives in its own folder so Delete is one
/// directory removal.
///
/// A model install is the helper's pinned Python environment (uv checks
/// every package against the hashes in its uv.lock) plus its weights,
/// fetched once by the helper's --prefetch mode. After that, processing
/// runs offline.
@MainActor
final class NoiseRemovalManager: ObservableObject {
    @Published private(set) var selectedOptionID: String
    @Published private(set) var states: [String: NoiseRemovalInstallState]

    let options = NoiseRemovalOption.all

    private static let selectedOptionDefaultsKey =
        "koom.noiseRemoval.selectedOptionID"
    private nonisolated static let installMarkerName = "installed.json"

    private let preferences: any KoomPreferences
    private var operationTask: Task<Void, Never>?
    private var operationID: UUID?
    private var operationOptionID: String?

    init(preferences: any KoomPreferences = KoomRuntimeProfile.preferences) {
        self.preferences = preferences
        let savedID = preferences.string(
            forKey: Self.selectedOptionDefaultsKey
        )
        selectedOptionID =
            savedID.flatMap(NoiseRemovalOption.withID)?.id
            ?? NoiseRemovalOption.defaultID
        states = Dictionary(
            uniqueKeysWithValues: NoiseRemovalOption.all.map {
                ($0.id, Self.isInstalled($0) ? .installed : .notInstalled)
            }
        )
    }

    var selectedOption: NoiseRemovalOption? {
        NoiseRemovalOption.withID(selectedOptionID)
    }

    func state(for option: NoiseRemovalOption) -> NoiseRemovalInstallState {
        states[option.id] ?? .notInstalled
    }

    /// Installs the selected model if it isn't installed yet.
    func prepareSelectedOption() {
        guard let selectedOption, selectedOption.needsInstall else { return }
        switch state(for: selectedOption) {
        case .notInstalled, .failed:
            startInstall(selectedOption)
        case .installing, .installed:
            break
        }
    }

    func use(_ option: NoiseRemovalOption) {
        selectedOptionID = option.id
        preferences.set(option.id, forKey: Self.selectedOptionDefaultsKey)
        AppLog.info("Noise removal: selected \(option.displayName).")
        prepareSelectedOption()
    }

    func reinstall(_ option: NoiseRemovalOption) {
        guard option.needsInstall else { return }
        startInstall(option)
    }

    func delete(_ option: NoiseRemovalOption) {
        guard option.needsInstall else { return }
        if operationOptionID == option.id {
            cancelCurrentOperation()
        }
        do {
            let directory = Self.installDirectory(for: option)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            states[option.id] = .notInstalled
            AppLog.info("Noise removal: deleted \(option.displayName).")
        } catch {
            states[option.id] = .failed(error.localizedDescription)
            AppLog.error(
                "Noise removal: could not delete \(option.displayName): \(error.localizedDescription)"
            )
        }
        // Keeping a deleted model selected would download it again at the
        // next launch.
        if selectedOptionID == option.id,
            let fallback = NoiseRemovalOption.withID(
                NoiseRemovalOption.appleVoiceIsolationID
            )
        {
            use(fallback)
        }
    }

    func stop() {
        cancelCurrentOperation()
    }

    /// What to run on a finished recording. Falls back to Apple Voice
    /// Isolation while the selected model is missing or still installing.
    func planForRecording() -> NoiseRemovalPlan {
        guard let option = selectedOption else { return .appleVoiceIsolation }
        switch option.method {
        case .off:
            return .off
        case .appleVoiceIsolation:
            return .appleVoiceIsolation
        case .helper(let name):
            guard state(for: option) == .installed else {
                AppLog.info(
                    "Noise removal: \(option.displayName) isn't installed yet (\(state(for: option))); using Apple Voice Isolation for this recording."
                )
                return .appleVoiceIsolation
            }
            return .helper(Self.runtime(for: option, helperName: name))
        }
    }

    // MARK: - Install

    private func startInstall(_ option: NoiseRemovalOption) {
        guard case .helper(let helperName) = option.method else { return }
        cancelCurrentOperation()
        let operationID = UUID()
        self.operationID = operationID
        operationOptionID = option.id
        states[option.id] = .installing("Installing…")

        operationTask = Task { [weak self] in
            do {
                try await Self.install(option, helperName: helperName) {
                    stage in
                    await MainActor.run {
                        guard let self, self.operationID == operationID
                        else { return }
                        self.states[option.id] = .installing(stage)
                    }
                }
                guard let self, self.operationID == operationID else { return }
                self.states[option.id] = .installed
                AppLog.info("Noise removal: \(option.displayName) is ready.")
            } catch {
                guard let self, self.operationID == operationID else { return }
                if Task.isCancelled {
                    self.states[option.id] =
                        Self.isInstalled(option) ? .installed : .notInstalled
                } else {
                    self.states[option.id] = .failed(error.localizedDescription)
                    AppLog.error(
                        "Noise removal: installing \(option.displayName) failed: \(error.localizedDescription)"
                    )
                }
            }
            if let self, self.operationID == operationID {
                self.operationID = nil
                self.operationOptionID = nil
                self.operationTask = nil
            }
        }
    }

    private func cancelCurrentOperation() {
        operationTask?.cancel()
        operationTask = nil
        operationID = nil
        guard let optionID = operationOptionID,
            let option = NoiseRemovalOption.withID(optionID)
        else { return }
        operationOptionID = nil
        states[optionID] = Self.isInstalled(option) ? .installed : .notInstalled
    }

    private nonisolated static func install(
        _ option: NoiseRemovalOption,
        helperName: String,
        progress: @Sendable (String) async -> Void
    ) async throws {
        guard let uvURL = uvExecutableURL else {
            throw InstallError(
                "uv is missing from koom.app. Rebuild it with ./scripts/build-app.sh."
            )
        }
        guard let sourceURL = helperSourceURL(named: helperName) else {
            throw InstallError(
                "The \(option.displayName) helper files are missing from koom.app."
            )
        }

        // Start clean so a half-finished or outdated install can't linger.
        let directory = installDirectory(for: option)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        AppLog.info(
            "Noise removal: installing \(option.displayName) into \(directory.path)."
        )
        await progress("Installing Python environment…")
        var uvEnvironment = ProcessInfo.processInfo.environment
        uvEnvironment["UV_PROJECT_ENVIRONMENT"] =
            directory.appendingPathComponent("env").path
        uvEnvironment["UV_PYTHON_INSTALL_DIR"] =
            directory.appendingPathComponent("python").path
        // Never build on whatever Python the user has installed.
        uvEnvironment["UV_PYTHON_PREFERENCE"] = "only-managed"
        uvEnvironment["UV_NO_CONFIG"] = "1"
        _ = try await ProcessRunner.run(
            uvURL,
            arguments: [
                "sync", "--frozen", "--no-cache", "--project", sourceURL.path,
            ],
            environment: uvEnvironment
        )

        await progress("Downloading model…")
        let runtime = runtime(for: option, helperName: helperName)
        var prefetchEnvironment = runtime.environment
        prefetchEnvironment.removeValue(forKey: "HF_HUB_OFFLINE")
        try fileManager.createDirectory(
            at: runtime.workingDirectoryURL,
            withIntermediateDirectories: true
        )
        _ = try await ProcessRunner.run(
            runtime.pythonURL,
            arguments: [runtime.scriptURL.path, "--prefetch"],
            environment: prefetchEnvironment,
            currentDirectoryURL: runtime.workingDirectoryURL
        )

        let marker = InstallMarker(
            lockfileSHA256: try lockfileHash(sourceURL: sourceURL)
        )
        try JSONEncoder().encode(marker).write(
            to: directory.appendingPathComponent(installMarkerName)
        )
    }

    // MARK: - Files

    private struct InstallMarker: Codable {
        let lockfileSHA256: String
    }

    private struct InstallError: LocalizedError {
        let errorDescription: String?

        init(_ message: String) {
            errorDescription = message
        }
    }

    /// Installed means installed against the uv.lock this build ships; a
    /// koom update that changes a helper's dependencies reinstalls it.
    private nonisolated static func isInstalled(
        _ option: NoiseRemovalOption
    ) -> Bool {
        guard case .helper(let helperName) = option.method else { return true }
        guard let sourceURL = helperSourceURL(named: helperName),
            let data = try? Data(
                contentsOf: installDirectory(for: option)
                    .appendingPathComponent(installMarkerName)
            ),
            let marker = try? JSONDecoder().decode(
                InstallMarker.self,
                from: data
            ),
            let currentHash = try? lockfileHash(sourceURL: sourceURL)
        else {
            return false
        }
        return marker.lockfileSHA256 == currentHash
            && FileManager.default.isExecutableFile(
                atPath: runtime(for: option, helperName: helperName)
                    .pythonURL.path
            )
    }

    private nonisolated static func runtime(
        for option: NoiseRemovalOption,
        helperName: String
    ) -> NoiseRemovalHelperRuntime {
        let directory = installDirectory(for: option)
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HOME"] = directory.appendingPathComponent("hf").path
        environment["DPDFNET_CACHE_DIR"] =
            directory.appendingPathComponent("dpdfnet").path
        // Weights are fetched at install time; processing stays offline.
        environment["HF_HUB_OFFLINE"] = "1"
        // The helper scripts live in the signed app bundle.
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        return NoiseRemovalHelperRuntime(
            displayName: option.displayName,
            pythonURL: directory.appendingPathComponent("env/bin/python"),
            scriptURL: (helperSourceURL(named: helperName)
                ?? directory).appendingPathComponent("enhance.py"),
            // ClearerVoice keeps its checkpoints relative to the working
            // directory.
            workingDirectoryURL: directory.appendingPathComponent("work"),
            environment: environment
        )
    }

    private nonisolated static func lockfileHash(
        sourceURL: URL
    ) throws -> String {
        let data = try Data(
            contentsOf: sourceURL.appendingPathComponent("uv.lock")
        )
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private nonisolated static func installDirectory(
        for option: NoiseRemovalOption
    ) -> URL {
        let root =
            KoomRuntimeProfile.denoisersDirectoryURL
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            .appendingPathComponent("koom/denoisers", isDirectory: true)
        return root.appendingPathComponent(option.id, isDirectory: true)
    }

    private nonisolated static var uvExecutableURL: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/uv/uv")
        return FileManager.default.isExecutableFile(atPath: url.path)
            ? url : nil
    }

    /// The helper's enhance.py, pyproject.toml and uv.lock: in the app
    /// bundle, or in the source tree when running unbundled.
    private nonisolated static func helperSourceURL(
        named helperName: String
    ) -> URL? {
        let sourceFallback = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/denoisers")
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("denoisers"),
            sourceFallback,
        ].compactMap { $0 }
        return candidates.map {
            $0.appendingPathComponent(helperName, isDirectory: true)
        }.first {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("uv.lock").path
            )
        }
    }
}
