// radxa server response models, matches moe's go server json

import Foundation

struct RadxaReadyResponse: Decodable {
    let status: String
    let camera: String?
    let tokenConfigured: Bool?
    let baseUrl: String?
    let network: RadxaNetworkStatus?

    enum CodingKeys: String, CodingKey {
        case status, camera, network
        case tokenConfigured = "token_configured"
        case baseUrl = "base_url"
    }
}

struct RadxaNetworkStatus: Decodable {
    let mode: String
    let connection: String?
    let ip: String?
    let hotspotSsid: String?

    enum CodingKeys: String, CodingKey {
        case mode, connection, ip
        case hotspotSsid = "hotspot_ssid"
    }
}

struct RadxaWifiNetwork: Decodable, Identifiable {
    let ssid: String
    let signal: String
    let security: String

    var id: String { ssid }
    var signalInt: Int { Int(signal) ?? 0 }

    var isEnterprise: Bool {
        let sec = security.lowercased()
        return sec.contains("enterprise") || sec.contains("802.1x") || sec.contains("eap")
    }
}

struct RadxaWifiScanResponse: Decodable {
    let networks: [RadxaWifiNetwork]
}

struct RadxaWifiConfigureResponse: Decodable {
    let status: String
    let ssid: String?
    let message: String?
    let reconnectAt: String?

    enum CodingKeys: String, CodingKey {
        case status, ssid, message
        case reconnectAt = "reconnect_at"
    }
}

struct RadxaTokenResponse: Decodable {
    let status: String
}
