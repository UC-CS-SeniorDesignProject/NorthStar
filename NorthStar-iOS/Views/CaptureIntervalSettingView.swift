// capture speed settings - aggressiveness slider + manual override
import SwiftUI

struct CaptureIntervalSettingView: View {
    @AppStorage("manualCaptureInterval") private var manualInterval: Double = 0
    @AppStorage("captureAggressiveness") private var aggressiveness: Double = 0.8

    private var isManual: Bool { manualInterval > 0 }

    var body: some View {
        Form {
            // Auto timing aggressiveness
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Aggressiveness")
                        Spacer()
                        Text(aggressivenessLabel)
                            .monospacedDigit()
                            .foregroundStyle(aggressivenessColor)
                            .bold()
                    }

                    Slider(value: $aggressiveness, in: 0.0...1.0, step: 0.05) {
                        Text("Aggressiveness")
                    }

                    HStack {
                        Text("Conservative")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Aggressive")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Auto Timing")
            } footer: {
                Text("Controls how fast the auto-capture fires between cycles.\n**Aggressive**: minimal wait, maximum frame rate, may overload slow connections.\n**Conservative**: more buffer between captures, more stable.")
            }

            Section {
                Button("Max Aggressive") { aggressiveness = 1.0 }
                Button("Aggressive (Default)") { aggressiveness = 0.8 }
                Button("Balanced") { aggressiveness = 0.5 }
                Button("Conservative") { aggressiveness = 0.2 }
            } header: {
                Text("Presets")
            }

            // Manual override
            Section {
                Toggle("Manual Override", isOn: Binding(
                    get: { isManual },
                    set: { manualInterval = $0 ? 1.0 : 0 }
                ))
            } footer: {
                Text("Overrides auto timing with a fixed interval. Use this if auto timing isn't working well for your setup.")
            }

            if isManual {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Fixed Interval")
                            Spacer()
                            Text("\(String(format: "%.1f", manualInterval))s")
                                .monospacedDigit()
                                .foregroundStyle(.blue)
                        }

                        Slider(value: $manualInterval, in: 0.2...10.0, step: 0.1) {
                            Text("Capture Interval")
                        }

                        HStack {
                            Text("0.2s")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("10s")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Fixed Interval")
                }

                Section {
                    Button("0.2s (Fastest)") { manualInterval = 0.2 }
                    Button("0.5s") { manualInterval = 0.5 }
                    Button("1.0s") { manualInterval = 1.0 }
                    Button("2.0s") { manualInterval = 2.0 }
                } header: {
                    Text("Quick Set")
                }
            }
        }
        .navigationTitle("Capture Interval")
    }

    private var aggressivenessLabel: String {
        switch aggressiveness {
        case 0.9...: return "Max"
        case 0.7..<0.9: return "Aggressive"
        case 0.4..<0.7: return "Balanced"
        default: return "Conservative"
        }
    }

    private var aggressivenessColor: Color {
        switch aggressiveness {
        case 0.9...: return .red
        case 0.7..<0.9: return .orange
        case 0.4..<0.7: return .yellow
        default: return .green
        }
    }
}
