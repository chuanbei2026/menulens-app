import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("openai_model") private var model = "gpt-4.1"
    @AppStorage("generate_dish_images") private var generateDishImages = true
    @AppStorage("thumbnail_grid_mode") private var thumbnailGridMode = true
    @State private var apiKey = KeychainStore.loadAPIKey()

    private let models = ["gpt-4.1", "gpt-4o", "gpt-4.1-mini", "gpt-4o-mini"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-...", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("OpenAI API Key")
                } footer: {
                    Text("Key 仅保存在本机 Keychain 中，不会随代码或备份明文外泄。")
                }

                Section {
                    Picker("模型", selection: $model) {
                        ForEach(models, id: \.self) { Text($0) }
                    }
                } footer: {
                    Text("识别整页菜单建议用 gpt-4.1 或 gpt-4o；mini 版更快更便宜，但版式坐标和小语种翻译的质量会下降。")
                }

                Section {
                    Toggle("自动生成菜品配图", isOn: $generateDishImages)
                    if generateDishImages {
                        Toggle("拼图省钱模式", isOn: $thumbnailGridMode)
                    }
                } footer: {
                    Text("菜单上没有照片的菜，用 gpt-image-1 自动生成小图。拼图模式一次生成 2×2 四宫格再切开，每道菜约 $0.003（单张模式约 $0.011，画质稍好）。菜单本身的照片始终优先使用。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        KeychainStore.saveAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}
