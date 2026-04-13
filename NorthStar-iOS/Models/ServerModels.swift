
import Foundation

struct HealthResponse: Decodable {
    let status: String
}

struct ReadyResponse: Decodable {
    let status: String
    let paddleocrVersion: String?
    let yoloDevice: String?

    enum CodingKeys: String, CodingKey {
        case status
        case paddleocrVersion = "paddleocr_version"
        case yoloDevice = "yolo_device"
    }
}

struct APIErrorResponse: Decodable {
    let detail: String
}
