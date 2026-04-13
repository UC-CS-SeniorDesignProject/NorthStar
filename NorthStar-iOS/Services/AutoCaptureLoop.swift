// main capture loop - grabs frames from radxa, sends to server, speaks guidance
import UIKit
import AVFoundation
import Accessibility
@MainActor
@Observable
final class AutoCaptureLoop {

    enum State: String {
        case idle
        case capturing
        case processing
        case speaking
        case waiting
    }

    // Timing for the most recent cycle (milliseconds).
    struct CycleTiming {
        var captureMs: Double = 0
        var processMs: Double = 0
        var totalMs: Double = 0
    }

    var state: State = .idle
    var isRunning = false
    var isPaused = false
    var lastGuidance: String?
    var lastCapturedImage: UIImage?
    var lastDetectResult: DetectResponse?
    var errorMessage: String?

    // Per-cycle timing
    var lastTiming = CycleTiming()
    var avgCaptureMs: Double = 0
    var avgProcessMs: Double = 0
    var avgCycleMs: Double = 0

    // Stats
    var totalCaptures: Int = 0
    var totalProcessed: Int = 0
    var totalErrors: Int = 0
    var successRate: Double {
        guard totalCaptures > 0 else { return 0 }
        return Double(totalProcessed) / Double(totalCaptures) * 100
    }

    private var loopTask: Task<Void, Never>?
    private let captureService: CaptureService
    private let detectService: DetectService
    private let visionDetectService = VisionDetectService()
    private let speech = SpeechService.shared
    private let latencyMonitor: LatencyMonitor
    private let processingMode: () -> ProcessingMode
    private let manualInterval: () -> Double?
    let radxaWS: RadxaWebSocketService
    var activityLog = ActivityLog()
    private var consecutiveErrors = 0
    private let maxConsecutiveErrors = 5 // auto pause after this many fails

    // Rolling averages
    private var captureTimings: [Double] = []
    private var processTimings: [Double] = []
    private var cycleTimings: [Double] = []
    private let maxTimingSamples = 50

    init(captureClient: APIClient, processingClient: APIClient,
         latencyMonitor: LatencyMonitor, radxaWS: RadxaWebSocketService,
         processingMode: @escaping () -> ProcessingMode,
         manualInterval: @escaping () -> Double? = { nil }) {
        self.captureService = CaptureService(client: captureClient)
        self.detectService = DetectService(client: processingClient)
        self.latencyMonitor = latencyMonitor
        self.radxaWS = radxaWS
        self.processingMode = processingMode
        self.manualInterval = manualInterval
    }

    func start(captureEndpoint: String) {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        consecutiveErrors = 0
        UIApplication.shared.isIdleTimerDisabled = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        // main loop runs until cancelled or stopped
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.isPaused {
                    try? await Task.sleep(for: .seconds(0.5))
                    continue
                }
                let cycleStart = CFAbsoluteTimeGetCurrent()
                await self.runOnce(captureEndpoint: captureEndpoint)
                let cycleMs = (CFAbsoluteTimeGetCurrent() - cycleStart) * 1000
                self.lastTiming.totalMs = cycleMs
                self.addTimingSample(cycleMs, to: &self.cycleTimings, avg: &self.avgCycleMs)

                let elapsed = cycleMs / 1000.0
                let target = self.manualInterval() ?? self.latencyMonitor.suggestedCaptureIntervalSeconds
                let remaining = target - elapsed
                if remaining > 0.05 {
                    self.state = .waiting
                    try? await Task.sleep(for: .seconds(remaining))
                }
            }
        }
    }

    func pause() {
        isPaused = true
        state = .idle
        speech.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func resume() {
        isPaused = false
        consecutiveErrors = 0
        UIApplication.shared.isIdleTimerDisabled = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        isRunning = false
        isPaused = false
        state = .idle
        consecutiveErrors = 0
        speech.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func runOnce(captureEndpoint: String) async {
        // 1. Capture - WebSocket (fast, binary) or REST fallback
        guard !isPaused else { return }
        state = .capturing
        let captureStart = CFAbsoluteTimeGetCurrent()
        let image: UIImage
        var rawJpeg: Data? // raw JPEG to send directly to server (no re-encoding)
        do {
            if radxaWS.isConnected {
                let result = try await radxaWS.captureRaw(quality: 70, maxSide: 1280)
                image = result.image
                rawJpeg = result.jpegData
            } else {
                image = try await captureService.capture(endpoint: captureEndpoint)
            }
            guard !isPaused else { return }
            lastCapturedImage = image
            totalCaptures += 1
        } catch {
            guard !isPaused else { return }
            errorMessage = "Capture: \(error.localizedDescription)"
            totalErrors += 1
            consecutiveErrors += 1
            activityLog.add(ActivityLog.Entry(
                timestamp: Date(), image: nil, captureMs: 0, processMs: 0, totalMs: 0,
                objectCount: 0, objects: "", guidance: nil, engine: "", error: error.localizedDescription
            ))
            if consecutiveErrors >= maxConsecutiveErrors {
                errorMessage = "Connection lost - paused after \(maxConsecutiveErrors) failures. Will resume when devices reconnect."
                pause()
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            return
        }
        let captureMs = (CFAbsoluteTimeGetCurrent() - captureStart) * 1000
        lastTiming.captureMs = captureMs
        addTimingSample(captureMs, to: &captureTimings, avg: &avgCaptureMs)

        // 2. Process (detect) - use raw JPEG if available (skip re-encoding)
        guard !isPaused else { return }
        state = .processing
        let processStart = CFAbsoluteTimeGetCurrent()
        let (result, engine) = await detectImageWithEngine(image, rawJpeg: rawJpeg)
        guard !isPaused else { return }
        let processMs = (CFAbsoluteTimeGetCurrent() - processStart) * 1000
        lastTiming.processMs = processMs
        addTimingSample(processMs, to: &processTimings, avg: &avgProcessMs)

        let totalCycleMs = captureMs + processMs

        if let result {
            lastDetectResult = result
            totalProcessed += 1
            errorMessage = nil
            consecutiveErrors = 0

            var spokenText: String?
            if !isPaused, let guidance = result.guidance, !guidance.isEmpty {
                // Server provided guidance - speak it
                state = .speaking
                lastGuidance = guidance
                spokenText = guidance
                speech.speakWhenReady(guidance)
                UIAccessibility.post(notification: .announcement, argument: guidance)
            } else if !isPaused, engine.contains("On-Device"), !result.objects.isEmpty {
                // On-device has no guidance - build a quick sentence from labels
                let spoken = buildOnDeviceSummary(result.objects)
                state = .speaking
                lastGuidance = spoken
                spokenText = spoken
                speech.speakWhenReady(spoken)
                UIAccessibility.post(notification: .announcement, argument: spoken)
            }

            activityLog.add(ActivityLog.Entry(
                timestamp: Date(), image: image, captureMs: captureMs, processMs: processMs,
                totalMs: totalCycleMs, objectCount: result.objects.count,
                objects: result.objects.map { $0.label }.joined(separator: ", "),
                guidance: spokenText, engine: engine, error: nil
            ))
        } else {
            totalErrors += 1
            consecutiveErrors += 1
            if consecutiveErrors >= maxConsecutiveErrors {
                errorMessage = "Processing failed - paused after \(maxConsecutiveErrors) failures. Will resume when devices reconnect."
                pause()
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            activityLog.add(ActivityLog.Entry(
                timestamp: Date(), image: image, captureMs: captureMs, processMs: processMs,
                totalMs: totalCycleMs, objectCount: 0, objects: "", guidance: nil,
                engine: engine, error: errorMessage
            ))
        }
    }

    private func detectImageWithEngine(_ image: UIImage, rawJpeg: Data? = nil) async -> (DetectResponse?, String) {
        let mode = processingMode()
        switch mode {
        case .server:
            return (await serverDetect(image, rawJpeg: rawJpeg), "Server")
        case .onDevice:
            return (await visionDetect(image), "On-Device")
        case .auto:
            let serverHealthy = latencyMonitor.current.serverReachable || latencyMonitor.stats.avgServerMs > 0
            if serverHealthy {
                let result = await serverDetect(image, rawJpeg: rawJpeg)
                if let result { return (result, "Server") }
                if !latencyMonitor.current.serverReachable {
                    return (await visionDetect(image), "On-Device (fallback)")
                }
                return (nil, "Server")
            } else {
                return (await visionDetect(image), "On-Device")
            }
        }
    }

    private func serverDetect(_ image: UIImage, rawJpeg: Data? = nil) async -> DetectResponse? {
        do {
            // Use raw JPEG if available (no re-encoding needed)
            if let jpeg = rawJpeg {
                return try await detectService.detect(jpegData: jpeg)
            }
            return try await detectService.detect(image: image, options: DetectOptions(skipDedup: true))
        } catch {
            errorMessage = "Server: \(error.localizedDescription)"
            return nil
        }
    }

    private func visionDetect(_ image: UIImage) async -> DetectResponse? {
        do {
            return try await visionDetectService.detect(image: image)
        } catch {
            errorMessage = "Vision: \(error.localizedDescription)"
            return nil
        }
    }

    // Build a natural sentence from on-device detection labels.
    // e.g. ["person", "person", "dog", "cup"] -> "2 people, a dog, and a cup detected"
    private func buildOnDeviceSummary(_ objects: [DetectedObject]) -> String {
        var counts: [(String, Int)] = []
        var seen: [String: Int] = [:]
        for obj in objects {
            let label = obj.label.lowercased()
            if let idx = seen[label] {
                counts[idx].1 += 1
            } else {
                seen[label] = counts.count
                counts.append((label, 1))
            }
        }

        let parts = counts.map { label, count -> String in
            if count == 1 {
                let article = "aeiou".contains(label.prefix(1)) ? "an" : "a"
                return "\(article) \(label)"
            } else {
                return "\(count) \(Self.pluralize(label))"
            }
        }

        if parts.isEmpty { return "" }
        if parts.count == 1 { return "\(parts[0]) detected" }
        let last = parts.last!
        let rest = parts.dropLast().joined(separator: ", ")
        return "\(rest), and \(last) detected"
    }

    // Irregular plurals for common detection labels (COCO, ImageNet, etc.)
    // had to hardcode these bc english is dumb
    private static let irregularPlurals: [String: String] = [
        "person": "people", "mouse": "mice", "knife": "knives",
        "wife": "wives", "life": "lives", "leaf": "leaves",
        "shelf": "shelves", "half": "halves", "wolf": "wolves",
        "calf": "calves", "loaf": "loaves", "thief": "thieves",
        "child": "children", "foot": "feet", "tooth": "teeth",
        "goose": "geese", "man": "men", "woman": "women",
        "ox": "oxen", "sheep": "sheep", "deer": "deer",
        "fish": "fish", "moose": "moose", "aircraft": "aircraft",
        "scissors": "scissors", "broccoli": "broccoli",
    ]

    private static func pluralize(_ word: String) -> String {
        if let irregular = irregularPlurals[word] { return irregular }
        if word.hasSuffix("y") && !"aeiou".contains(word.dropLast().suffix(1)) {
            return String(word.dropLast()) + "ies" // city->cities, puppy->puppies
        }
        if word.hasSuffix("s") || word.hasSuffix("x") || word.hasSuffix("z")
            || word.hasSuffix("ch") || word.hasSuffix("sh") {
            return word + "es" // bus->buses, box->boxes, bench->benches
        }
        if word.hasSuffix("fe") {
            return String(word.dropLast(2)) + "ves" // knife->knives (backup)
        }
        if word.hasSuffix("f") {
            return String(word.dropLast()) + "ves" // scarf->scarves
        }
        return word + "s"
    }

    private func addTimingSample(_ value: Double, to samples: inout [Double], avg: inout Double) {
        samples.append(value)
        if samples.count > maxTimingSamples { samples.removeFirst() }
        avg = samples.reduce(0, +) / Double(samples.count)
    }
}
