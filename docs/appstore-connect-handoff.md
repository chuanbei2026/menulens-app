# App Store Connect 填表交接单 — ForeignMenu / 外乡人的菜单

写于 2026-08-27。给接手在 App Store Connect 网页上填表的 agent。

> **如果你没有这台 Mac 的文件访问权限**：截图全部已提交到本仓库，可以直接从
> GitHub 取，路径见第 6.6 节。原始文件可用
> `https://raw.githubusercontent.com/chuanbei2026/menulens-app/main/<路径>` 下载。
> 唯一不在仓库里的是审核用测试 Key（见 6.7），那一项必须问交接人。

**这份文件是自包含的** —— 所有要填的值都在下面，逐字复制，不需要去别处找。
只有一个例外（Review Notes 里的测试 Key），已在该处明确标出。

---

## 0. 交接给你的人已经做完的事 —— 不要重做

| 已完成 | 细节 |
|---|---|
| App 记录已创建 | 名称 `ForeignMenu` 已被 ASC 接受（`MenuMirror`、`MenuLens`、`口袋菜单` 都被占用过，别改回去） |
| Bundle ID | `ai.xiangyang.MenuLens` —— **不要动**，包里就是这个 |
| 构建版本已交付 | `1.0 (1)`，经 Transporter 于 2026-08-27 投递，正在等 Apple 处理 |
| 签名 | Apple Distribution + App Store 描述文件，已验证 |
| 出口合规 | `ITSAppUsesNonExemptEncryption = false` 已在 Info.plist，**不会**问你加密问卷 |

**你要做的**：把下面的元数据、隐私标签、截图填进去，然后等构建版本处理完选上它。

---

## 1. 这个 App 是什么（填表时需要的理解）

拍一张外语菜单的照片，它把整份菜单**按原版式就地翻译**成你的语言 ——
译文写在菜单原来的位置上，版式、字号、行距保留，可以把手机直接递给服务员。

- 7 种语言：中文（简体）、English、日本語、한국어、Français、Español、हिन्दी
- 一个开关同时切换**界面语言**和**翻译目标语言**，全新安装跟随系统语言
- 用户自备 OpenAI API Key，照片直接从设备发给 OpenAI，**开发者没有服务器**
- 内置两家真实餐厅的完整示例，不填 Key 也能体验全部功能

---

## 2. 页面导航

```
appstoreconnect.apple.com → Apps → ForeignMenu
│
├─ 顶部标签: App Store | TestFlight
│
├─ 【App Store 标签】左侧栏
│   ├─ General / 通用
│   │   ├─ App Information ──────── 第 3 节
│   │   ├─ Pricing and Availability ─ 第 4 节
│   │   └─ App Privacy ──────────── 第 5 节
│   └─ iOS App
│       └─ 1.0 Prepare for Submission ─ 第 6 节
│
└─ 【TestFlight 标签】 ── 第 7 节
```

⚠️ **关键区分**：

- **名称、副标题**在 `App Information`（App 级，跨版本）
- **描述、关键词、截图**在版本页 `1.0 Prepare for Submission`（每版可改）
- 两个页面**各自**有语言下拉；加简体中文本地化要**两边都加**

---

## 3. App Information

### 3.1 先加简体中文本地化

页面顶部有语言下拉（默认 `English (U.S.)`）→ `Add Language` → `Simplified Chinese`

### 3.2 名称与副标题

| 语言 | 字段 | 值（逐字复制） |
|---|---|---|
| English (U.S.) | Name | `ForeignMenu` |
| English (U.S.) | Subtitle | `Menus translated in place` |
| 简体中文 | Name | `外乡人的菜单` |
| 简体中文 | Subtitle | `拍菜单，秒变母语，还能点菜` |

副标题上限 30 字符，两个都在限内。

### 3.3 类别

- Primary Category: **Travel**
- Secondary Category: **Food & Drink**

### 3.4 隐私政策 URL

```
https://chuanbei2026.github.io/menulens-app/privacy-policy.html
```

（两种语言都填同一个）

### 3.5 年龄分级（Age Rating → Edit）

走 2025 年改版后的新问卷。按实际情况答：

| 问题类型 | 答 |
|---|---|
| 暴力 / 恐怖 / 성적内容 / 赌博 / 药物 / 脏话 | **全部 None / 无** |
| 不受限制的网页访问 | **No** |
| 用户生成内容 | **No**（没有社交、没有 UGC 分享） |
| **Alcohol, Tobacco, or Drug Use or References** | **None** —— 见下方说明 |

> ✏️ **2026-08-27 修正**：这份交接单原先写「新问卷专门问 AI 功能」。实测下来
> 现行问卷里**没有**这一问（七步答完，结果 4+：172 国 4+ / 巴西 AL / 韩国 ALL /
> 越南 00+）。不要去找不存在的那一题。

**关于酒精那一问**（内置示例是真实餐厅菜单，值得说清楚）：

已扫过两份内置示例的全部菜品和文本行 —— **零个菜品**提到酒精，没有酒水单、
没有任何饮酒的描绘或推荐。唯一命中是 La Mar 那张菜单上的过敏原说明行，
OCR 打坏后读作 `ⓐ contains alcohol / ⓢ contains soy / raw or undercooked…`
—— 那是**食品安全标注**，和「contains soy」并列，不是对饮酒的指涉。

所以 **None 站得住**。保守起见改成 Infrequent/Mild 的代价是分级被推到 13+，
失去 4+，对一个旅行工具类 App 不值得。

（用户自己拍的菜单可能包含酒水单，但那是用户提供的内容，不是 App 自身的内容 ——
Apple 分级问卷问的是后者。本 App 没有分享、没有社交，不触发 UGC 的那套问题。）

预期结果：**4+**。

---

## 4. Pricing and Availability

- 价格：**Free**
- 国家/地区：**全选**（包括欧盟）
  - ⚠️ 欧盟需要先申报 DSA trader 信息，见第 8 节。**如果 trader 信息还没填完，欧盟国家先不要取消勾选** —— 交接人已决定要在欧盟发行

---

## 5. App Privacy（隐私营养标签）

`App Privacy` → `Get Started`

### 只勾这一项

```
Data Types → User Content → Photos or Videos     ☑ 勾选

  Purpose:                App Functionality      ☑
  Linked to the user:     No
  Used for tracking:      No
```

其余所有数据类型：**不勾**（历史记录、同行成员姓名与头像、API Key 全部不出设备）。

### 🚨 绝对不要选 "Data Not Collected"

这是一个已经被纠正过的错误结论。理由：

> Apple 对 "collect" 的定义是「以你或**你的第三方合作方**能访问、且留存超过实时
> 服务该请求所必需的方式，把数据传出设备」。菜单照片会发给 OpenAI，而 OpenAI 对
> API 数据有约 30 天的滥用监控留存 —— 超过「实时所必需」，所以属于收集，必须申报。

营养标签、App 内的同意屏、隐私政策三处口径必须一致，Apple 会交叉比对。
App 内同意屏和隐私政策都已经按上面这个口径写好了，**不要改动标签去追求「更干净」**。

---

## 6. 版本 1.0 Prepare for Submission

顶部同样有语言下拉。

### 6.1 English (U.S.) — Description

```
Point your camera at any foreign menu — ForeignMenu translates it in place, preserving the original layout. Dish names stay bilingual so you can order by pointing. Auto-straightens hand-held photos, handles multi-page menus, generates dish thumbnails, tracks who ordered what for group dining, and annotates the order back onto the menu for your server.

Seven languages — one switch sets both the interface and the translation target, and a fresh install follows your system language. No server, no account, no tracking — bring your own OpenAI API key (in-app guide; a menu costs ~$0.05–0.25). Two full sample restaurants included, no setup needed to try.
```

### 6.2 English (U.S.) — Keywords

```
menu,translate,travel,restaurant,food,order,japan,korea,india,scan,ocr,dish,camera
```

### 6.3 简体中文 — 描述

```
出国吃饭看不懂菜单？拍一张，外乡人的菜单把整份菜单原版式翻译成你的语言。

【原版式翻译】不是干巴巴的文字列表——译文直接写在菜单原来的位置上，版式、字号、行距都保留，像拿到了一份母语版菜单。菜名保留原文对照，点菜时直接指给服务员看。

【自动矫正】手持拍摄的倾斜、透视、模糊照片自动拉正、锐化，多页菜单一次搞定。

【看图点菜】菜单上没有配图？AI 为每道菜生成参考小图。列表模式支持搜索、素食/海鲜/羊肉标识。

【多人点单】给同桌的每个人建档（可传头像），谁点的菜一目了然。确认后一键把所点菜品标注回原菜单——服务员对着屏幕就能下单，上菜时按名字对号入座。

【七种语言】中文（简体）、English、日本語、한국어、Français、Español、हिन्दी。一个开关同时切换界面语言和翻译目标语言，全新安装自动跟随系统语言。菜单原文语言自动识别，无需设置。

【隐私优先】没有服务器、没有账号、没有追踪。你的 OpenAI API Key 和所有翻译记录只保存在手机本地。

使用需要你自己的 OpenAI API Key（应用内有获取指引，一份菜单约 $0.05-0.25）。内置两家真实餐厅的完整示例，安装后无需任何配置即可体验全部功能。
```

### 6.4 简体中文 — 关键词

```
菜单,翻译,旅行,点菜,menu,translator,travel,印度,日本,restaurant,菜單,OCR,hindi
```

### 6.5 技术支持 URL（两种语言都填）

```
https://chuanbei2026.github.io/menulens-app/support.html
```

⚠️ **不要填 GitHub 仓库地址** —— 那是开发者向的 README。Apple 有时会要求支持页面上
有可联系到开发者的方式。上面这个页面是专门为此建的，含联系邮箱、费用说明、
「不填 Key 也能用」的说明和排障 FAQ，中英双语。

Marketing URL 留空。Promotional Text 留空。

### 6.6 截图

**已按 App Store 槽位的原生分辨率拍好并逐张核对过尺寸，直接上传，不要缩放或裁剪。**

| ASC 槽位 | 页面语言 | 目录（绝对路径） | 张数 |
|---|---|---|---|
| iPhone 6.9" Display | English (U.S.) | `docs/screenshots/iphone-6.9/en/` | 4 |
| iPhone 6.9" Display | 简体中文 | `docs/screenshots/iphone-6.9/zh-Hans/` | 4 |
| iPad 13" Display | English (U.S.) | `docs/screenshots/ipad-13/en/` | 3 |
| iPad 13" Display | 简体中文 | `docs/screenshots/ipad-13/zh-Hans/` | 3 |

每个目录里按**文件名顺序**上传（`01_` → `04_`），顺序就是展示顺序：

| 文件 | 内容 |
|---|---|
| `01_home.png` | 首页 |
| `02_canvas.png` | **主图** —— 原版式就地翻译，带多人点单标记 |
| `03_list.png` | 菜品列表：配图、搜索、成员筹码 |
| `04_server.png` | 原文菜单 + 点单标记，给服务员看（仅 iPhone 有这张） |

尺寸：iPhone `1320×2868`，iPad `2064×2752`。

> `fr/` 和 `ko/` 目录下也各有一套。**现在不用传** —— 只有加了法语/韩语本地化才需要。

### 6.7 App Review Information（页面最下方）

**Sign-in required**: **No**（App 没有账号系统）

**Notes** —— 逐字复制：

```
ForeignMenu translates restaurant menus photographed by the user. It calls the OpenAI API directly from the device; users supply their own API key (Settings → OpenAI API Key). No developer server is involved.

Before the first photo is ever sent, the app shows a consent sheet naming OpenAI, listing exactly what is sent and what stays on the device, and offering a working "Not now" (guideline 5.1.2(i)). The permission can be withdrawn at any time in Settings.

FOR REVIEW: the app is fully functional WITHOUT any API key — tap the clock icon (top-left) on the home screen to open History, which contains two complete pre-translated sample restaurants (La Mar, Naan n Curry) demonstrating every feature: zoomable in-place translated canvas, dish list with search and thumbnails, group ordering with member tags, order annotation, and PDF export. The samples are bundled in all seven app languages and seeded in the language of the device, so they appear in your own language.

ForeignMenu is free. There is no paid tier, no in-app purchase, and no content sold by the developer. The OpenAI API key is the user's own account with a third party — it unlocks no developer-provided content, and the developer receives no payment of any kind.

Optionally, this demo API key can be used to test live recognition:
<<<在这里粘贴测试 KEY>>>
```

### 6.8 App Review 联系人（提交必填）

| 字段 | 值 |
|---|---|
| First Name | `Xiangyang` |
| Last Name | `Shi` |
| Email | `chuanbei666@gmail.com` |
| Phone | ⚠️ **问交接人** —— 和 EU DSA 那栏填的是同一个号码（本文件刻意不写电话） |

### 6.9 Content Rights（App Information 里，提交必答）

问题：*Does your app contain, show, or access third-party content?*

**答 Yes。** 理由：内置的两份示例是**真实餐厅**（La Mar、Naan n Curry）菜单的照片，
画面里有店名和 logo；而且 App 的核心功能本身就是处理用户拍摄的第三方菜单。

⚠️ 这一题的后续追问（是否拥有相应权利）涉及法律判断，**由交接人决定**，
不要代答。相关事实见交接单第 11 节。

### 🔑 唯一需要人工提供的值

最后一行的 `<<<在这里粘贴测试 KEY>>>` 要换成一个真实的 OpenAI API Key。

**这个 Key 刻意没有写进本文件**（它是一个能花钱的凭证）。它在交接人本机的
`docs/review-key.local.md` 里，是文件中以 `sk-`
开头的那一行。

- 如果你能读本地文件：从那里取。
- 如果不能：**停下来问交接人**，让他粘给你。不要留占位符提交 —— 那是审核员实测
  「拍照识别」这条主路径的唯一途径，留空会大幅提高被拒概率。

**为什么 3.1.1 那段话很重要**：Apple 论坛上有过 BYOK（用户自备 Key）的 AI App
被以「用 API Key 解锁功能」为由按 3.1.1 拒掉的先例。那个案例是**付费**App；
本 App 完全免费、无任何 IAP，所以 Notes 里那段「free / no paid tier / no IAP」
是主动预防性说明，**不要删**。

---

## 7. TestFlight — 等构建版本处理完

`TestFlight` 标签 → `iOS Builds`

```
1.0 (1)  状态：正在处理 → 已就绪
```

- 处理通常 5–30 分钟
- **注意**：Transporter 的界面不显示 iOS `.ipa` 的应用图标，那是它的正常行为，
  包里的图标是完整的（`Assets.car` 中 1024×1024，phone + pad 两个 idiom 都在，
  已剥离 alpha 通道）。TestFlight 这里才会显示真实图标
- 处理完后回到 `1.0 Prepare for Submission`，中间的 **Build** 区点 `+`，选 `1.0 (1)`

### 如果 Apple 发来退回邮件

发到 `672546048@qq.com`（开发者账号邮箱，**不是**对外的 Gmail）。
把邮件原文贴给交接人，不要自己猜着改。

已经处理过一轮的：**Error 90717 图标含 alpha 通道** —— 已修，如果又报同一条，
说明上传的是旧包。

---

## 8. EU DSA trader —— 账号级，不在这个 App 里面

这一项**不在 App 页面内**，要回到 App Store Connect 首页找账号级设置。
确切菜单路径请看 Apple 官方说明（ASC 通常也会弹横幅提醒）：

```
https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/
```

申报为 **trader**（已决定，欧盟正常发行）。三项必填，**三项都会公开显示在欧盟
App Store 商品页上**：

| 字段 | 值 |
|---|---|
| 地址 | ⚠️ **问交接人** —— 刻意不写进任何文件（是能定位到本人的住址） |
| 电话 | ⚠️ **问交接人** —— 同上 |
| 邮箱 | `chuanbei666@gmail.com` |

Apple 的验证：邮箱和电话走双重验证收码；地址需要上传证明文件（若填 P.O. Box
等替代地址，Apple 要求提供能反映关联的账单或收据）。

> 邮箱用 Gmail 而不是 qq 邮箱是有意的：qq 邮箱对境外发件方的投递和过滤不可靠，
> 而这是面向出境旅行者的 App，欧美用户的来信必须能收到。隐私政策里的联系邮箱
> 也已经统一成同一个 Gmail。

---

## 9. 提交前自查

按顺序逐项确认，全绿再点 `Submit for Review`：

- [ ] App Information 里 English 和简体中文**两套**名称/副标题都填了
- [ ] 类别 Travel / Food & Drink
- [ ] 隐私政策 URL 已填
- [ ] 年龄分级问卷已答完，结果 4+
- [ ] App Privacy **只**勾了 `Photos or Videos`，且**不是** "Data Not Collected"
- [ ] 版本页 English 和简体中文**两套**描述/关键词都填了
- [ ] iPhone 6.9" 两个语言各 4 张截图
- [ ] iPad 13" 两个语言各 3 张截图
- [ ] Review Notes 已填，且**测试 Key 的占位符已换成真实 Key**
- [ ] Sign-in required = No
- [ ] Build 已选 `1.0 (1)`
- [ ] EU DSA trader 三项已填（或已决定取消勾选欧盟）
- [ ] Pricing = Free，国家/地区已选

### 提交前最好还做一件事

在 TestFlight 里装到真机上，**七种语言各点一遍**，看有没有文案溢出
（印地语和法语的句子最长，按钮和 footer 最容易被挤爆）。
被拒一次要等好几天，这一步不值得省。

---

## 10. 遇到任何一条都停下来问交接人

- ASC 说名称已被占用
- Bundle ID 下拉里没有 `ai.xiangyang.MenuLens`
- 年龄分级问卷把结果推到 4+ 以上
- Apple 发来退回邮件
- 需要那个测试 Key、地址、或电话

这些都不要自行猜测处理。

---

## 11. Content Rights 的事实依据（交接人决策用，agent 不要代答）

ASC 在 App Information 里问：*Does your app contain, show, or access third-party content?*

### 事实

| 事实 | 细节 |
|---|---|
| 内置示例是真实餐厅的菜单照片 | La Mar（秘鲁菜，Issaquah 店）、Naan n Curry（印巴菜） |
| 画面里有第三方商标 | 主截图 `02_canvas.png` 左上角是 **naan n curry 的 logo**，页面上有店名 |
| App 核心功能 | 处理**用户自己拍摄**的第三方菜单 —— 这部分是用户提供的内容，不由开发者分发 |
| 暴露面最大的地方 | **不是 App 内，而是 App Store 商品页截图** —— 那是开发者主动的营销素材 |

### 判断

「这个 App 包含第三方内容」这句事实上成立，**答 Yes 是正确的**，绝大多数 App 都是 Yes。

真正需要人来定的是后续那一问（是否拥有必要的权利）。相关考量：

- 菜单的**文字列表**是事实性汇编，著作权很弱；照片是自己拍的
- **logo 是商标**，这是风险实际所在。在 App 内作为演示展示，通常算描述性/指名性使用；
  但把它放进 **App Store 营销截图**性质不同 —— 可能被读作暗示背书
- 实际风险：小（App 很小、不易被注意到），但非零，而且正是 **5.2.1** 投诉针对的那一类

### 可选做法（成本递增）

| 方案 | 做法 | 代价 |
|---|---|---|
| A | 答 Yes，照现状提交 | 0。最可能没事，同类 App 普遍这么做 |
| B | 保留 App 内示例，但把截图里的 logo 区域模糊/遮掉 | 主截图观感变差 |
| C | 换一份自己有权利的菜单重烤示例 | 要重跑七种语言 + 重拍 28 张截图 |

交接人尚未决定。**没有明确指示前按 A（答 Yes）填，并把这一节指给交接人看。**
