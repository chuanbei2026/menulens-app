import PhotosUI
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("openai_model") private var model = "gpt-4.1"
    @AppStorage("thumbnail_grid_mode") private var thumbnailGridMode = true
    @AppStorage("flatten_lighting") private var flattenLighting = true
    @AppStorage("target_language") private var targetLanguageCode = TargetLanguage.simplifiedChinese.rawValue
    @ObservedObject private var party = PartyStore.shared
    @State private var apiKey = KeychainStore.loadAPIKey()
    @State private var newMemberName = ""
    @State private var avatarTargetID: UUID?
    @State private var avatarPickerItem: PhotosPickerItem?
    @State private var showAvatarPicker = false

    private let models = ["gpt-4.1", "gpt-5-mini", "gpt-5", "gpt-4o"]

    private func addMember() {
        party.add(name: newMemberName)
        newMemberName = ""
    }

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
                    Text("实测一页密排菜单（148 行）：gpt-4.1 约 45 秒 / $0.03（推荐，边翻边显示进度）· gpt-5-mini 约 115 秒 / $0.01（更省钱，译名更讲究，但要等更久）· gpt-5 最准也最慢。配图另计，拼图模式约 $0.003/道。")
                }

                Section {
                    ForEach($party.members) { $member in
                        HStack(spacing: 10) {
                            Button {
                                avatarTargetID = member.id
                                showAvatarPicker = true
                            } label: {
                                AvatarView(party: party, memberID: member.id, size: 30)
                            }
                            .buttonStyle(.borderless)
                            TextField("名字", text: $member.name)
                            if party.members.count > 1 {
                                Button {
                                    party.remove(id: member.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.gray)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    HStack {
                        TextField("添加成员…", text: $newMemberName)
                            .onSubmit { addMember() }
                        Button("添加", action: addMember)
                            .disabled(newMemberName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("同行成员")
                } footer: {
                    Text("点菜时可以标记每道菜是谁点的，上菜时按名字对号入座。点头像可从相册上传照片（自动裁成圆形），点 ✕ 删除成员。")
                }
                .photosPicker(isPresented: $showAvatarPicker, selection: $avatarPickerItem, matching: .images)
                .onChange(of: avatarPickerItem) {
                    guard let item = avatarPickerItem, let target = avatarTargetID else { return }
                    Task { @MainActor in
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) {
                            party.setAvatar(image, for: target)
                        }
                        avatarPickerItem = nil
                        avatarTargetID = nil
                    }
                }

                Section {
                    Toggle("整页匀光（推荐）", isOn: $flattenLighting)
                } footer: {
                    Text("消除拍照时的阴影和光斑，纸面变得干净均匀，翻译文字与原版融合得更自然。深色菜单会自动跳过。")
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
