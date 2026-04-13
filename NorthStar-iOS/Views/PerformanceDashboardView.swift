// performance stats - latency gauges, pipeline breakdown etc
import SwiftUI

struct PerformanceDashboardView: View {
    let latencyMonitor: LatencyMonitor
    let autoCaptureLoop: AutoCaptureLoop

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(spacing: 20) {
                    successRing
                    captureStats
                }

                fullPipelineBreakdown
                networkLatency
                latencyRanges
                sessionInfo
            }
            .padding()
        }
        .navigationTitle("Performance")
    }


    private var successRing: some View {
        let rate = autoCaptureLoop.successRate / 100.0
        return VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color(.systemGray5), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: CGFloat(rate))
                    .stroke(
                        rate > 0.8 ? Color.green : rate > 0.5 ? Color.yellow : Color.red,
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(Int(autoCaptureLoop.successRate))%")
                        .font(.system(.title2, design: .rounded).bold())
                    Text("success")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 100, height: 100)
        }
        .accessibilityLabel("Success rate: \(Int(autoCaptureLoop.successRate)) percent")
    }


    private var captureStats: some View {
        VStack(alignment: .leading, spacing: 12) {
            iconStat(icon: "camera.fill", color: .blue, label: "Captures", value: "\(autoCaptureLoop.totalCaptures)")
            iconStat(icon: "checkmark.circle.fill", color: .green, label: "Processed", value: "\(autoCaptureLoop.totalProcessed)")
            iconStat(icon: "xmark.circle.fill", color: .red, label: "Errors", value: "\(autoCaptureLoop.totalErrors)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func iconStat(icon: String, color: Color, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 20)
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.subheadline.monospacedDigit().bold())
        }
        .accessibilityElement(children: .combine)
    }


    private var fullPipelineBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pipeline Latency")
                .font(.headline)

            if autoCaptureLoop.avgCycleMs > 0 {
                // Visual stacked bar
                let capRatio = autoCaptureLoop.avgCaptureMs / autoCaptureLoop.avgCycleMs
                let procRatio = autoCaptureLoop.avgProcessMs / autoCaptureLoop.avgCycleMs

                GeometryReader { geo in
                    HStack(spacing: 1) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.cyan)
                            .frame(width: Swift.max(4, geo.size.width * capRatio))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.orange)
                            .frame(width: Swift.max(4, geo.size.width * procRatio))
                    }
                }
                .frame(height: 24)
                .cornerRadius(6)

                // Legend
                VStack(spacing: 6) {
                    pipelineRow(color: .cyan, label: "Image Capture + Download",
                                detail: "Radxa takes photo, transfers JPEG to phone",
                                avg: autoCaptureLoop.avgCaptureMs,
                                last: autoCaptureLoop.lastTiming.captureMs)
                    pipelineRow(color: .orange, label: "Server Processing",
                                detail: "Upload to server, run detection, receive results",
                                avg: autoCaptureLoop.avgProcessMs,
                                last: autoCaptureLoop.lastTiming.processMs)
                    Divider()
                    pipelineRow(color: .primary, label: "Total Cycle",
                                detail: "Full round-trip per frame",
                                avg: autoCaptureLoop.avgCycleMs,
                                last: autoCaptureLoop.lastTiming.totalMs)
                }
            } else {
                Text("Start capture to see timing data")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(14)
    }

    private func pipelineRow(color: Color, label: String, detail: String, avg: Double, last: Double) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption.bold())
                Text(detail).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(Int(avg))ms avg").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text("\(Int(last))ms last").font(.system(size: 9).monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
    }


    private var networkLatency: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Network Latency (Ping)")
                .font(.headline)

            HStack(spacing: 12) {
                latencyGauge(label: "Glasses", current: latencyMonitor.current.radxaMs, avg: latencyMonitor.stats.avgRadxaMs)
                latencyGauge(label: "Server", current: latencyMonitor.current.serverMs, avg: latencyMonitor.stats.avgServerMs)
                latencyGauge(label: "Total", current: latencyMonitor.current.totalMs, avg: latencyMonitor.stats.avgTotalMs)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(14)
    }

    private func latencyGauge(label: String, current: Double?, avg: Double) -> some View {
        let ms = current ?? 0
        let fill = Swift.min(ms / 500.0, 1.0)

        return VStack(spacing: 6) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(.systemGray5))
                    .frame(width: 36, height: 70)
                RoundedRectangle(cornerRadius: 5)
                    .fill(current != nil ? latencyColor(ms) : Color(.systemGray4))
                    .frame(width: 36, height: Swift.max(4, 70 * fill))
            }
            Text(current.map { "\(Int($0))" } ?? "--")
                .font(.system(.caption, design: .rounded).bold())
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            if avg > 0 {
                Text("avg \(Int(avg))")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel("\(label): \(current.map { "\(Int($0)) milliseconds" } ?? "offline")")
    }


    private var latencyRanges: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Latency Range")
                .font(.headline)

            latencyRangeBar(
                label: "Glasses Ping",
                minMs: latencyMonitor.stats.minRadxaMs == .infinity ? nil : latencyMonitor.stats.minRadxaMs,
                avg: latencyMonitor.stats.avgRadxaMs,
                maxMs: latencyMonitor.stats.maxRadxaMs == 0 ? nil : latencyMonitor.stats.maxRadxaMs,
                color: .blue
            )
            latencyRangeBar(
                label: "Server Ping",
                minMs: latencyMonitor.stats.minServerMs == .infinity ? nil : latencyMonitor.stats.minServerMs,
                avg: latencyMonitor.stats.avgServerMs,
                maxMs: latencyMonitor.stats.maxServerMs == 0 ? nil : latencyMonitor.stats.maxServerMs,
                color: .purple
            )
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(14)
    }

    private func latencyRangeBar(label: String, minMs: Double?, avg: Double, maxMs: Double?, color: Color) -> some View {
        let maxScale = 500.0
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption.bold())
                Spacer()
                if let minMs, let maxMs {
                    Text("\(Int(minMs))–\(Int(maxMs))ms")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color(.systemGray4)).frame(height: 8)
                    if let minMs, let maxMs {
                        let startX = minMs / maxScale * w
                        let endX = maxMs / maxScale * w
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color.opacity(0.3))
                            .frame(width: Swift.max(4, endX - startX), height: 8)
                            .offset(x: startX)
                    }
                    if avg > 0 {
                        Circle().fill(color).frame(width: 10, height: 10)
                            .offset(x: Swift.min(avg / maxScale * w, w - 5))
                    }
                }
            }
            .frame(height: 10)
        }
    }


    private var sessionInfo: some View {
        HStack {
            Label("\(latencyMonitor.stats.sampleCount) samples", systemImage: "waveform.path")
            Spacer()
            Label("Interval: \(String(format: "%.1fs", latencyMonitor.suggestedCaptureIntervalSeconds))", systemImage: "timer")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private func latencyColor(_ ms: Double) -> Color {
        switch ms {
        case ..<100: return .green
        case ..<300: return .yellow
        default: return .red
        }
    }
}
