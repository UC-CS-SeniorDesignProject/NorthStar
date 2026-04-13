// server vs on device vs auto mode

import Foundation

enum ProcessingMode: String, CaseIterable, Identifiable {
    case auto = "auto"
    case server = "server"
    case onDevice = "onDevice"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto (fallback to on-device)"
        case .server: return "Server Only"
        case .onDevice: return "On-Device Only (Apple Vision)"
        }
    }

    var icon: String {
        switch self {
        case .auto: return "arrow.triangle.branch"
        case .server: return "server.rack"
        case .onDevice: return "iphone"
        }
    }
}
