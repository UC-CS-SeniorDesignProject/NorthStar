// gets images from radxa over REST (fallback, ws is faster)

import UIKit
struct CaptureService {
    let client: APIClient

    struct CaptureResponse: Decodable {
        let imageB64: String?
        let image: String?

        enum CodingKeys: String, CodingKey {
            case imageB64 = "image_b64"
            case image
        }

        var base64Data: String? {
            imageB64 ?? image
        }
    }

    enum CaptureError: LocalizedError {
        case invalidImageData
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .invalidImageData:
                return "Server returned data that could not be decoded as an image"
            case .emptyResponse:
                return "Server returned an empty response"
            }
        }
    }

    // Send a GET request to the capture endpoint. The server should take a photo
    // and return it as either raw image bytes or a JSON body with base64 image data.
    func capture(endpoint: String) async throws -> UIImage {
        let data = try await client.requestData(url: endpoint, authenticated: true)

        guard !data.isEmpty else {
            throw CaptureError.emptyResponse
        }

        // Try decoding as raw image bytes first
        if let image = UIImage(data: data) {
            return image
        }

        // Try decoding as JSON with base64
        if let jsonResponse = try? JSONDecoder().decode(CaptureResponse.self, from: data),
           let b64 = jsonResponse.base64Data,
           let imageData = Data(base64Encoded: b64),
           let image = UIImage(data: imageData) {
            return image
        }

        // Try the entire body as a raw base64 string
        if let b64String = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let imageData = Data(base64Encoded: b64String),
           let image = UIImage(data: imageData) {
            return image
        }

        throw CaptureError.invalidImageData
    }
}
