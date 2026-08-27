# App Store 截图

**全部由脚本重拍，勿手工修改** —— 名字、语言、UI 一改就得重拍。

| 目录 | 尺寸 | App Store Connect 槽位 |
|---|---|---|
| `iphone-6.9/<lang>/` | 1320×2868 | 6.9 英寸 iPhone（iPhone 17 Pro Max 原生分辨率） |
| `ipad-13/<lang>/` | 2064×2752 | 13 英寸 iPad（iPad Pro 13" 原生分辨率） |

语言：`en`（主语言）· `zh-Hans` · `fr` · `ko`。
App Store Connect 支持按 locale 上传不同截图；没拍的语言会回落到主语言那套。

| 文件 | 内容 |
|---|---|
| `01_home` | 首页 |
| `02_canvas` | **主图** —— 原版式就地翻译，带多人点单标记 |
| `03_list` | 菜品列表：配图、搜索、成员筹码 |
| `04_server` | 原文菜单 + 点单标记，给服务员看（仅 iPhone） |

## 怎么重拍

```bash
# 1) 装好对应模拟器：iPhone 17 Pro Max、iPad Pro 13-inch
# 2) 为目标模拟器构建
xcodebuild -project MenuLens.xcodeproj -scheme MenuLens -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath build build
# 3) 跑 tools/shoot-screenshots.sh（见该脚本头部注释）
```

拍摄依赖 `ContentView.swift` 里的 DEBUG 启动参数（`-openLatest` /
`-listMode` / `-showOriginal` / `-demoCart` / `-target_language`），
所以**必须用 Debug 构建**拍，Release 里那些钩子被编译掉了。

每种语言开拍前会先 `simctl uninstall` 清沙盒 —— 内置示例是「首次启动时按当时的
App 语言 seed 一次」，不重装就还是上一种语言的那套。
