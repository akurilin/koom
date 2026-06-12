import SwiftUI

/// Recovery tab: surfaces recordings whose state machine got stuck —
/// interrupted sessions that were never finalized, and local files
/// that never made it to the server. Replaces the launch-time NSAlert
/// chain so nothing is lost and nothing blocks startup.
struct RecoveryView: View {
    @EnvironmentObject private var model: AppModel

    private let cardFill = Color.white.opacity(0.74)
    private let cardStroke = Color.black.opacity(0.06)

    private var canActOnSessions: Bool {
        model.recordingState == .idle && !model.isBusy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HuggingScrollView(maxHeight: 320) {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("Interrupted recordings")

                    if model.recoverableSessions.isEmpty {
                        Text("No interrupted recordings. Sessions that crash or lose power mid-recording will show up here.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(model.recoverableSessions) { session in
                            sessionCard(session)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            catchUpSection
        }
        .onAppear {
            model.refreshRecoverableSessions()
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.72))
    }

    private func sessionCard(_ session: RecordingSessionStore.SessionHandle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.session.finalFilename)
                .font(.system(size: 12, weight: .semibold).monospaced())
                .lineLimit(1)
                .truncationMode(.middle)

            Text(sessionSubtitle(session))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Resume") {
                    model.resumeRecoverableSession(session)
                }
                .help("Continue recording where this session left off")

                Button(
                    model.uploadRecordingsEnabled
                        ? "Finish & upload"
                        : "Finish locally"
                ) {
                    model.finishRecoverableSession(session)
                }
                .help(
                    model.uploadRecordingsEnabled
                        ? "Assemble the partial recording and upload it"
                        : "Assemble the partial recording and keep it locally"
                )

                Spacer()

                Button("Discard", role: .destructive) {
                    model.discardRecoverableSession(session)
                }
                .help("Delete this session's segments permanently")
            }
            .controlSize(.small)
            .disabled(!canActOnSessions)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(cardFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(cardStroke)
        }
    }

    private func sessionSubtitle(_ session: RecordingSessionStore.SessionHandle) -> String {
        let segmentCount = session.session.segments.count
        let segments = "\(segmentCount) segment\(segmentCount == 1 ? "" : "s")"
        let lastActive = session.session.updatedAt.formatted(
            date: .abbreviated,
            time: .shortened
        )
        return "\(session.environment.displayName) · \(segments) · last active \(lastActive)"
    }

    private var catchUpSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Unsent recordings")

            Text(
                model.uploadRecordingsEnabled
                    ? "Compares local recordings for the active environment against the server and uploads anything missing."
                    : "Backend uploads are disabled in Settings. Local recordings will not be synced."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Button("Sync unsent recordings") {
                model.catchUpRecordings()
            }
            .disabled(
                !model.uploadRecordingsEnabled
                    || model.isCatchingUp
                    || model.isBusy
                    || model.recordingState != .idle
            )

            if model.catchUpState != .idle {
                CatchUpStatusView(state: model.catchUpState)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(cardFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(cardStroke)
        }
    }
}
