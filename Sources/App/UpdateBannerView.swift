import SwiftUI
import PortForwardingLib

struct UpdateBannerView: View {
    @ObservedObject var updateChecker: UpdateChecker
    var compact: Bool = false
    var onBeforeUpdate: () -> Void = {}

    var body: some View {
        if let update = updateChecker.availableUpdate {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)

                if compact {
                    Text("v\(update.version) available")
                        .font(.caption)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Version \(update.version) available")
                            .font(.callout)
                            .fontWeight(.medium)
                        Text("Current: v\(updateChecker.currentVersion)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if updateChecker.isDownloading {
                    ProgressView()
                        .controlSize(.small)
                    Text("Updating...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(action: {
                        onBeforeUpdate()
                        Task { await updateChecker.downloadAndInstall() }
                    }) {
                        Text("Update")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .buttonStyle(.bordered)
                    .tint(.blue)
                }
            }
            .padding(compact ? 8 : 12)
            .background(.blue.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        if let error = updateChecker.error {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Retry") {
                    Task { await updateChecker.checkForUpdate() }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
            .padding(compact ? 8 : 12)
        }
    }
}
