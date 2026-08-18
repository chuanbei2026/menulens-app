import SwiftUI

@MainActor
final class AnalysisViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case analyzing
        case done
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var pickedImage: UIImage?
    @Published var document: MenuDocument?

    /// Model id is a plain preference; the API key lives in the Keychain.
    @AppStorage("openai_model") var model = "gpt-4.1"

    func analyze() async {
        guard let image = pickedImage else { return }
        guard let jpeg = image.jpegDataForUpload() else {
            phase = .failed("无法编码所选图片。")
            return
        }
        phase = .analyzing
        do {
            let client = OpenAIClient(apiKey: KeychainStore.loadAPIKey(), model: model)
            document = try await client.analyzeMenu(jpegData: jpeg)
            phase = .done
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func reset() {
        phase = .idle
        pickedImage = nil
        document = nil
    }
}
