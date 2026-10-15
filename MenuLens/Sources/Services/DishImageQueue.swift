import UIKit

/// Dish thumbnails for one scan, generated through a small concurrency
/// window. Dishes can be added while the scan is still coming in (one page
/// at a time), so pictures for page 1 start before page 3 is translated.
///
/// In grid mode dishes are batched four to a 2x2 collage (~4x cheaper per
/// dish). Leftovers wait in a buffer for the next page's dishes and are only
/// sent as single pictures on `finish()` — so a scan whose pages arrive in
/// order makes exactly the requests one all-at-once batch would.
@MainActor
final class DishImageQueue {
    typealias Dish = (key: String, spec: ImageGenClient.DishSpec)

    private enum Job {
        case grid([Dish])
        case single(Dish)
    }

    /// One result per dish, keyed as it was added; nil when generation failed.
    var onResult: ((String, UIImage?) -> Void)?
    /// Called once, after `finish()`, when nothing is queued or in flight.
    var onDrained: (() -> Void)?

    let client: ImageGenClient
    private let gridMode: Bool
    /// 2-wide: stays under the image model's images-per-minute cap.
    private let window = 2
    private var buffer: [Dish] = []
    private var jobs: [Job] = []
    private var running = 0
    private var finished = false
    private var drained = false
    private var tasks: [Task<Void, Never>] = []
    private(set) var isCancelled = false

    /// Why generation stopped early (out of credits, signed out), if it did.
    var stopReason: Backend.BackendError? { client.stopReason }

    init(client: ImageGenClient, gridMode: Bool) {
        self.client = client
        self.gridMode = gridMode
    }

    func add(_ dishes: [Dish]) {
        guard !isCancelled, !finished else { return }
        if gridMode {
            buffer += dishes
            while buffer.count >= 4 {
                jobs.append(.grid(Array(buffer.prefix(4))))
                buffer.removeFirst(4)
            }
        } else {
            jobs += dishes.map { .single($0) }
        }
        pump()
    }

    /// No more dishes are coming: send the leftovers one by one.
    func finish() {
        guard !isCancelled, !finished else { return }
        finished = true
        jobs += buffer.map { .single($0) }
        buffer = []
        pump()
    }

    func cancel() {
        isCancelled = true
        tasks.forEach { $0.cancel() }
        tasks = []
        jobs = []
        buffer = []
    }

    private func pump() {
        // Out of credits (or signed out): queue nothing more.
        if stopReason != nil { jobs = [] }
        while running < window, !jobs.isEmpty {
            let job = jobs.removeFirst()
            running += 1
            let client = client
            tasks.append(Task { [weak self] in
                let results: [(String, UIImage?)]
                switch job {
                case let .single(dish):
                    results = [(dish.key, await client.generateDishThumbnail(dish.spec))]
                case let .grid(cells):
                    let images = await client.generateDishGrid(cells.map(\.spec))
                    results = cells.enumerated().map { index, cell in (cell.key, images?[index]) }
                }
                guard let self, !self.isCancelled else { return }
                self.running -= 1
                for (key, image) in results { self.onResult?(key, image) }
                self.pump()
            })
        }
        if finished, running == 0, jobs.isEmpty, !drained, !isCancelled {
            drained = true
            onDrained?()
        }
    }
}
