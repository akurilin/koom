import AppKit
import SwiftUI

/// Settings card for choosing and managing noise removal models. Laid out
/// like the local title models card.
struct NoiseRemovalSettingsView: View {
    @ObservedObject var manager: NoiseRemovalManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Noise removal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.72))

            ForEach(manager.options) { option in
                optionRow(option)

                if option.id != manager.options.last?.id {
                    Divider()
                }
            }

            Text(
                "Runs on this Mac after each recording, before upload. Every option also evens out the volume. Models download once and then work offline; until the selected one is ready, recordings use Apple Voice Isolation."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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

    private func optionRow(_ option: NoiseRemovalOption) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(option.displayName)
                        .font(.system(size: 13, weight: .medium))

                    if option.id == manager.selectedOptionID {
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

                Text(summary(for: option))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let status = statusText(for: option) {
                    status
                        .font(.system(size: 10))
                        .foregroundStyle(statusColor(for: option))
                        .lineLimit(3)
                }
            }

            Spacer()

            action(for: option)

            if option.needsInstall || option.sourceURL != nil {
                Menu {
                    if option.needsInstall {
                        switch manager.state(for: option) {
                        case .installed, .failed:
                            Button("Reinstall") {
                                manager.reinstall(option)
                            }
                            Button("Delete", role: .destructive) {
                                manager.delete(option)
                            }
                            Divider()
                        case .installing:
                            Button("Cancel and delete", role: .destructive) {
                                manager.delete(option)
                            }
                            Divider()
                        case .notInstalled:
                            EmptyView()
                        }
                    }
                    if let sourceURL = option.sourceURL {
                        Button("View model source") {
                            NSWorkspace.shared.open(sourceURL)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private func action(for option: NoiseRemovalOption) -> some View {
        let isSelected = option.id == manager.selectedOptionID
        switch manager.state(for: option) {
        case .installing:
            ProgressView()
                .controlSize(.small)
                .frame(width: 54)
        case .installed where isSelected:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .frame(width: 54)
                .accessibilityLabel("Selected and ready")
        case .installed:
            Button("Use") {
                manager.use(option)
            }
            .controlSize(.small)
        case .notInstalled, .failed:
            Button(isSelected ? "Retry" : "Download") {
                manager.use(option)
            }
            .controlSize(.small)
        }
    }

    private func summary(for option: NoiseRemovalOption) -> String {
        guard let downloadSize = option.downloadSize else {
            return option.summary
        }
        return "\(option.summary) \(downloadSize)."
    }

    private func statusText(for option: NoiseRemovalOption) -> Text? {
        guard option.needsInstall else { return nil }
        switch manager.state(for: option) {
        case .notInstalled:
            return Text("Not downloaded")
        case .installing(let stage):
            return Text(stage)
        case .installed:
            return Text("Ready")
        case .failed(let message):
            return Text(message)
        }
    }

    private func statusColor(for option: NoiseRemovalOption) -> Color {
        if case .failed = manager.state(for: option) {
            return .red
        }
        return .secondary
    }
}
