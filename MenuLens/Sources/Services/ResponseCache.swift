import CryptoKit
import Foundation

/// Disk cache for expensive API results, keyed by a SHA-256 of the exact
/// request inputs. Identical requests (same photo bytes, model, target
/// language, prompt version) are answered locally for free — which is most
/// of what development iteration and "re-scan the same menu" do.
enum ResponseCache {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("api-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func key(_ parts: [Data]) -> String {
        var hasher = SHA256()
        for part in parts {
            hasher.update(data: part)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func load(_ key: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(key))
    }

    static func store(_ key: String, _ data: Data) {
        try? data.write(to: directory.appendingPathComponent(key))
    }
}
