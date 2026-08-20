import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("openai_model") private var model = "gpt-4.1"
    @AppStorage("thumbnail_grid_mode") private var thumbnailGridMode = true
    @AppStorage("target_language") private var targetLanguageCode = TargetLanguage.simplifiedChinese.rawValue
    @State private var apiKey = KeychainStore.loadAPIKey()

    private let models = ["gpt-4.1", "gpt-4o", "gpt-4.1-mini", "gpt-4o-mini"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("目标语言", selection: $targetLanguageCode) {
                        ForEach(TargetLanguage.allCases) { language in
                            Text(language.displayName).tag(language.rawValue)
                        }
                    }
                } footer: {
                    Text("菜单会被翻译成该语言。菜单本身的语言无需设置，自动识别。")
                }

                Section {
                    SecureField("sk-...", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Link(destination: URL(string: "https://platform.openai.com/api-keys")!) {
                        Label("如何获取 OpenAI API Key？", systemImage: "questionmark.circle")
                    }
                } header: {
                    Text("OpenAI API Key")
                } footer: {
                    Text("在上方链接的 OpenAI 平台注册并充值后，创建一个 Key 粘贴到这里。Key 只保存在你手机本地的系统钥匙串（Keychain）中，只用于直接调用 OpenAI —— 不会上传到任何云端，本 App 没有自己的服务器。")
                }

                Section {
                    Picker("模型", selection: $model) {
                        ForEach(models, id: \.self) { Text($0) }
                    }
                } footer: {
                    Text("识别整页菜单建议用 gpt-4.1 或 gpt-4o；mini 版更快更便宜，但版式坐标和小语种翻译的质量会下降。")
                }

                Section {
                    Toggle("拼图省钱模式", isOn: $thumbnailGridMode)
                } footer: {
                    Text("是否生成配图在主界面每次识别前勾选。拼图模式一次生成 2×2 四宫格再切开，每道菜约 $0.003（单张模式约 $0.011，画质稍好）。菜单本身的照片始终优先使用。")
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
