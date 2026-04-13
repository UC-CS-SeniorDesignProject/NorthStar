// scans network to find radxa and server automatically
import Foundation
@MainActor
@Observable
final class NetworkDiscovery {

    var isScanning = false
    var discoveredRadxaURL: String?
    var discoveredServerURL: String?
    var scanProgress: Double = 0 // 0.0–1.0
    private var cancelled = false

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 1.5
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    // Cancel an in-progress scan.
    func cancel() {
        cancelled = true
    }

    // Full discovery: tries mDNS first, then subnet scan.
    func discover() async {
        isScanning = true
        cancelled = false
        scanProgress = 0
        discoveredRadxaURL = nil
        discoveredServerURL = nil

        // Phase 1: Try mDNS names (fast, no scan needed)
        scanProgress = 0.05
        async let radxaMdns = tryHost("http://radxa.local:8080")
        async let serverMdns = tryHost("http://northstar-server.local:8000")

        let (radxaOk, serverOk) = await (radxaMdns, serverMdns)
        if radxaOk { discoveredRadxaURL = "http://radxa.local:8080" }
        if serverOk { discoveredServerURL = "http://northstar-server.local:8000" }

        // Phase 2: If either is still missing and not cancelled, scan the subnet
        if !cancelled && (discoveredRadxaURL == nil || discoveredServerURL == nil) {
            await scanSubnet()
        }

        scanProgress = 1.0
        isScanning = false
    }

    enum DiscoveryResult: Sendable {
        case radxa(String)
        case server(String)
    }

    // Scan the local subnet for devices responding to /healthz on known ports.
    private func scanSubnet() async {
        guard let subnet = getSubnet() else { return }

        let batchSize = 20
        let totalHosts = 254
        var scanned = 0

        for batchStart in stride(from: 1, through: totalHosts, by: batchSize) {
            let batchEnd = min(batchStart + batchSize - 1, totalHosts)
            let needRadxa = discoveredRadxaURL == nil
            let needServer = discoveredServerURL == nil

            let results = await withTaskGroup(of: DiscoveryResult?.self, returning: [DiscoveryResult].self) { group in
                for i in batchStart...batchEnd {
                    let ip = "\(subnet).\(i)"
                    group.addTask { [self] in
                        if needRadxa {
                            let url = "http://\(ip):8080"
                            if await self.identifyRadxa(url) { return .radxa(url) }
                        }
                        if needServer {
                            let url = "http://\(ip):8000"
                            if await self.identifyServer(url) { return .server(url) }
                        }
                        return nil
                    }
                }
                var found: [DiscoveryResult] = []
                for await result in group {
                    if let r = result { found.append(r) }
                }
                return found
            }

            for result in results {
                switch result {
                case .radxa(let url): discoveredRadxaURL = url
                case .server(let url): discoveredServerURL = url
                }
            }

            scanned += (batchEnd - batchStart + 1)
            scanProgress = 0.1 + 0.9 * (Double(scanned) / Double(totalHosts))

            if discoveredRadxaURL != nil && discoveredServerURL != nil { break }
            if cancelled { break }
        }
    }

    // Check if a host is the Radxa (has network.mode in readyz).
    private nonisolated func identifyRadxa(_ baseURL: String) async -> Bool {
        guard let url = URL(string: baseURL + "/readyz") else { return false }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["network"] != nil {
                return true
            }
        } catch {}
        return false
    }

    // Check if a host is the OCR/OD server (has paddleocr_version or yolo_device in readyz).
    private nonisolated func identifyServer(_ baseURL: String) async -> Bool {
        guard let url = URL(string: baseURL + "/readyz") else { return false }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["paddleocr_version"] != nil || json["yolo_device"] != nil {
                return true
            }
        } catch {}
        return false
    }

    // Simple check if a host responds to /healthz.
    private nonisolated func tryHost(_ baseURL: String) async -> Bool {
        guard let url = URL(string: baseURL + "/healthz") else { return false }
        do {
            let (_, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            return true
        } catch {
            return false
        }
    }

    // Get the first 3 octets of the device's local IP (e.g. "192.168.1").
    private func getSubnet() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let addr = ptr.pointee
            guard addr.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: addr.ifa_name)
            // en0 = WiFi on iOS
            guard name == "en0" else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr.ifa_addr, socklen_t(addr.ifa_addr.pointee.sa_len),
                           &hostname, socklen_t(hostname.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: hostname)
                let parts = ip.split(separator: ".")
                if parts.count == 4 {
                    return "\(parts[0]).\(parts[1]).\(parts[2])"
                }
            }
        }
        return nil
    }
}
