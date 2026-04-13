// tts - picks best voice, queues speech so it doesnt cut off

import AVFoundation
@MainActor
final class SpeechService: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechService()

    // Voice quality tier - determined by identifier, NOT the broken .quality property.
    enum VoiceTier: Int, Comparable {
        case compact = 0
        case enhanced = 1
        case siri = 2

        static func < (lhs: VoiceTier, rhs: VoiceTier) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .siri: return "Siri"
            case .enhanced: return "Enhanced"
            case .compact: return "Default"
            }
        }
    }

    private let synthesizer = AVSpeechSynthesizer()
    private(set) var voice: AVSpeechSynthesisVoice?

    var isSpeaking: Bool { synthesizer.isSpeaking }
    private(set) var pendingText: String?

    private override init() {
        super.init()
        synthesizer.delegate = self
        voice = Self.loadVoice()
    }

    func setVoice(_ newVoice: AVSpeechSynthesisVoice) {
        voice = newVoice
        UserDefaults.standard.set(newVoice.identifier, forKey: "selectedVoiceIdentifier")
    }

    func clearVoicePreference() {
        UserDefaults.standard.removeObject(forKey: "selectedVoiceIdentifier")
        voice = Self.loadVoice()
    }

    func speak(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }

        pendingText = text
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.prefersAssistiveTechnologySettings = false

        // Audio session is managed by AutoCaptureLoop when running,
        // but set it here too for standalone speak() calls (e.g. TTS test)
        if !AVAudioSession.sharedInstance().isOtherAudioPlaying {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        synthesizer.speak(utterance)
    }

    func speakWhenReady(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if !synthesizer.isSpeaking {
            speak(text)
        } else {
            pendingText = text
        }
    }

    func stop() {
        pendingText = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }


    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if let pending = self.pendingText, pending != utterance.speechString {
                self.speak(pending)
            } else {
                self.pendingText = nil
            }
        }
    }

    // check voice identifier to figure out quality
    // apple's .quality enum is broken so we parse the string instead
    nonisolated static func tier(for voice: AVSpeechSynthesisVoice) -> VoiceTier {
        let id = voice.identifier.lowercased()
        // True premium neural voices
        if id.contains("premium") {
            return .siri
        }
        // Siri bundle voices - better than compact but not fully neural
        if id.contains("siri") {
            return .siri
        }
        // Enhanced downloaded voices
        if id.contains("enhanced") {
            return .enhanced
        }
        return .compact
    }

    // Whether a voice is a true premium neural voice (not just a Siri compact bundle).
    nonisolated static func isPremiumNeural(_ voice: AVSpeechSynthesisVoice) -> Bool {
        voice.identifier.lowercased().contains("premium")
    }


    private nonisolated static func loadVoice() -> AVSpeechSynthesisVoice? {
        if let savedId = UserDefaults.standard.string(forKey: "selectedVoiceIdentifier"),
           let saved = AVSpeechSynthesisVoice(identifier: savedId) {
            return saved
        }
        return bestAvailableVoice()
    }

    private nonisolated static func bestAvailableVoice() -> AVSpeechSynthesisVoice? {
        let all = AVSpeechSynthesisVoice.speechVoices()

        // Siri English voice
        if let v = all.first(where: { $0.language.hasPrefix("en") && tier(for: $0) == .siri }) { return v }
        // Siri any language
        if let v = all.first(where: { tier(for: $0) == .siri }) { return v }
        // Enhanced English
        if let v = all.first(where: { $0.language.hasPrefix("en") && tier(for: $0) == .enhanced }) { return v }
        // Enhanced any
        if let v = all.first(where: { tier(for: $0) == .enhanced }) { return v }
        // Fallback
        return AVSpeechSynthesisVoice(language: "en-US")
    }
}
