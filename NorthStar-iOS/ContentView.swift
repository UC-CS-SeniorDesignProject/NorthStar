// main layout - home tab + tools tab

import SwiftUI

struct ContentView: View {
    let captureClient: APIClient
    let processingClient: APIClient

    @AppStorage("processingMode") private var processingModeRaw = ProcessingMode.auto.rawValue
    @AppStorage("captureBaseURL") private var captureBaseURL = "http://radxa.local:8080"
    @AppStorage("processingBaseURL") private var processingBaseURL = "http://localhost:8000"

    @State private var latencyMonitor = LatencyMonitor()
    @State private var radxaWS = RadxaWebSocketService()
    @State private var autoCaptureLoop: AutoCaptureLoop
    @State private var radxaVM = RadxaSetupViewModel()
    @State private var networkDiscovery = NetworkDiscovery()

    private var processingMode: ProcessingMode {
        ProcessingMode(rawValue: processingModeRaw) ?? .auto
    }

    // have to init all the state stuff here bc they depend on each other
    // tried doing it inline but swiftui kept complaining
    init(captureClient: APIClient, processingClient: APIClient) {
        self.captureClient = captureClient
        self.processingClient = processingClient
        // these all depend on each other so order matters
        let monitor = LatencyMonitor()
        let ws = RadxaWebSocketService()
        self._latencyMonitor = State(initialValue: monitor)
        self._radxaWS = State(initialValue: ws)
        self._autoCaptureLoop = State(initialValue: AutoCaptureLoop(
            captureClient: captureClient,
            processingClient: processingClient,
            latencyMonitor: monitor,
            radxaWS: ws,
            processingMode: { ProcessingMode(rawValue: UserDefaults.standard.string(forKey: "processingMode") ?? ProcessingMode.auto.rawValue) ?? .auto },
            manualInterval: {
                let val = UserDefaults.standard.double(forKey: "manualCaptureInterval")
                return val > 0 ? val : nil
            }
        ))
        // when radxa setup finishes it saves the url so we remember it
        let vm = RadxaSetupViewModel()
        vm.onSetupComplete = { baseURL, apiKey in
            UserDefaults.standard.set(baseURL, forKey: "captureBaseURL")
            UserDefaults.standard.set(apiKey, forKey: "captureAPIKey")
            Task { await captureClient.updateConfig(baseURL: baseURL, apiKey: apiKey) }
        }
        self._radxaVM = State(initialValue: vm)
    }

    var body: some View {
        TabView {
            DashboardView(
                latencyMonitor: latencyMonitor,
                autoCaptureLoop: autoCaptureLoop,
                captureClient: captureClient,
                processingClient: processingClient,
                networkDiscovery: networkDiscovery
            )
            .tabItem {
                Label("Home", systemImage: "star.fill")
            }

            toolsTab
                .tabItem {
                    Label("Tools", systemImage: "wrench.and.screwdriver")
                }
        }
        .task {
            // start pinging both servers and connect websocket
            latencyMonitor.start(radxaBaseURL: captureBaseURL, serverBaseURL: processingBaseURL)
            let captureKey = UserDefaults.standard.string(forKey: "captureAPIKey") ?? "radxatoken"
            radxaWS.connect(baseURL: captureBaseURL, apiKey: captureKey)
        }
        .onChange(of: captureBaseURL) { _, _ in
            // url changed reconnect everything
            restartMonitor()
            let captureKey = UserDefaults.standard.string(forKey: "captureAPIKey") ?? "radxatoken"
            radxaWS.disconnect()
            radxaWS.connect(baseURL: captureBaseURL, apiKey: captureKey)
        }
        .onChange(of: processingBaseURL) { _, _ in restartMonitor() }
    }

    // all the dev/testing/config stuff goes here
    private var toolsTab: some View {
        NavigationStack {
            List {
                Section("Performance") {
                    NavigationLink {
                        PerformanceDashboardView(
                            latencyMonitor: latencyMonitor,
                            autoCaptureLoop: autoCaptureLoop
                        )
                    } label: {
                        Label("Performance Dashboard", systemImage: "chart.bar.fill")
                    }

                    NavigationLink {
                        ActivityLogView(activityLog: autoCaptureLoop.activityLog)
                    } label: {
                        Label("Activity Log", systemImage: "list.bullet.rectangle")
                    }
                }

                Section("Testing") {
                    NavigationLink {
                        OCRView(viewModel: OCRViewModel(client: processingClient, mode: { [self] in processingMode }), captureClient: captureClient)
                    } label: {
                        Label("OCR", systemImage: "doc.text.viewfinder")
                    }

                    NavigationLink {
                        DetectView(viewModel: DetectViewModel(client: processingClient, mode: { [self] in processingMode }), captureClient: captureClient)
                    } label: {
                        Label("Detection", systemImage: "eye")
                    }

                    NavigationLink {
                        RemoteCaptureView(viewModel: CaptureViewModel(
                            captureClient: captureClient,
                            processingClient: processingClient,
                            mode: { [self] in processingMode }
                        ))
                    } label: {
                        Label("Manual Capture", systemImage: "camera.on.rectangle")
                    }
                }

                Section("Configuration") {
                    NavigationLink {
                        ServerStatusView(viewModel: ServerViewModel(client: processingClient))
                    } label: {
                        Label("Server Status", systemImage: "server.rack")
                    }

                    NavigationLink {
                        RadxaSetupView(viewModel: radxaVM)
                    } label: {
                        Label("Radxa Setup", systemImage: "antenna.radiowaves.left.and.right")
                    }

                    NavigationLink {
                        CaptureIntervalSettingView()
                    } label: {
                        Label("Capture Interval", systemImage: "timer")
                    }

                    NavigationLink {
                        TTSInfoView()
                    } label: {
                        Label("Text-to-Speech", systemImage: "speaker.wave.2.fill")
                    }
                }
            }
            .navigationTitle("Tools")
        }
    }

    private func restartMonitor() {
        latencyMonitor.start(radxaBaseURL: captureBaseURL, serverBaseURL: processingBaseURL)
    }
}
