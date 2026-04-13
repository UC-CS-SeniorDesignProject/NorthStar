import Foundation

@MainActor
@Observable
final class ServerViewModel {
    var healthStatus: String?
    var readyStatus: String?
    var paddleocrVersion: String?
    var yoloDevice: String?
    var metricsText: String?
    var isLoading = false
    var errorMessage: String?

    var isHealthy: Bool { healthStatus == "ok" }
    var isReady: Bool { readyStatus == "ready" }

    private let service: ServerService

    init(client: APIClient) {
        self.service = ServerService(client: client)
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.checkHealth() }
            group.addTask { await self.checkReady() }
        }

        isLoading = false
    }

    func fetchMetrics() async {
        isLoading = true
        do {
            metricsText = try await service.metrics()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func checkHealth() async {
        do {
            let resp = try await service.healthz()
            healthStatus = resp.status
        } catch {
            healthStatus = "unreachable"
            errorMessage = error.localizedDescription
        }
    }

    private func checkReady() async {
        do {
            let resp = try await service.readyz()
            readyStatus = resp.status
            paddleocrVersion = resp.paddleocrVersion
            yoloDevice = resp.yoloDevice
        } catch {
            readyStatus = "not ready"
        }
    }
}
