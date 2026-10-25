import Foundation

/// The result screen's three views, left to right.
enum ResultTab: Hashable, CaseIterable {
    case status
    case canvas
    case list

    /// Which view a result opens on. A multi-page scan whose pages are still
    /// coming in opens on the per-page status; everything else — a
    /// single-page scan, a saved scan from History — on the canvas, as before.
    static func initial(pageCount: Int, receivingPages: Bool) -> ResultTab {
        pageCount > 1 && receivingPages ? .status : .canvas
    }

    /// Where to go once every page has finished (done or failed): from the
    /// status view to the canvas, once per scan — unless the user picked a
    /// view themselves since the scan started, or nothing landed to look at.
    static func afterAllPagesFinished(
        current: ResultTab, userChoseView: Bool, anyPageDone: Bool
    ) -> ResultTab? {
        guard current == .status, !userChoseView, anyPageDone else { return nil }
        return .canvas
    }
}

/// How the result screen uses the space it has.
enum ResultArrangement: Equatable {
    /// Status · canvas pages · list, one swipe apart (phones, the folded
    /// iPhone Duo, portrait iPad).
    case pager
    /// Canvas and list side by side, status in the canvas column while pages
    /// come in: the unfolded iPhone Duo (~880 pt beside its system column),
    /// narrower iPad windows. Three columns would leave the list too narrow
    /// to read a dish name on one line.
    case twoColumns
    /// Status, canvas and list at once (landscape iPad).
    case threeColumns

    /// Wide enough for three columns: a landscape iPad (1133 pt and up).
    static let threeColumnWidth: CGFloat = 1000

    static func choose(regularWidth: Bool, size: CGSize) -> ResultArrangement {
        guard regularWidth, size.width > size.height else { return .pager }
        return size.width >= threeColumnWidth ? .threeColumns : .twoColumns
    }
}

/// Photo order (what the result screen shows, failed pages included) vs. the
/// saved scan (only the pages that came back): history, the PDF and the dish
/// pictures on disk use the saved positions.
enum PageCompaction {
    /// Photo index → saved index, for the pages that are present.
    static func map(present: [Bool]) -> [Int: Int] {
        var map: [Int: Int] = [:]
        for (index, isPresent) in present.enumerated() where isPresent {
            map[index] = map.count
        }
        return map
    }

    /// A dish key filed under the `old` saved positions ("p1_s0_i3"), moved
    /// to the `new` ones; nil when its page is no longer saved. `old == nil`
    /// means the key is still in photo order (nothing saved yet).
    static func rekey(_ key: String, from old: [Int: Int]?, to new: [Int: Int]) -> String? {
        guard key.hasPrefix("p"), let separator = key.firstIndex(of: "_"),
              let page = Int(key[key.index(after: key.startIndex) ..< separator])
        else { return nil }
        let photo: Int?
        if let old {
            photo = old.first { $0.value == page }?.key
        } else {
            photo = page
        }
        guard let photo, let moved = new[photo] else { return nil }
        return "p\(moved)" + key[separator...]
    }
}
