# App Store 提审资料包 — ForeignMenu · 外乡人的菜单

> **2026-10-15：下一版（1.1）改为自建后端 + Apple 登录 + 点数。** 提交 1.1 时用紧接着的「1.1 提审资料」，
> 它替代下面 1.0 的描述、隐私标签和审核备注（1.0 那几段保留作历史，内容已经不成立：
> 「没有服务器、没有账号、需要自己的 OpenAI API Key」）。

## 1.1 (4) resubmission（2026-10-19 被拒后重新提交）

> **背景**：1.1 (3) 在 2026-10-19 被拒（审核设备 iPad Air 11-inch (M3)），两条：
> **3.1.1**（App 内兑换码能解锁付费内容）和 **5.1.1(v)**（扫菜单前必须先注册）。内购本身没有被拒。
> 1.1 (4) 从 `main` 构建（含繁体中文、覆盖重试、新结果页、订阅），版本号仍是 **1.1**，构建号 **4**。
> **店主 2026-10-19 定：三个订阅随 1.1 (4) 一起提交**，下面的文本都是带订阅的版本。
> 下面的内容**替代**「1.1 提审资料」里同名的字段；没列出的字段（名称、副标题、关键词、URL、
> 出口合规、年龄分级、上架地区）**不变**。

### 这一版改了什么（相对 1.1 (3)）

| | 1.1 (3)（被拒） | 1.1 (4) |
|---|---|---|
| 扫菜单前 | 必须先用 Apple 登录 | ✅ **不用登录**：首次打开自动建一个本机账号，送 300 点 |
| Apple 登录 | 必需 | 可选（设置 → 账号），只用来把余额带到其他设备 |
| 兑换码 | 设置 → 账号 → 兑换码 | ❌ **已删除**（App 和后端都下线）；送点数改用 App Store 优惠码（Offer Codes） |
| 商店 | 三个点数包 | 会员订阅（月 / 季 / 年）+ 三个点数包 + 「兑换 App Store 优惠码」（Apple 自己的兑换页） |
| 删除账号 | 设置 → 账号 → 删除账号 | 不变，本机账号和 Apple 账号都能删 |

### App Store Connect 要改的字段（逐项）

| # | 位置 | 字段 | 改成 |
|---|---|---|---|
| 1 | 1.1 版本页 → 构建版本 | Build | 换成 **1.1 (4)**（把 (3) 移掉） |
| 2 | 1.1 版本页 → 简体中文 | 描述 | 下面「描述（zh-Hans）」整段 |
| 3 | 1.1 版本页 → English (U.S.) | Description | 下面「Description (en)」整段 |
| 4 | 1.1 版本页 → 两个语言 | 宣传文本 Promotional Text | 下面两行（可随时改，不用审核） |
| 5 | 1.1 版本页 → 两个语言 | 此版本的新增内容 What's New | 下面两行 |
| 6 | 1.1 版本页 → App 审核信息 | 备注 Notes | 下面「审核备注」整段（英文） |
| 7 | 1.1 版本页 → App 审核信息 | 登录信息 Sign-in required | **取消勾选**「需要登录」（不需要演示账号） |
| 8 | 1.1 版本页 → App 预览和截图 | 6.9″ iPhone、13″ iPad（en / zh-Hans） | 换 `04_account`，把 `05_signin` 换成 `05_start`（路径见下面「截图」） |
| 9 | 解决方案中心（Resolution Center） | 回复 | 下面「给审核的回复」 |
| — | App 隐私 | 营养标签 | **不变**（见下面「隐私标签」） |
| 10 | 订阅 | 群组 + 三个订阅 | 按下面「订阅（1.2）」一节建好（价格、本地化、审核截图），**附加到 1.1 (4)** |
| 11 | App 信息 → App Store Server Notifications | Production / Sandbox | `https://api.chuanbei.dev/menu/appstore/notifications`，Version 2（后端部署之后再填，填完发测试通知） |
| — | 内购 | 三个点数包 | 不变，继续附加到 1.1 一起提交 |

> **备用（订阅被撤下、不随 1.1 (4) 提交时）**：两段描述删掉【会员】/ Membership 那一段和结尾的使用条款行，
> 审核备注删掉 "Subscriptions" 那一段，What's New 去掉「和会员订阅」/ "and a membership"；其余文字不变。
> 那样商店的会员区会显示「这里暂时还不能开通会员」（审核员可能按 2.1 提问）。

### 宣传文本（Promotional Text）

- zh-Hans：`拍一张外语菜单，原版式变成母语菜单。不用登录，打开就送 300 点，也不用申请 OpenAI key。`
- en：`Snap a foreign menu and read it in your language, laid out like the original. No sign-in: start with 300 free credits — no OpenAI key needed.`

### 描述（zh-Hans）

```
出国吃饭看不懂菜单？拍一张，外乡人的菜单把整份菜单原版式翻译成你的语言。

【原版式翻译】不是干巴巴的文字列表——译文直接写在菜单原来的位置上，版式、字号、行距都保留，像拿到了一份母语版菜单。菜名保留原文对照，点菜时直接指给服务员看。

【翻好一页先看一页】多页菜单不用等全部翻完，第一页好了就能先看。

【自动矫正】手持拍摄的倾斜、透视、模糊照片自动拉正、锐化，一次最多 8 页。

【看图点菜】菜单上没有配图？AI 为每道菜生成参考小图（标注为 AI 生成）。列表模式支持搜索、素食 / 海鲜 / 猪肉 / 牛肉 / 羊肉标识，还会挑出两三道值得点的菜，并说明理由。

【多人点单】给同桌的每个人建档（可传头像），标出各自不吃的东西，谁点的菜一目了然。确认后一键把所点菜品标注回原菜单——服务员对着屏幕就能下单。

【八种语言】中文（简体、繁體）、English、日本語、한국어、Français、Español、हिन्दी。一个开关同时切换界面语言和翻译目标语言，全新安装自动跟随系统语言。菜单原文语言自动识别。

【点数】不用登录，打开就能用，新账号送 300 点。识别一页菜单约 8–12 点，一张配图（4 道菜）约 0.5 点，按实际用量扣，点数不过期。用完可以在应用内购买。想在其他设备上用同一份余额，可以选择用 Apple 登录。

【会员】按月、按季或按年订阅：扫菜单、生成配图不扣点数（每月约 600 点用量以内），每月再送 50 点。可随时在 App Store 设置里取消。

【隐私】我们不要你的姓名和邮箱。菜单照片和文字只在识别时经过我们的服务器转给 AI，不保存；翻译记录、同行成员和头像只保存在手机上。可以随时在应用内删除账号。

内置两家真实餐厅的完整示例，打开就能体验全部功能。

使用条款：https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
```

### Description (en)

```
Can't read the menu? Snap it, and ForeignMenu translates the whole thing in place, keeping the original layout — like being handed a menu in your own language. Dish names stay bilingual, so you can order by pointing.

• Pages as they're ready: multi-page menus show each page as soon as it's translated.
• Auto-straightens tilted, hand-held photos; up to 8 pages at once.
• Dish pictures: dishes without a photo get an AI-generated thumbnail (marked as AI). The dish list has search, vegetarian / seafood / pork / beef / lamb tags, and two or three picks worth ordering, with the reason.
• Group dining: add everyone at the table, mark what each person doesn't eat, see who ordered what, and annotate the order back onto the menu for your server.
• Eight languages — one switch sets both the interface and the translation language; a fresh install follows your system language.
• Credits: no sign-in needed — start with 300 free credits. A menu page takes about 8–12, a dish picture (four dishes) about 0.5, charged by actual use; credits never expire and more can be bought in the app. Sign in with Apple is optional, to use your balance on other devices.
• Membership: subscribe monthly, quarterly or yearly — menu scans and dish pictures don't use credits (fair use about 600 credits a month), plus 50 credits every month. Cancel any time in your App Store settings.
• Privacy: no name or email asked. Menu photos and text pass through our server to the AI only while they're read and are not stored; your history, people and photos stay on your phone. Delete your account any time in the app.

Two full sample restaurants are included — try every feature right away.

Terms of Use: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
```

> 和 1.1 (3) 的描述比：【点数】/ Credits 一段不再说「用 Apple 登录」；最后一句不再说「不登录也能」；
> 新增【会员】段和使用条款链接（有自动续订订阅的 App 必须写明）；语言改成八种（这个构建含繁体中文）；一页点数按 1.2 已核实的 8–12 点。两段都**没有**提兑换码（1.1 (3) 的描述本来就没提）。

### What's New

- zh-Hans：`不用再自己申请 OpenAI key，也不用登录：打开就能识别菜单，新账号送 300 点。多页菜单翻好一页先看一页；新增繁体中文和会员订阅。`
- en：`No more OpenAI key, and no sign-in: open the app and scan — new accounts get 300 free credits. Multi-page menus show each page as soon as it's ready; Traditional Chinese and a membership are new.`

### 审核备注（Review Notes，粘贴到 App Review Information → Notes）

```
ForeignMenu translates restaurant menus photographed by the user.

No sign-in needed: scanning works immediately with 300 free credits on an automatically created device account (a random account id only — no name, email or other personal data is asked for). Sign in with Apple is optional (Settings → Account) and only lets the user keep the same balance on other devices; signing in moves the device account's balance into the Apple account. Sign-out and account deletion are in the same place.

To test: on the start screen, take or pick a menu photo and tap "Scan and translate". Before the first photo is sent, a consent sheet names who receives what and offers a working "Not now" (guideline 5.1.2(i)); it can be withdrawn in Settings. Two complete pre-translated sample restaurants are under the clock icon (top left). Our server forwards the photo and its OCR text to an AI model (OpenAI; AWS Bedrock in regions OpenAI doesn't serve) and stores neither.

How to buy: Settings → Account → Buy credits (also offered when credits run out) opens the Shop with three consumable credit packs (100 / 500 / 2000 credits). Sandbox purchases work on the device account; no sign-in is needed to buy.

Subscriptions (new in this version): ForeignMenu Membership (monthly / quarterly / yearly, one group) makes menu scans and dish pictures free of credits up to a fair use of about 600 credits' worth a month, and adds 50 credits each month. Above the fair use, calls use credits as before. Buy it in the same Shop (Settings → Account → Buy credits); it works on the device account with a Sandbox account, no sign-in needed. Terms of Use: Apple's standard EULA; Privacy Policy linked on the paywall.

Changes since the previous submission (1.1 (3)):
- Guideline 3.1.1: redeem codes have been removed from the app entirely; nothing in the app unlocks credits with a code any more (the server endpoint is disabled too). The only code entry left is Apple's own offer code redemption sheet ("Redeem App Store Offer Code" in the Shop).
- Guideline 5.1.1(v): registration is no longer required. Every feature works without an account the user has to create; Sign in with Apple is optional.

Account deletion: Settings → Account → Delete account (for the device account as well as an Apple account; for an Apple account it also revokes the Sign in with Apple authorization).
```

### 给审核的回复（Resolution Center，可选，提交 1.1 (4) 时附上）

```
Thank you for the review. In build 1.1 (4):
- 3.1.1: we removed the redeem-code feature completely. Credits can only be bought with In-App Purchase; promotional giveaways will use App Store Offer Codes.
- 5.1.1(v): no registration is required any more. The app creates an anonymous device account automatically, so menu scanning works right away with 300 free credits. Sign in with Apple is optional and only used to keep the balance across devices.
```

### 订阅随 1.1 (4) 提交：还要做的

1. **先部署后端**（订阅路由和本次的匿名账号路由在同一次 `deploy.sh` 里），再在 ASC 填 Server Notifications 地址、发测试通知。
2. ASC 按下面「订阅（1.2）」一节建群组和三个订阅，附加到 1.1 (4)（那一节的「1.1 审核结束后再部署」已不适用）。
3. 订阅的审核截图（商店会员区）要在 ASC 建好订阅之后在真机 / TestFlight 上截（命令行跑的模拟器拿不到方案）。

### 截图（只换这两张，其余 01–03、06 不变）

| 文件 | 内容 | 状态 |
|---|---|---|
| `docs/screenshots/iphone-6.9/<lang>/04_account.png` | 设置 → 账号：「未登录（本机账号）」、余额、30 天图表（假数据）、买点数、可选的「通过 Apple 登录」 | ✅ en / zh-Hans / fr / ko 已重拍 |
| `docs/screenshots/ipad-13/<lang>/04_account.png` | 同上（iPad，主屏在后面） | ✅ en / zh-Hans / fr / ko 已重拍 |
| `docs/screenshots/iphone-6.9/<lang>/05_start.png` | 全新安装后的首页：没有登录卡片，拍照 / 相册直接可用（**替代 `05_signin.png`，旧文件已删**） | ✅ en / zh-Hans / fr / ko |
| `docs/screenshots/ipad-13/<lang>/05_start.png` | 同上（iPad） | ✅ en / zh-Hans / fr / ko |
| 订阅审核截图（商店会员区，方案按钮） | 命令行下 StoreKit 拿不到订阅方案 | ⏳ 以后再拍：ASC 建好订阅后在真机 / TestFlight 上截 |

ASC 里：删掉旧的 `05_signin`，上传 `05_start` 放在同一个位置；`04_account` 直接替换。

### 隐私标签（App Privacy）

**不用改。** 逐项核对过：

| 数据类型 | 1.1 (4) | 说明 |
|---|---|---|
| Identifiers → **User ID** | ✅ 收集 · **Linked to You** · App Functionality | 本机账号的随机 ID（`anon:<uuid>`）和 Apple 登录的匿名 ID 一样，都和余额、购买、订阅关联 —— 仍然 "linked" |
| Purchases → **Purchase History** | ✅ 收集 · Linked · App Functionality | 点数包、订阅、优惠码兑换的交易号，按账号记录（本机账号并入 Apple 账号时一起移过去） |
| Usage Data → **Product Interaction** | ✅ 收集 · Linked · App Functionality | 不变 |
| User Content | 不变 | 不变 |
| Tracking | ❌ | 不变；没有第三方 SDK |

- 本机账号的**设备密钥**只是一个登录凭证（服务器只存它的哈希），不是 Apple 定义里的用户数据类型。
- **防滥用的 IP 计数**（新建本机账号按 IP 限流）：只存 IP 的哈希和次数，不关联账号，最多 2 天自动删除，
  只用于防欺诈 / 安全。Apple 的数据类型里没有对得上的一项（不是 Device ID，也不和用户关联），建议不单列；
  隐私政策里已写明（`docs/privacy-policy.html`「防止滥用」一条）。
- 隐私政策已改：不再说「识别需要 Apple 登录」，改成「本机账号 + 可选的 Apple 登录」，并加了优惠码和防滥用两句。
  **推 GitHub Pages 要和提交 1.1 (4) 同一天。**

### 1.1 (4) 提交前 checklist

- [ ] 后端部署（新路由 `/auth/anonymous`、`/auth/apple/link`、`/auth/refresh`，兑换码 410），见 backend/README.md；部署后用 curl 建一个本机账号核对 300 点
- [ ] Archive 1.1 (4) 并上传（店主做）
- [ ] ASC 按上表逐项改；取消「需要登录」
- [ ] 截图替换（04、05）
- [ ] 推送 menulens 仓库（隐私政策、支持页随 GitHub Pages 生效）
- [ ] 真机：全新安装 → 不登录直接扫一页 → 设置里看到「未登录（本机账号）」→ 用 Apple 登录 → 余额并入；再删除账号
- [ ] 真机 Sandbox：买一个点数包到账（不登录）
- [ ] 订阅群组 + 三个订阅建好并附加到 1.1 (4)；订阅审核截图已传
- [ ] Server Notifications（Production + Sandbox，V2）已填，测试通知在日志里看到
- [ ] 真机 Sandbox：不登录买一次月度会员，`GET /credits` 的 `subscription.active` 为 true

---

## 1.1 提审资料（自建后端版）

> ⚠️ 1.1 (3) 的版本，2026-10-19 被拒；字段以上面「1.1 (4) resubmission」为准。

### 这一版变了什么（给填表的人看）

| | 1.0（线上） | 1.1 |
|---|---|---|
| 怎么用 AI | 用户自己填 OpenAI API Key | **Apple 登录**，用我们的服务器，按点数扣费 |
| 免费额度 | — | 新账号 **300 点**，只送一次 |
| 内购 | 无 | 3 个消耗型：$0.99 = 100 点、$4.99 = 500 点、$19.99 = 2000 点，**没有赠送** |
| 兑换码 | 无 | ~~有（设置 → 账号 → 兑换码）~~ 1.1 (4) 已删除（3.1.1） |
| 多页菜单 | 全部翻完才能看 | 翻好一页先看一页 |
| 识别模型 | 用户选 OpenAI 模型 | 默认 GPT-4.1，可选；OpenAI 不支持的地区只给 Mistral Large 3（经 AWS Bedrock），且不生成配图 |
| 上架地区 | 全部 | 去掉中国大陆、香港、澳门、俄罗斯、白俄罗斯、委内瑞拉、科索沃、安圭拉、英属维尔京群岛、蒙特塞拉特、特克斯和凯科斯群岛 |

版本号：project.yml 里的 `MARKETING_VERSION` 改成 `1.1`（构建号从 2 起）。

### 宣传文本（Promotional Text，170 字符上限，随时可改不用审核）

- zh-Hans：`拍一张外语菜单，原版式变成母语菜单。新账号送 300 点，不用再申请 OpenAI key。`
- en：`Snap a foreign menu and read it in your language, laid out like the original. New accounts get 300 free credits — no OpenAI key needed.`

### 描述（中文）

出国吃饭看不懂菜单？拍一张，外乡人的菜单把整份菜单原版式翻译成你的语言。

【原版式翻译】不是干巴巴的文字列表——译文直接写在菜单原来的位置上，版式、字号、行距都保留，像拿到了一份母语版菜单。菜名保留原文对照，点菜时直接指给服务员看。

【翻好一页先看一页】多页菜单不用等全部翻完，第一页好了就能先看。

【自动矫正】手持拍摄的倾斜、透视、模糊照片自动拉正、锐化，一次最多 8 页。

【看图点菜】菜单上没有配图？AI 为每道菜生成参考小图（标注为 AI 生成）。列表模式支持搜索、素食 / 海鲜 / 猪肉 / 牛肉 / 羊肉标识，还会挑出两三道值得点的菜，并说明理由。

【多人点单】给同桌的每个人建档（可传头像），标出各自不吃的东西，谁点的菜一目了然。确认后一键把所点菜品标注回原菜单——服务员对着屏幕就能下单。

【七种语言】中文（简体）、English、日本語、한국어、Français、Español、हिन्दी。一个开关同时切换界面语言和翻译目标语言，全新安装自动跟随系统语言。菜单原文语言自动识别。

【点数】用 Apple 账号登录即可使用，新账号送 300 点。识别一页菜单约 5–10 点，一张配图（4 道菜）约 0.5 点，按实际用量扣，点数不过期。用完可以在应用内购买。

【隐私】我们不要你的姓名和邮箱。菜单照片和文字只在识别时经过我们的服务器转给 AI，不保存；翻译记录、同行成员和头像只保存在手机上。可以随时在应用内删除账号。

内置两家真实餐厅的完整示例，不登录也能体验全部功能。

### Description (English)

Can't read the menu? Snap it, and ForeignMenu translates the whole thing in place, keeping the original layout — like being handed a menu in your own language. Dish names stay bilingual, so you can order by pointing.

• Pages as they're ready: multi-page menus show each page as soon as it's translated.
• Auto-straightens tilted, hand-held photos; up to 8 pages at once.
• Dish pictures: dishes without a photo get an AI-generated thumbnail (marked as AI). The dish list has search, vegetarian / seafood / pork / beef / lamb tags, and two or three picks worth ordering, with the reason.
• Group dining: add everyone at the table, mark what each person doesn't eat, see who ordered what, and annotate the order back onto the menu for your server.
• Seven languages — one switch sets both the interface and the translation language; a fresh install follows your system language.
• Credits: sign in with Apple and get 300 free credits. A menu page takes about 5–10, a dish picture (four dishes) about 0.5, charged by actual use; credits never expire and more can be bought in the app.
• Privacy: no name or email asked. Menu photos and text pass through our server to the AI only while they're read and are not stored; your history, people and photos stay on your phone. Delete your account any time in the app.

Two full sample restaurants are included — try every feature without signing in.

### 关键词（不变）

沿用下面 1.0 的两套关键词（不重复名称和副标题里的词）。

### App 隐私（营养标签）· 1.1

| 数据类型 | 收集 | 关联身份 | 用途 | 说明 |
|---|---|---|---|---|
| Identifiers → **User ID** | ✅ | Linked to You | App Functionality | Apple 登录给的匿名账号 ID（不要姓名和邮箱） |
| Purchases → **Purchase History** | ✅ | Linked to You | App Functionality | 交易号和点数包，用来到账、防止重复到账 |
| Usage Data → **Product Interaction** | ✅ | Linked to You | App Functionality | 点数余额、每天的用量（次数、token 数），不含菜单内容 |
| User Content → **Photos or Videos**、**Other User Content** | ⚠️ 按 Apple 定义判断 | Not Linked | App Functionality | 照片和识别出的文字经我们的服务器实时转给 AI（OpenAI 或 AWS Bedrock），我们不保存；OpenAI 对 API 数据有约 30 天滥用监控留存——1.0 时据此申报过「收集」，1.1 继续申报更稳妥 |
| Tracking | ❌ | | | 不用于追踪，没有第三方 SDK |

营养标签、App 内同意屏、隐私政策（docs/privacy-policy.html，已改成新口径）三处必须一致。

### 审核备注（Review Notes）· 1.1

> ForeignMenu translates restaurant menus photographed by the user. Since this version there is no API
> key: the user signs in with Apple (start screen, or Settings → Account) and new accounts get 300 free
> credits. Our own server forwards the photo and its OCR text to an AI model (OpenAI; AWS Bedrock in
> regions OpenAI doesn't serve) and stores neither.
>
> Before the first photo is sent, a consent sheet names who receives what and offers a working
> "Not now" (guideline 5.1.2(i)); it can be withdrawn in Settings.
>
> To test: sign in with Apple, take or pick a menu photo, tap Scan. Credits can be bought in
> Settings → Account → Buy credits (three consumable packs; sandbox purchases work). Account deletion:
> Settings → Account → Delete account. Without signing in, the History screen (clock icon, top left)
> has two complete pre-translated sample restaurants showing every feature.

### 更新说明（What's New）· 1.1

- zh-Hans：不用再自己申请 OpenAI key 了。用 Apple 账号登录就能识别菜单，新账号送 300 点；多页菜单翻好一页就能先看一页。
- en：No more OpenAI key. Sign in with Apple and start scanning — new accounts get 300 free credits, and multi-page menus show each page as soon as it's ready.

### 内购（附加到 1.1 一起提交）

| Product ID | Reference Name | 价格 | 显示名称（中 / 英） | 描述（中 / 英） |
|---|---|---|---|---|
| ai.xiangyang.MenuLens.credits.100 | 100 credits | US$0.99 | 100 点 / 100 Credits | 识别菜单和生成配图用的点数 / Credits for menu scans and dish pictures |
| ai.xiangyang.MenuLens.credits.500 | 500 credits | US$4.99 | 500 点 / 500 Credits | 同上 |
| ai.xiangyang.MenuLens.credits.2000 | 2000 credits | US$19.99 | 2000 点 / 2000 Credits | 同上 |

每个商品要一张商店页面截图。名称和描述里不出现赠送 / bonus。

### 1.1 提审前 checklist

- [ ] App ID 已开 Sign in with Apple（Xcode 自动开通，browser agent 确认）
- [ ] Sign in with Apple 撤销用的 .p8 key 建好，后端接上「删除账号时撤销 Apple 授权」
- [ ] 3 个内购建好（草稿），截图已传
- [ ] 上架地区按上表去掉
- [ ] 真机用 Sandbox 账号买一次，确认到账
- [ ] 推送 menulens 仓库（隐私政策和支持页随 GitHub Pages 生效）——**和提交 1.1 同一天**，免得线上 1.0 和隐私政策对不上
- [ ] 截图重拍：首页登录卡片、边扫边看、设置里的积分卡片
- [ ] 作废 1.0 审核用的测试 OpenAI key

---

## 1.2 多语言商店页（App 已支持这些语言，商店页还没有）

> 1.2 提交时在 App Store Connect 里**新增这 6 个语言**，各填下面的名称、副标题、宣传文本、描述、关键词、更新说明。
> 字数已用脚本核对，都在 Apple 的限制以内（名称 / 副标题 30、宣传文本 170、关键词 100、描述 4000）。
> 截图：fr、ko 已有（docs/screenshots/*/fr|ko/）；zh-Hant 等繁体中文版做好后补拍；ja、es、hi 暂时回落到英文截图。
> 1.2 的 What's New 在 en / zh-Hans 里也加一句「新增繁体中文」。

### 繁體中文 (zh-Hant)

| 字段 | 内容 |
|---|---|
| 名称 | 外鄉人的菜單 |
| 副标题 | 拍菜單，秒變母語，還能點菜 |
| 宣传文本 | 拍一張外語菜單，原版式變成母語菜單。新帳號送 300 點，不用申請 OpenAI key。 |
| 关键词 | `菜單,翻譯,旅行,點菜,餐廳,日本,韓國,泰國,出國,美食,menu,translator,OCR,外食` |
| 更新说明 | 新增繁體中文。 |

描述：

出國吃飯看不懂菜單？拍一張，外鄉人的菜單把整份菜單原版式翻譯成你的語言。

【原版式翻譯】譯文直接寫在菜單原來的位置上，版式、字號都保留，像拿到一份母語版菜單。菜名保留原文對照，點菜時直接指給服務生看。

【翻好一頁先看一頁】多頁菜單不用等全部翻完，第一頁好了就能先看。

【自動校正】手持拍攝的傾斜、透視照片自動拉正，一次最多 8 頁。

【看圖點菜】沒有配圖的菜，AI 生成參考小圖（標註為 AI 生成）。列表支援搜尋、素食／海鮮／豬肉／牛肉／羊肉標示，還會挑出兩三道值得點的菜並說明理由。

【多人點單】為同桌每個人建檔、標出各自不吃的東西，誰點了什麼一目了然，確認後一鍵標回原菜單給服務生看。

【八種語言】繁體中文、简体中文、English、日本語、한국어、Français、Español、हिन्दी。

【點數】不用登入，打開就能用，新帳號送 300 點。翻譯一頁約 8–12 點，一張配圖（4 道菜）約 0.5 點，點數不過期，用完可在 App 內購買。

【隱私】不需要姓名和電子郵件。菜單照片和文字只在辨識時經我們的伺服器轉給 AI，不保存；翻譯紀錄、同行成員只存在手機上。

內建兩家真實餐廳的完整範例，打開就能體驗全部功能。

### 日本語 (ja)

| 字段 | 内容 |
|---|---|
| 名称 | ForeignMenu |
| 副标题 | 外国語メニューをそのまま翻訳 |
| 宣传文本 | 外国語のメニューを撮るだけで、元のレイアウトのまま母国語に。新規アカウントに300クレジット、OpenAIのキーは不要です。 |
| 关键词 | `メニュー,翻訳,旅行,レストラン,海外,食事,注文,カメラ,OCR,グルメ,外食,韓国,タイ,フランス` |
| 更新说明 | 繁体字中国語に対応しました。 |

描述：

海外でメニューが読めない？撮るだけで、ForeignMenu がメニュー全体を元のレイアウトのまま翻訳します。

・その場で翻訳：訳文を元の位置に書き込むので、母国語版のメニューを手にしたような感覚。料理名は原文と並べて表示し、指さしで注文できます。
・できたページから表示：複数ページのメニューも、訳せたページから順に見られます。
・自動補正：傾いた写真もまっすぐに。一度に最大8ページ。
・写真のない料理には AI が参考画像を生成（AI 生成と表示）。検索、ベジタリアン／シーフード／豚・牛・羊の表示、おすすめの2〜3品とその理由も。
・グループの注文：同席者ごとに苦手なものを登録し、誰が何を頼んだかをメニューに書き戻して店員さんに見せられます。
・8言語対応：日本語、English、简体中文、繁體中文、한국어、Français、Español、हिन्दी。
・クレジット：サインイン不要、最初から300クレジット。1ページ約8〜12、料理画像（4品）約0.5。期限なし、アプリ内で購入できます。
・プライバシー：名前やメールは不要。メニューの写真と文字は読み取りのときだけ当社サーバー経由で AI に送られ、保存しません。履歴は端末内のみ。

実在のレストラン2軒のサンプル付きで、すぐに全機能を試せます。

### 한국어 (ko)

| 字段 | 内容 |
|---|---|
| 名称 | ForeignMenu |
| 副标题 | 외국어 메뉴를 그대로 번역 |
| 宣传文本 | 외국어 메뉴를 찍기만 하면 원래 레이아웃 그대로 내 언어로. 새 계정에 300 크레딧, OpenAI 키는 필요 없어요. |
| 关键词 | `메뉴,번역,여행,식당,레스토랑,해외,음식,주문,카메라,OCR,맛집,일본,태국,번역기` |
| 更新说明 | 번체 중국어를 지원합니다. |

描述：

해외에서 메뉴를 못 읽겠다면? 찍기만 하세요. ForeignMenu가 메뉴 전체를 원래 레이아웃 그대로 번역합니다.

• 제자리 번역: 번역문을 원래 자리에 써 넣어, 내 언어로 된 메뉴판을 받은 것처럼 보입니다. 요리 이름은 원문과 함께 보여 줘 손가락으로 가리켜 주문할 수 있어요.
• 번역된 페이지부터 보기: 여러 페이지 메뉴도 번역이 끝난 페이지부터 바로 볼 수 있습니다.
• 자동 보정: 기울어진 사진도 반듯하게, 한 번에 최대 8페이지.
• 사진이 없는 요리는 AI가 참고 이미지를 만들어 줍니다(AI 생성 표시). 검색, 채식／해산물／돼지고기／소고기／양고기 표시, 추천 메뉴 2~3개와 그 이유까지.
• 함께 주문: 일행마다 못 먹는 음식을 등록하고, 누가 무엇을 시켰는지 메뉴에 표시해 직원에게 보여 줄 수 있어요.
• 8개 언어: 한국어, English, 日本語, 简体中文, 繁體中文, Français, Español, हिन्दी.
• 크레딧: 로그인 없이 바로 300 크레딧. 한 페이지 약 8–12, 요리 이미지(4개) 약 0.5. 만료 없음, 앱에서 구매 가능.
• 개인정보: 이름과 이메일은 받지 않습니다. 메뉴 사진과 글자는 인식할 때만 저희 서버를 거쳐 AI로 전달되고 저장되지 않으며, 기록은 기기에만 남습니다.

실제 레스토랑 두 곳의 샘플이 들어 있어 바로 모든 기능을 써 볼 수 있습니다.

### Français (fr)

| 字段 | 内容 |
|---|---|
| 名称 | ForeignMenu |
| 副标题 | Menus traduits sur place |
| 宣传文本 | Photographiez une carte en langue étrangère et lisez-la dans votre langue, mise en page d'origine. 300 crédits offerts, sans clé OpenAI. |
| 关键词 | `menu,carte,traduction,traducteur,voyage,restaurant,cuisine,commander,photo,OCR,japon,corée` |
| 更新说明 | Ajout du chinois traditionnel. |

描述：

Impossible de lire la carte ? Prenez-la en photo : ForeignMenu la traduit en entier, en gardant la mise en page d'origine.

• Traduction sur place : le texte traduit prend la place de l'original, comme si on vous tendait la carte dans votre langue. Les noms des plats restent bilingues pour commander du doigt.
• Page par page : sur une carte de plusieurs pages, chaque page s'affiche dès qu'elle est prête.
• Redressement automatique des photos prises à la main, jusqu'à 8 pages.
• Les plats sans photo reçoivent une image générée par IA (signalée comme telle). Recherche, mentions végétarien / fruits de mer / porc / bœuf / agneau, et 2 ou 3 plats à essayer, avec la raison.
• Repas en groupe : notez ce que chacun ne mange pas, voyez qui a commandé quoi et annotez la commande sur la carte pour le serveur.
• 8 langues : Français, English, Español, 日本語, 한국어, 简体中文, 繁體中文, हिन्दी.
• Crédits : sans inscription, 300 crédits offerts dès le départ. Une page coûte environ 8–12, une image de plats (quatre) environ 0,5. Sans expiration, rechargeables dans l'app.
• Confidentialité : ni nom ni e-mail. Les photos et le texte de la carte passent par notre serveur vers l'IA le temps de la lecture et ne sont pas conservés ; l'historique reste sur votre téléphone.

Deux vrais restaurants sont inclus en exemple : essayez tout tout de suite.

### Español (es)

| 字段 | 内容 |
|---|---|
| 名称 | ForeignMenu |
| 副标题 | Menús traducidos al instante |
| 宣传文本 | Fotografía una carta en otro idioma y léela en el tuyo, con su diseño original. 300 créditos gratis al empezar, sin clave de OpenAI. |
| 关键词 | `menú,carta,traducir,traductor,viaje,restaurante,comida,pedir,foto,OCR,japón,corea` |
| 更新说明 | Ahora en chino tradicional. |

描述：

¿No entiendes la carta? Hazle una foto: ForeignMenu la traduce entera manteniendo el diseño original.

• Traducción en su sitio: el texto traducido ocupa el lugar del original, como si te dieran la carta en tu idioma. Los nombres de los platos quedan en los dos idiomas para pedir señalando.
• Página a página: en cartas de varias páginas, cada página aparece en cuanto está lista.
• Endereza solo las fotos torcidas; hasta 8 páginas.
• Los platos sin foto reciben una imagen generada por IA (marcada como tal). Búsqueda, etiquetas vegetariano / marisco / cerdo / ternera / cordero, y 2 o 3 platos recomendados con el motivo.
• Comidas en grupo: apunta lo que no come cada uno, mira quién pidió qué y marca el pedido sobre la carta para el camarero.
• 8 idiomas: Español, English, Français, 日本語, 한국어, 简体中文, 繁體中文, हिन्दी.
• Créditos: sin registrarte, 300 gratis desde el principio. Una página cuesta unos 8–12 y una imagen de platos (cuatro) unos 0,5. No caducan y puedes comprar más en la app.
• Privacidad: sin nombre ni correo. Las fotos y el texto de la carta pasan por nuestro servidor hacia la IA solo mientras se leen y no se guardan; el historial queda en tu teléfono.

Incluye dos restaurantes reales de ejemplo: pruébalo todo al instante.

### हिन्दी (hi)

| 字段 | 内容 |
|---|---|
| 名称 | ForeignMenu |
| 副标题 | विदेशी मेन्यू, आपकी भाषा में |
| 宣传文本 | विदेशी भाषा के मेन्यू की फ़ोटो लें और उसे अपनी भाषा में पढ़ें, वही लेआउट। नए खाते को 300 मुफ़्त क्रेडिट, OpenAI की ज़रूरत नहीं। |
| 关键词 | `मेन्यू,अनुवाद,यात्रा,रेस्टोरेंट,खाना,ऑर्डर,menu,translate,travel,OCR,विदेश` |
| 更新说明 | अब पारंपरिक चीनी में भी। |

描述：

विदेश में मेन्यू पढ़ नहीं पा रहे? बस फ़ोटो लें — ForeignMenu पूरे मेन्यू का अनुवाद उसी लेआउट में कर देता है।

• वहीं पर अनुवाद: अनुवाद ठीक उसी जगह लिखा जाता है, जैसे मेन्यू आपकी भाषा में छपा हो। व्यंजनों के नाम दोनों भाषाओं में रहते हैं, ताकि आप उंगली रखकर ऑर्डर कर सकें।
• पेज तैयार होते ही दिखे: कई पेज वाले मेन्यू में हर पेज अनुवाद होते ही दिखने लगता है।
• टेढ़ी फ़ोटो अपने-आप सीधी, एक बार में 8 पेज तक।
• जिन व्यंजनों की फ़ोटो नहीं, उनके लिए AI से बनी तस्वीर (AI लिखा रहता है)। खोज, शाकाहारी / सीफ़ूड / पोर्क / बीफ़ / मटन के निशान, और 2-3 सुझाए गए व्यंजन, कारण के साथ।
• साथ में ऑर्डर: हर व्यक्ति क्या नहीं खाता, लिखें; किसने क्या ऑर्डर किया, देखें; और वेटर के लिए मेन्यू पर ऑर्डर चिह्नित करें।
• 8 भाषाएँ: हिन्दी, English, 日本語, 한국어, 简体中文, 繁體中文, Français, Español।
• क्रेडिट: साइन इन की ज़रूरत नहीं, शुरू से 300 क्रेडिट। एक पेज लगभग 8–12, व्यंजनों की एक तस्वीर (चार) लगभग 0.5। क्रेडिट कभी ख़त्म नहीं होते, ऐप में और ख़रीद सकते हैं।
• निजता: नाम या ईमेल नहीं चाहिए। मेन्यू की फ़ोटो और टेक्स्ट केवल पढ़ते समय हमारे सर्वर से AI तक जाते हैं, सहेजे नहीं जाते; इतिहास आपके फ़ोन पर ही रहता है।

दो असली रेस्टोरेंट के उदाहरण शामिल हैं — तुरंत सब आज़माएँ।

---

## 1.2 提审前 checklist（繁体中文 + 港澳重新上架）

- [ ] App：繁体中文（zh-Hant）做完并合入；版本号 1.2、构建号从 1 起
- [ ] 商店页：新增 zh-Hant / ja / ko / fr / es / hi 六个语言（上面「1.2 多语言商店页」）
- [ ] 截图：补拍 zh-Hant（iPhone + iPad）；fr / ko 沿用；ja / es / hi 回落英文
- [ ] **上架地区：重新勾选香港、澳门**（其余 OpenAI 不支持的地区继续不选）
  - 港澳用户在 App 里只能选 Mistral Large 3（AWS Bedrock，AWS 销售，没有地区名单，只受美国制裁约束），没有 AI 配图；后端早已就绪（src/regions.mjs）
  - 港澳当地没有 ICP / 网信办式的备案要求（docs 见 DateSeries 仓库 docs/research/2026-10-china-and-model-terms.md 的 A5）
  - 上架前先在模拟器用 `-storefront HKG` + 繁体中文实扫一页，确认 Mistral 输出的是繁体
- [ ] 审核备注加一句：“In Hong Kong and Macau the app uses a different model (Mistral Large 3 on AWS Bedrock) and offers no AI dish pictures, because OpenAI does not serve those regions.”
- [ ] 隐私政策：已经写了「OpenAI 或 AWS Bedrock」，不用改
- [ ] What's New（en / zh-Hans 也加）：新增繁体中文；香港、澳门可以下载了；翻译更完整（不再漏行漏菜）
- [ ] 1.2 的 en / zh-Hans 描述里「一页约 5–10 点」改成「约 8–12 点」（完整的翻译输出更长，2026-10-16 实测 9–12）

---

## 订阅（1.2）— 2026-10-19 起随 1.1 (4) 提交

> ⚠️ 店主 2026-10-19 定：订阅随 **1.1 (4)** 一起提交，本节的群组、商品、本地化、通知地址照用；
> 下面「审核结束后再部署」「1.2 订阅 checklist」里关于等待 1.1 审核的条目已不适用（见上面「1.1 (4) resubmission」）。

> 代码在分支 `subscriptions`（后端 + App）。**1.1 (3) 还在审核、审核员用的是线上后端**：
> 审核结果出来之前不要跑 `deploy.sh`、不要在 App Store Connect 里把订阅提交审核。
> 后端部署不需要新表、新权限、新环境变量（默认 600 / 50 写在 `config.mjs`，要调就设
> `SUBSCRIBER_MONTHLY_FAIR_USE` / `SUBSCRIBER_MONTHLY_GRANT`）。

### 规则（店主 2026-10-17 定）

| | 非会员（不变） | 会员 |
|---|---|---|
| 注册 | 送 300 点 | 同左 |
| 识别菜单、生成配图 | 按实际用量扣点 | **不扣点**，每个自然月（温哥华时区）约 **600 点的用量** 以内（合理使用） |
| 超出合理使用 | — | 照常从点数余额扣 |
| 每月赠送 | 无 | **+50 点**（当月第一次使用时到账，永不过期） |
| 点数包 | $0.99 / 4.99 / 19.99 = 100 / 500 / 2000 | 照样可以买 |

### 订阅群组

| 字段 | 值 |
|---|---|
| Reference Name | `ForeignMenu Membership` |
| 群组显示名（App Store 本地化） | zh-Hans `外乡人的菜单会员` · en `ForeignMenu Membership` · zh-Hant `外鄉人的菜單會員` · ja `ForeignMenu メンバーシップ` · ko `ForeignMenu 멤버십` · fr `Abonnement ForeignMenu` · es `Suscripción ForeignMenu` · hi `ForeignMenu सदस्यता` |
| 等级（Subscription Levels） | 三个都放 **Level 1**（同一服务、不同时长 → 互换在下个续订日生效，没有按比例退款） |

### 三个订阅

| Product ID | Reference Name | 时长 | 价格（美国，其余区按 Apple 自动换算） | Family Sharing |
|---|---|---|---|---|
| `ai.xiangyang.MenuLens.sub.monthly` | Membership Monthly | 1 个月 | **US$3.99**（Apple 的价位没有整 $4.00 时选 $3.99；有 $4.00 选 $4.00） | 关 |
| `ai.xiangyang.MenuLens.sub.quarterly` | Membership Quarterly | 3 个月 | **US$9.99**（同上，有 $10.00 选 $10.00） | 关 |
| `ai.xiangyang.MenuLens.sub.yearly` | Membership Yearly | 1 年 | **US$29.99**（同上，有 $30.00 选 $30.00） | 关 |

不设免费试用 / 推介优惠（以后要加再说）。`MenuLens/Products.storekit` 里本地测试用的是 4.00 / 10.00 / 30.00。

### 本地化（显示名 ≤ 35 字符，描述 ≤ 55 字符）

| 语言 | 月度 | 季度 | 年度 | 描述（三个通用） |
|---|---|---|---|---|
| zh-Hans | 月度会员 | 季度会员 | 年度会员 | 扫菜单、生成配图不扣点数，每月再送 50 点 |
| en-US | Monthly Membership | Quarterly Membership | Yearly Membership | Scan menus without using credits, plus 50 a month |
| zh-Hant | 月度會員 | 季度會員 | 年度會員 | 掃描菜單、產生配圖不扣點數，每月再送 50 點 |
| ja | 月額メンバーシップ | 3か月メンバーシップ | 年額メンバーシップ | メニュー読み取りでクレジット不要、毎月50クレジット進呈 |
| ko | 월간 멤버십 | 3개월 멤버십 | 연간 멤버십 | 메뉴 인식에 크레딧 차감 없음, 매달 50 크레딧 지급 |
| fr | Abonnement mensuel | Abonnement trimestriel | Abonnement annuel | Scans sans crédits, plus 50 crédits par mois |
| es | Suscripción mensual | Suscripción trimestral | Suscripción anual | Escanea sin gastar créditos y recibe 50 al mes |
| hi | मासिक सदस्यता | त्रैमासिक सदस्यता | वार्षिक सदस्यता | बिना क्रेडिट मेन्यू स्कैन, हर महीने 50 क्रेडिट |

### 审核用截图（Review Information → Screenshot，三个订阅可用同一张）

App 内「商店」页的会员区（`我 → 账号 → 买点数`）。需要 ASC 里三个订阅建好之后在真机 / TestFlight
上截（StoreKit 那时才拿得到方案）；或者在 Xcode 里 **Run**（scheme 带 `Products.storekit`）在模拟器上截。
开发阶段的截图：`/private/tmp/claude-501/-Users-xiangyang-Desktop-workplace-date-series/d3337d06-422d-4242-9ccd-2f9c53e29d7b/scratchpad/shots/subs-fm/`
（命令行下 StoreKit 拿不到方案，方案按钮那块显示「这里暂时还不能开通会员」，见下面风险）。

审核备注（Review Notes）追加一段：

> **Subscriptions (new in 1.2).** ForeignMenu Membership (monthly / quarterly / yearly, one group) makes menu scans
> and dish pictures free of credits up to a fair use of about 600 credits' worth a month, and adds 50 credits each
> month. Above the fair use, calls use credits as before. Buy it in Settings → Account → Buy credits (the Shop). The
> demo account can subscribe with a Sandbox account. Terms of Use: Apple's standard EULA; Privacy Policy linked on
> the paywall.

### App Store Server Notifications（App 信息 → App Store Server Notifications）

| 环境 | URL | 版本 |
|---|---|---|
| Production | `https://api.chuanbei.dev/menu/appstore/notifications` | Version 2 |
| Sandbox | `https://api.chuanbei.dev/menu/appstore/notifications` | Version 2 |

⚠️ 后端没部署之前 Apple 发过来会 404（Apple 会重试几天，无害）；**最好部署之后再填**，填完在 ASC 里点
「Request a Test Notification」，日志里应出现 `app store notification … type: TEST, ignored: no_transaction`。

### 商店页文字（1.2 描述里加一句）

- zh-Hans：【会员】按月、按季或按年订阅：扫菜单、生成配图不扣点数（每月约 600 点用量以内），每月再送 50 点。可随时在 App Store 设置里取消。
- en：【Membership】Subscribe monthly, quarterly or yearly: menu scans and dish pictures don't use credits (fair use about 600 credits a month), plus 50 credits every month. Cancel any time in your App Store settings.
- 描述末尾加 Terms of Use 链接（订阅 App 必须）：`https://www.apple.com/legal/internet-services/itunes/dev/stdeula/`

### 1.2 订阅 checklist

- [ ] 1.1 审核结果出来
- [ ] `subscriptions` 分支合并，`npm test` 通过，`AWS_PROFILE=claude-agent ./deploy.sh`
- [ ] ASC：订阅群组 + 三个订阅（价格、本地化、审核截图），附加到 1.2 一起提交
- [ ] ASC：Server Notifications URL（Production + Sandbox，V2），发测试通知看日志
- [ ] Sandbox 账号真机买一次月度：`GET /credits` 的 `subscription.active` 为 true，扫一页菜单 `charged: 0`
- [ ] 上线并稳定后：`ALLOW_SANDBOX_PURCHASES=0`（订阅和点数包共用这个开关）

## 1.0 提审资料（2026-08，已提交；以下为历史记录）

## 基本信息

| 字段 | 值 |
|---|---|
| App 名称 (App Store) | 按语言分别填：英文及其他区 **ForeignMenu**，中文区 **外乡人的菜单**（App Store Connect 支持按 locale 设名称 —— 比塞成一个 `A - B` 串更好，也不用挤 30 字符上限） |
| 主语言 | **English (U.S.)** |
| 副标题 · en (30 字符上限) | `Menus translated in place` (25) |
| 副标题 · zh-Hans | `拍菜单，秒变母语，还能点菜` |
| Bundle ID | ai.xiangyang.MenuLens |
| 类别 | 主：旅行 Travel；次：美食佳饮 Food & Drink |
| 价格 | 免费 |
| 年龄分级 | 4+（实测七步问卷：172 国 4+ / 巴西 AL / 韩国 ALL / 越南 00+） |
| Copyright | `2026 Xiangyang Shi` —— 无 © 符号，署名用 Team 证书上的拼法 |
| Content Rights | **Yes**（内置示例是真实餐厅菜单，含店名与 logo）—— 后续权利追问见 release plan |

## 描述（中文）

出国吃饭看不懂菜单？拍一张，外乡人的菜单把整份菜单原版式翻译成你的语言。

【原版式翻译】不是干巴巴的文字列表——译文直接写在菜单原来的位置上，
版式、字号、行距都保留，像拿到了一份母语版菜单。菜名保留原文对照，点菜时
直接指给服务员看。

【自动矫正】手持拍摄的倾斜、透视、模糊照片自动拉正、锐化，多页菜单一次搞定。

【看图点菜】菜单上没有配图？AI 为每道菜生成参考小图。列表模式支持搜索、
素食/海鲜/羊肉标识。

【多人点单】给同桌的每个人建档（可传头像），谁点的菜一目了然。确认后一键
把所点菜品标注回原菜单——服务员对着屏幕就能下单，上菜时按名字对号入座。

【七种语言】中文（简体）、English、日本語、한국어、Français、Español、हिन्दी。
一个开关同时切换界面语言和翻译目标语言，全新安装自动跟随系统语言。
菜单原文语言自动识别，无需设置。

【隐私优先】没有服务器、没有账号、没有追踪。你的 OpenAI API Key 和所有
翻译记录只保存在手机本地。

使用需要你自己的 OpenAI API Key（应用内有获取指引，一份菜单约 $0.05-0.25）。
内置两家真实餐厅的完整示例，安装后无需任何配置即可体验全部功能。

## Description (English)

Point your camera at any foreign menu — ForeignMenu translates it in place,
preserving the original layout. Dish names stay bilingual so you can order
by pointing. Auto-straightens hand-held photos, handles multi-page menus,
generates dish thumbnails, tracks who ordered what for group dining, and
annotates the order back onto the menu for your server.
Seven languages — one switch sets both the interface and the translation target,
and a fresh install follows your system language. No server, no account, no
tracking — bring your own OpenAI API key (in-app guide; a menu costs
~$0.05–0.25). Two full sample restaurants included, no setup needed to try.

## 关键词 (100 字符上限，按 locale 各填一套)

**en**（82 字符）

```
menu,translate,travel,restaurant,food,order,japan,korea,india,scan,ocr,dish,camera
```

**zh-Hans**

```
菜单,翻译,旅行,点菜,menu,translator,travel,印度,日本,restaurant,菜單,OCR,hindi
```

> 关键词里**不要**重复 App 名称和副标题里已有的词 —— Apple 已经索引了它们，
> 重复是浪费额度。

## URL

| 字段 | 值 |
|---|---|
| 隐私政策 URL | https://chuanbei2026.github.io/menulens-app/privacy-policy.html |
| 技术支持 URL | https://chuanbei2026.github.io/menulens-app/support.html —— 面向用户的支持页（含联系邮箱、FAQ）。**不要**填 GitHub README：那是开发者向的，Apple 有时会要求支持页上有联系方式 |
| 联系邮箱 | chuanbei666@gmail.com —— 隐私政策、DSA trader 栏、支持联系统一用这一个 |

## App 隐私（隐私营养标签）

> ⚠️ 2026-08-26 更正：原来这里写"不收集数据"，**是错的**。Apple 对 "collect"
> 的定义包含"发给你集成的第三方、且留存超过实时服务该请求所必需"，OpenAI 对 API
> 数据有约 30 天滥用监控留存 —— 所以菜单照片必须申报。详见
> `appstore-release-plan.md` 的 🔴-2。

| 字段 | 值 |
|---|---|
| 数据类型 | User Content → **Photos or Videos**（菜单照片） |
| 用途 | App Functionality |
| 关联身份 | **Not Linked to You**（不发送任何账号或标识符） |
| 用于追踪 | **Not Used for Tracking** |

其余数据（历史记录、同行成员姓名与头像、API Key）全部不出设备，不申报。
营养标签、App 内同意屏、隐私政策三处口径必须完全一致 —— Apple 会交叉比对。

## 出口合规

已在 Info.plist 设 `ITSAppUsesNonExemptEncryption = NO`（仅标准 HTTPS），提审时无需再答加密问卷。

## 审核备注（Review Notes 粘贴用）

> ForeignMenu translates restaurant menus photographed by the user. It calls
> the OpenAI API directly from the device; users supply their own API key
> (Settings → OpenAI API Key). No developer server is involved.
>
> Before the first photo is ever sent, the app shows a consent sheet naming
> OpenAI, listing exactly what is sent and what stays on the device, and
> offering a working "Not now" (guideline 5.1.2(i)). The permission can be
> withdrawn at any time in Settings.
>
> FOR REVIEW: the app is fully functional WITHOUT any API key — tap the
> clock icon (top-left) on the home screen to open History, which contains
> two complete pre-translated sample restaurants (La Mar, Naan n Curry)
> demonstrating every feature: zoomable in-place translated canvas, dish
> list with search and thumbnails, group ordering with member tags, order
> annotation, and PDF export. The samples are bundled in all seven app
> languages and seeded in the language of the device, so they appear in
> your own language.
>
> ForeignMenu is free. There is no paid tier, no in-app purchase, and no
> content sold by the developer. The OpenAI API key is the user's own
> account with a third party — it unlocks no developer-provided content,
> and the developer receives no payment of any kind.
>
> Optionally, this demo API key can be used to test live recognition:
> [提审时从 docs/review-key.local.md（本地文件，不入库）复制真实测试 Key 粘贴到这里]

## 提审前 checklist

> 完整的顺序、阻碍分析和判断在 `appstore-release-plan.md`。下面只是机械步骤。
> **先看那份**：有四条不改就会被拒的问题（第三方 AI 同意屏、隐私标签、
> 内置示例语言、PrivacyInfo.xcprivacy）不在下面这个列表里。

- [x] Apple Developer Program 注册通过（$99/年，个人，Team LNP5ER743F）
- [x] 定新名字：**ForeignMenu** / **外乡人的菜单**（跨 6 个商店筛过无撞名）
- [~] USPTO 已查无结果；EUIPO 未查（描述性词组，注册价值低，非阻塞）
- [x] App Store Connect 创建 App（Bundle ID ai.xiangyang.MenuLens —— 这个不用改）
- [x] 填 EU DSA trader 三项（地址 / 电话 / 邮箱，均会公开显示）
- [x] repo 已推 GitHub（public）并已开 Pages，隐私政策 URL 生效
- [x] 签名 + 打包 + 交付：`Apple Distribution` 证书 + App Store 描述文件，
      经 Transporter 交付 `1.0 (1)`（2026-08-27）
      —— 注意 Xcode 26 不再自带 iTMSTransporter，`altool` 的上传路径需要
      先装 Transporter.app；Xcode Organizer 的上传是自带实现，不受影响
- [x] 上传 6.9 英寸 iPhone 截图（`docs/screenshots/iphone-6.9/<lang>/`，1320×2868 ✅ 已重拍）
- [x] 上传 13 英寸 iPad 截图（`docs/screenshots/ipad-13/<lang>/`，2064×2752 ✅ 已重拍）
      —— en / zh-Hans / fr / ko 四套，按 locale 分别上传；未拍的语言回落主语言
- [x] 已提交审核（2026-08-27）
- [x] 申报 EU DSA trader 状态（欧盟正常发行）
- [x] 年龄分级问卷（七步，结果 4+；**没有** AI 相关的题）
- [x] 创建低限额测试 Key（已存 docs/review-key.local.md，本地文件），过审后作废

## 状态

**2026-08-27 已提交审核**（版本 1.0，构建 1.0 (1)）。等 Apple 邮件。

过审后要做的：

- [ ] 去 https://platform.openai.com/api-keys **作废审核用的测试 Key**
- [ ] 确认欧盟商品页上 trader 三项显示正常
- [ ] 考虑补 fr / ko 两个语言的本地化（截图已拍好，在 `docs/screenshots/*/fr|ko/`）
