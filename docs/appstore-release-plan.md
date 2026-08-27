# 上架路线图与阻碍分析 — MenuLens

> 写于 2026-08-26。已有 Apple Developer Program 会员（个人，$99/年）。
> 与 `appstore-metadata.md` 配套：那份是**提交时要粘贴的素材**，这份是**顺序、
> 阻碍和判断**。两份里的 checklist 以这份为准 —— 调研后发现原 checklist 有
> 两处结论已经过期/写错了（见 🔴-2 和 🔴-3）。

---

## 0. 一句话结论

技术上离上架很近（签名、截图、隐私政策、示例数据都已备好），
**真正的阻碍不在打包，而在 2025 年 11 月 Apple 新加的第三方 AI 数据共享规则**，
以及一条我们自己写错了的隐私声明。这两条不修，第一次提审基本会被拒。

---

## 1. 现状盘点

| 项 | 状态 | 位置 |
|---|---|---|
| Bundle ID `ai.xiangyang.MenuLens` | 待在 App Store Connect 注册 | `project.yml` |
| 签名 Team `LNP5ER743F` | 已写死在 `project.yml`（需确认已是**付费**个人 Team，不是 Personal Team） | `project.yml` |
| Xcode / SDK | ✅ Xcode 26.6，满足 2026-04-28 起「必须 iOS 26 SDK」的硬要求 | 本机 |
| 出口合规 | ✅ `ITSAppUsesNonExemptEncryption = false`（只用标准 HTTPS） | `Info.plist` |
| 隐私政策 URL | ✅ 已上线（GitHub Pages） | `docs/privacy-policy.html` |
| 技术支持 URL | ✅ GitHub repo | — |
| 6.9" iPhone 截图 | ✅ 1320×2868 | `docs/screenshots/` |
| 13" iPad 截图 | ✅ 2064×2752 | `docs/screenshots/ipad/` |
| 六语言界面 | ✅ 刚做完（系统语言 = 翻译目标语言） | `Sources/Localization/` |
| 提审用低额度 Key | ✅ 已备 | `docs/review-key.local.md`（本地，不入库） |
| **PrivacyInfo.xcprivacy** | ❌ 不存在 | — |
| **第三方 AI 同意屏** | ❌ 不存在 | — |

---

## 2. 阻碍分析

分三级：🔴 = 不改就会被拒；🟡 = 有真实风险，要靠设计或话术化解；🟢 = 流程性，
不难但会卡住进度。

### 🔴 会被拒，必须先修

#### 🔴-1 Guideline 5.1.2(i)：第三方 AI 数据共享，必须**事前**取得明示同意

这是 Apple **2025-11-13** 才加进指南的条款，第一次把「第三方 AI」列成受管类别。
原文（Apple 官方指南页）：

> You must clearly disclose where personal data will be shared with third parties,
> **including with third-party AI**, and obtain explicit permission before doing so.

MenuLens 把用户拍的菜单照片直接发给 `api.openai.com`，正中这一条。
目前代码里**没有任何同意环节** —— 填了 Key 就直接开始发照片。

要满足这条，业界目前的做法（也是 Apple 审核实际在查的三件事对齐）：

1. **首次调用之前**弹一次说明屏，必须点名服务商（OpenAI）、列出发送的数据类别
   （菜单照片；不含姓名/位置/标识符），说明用途；
2. 给一条**真正能拒绝**的路径 —— 拒绝后 App 仍可用（MenuLens 天然满足：
   内置示例菜单不需要联网，可以「只看示例」）；
3. **隐私政策、同意屏、二进制实际发出的数据**三者必须说同一件事。

> 落地建议：把同意屏挂在**首次点「识别并翻译」**时（不是启动时），
> 用户在这一刻最能理解为什么要发照片。同意状态存 `UserDefaults`，
> 设置页给一个可撤回的开关（新规要求「可事后撤回」）。
> 六种语言的文案要一起加 —— 现在加新文案的流程见 README 的 Language 一节。

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

顺带把隐私政策开头那句「不收集、不存储、不出售你的任何数据」调一下措辞 ——
改成「我们没有服务器，你的数据不经过我们；菜单照片只发给 OpenAI 处理」更准确，
并补一句 OpenAI 的留存期。三处口径必须一致，Apple 会交叉比对。

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

> 我的建议：**A + C**。用一份日文或法文菜单烤成英文示例（英文是基准语言，
> 也是审核员的默认语言），中文那两份保留给中文用户。Review Notes 里同时给 demo Key 兜底。

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

---

### 🟡 有真实风险，靠设计和话术化解

#### 🟡-1 Guideline 3.1.1：「用 API Key 解锁功能」有被拒先例

Apple 开发者论坛上有一个明确的案例（thread 763884）：一个 **一次性付费** 的
BYOK（bring-your-own-key）AI App 被拒，原话：

> The app unlocks or enables additional functionality with mechanisms other than
> in-app purchase, which is not appropriate. Specifically, **the app uses API keys
> to unlock or enable functionality.**

那个线程最后**没有公开的解决方案**（Apple 只回复「正在调查，会有代表联系你」）。

MenuLens 的处境比它好，但不是免疫：

| 差异 | 对我们的影响 |
|---|---|
| MenuLens **免费**，没有任何付费层 | ✅ 关键。3.1.1 保护的是 IAP 收入，我们没有东西被「绕过」 |
| Key 不解锁**我们卖的**内容，只是用户自己的算力账户 | ✅ 可以在 Review Notes 里直说 |
| 但 Key 确实「enable functionality」 | ⚠️ 审核员照字面套条款仍可能拒 |

**Review Notes 里要主动写清**（照抄即可）：

> MenuLens is free. There is no paid tier, no in-app purchase, and no content sold
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
新问卷**专门问 AI 助手/聊天机器人功能**。MenuLens 不是开放式聊天、
不能任意访问网络内容，**4+ 应该仍然拿得到**，但问卷要按实际情况老实答
（有 AI 生成内容、无用户间交流、无开放式对话）。

#### 🟡-4 名称与商标

"MenuLens" 要先在 App Store 搜一遍有没有重名/近名，以及有没有人注册了商标。
名称被占用是 App Store Connect 里最常见的「卡在第一步」。
`MenuLens - 口袋菜单` 共 15 字符，在 30 字符上限内，没问题。

---

### 🟢 流程性，但会卡进度

#### 🟢-1 EU DSA trader 状态 —— 不填就在欧盟下架

2025 年起 Apple 强制要求申报 trader 状态，**没填的 App 会从欧盟商店移除**
（Apple 已因此批量下架超过 13.5 万个 App）。

对个人开发者的现实影响：**如果申报为 trader，Apple 会把你的地址和电话公开显示
在欧盟 App Store 商品页上。** 只能填 P.O. Box 之类，不能留空。

两条路：

| 选择 | 后果 |
|---|---|
| 申报 trader + 提供可公开的地址/电话 | 欧盟可下载。建议用 P.O. Box 或工作地址，别用家庭住址 |
| 申报 non-trader（爱好者、无商业化意图） | 定义上要求你**不是**为营利而做。免费无 IAP 的 App 说得通，但这是你自己的法律判断 |
| 直接不在欧盟发行 | 上架时把欧盟国家全部取消勾选。最省事，代价是丢掉欧洲用户（对一个旅行 App 来说很痛） |

#### 🟢-2 其余机械步骤

1. 确认 `DEVELOPMENT_TEAM` 已指向付费 Team（Xcode → Settings → Accounts）
2. App Store Connect → 注册 Bundle ID `ai.xiangyang.MenuLens`
3. 创建 App 记录（名称、副标题、类别：旅行 / 美食佳饮、免费）
4. `xcodegen generate` → Product → Archive → Distribute → App Store Connect
5. 填元数据（照抄 `appstore-metadata.md`，注意按 🔴-2 改隐私标签）
6. **先发 TestFlight 自测一轮**（尤其六种语言各点一遍，看有没有文案溢出）
7. 提交审核

---

## 3. 建议的执行顺序

```
① 🔴-4 PrivacyInfo.xcprivacy          （最小，半小时）
② 🔴-2 隐私标签 + 隐私政策措辞对齐    （改文档，不改代码）
③ 🔴-1 第三方 AI 同意屏 + 可撤回开关  （要写代码 + 6 语言文案）
④ 🔴-3 重烤一份英文目标语言的示例菜单 （要花 API 钱，需要你决定用哪份菜单）
⑤ 🟡-4 查名称/商标                    （5 分钟，但要先做，会影响 ②③④ 白做）
⑥ 🟢-1 决定欧盟策略                   （你的个人隐私取舍，我不能替你定）
⑦ 打包 → TestFlight → 提审
```

其中 ⑤ 建议**最先做**：名字被占用的话，元数据和截图里的名称都要重做。

---

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
