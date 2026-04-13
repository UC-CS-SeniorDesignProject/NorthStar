// ocr testing page
import SwiftUI

struct OCRView: View {
    @Bindable var viewModel: OCRViewModel
    var captureClient: APIClient?
    @AppStorage("captureEndpoint") private var captureEndpoint = "/v1/capture"
    @State private var isCapturingFromGlasses = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    imageSection
                    actionButtons
                    if viewModel.isLoading {
                        ProgressView("Running OCR...")
                    }
                    if let error = viewModel.errorMessage {
                        errorBanner(error)
                    }
                    if let result = viewModel.ocrResult {
                        resultSection(result)
                    }
                }
                .padding()
            }
            .navigationTitle("OCR")
            .sheet(isPresented: $viewModel.showImagePicker) {
                ImagePicker(
                    sourceType: viewModel.imagePickerSource,
                    selectedImage: $viewModel.selectedImage
                )
            }
        }
    }


    @ViewBuilder
    private var imageSection: some View {
        if let image = viewModel.selectedImage {
            let imageSize = image.size
            GeometryReader { geo in
                let displaySize = fitSize(imageSize: imageSize, containerWidth: geo.size.width)
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: displaySize.width, height: displaySize.height)

                    if let result = viewModel.ocrResult {
                        let blocks = result.pages.flatMap(\.blocks)
                        OCRBoundingBoxOverlay(
                            blocks: blocks,
                            imageSize: imageSize,
                            displaySize: displaySize
                        )
                    }
                }
                .frame(width: geo.size.width, height: displaySize.height)
            }
            .aspectRatio(imageSize.width / imageSize.height, contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemGray6))
                .frame(height: 200)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.viewfinder")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("Select an image to run OCR")
                            .foregroundStyle(.secondary)
                    }
                }
        }
    }


    private var actionButtons: some View {
        VStack(spacing: 10) {
        HStack(spacing: 12) {
            Button { viewModel.pickFromLibrary() } label: {
                Label("Library", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(.bordered)

            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { viewModel.pickFromCamera() } label: {
                    Label("Camera", systemImage: "camera")
                }
                .buttonStyle(.bordered)
            }

            if captureClient != nil {
                Button {
                    Task { await captureFromGlasses() }
                } label: {
                    Label(isCapturingFromGlasses ? "..." : "Glasses", systemImage: "eyeglasses")
                }
                .buttonStyle(.bordered)
                .disabled(isCapturingFromGlasses)
            }

        }

        if viewModel.selectedImage != nil {
            VStack(spacing: 8) {
                Picker("Engine", selection: Binding(
                    get: { ProcessingMode(rawValue: engineModeRaw) ?? .auto },
                    set: { engineModeRaw = $0.rawValue }
                )) {
                    ForEach(ProcessingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Button {
                    Task { await runWithSelectedEngine() }
                } label: {
                    Label("Run OCR", systemImage: "text.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isLoading)
            }
        }
        }
    }

    @AppStorage("ocrTestEngine") private var engineModeRaw = ProcessingMode.auto.rawValue

    private func runWithSelectedEngine() async {
        guard let image = viewModel.selectedImage else { return }
        viewModel.isLoading = true
        viewModel.ocrResult = nil
        viewModel.errorMessage = nil
        viewModel.usedEngine = nil

        let mode = ProcessingMode(rawValue: engineModeRaw) ?? .auto

        switch mode {
        case .server:
            await runServerOCR(image)
        case .onDevice:
            await runVisionOCR(image)
        case .auto:
            await runServerOCR(image)
            if viewModel.ocrResult == nil {
                await runVisionOCR(image)
            }
        }

        if let text = viewModel.ocrResult?.pages.first?.fullText, !text.isEmpty {
            SpeechService.shared.speakWhenReady(text)
        }

        viewModel.isLoading = false
    }

    private func runServerOCR(_ image: UIImage) async {
        do {
            let service = OCRService(client: viewModel.processingClient)
            viewModel.ocrResult = try await service.ocr(image: image)
            viewModel.usedEngine = "Server (PaddleOCR)"
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private func runVisionOCR(_ image: UIImage) async {
        do {
            viewModel.ocrResult = try await VisionOCRService().ocr(image: image)
            viewModel.usedEngine = "On-Device (Apple Vision)"
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }


    @ViewBuilder
    private func resultSection(_ result: OCRResponse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Results")
                    .font(.headline)
                Spacer()
                if let engine = viewModel.usedEngine {
                    Label(engine, systemImage: result.model.paddleocrVersion == "Apple Vision" ? "iphone" : "server.rack")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            }

            HStack {
                if result.cache.hit {
                    Label("Cached", systemImage: "bolt.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text("\(String(format: "%.0f", result.timingMs.total)) ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(result.pages) { page in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Full Text")
                        .font(.subheadline).bold()
                    Text(page.fullText)
                        .font(.body)
                        .textSelection(.enabled)
                        .padding(12)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)

                    Text("Blocks (\(page.blocks.count))")
                        .font(.subheadline).bold()

                    ForEach(page.blocks) { block in
                        HStack {
                            Text(block.text)
                                .font(.callout)
                            Spacer()
                            Text(String(format: "%.1f%%", block.confidence * 100))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Button("Clear", role: .destructive) {
                viewModel.clear()
            }
        }
    }


    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(8)
    }

    private func fitSize(imageSize: CGSize, containerWidth: CGFloat) -> CGSize {
        let scale = containerWidth / imageSize.width
        return CGSize(width: containerWidth, height: imageSize.height * scale)
    }

    private func captureFromGlasses() async {
        guard let client = captureClient else { return }
        isCapturingFromGlasses = true
        do {
            let service = CaptureService(client: client)
            viewModel.selectedImage = try await service.capture(endpoint: captureEndpoint)
        } catch {
            viewModel.errorMessage = "Glasses capture: \(error.localizedDescription)"
        }
        isCapturingFromGlasses = false
    }
}
