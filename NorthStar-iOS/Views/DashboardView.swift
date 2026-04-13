// main dashboard screen
import SwiftUI

struct DashboardView: View {
    let latencyMonitor: LatencyMonitor
    let autoCaptureLoop: AutoCaptureLoop
    let captureClient: APIClient
    let processingClient: APIClient
    let networkDiscovery: NetworkDiscovery
    @AppStorage("captureEndpoint") private var captureEndpoint = "/v1/capture"
    @AppStorage("processingMode") private var processingModeRaw = ProcessingMode.auto.rawValue
    @AppStorage("captureBaseURL") private var captureBaseURL = "http://radxa.local:8080"
    @AppStorage("captureAPIKey") private var captureAPIKey = "radxatoken"
    @AppStorage("processingBaseURL") private var processingBaseURL = "http://localhost:8000"
    @AppStorage("processingAPIKey") private var processingAPIKey = "test"
    @AppStorage("captureBaseURLOverride") private var captureOverride = false
    @AppStorage("processingBaseURLOverride") private var processingOverride = false

    @State private var showGlassesSettings = false
    @State private var showServerSettings = false
    @State private var userStopped = false
    @State private var showActivityLog = false
    @State private var pulsePlay = false
    @State private var wasConnected = false
    @State private var ocrResult: OCRResponse?
    @State private var isRunningOCR = false
    @State private var ocrEngine: String?
    @AppStorage("pauseDetectDuringOCR") private var pauseDetectDuringOCR = true

    private var processingMode: Binding<ProcessingMode> {
        Binding(
            get: { ProcessingMode(rawValue: processingModeRaw) ?? .auto },
            set: { processingModeRaw = $0.rawValue }
        )
    }

    private var glassesConnected: Bool {
        autoCaptureLoop.radxaWS.isConnected || latencyMonitor.current.radxaReachable
    }

    private var allConnected: Bool {
        glassesConnected && latencyMonitor.current.serverReachable
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if networkDiscovery.isScanning {
                        scanningBanner
                    }
                    mainControl
                    guidanceCard
                    ocrSection
                    deviceRow
                    if autoCaptureLoop.isRunning {
                        runningStats
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("NorthStar")
            .task { await runDiscovery() }
            .onChange(of: allConnected) { _, connected in
                if connected {
                    if networkDiscovery.isScanning { networkDiscovery.cancel() }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    autoCaptureLoop.errorMessage = nil

                    if autoCaptureLoop.isPaused {
                        autoCaptureLoop.resume()
                    } else if !autoCaptureLoop.isRunning && !userStopped {
                        autoCaptureLoop.start(captureEndpoint: captureEndpoint)
                    }
                    pulsePlay = false
                    wasConnected = true
                } else if wasConnected {
                    // Only warn if we were previously connected (not on initial launch)
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                }
            }
            .onChange(of: autoCaptureLoop.isRunning) { _, running in
                if !running && allConnected && !userStopped {
                    pulsePlay = true
                } else {
                    pulsePlay = false
                }
            }
            .sheet(isPresented: $showGlassesSettings) { glassesSheet }
            .sheet(isPresented: $showServerSettings) { serverSheet }
            .sheet(isPresented: $showActivityLog) {
                NavigationStack {
                    ActivityLogView(activityLog: autoCaptureLoop.activityLog)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showActivityLog = false }
                            }
                        }
                }
            }
        }
    }


    private var mainControl: some View {
        VStack(spacing: 14) {
            // Main play/pause button
            Button {
                if autoCaptureLoop.isRunning && !autoCaptureLoop.isPaused {
                    autoCaptureLoop.pause()
                } else if autoCaptureLoop.isPaused {
                    userStopped = false
                    autoCaptureLoop.resume()
                } else {
                    userStopped = false
                    autoCaptureLoop.start(captureEndpoint: captureEndpoint)
                }
            } label: {
                ZStack {
                    // ring around button shows latency
                    Circle()
                        .stroke(Color(.systemGray4), lineWidth: 4)
                        .frame(width: 120, height: 120)

                    if let total = latencyMonitor.current.totalMs {
                        Circle()
                            .trim(from: 0, to: min(CGFloat(total) / 500.0, 1.0))
                            .stroke(latencyColor(total), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .frame(width: 120, height: 120)
                            .rotationEffect(.degrees(-90))
                    }

                    // Inner button
                    Circle()
                        .fill(buttonFillColor)
                        .frame(width: 100, height: 100)

                    Image(systemName: buttonIcon)
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(buttonIconColor)
                        .scaleEffect(pulsePlay ? 1.15 : 1.0)
                        .animation(pulsePlay ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: pulsePlay)
                }
            }
            .buttonStyle(.plain)
            .disabled(!allConnected && !autoCaptureLoop.isRunning)
            .accessibilityLabel(buttonAccessibilityLabel)

            // Status text
            Group {
                if autoCaptureLoop.isPaused {
                    Label("Paused", systemImage: "pause.circle")
                        .foregroundStyle(.orange)
                } else if autoCaptureLoop.isRunning {
                    Label(stateLabel(autoCaptureLoop.state), systemImage: stateIcon(autoCaptureLoop.state))
                        .foregroundStyle(stateColor(autoCaptureLoop.state))
                } else if !allConnected {
                    Label("Waiting for devices", systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.secondary)
                } else if userStopped {
                    Label("Stopped", systemImage: "stop.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Ready", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            }
            .font(.subheadline)

            // Stop button (only when running or paused)
            if autoCaptureLoop.isRunning || autoCaptureLoop.isPaused {
                Button {
                    userStopped = true
                    autoCaptureLoop.stop()
                } label: {
                    Text("Stop")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop completely")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }


    @ViewBuilder
    private var guidanceCard: some View {
        if let guidance = autoCaptureLoop.lastGuidance {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "quote.opening")
                    .font(.title3)
                    .foregroundStyle(.blue.opacity(0.6))
                    .padding(.top, 2)
                Text(guidance)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .background(.ultraThinMaterial)
            .cornerRadius(16)
            .accessibilityLabel("Guidance: \(guidance)")
        }

        if let error = autoCaptureLoop.errorMessage, autoCaptureLoop.isRunning {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.caption)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08))
            .cornerRadius(12)
        }
    }


    @ViewBuilder
    private var ocrSection: some View {
        if autoCaptureLoop.lastCapturedImage != nil || latencyMonitor.current.radxaReachable {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    // OCR on latest image
                    Button {
                        Task { await runOCR() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text.viewfinder")
                            Text(isRunningOCR ? "Reading..." : "Read Text")
                            if isRunningOCR { ProgressView().scaleEffect(0.7) }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                    .disabled(isRunningOCR || autoCaptureLoop.lastCapturedImage == nil)
                    .accessibilityLabel("Run OCR on latest image")

                    // Capture fresh + OCR
                    Button {
                        Task { await captureAndOCR() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "camera.viewfinder")
                            Text(isRunningOCR ? "..." : "Capture + OCR")
                            if isRunningOCR { ProgressView().scaleEffect(0.7) }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                    .disabled(isRunningOCR || !latencyMonitor.current.radxaReachable)
                    .accessibilityLabel("Capture from glasses and run OCR")
                }

                // Discrete pause toggle
                if autoCaptureLoop.isRunning {
                    Toggle(isOn: $pauseDetectDuringOCR) {
                        Text("Pause detection during OCR")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }

                if let result = ocrResult, let text = result.pages.first?.fullText, !text.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "text.quote")
                                .foregroundStyle(.purple)
                            Text("OCR Result")
                                .font(.caption.bold())
                            Spacer()
                            if let engine = ocrEngine {
                                Text(engine)
                                    .font(.system(size: 9).bold())
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.purple.opacity(0.15))
                                    .cornerRadius(3)
                            }
                            Text("\(String(format: "%.0f", result.timingMs.total))ms")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(text)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.purple.opacity(0.08))
                    .cornerRadius(12)
                    .accessibilityLabel("OCR result: \(text)")
                }
            }
        }
    }

    private func runOCR() async {
        guard let image = autoCaptureLoop.lastCapturedImage else { return }
        isRunningOCR = true
        ocrResult = nil
        ocrEngine = nil

        if pauseDetectDuringOCR && autoCaptureLoop.isRunning && !autoCaptureLoop.isPaused {
            autoCaptureLoop.pause()
            await performOCR(on: image)
            autoCaptureLoop.resume()
        } else {
            await performOCR(on: image)
        }

        isRunningOCR = false
    }

    private func captureAndOCR() async {
        isRunningOCR = true
        ocrResult = nil
        ocrEngine = nil

        if pauseDetectDuringOCR && autoCaptureLoop.isRunning && !autoCaptureLoop.isPaused {
            autoCaptureLoop.pause()
        }

        do {
            let service = CaptureService(client: captureClient)
            let image = try await service.capture(endpoint: captureEndpoint)
            autoCaptureLoop.lastCapturedImage = image
            await performOCR(on: image)
        } catch {}

        if pauseDetectDuringOCR && autoCaptureLoop.isPaused {
            autoCaptureLoop.resume()
        }

        isRunningOCR = false
    }

    // Hybrid OCR: use server if reachable (based on processing mode), fall back to on-device.
    private func performOCR(on image: UIImage) async {
        let mode = ProcessingMode(rawValue: processingModeRaw) ?? .auto

        switch mode {
        case .server:
            await serverOCR(image)
        case .onDevice:
            await onDeviceOCR(image)
        case .auto:
            // Try server first if reachable
            if latencyMonitor.current.serverReachable {
                await serverOCR(image)
            }
            // Fall back to on-device if server failed or wasn't tried
            if ocrResult == nil {
                await onDeviceOCR(image)
            }
        }

        if let text = ocrResult?.pages.first?.fullText, !text.isEmpty {
            SpeechService.shared.speakWhenReady(text)
        }
    }

    private func serverOCR(_ image: UIImage) async {
        do {
            let service = OCRService(client: processingClient)
            ocrResult = try await service.ocr(image: image)
            ocrEngine = "Server"
        } catch {
            ocrResult = nil
        }
    }

    private func onDeviceOCR(_ image: UIImage) async {
        do {
            ocrResult = try await VisionOCRService().ocr(image: image)
            ocrEngine = "On-Device"
        } catch {}
    }


    private var deviceRow: some View {
        HStack(spacing: 12) {
            deviceTile(
                icon: "eyeglasses",
                name: autoCaptureLoop.radxaWS.isConnected ? "Glasses (WS)" : "Glasses",
                connected: glassesConnected,
                latency: latencyMonitor.current.radxaMs
            ) {
                showGlassesSettings = true
            }

            deviceTile(
                icon: "server.rack",
                name: "Server",
                connected: latencyMonitor.current.serverReachable,
                latency: latencyMonitor.current.serverMs
            ) {
                showServerSettings = true
            }
        }
    }

    private func deviceTile(icon: String, name: String, connected: Bool, latency: Double?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(connected ? Color.green.opacity(0.08) : Color.red.opacity(0.08))
                        .frame(height: 56)

                    HStack(spacing: 10) {
                        Image(systemName: icon)
                            .font(.title3)
                            .foregroundStyle(connected ? .green : .red)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(name)
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)

                            if connected, let ms = latency {
                                Text("\(Int(ms))ms")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Offline")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name): \(connected ? "connected" : "offline")")
        .accessibilityHint("Tap to configure")
    }


    private var runningStats: some View {
        Button { showActivityLog = true } label: { HStack(spacing: 0) {
            miniStat(value: "\(autoCaptureLoop.totalCaptures)", label: "Captures", icon: "camera.fill")
            Divider().frame(height: 24)
            miniStat(value: "\(Int(autoCaptureLoop.successRate))%", label: "Success", icon: "checkmark.circle.fill")
            Divider().frame(height: 24)
            miniStat(value: captureRateLabel, label: "Rate", icon: "speedometer")
            Divider().frame(height: 24)
            if let total = latencyMonitor.current.totalMs {
                miniStat(value: "\(Int(total))ms", label: "Latency", icon: "bolt.fill")
            } else {
                miniStat(value: "--", label: "Latency", icon: "bolt.fill")
            }
        } }
        .buttonStyle(.plain)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(14)
        .accessibilityHint("Tap to view activity log")
    }

    private func miniStat(value: String, label: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.subheadline, design: .rounded).bold())
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 8))
                Text(label)
                    .font(.system(size: 10))
            }
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }


    private var scanningBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.7)
            Text("Scanning network...")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(Int(networkDiscovery.scanProgress * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(10)
        .accessibilityLabel("Scanning network for devices, \(Int(networkDiscovery.scanProgress * 100)) percent complete")
    }


    private func runDiscovery() async {
        if captureOverride && processingOverride { return }
        await networkDiscovery.discover()
        if !captureOverride, let url = networkDiscovery.discoveredRadxaURL, url != captureBaseURL {
            captureBaseURL = url
            Task { await captureClient.updateConfig(baseURL: url, apiKey: captureAPIKey) }
        }
        if !processingOverride, let url = networkDiscovery.discoveredServerURL, url != processingBaseURL {
            processingBaseURL = url
            Task { await processingClient.updateConfig(baseURL: url, apiKey: processingAPIKey) }
        }
    }


    private var glassesSheet: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    LabeledContent("Connection") {
                        HStack(spacing: 6) {
                            Circle().fill(latencyMonitor.current.radxaReachable ? .green : .red).frame(width: 8, height: 8)
                            Text(latencyMonitor.current.radxaReachable ? "Connected" : "Offline")
                        }
                    }
                    if let ms = latencyMonitor.current.radxaMs {
                        LabeledContent("Latency", value: "\(Int(ms))ms")
                    }
                    if latencyMonitor.stats.avgRadxaMs > 0 {
                        LabeledContent("Average", value: "\(Int(latencyMonitor.stats.avgRadxaMs))ms")
                    }
                }

                Section {
                    Toggle("Manual Address", isOn: $captureOverride)
                    LabeledContent("URL") {
                        TextField("URL", text: $captureBaseURL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .multilineTextAlignment(.trailing)
                            .font(.callout.monospaced())
                            .disabled(!captureOverride)
                    }
                    LabeledContent("API Key") {
                        SecureField("Key", text: $captureAPIKey)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Endpoint") {
                        TextField("/v1/capture", text: $captureEndpoint)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .multilineTextAlignment(.trailing)
                            .font(.callout.monospaced())
                    }
                    Button {
                        Task { await runDiscovery() }
                    } label: {
                        HStack {
                            Label("Scan Network", systemImage: "antenna.radiowaves.left.and.right")
                            Spacer()
                            if networkDiscovery.isScanning { ProgressView() }
                        }
                    }
                    .disabled(networkDiscovery.isScanning || captureOverride)
                } header: {
                    Text("Connection")
                } footer: {
                    Text(captureOverride ? "Using manual address." : "Auto-discovered on your network.")
                }
                .onChange(of: captureBaseURL) { _, _ in Task { await captureClient.updateConfig(baseURL: captureBaseURL, apiKey: captureAPIKey) } }
                .onChange(of: captureAPIKey) { _, _ in Task { await captureClient.updateConfig(baseURL: captureBaseURL, apiKey: captureAPIKey) } }
            }
            .navigationTitle("Glasses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showGlassesSettings = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    private var serverSheet: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    LabeledContent("Connection") {
                        HStack(spacing: 6) {
                            Circle().fill(latencyMonitor.current.serverReachable ? .green : .red).frame(width: 8, height: 8)
                            Text(latencyMonitor.current.serverReachable ? "Connected" : "Offline")
                        }
                    }
                    if let ms = latencyMonitor.current.serverMs {
                        LabeledContent("Latency", value: "\(Int(ms))ms")
                    }
                    if latencyMonitor.stats.avgServerMs > 0 {
                        LabeledContent("Average", value: "\(Int(latencyMonitor.stats.avgServerMs))ms")
                    }
                }

                Section {
                    Toggle("Manual Address", isOn: $processingOverride)
                    LabeledContent("URL") {
                        TextField("URL", text: $processingBaseURL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .multilineTextAlignment(.trailing)
                            .font(.callout.monospaced())
                            .disabled(!processingOverride)
                    }
                    LabeledContent("API Key") {
                        SecureField("Key", text: $processingAPIKey)
                            .multilineTextAlignment(.trailing)
                    }
                    Button {
                        Task { await runDiscovery() }
                    } label: {
                        HStack {
                            Label("Scan Network", systemImage: "antenna.radiowaves.left.and.right")
                            Spacer()
                            if networkDiscovery.isScanning { ProgressView() }
                        }
                    }
                    .disabled(networkDiscovery.isScanning || processingOverride)

                    Picker("Processing", selection: processingMode) {
                        ForEach(ProcessingMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text(processingOverride ? "Using manual address." : "Auto-discovered on your network.")
                }
                .onChange(of: processingBaseURL) { _, _ in Task { await processingClient.updateConfig(baseURL: processingBaseURL, apiKey: processingAPIKey) } }
                .onChange(of: processingAPIKey) { _, _ in Task { await processingClient.updateConfig(baseURL: processingBaseURL, apiKey: processingAPIKey) } }
            }
            .navigationTitle("Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showServerSettings = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    private var captureRateLabel: String {
        let cycleMs = autoCaptureLoop.avgCycleMs
        guard cycleMs > 0 else { return "--" }
        let fps = 1000.0 / cycleMs
        return fps >= 1 ? String(format: "%.1f/s", fps) : String(format: "%.1fs", cycleMs / 1000.0)
    }


    private var buttonIcon: String {
        if autoCaptureLoop.isPaused { return "play.fill" }
        if autoCaptureLoop.isRunning { return "pause.fill" }
        return "play.fill"
    }

    private var buttonFillColor: Color {
        if autoCaptureLoop.isPaused { return Color.orange.opacity(0.1) }
        if autoCaptureLoop.isRunning { return Color.green.opacity(0.1) }
        return allConnected ? Color.blue.opacity(0.1) : Color(.systemGray5)
    }

    private var buttonIconColor: Color {
        if autoCaptureLoop.isPaused { return .orange }
        if autoCaptureLoop.isRunning { return .green }
        return allConnected ? .blue : .gray
    }

    private var buttonAccessibilityLabel: String {
        if autoCaptureLoop.isPaused { return "Resume" }
        if autoCaptureLoop.isRunning { return "Pause" }
        return "Start"
    }


    private func latencyColor(_ ms: Double) -> Color {
        switch ms {
        case ..<100: return .green
        case ..<300: return .yellow
        default: return .red
        }
    }

    private func stateColor(_ state: AutoCaptureLoop.State) -> Color {
        switch state {
        case .idle: return .gray
        case .capturing: return .blue
        case .processing: return .orange
        case .speaking: return .green
        case .waiting: return .secondary
        }
    }

    private func stateIcon(_ state: AutoCaptureLoop.State) -> String {
        switch state {
        case .idle: return "circle"
        case .capturing: return "camera.fill"
        case .processing: return "gearshape.2.fill"
        case .speaking: return "speaker.wave.2.fill"
        case .waiting: return "clock.fill"
        }
    }

    private func stateLabel(_ state: AutoCaptureLoop.State) -> String {
        switch state {
        case .idle: return "Idle"
        case .capturing: return "Capturing"
        case .processing: return "Processing"
        case .speaking: return "Speaking"
        case .waiting: return "Waiting"
        }
    }
}
