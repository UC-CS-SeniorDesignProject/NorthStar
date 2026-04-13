// pings both servers, tracks latency stats
import Foundation
@MainActor
@Observable
final class LatencyMonitor {

    struct LatencySnapshot {
        var radxaMs: Double?
        var serverMs: Double?
        var totalMs: Double? {
            guard let r = radxaMs, let s = serverMs else { return nil }
            return r + s
        }
        var radxaReachable: Bool { radxaMs != nil }
        var serverReachable: Bool { serverMs != nil }
    }

    struct AggregateStats {
        var avgRadxaMs: Double = 0
        var avgServerMs: Double = 0
        var avgTotalMs: Double = 0
        var minRadxaMs: Double = .infinity
        var minServerMs: Double = .infinity
        var maxRadxaMs: Double = 0
        var maxServerMs: Double = 0
        var p95RadxaMs: Double = 0
        var p95ServerMs: Double = 0
        var sampleCount: Int = 0
    }

    var current = LatencySnapshot()
    var stats = AggregateStats()
    var isMonitoring = false

    private var monitorTask: Task<Void, Never>?
    private let session: URLSession

    // Rolling window - larger window for more stable stats
    private var radxaSamples: [Double] = []
    private var serverSamples: [Double] = []
    private let maxSamples = 100

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 3
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    func start(radxaBaseURL: String, serverBaseURL: String) {
        stop()
        isMonitoring = true
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.measureOnce(radxaBaseURL: radxaBaseURL, serverBaseURL: serverBaseURL)
                // Poll every 1 second for tight latency tracking
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        isMonitoring = false
    }

    // Single measurement round - both pings run in parallel.
    func measureOnce(radxaBaseURL: String, serverBaseURL: String) async {
        async let radxa = ping(baseURL: radxaBaseURL)
        async let server = ping(baseURL: serverBaseURL)

        let (r, s) = await (radxa, server)
        current.radxaMs = r
        current.serverMs = s

        if let r {
            addSample(r, to: &radxaSamples,
                      avg: \.avgRadxaMs, min: \.minRadxaMs, max: \.maxRadxaMs, p95: \.p95RadxaMs)
        }
        if let s {
            addSample(s, to: &serverSamples,
                      avg: \.avgServerMs, min: \.minServerMs, max: \.maxServerMs, p95: \.p95ServerMs)
        }
        stats.sampleCount = max(radxaSamples.count, serverSamples.count)
        if stats.avgRadxaMs > 0 && stats.avgServerMs > 0 {
            stats.avgTotalMs = stats.avgRadxaMs + stats.avgServerMs
        }
    }

    // how fast to capture based on aggressiveness setting
    // 1.0 = no buffer, 0.0 = lots of buffer
    func suggestedInterval(aggressiveness: Double) -> Double {
        guard let total = current.totalMs else { return 2.0 }

        let pingSeconds = total / 1000.0
        let clamped = min(1.0, max(0.0, aggressiveness))
        let buffer = (1.0 - clamped) * pingSeconds
        let interval = pingSeconds + buffer

        // At maximum aggressiveness, allow near-zero wait (just ping time)
        // At minimum, cap at 10s
        return min(10.0, max(0.1, interval))
    }

    // Convenience for default aggressiveness from user setting.
    var suggestedCaptureIntervalSeconds: Double {
        let aggressiveness = UserDefaults.standard.double(forKey: "captureAggressiveness")
        // Default to aggressive (0.8) if not set
        let val = aggressiveness > 0 ? aggressiveness : 0.8
        return suggestedInterval(aggressiveness: val)
    }


    private func ping(baseURL: String) async -> Double? {
        guard let url = URL(string: baseURL + "/healthz") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3

        let start = CFAbsoluteTimeGetCurrent()
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        } catch {
            return nil
        }
    }

    private func addSample(_ value: Double, to samples: inout [Double],
                           avg: WritableKeyPath<AggregateStats, Double>,
                           min minPath: WritableKeyPath<AggregateStats, Double>,
                           max maxPath: WritableKeyPath<AggregateStats, Double>,
                           p95: WritableKeyPath<AggregateStats, Double>) {
        samples.append(value)
        if samples.count > maxSamples { samples.removeFirst() }

        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return }
        stats[keyPath: avg] = sorted.reduce(0, +) / Double(sorted.count)
        stats[keyPath: minPath] = sorted.first ?? value
        stats[keyPath: maxPath] = sorted.last ?? value

        // P95: value at 95th percentile
        let p95Index = min(Int(Double(sorted.count - 1) * 0.95), sorted.count - 1)
        stats[keyPath: p95] = sorted[p95Index]
    }
}
