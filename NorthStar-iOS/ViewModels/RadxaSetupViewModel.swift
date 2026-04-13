// radxa wifi setup flow - hotspot detection, token, wifi config
import SwiftUI

@MainActor
@Observable
final class RadxaSetupViewModel {


    static let hotspotSSID = "radxa-setup"
    static let hotspotBaseURL = "http://10.42.0.1:8080"
    static let mdnsBaseURL = "http://radxa.local:8080"


    enum SetupPhase: String {
        case detecting       // checking current network
        case onHotspot       // connected to radxa-setup
        case tokenSetup      // setting up token (first time)
        case tokenEntry      // entering existing token (returning to hotspot)
        case wifiSelect      // choosing a network
        case wifiPassword    // entering password
        case connecting      // Radxa switching networks
        case reconnecting    // polling radxa.local
        case connected       // ready to use
        case failed          // something went wrong
    }

    var phase: SetupPhase = .detecting
    var isLoading = false
    var errorMessage: String?

    // Token
    var newToken: String = ""

    // Wi-Fi
    var networks: [RadxaWifiNetwork] = []
    var selectedNetwork: RadxaWifiNetwork?
    var wifiPassword: String = ""

    // Enterprise WiFi
    var isEnterpriseMode = false
    var enterpriseUsername: String = ""
    var enterpriseEAPMethod: String = "peap"
    var enterprisePhase2: String = "mschapv2"

    // Connection info
    var radxaStatus: RadxaReadyResponse?
    var currentSSID: String?
    private var activeBaseURL: String = hotspotBaseURL

    // Persisted values
    @ObservationIgnored
    var onSetupComplete: ((String, String) -> Void)? // (baseURL, apiKey)

    private let service = RadxaService()

    // tries mdns first then hotspot ip

    // Check if we're on the Radxa hotspot or can reach Radxa via mDNS.
    func detectRadxa() async {
        phase = .detecting
        isLoading = true
        errorMessage = nil

        // Try both mDNS and hotspot - either could respond
        let status: RadxaReadyResponse?
        let baseURL: String

        if let s = try? await service.readyz(baseURL: activeBaseURL) {
            // Prefer hotspot check first - if we're on the hotspot, we need setup
            status = s
            baseURL = Self.hotspotBaseURL
        } else if let s = try? await service.readyz(baseURL: Self.mdnsBaseURL) {
            status = s
            baseURL = Self.mdnsBaseURL
        } else {
            status = nil
            baseURL = Self.hotspotBaseURL
        }

        // If Radxa is in hotspot mode, always go to WiFi setup
        if let status, status.network?.mode == "hotspot" {
            radxaStatus = status
            activeBaseURL = baseURL
            if status.tokenConfigured == true {
                let savedKey = UserDefaults.standard.string(forKey: "serverAPIKey") ?? ""
                if !savedKey.isEmpty {
                    do {
                        _ = try await service.wifiStatus(baseURL: baseURL, apiKey: savedKey)
                        newToken = savedKey
                        phase = .wifiSelect
                        await scanNetworks()
                        isLoading = false
                        return
                    } catch {}
                }
                phase = .tokenEntry
            } else {
                phase = .tokenSetup
            }
            isLoading = false
            return
        }

        // Radxa is on a real network - we're good
        if let status {
            radxaStatus = status
            phase = .connected
            isLoading = false
            return
        }

        errorMessage = "Cannot reach Radxa. Make sure you're connected to the \"radxa-setup\" Wi-Fi network, or that the Radxa is on the same network."
        phase = .failed
        isLoading = false
    }


    func submitToken() async {
        guard newToken.count >= 8 else {
            errorMessage = "Token must be at least 8 characters."
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            _ = try await service.setupToken(newToken, baseURL: activeBaseURL)
            phase = .wifiSelect
            await scanNetworks()
        } catch {
            errorMessage = "Failed to set token: \(error.localizedDescription)"
        }

        isLoading = false
    }

    // Verify an existing token and proceed to Wi-Fi selection.
    func submitExistingToken() async {
        guard !newToken.isEmpty else {
            errorMessage = "Enter the token you previously configured."
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            _ = try await service.wifiStatus(baseURL: activeBaseURL, apiKey: newToken)
            phase = .wifiSelect
            await scanNetworks()
        } catch {
            errorMessage = "Token rejected. Make sure you're using the token you originally set up."
        }

        isLoading = false
    }


    func scanNetworks() async {
        isLoading = true
        errorMessage = nil

        do {
            networks = try await service.scanNetworks(baseURL: activeBaseURL, apiKey: newToken)
            networks.sort { $0.signalInt > $1.signalInt }
        } catch {
            errorMessage = "Failed to scan networks: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func selectNetwork(_ network: RadxaWifiNetwork) {
        selectedNetwork = network
        wifiPassword = ""
        enterpriseUsername = ""
        enterpriseEAPMethod = "peap"
        enterprisePhase2 = "mschapv2"
        isEnterpriseMode = network.isEnterprise
        phase = .wifiPassword
    }

    func submitWifiCredentials() async {
        guard let network = selectedNetwork else { return }

        isLoading = true
        errorMessage = nil
        phase = .connecting

        do {
            if isEnterpriseMode {
                _ = try await service.configureEnterpriseWifi(
                    ssid: network.ssid,
                    identity: enterpriseUsername,
                    password: wifiPassword,
                    eapMethod: enterpriseEAPMethod,
                    phase2Auth: enterprisePhase2,
                    baseURL: activeBaseURL,
                    apiKey: newToken
                )
            } else {
                _ = try await service.configureWifi(
                    ssid: network.ssid,
                    password: wifiPassword,
                    baseURL: activeBaseURL,
                    apiKey: newToken
                )
            }

            // The Radxa is now switching networks. Poll mDNS until it's reachable.
            phase = .reconnecting
            await pollForReconnection()
        } catch {
            errorMessage = "Failed to send Wi-Fi credentials: \(error.localizedDescription)"
            phase = .wifiSelect
        }

        isLoading = false
    }

    private func pollForReconnection() async {
        // Give the Radxa time to switch networks (it waits 2s + connect + IP assignment)
        try? await Task.sleep(for: .seconds(5))

        for _ in 1...20 {
            guard !Task.isCancelled else { return }
            do {
                let status = try await service.readyz(baseURL: Self.mdnsBaseURL)
                radxaStatus = status
                phase = .connected

                // Notify the app to store the connection details
                onSetupComplete?(Self.mdnsBaseURL, newToken)
                return
            } catch {
                // Wait 2s between attempts (total ~45s timeout)
                try? await Task.sleep(for: .seconds(2))
            }
        }

        errorMessage = "Could not reconnect to Radxa on the new network. The Radxa may have fallen back to hotspot mode - reconnect to \"radxa-setup\" and try again."
        phase = .failed
    }


    func startOver() {
        phase = .detecting
        isLoading = false
        errorMessage = nil
        newToken = ""
        networks = []
        selectedNetwork = nil
        wifiPassword = ""
        enterpriseUsername = ""
        enterpriseEAPMethod = "peap"
        enterprisePhase2 = "mschapv2"
        radxaStatus = nil
        activeBaseURL = Self.hotspotBaseURL
    }
}
