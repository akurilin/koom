import AppKit
import SwiftUI

/// Settings tab of the main panel: backend credentials, active
/// environment, and recording compression preferences.
///
/// Reachable via the panel's tab picker or `Cmd+,` (rewired in
/// KoomApp to switch to this tab).
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
    @EnvironmentObject private var model: AppModel

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
    @State private var captureResolution: CaptureResolutionOption =
        CompressionSettings.default.captureResolution
    @State private var uploadRecordings: Bool =
        CompressionSettings.default.uploadRecordings
    @State private var optimizeRecordings: Bool =
        CompressionSettings.default.optimizeRecordings
    @State private var errorMessage: String?
    @State private var confirmationMessage: String?

    var body: some View {
        HuggingScrollView(maxHeight: 720) {
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

                settingsCard(header: "Recording quality") {
                    HStack {
                        Text("Resolution")
                            .font(.system(size: 13))

                        Spacer()

                        Picker("Resolution", selection: $captureResolution) {
                            ForEach(CaptureResolutionOption.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }

                    Toggle(
                        "Optimize recordings with ffmpeg when available",
                        isOn: $optimizeRecordings
                    )
                    .font(.system(size: 13))

                    footnote(
                        "koom captures directly at the selected maximum resolution while preserving the display's aspect ratio. 4K uses substantially more processing time, disk space, and upload bandwidth. ffmpeg optimization keeps the selected resolution."
                    )
                }

                LocalTitleModelsSettingsView(
                    manager: model.localTitleModelManager
                )

                settingsCard(header: "Upload") {
                    Toggle(
                        "Upload recordings to the backend",
                        isOn: $uploadRecordings
                    )
                    .font(.system(size: 13))

                    footnote(
                        "When upload is off, finalized recordings remain in the local recordings folder and no upload, transcription, thumbnail, or auto-title processing runs."
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
        captureResolution = compressionSettings.captureResolution
        uploadRecordings = compressionSettings.uploadRecordings
        optimizeRecordings = compressionSettings.optimizeRecordings

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

        guard !uploadRecordings || effectiveActiveBackendURL != nil else {
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

        settingsStore.saveCaptureResolution(captureResolution)
        settingsStore.saveUploadRecordings(uploadRecordings)
        settingsStore.saveOptimizeRecordings(optimizeRecordings)

        AppLog.info(
            "Settings saved. Active environment: \(activeEnvironment.displayName). Dev backend: \(KoomConfig.backendURL(for: .dev)?.absoluteString ?? "unset"), Prod backend: \(KoomConfig.backendURL(for: .prod)?.absoluteString ?? "unset"), active backend: \(effectiveActiveBackendURL?.absoluteString ?? "unset"), compression: \(CompressionSettings(captureResolution: captureResolution, uploadRecordings: uploadRecordings, optimizeRecordings: optimizeRecordings).logDescription)."
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

private struct LocalTitleModelsSettingsView: View {
    @ObservedObject var manager: LocalTitleModelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Local title generation")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.72))

            Toggle(
                "Enable local title generation",
                isOn: Binding(
                    get: { manager.isEnabled },
                    set: { manager.setEnabled($0) }
                )
            )
            .font(.system(size: 13))

            if let catalogIssue = manager.catalogIssue {
                Text(catalogIssue)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(manager.models) { titleModel in
                    modelRow(titleModel)

                    if titleModel.id != manager.models.last?.id {
                        Divider()
                    }
                }

                Text(
                    "The selected model downloads from Hugging Face once, then title generation stays on this Mac and works offline. If a recording finishes before the model is ready, only that recording's title is skipped."
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
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

    private func modelRow(_ titleModel: LocalTitleModel) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(titleModel.displayName)
                        .font(.system(size: 13, weight: .medium))

                    if titleModel.id == manager.selectedModelID {
                        Text("Selected")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color.black.opacity(0.06))
                            )
                    }
                }

                Text(
                    "\(titleModel.summary) \(titleModel.formattedDownloadSize) · \(titleModel.quantization) · \(titleModel.license)"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

                statusText(for: titleModel)
                    .font(.system(size: 10))
                    .foregroundStyle(statusColor(for: titleModel))
                    .lineLimit(2)
            }

            Spacer()

            modelAction(for: titleModel)

            Menu {
                if canManageDownloadedFile(titleModel) {
                    Button("Redownload") {
                        manager.redownload(titleModel)
                    }
                    Button("Delete", role: .destructive) {
                        manager.delete(titleModel)
                    }
                    Divider()
                }
                Button("View model source") {
                    NSWorkspace.shared.open(titleModel.sourceURL)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    @ViewBuilder
    private func modelAction(for titleModel: LocalTitleModel) -> some View {
        switch manager.state(for: titleModel) {
        case .downloading, .verifying, .starting:
            ProgressView()
                .controlSize(.small)
                .frame(width: 54)
        case .ready where titleModel.id == manager.selectedModelID:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .frame(width: 54)
                .accessibilityLabel("Ready")
        default:
            Button(actionLabel(for: titleModel)) {
                manager.use(titleModel)
            }
            .controlSize(.small)
        }
    }

    private func actionLabel(for titleModel: LocalTitleModel) -> String {
        switch manager.state(for: titleModel) {
        case .downloaded, .ready:
            return "Use"
        default:
            return "Download"
        }
    }

    private func statusText(for titleModel: LocalTitleModel) -> Text {
        switch manager.state(for: titleModel) {
        case .notDownloaded:
            return Text("Not downloaded")
        case .downloaded:
            return Text("Downloaded")
        case .downloading:
            return Text("Downloading…")
        case .verifying:
            return Text("Verifying download…")
        case .starting:
            return Text("Starting local model…")
        case .ready:
            return Text("Ready")
        case .failed(let message):
            return Text(message)
        }
    }

    private func statusColor(for titleModel: LocalTitleModel) -> Color {
        if case .failed = manager.state(for: titleModel) {
            return .red
        }
        return .secondary
    }

    private func canManageDownloadedFile(
        _ titleModel: LocalTitleModel
    ) -> Bool {
        switch manager.state(for: titleModel) {
        case .downloaded, .ready, .failed:
            return true
        default:
            return false
        }
    }
}
