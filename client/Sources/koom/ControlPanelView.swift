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
            }

            VStack(alignment: .leading, spacing: 8) {
                Picker("Monitor", selection: $model.selectedDisplayID) {
                    ForEach(model.displays) { display in
                        Text(display.name).tag(display.id)
                    }
                }
                .onChange(of: model.selectedDisplayID) { _ in
                    model.displaySelectionDidChange()
                }

                Picker("Camera", selection: $model.selectedCameraID) {
                    Text("None").tag("")
                    ForEach(model.cameras) { camera in
                        Text(camera.name).tag(camera.id)
                    }
                }
                .onChange(of: model.selectedCameraID) { _ in
                    model.cameraSelectionDidChange()
                }

                Picker("Microphone", selection: $model.selectedMicrophoneID) {
                    Text("None").tag("")
                    ForEach(model.microphones) { microphone in
                        Text(microphone.name).tag(microphone.id)
                    }
                }
                .onChange(of: model.selectedMicrophoneID) { _ in
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

                UploadStatusView(state: model.uploadState)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 360, height: 380)
        .background(WindowAccessor { window in
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

        case .completed(let shareURL):
            VStack(alignment: .leading, spacing: 4) {
                Text("Uploaded. Share URL copied and opened.")
                    .font(.caption)
                    .foregroundStyle(.green)
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
}
