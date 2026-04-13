import UIKit
@MainActor
@Observable
final class ActivityLog {
    struct Entry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let image: UIImage?
        let captureMs: Double
        let processMs: Double
        let totalMs: Double
        let objectCount: Int
        let objects: String // comma-separated labels
        let guidance: String?
        let engine: String // "Server" or "On-Device"
        let error: String?

        var isError: Bool { error != nil }
    }

    var entries: [Entry] = []
    private let maxEntries = 100

    func add(_ entry: Entry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast()
        }
    }

    func clear() {
        entries.removeAll()
    }
}
