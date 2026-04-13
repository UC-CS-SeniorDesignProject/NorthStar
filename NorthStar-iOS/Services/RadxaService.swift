// radxa wifi/token api calls, matches radxa server endpoints
// uses own URLSession bc hotspot url is diffrent than normal
import Foundation
struct RadxaService {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }


    func healthz(baseURL: String) async throws -> HealthResponse {
        let data = try await get(baseURL + "/healthz")
        return try JSONDecoder().decode(HealthResponse.self, from: data)
    }

    func readyz(baseURL: String) async throws -> RadxaReadyResponse {
        let data = try await get(baseURL + "/readyz")
        return try JSONDecoder().decode(RadxaReadyResponse.self, from: data)
    }


    func setupToken(_ token: String, baseURL: String, currentToken: String? = nil) async throws -> RadxaTokenResponse {
        var headers: [String: String] = [:]
        if let current = currentToken, !current.isEmpty {
            headers["X-API-Key"] = current
        }
        let body = ["token": token]
        let data = try await post(baseURL + "/api/token/setup", json: body, headers: headers)
        return try JSONDecoder().decode(RadxaTokenResponse.self, from: data)
    }


    func wifiStatus(baseURL: String, apiKey: String) async throws -> RadxaNetworkStatus {
        let data = try await get(baseURL + "/api/wifi/status", apiKey: apiKey)
        return try JSONDecoder().decode(RadxaNetworkStatus.self, from: data)
    }

    func scanNetworks(baseURL: String, apiKey: String) async throws -> [RadxaWifiNetwork] {
        let data = try await get(baseURL + "/api/wifi/networks", apiKey: apiKey, timeout: 30)
        let response = try JSONDecoder().decode(RadxaWifiScanResponse.self, from: data)
        return response.networks
    }

    func configureWifi(ssid: String, password: String, baseURL: String, apiKey: String) async throws -> RadxaWifiConfigureResponse {
        let body = ["ssid": ssid, "password": password]
        let data = try await post(baseURL + "/api/wifi/configure", json: body, headers: ["X-API-Key": apiKey])
        return try JSONDecoder().decode(RadxaWifiConfigureResponse.self, from: data)
    }

    func configureEnterpriseWifi(ssid: String, identity: String, password: String,
                                  eapMethod: String, phase2Auth: String,
                                  baseURL: String, apiKey: String) async throws -> RadxaWifiConfigureResponse {
        let body = [
            "ssid": ssid,
            "password": password,
            "security": "wpa-eap",
            "eap_method": eapMethod,
            "phase2_auth": phase2Auth,
            "identity": identity,
        ]
        let data = try await post(baseURL + "/api/wifi/configure", json: body, headers: ["X-API-Key": apiKey])
        return try JSONDecoder().decode(RadxaWifiConfigureResponse.self, from: data)
    }


    private func get(_ urlString: String, apiKey: String? = nil, timeout: TimeInterval? = nil) async throws -> Data {
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let key = apiKey {
            request.setValue(key, forHTTPHeaderField: "X-API-Key")
        }
        if let t = timeout {
            request.timeoutInterval = t
        }
        let (data, response) = try await session.data(for: request)
        try checkStatus(response)
        return data
    }

    private func post(_ urlString: String, json: [String: String], headers: [String: String] = [:]) async throws -> Data {
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(json)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: request)
        try checkStatus(response)
        return data
    }

    private func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.networkError(URLError(.badServerResponse))
        }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw APIError.unauthorized
        default: throw APIError.unexpectedStatus(http.statusCode, "Radxa responded with \(http.statusCode)")
        }
    }
}
