import SwiftUI

struct ServerStatusView: View {
    var viewModel: ServerViewModel

    var body: some View {
        NavigationStack {
            List {
                Section("Server Health") {
                    statusRow(
                        title: "Liveness",
                        value: viewModel.healthStatus ?? "Unknown",
                        isGood: viewModel.isHealthy
                    )
                    statusRow(
                        title: "Readiness",
                        value: viewModel.readyStatus ?? "Unknown",
                        isGood: viewModel.isReady
                    )
                }

                Section("Engine Info") {
                    if viewModel.isReady {
                        if let version = viewModel.paddleocrVersion {
                            LabeledContent("PaddleOCR", value: "v\(version)")
                        }
                        if let device = viewModel.yoloDevice {
                            LabeledContent("YOLO Device", value: device.uppercased())
                        }
                    } else {
                        Text("Waiting for server...")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Error") {
                    if let error = viewModel.errorMessage {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.callout)
                        }
                    } else {
                        Text("No errors")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Actions") {
                    Button {
                        Task { await viewModel.fetchMetrics() }
                    } label: {
                        Label("Fetch Prometheus Metrics", systemImage: "chart.bar")
                    }
                    .disabled(viewModel.isLoading)
                }

                Section("Metrics") {
                    if let metrics = viewModel.metricsText {
                        Text(metrics)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    } else {
                        Text("Tap button above to load metrics")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Server")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel.isLoading)
                }
            }
            .refreshable {
                await viewModel.refresh()
            }
            .task {
                await viewModel.refresh()
            }
        }
    }

    private func statusRow(title: String, value: String, isGood: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(isGood ? .green : .red)
                    .frame(width: 10, height: 10)
                Text(value)
                    .foregroundStyle(isGood ? .primary : .secondary)
            }
        }
    }
}
