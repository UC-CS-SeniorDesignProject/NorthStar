// on device ocr using apple vision - fallback when server is down
import UIKit
import Vision
struct VisionOCRService {

    enum VisionError: LocalizedError {
        case noCGImage
        case recognitionFailed(String)

        var errorDescription: String? {
            switch self {
            case .noCGImage:
                return "Could not convert UIImage to CGImage"
            case .recognitionFailed(let detail):
                return "Vision OCR failed: \(detail)"
            }
        }
    }

    // Run Apple Vision OCR on a UIImage and return an OCRResponse.
    func ocr(image: UIImage) async throws -> OCRResponse {
        guard let cgImage = image.cgImage else {
            throw VisionError.noCGImage
        }

        let start = CFAbsoluteTimeGetCurrent()

        let observations = try await performTextRecognition(on: cgImage)

        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000 // ms

        let imageWidth = Double(cgImage.width)
        let imageHeight = Double(cgImage.height)

        // Convert Vision observations -> OCRBlocks
        var blocks: [OCRBlock] = []
        var fullTextParts: [String] = []

        for (index, observation) in observations.enumerated() {
            guard let topCandidate = observation.topCandidates(1).first else { continue }

            let text = topCandidate.string
            let confidence = Double(topCandidate.confidence)
            fullTextParts.append(text)

            // Vision uses normalized coordinates (0-1), bottom-left origin.
            // Convert to pixel coordinates, top-left origin.
            let bbox = observation.boundingBox
            let x0 = bbox.origin.x * imageWidth
            let y0 = (1.0 - bbox.origin.y - bbox.height) * imageHeight
            let x1 = (bbox.origin.x + bbox.width) * imageWidth
            let y1 = (1.0 - bbox.origin.y) * imageHeight

            let polygon: [[Double]] = [
                [x0, y0],
                [x1, y0],
                [x1, y1],
                [x0, y1]
            ]
            let bboxXyxy = [x0, y0, x1, y1]

            blocks.append(OCRBlock(
                id: "p0_b\(index)",
                text: text,
                confidence: confidence,
                polygon: polygon,
                bboxXyxy: bboxXyxy
            ))
        }

        let fullText = fullTextParts.joined(separator: "\n")

        let page = OCRPage(
            pageIndex: 0,
            blocks: blocks,
            fullText: fullText
        )

        return OCRResponse(
            requestId: UUID().uuidString,
            contentSha256: "",
            width: Int(imageWidth),
            height: Int(imageHeight),
            pages: [page],
            timingMs: TimingInfo(ocrInfer: elapsed, total: elapsed),
            cache: CacheInfo(hit: false),
            model: ModelInfo(paddleocrVersion: "Apple Vision")
        )
    }


    private func performTextRecognition(on cgImage: CGImage) async throws -> [VNRecognizedTextObservation] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: VisionError.recognitionFailed(error.localizedDescription))
                    return
                }
                let results = request.results as? [VNRecognizedTextObservation] ?? []
                continuation.resume(returning: results)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: VisionError.recognitionFailed(error.localizedDescription))
            }
        }
    }
}
