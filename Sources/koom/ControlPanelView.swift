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
