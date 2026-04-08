import SwiftUI

/// Minimal two-field settings window that lets the user paste the
/// koom backend URL and admin secret.
///
/// Opened automatically on first run (from AppDelegate) when either
/// value is missing, and otherwise reachable via `Cmd+,` or the
/// "koom → Settings…" menu item. Both are wired for free by
/// SwiftUI's `Settings` scene — this view is what that scene hosts.
///
/// Persistence:
///
///   - Backend URL  → UserDefaults (via KoomConfig)
///   - Admin secret → Keychain     (via KoomConfig)
///
/// The view never tries to call the backend or validate the secret
/// online. Save just writes both values and closes. The doctor
/// script and the upload flow itself are where bad credentials
/// surface as actionable errors.
struct SettingsView: View {
    @State private var backendURLString: String = ""
    @State private var adminSecret: String = ""
    @State private var errorMessage: String?
    @State private var savedAt: Date?

    var body: some View {
        Form {
            Section {
                TextField("Backend URL", text: $backendURLString, prompt: Text("http://localhost:3000"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)

                SecureField("Admin secret", text: $adminSecret, prompt: Text("KOOM_ADMIN_SECRET"))
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("koom Backend")
                    .font(.headline)
            } footer: {
                Text("The backend URL and admin secret are the two values from your web/.env.local.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if let savedAt {
                Text("Saved at \(savedAt.formatted(date: .omitted, time: .standard)).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(backendURLString.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            loadFromStore()
        }
    }

    // MARK: - Actions

    private func loadFromStore() {
        backendURLString = KoomConfig.backendURL?.absoluteString ?? ""

        do {
            adminSecret = try KoomConfig.loadAdminSecret() ?? ""
        } catch {
            errorMessage = "Could not read admin secret from Keychain: \(error.localizedDescription)"
        }
    }

    private func save() {
        errorMessage = nil
        savedAt = nil

        let trimmedURL = backendURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            errorMessage = "Backend URL must be a valid http:// or https:// URL."
            return
        }

        // Strip any trailing slash so appendingPathComponent at call
        // sites produces clean results like `https://host/api/...`.
        let normalized: URL
        if url.absoluteString.hasSuffix("/") {
            normalized = URL(string: String(url.absoluteString.dropLast())) ?? url
        } else {
            normalized = url
        }
        KoomConfig.backendURL = normalized
        backendURLString = normalized.absoluteString

        let secret = adminSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if secret.isEmpty {
                try KoomConfig.clearAdminSecret()
            } else {
                try KoomConfig.saveAdminSecret(secret)
            }
        } catch {
            errorMessage = "Could not save admin secret to Keychain: \(error.localizedDescription)"
            return
        }

        savedAt = Date()
        AppLog.info("Settings saved. Backend: \(normalized.absoluteString), admin secret \(secret.isEmpty ? "cleared" : "set (\(secret.count) chars)").")
    }
}
