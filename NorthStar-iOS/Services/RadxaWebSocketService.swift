// websocket to radxa for fast image capture
import Foundation
import UIKit

@MainActor
@Observable
final class RadxaWebSocketService: NSObject, URLSessionWebSocketDelegate {

    enum ConnectionState: String {
        case disconnected
        case connecting
        case authenticating
        case connected
        case reconnecting
    }

    struct FrameMeta {
        let id: String
        let width: Int
        let height: Int
        let bytes: Int
        let captureMs: Double
        let encodeMs: Double
        let timestamp: Double
    }

    var state: ConnectionState = .disconnected
    var lastFrameMeta: FrameMeta?

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession!
    private var baseURL: String = ""
    private var apiKey: String = ""
    private var reconnectAttempts = 0
    private let maxReconnectDelay: TimeInterval = 10
    private var heartbeatTask: Task<Void, Never>?
    private var awaitingPong = false
    private var missedPongCount = 0

    struct CaptureResult {
        let image: UIImage
        let jpegData: Data
    }

    private var pendingCapture: CheckedContinuation<CaptureResult, Error>?
    private var captureTimeoutTask: Task<Void, Never>?
    private let captureTimeoutSeconds: TimeInterval = 10

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func connect(baseURL: String, apiKey: String) {
        if self.baseURL == baseURL && self.apiKey == apiKey && (state == .connected || state == .connecting || state == .authenticating) {
            return
        }
        cleanupConnection()
        self.baseURL = baseURL
        self.apiKey = apiKey
        reconnectAttempts = 0
        openConnection()
    }

    func disconnect() {
        cleanupConnection()
        state = .disconnected
    }

    private func cleanupConnection() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        captureTimeoutTask?.cancel()
        captureTimeoutTask = nil
        let oldTask = webSocketTask
        webSocketTask = nil
        let wasConnecting = state == .reconnecting
        if !wasConnecting { state = .disconnected }
        oldTask?.cancel(with: .goingAway, reason: nil)
        failPendingCapture(with: URLError(.cancelled))
    }

    var isConnected: Bool { state == .connected }

    func capture(id: String = UUID().uuidString, quality: Int? = nil, maxSide: Int? = nil) async throws -> UIImage {
        let result = try await captureRaw(id: id, quality: quality, maxSide: maxSide)
        return result.image
    }

    // returns both UIImage and raw jpeg so we can forward to server without re-encoding
    func captureRaw(id: String = UUID().uuidString, quality: Int? = nil, maxSide: Int? = nil) async throws -> CaptureResult {
        guard state == .connected, let ws = webSocketTask else {
            throw CaptureService.CaptureError.emptyResponse
        }

        if pendingCapture != nil {
            throw NSError(domain: "RadxaWS", code: -1, userInfo: [NSLocalizedDescriptionKey: "capture already in progress"])
        }

        var request: [String: Any] = ["type": "capture", "id": id]
        if let q = quality { request["quality"] = q }
        if let m = maxSide { request["max_side"] = m }

        let jsonData = try JSONSerialization.data(withJSONObject: request)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? ""

        return try await withCheckedThrowingContinuation { continuation in
            self.pendingCapture = continuation

            self.captureTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.captureTimeoutSeconds ?? 10))
                guard let self, !Task.isCancelled else { return }
                self.failPendingCapture(with: URLError(.timedOut))
            }

            ws.send(.string(jsonString)) { [weak self] error in
                if let error {
                    Task { @MainActor in
                        self?.captureTimeoutTask?.cancel()
                        self?.failPendingCapture(with: error)
                    }
                }
            }
        }
    }

    private func openConnection() {
        let wsURL: String
        if baseURL.hasPrefix("http://") {
            wsURL = "ws://" + baseURL.dropFirst(7) + "/ws"
        } else if baseURL.hasPrefix("https://") {
            wsURL = "wss://" + baseURL.dropFirst(8) + "/ws"
        } else {
            wsURL = "ws://" + baseURL + "/ws"
        }

        guard let url = URL(string: wsURL) else {
            state = .disconnected
            return
        }

        state = .connecting
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        authenticate()
    }

    private func authenticate() {
        state = .authenticating

        let authPayload: [String: String] = ["type": "auth", "token": apiKey]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: authPayload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            state = .disconnected
            return
        }

        webSocketTask?.send(.string(jsonString)) { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.handleDisconnect(error: error)
                }
            }
        }

        receiveNext()
    }

    private func receiveNext() {
        webSocketTask?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let message):
                    self.handleMessage(message)
                    self.receiveNext()
                case .failure(let error):
                    self.handleDisconnect(error: error)
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            handleTextMessage(text)
        case .data(let data):
            handleBinaryMessage(data)
        @unknown default:
            break
        }
    }

    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "auth_ok":
            state = .connected
            reconnectAttempts = 0
            awaitingPong = false
            missedPongCount = 0
            startHeartbeat()

        case "pong":
            awaitingPong = false
            missedPongCount = 0

        case "frame":
            lastFrameMeta = FrameMeta(
                id: json["id"] as? String ?? "",
                width: json["width"] as? Int ?? 0,
                height: json["height"] as? Int ?? 0,
                bytes: json["bytes"] as? Int ?? 0,
                captureMs: json["capture_ms"] as? Double ?? 0,
                encodeMs: json["encode_ms"] as? Double ?? 0,
                timestamp: json["ts"] as? Double ?? 0
            )

        case "error":
            let detail = json["detail"] as? String ?? "unknown error"
            if state == .authenticating {
                state = .disconnected
                failPendingCapture(with: NSError(domain: "RadxaWS", code: 401, userInfo: [NSLocalizedDescriptionKey: detail]))
            } else {
                failPendingCapture(with: NSError(domain: "RadxaWS", code: 500, userInfo: [NSLocalizedDescriptionKey: detail]))
            }

        default:
            break
        }
    }

    private func handleBinaryMessage(_ data: Data) {
        captureTimeoutTask?.cancel()
        captureTimeoutTask = nil

        guard let image = UIImage(data: data) else {
            failPendingCapture(with: CaptureService.CaptureError.invalidImageData)
            return
        }

        if let continuation = pendingCapture {
            pendingCapture = nil
            continuation.resume(returning: CaptureResult(image: image, jpegData: data))
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        missedPongCount = 0
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                guard self.state == .connected else { continue }

                if self.awaitingPong {
                    self.missedPongCount += 1
                    if self.missedPongCount >= 3 {
                        self.handleDisconnect(error: nil)
                        return
                    }
                }

                self.awaitingPong = true
                self.webSocketTask?.send(.string("{\"type\":\"ping\"}")) { _ in }
            }
        }
    }

    private func handleDisconnect(error: Error?) {
        guard state != .disconnected else { return }
        guard webSocketTask != nil else { return }

        heartbeatTask?.cancel()
        heartbeatTask = nil
        captureTimeoutTask?.cancel()
        captureTimeoutTask = nil
        webSocketTask = nil
        failPendingCapture(with: error ?? URLError(.networkConnectionLost))

        guard !baseURL.isEmpty else {
            state = .disconnected
            return
        }

        // exponential backoff reconnect
        state = .reconnecting
        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(reconnectAttempts - 1)), maxReconnectDelay)

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.state == .reconnecting else { return }
            self.openConnection()
        }
    }

    private func failPendingCapture(with error: Error) {
        captureTimeoutTask?.cancel()
        captureTimeoutTask = nil
        if let continuation = pendingCapture {
            pendingCapture = nil
            continuation.resume(throwing: error)
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor [weak self] in
            self?.handleDisconnect(error: nil)
        }
    }
}
