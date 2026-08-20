# App Store 提审资料包 — MenuLens · 口袋菜单

## 基本信息

| 字段 | 值 |
|---|---|
| App 名称 (App Store) | MenuLens - 口袋菜单 |
| 副标题 (30 字符) | 拍菜单，秒变中文，还能点菜 |
| Bundle ID | ai.xiangyang.MenuLens |
| 类别 | 主：旅行 Travel；次：美食佳饮 Food & Drink |
| 价格 | 免费 |
| 年龄分级 | 4+ |

## 描述（中文）

出国吃饭看不懂菜单？拍一张，MenuLens 把整份菜单原版式翻译成你的语言。

【原版式翻译】不是干巴巴的文字列表——译文直接写在菜单原来的位置上，
版式、字号、行距都保留，像拿到了一份母语版菜单。菜名保留原文对照，点菜时
直接指给服务员看。

【自动矫正】手持拍摄的倾斜、透视、模糊照片自动拉正、锐化，多页菜单一次搞定。

【看图点菜】菜单上没有配图？AI 为每道菜生成参考小图。列表模式支持搜索、
素食/海鲜/羊肉标识。

【多人点单】给同桌的每个人建档（可传头像），谁点的菜一目了然。确认后一键
把所点菜品标注回原菜单——服务员对着屏幕就能下单，上菜时按名字对号入座。

【六种目标语言】中文（简体）、English、日本語、한국어、Français、Español。
菜单原文语言自动识别，无需设置。

【隐私优先】没有服务器、没有账号、没有追踪。你的 OpenAI API Key 和所有
翻译记录只保存在手机本地。

使用需要你自己的 OpenAI API Key（应用内有获取指引，一份菜单约 $0.05-0.25）。
内置两家真实餐厅的完整示例，安装后无需任何配置即可体验全部功能。

## Description (English)

Point your camera at any foreign menu — MenuLens translates it in place,
preserving the original layout. Dish names stay bilingual so you can order
by pointing. Auto-straightens hand-held photos, handles multi-page menus,
generates dish thumbnails, tracks who ordered what for group dining, and
annotates the order back onto the menu for your server. Six target
languages. No server, no account, no tracking — bring your own OpenAI API
key (in-app guide; a menu costs ~$0.05–0.25). Two full sample restaurants
included, no setup needed to try.

## 关键词 (100 字符)

菜单,翻译,旅行,点菜,menu,translator,travel,日本,韩国,restaurant,菜單,OCR

## URL

| 字段 | 值 |
|---|---|
| 隐私政策 URL | https://<你的GitHub用户名>.github.io/menulens/privacy-policy.html （推 GitHub Pages 后生效） |
| 技术支持 URL | 同上仓库的 README 或 issues 页 |

## App 隐私（隐私营养标签）

选择 **"不收集数据 / Data Not Collected"** —— 无服务器、无 SDK、无标识符。
（照片经 HTTPS 直连 OpenAI 处理、不经过开发者服务器，属于"不由开发者收集"。）

## 出口合规

已在 Info.plist 设 `ITSAppUsesNonExemptEncryption = NO`（仅标准 HTTPS），提审时无需再答加密问卷。

## 审核备注（Review Notes 粘贴用）

> MenuLens translates restaurant menus photographed by the user. It calls
> the OpenAI API directly from the device; users supply their own API key
> (Settings → OpenAI API Key). No developer server is involved.
>
> FOR REVIEW: the app is fully functional WITHOUT any API key — tap the
> clock icon (top-left) on the home screen to open History, which contains
> two complete pre-translated sample restaurants (La Mar, Naan n Curry)
> demonstrating every feature: zoomable in-place translated canvas, dish
> list with search and thumbnails, group ordering with member tags, order
> annotation, and PDF export.
>
> Optionally, this demo API key can be used to test live recognition:
> [在此粘贴一个限额较低的测试 Key，提审期间有效]

## 提审前 checklist

- [ ] Apple Developer Program 注册通过（$99/年，个人）
- [ ] App Store Connect 创建 App（名称 MenuLens - 口袋菜单，Bundle ID ai.xiangyang.MenuLens）
- [ ] 把 repo 推到 GitHub 并开 Pages，填隐私政策 URL
- [ ] Xcode：Signing 选中付费 Team → Product → Archive → Distribute → App Store Connect
- [ ] 上传 6.9 英寸截图（docs/screenshots/，1320×2868，已备好）
- [ ] TestFlight 内测一轮再提正式审核
- [ ] 创建一个低限额（如 $5）的专用测试 Key 填进审核备注，过审后作废
