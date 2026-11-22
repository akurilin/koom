import AppKit
import AuthenticationServices
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
///   - Device credentials    → Keychain     (via KoomConfig), obtained
///                             by signing in with Google (DeviceSignIn)
///   - Compression settings  → UserDefaults (via AppSettingsStore)
///
/// Apart from signing in and out, the view never calls the backend.
/// Changes persist automatically. The upload flow is where a revoked
/// sign-in surfaces as an actionable error.
struct SettingsView: View {
    private struct EnvironmentDraft {
        var backendURLString: String
    }

    private let settingsStore = AppSettingsStore()
    @EnvironmentObject private var model: AppModel

    @State private var activeEnvironment: KoomEnvironment =
        KoomConfig.activeEnvironment
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var devDraft = EnvironmentDraft(backendURLString: "")
    @State private var prodDraft = EnvironmentDraft(backendURLString: "")
    @State private var credentials: [KoomEnvironment: KoomConfig.DeviceCredential] = [:]
    @State private var isSigningIn = false
    @State private var accountError: String?
    @State private var captureResolution: CaptureResolutionOption =
        CompressionSettings.default.captureResolution
    @State private var uploadRecordings: Bool =
        CompressionSettings.default.uploadRecordings
    @State private var optimizeRecordings: Bool =
        CompressionSettings.default.optimizeRecordings
    @State private var dirtyBackendURLs: Set<KoomEnvironment> = []
    @State private var backendURLSaveTasks: [KoomEnvironment: Task<Void, Never>] = [:]

    var body: some View {
        HuggingScrollView(maxHeight: 720) {
            VStack(alignment: .leading, spacing: 12) {
                settingsCard(header: "Active environment") {
                    Picker("Active environment", selection: activeEnvironmentBinding) {
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
                    .onSubmit {
                        flushPendingTextSettings(for: activeEnvironment)
                    }

                    fieldLabel("Account")
                    accountRow

                    footnote(backendSectionFooter)
                }

                settingsCard(header: "Recording quality") {
                    HStack {
                        Text("Resolution")
                            .font(.system(size: 13))

                        Spacer()

                        Picker("Resolution", selection: captureResolutionBinding) {
                            ForEach(CaptureResolutionOption.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }

                    Toggle(
                        "Optimize recordings with ffmpeg when available",
                        isOn: optimizeRecordingsBinding
                    )
                    .font(.system(size: 13))

                    footnote(
                        "koom captures directly at the selected maximum resolution while preserving the display's aspect ratio. 4K uses substantially more processing time, disk space, and upload bandwidth. ffmpeg optimization keeps the selected resolution."
                    )
                }

                NoiseRemovalSettingsView(
                    manager: model.noiseRemovalManager
                )

                LocalTitleModelsSettingsView(
                    manager: model.localTitleModelManager
                )

                settingsCard(header: "Upload") {
                    Toggle(
                        "Upload recordings to the backend",
                        isOn: uploadRecordingsBinding
                    )
                    .font(.system(size: 13))

                    footnote(
                        "When upload is off, finalized recordings remain in the local recordings folder and no upload, transcription, thumbnail, or auto-title processing runs."
                    )
                }

                if let errorMessage = displayedErrorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Changes are saved automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            loadFromStore()
        }
        .onDisappear {
            flushAllPendingTextSettings()
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

    private var activeEnvironmentBinding: Binding<KoomEnvironment> {
        Binding(
            get: { activeEnvironment },
            set: { newValue in
                guard newValue != activeEnvironment else { return }

                flushPendingTextSettings(for: activeEnvironment)
                activeEnvironment = newValue
                KoomConfig.activeEnvironment = newValue
                AppLog.info(
                    "Settings automatically saved active environment: \(newValue.displayName)."
                )
            }
        )
    }

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
                let environment = activeEnvironment
                switch activeEnvironment {
                case .dev:
                    devDraft.backendURLString = newValue
                case .prod:
                    prodDraft.backendURLString = newValue
                }
                dirtyBackendURLs.insert(environment)
                scheduleBackendURLPersistence(for: environment)
            }
        )
    }

    private var captureResolutionBinding: Binding<CaptureResolutionOption> {
        Binding(
            get: { captureResolution },
            set: { newValue in
                captureResolution = newValue
                settingsStore.saveCaptureResolution(newValue)
                AppLog.info(
                    "Settings automatically saved capture resolution: \(newValue.rawValue)."
                )
            }
        )
    }

    private var optimizeRecordingsBinding: Binding<Bool> {
        Binding(
            get: { optimizeRecordings },
            set: { newValue in
                optimizeRecordings = newValue
                settingsStore.saveOptimizeRecordings(newValue)
                AppLog.info(
                    "Settings automatically saved recording optimization: \(newValue)."
                )
            }
        )
    }

    private var uploadRecordingsBinding: Binding<Bool> {
        Binding(
            get: { uploadRecordings },
            set: { newValue in
                uploadRecordings = newValue
                settingsStore.saveUploadRecordings(newValue)
                AppLog.info(
                    "Settings automatically saved backend uploads: \(newValue)."
                )
            }
        )
    }

    // MARK: - Derived text

    private var backendSectionFooter: String {
        switch activeEnvironment {
        case .dev:
            return
                "Leave the URL blank to use \(KoomEnvironment.dev.backendURLPrompt). Dev and Prod are signed in separately."
        case .prod:
            return
                "Use the deployed backend URL, then sign in with a Google account allowed on that deployment. Prod recordings are stored separately from Dev."
        }
    }

    private var displayedErrorMessage: String? {
        backendURLValidationMessage ?? accountError
    }

    private var backendURLValidationMessage: String? {
        let environment = activeEnvironment
        let rawValue =
            switch environment {
            case .dev:
                devDraft.backendURLString
            case .prod:
                prodDraft.backendURLString
            }

        do {
            let backendURL = try BackendURLSetting.normalizedURL(
                rawValue,
                for: environment
            )
            let effectiveBackendURL =
                backendURL ?? environment.defaultBackendURL

            guard !uploadRecordings || effectiveBackendURL != nil else {
                return
                    "\(environment.displayName) backend URL must be a valid http:// or https:// URL."
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Actions

    private func loadFromStore() {
        cancelScheduledTextPersistence()
        dirtyBackendURLs.removeAll()
        accountError = nil

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
            for environment in KoomEnvironment.allCases {
                credentials[environment] = try KoomConfig.loadDeviceCredential(
                    for: environment
                )
            }
        } catch {
            accountError =
                "Could not read sign-in from Keychain: \(error.localizedDescription)"
        }
    }

    private func scheduleBackendURLPersistence(
        for environment: KoomEnvironment
    ) {
        backendURLSaveTasks[environment]?.cancel()
        backendURLSaveTasks[environment] = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            persistBackendURL(for: environment)
            backendURLSaveTasks[environment] = nil
        }
    }

    private func persistBackendURL(for environment: KoomEnvironment) {
        let rawValue =
            switch environment {
            case .dev:
                devDraft.backendURLString
            case .prod:
                prodDraft.backendURLString
            }

        let backendURL: URL?
        do {
            backendURL = try BackendURLSetting.normalizedURL(
                rawValue,
                for: environment
            )
        } catch {
            return
        }

        KoomConfig.setBackendURL(backendURL, for: environment)
        setBackendURLDraft(
            backendURL?.absoluteString ?? "",
            for: environment
        )
        dirtyBackendURLs.remove(environment)
        AppLog.info(
            "Settings automatically saved \(environment.displayName) backend URL: \(KoomConfig.backendURL(for: environment)?.absoluteString ?? "unset")."
        )
    }

    private func flushPendingTextSettings(
        for environment: KoomEnvironment
    ) {
        backendURLSaveTasks[environment]?.cancel()
        backendURLSaveTasks[environment] = nil

        if dirtyBackendURLs.contains(environment) {
            persistBackendURL(for: environment)
        }
    }

    private func flushAllPendingTextSettings() {
        for environment in KoomEnvironment.allCases {
            flushPendingTextSettings(for: environment)
        }
    }

    private func cancelScheduledTextPersistence() {
        for task in backendURLSaveTasks.values {
            task.cancel()
        }
        backendURLSaveTasks.removeAll()
    }

    private func setBackendURLDraft(
        _ value: String,
        for environment: KoomEnvironment
    ) {
        switch environment {
        case .dev:
            devDraft.backendURLString = value
        case .prod:
            prodDraft.backendURLString = value
        }
    }

    // MARK: - Account

    @ViewBuilder
    private var accountRow: some View {
        if let credential = credentials[activeEnvironment] {
            HStack {
                Text("Signed in as \(credential.email)")
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Sign out") {
                    Task { await signOut(of: activeEnvironment) }
                }
            }
        } else {
            Button(isSigningIn ? "Signing in…" : "Sign in with Google") {
                Task { await signIn(to: activeEnvironment) }
            }
            .disabled(isSigningIn || backendURLValidationMessage != nil)
        }
    }

    private func signIn(to environment: KoomEnvironment) async {
        flushPendingTextSettings(for: environment)
        guard let backendURL = KoomConfig.backendURL(for: environment) else {
            accountError = "Set the \(environment.displayName) backend URL first."
            return
        }

        isSigningIn = true
        accountError = nil
        defer { isSigningIn = false }

        let state = DeviceSignIn.makeState()
        do {
            let callbackURL = try await webAuthenticationSession.authenticate(
                using: DeviceSignIn.connectURL(
                    backendURL: backendURL,
                    state: state,
                    deviceName: DeviceSignIn.deviceName
                ),
                callback: .customScheme(DeviceSignIn.callbackScheme),
                preferredBrowserSession: .shared,
                additionalHeaderFields: [:]
            )
            switch try DeviceSignIn.parseCallback(callbackURL, expectedState: state) {
            case .signedIn(let credential):
                try KoomConfig.saveDeviceCredential(credential, for: environment)
                credentials[environment] = credential
                AppLog.info(
                    "Signed in to \(environment.displayName) as \(credential.email)."
                )
            case .cancelled:
                break
            }
        } catch ASWebAuthenticationSessionError.canceledLogin {
            // The user closed the sign-in window; nothing to report.
        } catch {
            accountError = "Sign-in failed: \(error.localizedDescription)"
        }
    }

    private func signOut(of environment: KoomEnvironment) async {
        guard let credential = credentials[environment] else { return }
        accountError = nil

        // Revoke server-side first so the token stops working, but
        // never let an unreachable server trap the user signed in.
        if let backendURL = KoomConfig.backendURL(for: environment) {
            do {
                try await KoomAPI(
                    backendURL: backendURL,
                    deviceToken: credential.token
                ).revokeDeviceToken()
            } catch {
                AppLog.error(
                    "Could not revoke the \(environment.displayName) device token: \(error.localizedDescription)"
                )
            }
        }

        do {
            try KoomConfig.clearDeviceCredential(for: environment)
            credentials[environment] = nil
            AppLog.info("Signed out of \(environment.displayName).")
        } catch {
            accountError = "Could not sign out: \(error.localizedDescription)"
        }
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

enum BackendURLSetting {
    private struct ValidationError: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    static func normalizedURL(
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
                    "The model downloads once and runs on this Mac. Uploads use the recording date when the model is unavailable."
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
