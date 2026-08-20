import UIKit

/// Programmatic "beautified" re-typeset of the translated menu — the clean
/// poster look a generative model can't deliver (its Chinese glyphs come out
/// as pseudo-characters; ours are real text). Cream paper, navy section
/// banners, two-column flow: original name with a right-aligned price, the
/// translated name in terracotta, the translated description in gray.
/// Used by the in-app 美排 tab (page images) and the PDF export.
struct MenuPosterRenderer {
    let scan: MenuScan

    let pageSize = CGSize(width: 1240, height: 1754)
    private let margin: CGFloat = 76
    private let columnGap: CGFloat = 48
    private var columnWidth: CGFloat { (pageSize.width - 2 * margin - columnGap) / 2 }

    private let paper = UIColor(red: 0.980, green: 0.965, blue: 0.930, alpha: 1)
    private let navy = UIColor(red: 0.115, green: 0.165, blue: 0.290, alpha: 1)
    private let terracotta = UIColor(red: 0.72, green: 0.20, blue: 0.10, alpha: 1)
    private let gray = UIColor(white: 0.32, alpha: 1)

    // MARK: - Layout

    private enum Kind {
        case pageTitle
        case sectionHeader(original: String, translated: String)
        case dish(MenuItemEntry)
    }

    private struct Placed {
        let kind: Kind
        let frame: CGRect
    }

    private func measureDish(_ item: MenuItemEntry) -> CGFloat {
        var height = TextDraw.text(
            item.originalName, font: nameFont, color: .black,
            at: .zero, maxWidth: columnWidth - 86, dryRun: true
        )
        height += 4 + TextDraw.text(
            translatedLine(for: item), font: zhFont, color: terracotta,
            at: .zero, maxWidth: columnWidth, dryRun: true
        )
        if let desc = item.chineseDescription, !desc.isEmpty {
            height += 3 + TextDraw.text(
                desc, font: descFont, color: gray,
                at: .zero, maxWidth: columnWidth, dryRun: true
            )
        }
        return height + 18
    }

    private var nameFont: UIFont { .systemFont(ofSize: 22, weight: .bold) }
    private var priceFont: UIFont { .systemFont(ofSize: 20, weight: .semibold) }
    private var zhFont: UIFont { .systemFont(ofSize: 18, weight: .semibold) }
    private var descFont: UIFont { .systemFont(ofSize: 14) }

    private func translatedLine(for item: MenuItemEntry) -> String {
        var line = item.chineseName
        let emoji = (item.tags ?? []).compactMap { tag -> String? in
            switch tag {
            case "vegan": return "🌱"
            case "vegetarian": return "🥬"
            case "contains_lamb": return "🐑"
            case "contains_seafood": return "🐟"
            default: return nil
            }
        }.joined()
        if !emoji.isEmpty { line += " " + emoji }
        return line
    }

    private func paginate() -> [[Placed]] {
        var pages: [[Placed]] = [[]]
        var pageIndex = 0
        var column = 0

        let titleHeight: CGFloat = 150
        pages[0].append(Placed(
            kind: .pageTitle,
            frame: CGRect(x: margin, y: margin, width: pageSize.width - 2 * margin, height: titleHeight)
        ))
        var columnTop = margin + titleHeight + 34
        var y = columnTop

        func columnX() -> CGFloat { margin + CGFloat(column) * (columnWidth + columnGap) }

        func ensure(_ height: CGFloat) {
            guard y + height > pageSize.height - margin else { return }
            if column == 0 {
                column = 1
            } else {
                column = 0
                pageIndex += 1
                pages.append([])
                columnTop = margin
            }
            y = columnTop
        }

        for document in scan.pages {
            for section in document.sections {
                let original = section.originalTitle ?? ""
                let translated = section.chineseTitle ?? ""
                if !original.isEmpty || !translated.isEmpty {
                    ensure(46 + 14 + 60) // header + at least one small dish
                    pages[pageIndex].append(Placed(
                        kind: .sectionHeader(original: original, translated: translated),
                        frame: CGRect(x: columnX(), y: y, width: columnWidth, height: 46)
                    ))
                    y += 46 + 14
                }
                for item in section.items {
                    let height = measureDish(item)
                    ensure(height)
                    pages[pageIndex].append(Placed(
                        kind: .dish(item),
                        frame: CGRect(x: columnX(), y: y, width: columnWidth, height: height)
                    ))
                    y += height
                }
                y += 10
            }
        }
        return pages
    }

    // MARK: - Drawing

    var pageCount: Int { paginate().count }

    func renderImages() -> [UIImage] {
        let pages = paginate()
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return pages.indices.map { index in
            UIGraphicsImageRenderer(size: pageSize, format: format).image { _ in
                draw(blocks: pages[index])
            }
        }
    }

    /// Append the poster pages to a PDF being built.
    func drawPDFPages(ctx: UIGraphicsPDFRendererContext) {
        for blocks in paginate() {
            ctx.beginPage(withBounds: CGRect(origin: .zero, size: pageSize), pageInfo: [:])
            draw(blocks: blocks)
        }
    }

    private func draw(blocks: [Placed]) {
        paper.setFill()
        UIBezierPath(rect: CGRect(origin: .zero, size: pageSize)).fill()

        for placed in blocks {
            switch placed.kind {
            case .pageTitle:
                drawPageTitle(in: placed.frame)
            case let .sectionHeader(original, translated):
                drawSectionHeader(original: original, translated: translated, in: placed.frame)
            case let .dish(item):
                drawDish(item, in: placed.frame)
            }
        }
    }

    private func drawPageTitle(in frame: CGRect) {
        let name = scan.restaurantName ?? "MENU"
        let serif = UIFont.systemFont(ofSize: 64, weight: .bold)
        let serifDescriptor = serif.fontDescriptor.withDesign(.serif) ?? serif.fontDescriptor
        let titleFont = UIFont(descriptor: serifDescriptor, size: 64)

        let title = name as NSString
        let titleSize = title.size(withAttributes: [.font: titleFont])
        title.draw(
            at: CGPoint(x: frame.midX - titleSize.width / 2, y: frame.minY),
            withAttributes: [.font: titleFont, .foregroundColor: navy]
        )

        let subtitle = "\(scan.sourceLanguageChinese) → \(TargetLanguage.from(code: scan.targetLanguage).displayName)" as NSString
        let subFont = UIFont.systemFont(ofSize: 20, weight: .regular)
        let subSize = subtitle.size(withAttributes: [.font: subFont])
        subtitle.draw(
            at: CGPoint(x: frame.midX - subSize.width / 2, y: frame.minY + titleSize.height + 10),
            withAttributes: [.font: subFont, .foregroundColor: gray]
        )

        navy.withAlphaComponent(0.6).setStroke()
        let rule = UIBezierPath()
        rule.move(to: CGPoint(x: frame.minX, y: frame.maxY - 4))
        rule.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY - 4))
        rule.lineWidth = 2
        rule.stroke()
    }

    private func drawSectionHeader(original: String, translated: String, in frame: CGRect) {
        navy.setFill()
        UIBezierPath(roundedRect: frame, cornerRadius: 4).fill()

        var title = original
        if !translated.isEmpty, translated != original {
            title = original.isEmpty ? translated : "\(original) · \(translated)"
        }
        let font = UIFont.systemFont(ofSize: 21, weight: .bold)
        let text = title as NSString
        let size = text.size(withAttributes: [.font: font])
        text.draw(
            at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2),
            withAttributes: [.font: font, .foregroundColor: UIColor.white]
        )
    }

    private func drawDish(_ item: MenuItemEntry, in frame: CGRect) {
        var y = frame.minY

        let nameHeight = TextDraw.text(
            item.originalName, font: nameFont, color: .black,
            at: CGPoint(x: frame.minX, y: y), maxWidth: frame.width - 86
        )
        if let price = item.price {
            let text = price as NSString
            let size = text.size(withAttributes: [.font: priceFont])
            text.draw(
                at: CGPoint(x: frame.maxX - size.width, y: y + 1),
                withAttributes: [.font: priceFont, .foregroundColor: navy]
            )
        }
        y += nameHeight + 4

        y += TextDraw.text(
            translatedLine(for: item), font: zhFont, color: terracotta,
            at: CGPoint(x: frame.minX, y: y), maxWidth: frame.width
        )

        if let desc = item.chineseDescription, !desc.isEmpty {
            y += 3
            TextDraw.text(
                desc, font: descFont, color: gray,
                at: CGPoint(x: frame.minX, y: y), maxWidth: frame.width
            )
        }
    }
}
