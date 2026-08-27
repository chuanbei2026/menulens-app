# App Store 提审资料包 — ForeignMenu · 外乡人的菜单

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
| 年龄分级 | 4+ |

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
| 技术支持 URL | https://github.com/chuanbei2026/menulens-app |
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
> annotation, and PDF export. The samples are bundled in all six app
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

- [ ] Apple Developer Program 注册通过（$99/年，个人）
- [x] 定新名字：**ForeignMenu** / **外乡人的菜单**（跨 6 个商店筛过无撞名）
- [ ] 在 USPTO 与 EUIPO 各查一次 ForeignMenu 的商标
- [ ] App Store Connect 创建 App（Bundle ID ai.xiangyang.MenuLens —— 这个不用改）
- [ ] 填 EU DSA trader 三项（地址 / 电话 / 邮箱，均会公开显示）
- [x] repo 已推 GitHub（public）并已开 Pages，隐私政策 URL 生效
- [ ] Xcode：Signing 选中付费 Team → Product → Archive → Distribute → App Store Connect
- [ ] 上传 6.9 英寸 iPhone 截图（`docs/screenshots/iphone-6.9/<lang>/`，1320×2868 ✅ 已重拍）
- [ ] 上传 13 英寸 iPad 截图（`docs/screenshots/ipad-13/<lang>/`，2064×2752 ✅ 已重拍）
      —— en / zh-Hans / fr / ko 四套，按 locale 分别上传；未拍的语言回落主语言
- [ ] TestFlight 内测一轮再提正式审核（七种语言各走一遍，看文案溢出）
- [ ] 申报 EU DSA trader 状态，或取消勾选欧盟国家（不申报会被移除，见 release plan 🟢-1）
- [ ] 回答新版年龄分级问卷（2025-07 改版，专门问 AI 功能）
- [x] 创建低限额测试 Key（已存 docs/review-key.local.md，本地文件），过审后作废
