// health/ready checks for processing server

import Foundation

struct ServerService {
    let client: APIClient

    func healthz() async throws -> HealthResponse {
        return try await client.request(path: "/healthz", authenticated: false)
    }

    func readyz() async throws -> ReadyResponse {
        return try await client.request(path: "/readyz", authenticated: false)
    }

    func metrics() async throws -> String {
        return try await client.requestRaw(path: "/metrics")
    }
}
