import SwiftUI

struct SettingsView: View {
    // Capture server (Radxa)
    @AppStorage("captureBaseURL") private var captureBaseURL = "http://radxa.local:8080"
    @AppStorage("captureAPIKey") private var captureAPIKey = "radxatoken"
    @AppStorage("captureEndpoint") private var captureEndpoint = "/v1/capture"

    // Processing server (OCR/OD)
    @AppStorage("processingBaseURL") private var processingBaseURL = "http://localhost:8000"
    @AppStorage("processingAPIKey") private var processingAPIKey = "test"

    @AppStorage("processingMode") private var processingModeRaw = ProcessingMode.auto.rawValue

    let captureClient: APIClient
    let processingClient: APIClient

    @State private var captureTestResult: String?
    @State private var captureTestSuccess = false
    @State private var isCaptureTestRunning = false

    @State private var processingTestResult: String?
    @State private var processingTestSuccess = false
    @State private var isProcessingTestRunning = false

    private var processingMode: Binding<ProcessingMode> {
        Binding(
            get: { ProcessingMode(rawValue: processingModeRaw) ?? .auto },
            set: { processingModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Processing Mode", selection: processingMode) {
                        ForEach(ProcessingMode.allCases) { mode in
                            Label(mode.displayName, systemImage: mode.icon)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                } header: {
                    Text("Processing Engine")
                } footer: {
                    Text("**Auto**: tries the server first; if it fails, falls back to Apple Vision on-device.\n**Server Only**: always uses the remote API.\n**On-Device Only**: uses Apple Vision framework - works offline, no server needed.")
                }

                // ── Capture Server (Radxa) ──────────────────────────
                Section {
                    LabeledContent("Base URL") {
                        TextField("http://radxa.local:8080", text: $captureBaseURL)
                            .textContentType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .multilineTextAlignment(.trailing)
                    }

                    LabeledContent("API Key") {
                        SecureField("Radxa API key", text: $captureAPIKey)
                            .multilineTextAlignment(.trailing)
                    }

                    LabeledContent("Capture Endpoint") {
                        TextField("/v1/capture", text: $captureEndpoint)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .multilineTextAlignment(.trailing)
                            .font(.callout.monospaced())
                    }

                    Button {
                        Task { await testCaptureConnection() }
                    } label: {
                        HStack {
                            Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                            Spacer()
                            if isCaptureTestRunning { ProgressView() }
                        }
                    }
                    .disabled(isCaptureTestRunning)

                    if let result = captureTestResult {
                        HStack {
                            Image(systemName: captureTestSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(captureTestSuccess ? .green : .red)
                            Text(result)
                                .font(.callout)
                        }
                    }
                } header: {
                    Text("Capture Server (Radxa)")
                } footer: {
                    Text("The Radxa device captures images from the glasses camera. Configure via the Radxa tab.")
                }

                // ── Processing Server (OCR/OD) ─────────────────────
                Section {
                    LabeledContent("Base URL") {
                        TextField("http://192.168.1.50:8000", text: $processingBaseURL)
                            .textContentType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .multilineTextAlignment(.trailing)
                    }

                    LabeledContent("API Key") {
                        SecureField("OCR server API key", text: $processingAPIKey)
                            .multilineTextAlignment(.trailing)
                    }

                    Button {
                        Task { await testProcessingConnection() }
                    } label: {
                        HStack {
                            Label("Test Connection", systemImage: "server.rack")
                            Spacer()
                            if isProcessingTestRunning { ProgressView() }
                        }
                    }
                    .disabled(isProcessingTestRunning)

                    if let result = processingTestResult {
                        HStack {
                            Image(systemName: processingTestSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(processingTestSuccess ? .green : .red)
                            Text(result)
                                .font(.callout)
                        }
                    }
                } header: {
                    Text("Processing Server (OCR / Detection)")
                } footer: {
                    Text("The server running PaddleOCR and YOLOv8. Images are sent here for OCR and object detection.")
                }

                Section("On-Device Capabilities") {
                    Label("OCR (VNRecognizeTextRequest)", systemImage: "doc.text.viewfinder")
                    Label("Image Classification", systemImage: "tag")
                    Label("Face Detection", systemImage: "face.smiling")
                    Label("Barcode Detection", systemImage: "barcode")
                    Label("Rectangle Detection", systemImage: "rectangle.dashed")
                }

                Section("About") {
                    LabeledContent("App", value: "NorthStar")
                    LabeledContent("Engines", value: "PaddleOCR + YOLOv8 + Apple Vision")
                }
            }
            .navigationTitle("Settings")
            .onChange(of: captureBaseURL) { _, _ in syncCaptureConfig() }
            .onChange(of: captureAPIKey) { _, _ in syncCaptureConfig() }
            .onChange(of: processingBaseURL) { _, _ in syncProcessingConfig() }
            .onChange(of: processingAPIKey) { _, _ in syncProcessingConfig() }
            .onAppear {
                syncCaptureConfig()
                syncProcessingConfig()
            }
        }
    }


    private func syncCaptureConfig() {
        Task { await captureClient.updateConfig(baseURL: captureBaseURL, apiKey: captureAPIKey) }
    }

    private func syncProcessingConfig() {
        Task { await processingClient.updateConfig(baseURL: processingBaseURL, apiKey: processingAPIKey) }
    }


    private func testCaptureConnection() async {
        isCaptureTestRunning = true
        captureTestResult = nil
        syncCaptureConfig()

        let service = ServerService(client: captureClient)
        do {
            let health = try await service.healthz()
            captureTestSuccess = health.status == "ok"
            captureTestResult = captureTestSuccess ? "Radxa is reachable." : "Status: \(health.status)"
        } catch {
            captureTestSuccess = false
            captureTestResult = error.localizedDescription
        }
        isCaptureTestRunning = false
    }

    private func testProcessingConnection() async {
        isProcessingTestRunning = true
        processingTestResult = nil
        syncProcessingConfig()

        let service = ServerService(client: processingClient)
        do {
            let health = try await service.healthz()
            processingTestSuccess = health.status == "ok"
            processingTestResult = processingTestSuccess ? "OCR/Detection server is reachable." : "Status: \(health.status)"
        } catch {
            processingTestSuccess = false
            processingTestResult = error.localizedDescription
        }
        isProcessingTestRunning = false
    }
}
