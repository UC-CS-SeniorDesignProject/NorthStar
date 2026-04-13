// voice selection and tts info
import SwiftUI
import AVFoundation

struct TTSInfoView: View {
    @State private var activeVoice: AVSpeechSynthesisVoice?
    @State private var siriVoices: [AVSpeechSynthesisVoice] = []
    @State private var enhancedVoices: [AVSpeechSynthesisVoice] = []
    @State private var defaultVoices: [AVSpeechSynthesisVoice] = []
    @State private var testText = "NorthStar guidance is active."

    var body: some View {
        List {
            // Active voice banner
            Section {
                if let voice = activeVoice {
                    let tier = SpeechService.tier(for: voice)
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(tierColor(tier).opacity(0.15))
                                .frame(width: 44, height: 44)
                            Image(systemName: "speaker.wave.2.fill")
                                .foregroundStyle(tierColor(tier))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(voice.name)
                                .font(.headline)
                            HStack(spacing: 4) {
                                Text(tier.label)
                                Text(voiceAccent(voice.language))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color(.systemGray5))
                                    .cornerRadius(3)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        tierBadge(tier)
                    }
                    .padding(.vertical, 4)
                } else {
                    Label("No voice available", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Active Voice")
            } footer: {
                if let voice = activeVoice, SpeechService.tier(for: voice) == .compact {
                    Text("You're using a basic voice. Download a Siri voice for much better quality:\n**Settings > Accessibility > Spoken Content > Voices > English** > tap any Siri voice to download.")
                        .foregroundStyle(.orange)
                } else {
                    Text("Tap any voice below to switch. The app remembers your choice.")
                }
            }

            // Reset
            if UserDefaults.standard.string(forKey: "selectedVoiceIdentifier") != nil {
                Section {
                    Button("Reset to Auto-Select") {
                        SpeechService.shared.clearVoicePreference()
                        loadVoices()
                    }
                } footer: {
                    Text("Reverts to automatic best-voice selection.")
                }
            }

            // Test
            Section {
                Button {
                    SpeechService.shared.speak(testText)
                } label: {
                    Label("Play Test", systemImage: "play.circle.fill")
                }
                TextField("Test text", text: $testText)
                    .font(.callout)
            }

            // Siri voices
            voiceSection(
                title: "Siri (Neural)",
                voices: siriVoices,
                emptyMessage: "No Siri voices installed. To install:\n1. Open **Settings**\n2. Go to **Accessibility > Spoken Content > Voices**\n3. Tap **English** (or your language)\n4. Download any voice labeled **Siri**",
                emptyIcon: "arrow.down.circle",
                emptyColor: .orange,
                footer: "Siri voices come in two types: **Neural** (premium, natural-sounding) and **Compact** (smaller, more robotic). Look for voices marked NEURAL for the best quality. Download more from Settings > Accessibility > Spoken Content > Voices."
            )

            // Enhanced voices
            voiceSection(
                title: "Enhanced",
                voices: enhancedVoices,
                emptyMessage: "No Enhanced voices installed. Download from **Settings > Accessibility > Spoken Content > Voices**.",
                emptyIcon: "arrow.down.circle",
                emptyColor: .yellow,
                footer: "Good quality. Clearer than default, smaller download than Siri."
            )

            // Default voices
            voiceSection(
                title: "Default (Compact)",
                voices: defaultVoices,
                emptyMessage: nil,
                emptyIcon: nil,
                emptyColor: nil,
                footer: "Basic system voices. Always available, no download needed."
            )
        }
        .navigationTitle("Text-to-Speech")
        .onAppear { loadVoices() }
    }


    private func voiceSection(title: String, voices: [AVSpeechSynthesisVoice],
                              emptyMessage: String?, emptyIcon: String?, emptyColor: Color?,
                              footer: String) -> some View {
        Section {
            if voices.isEmpty, let msg = emptyMessage, let icon = emptyIcon, let color = emptyColor {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Not installed", systemImage: icon)
                        .foregroundStyle(color)
                    Text(.init(msg))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(voices, id: \.identifier) { voice in
                    voiceRow(voice)
                }
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                Text("\(voices.count) installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text(footer)
        }
    }


    private func voiceRow(_ voice: AVSpeechSynthesisVoice) -> some View {
        Button {
            SpeechService.shared.setVoice(voice)
            activeVoice = voice
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(voice.name)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Text(voiceAccent(voice.language))
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color(.systemGray5))
                            .cornerRadius(3)
                        if SpeechService.isPremiumNeural(voice) {
                            Text("NEURAL")
                                .font(.system(size: 7, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.2))
                                .foregroundStyle(.green)
                                .cornerRadius(3)
                        }
                    }
                    Text(voice.identifier.components(separatedBy: ".").last ?? voice.language)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if voice.identifier == activeVoice?.identifier {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }

                Button {
                    SpeechService.shared.setVoice(voice)
                    activeVoice = voice
                    SpeechService.shared.speak(testText)
                } label: {
                    Image(systemName: "play.circle")
                        .font(.title3)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
        .buttonStyle(.plain)
    }


    private func loadVoices() {
        let all = AVSpeechSynthesisVoice.speechVoices()
        siriVoices = all.filter { SpeechService.tier(for: $0) == .siri }.sorted { v1, v2 in
            // Premium neural first, then siri compact
            if SpeechService.isPremiumNeural(v1) != SpeechService.isPremiumNeural(v2) {
                return SpeechService.isPremiumNeural(v1)
            }
            return v1.name < v2.name
        }
        enhancedVoices = all.filter { SpeechService.tier(for: $0) == .enhanced }.sorted { $0.name < $1.name }
        defaultVoices = all.filter { SpeechService.tier(for: $0) == .compact }.sorted { $0.name < $1.name }
        activeVoice = SpeechService.shared.voice
    }

    private func voiceAccent(_ language: String) -> String {
        switch language {
        case "en-US": return "US"
        case "en-GB": return "UK"
        case "en-AU": return "AU"
        case "en-IN": return "India"
        case "en-IE": return "Ireland"
        case "en-ZA": return "South Africa"
        case "en-SG": return "Singapore"
        default:
            let parts = language.split(separator: "-")
            return parts.count > 1 ? String(parts[1]) : language
        }
    }

    private func tierColor(_ tier: SpeechService.VoiceTier) -> Color {
        switch tier {
        case .siri: return .green
        case .enhanced: return .blue
        case .compact: return .gray
        }
    }

    private func tierBadge(_ tier: SpeechService.VoiceTier) -> some View {
        Text(tier.label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tierColor(tier).opacity(0.15))
            .foregroundStyle(tierColor(tier))
            .cornerRadius(6)
    }
}
