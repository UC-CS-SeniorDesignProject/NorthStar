// http client for both servers, actor based

import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case unauthorized
    case badRequest(String)
    case unsupportedMedia(String)
    case serverError(String)
    case networkError(Error)
    case decodingError(Error)
    case unexpectedStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid server URL"
        case .unauthorized:
            return "Invalid or missing API key (401)"
        case .badRequest(let detail):
            return "Bad request: \(detail)"
        case .unsupportedMedia(let detail):
            return "Unsupported media: \(detail)"
        case .serverError(let detail):
            return "Server error: \(detail)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .unexpectedStatus(let code, let detail):
            return "HTTP \(code): \(detail)"
        }
    }
}

actor APIClient {
    var baseURL: String
    var apiKey: String

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: String = "http://localhost:8000", apiKey: String = "") {
        self.baseURL = baseURL
        self.apiKey = apiKey

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: config)

        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    func updateConfig(baseURL: String, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }


    func request<T: Decodable>(
        path: String,
        method: String = "GET",
        body: (any Encodable)? = nil,
        authenticated: Bool = true
    ) async throws -> T {
        guard let url = URL(string: baseURL + path) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")

        if authenticated {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }

        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError(URLError(.badServerResponse))
        }

        try Self.checkStatus(httpResponse, data: data)

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    // Upload an image as multipart/form-data. Returns decoded JSON response.
    func uploadImage<T: Decodable>(
        path: String,
        imageData: Data,
        filename: String = "image.jpg",
        mimeType: String = "image/jpeg"
    ) async throws -> T {
        guard let url = URL(string: baseURL + path) else {
            throw APIError.invalidURL
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError(URLError(.badServerResponse))
        }

        try Self.checkStatus(httpResponse, data: data)

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    // Fetch raw bytes from a URL (for image downloads, etc.).
    // Supports both absolute URLs and paths relative to baseURL.
    func requestData(
        url urlString: String,
        authenticated: Bool = false
    ) async throws -> Data {
        let resolvedURL: String
        if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
            resolvedURL = urlString
        } else {
            resolvedURL = baseURL + urlString
        }

        guard let url = URL(string: resolvedURL) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")

        if authenticated {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError(URLError(.badServerResponse))
        }

        try Self.checkStatus(httpResponse, data: data)

        return data
    }

    // For endpoints returning raw text (e.g., /metrics)
    func requestRaw(
        path: String,
        authenticated: Bool = false
    ) async throws -> String {
        guard let url = URL(string: baseURL + path) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        if authenticated {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError(URLError(.badServerResponse))
        }

        try Self.checkStatus(httpResponse, data: data)

        return String(data: data, encoding: .utf8) ?? ""
    }


    private static func checkStatus(_ response: HTTPURLResponse, data: Data) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw APIError.unauthorized
        case 400:
            let detail = Self.extractDetail(from: data)
            throw APIError.badRequest(detail)
        case 415:
            let detail = Self.extractDetail(from: data)
            throw APIError.unsupportedMedia(detail)
        case 500..<600:
            let detail = Self.extractDetail(from: data)
            throw APIError.serverError(detail)
        default:
            let detail = Self.extractDetail(from: data)
            throw APIError.unexpectedStatus(response.statusCode, detail)
        }
    }

    private static func extractDetail(from data: Data) -> String {
        if let errorResp = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
            return errorResp.detail
        }
        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }
}
