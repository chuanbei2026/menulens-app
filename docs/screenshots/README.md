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
| `01_canvas` | **主图** —— 原版式就地翻译，带多人点单标记 |
| `02_list` | 菜品列表：「值得点」推荐、带 AI 角标的配图、成员筹码 |
| `03_pages` | 多页菜单翻到一半：第 1 页已可看，第 2 页还在翻译（「1/2 页」横幅） |
| `04_account` | 设置 → 账号：「未登录（本机账号）」、余额、点数图表（假数据）、买点数、可选的 Apple 登录 |
| `05_start` | 全新安装后的首页：不用登录，直接可拍（1.1 (4) 起替代 `05_signin`，那张是必须登录的卡片） |
| `06_server` | 原文菜单 + 点单标记，给服务员看（仅 iPhone） |
| `../iap-review-shop.png` | 内购审核截图：商店（三档点数包和价格），iPhone · en |

## 怎么重拍

```bash
# 1) 装好对应模拟器：iPhone 17 Pro Max、iPad Pro 13-inch
# 2) 为目标模拟器构建
xcodebuild -project MenuLens.xcodeproj -scheme MenuLens -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath build build
# 3) 跑 tools/shoot-screenshots.sh（见该脚本头部注释）
```

拍摄依赖 `ContentView.swift` 里的 DEBUG 启动参数（`-openLatest` / `-listMode` /
`-showOriginal` / `-demoCart` / `-demoReceiving` / `-showSettings` / `-sessionToken` /
`-signOut` / `-storefront` / `-target_language`），所以**必须用 Debug 构建**拍，
Release 里那些钩子被编译掉了。

- **要一个开发用 session token**（`SESSION_TOKEN=…`，签发方法见 `backend/README.md`）：01–03、06 用它。
  `04_account` 用脚本自己拼的本机账号 session（不发给服务器）+ `-demoUsage` 假数据；`05_start` 是全新安装。
  只重拍其中几张：`SHOTS="04 05"`（这两张不需要 `SESSION_TOKEN`）。
- **Debug 构建要签名**（不要 `CODE_SIGNING_ALLOWED=NO`），否则模拟器里 Keychain 存不进去。
- **不花点数**：全部用内置示例菜单。`03_pages` 用 `-demoReceiving` 把双页示例的第 2 页
  显示成「翻译中」—— 和真实扫描到一半时同一套界面，但不发请求（响应缓存在每种语言
  重装时会被清掉，没法靠缓存重现）。
- `-storefront USA`：按美区拍（所有模型、配图开启）。
- 模拟器可能被别的会话关掉；脚本每次启动前会检查并重新启动设备、重设状态栏。

每种语言开拍前会先 `simctl uninstall` 清沙盒 —— 内置示例是「首次启动时按当时的
App 语言 seed 一次」，不重装就还是上一种语言的那套。

内购审核截图（`iap-review-shop.png`）不在脚本里：商店的商品只有在 StoreKit 测试配置
（`MenuLens/Products.storekit`）下才有，用 `MenuLensTests/ShopTests` 在 iPhone 17 Pro Max
上把商店页摆出来再截（见该测试的注释）。
