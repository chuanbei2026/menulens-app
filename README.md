# MenuLens

拍下外语菜单（**支持多页**），得到一份**同版式、可缩放**的中文对照 PDF：

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
