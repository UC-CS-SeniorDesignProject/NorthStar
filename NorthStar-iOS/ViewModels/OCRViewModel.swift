// handles ocr processing logic, server or on device
import SwiftUI

@MainActor
@Observable
final class OCRViewModel {
    var selectedImage: UIImage?
    var ocrResult: OCRResponse?
    var isLoading = false
    var errorMessage: String?
    var showImagePicker = false
    var imagePickerSource: UIImagePickerController.SourceType = .photoLibrary

    // Which engine actually processed the last request.
    var usedEngine: String?

    let processingClient: APIClient
    private let serverService: OCRService
    private let visionService = VisionOCRService()
    private let speech = SpeechService.shared
    private let mode: () -> ProcessingMode

    init(client: APIClient, mode: @escaping () -> ProcessingMode) {
        self.processingClient = client
        self.serverService = OCRService(client: client)
        self.mode = mode
    }

    func runOCR() async {
        guard let image = selectedImage else { return }
        isLoading = true
        errorMessage = nil
        ocrResult = nil
        usedEngine = nil

        let currentMode = mode()

        switch currentMode {
        case .server:
            await runServerOCR(image: image)

        case .onDevice:
            await runVisionOCR(image: image)

        case .auto:
            // Try server first, fall back to on-device
            await runServerOCR(image: image)
            if ocrResult == nil {
                let serverError = errorMessage
                errorMessage = nil
                await runVisionOCR(image: image)
                if ocrResult != nil {
                    errorMessage = "Server unavailable, used on-device Vision. (\(serverError ?? "connection failed"))"
                }
            }
        }

        isLoading = false

        if let text = ocrResult?.pages.first?.fullText, !text.isEmpty {
            speech.speak(text)
        }
    }

    private func runServerOCR(image: UIImage) async {
        do {
            ocrResult = try await serverService.ocr(image: image)
            usedEngine = "Server (PaddleOCR)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func runVisionOCR(image: UIImage) async {
        do {
            ocrResult = try await visionService.ocr(image: image)
            usedEngine = "On-Device (Apple Vision)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pickFromLibrary() {
        imagePickerSource = .photoLibrary
        showImagePicker = true
    }

    func pickFromCamera() {
        imagePickerSource = .camera
        showImagePicker = true
    }

    func clear() {
        selectedImage = nil
        ocrResult = nil
        errorMessage = nil
        usedEngine = nil
        speech.stop()
    }
}
