import AppKit
import SwiftUI

struct ControlPanelView: View {
    @EnvironmentObject private var model: AppModel

    private let panelBackgroundTop = Color(
        red: 0.98,
        green: 0.97,
        blue: 0.94
    )
    private let panelBackgroundBottom = Color(
        red: 0.96,
        green: 0.95,
        blue: 0.91
    )
    private let surfaceFill = Color.white.opacity(0.74)
    private let surfaceStroke = Color.black.opacity(0.06)
    private let rowFill = Color(red: 0.95, green: 0.94, blue: 0.90)
    private let rowStroke = Color.black.opacity(0.04)
    private let accentRed = Color(red: 0.93, green: 0.26, blue: 0.23)

    private var displayOptions: [SourceMenuOption<CGDirectDisplayID>] {
        model.displays.map { display in
            SourceMenuOption(value: display.id, title: display.name)
        }
    }

    private var cameraOptions: [SourceMenuOption<String>] {
        [SourceMenuOption(value: "", title: "None")]
            + model.cameras.map { camera in
                SourceMenuOption(value: camera.id, title: camera.name)
            }
    }

    private var microphoneOptions: [SourceMenuOption<String>] {
        [SourceMenuOption(value: "", title: "None")]
            + model.microphones.map { microphone in
                SourceMenuOption(value: microphone.id, title: microphone.name)
            }
    }

    private var canEditSources: Bool {
        model.recordingState == .idle && !model.isBusy
    }

    private var canTriggerPrimaryAction: Bool {
        if model.recordingState == .idle {
            return !model.isBusy && !model.displays.isEmpty
        }

        return !model.isBusy
    }

    private var primaryButtonTitle: String {
        model.recordingState == .idle ? "Start recording" : "Stop recording"
    }

    private var footerStatus: (title: String, color: Color) {
        switch model.recordingState {
        case .recording:
            return ("Recording", accentRed)
        case .paused:
            return ("Paused", Color(red: 0.84, green: 0.53, blue: 0.15))
        case .idle:
            break
        }

        switch model.uploadState {
        case .failed:
            return ("Upload failed", accentRed)
        case .idle:
            break
        case .completed:
            return ("Uploaded", Color(red: 0.18, green: 0.68, blue: 0.33))
        default:
            return ("Uploading", Color(red: 0.24, green: 0.49, blue: 0.90))
        }

        switch model.catchUpState {
        case .failed:
            return ("Sync error", accentRed)
        case .idle:
            break
        case .completed, .noMissingFiles:
            return ("Ready", Color(red: 0.18, green: 0.68, blue: 0.33))
        default:
            return ("Syncing", Color(red: 0.24, green: 0.49, blue: 0.90))
        }

        if model.isBusy {
            return ("Working", Color(red: 0.24, green: 0.49, blue: 0.90))
        }

        return ("Ready", Color(red: 0.18, green: 0.68, blue: 0.33))
    }

    private var detailStatusMessage: String? {
        if model.statusMessage == "Ready." || model.statusMessage == "Paused." {
            return nil
        }

        if model.uploadState != .idle || model.catchUpState != .idle {
            return nil
        }

        return model.statusMessage
    }

    private var showsDetailCard: Bool {
        detailStatusMessage != nil
            || model.lastRecordingURL != nil
            || model.uploadState != .idle
            || model.catchUpState != .idle
    }

    private var selectedDisplayTitle: String {
        model.displays.first(where: { $0.id == model.selectedDisplayID })?.name
            ?? (model.displays.isEmpty ? "No display found" : "Choose display")
    }

    private var selectedCameraTitle: String {
        if model.selectedCameraID.isEmpty {
            return "None"
        }

        return model.cameras.first(where: { $0.id == model.selectedCameraID })?.name
            ?? "Unavailable"
    }

    private var selectedMicrophoneTitle: String {
        if model.selectedMicrophoneID.isEmpty {
            return "None"
        }

        return model.microphones.first(where: { $0.id == model.selectedMicrophoneID })?.name
            ?? "Unavailable"
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [panelBackgroundTop, panelBackgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 18) {
                header

                VStack(spacing: 12) {
                    SourceMenuRow(
                        icon: "display",
                        label: "Display",
                        selectionTitle: selectedDisplayTitle,
                        options: displayOptions,
                        fill: rowFill,
                        stroke: rowStroke,
                        isEnabled: canEditSources
                    ) { selection in
                        model.selectedDisplayID = selection
                        model.displaySelectionDidChange()
                    }

                    SourceMenuRow(
                        icon: "video.fill",
                        label: "Camera",
                        selectionTitle: selectedCameraTitle,
                        options: cameraOptions,
                        fill: rowFill,
                        stroke: rowStroke,
                        isEnabled: canEditSources
                    ) { selection in
                        model.selectedCameraID = selection
                        model.cameraSelectionDidChange()
                    }

                    SourceMenuRow(
                        icon: "mic.fill",
                        label: "Microphone",
                        selectionTitle: selectedMicrophoneTitle,
                        options: microphoneOptions,
                        fill: rowFill,
                        stroke: rowStroke,
                        isEnabled: canEditSources
                    ) { selection in
                        model.selectedMicrophoneID = selection
                        model.microphoneSelectionDidChange()
                    }
                }

                primaryRecordButton

                if model.recordingState != .idle {
                    secondaryControls
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer(minLength: 0)

                VStack(spacing: 12) {
                    statusFooter

                    if showsDetailCard {
                        detailCard
                            .transition(
                                .move(edge: .bottom).combined(with: .opacity)
                            )
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 28)
            .padding(.bottom, 20)
        }
        .frame(width: 430, height: 520)
        .background(
            WindowAccessor { window in
                model.configureControlWindow(window)
            }
        )
        .animation(.snappy(duration: 0.24), value: model.recordingState)
        .animation(.snappy(duration: 0.24), value: model.uploadState)
        .animation(.snappy(duration: 0.24), value: model.catchUpState)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("koom")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .tracking(-1.2)
                Text("Local screen recorder")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.66))
            }

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                Button {
                    model.refreshHardware()
                } label: {
                    ToolbarIcon(symbol: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                .help("Refresh displays and devices")
                .accessibilityLabel("Refresh hardware")

                SettingsLink {
                    ToolbarIcon(symbol: "gearshape")
                }
                .buttonStyle(.plain)
                .help("Open Settings")
                .accessibilityLabel("Open Settings")
            }
        }
    }

    private var primaryRecordButton: some View {
        Button {
            if model.recordingState == .idle {
                model.startRecording()
            } else {
                model.stopRecording()
            }
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(.white)
                    .frame(width: 12, height: 12)

                Text(primaryButtonTitle)
                    .font(.system(size: 20, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                accentRed,
                                accentRed.opacity(0.94),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12))
            }
            .shadow(color: accentRed.opacity(0.28), radius: 18, x: 0, y: 10)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .disabled(!canTriggerPrimaryAction)
        .opacity(canTriggerPrimaryAction ? 1 : 0.56)
    }

    private var secondaryControls: some View {
        HStack(spacing: 10) {
            Button(model.recordingState == .paused ? "Resume" : "Pause") {
                model.togglePause()
            }
            .disabled(model.isBusy)

            Button("Restart") {
                model.restartRecording()
            }
            .disabled(model.isBusy)
        }
        .buttonStyle(ControlPanelCapsuleButtonStyle())
    }

    private var statusFooter: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(footerStatus.color)
                .frame(width: 8, height: 8)

            Text(footerStatus.title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
    }

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let detailStatusMessage {
                Text(detailStatusMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let lastRecordingURL = model.lastRecordingURL {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Last recording")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("Reveal") {
                            model.revealLastRecording()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .disabled(model.isBusy)
                    }

                    Text(lastRecordingURL.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            if model.catchUpState != .idle {
                CatchUpStatusView(state: model.catchUpState)
            }

            if model.uploadState != .idle {
                UploadStatusView(state: model.uploadState)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(surfaceFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(surfaceStroke)
        }
        .shadow(color: .black.opacity(0.05), radius: 14, x: 0, y: 8)
    }
}

private struct SourceMenuOption<Value: Hashable>: Hashable, Identifiable {
    let value: Value
    let title: String

    var id: String {
        "\(title)-\(String(describing: value))"
    }
}

private struct SourceMenuRow<Value: Hashable>: View {
    let icon: String
    let label: String
    let selectionTitle: String
    let options: [SourceMenuOption<Value>]
    let fill: Color
    let stroke: Color
    let isEnabled: Bool
    let onSelect: (Value) -> Void

    var body: some View {
        Menu {
            if options.isEmpty {
                Text("No options available")
            } else {
                ForEach(options) { option in
                    Button(option.title) {
                        onSelect(option.value)
                    }
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.62))
                    .frame(width: 22)

                Text(label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .frame(width: 90, alignment: .leading)

                Spacer(minLength: 12)

                Text(selectionTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(Color.primary.opacity(0.92))

                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.4))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 17)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(fill)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(stroke)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || options.isEmpty)
        .opacity((isEnabled && !options.isEmpty) ? 1 : 0.64)
    }
}

private struct ToolbarIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(Color.primary.opacity(0.72))
            .frame(width: 48, height: 48)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.62))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.06))
            }
            .shadow(color: .black.opacity(0.04), radius: 10, x: 0, y: 6)
    }
}

private struct ControlPanelCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.76))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.52 : 0.62))
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.black.opacity(0.06))
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// Renders the current upload state. Shows nothing at all when
/// `state == .idle` so the control panel layout stays compact.
private struct UploadStatusView: View {
    let state: UploadState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()

        case .preparing:
            statusRow("Preparing upload…")

        case .optimizing:
            statusRow("Optimizing upload copy…")

        case .initializing:
            statusRow("Starting upload…")

        case .uploading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Uploading")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: progress)
            }

        case .finalizing:
            statusRow("Finalizing upload…")

        case .postProcessing(let stage):
            statusRow(postProcessingDescription(stage))

        case .completed(let shareURL, let summary):
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    summary.usedOptimizedCopy
                        ? "Uploaded optimized copy. Share URL copied and opened."
                        : "Uploaded. Share URL copied and opened."
                )
                .font(.caption)
                .foregroundStyle(.green)

                Text(summaryDescription(summary))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(shareURL.absoluteString)
                    .font(.caption2.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 2) {
                Text("Upload failed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)

                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusRow(_ message: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func summaryDescription(_ summary: UploadCompletionSummary) -> String {
        let localSize = ByteCountFormatter.string(
            fromByteCount: summary.localSizeBytes,
            countStyle: .file
        )
        let uploadedSize = ByteCountFormatter.string(
            fromByteCount: summary.uploadedSizeBytes,
            countStyle: .file
        )

        guard summary.usedOptimizedCopy else {
            return "Uploaded size: \(uploadedSize). Local file remains \(localSize)."
        }

        let savingsPercent = Int((summary.savingsRatio * 100).rounded())
        return
            "Uploaded size: \(uploadedSize) from \(localSize) (\(savingsPercent)% smaller)."
    }

    private func postProcessingDescription(_ stage: PostUploadStage) -> String {
        switch stage {
        case .preparingOllama(let modelName):
            return
                "Upload finished. Preparing Ollama (\(modelName)) for local title generation…"
        case .extractingAudio:
            return
                "Upload finished. Extracting microphone audio for transcription…"
        case .transcribing(let modelName):
            return
                "Upload finished. Transcribing narration with Whisper (\(modelName))…"
        case .generatingTitle(let modelName):
            return
                "Upload finished. Generating a short title summary with Ollama (\(modelName))…"
        case .savingGeneratedTitle:
            return
                "Upload finished. Saving the generated title to the backend…"
        case .uploadingTranscript:
            return
                "Upload finished. Uploading word-level transcript…"
        case .generatingThumbnail:
            return
                "Upload finished. Generating a JPEG thumbnail from the recording…"
        case .uploadingThumbnail:
            return
                "Upload finished. Uploading the generated thumbnail…"
        }
    }
}

/// Renders the batch catch-up state. Shows nothing when
/// `state == .idle` so the panel only grows when a sync runs.
private struct CatchUpStatusView: View {
    let state: CatchUpState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()

        case .scanning:
            statusRow("Scanning local recordings…")

        case .diffing(let localCount):
            statusRow(
                "Checking \(localCount) file\(localCount == 1 ? "" : "s") against the server…"
            )

        case .noMissingFiles(let localCount):
            Text(
                "All caught up — \(localCount) recording\(localCount == 1 ? " is" : "s are") already uploaded."
            )
            .font(.caption)
            .foregroundStyle(.green)

        case .uploading(let currentIndex, let totalMissing, let currentFilename):
            VStack(alignment: .leading, spacing: 2) {
                Text("Catching up \(currentIndex) of \(totalMissing)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(currentFilename)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

        case .completed(let uploaded, let total):
            if total == 0 {
                Text("No local recordings to sync.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Catch-up complete — uploaded \(uploaded) of \(total).")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

        case .failed(let uploaded, let total, let message):
            VStack(alignment: .leading, spacing: 2) {
                Text("Catch-up finished with errors (\(uploaded) of \(total) uploaded)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)

                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusRow(_ message: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
