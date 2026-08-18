import SwiftUI

/// Scrollable in-app preview of the analyzed menu + "导出 PDF".
struct ResultView: View {
    let document: MenuDocument
    let sourceImage: UIImage
    let onRestart: () -> Void

    @State private var pdfURL: URL?
    @State private var isRenderingPDF = false

    var body: some View {
        List {
            Section {
                LabeledContent("识别语言", value: "\(document.sourceLanguageChinese) (\(document.sourceLanguage))")
                if let name = document.restaurantName {
                    LabeledContent("餐厅", value: name)
                }
                LabeledContent("菜品数", value: "\(document.allItems.count)")
            }

            ForEach(Array(document.sections.enumerated()), id: \.offset) { _, section in
                Section {
                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                        ItemRow(item: item, sourceImage: sourceImage)
                    }
                } header: {
                    if section.originalTitle != nil || section.chineseTitle != nil {
                        Text([section.chineseTitle, section.originalTitle]
                            .compactMap { $0 }.joined(separator: " / "))
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("重新开始", action: onRestart)
            }
            ToolbarItem(placement: .topBarTrailing) {
                if isRenderingPDF {
                    ProgressView()
                } else if let pdfURL {
                    ShareLink(item: pdfURL) {
                        Label("导出 PDF", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button {
                        renderPDF()
                    } label: {
                        Label("生成 PDF", systemImage: "doc.richtext")
                    }
                }
            }
        }
    }

    private func renderPDF() {
        isRenderingPDF = true
        let doc = document
        let image = sourceImage
        Task.detached(priority: .userInitiated) {
            let data = MenuPDFRenderer(document: doc, sourceImage: image).renderPDF()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("MenuLens-\(Int(Date().timeIntervalSince1970)).pdf")
            try? data.write(to: url)
            await MainActor.run {
                pdfURL = url
                isRenderingPDF = false
            }
        }
    }
}

private struct ItemRow: View {
    let item: MenuItemEntry
    let sourceImage: UIImage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                if let photoBox = item.photoBBox,
                   let cropped = sourceImage.crop(normalized: photoBox) {
                    Image(uiImage: cropped)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.originalName)
                        .font(.headline)
                    Text(item.chineseName)
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
                Spacer()
                if let price = item.price {
                    Text(price)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            WordGlossView(words: item.words)

            if let zhDesc = item.chineseDescription {
                Text(zhDesc)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let descWords = item.descriptionWords, !descWords.isEmpty {
                WordGlossView(words: descWords, compact: true)
            }
        }
        .padding(.vertical, 4)
    }
}
