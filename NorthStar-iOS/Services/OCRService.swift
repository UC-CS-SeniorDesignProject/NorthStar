// sends images to server for ocr

import Foundation
import UIKit

struct OCRService {
    let client: APIClient

    // Run OCR on an image. Uses multipart upload (raw bytes, no base64).
    func ocr(image: UIImage, options: OcrOptions? = nil) async throws -> OCRResponse {
        guard let jpegData = image.jpegData(compressionQuality: 0.95) else {
            throw APIError.badRequest("Failed to encode image as JPEG")
        }
        return try await client.uploadImage(path: "/v1/ocr", imageData: jpegData)
    }

    // OCR from raw JPEG data (skip re-encoding).
    func ocr(jpegData: Data) async throws -> OCRResponse {
        return try await client.uploadImage(path: "/v1/ocr", imageData: jpegData)
    }

    func batchOCR(images: [UIImage]) async throws -> BatchOCRResponse {
        let b64s = images.map { ImageUtils.toBase64($0) }
        let body = BatchOCRRequest(imagesB64: b64s)
        return try await client.request(path: "/v1/ocr/batch", method: "POST", body: body)
    }
}
