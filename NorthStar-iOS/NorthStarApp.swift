// app entry point, two clients for radxa + processing server

import SwiftUI

@main
struct NorthStarApp: App {
    // radxa handles camera capture, processing server handles detection/ocr
    @State private var captureClient = APIClient(baseURL: "http://radxa.local:8080")
    @State private var processingClient = APIClient(baseURL: "http://localhost:8000")

    var body: some Scene {
        WindowGroup {
            ContentView(captureClient: captureClient, processingClient: processingClient)
                .task {
                    // load saved urls and keys from last session
                    let captureURL = UserDefaults.standard.string(forKey: "captureBaseURL") ?? "http://radxa.local:8080"
                    let captureKey = UserDefaults.standard.string(forKey: "captureAPIKey") ?? "radxatoken"
                    await captureClient.updateConfig(baseURL: captureURL, apiKey: captureKey)

                    let processingURL = UserDefaults.standard.string(forKey: "processingBaseURL") ?? "http://localhost:8000"
                    let processingKey = UserDefaults.standard.string(forKey: "processingAPIKey") ?? "test"
                    await processingClient.updateConfig(baseURL: processingURL, apiKey: processingKey)
                }
        }
    }
}
