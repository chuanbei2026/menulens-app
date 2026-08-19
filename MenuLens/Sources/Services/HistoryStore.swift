import SwiftUI
import UIKit

/// Local, on-device history of analyzed menus.
///
/// Layout on disk (app sandbox, survives app restarts, removed on uninstall):
///
///     Documents/scans/<scan-id>/
///         scan.json     the MenuScan (all translations + bboxes)
///         page_0.jpg    photographed pages, in order
///         page_1.jpg
///
/// Scans are text-heavy and small (a few hundred KB with images), so the
/// store keeps all `MenuScan` records in memory; page images are loaded
/// lazily only when a record is opened.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    /// All saved scans, newest first.
    @Published private(set) var scans: [MenuScan] = []

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        refresh()
    }

    private var rootURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("scans", isDirectory: true)
    }

    private func directory(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func refresh() {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: nil)) ?? []
        scans = entries
            .compactMap { entry -> MenuScan? in
                guard let data = try? Data(contentsOf: entry.appendingPathComponent("scan.json"))
                else { return nil }
                return try? decoder.decode(MenuScan.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func save(scan: MenuScan, images: [UIImage]) {
        let dir = directory(for: scan.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? encoder.encode(scan).write(to: dir.appendingPathComponent("scan.json"))
        for (index, image) in images.enumerated() {
            try? image.jpegDataForUpload(maxDimension: 2000)?
                .write(to: dir.appendingPathComponent("page_\(index).jpg"))
        }
        refresh()
    }

    /// Load the photographed pages for a saved scan, in page order.
    /// Missing files yield a shorter array; consumers must index defensively.
    func loadImages(for scan: MenuScan) -> [UIImage] {
        let dir = directory(for: scan.id)
        return (0 ..< scan.pages.count).compactMap { index in
            UIImage(contentsOfFile: dir.appendingPathComponent("page_\(index).jpg").path)
        }
    }

    func delete(_ scan: MenuScan) {
        try? FileManager.default.removeItem(at: directory(for: scan.id))
        refresh()
    }

    // MARK: - AI-generated dish thumbnails (gen_<dishKey>.jpg alongside the scan)

    func saveGeneratedImage(_ image: UIImage, scanID: UUID, dishKey: String) {
        let url = directory(for: scanID).appendingPathComponent("gen_\(dishKey).jpg")
        try? image.jpegData(compressionQuality: 0.8)?.write(to: url)
    }

    func loadGeneratedImages(for scan: MenuScan) -> [String: UIImage] {
        let dir = directory(for: scan.id)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var result: [String: UIImage] = [:]
        for file in files where file.hasPrefix("gen_") && file.hasSuffix(".jpg") {
            let key = String(file.dropFirst("gen_".count).dropLast(".jpg".count))
            result[key] = UIImage(contentsOfFile: dir.appendingPathComponent(file).path)
        }
        return result
    }
}
