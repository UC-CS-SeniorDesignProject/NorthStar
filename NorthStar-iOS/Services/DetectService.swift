// sends images to server for detection, multipart upload

import Foundation
import UIKit

struct DetectService {
    let client: APIClient

    // Detect objects in an image. Uses multipart upload (raw bytes, no base64).
    func detect(image: UIImage, options: DetectOptions? = nil) async throws -> DetectResponse {
        guard let jpegData = image.jpegData(compressionQuality: 0.85) else {
            throw APIError.badRequest("Failed to encode image as JPEG")
        }
        return try await client.uploadImage(path: "/v1/detect", imageData: jpegData)
    }

    // Detect from raw JPEG data (skip re-encoding). Fastest path.
    func detect(jpegData: Data, options: DetectOptions? = nil) async throws -> DetectResponse {
        return try await client.uploadImage(path: "/v1/detect", imageData: jpegData)
    }

    func resetScene() async throws -> SceneResetResponse {
        return try await client.request(path: "/v1/detect/reset", method: "POST")
    }
}
