// shows last 100 capture cycles with timing and thumbnails
import SwiftUI

struct ActivityLogView: View {
    let activityLog: ActivityLog

    var body: some View {
        Group {
            if activityLog.entries.isEmpty {
                ContentUnavailableView(
                    "No Activity",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Start the capture loop to see activity here.")
                )
            } else {
                List {
                    ForEach(activityLog.entries) { entry in
                        entryRow(entry)
                    }
                }
            }
        }
        .navigationTitle("Activity Log")
        .toolbar {
            if !activityLog.entries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") { activityLog.clear() }
                }
            }
        }
    }

    private func entryRow(_ entry: ActivityLog.Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: timestamp + engine
            HStack {
                Text(entry.timestamp, style: .time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(entry.engine)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(entry.engine == "Server" ? Color.blue.opacity(0.12) : Color.purple.opacity(0.12))
                    .foregroundStyle(entry.engine == "Server" ? .blue : .purple)
                    .cornerRadius(4)
            }

            // Image thumbnail
            if let image = entry.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 120)
                    .cornerRadius(6)
            }

            // Error
            if let error = entry.error {
                Label(error, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // Results
            if !entry.isError {
                if let guidance = entry.guidance {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                        Text(guidance)
                            .font(.caption)
                    }
                }

                if !entry.objects.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "eye.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                        Text("\(entry.objectCount) objects: \(entry.objects)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Timing
                HStack(spacing: 12) {
                    timingLabel("Capture", ms: entry.captureMs, color: .blue)
                    timingLabel("Process", ms: entry.processMs, color: .orange)
                    timingLabel("Total", ms: entry.totalMs, color: .primary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func timingLabel(_ label: String, ms: Double, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text("\(Int(ms))ms")
                .font(.system(size: 9, design: .monospaced).bold())
                .foregroundStyle(color)
        }
    }
}
