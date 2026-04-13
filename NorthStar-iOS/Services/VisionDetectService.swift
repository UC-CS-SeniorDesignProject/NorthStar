// on device detection - apple vision fallback
import UIKit
import Vision
struct VisionDetectService {

    enum VisionError: LocalizedError {
        case noCGImage
        case detectionFailed(String)

        var errorDescription: String? {
            switch self {
            case .noCGImage:
                return "Could not convert UIImage to CGImage"
            case .detectionFailed(let detail):
                return "Vision detection failed: \(detail)"
            }
        }
    }

    func detect(image: UIImage) async throws -> DetectResponse {
        guard let cgImage = image.cgImage else {
            throw VisionError.noCGImage
        }

        let start = CFAbsoluteTimeGetCurrent()

        let imageWidth = Double(cgImage.width)
        let imageHeight = Double(cgImage.height)

        // Run all detectors concurrently
        async let classifications = classifyImage(cgImage)
        async let faces = detectFaces(cgImage, width: imageWidth, height: imageHeight)
        async let barcodes = detectBarcodes(cgImage, width: imageWidth, height: imageHeight)
        async let rectangles = detectRectangles(cgImage, width: imageWidth, height: imageHeight)

        var allObjects: [DetectedObject] = []

        // Classifications - top 5 with confidence > 10%
        if let classResults = try? await classifications {
            allObjects.append(contentsOf: classResults)
        }

        // Face detections
        if let faceResults = try? await faces {
            allObjects.append(contentsOf: faceResults)
        }

        // Barcode detections
        if let barcodeResults = try? await barcodes {
            allObjects.append(contentsOf: barcodeResults)
        }

        // Rectangle detections
        if let rectResults = try? await rectangles {
            allObjects.append(contentsOf: rectResults)
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        return DetectResponse(
            requestId: UUID().uuidString,
            changed: true,
            objects: allObjects,
            appeared: allObjects,
            disappeared: [],
            device: "Apple Neural Engine",
            timingMs: elapsed
        )
    }


    private func classifyImage(_ cgImage: CGImage) async throws -> [DetectedObject] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNClassifyImageRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: VisionError.detectionFailed(error.localizedDescription))
                    return
                }
                guard let results = request.results as? [VNClassificationObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                // Top 5 classifications with confidence > 10%
                let top = results
                    .filter { $0.confidence > 0.1 }
                    .prefix(5)
                    .map { obs in
                        DetectedObject(
                            label: obs.identifier,
                            confidence: Double(obs.confidence),
                            bbox: [0, 0, 0, 0]  // classifications don't have bounding boxes
                        )
                    }
                continuation.resume(returning: Array(top))
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: VisionError.detectionFailed(error.localizedDescription))
            }
        }
    }


    private func detectFaces(_ cgImage: CGImage, width: Double, height: Double) async throws -> [DetectedObject] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNDetectFaceRectanglesRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: VisionError.detectionFailed(error.localizedDescription))
                    return
                }
                guard let results = request.results as? [VNFaceObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                let objects = results.map { obs in
                    let bbox = Self.visionRectToPixels(obs.boundingBox, width: width, height: height)
                    return DetectedObject(
                        label: "face",
                        confidence: Double(obs.confidence),
                        bbox: bbox
                    )
                }
                continuation.resume(returning: objects)
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: VisionError.detectionFailed(error.localizedDescription))
            }
        }
    }


    private func detectBarcodes(_ cgImage: CGImage, width: Double, height: Double) async throws -> [DetectedObject] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNDetectBarcodesRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: VisionError.detectionFailed(error.localizedDescription))
                    return
                }
                guard let results = request.results as? [VNBarcodeObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                let objects = results.map { obs in
                    let bbox = Self.visionRectToPixels(obs.boundingBox, width: width, height: height)
                    let label = "barcode (\(obs.symbology.rawValue.replacingOccurrences(of: "VNBarcodeSymbology", with: "")))"
                    return DetectedObject(
                        label: label,
                        confidence: Double(obs.confidence),
                        bbox: bbox
                    )
                }
                continuation.resume(returning: objects)
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: VisionError.detectionFailed(error.localizedDescription))
            }
        }
    }


    private func detectRectangles(_ cgImage: CGImage, width: Double, height: Double) async throws -> [DetectedObject] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNDetectRectanglesRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: VisionError.detectionFailed(error.localizedDescription))
                    return
                }
                guard let results = request.results as? [VNRectangleObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                let objects = results.map { obs in
                    let bbox = Self.visionRectToPixels(obs.boundingBox, width: width, height: height)
                    return DetectedObject(
                        label: "rectangle",
                        confidence: Double(obs.confidence),
                        bbox: bbox
                    )
                }
                continuation.resume(returning: objects)
            }

            request.maximumObservations = 10
            request.minimumConfidence = 0.5

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: VisionError.detectionFailed(error.localizedDescription))
            }
        }
    }


    // Convert Vision normalized rect (bottom-left origin) to pixel bbox [x0, y0, x1, y1] (top-left origin).
    private static func visionRectToPixels(_ rect: CGRect, width: Double, height: Double) -> [Double] {
        let x0 = rect.origin.x * width
        let y0 = (1.0 - rect.origin.y - rect.height) * height
        let x1 = (rect.origin.x + rect.width) * width
        let y1 = (1.0 - rect.origin.y) * height
        return [x0, y0, x1, y1]
    }
}
