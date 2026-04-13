import SwiftUI

struct RemoteCaptureView: View {
    @Bindable var viewModel: CaptureViewModel
    @AppStorage("captureEndpoint") private var captureEndpoint = "/v1/capture"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    endpointSection
                    imageSection
                    actionButtons

                    if viewModel.isCapturing {
                        ProgressView("Capturing from server...")
                    }
                    if viewModel.isProcessing {
                        ProgressView("Processing image...")
                    }
                    if let error = viewModel.errorMessage {
                        errorBanner(error)
                    }
                    if let result = viewModel.ocrResult {
                        ocrResultSection(result)
                    }
                    if let result = viewModel.detectResult {
                        detectResultSection(result)
                    }
                }
                .padding()
            }
            .navigationTitle("Remote Capture")
        }
    }


    private var endpointSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Capture Endpoint")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("/v1/capture or full URL", text: $captureEndpoint)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .font(.callout.monospaced())
            }
            Text("GET request sent here. Server should capture a photo and return the image.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }


    @ViewBuilder
    private var imageSection: some View {
        if let image = viewModel.capturedImage {
            let imageSize = image.size
            GeometryReader { geo in
                let displaySize = fitSize(imageSize: imageSize, containerWidth: geo.size.width)
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: displaySize.width, height: displaySize.height)

                    // OCR overlay
                    if let ocrResult = viewModel.ocrResult {
                        let blocks = ocrResult.pages.flatMap(\.blocks)
                        OCRBoundingBoxOverlay(
                            blocks: blocks,
                            imageSize: imageSize,
                            displaySize: displaySize
                        )
                    }

                    // Detection overlay
                    if let detectResult = viewModel.detectResult, detectResult.changed {
                        DetectBoundingBoxOverlay(
                            objects: detectResult.objects,
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
                        Image(systemName: "camera.on.rectangle")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("Tap Capture to request a photo from the server")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }
        }
    }


    private var actionButtons: some View {
        VStack(spacing: 10) {
            // Capture button
            Button {
                Task { await viewModel.capture(endpoint: captureEndpoint) }
            } label: {
                HStack {
                    Image(systemName: "camera.shutter.button")
                    Text("Capture")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(viewModel.isCapturing || captureEndpoint.isEmpty)

            // Auto-process picker
            Picker("After capture", selection: $viewModel.autoProcess) {
                ForEach(CaptureViewModel.AutoProcess.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)

            // Manual process buttons (when image exists but no auto-process)
            if let image = viewModel.capturedImage {
                HStack(spacing: 12) {
                    Button {
                        Task { await viewModel.runOCR(on: image) }
                    } label: {
                        Label("Run OCR", systemImage: "text.viewfinder")
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isProcessing)

                    Button {
                        Task { await viewModel.runDetection(on: image) }
                    } label: {
                        Label("Detect", systemImage: "eye")
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isProcessing)

                    Spacer()

                    Button("Clear", role: .destructive) {
                        viewModel.clear()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }


    @ViewBuilder
    private func ocrResultSection(_ result: OCRResponse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("OCR Results", systemImage: "doc.text.viewfinder")
                    .font(.headline)
                Spacer()
                if let engine = viewModel.ocrEngine {
                    Text(engine)
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
                Text("\(String(format: "%.0f", result.timingMs.total)) ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(result.pages) { page in
                Text(page.fullText)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)

                ForEach(page.blocks) { block in
                    HStack {
                        Text(block.text)
                            .font(.callout)
                        Spacer()
                        Text(String(format: "%.1f%%", block.confidence * 100))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }


    @ViewBuilder
    private func detectResultSection(_ result: DetectResponse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Detection Results", systemImage: "eye")
                    .font(.headline)
                Spacer()
                if let engine = viewModel.detectEngine {
                    Text(engine)
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
                Text("\(String(format: "%.0f", result.timingMs)) ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let guidance = result.guidance, !guidance.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Guidance")
                        .font(.subheadline).bold()
                    Text(guidance)
                        .font(.callout)
                        .foregroundStyle(.primary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            }

            if result.changed {
                ForEach(result.objects) { obj in
                    HStack {
                        Circle()
                            .fill(.blue)
                            .frame(width: 8, height: 8)
                        Text(obj.label)
                            .font(.callout)
                        Spacer()
                        Text(String(format: "%.1f%%", obj.confidence * 100))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("No change from previous scene")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
}
