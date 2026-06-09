import Foundation

struct Lease {
    let sessionId: String
    let expiry: Date
}

class LeaseWatcher {
    static let leaseDir = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".restnot/leases", isDirectory: true)

    func activeLeases() -> [Lease] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Self.leaseDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let now = Date()
        var active: [Lease] = []

        for file in files {
            guard
                let raw = try? String(contentsOf: file, encoding: .utf8),
                let epoch = TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            else { continue }

            let expiry = Date(timeIntervalSince1970: epoch)
            if expiry > now {
                active.append(Lease(sessionId: file.lastPathComponent, expiry: expiry))
            } else {
                try? fm.removeItem(at: file)
            }
        }

        return active
    }
}
