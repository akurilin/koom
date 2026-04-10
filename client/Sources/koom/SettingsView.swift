import AppKit
import SwiftUI

/// Settings window for backend credentials, active environment, and
/// recording compression preferences.
///
/// Opened automatically on first run (from AppDelegate) when either
/// value is missing, and otherwise reachable via `Cmd+,` or the
/// "koom → Settings…" menu item. Both are wired for free by
/// SwiftUI's `Settings` scene — this view is what that scene hosts.
///
/// Persistence:
///
///   - Active environment    → UserDefaults (via KoomConfig)
///   - Backend URLs          → UserDefaults (via KoomConfig)
///   - Admin secrets         → Keychain     (via KoomConfig)
///   - Compression settings  → UserDefaults (via AppSettingsStore)
///
/// The view never tries to call the backend or validate the secret
/// online. Save just writes the values. The doctor script and the
/// upload flow itself are where bad credentials surface as actionable
/// errors.
struct SettingsView: View {
    private struct EnvironmentDraft {
        var backendURLString: String
        var adminSecret: String
    }

    private struct ValidationError: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    private let settingsStore = AppSettingsStore()

    @State private var activeEnvironment: KoomEnvironment =
        KoomConfig.activeEnvironment
    @State private var devDraft = EnvironmentDraft(
        backendURLString: "",
        adminSecret: ""
    )
    @State private var prodDraft = EnvironmentDraft(
        backendURLString: "",
        adminSecret: ""
    )
    @State private var captureFrameRate: CaptureFrameRateOption =
        CompressionSettings.default.captureFrameRate
    @State private var optimizeUploads: Bool =
        CompressionSettings.default.optimizeUploads
    @State private var errorMessage: String?
    @State private var settingsWindow: NSWindow?

    var body: some View {
        Form {
            Section {
                Picker("Active environment", selection: $activeEnvironment) {
                    ForEach(KoomEnvironment.allCases) { environment in
                        Text(environment.displayName).tag(environment)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(
                    "New recordings and catch-up uploads use the active environment. Recordings live under \(recordingsDirectoryPath(for: activeEnvironment))."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                TextField(
                    "Backend URL",
                    text: backendURLBinding,
                    prompt: Text(activeEnvironment.backendURLPrompt)
                )
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)

                SecureField(
                    "Admin secret",
                    text: adminSecretBinding,
                    prompt: Text("KOOM_ADMIN_SECRET")
                )
                .textFieldStyle(.roundedBorder)
            } header: {
                Text("\(activeEnvironment.displayName) Backend")
                    .font(.headline)
            } footer: {
                Text(backendSectionFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Capture cadence", selection: $captureFrameRate) {
                    ForEach(CaptureFrameRateOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }

                Toggle(
                    "Optimize uploads with ffmpeg when available",
                    isOn: $optimizeUploads
                )
            } header: {
                Text("Compression")
                    .font(.headline)
            } footer: {
                Text(
                    "15 fps usually shrinks static screen recordings with little quality cost. Upload optimization keeps the local recording untouched and only uploads a smaller MP4 when ffmpeg is installed and the re-encode is meaningfully smaller."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Save & Close") {
                    saveAndClose()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(
            WindowAccessor { window in
                captureSettingsWindow(window)
            }
        )
        .onAppear {
            loadFromStore()
        }
    }

    // MARK: - Bindings

    private var backendURLBinding: Binding<String> {
        Binding(
            get: {
                switch activeEnvironment {
                case .dev:
                    devDraft.backendURLString
                case .prod:
                    prodDraft.backendURLString
                }
            },
            set: { newValue in
                switch activeEnvironment {
                case .dev:
                    devDraft.backendURLString = newValue
                case .prod:
                    prodDraft.backendURLString = newValue
                }
            }
        )
    }

    private var adminSecretBinding: Binding<String> {
        Binding(
            get: {
                switch activeEnvironment {
                case .dev:
                    devDraft.adminSecret
                case .prod:
                    prodDraft.adminSecret
                }
            },
            set: { newValue in
                switch activeEnvironment {
                case .dev:
                    devDraft.adminSecret = newValue
                case .prod:
                    prodDraft.adminSecret = newValue
                }
            }
        )
    }

    // MARK: - Derived text

    private var backendSectionFooter: String {
        switch activeEnvironment {
        case .dev:
            return
                "Leave the URL blank to use \(KoomEnvironment.dev.backendURLPrompt). Store the Dev secret separately so switching environments does not overwrite Prod."
        case .prod:
            return
                "Use the deployed backend URL and its matching admin secret. Prod recordings are stored separately from Dev."
        }
    }

    // MARK: - Actions

    private func loadFromStore() {
        activeEnvironment = KoomConfig.activeEnvironment
        devDraft.backendURLString =
            KoomConfig.backendURL(for: .dev)?.absoluteString ?? ""
        prodDraft.backendURLString =
            KoomConfig.backendURL(for: .prod)?.absoluteString ?? ""

        let compressionSettings = settingsStore.loadCompressionSettings()
        captureFrameRate = compressionSettings.captureFrameRate
        optimizeUploads = compressionSettings.optimizeUploads

        do {
            let adminSecrets = try KoomConfig.loadAdminSecrets()
            devDraft.adminSecret = adminSecrets.dev
            prodDraft.adminSecret = adminSecrets.prod
        } catch {
            errorMessage =
                "Could not read admin secret from Keychain: \(error.localizedDescription)"
        }
    }

    private func saveAndClose() {
        errorMessage = nil

        let devURL: URL?
        let prodURL: URL?
        do {
            devURL = try normalizedBackendURL(devDraft.backendURLString, for: .dev)
            prodURL = try normalizedBackendURL(prodDraft.backendURLString, for: .prod)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let effectiveActiveBackendURL =
            switch activeEnvironment {
            case .dev:
                devURL ?? KoomEnvironment.dev.defaultBackendURL
            case .prod:
                prodURL
            }

        guard let effectiveActiveBackendURL else {
            errorMessage =
                "\(activeEnvironment.displayName) backend URL must be a valid http:// or https:// URL."
            return
        }

        do {
            KoomConfig.activeEnvironment = activeEnvironment
            KoomConfig.setBackendURL(devURL, for: .dev)
            KoomConfig.setBackendURL(prodURL, for: .prod)
            try saveSecret(devDraft.adminSecret, for: .dev)
            try saveSecret(prodDraft.adminSecret, for: .prod)

            devDraft.backendURLString =
                KoomConfig.backendURL(for: .dev)?.absoluteString ?? ""
            prodDraft.backendURLString =
                KoomConfig.backendURL(for: .prod)?.absoluteString ?? ""
            devDraft.adminSecret = normalizedSecret(devDraft.adminSecret)
            prodDraft.adminSecret = normalizedSecret(prodDraft.adminSecret)
        } catch {
            errorMessage =
                "Could not save environment settings: \(error.localizedDescription)"
            return
        }

        settingsStore.saveCaptureFrameRate(captureFrameRate)
        settingsStore.saveOptimizeUploads(optimizeUploads)

        AppLog.info(
            "Settings saved. Active environment: \(activeEnvironment.displayName). Dev backend: \(KoomConfig.backendURL(for: .dev)?.absoluteString ?? "unset"), Prod backend: \(KoomConfig.backendURL(for: .prod)?.absoluteString ?? "unset"), active backend: \(effectiveActiveBackendURL.absoluteString), compression: \(CompressionSettings(captureFrameRate: captureFrameRate, optimizeUploads: optimizeUploads).logDescription)."
        )
        closeSettingsWindow()
    }

    private func normalizedBackendURL(
        _ rawValue: String,
        for environment: KoomEnvironment
    ) throws -> URL? {
        let trimmedURL = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            return nil
        }

        guard let url = URL(string: trimmedURL),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host != nil
        else {
            throw ValidationError(
                message:
                    "\(environment.displayName) backend URL must be a valid http:// or https:// URL."
            )
        }

        if url.absoluteString.hasSuffix("/") {
            return URL(string: String(url.absoluteString.dropLast())) ?? url
        }
        return url
    }

    private func saveSecret(
        _ rawSecret: String,
        for environment: KoomEnvironment
    ) throws {
        let secret = normalizedSecret(rawSecret)
        if secret.isEmpty {
            try KoomConfig.clearAdminSecret(for: environment)
        } else {
            try KoomConfig.saveAdminSecret(secret, for: environment)
        }
    }

    private func normalizedSecret(_ rawSecret: String) -> String {
        rawSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func recordingsDirectoryPath(
        for environment: KoomEnvironment
    ) -> String {
        NSString(
            string: RecordingSessionStore.recordingsDirectoryURL(for: environment)
                .path
        ).abbreviatingWithTildeInPath
    }

    private func captureSettingsWindow(_ window: NSWindow) {
        guard settingsWindow !== window else {
            return
        }

        settingsWindow = window
    }

    private func closeSettingsWindow() {
        if let settingsWindow {
            settingsWindow.performClose(nil)
            return
        }

        NSApp.keyWindow?.performClose(nil)
    }
}
