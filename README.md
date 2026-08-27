# ForeignMenu · 外乡人的菜单

拍下外语菜单（**支持多页**），得到一份**同版式、可缩放**的对照 PDF：

- 📷 **输入**：菜单照片，一页或多页（连拍或相册多选，最多 8 页）
- 🧠 **识别**：每页各调一次 OpenAI 视觉模型（默认 `gpt-4.1`，**页间并发**），
  一次请求完成 OCR、版式提取（归一化 bounding box）和整句中文翻译
- 🖼️ **配图**：菜单本身印有照片的菜直接从原图裁剪；没有照片的菜用
  `gpt-image-1` 自动生成小图（一菜一请求、并发窗口 3、逐张落盘，可在设置里关闭）
- 🔍 **浏览**：结果页是内嵌的 PDFKit 查看器 —— 双指缩放、拖动、连续翻页
- 🗂️ **历史**：识别结果自动保存在本机（`Documents/scans/`），主页左上角
  可查看历史记录、重新打开或左滑删除 —— 再去同一家餐厅不用重新识别
- 📄 **输出**：一份大尺寸 PDF
  - **版式页**（每拍摄页一张）：与照片同比例的大页面，原图淡淡地垫在底下，
    每道菜的双语卡片画在它自己的 bbox 位置上 —— 读起来就像原菜单的双语版
  - **附录页**：每道菜一张可读性优先的卡片（配图 + 双语名称/描述 + 价格），分页排版

## Name

App Store 上的名字是 **ForeignMenu**（中文区 **外乡人的菜单**）。

命名走了三轮，记录在此以免重复踩坑：

| 试过 | 结果 |
|---|---|
| `MenuLens` / `口袋菜单` | ❌ 五个开发者在用 MenuLens（其中一个同为旅行类菜单翻译），口袋菜单在中国区被占 |
| `MenuMirror` / `镜中菜单` | ❌ iTunes Search API 七区全绿，但 **App Store Connect 拦了** —— 有人预留了名字却没上架，那种名字 API 看不到 |
| **`ForeignMenu` / `外乡人的菜单`** | ✅ ASC 接受 |

> ⚠️ 教训：**iTunes Search API 只能看到已上架的 App**。预留但未发布的名字它看不到，
> 所以筛查只能排除明显撞名，最终裁判只有 ASC 的名称输入框。改名前先去占名。

中文名不是英文名的直译，而是修正：英文 "foreign" 指向菜单，但真正身在异乡的是**读菜单的人**，
所以中文用「外乡人的菜单」。

**Xcode 工程名、target 名、目录名和 Bundle ID `ai.xiangyang.MenuLens` 一律没改** ——
它们都不对用户可见，改动只会带来无谓的 diff 和签名风险。品牌名只存在于：

| 位置 | 内容 |
|---|---|
| 七份 `Resources/*.lproj/Localizable.strings` | `app.name`（导航栏标题）、`consent.body` 里的行文 |
| 七份 `Resources/*.lproj/InfoPlist.strings` | `CFBundleDisplayName`（桌面图标名） |
| `project.yml` | `CFBundleDisplayName`（基准语言的兜底） |

## Language

设置页里只有**一个**语言开关，它同时决定两件事：**界面语言**和**菜单翻译的目标语言**。
支持 `zh-Hans` / `en` / `ja` / `ko` / `fr` / `es` / `hi`（七种）。
菜单原文语言永远自动识别，不需要设置。

- 全新安装跟随**设备语言**（`AppLanguage.deviceDefault`），设备语言不在上述六种里则回落英文。
- 切换后**立即生效、不需要重启**，也不会丢掉正在看的识别结果。
- 所有界面文案走 `L("key")`（`MenuLens/Sources/Localization/Localization.swift`），
  它按 App 内的选择显式加载 `<lang>.lproj/Localizable.strings`。
  **不要**用 `NSLocalizedString` 或 SwiftUI 的 `Text("字面量")` —— 那两者跟随的是
  *设备* 语言，会出现「界面中文、译文法语」的错配。
- 加新文案：**七份** `MenuLens/Resources/*.lproj/Localizable.strings` 同时加同一个 key
  （键集合和格式占位符必须完全一致），再在代码里 `L("新key")`。
- 加新语言：`AppLanguage` 加一个 case（`displayName` / `promptName` /
  `showsGlutenFree` / `deviceDefault`）→ 建 `<lang>.lproj/` 两份 `.strings` →
  `project.yml` 的 `CFBundleLocalizations` 加一行 → 用
  `tools/retarget_sample.py` 烤该语言的内置示例。
- 已保存的识别结果**保留自己当初的语言**（`MenuScan.targetLanguage`）：换界面语言不会
  重译旧菜单，PDF 表头也仍按那份扫描自己的语言渲染。
- 例外：桌面图标名和相机/相册权限弹窗由 iOS 自己绘制，只能跟随**设备**语言
  （`<lang>.lproj/InfoPlist.strings`）；`EditButton`、搜索框等系统控件同理。

## Architecture

```
拍照/选图 ─► 压缩(≤2000px JPEG) ─► OpenAI Chat Completions
                                       │  response_format: json_schema (strict)
                                       ▼
                              MenuDocument (Codable)
                        ┌──────────────┴──────────────┐
                        ▼                             ▼
              App 内滚动预览                 MenuPDFRenderer
        (List + WordGlossView + 裁剪配图)   (UIGraphicsPDFRenderer)
                                                      │
                                                      ▼
                                            ShareLink 导出 PDF
```

Key files:

| File | Role |
|---|---|
| `MenuLens/Sources/Models/MenuModels.swift` | `MenuDocument` / `MenuSection` / `MenuItemEntry` / `WordGloss` / `NormalizedRect` |
| `MenuLens/Sources/Services/OpenAIClient.swift` | Chat Completions + strict JSON Schema（模型输出直接 decode 成 `MenuDocument`） |
| `MenuLens/Sources/Services/ImageUtilities.swift` | EXIF 方向归一、上传压缩、按归一化 bbox 裁剪配图 |
| `MenuLens/Sources/Services/KeychainStore.swift` | API key 存 Keychain |
| `MenuLens/Sources/PDF/MenuPDFRenderer.swift` | 版式页 + 附录页的 PDF 渲染 |
| `MenuLens/Sources/Views/` | SwiftUI：主流程、结果页、逐词对照 FlowLayout、设置页、相机 |
| `MenuLens/Sources/Localization/Localization.swift` | `L("key")` + `AppLanguage`：按 App 内选择加载 `.lproj`，见上面 Language 一节 |

## Getting started

Prerequisites: 完整的 **Xcode**（App Store 安装；命令行工具不够，iOS 编译需要
Xcode.app），以及 [XcodeGen](https://github.com/yonaskolb/XcodeGen)
（`brew install xcodegen`）。

```bash
git clone <this repo>
cd menulens
xcodegen generate        # 生成 MenuLens.xcodeproj（不进 git）
open MenuLens.xcodeproj
```

Xcode 里选一个模拟器或真机运行。首次使用先点右上角 ⚙️ 设置页，填入你的
OpenAI API key（保存在 Keychain，永不进仓库）。

## Notes

- `*.xcodeproj` 是生成物，已在 `.gitignore` 里；改工程配置请改 `project.yml`
  然后重新 `xcodegen generate`。
- 整页菜单一次请求约 30–90 秒；`gpt-4.1-mini` / `gpt-4o-mini` 更快更便宜，
  但 bbox 精度和小语种逐词对照质量会下降。
- bbox 全部是相对照片的归一化坐标（左上原点，0–1），所以裁剪、App 内预览和
  PDF 版式页共用同一套坐标，不会因分辨率不同而错位。
