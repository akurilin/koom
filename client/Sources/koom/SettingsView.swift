import AppKit
import SwiftUI

/// Settings tab of the main panel: backend credentials, active
/// environment, and recording compression preferences.
///
/// Selected automatically on first run (from AppDelegate) when either
/// value is missing, and otherwise reachable via the panel's tab
/// picker or `Cmd+,` (rewired in KoomApp to switch to this tab).
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
    @State private var confirmationMessage: String?

    var body: some View {
        HuggingScrollView(maxHeight: 620) {
            VStack(alignment: .leading, spacing: 12) {
                settingsCard(header: "Active environment") {
                    Picker("Active environment", selection: $activeEnvironment) {
                        ForEach(KoomEnvironment.allCases) { environment in
                            Text(environment.displayName).tag(environment)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    footnote(
                        "New recordings and catch-up uploads use the active environment. Recordings live under \(recordingsDirectoryPath(for: activeEnvironment))."
                    )
                }

                settingsCard(header: "\(activeEnvironment.displayName) backend") {
                    fieldLabel("Backend URL")
                    TextField(
                        "Backend URL",
                        text: backendURLBinding,
                        prompt: Text(activeEnvironment.backendURLPrompt)
                    )
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)
                    .labelsHidden()

                    fieldLabel("Admin secret")
                    SecureField(
                        "Admin secret",
                        text: adminSecretBinding,
                        prompt: Text("KOOM_ADMIN_SECRET")
                    )
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()

                    footnote(backendSectionFooter)
                }

                settingsCard(header: "Compression") {
                    HStack {
                        Text("Capture cadence")
                            .font(.system(size: 13))

                        Spacer()

                        Picker("Capture cadence", selection: $captureFrameRate) {
                            ForEach(CaptureFrameRateOption.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }

                    Toggle(
                        "Optimize uploads with ffmpeg when available",
                        isOn: $optimizeUploads
                    )
                    .font(.system(size: 13))

                    footnote(
                        "15 fps usually shrinks static screen recordings with little quality cost. Upload optimization keeps the local recording untouched and only uploads a smaller MP4 when ffmpeg is installed and the re-encode is meaningfully smaller."
                    )
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    if let confirmationMessage {
                        Text(confirmationMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Save") {
                        save()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            loadFromStore()
        }
    }

    // MARK: - Card styling (matches the Recovery tab)

    private func settingsCard(
        header: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(header)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.72))

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.74))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.black.opacity(0.06))
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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

    private func save() {
        errorMessage = nil
        confirmationMessage = nil

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
        confirmationMessage = "Saved."
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

}
