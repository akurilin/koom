import AppKit
import SwiftUI

struct ControlPanelView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("koom")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text("Local screen recorder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Refresh") {
                    model.refreshHardware()
                }
                .disabled(model.isBusy)

                SettingsLink {
                    Image(systemName: "gearshape.fill")
                        .imageScale(.medium)
                }
                .buttonStyle(.borderless)
                .help("Open Settings")
                .accessibilityLabel("Open Settings")
            }

            VStack(alignment: .leading, spacing: 8) {
                Picker("Monitor", selection: $model.selectedDisplayID) {
                    ForEach(model.displays) { display in
                        Text(display.name).tag(display.id)
                    }
                }
                .onChange(of: model.selectedDisplayID) {
                    model.displaySelectionDidChange()
                }

                Picker("Camera", selection: $model.selectedCameraID) {
                    Text("None").tag("")
                    ForEach(model.cameras) { camera in
                        Text(camera.name).tag(camera.id)
                    }
                }
                .onChange(of: model.selectedCameraID) {
                    model.cameraSelectionDidChange()
                }

                Picker("Microphone", selection: $model.selectedMicrophoneID) {
                    Text("None").tag("")
                    ForEach(model.microphones) { microphone in
                        Text(microphone.name).tag(microphone.id)
                    }
                }
                .onChange(of: model.selectedMicrophoneID) {
                    model.microphoneSelectionDidChange()
                }
            }
            .disabled(model.recordingState != .idle || model.isBusy)

            HStack(spacing: 10) {
                Button(model.recordingState == .idle ? "Start" : "Restart") {
                    if model.recordingState == .idle {
                        model.startRecording()
                    } else {
                        model.restartRecording()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy || model.displays.isEmpty)

                if model.recordingState != .idle {
                    Button(model.recordingState == .paused ? "Resume" : "Pause") {
                        model.togglePause()
                    }
                    .disabled(model.isBusy)

                    Button("Stop") {
                        model.stopRecording()
                    }
                    .disabled(model.isBusy)
                }
            }
            .buttonStyle(.borderedProminent)

            VStack(alignment: .leading, spacing: 6) {
                Text(model.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.primary)

                if let lastRecordingURL = model.lastRecordingURL {
                    Text(lastRecordingURL.path)
                        .font(.caption2.monospaced())
                        .lineLimit(2)
                        .foregroundStyle(.secondary)

                    Button("Reveal Last File") {
                        model.revealLastRecording()
                    }
                    .disabled(model.isBusy)
                }

                CatchUpStatusView(state: model.catchUpState)
                UploadStatusView(state: model.uploadState)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 360, height: 380)
        .background(
            WindowAccessor { window in
                model.configureControlWindow(window)
            })
    }
}

/// Renders the current upload state — spinner/text for the
/// indeterminate phases, a real progress bar while bytes are
/// streaming to R2, and a success or failure affordance at the end.
/// Shows nothing at all when `state == .idle` so the control panel
/// layout doesn't jitter between recordings.
private struct UploadStatusView: View {
    let state: UploadState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()

        case .preparing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Preparing upload…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)

        case .optimizing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Optimizing upload copy…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)

        case .initializing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Starting upload…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)

        case .uploading(let progress):
            VStack(alignment: .leading, spacing: 4) {
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
            .padding(.top, 4)

        case .finalizing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Finalizing upload…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)

        case .postProcessing(let stage):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(postProcessingDescription(stage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)

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
            .padding(.top, 4)

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
            .padding(.top, 4)
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
        case .generatingThumbnail:
            return
                "Upload finished. Generating a JPEG thumbnail from the recording…"
        case .uploadingThumbnail:
            return
                "Upload finished. Uploading the generated thumbnail…"
        }
    }
}

/// Renders the batch-catch-up state. Lives above the per-file
/// `UploadStatusView` in the control panel so the user can see
/// both "Catching up 2 of 5: foo.mp4" and the progress bar for
/// the currently-uploading file at the same time. Shows nothing
/// when `state == .idle` so the layout doesn't reserve space
/// outside active catch-up sessions.
private struct CatchUpStatusView: View {
    let state: CatchUpState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()

        case .scanning:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Scanning local recordings…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)

        case .diffing(let localCount):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking \(localCount) file\(localCount == 1 ? "" : "s") against the server…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)

        case .noMissingFiles(let localCount):
            Text("All caught up — \(localCount) recording\(localCount == 1 ? " is" : "s are") already uploaded.")
                .font(.caption)
                .foregroundStyle(.green)
                .padding(.top, 4)

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
            .padding(.top, 4)

        case .completed(let uploaded, let total):
            if total == 0 {
                Text("No local recordings to sync.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else {
                Text("Catch-up complete — uploaded \(uploaded) of \(total).")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .padding(.top, 4)
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
            .padding(.top, 4)
        }
    }
}
