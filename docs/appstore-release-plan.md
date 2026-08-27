# 上架路线图与阻碍分析 — MenuMirror · 镜中菜单

> 写于 2026-08-26，更新 2026-08-27。已有 Apple Developer Program 会员（个人，$99/年）。
> 与 `appstore-metadata.md` 配套：那份是**提交时要粘贴的素材**，这份是**顺序、
> 阻碍和判断**。两份里的 checklist 以这份为准 —— 调研后发现原 checklist 有
> 两处结论已经过期/写错了（见 🔴-2 和 🔴-3）。

---

## 0. 一句话结论

**2026-08-27 更新：原来那四条「会被拒」的问题已经全部修完（见下面各条的 ✅），
但查名字时发现了一条更早、更硬的阻碍 —— 「MenuLens」这个名字在 App Store 上
已经被至少五个开发者占用，其中一个就是同类目的直接竞品。名字不换，连 App
Store Connect 那一步都过不去。**

**再更新：名字已定为 MenuMirror / 镜中菜单并全局替换完毕，EU trader 三项也已齐。
代码侧和元数据侧现在都是干净的 —— 剩下的只有商标查询和打包提审。**

---

## 1. 现状盘点

| 项 | 状态 | 位置 |
|---|---|---|
| Bundle ID `ai.xiangyang.MenuLens` | 待在 App Store Connect 注册 | `project.yml` |
| 签名 Team `LNP5ER743F` | 已写死在 `project.yml`（需确认已是**付费**个人 Team，不是 Personal Team） | `project.yml` |
| Xcode / SDK | ✅ Xcode 26.6，满足 2026-04-28 起「必须 iOS 26 SDK」的硬要求 | 本机 |
| 版本号 | ✅ `1.0 (1)`，已由 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 驱动 | `project.yml` |
| Release 构建 / Archive | ✅ 都通过（arm64，`MinimumOSVersion 17.0`） | — |
| 出口合规 | ✅ `ITSAppUsesNonExemptEncryption = false`（只用标准 HTTPS） | `Info.plist` |
| 隐私政策 URL | ✅ 已上线（GitHub Pages） | `docs/privacy-policy.html` |
| 技术支持 URL | ✅ GitHub repo | — |
| 6.9" iPhone 截图 | ✅ 1320×2868，4 语言 × 4 张（已重拍） | `docs/screenshots/iphone-6.9/` |
| 13" iPad 截图 | ✅ 2064×2752，4 语言 × 3 张（已重拍） | `docs/screenshots/ipad-13/` |
| App Store 签名 / 打包 | ✅ 已产出可上传的 `.ipa`（见 🟢-2） | — |
| 七语言界面 | ✅ 系统语言 = 翻译目标语言（+ Hindi） | `Sources/Localization/` |
| 提审用低额度 Key | ✅ 已备 | `docs/review-key.local.md`（本地，不入库） |
| PrivacyInfo.xcprivacy | ✅ 已加（UserDefaults `CA92.1`） | `MenuLens/Resources/PrivacyInfo.xcprivacy` |
| 第三方 AI 同意屏 | ✅ 已加，可在设置页撤回 | `Sources/Views/AIConsentView.swift` |
| 七语言内置示例 | ✅ 7 语言 × 2 餐厅，按语言 seed | `MenuLens/Resources/Samples/<lang>/` |
| App 名称 | ✅ **MenuMirror** / **镜中菜单**，已全局替换 | 见 🔴-0 |
| EU trader 三项 | ✅ 地址 / 电话已定（值不入库）；邮箱统一用 Gmail | `docs/trader-info.local.md` |
| 联系邮箱口径 | ✅ 隐私政策 + DSA + 支持联系统一为同一个 Gmail | `docs/privacy-policy.html` |
| 签名 Team | ⚠️ `LNP5ER743F`，但本机签名资产仍是免费层（见 🟢-2） | `project.yml` |
| **MenuMirror 商标查询** | ❌ 只能你在浏览器里手查（两个库都挡自动访问） | — |

---

## 2. 阻碍分析

分三级：🔴 = 不改就会被拒；🟡 = 有真实风险，要靠设计或话术化解；🟢 = 流程性，
不难但会卡住进度。

### 🔴 会被拒，必须先修

#### ✅ 🔴-0 「MenuLens」名字被占用 —— 已改名为 MenuMirror / 镜中菜单

用 Apple 自己的 iTunes lookup API 查的（网页搜索给的 id 是假的，已排除）：

| 开发者 | 名字 | 类目 | 备注 |
|---|---|---|---|
| **Naoki Takahashi** | 美区叫 `FoodTranslator`，但**中国区/德国区/日本区就叫 `MenuLens`** | **旅行 Travel** | ⚠️ 同名 + 同类目 + 同功能（菜单翻译），2026-07 还在更新 |
| Streamlined Studios | `MenuLens: AI Calorie Scanner` / 中国区 `MenuLens: AI 菜单扫描器` | 美食佳饮 | |
| Juan Ballon | `MenuLens - AI Calorie Counter` | 健康健美 | |
| ALIGHT TEKNOLOJI | `Menu Lens: Diet & Healthy Food` | 工具 | |
| kwan ho baek | `Menu Lens` | 效率 | |

两个后果：

1. **App Store Connect 不会让你占用已被使用的名字** —— `MenuLens` 直接不可用，
   `MenuLens - 口袋菜单` 也极可能被判定为混淆近似而驳回。
2. 更麻烦的是第一行那个：**同名、同为旅行类、同样做菜单翻译**。即使名字侥幸通过，
   也可能招来 **4.1 Copycats** 或 **5.2.1** 的商标投诉。

**顺带：中文名「口袋菜单」在中国区也被占了** ——
`口袋菜单 - 最爱吃的都放在口袋`（Kai Chi Tsao）。所以中英文名都得换。

改名的影响范围（比想象中小，因为 Bundle ID 不用动）：

| 要改 | 不用改 |
|---|---|
| App Store 名称 + 副标题 | **Bundle ID `ai.xiangyang.MenuLens`**（永不对用户可见） |
| `project.yml` 的 `CFBundleDisplayName` | 代码里的类名、target 名 |
| 六份 `Localizable.strings` 的 `app.name` | 签名、证书、Team |
| `InfoPlist.strings` 的 `CFBundleDisplayName` | 截图（名字只出现在导航栏，会随 `app.name` 自动变） |
| README / docs / 隐私政策标题 | |

已经跨 us/cn/de/jp 四个商店筛过、**四个商店都没有同名或同前缀**的候选：
`MenuPaper`、`PaperMenu`、`MenuMirror`、`MenuPlate`、`MenuTwin`、`Menuscope`。
中文候选（cn/tw/hk 三区都干净）：`菜单镜`、`菜单原样`、`看懂菜单`、`同款菜单`、
`原版菜单`、`菜单照相馆`。

> ✅ **2026-08-27 已定并已替换**：英文 **MenuMirror**，中文 **镜中菜单**。
> 「同一份菜单，照出你的语言」—— 说的是原版式就地翻译这个差异点，同时避开
> `-Lens` 词根，不会读成那个同类目竞品的仿品。
> `MenuMirror` 在 us/cn/de/jp/fr/es 六区、`镜中菜单` 在 cn/tw/hk 三区均无同名或同前缀。
>
> 已替换：六份 `app.name`、六份 `InfoPlist.strings` 的 `CFBundleDisplayName`、
> 六份 `consent.body` 里的行文、`project.yml` 的 `CFBundleDisplayName`、
> README、隐私政策、本文件与 metadata 包。
> **Xcode 工程名 / target / 目录 / Bundle ID 一律未改**（都不对用户可见）。
>
> ⚠️ 仍待你做：iTunes 搜不到 ≠ Apple 一定放行 —— 还有「已预留但未上架」的名字，
> 而商标是另一套体系。建议在 **USPTO** 和 **EUIPO** 各查一次 MenuMirror。

#### 🔴-1 Guideline 5.1.2(i)：第三方 AI 数据共享，必须**事前**取得明示同意

这是 Apple **2025-11-13** 才加进指南的条款，第一次把「第三方 AI」列成受管类别。
原文（Apple 官方指南页）：

> You must clearly disclose where personal data will be shared with third parties,
> **including with third-party AI**, and obtain explicit permission before doing so.

本 App 把用户拍的菜单照片直接发给 `api.openai.com`，正中这一条。

要满足这条，业界目前的做法（也是 Apple 审核实际在查的三件事对齐）：

1. **首次调用之前**弹一次说明屏，必须点名服务商（OpenAI）、列出发送的数据类别
   （菜单照片；不含姓名/位置/标识符），说明用途；
2. 给一条**真正能拒绝**的路径 —— 拒绝后 App 仍可用（本 App 天然满足：
   内置示例菜单不需要联网，可以「只看示例」）；
3. **隐私政策、同意屏、二进制实际发出的数据**三者必须说同一件事。

> ✅ **2026-08-27 已实现**：`Sources/Views/AIConsentView.swift`。
>
> - 挂在**首次点「识别并翻译」**时，不是启动时 —— 用户在这一刻才理解为什么要发照片，
>   而且选照片本身不发送任何东西，只有这个按钮发送。
> - 点名 OpenAI，分两栏列出「会发出去的」和「永远不离开这台手机的」，
>   写明留存与「没有开发者服务器」，附隐私政策链接。
> - 「暂不」是真退路：示例菜单和已存翻译全在本地，拒绝后 App 完整可用。
> - 设置页有可随时关闭的开关（新规要求可事后撤回）。
> - 许可检查**下沉到了 `AnalysisViewModel`**（`analyze()` 与配图生成各一道），
>   而不是只挡在按钮上 —— 从历史记录打开旧扫描会触发补配图，那条路径同样会发请求。
> - 六种语言文案齐备，同意屏本身也跟随 App 语言。

#### 🔴-2 隐私营养标签不能填「不收集数据」

`appstore-metadata.md` 现在写的是选 **"Data Not Collected"**，理由是「不经过开发者
服务器」。**这个理由不成立。** Apple 对 "collect" 的定义是：

> transmitting data off the device in a way that allows you and/or **your third-party
> partners** to access it for a period longer than what is necessary to service the
> transmitted request in real time.

OpenAI 是我们集成的第三方，且 OpenAI 对 API 数据有约 30 天的滥用监控留存 ——
超过「实时服务该请求所必需」。所以照片属于「收集」，必须申报。

**改成**：

| 字段 | 值 |
|---|---|
| 数据类型 | User Content → **Photos or Videos**（菜单照片） |
| 用途 | App Functionality |
| 是否关联身份 | **Not Linked to You**（不发任何账号/标识符） |
| 是否用于追踪 | **Not Used for Tracking** |

其余（历史记录、成员姓名头像、Key）都不出设备，不申报。

顺带隐私政策开头那句「不收集、不存储、不出售你的任何数据」措辞也不准确 ——
照片确实离开了设备。

> ✅ **2026-08-27 已全部改完，三处口径现在一致**：
>
> - `appstore-metadata.md` 的营养标签结论已改正为上表；
> - `PrivacyInfo.xcprivacy` 的 `NSPrivacyCollectedDataTypes` 与上表逐字对应；
> - `docs/privacy-policy.html` 的总结句改成「除了你主动送去翻译的菜单照片之外，
>   没有任何数据离开你的手机」，并补上了同意流程、可撤回、以及 OpenAI 的
>   短期留存（中英文两版都改了）。

#### 🔴-3 内置示例菜单全是中文，英文审核员看不出这个 App 在干什么

这是我做完系统语言之后才暴露出来的问题：

```
Samples/la-mar/scan.json        targetLanguage = zh-Hans   源语言 = 英语
Samples/naan-n-curry/scan.json  targetLanguage = zh-Hans   源语言 = 英语
```

而 `appstore-metadata.md` 的 Review Notes 明确写着「不需要 Key 也能完整体验，
点左上角时钟看两份预翻译示例」。现在的实际效果是：

- 审核员（默认英文环境，新装 App 会跟随设备语言 → 英文界面）打开示例，
  看到的是**英文菜单被翻成中文** —— 界面英文、内容中文，像是坏了；
- 且两份示例的**源语言本来就是英文**，对英文用户来说「英译英」根本演示不出核心价值。

这条会同时踩 **2.1 App Completeness** 和 **4.2 Minimum Functionality**。

三个选项，成本递增：

| 方案 | 做法 | 成本 | 评价 |
|---|---|---|---|
| A | 重烤示例：找一份**非英文**菜单（日文/法文最好），烤成 `en` 目标语言 | 需要 API 调用（几十美分）+ 一次跑通 | ✅ 推荐。英文审核员一眼看懂 |
| B | 按语言分目录 `Samples/<lang>/`，每种语言烤一套 | 6× API 成本 + 改 `HistoryStore.seedBundledSamplesIfNeeded` | 最完整，但对首次上架过度 |
| C | 不动示例，Review Notes 里说明并附 demo Key | 0 | ⚠️ 赌审核员愿意用 Key 实测。不建议单独用 |

> ✅ **2026-08-27 已修，直接做了方案 B（全六种语言）**：
>
> - 新增 `tools/retarget_sample.py`：**不重跑整条流水线**（重跑会重排
>   `p<页>_s<节>_i<项>` 的 dishKey，把已烤好的 71 张配图全指错菜），
>   只从 `original*` 字段重译文案字段，几何、行号、dishKey 全部原封不动，
>   配图直接沿用。
> - 示例改成按语言分目录 `Samples/<lang>/<餐厅>/`，`HistoryStore` 在首次启动时
>   按当时的 App 语言 seed，**回落是英文而不是中文**。seed 标志位升到 `v5`。
> - 六种语言 × 2 家餐厅全部烤好并抽查过。
>
> 过程中修掉两个真问题：
>
> 1. 模型会**把长列表的尾巴丢掉**（138 行的菜单漏了最后 5 行，而 249 行的那份是
>    完整的 —— 所以不是上下文限制，重试也只是重新掷骰子）。加了**补漏回合**：
>    每轮只要还缺 id 就只针对缺的再问一次。
> 2. 模型把价格译进了菜名行（`'Classic Fish Cebiche 31'`），而已上线的中文数据是
>    `'Clásico* 31'` → `'经典酸橘鱼'`（**不含价格**）—— 画布把译名画在菜名 strip 上、
>    价格由 `price` 字段单独渲染，烤进价格会让它在画面上出现两次。
>    改成**本地确定性推导**：`dish_name` / `section_title` 行的译文直接复用该菜/该节的
>    译名，按原文前缀匹配。在中文基线上验证过 **93 条全中、零值不一致**，
>    这两类行现在根本不发给模型（也更省钱）。
>
> 顺带修掉一个只在「源语言 == 目标语言」时出现的显示问题：
> `Small Plates / SMALL PLATES`、`TANDOORI PANEER` / `Tandoori Paneer` 同串印两遍。
> 这恰好是英文审核员看英文示例时的场景。译名与原文相同时不再重复渲染
> （`MenuItemEntry.translationIsRedundant`），列表和 PDF 附录页都已处理。

#### 🔴-4 缺 `PrivacyInfo.xcprivacy`

App 自身用了 required-reason API 就要申报。我扫过整个代码库：

| API 类别 | 用到？ | 需要的 reason code |
|---|---|---|
| UserDefaults | ✅ 11 处 | `CA92.1`（仅本 App 自己的 defaults） |
| File timestamp | ❌ 无 | — |
| Disk space / Boot time / Active keyboards | ❌ 无 | — |

所以只需要一个很小的清单文件，声明 `NSPrivacyAccessedAPICategoryUserDefaults` +
`CA92.1`，加上 `NSPrivacyTracking = false`、`NSPrivacyTrackingDomains = []`，
以及和营养标签一致的 `NSPrivacyCollectedDataTypes`（照片 / App Functionality /
不关联身份 / 不追踪）。没有第三方 SDK，所以不涉及 SDK 签名清单那一摊事。

> ✅ **2026-08-27 已修**：`MenuLens/Resources/PrivacyInfo.xcprivacy`，已确认进包。

---

### 🟡 有真实风险，靠设计和话术化解

#### 🟡-1 Guideline 3.1.1：「用 API Key 解锁功能」有被拒先例

Apple 开发者论坛上有一个明确的案例（thread 763884）：一个 **一次性付费** 的
BYOK（bring-your-own-key）AI App 被拒，原话：

> The app unlocks or enables additional functionality with mechanisms other than
> in-app purchase, which is not appropriate. Specifically, **the app uses API keys
> to unlock or enable functionality.**

那个线程最后**没有公开的解决方案**（Apple 只回复「正在调查，会有代表联系你」）。

MenuMirror 的处境比它好，但不是免疫：

| 差异 | 对我们的影响 |
|---|---|
| MenuMirror **免费**，没有任何付费层 | ✅ 关键。3.1.1 保护的是 IAP 收入，我们没有东西被「绕过」 |
| Key 不解锁**我们卖的**内容，只是用户自己的算力账户 | ✅ 可以在 Review Notes 里直说 |
| 但 Key 确实「enable functionality」 | ⚠️ 审核员照字面套条款仍可能拒 |

**Review Notes 里要主动写清**（照抄即可）：

> MenuMirror is free. There is no paid tier, no in-app purchase, and no content sold
> by the developer. The OpenAI API key is the user's own account with a third party
> — it does not unlock any developer-provided content, and the developer receives
> no payment of any kind. Users who prefer not to use a key can browse the bundled
> sample menus, which demonstrate every feature offline.

真被拒了，走 App Review Board 申诉，重点就是「没有任何 IAP 被规避」。

#### 🟡-2 2.1 / 4.2：核心功能需要用户自备付费第三方账号

这本质上和 🔴-3 是同一件事的另一面。示例菜单修好后风险大幅下降。
另外 Review Notes 里的 demo Key 必须：额度足够跑几份菜单、**审核全程有效**
（包括被拒后重审）、过审后再作废。

#### 🟡-3 年龄分级要重答新问卷

Apple 2025-07 换了分级体系（新增 13+/16+/18+，删掉 12+/17+），
新问卷**专门问 AI 助手/聊天机器人功能**。MenuMirror 不是开放式聊天、
不能任意访问网络内容，**4+ 应该仍然拿得到**，但问卷要按实际情况老实答
（有 AI 生成内容、无用户间交流、无开放式对话）。

#### 🟡-4 名称与商标 → **已升级为 🔴-0，见上**

查过了，撞了。详见 🔴-0。

---

### 🟢 流程性，但会卡进度

#### 🟢-1 EU DSA trader 状态 —— 不填就在欧盟下架

2025 年起 Apple 强制要求申报 trader 状态，**没填的 App 会从欧盟商店移除**
（Apple 已因此批量下架超过 13.5 万个 App）。

对个人开发者的现实影响：**如果申报为 trader，Apple 会把你的地址和电话公开显示
在欧盟 App Store 商品页上。** 只能填 P.O. Box 之类，不能留空。

> ✅ **已决定（2026-08-27）：申报 trader，欧盟正常发行。**
> 地址已确定，但**刻意不写进 repo**（public GitHub，写进工作区就有手滑提交的风险）
> —— 提审时直接敲进 App Store Connect。字段清单和验证方式见
> `docs/trader-info.local.md`（gitignore，不入库）。
>
> **还缺**：trader 申报的**电话**和**邮箱**同样必填、同样会公开显示。

#### 🟢-2 签名：Archive 能过，**导出到 App Store 过不去**

Team ID 是 `LNP5ER743F`（已确认，保持不变）。但 2026-08-27 查本机签名资产，
三项证据都指向「这个 team 在本机的凭证仍是免费层」：

| 证据 | 实测 | 含义 |
|---|---|---|
| `security find-identity -v -p codesigning` | `Apple Distribution` **0 张**，只有 1 张 `Apple Development` | Archive → App Store **必须**要 Distribution 证书 |
| 描述文件有效期 | `2026-08-27`、`2026-09-02`（签发于 8/20、8/26）→ **7 天** | 7 天是免费 Team 的特征；付费是 1 年 |
| `com.apple.dt.Xcode.plist` 的 `IDEProvisioningTeams` | **不存在** | Xcode GUI 里从没登录过开发者账号 |

（证书 `OU=LNP5ER743F`、`O=向阳 史` 确认了 team 归属。注意 CN 里那串
`K72C3N5JXB` **不是** Team ID，是证书自己的编号。）

> ✅ **2026-08-27 已解决。** Team `LNP5ER743F` **是**付费 team —— 我原先从
> 「7 天描述文件 + 0 张 Distribution 证书」推断它是免费的，那个推断是错的，
> 那只是本机的过期缓存状态。加上
> `Apple Distribution: Xiangyang Shi (LNP5ER743F)` 证书后，
> `-allowProvisioningUpdates` 让 xcodebuild 自己建出了
> `iOS Team Store Provisioning Profile`，导出成功：
>
> ```
> ** EXPORT SUCCEEDED **   MenuLens.ipa  47 MB
> ```
>
> IPA 自检：Apple Distribution 签名 · App Store 类型描述文件（无设备列表）·
> `get-task-allow: False` · MenuMirror 1.0 (1) · MinimumOSVersion 17.0 ·
> 七套 lproj 与示例 · PrivacyInfo.xcprivacy 在。**这就是能上传的包。**

**当时实测的断点记录（留档）**：

| 步骤 | 结果 |
|---|---|
| Release 配置构建 | ✅ `BUILD SUCCEEDED` |
| `xcodebuild archive` | ✅ `ARCHIVE SUCCEEDED` —— 用开发证书签的，能过 |
| `xcodebuild -exportArchive`（`method: app-store-connect`, `teamID: LNP5ER743F`） | ❌ `error: exportArchive No profiles for 'ai.xiangyang.MenuLens' were found` |

所以 Archive 不是关卡，**导出/上传**才是：这个 bundle id 在这个 team 下
没有 App Store 类型的描述文件，而免费 Team 也签发不出来。

可复现的命令（archive 大约 1 分钟）：

```bash
xcodebuild -project MenuLens.xcodeproj -scheme MenuLens -configuration Release \
  -destination 'generic/platform=iOS' -archivePath /tmp/MenuMirror.xcarchive archive

# ExportOptions.plist: method=app-store-connect, teamID=LNP5ER743F, signingStyle=automatic
xcodebuild -exportArchive -archivePath /tmp/MenuMirror.xcarchive \
  -exportOptionsPlist /tmp/ExportOptions.plist -exportPath /tmp/export
```

**要做的**：

1. App Store Connect 里用付费会员注册 Bundle ID `ai.xiangyang.MenuLens`；
2. Xcode → Settings (⌘,) → Accounts → 登录付费会员的 Apple ID；
3. 在 Signing & Capabilities 选中该 Team，让 Xcode 签发
   Apple Distribution 证书 + App Store 描述文件。

**验证成功的判据**（两条都要满足）：

- `security find-identity -v -p codesigning` 出现一行 `Apple Distribution: ...`
- 上面那条 `-exportArchive` 命令跑出 `** EXPORT SUCCEEDED **`

#### 🟢-3 商标查询只能手动

两个库都挡自动访问（Justia 403、USPTO 公开 API 404），而且都是需要浏览器的
JS 应用。网页搜索没有搜到任何叫 MenuMirror 的产品或商标 —— 这是**弱正面信号，
不是清权检索**。

请自己各查一次（第 9 类「软件」和第 42 类「SaaS」）：

USPTO
https://tmsearch.uspto.gov

EUIPO
https://euipo.europa.eu/eSearch

> App Store 的**名称可用性**我已经用 Apple 自己的 API 查过了，那个是权威的：
> `MenuMirror` 在 us/cn/de/jp/fr/es 六区、`镜中菜单` 在 cn/tw/hk 三区均无撞名。
> 商标是另一套体系，两者不能互相替代。

#### 🟢-4 其余机械步骤

1. 见 🟢-2（签名）
2. App Store Connect → 注册 Bundle ID `ai.xiangyang.MenuLens`
3. 创建 App 记录（名称、副标题、类别：旅行 / 美食佳饮、免费）
4. `xcodegen generate` → Product → Archive → Distribute → App Store Connect
5. 填元数据（照抄 `appstore-metadata.md`，注意按 🔴-2 改隐私标签）
6. **先发 TestFlight 自测一轮**（尤其六种语言各点一遍，看有没有文案溢出）
7. 提交审核

---

## 3. 剩下要做的

```
① App Store Connect：创建 App 记录，主语言英文，按 locale 填名称
   （MenuMirror / 镜中菜单），Bundle ID 选 ai.xiangyang.MenuLens
② 填 EU DSA trader 三项（地址/电话手敲，不入库）
③ 元数据照抄 appstore-metadata.md（隐私标签用改正后那张表）
④ 上传截图：`docs/screenshots/iphone-6.9/` 与 `ipad-13/` 下四套，按 locale
⑤ 上传 .ipa（Xcode Organizer → Distribute，或 Transporter）
⑥ TestFlight 走一轮（七种语言各点一遍看文案溢出）→ 提审
⑦ EUIPO 商标查询（USPTO 你已查过无结果，见 🟢-3）
```

打包这一步已经验证可行，命令在 🟢-2。

已完成（2026-08-27）：

- ✅ 🔴-0 改名 MenuMirror / 镜中菜单，六区筛查无撞名
- ✅ 🔴-1 第三方 AI 同意屏 + 设置页可撤回开关 + 六语言文案
- ✅ 🔴-2 隐私标签结论改正，`PrivacyInfo.xcprivacy` 与隐私政策三处口径对齐
- ✅ 🔴-3 六种语言 × 2 家餐厅的示例全部烤好，seeding 按语言、回落英文
- ✅ 🔴-4 `PrivacyInfo.xcprivacy`
- ✅ 🟢-1 EU trader：申报，欧盟发行，三项齐
- ✅ 联系邮箱全局统一为 Gmail（qq 邮箱对境外发件方投递不可靠）
- ✅ 源语言 == 目标语言时的重复渲染
- ✅ 新增 Hindi（हिन्दी）：117 键文案 + 2 家餐厅示例 + `CFBundleLocalizations`
- ✅ 版本号从写死的 `1.0/1` 改为由 build settings 驱动（原来 `MARKETING_VERSION`
  是死的，改它不影响出包），并定为首发的 `1.0 (1)`
- ✅ 跑通 Release 构建 → Archive → **Export 成功，产出可上传的 App Store `.ipa`**
- ✅ 截图全部重拍：4 语言 × iPhone 6.9"(4 张) + iPad 13"(3 张)，尺寸逐张核对
- ✅ 画布渲染器补上「译名与原文相同则不重复渲染」（之前只做了列表和 PDF）
- ✅ `-demoCart` 的同行成员名字改为随语言变（原来硬编码「小明」，
  会出现在英/法/韩的商品页截图里）

## 4. 参考链接

App Store Review Guidelines（5.1.2(i) 原文）
https://developer.apple.com/app-store/review/guidelines/

Apple 2025-11-13 指南更新公告
https://developer.apple.com/news/?id=ey6d8onl

App Privacy Details（"collect" 的定义与营养标签填法）
https://developer.apple.com/app-store/app-privacy-details/

EU DSA trader 要求（App Store Connect 帮助）
https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/

新版年龄分级公告
https://developer.apple.com/news/?id=ks775ehf

SDK 最低版本要求（2026-04-28 起 iOS 26 SDK）
https://developer.apple.com/news/upcoming-requirements/

BYOK 被 3.1.1 拒的论坛案例
https://developer.apple.com/forums/thread/763884
