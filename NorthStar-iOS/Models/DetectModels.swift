// detect request/response models, matches christians /v1/detect endpoint
// guidance field comes from viets RAG pipeline

import Foundation

struct DetectRequest: Encodable {
    let imageB64: String
    var options: DetectOptions?

    enum CodingKeys: String, CodingKey {
        case imageB64 = "image_b64"
        case options
    }
}

struct DetectOptions: Codable {
    var skipDedup: Bool?
    var resetScene: Bool?

    enum CodingKeys: String, CodingKey {
        case skipDedup = "skip_dedup"
        case resetScene = "reset_scene"
    }
}


struct DetectResponse: Codable {
    let requestId: String
    let changed: Bool
    let objects: [DetectedObject]
    let appeared: [DetectedObject]
    let disappeared: [DetectedObject]
    let device: String
    let timingMs: Double
    let guidance: String?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case changed, objects, appeared, disappeared, device, guidance
        case timingMs = "timing_ms"
    }

    init(requestId: String, changed: Bool, objects: [DetectedObject], appeared: [DetectedObject], disappeared: [DetectedObject], device: String, timingMs: Double, guidance: String? = nil) {
        self.requestId = requestId
        self.changed = changed
        self.objects = objects
        self.appeared = appeared
        self.disappeared = disappeared
        self.device = device
        self.timingMs = timingMs
        self.guidance = guidance
    }
}

struct DetectedObject: Codable, Identifiable {
    let label: String
    let confidence: Double
    let bbox: [Double]

    var id: String { "\(label)-\(bbox.map { String($0) }.joined(separator: ","))" }

    init(label: String, confidence: Double, bbox: [Double]) {
        self.label = label
        self.confidence = confidence
        self.bbox = bbox
    }
}


struct SceneResetResponse: Decodable {
    let status: String
}
