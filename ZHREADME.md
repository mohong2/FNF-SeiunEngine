# SeiunEngine（中文）

**作者：mo_hong** — [github.com/mohong2/FNF-SeiunEngine](https://github.com/mohong2/FNF-SeiunEngine)

**你知道吗：** 如果你去催促一个开发者更新你想要的内容和优化，你可能等来的并不是你想要的更新，而是停更。我很想把这一个引擎做好，但我的实力就摆在那儿，请不要过度期待。

基于 Psych Engine 0.6.3 的 Friday Night Funkin' 引擎，为 Mandela Funkin Night 模组构建。

**声明：** 本项目开发过程中使用了 AI 工具辅助。

**[English](./README.md)**

## 支持的平台

- Windows
- macOS
- Linux
- Android
- iOS —— 能编，但没测过，能不能跑不知道

没有 HTML5 构建。

## 构建

需要 Haxe 4.2.5。

```sh
haxelib setup .haxelib
haxe -cp ./setup -main Main --interp
lime build windows
```

其他平台：`lime build mac`、`lime build linux`、`lime build android`、`lime build ios -arm64`。

也可以直接在 GitHub Actions 的 Build workflow 手动触发，选平台，跑完下载产物。

## 依赖

见 `hmm.json`。其中七个是我自己的 fork：

- flixel
- hxvlc
- extension-androidtools
- linc_luajit-rewriten
- openfl
- lime
- hscript

## Mod

把 mod 放进 `mods/`，参见 `Modding.md`。

## 联机

- 桌面构建默认启用局域网联机（主菜单 → 联机）。
- 离线构建：`art\build_x64_offline.bat`（`-D SEIUN_NO_ONLINE`），不编译联机代码、不发起任何网络请求。
- 专用服务器：`server\start_server.bat`，详见 `docs/online-usage.md` 与 `docs/multiplayer-protocol.md`。
- 联机菜单 UI / 房间协议模型**移植 / 参照**自 [Funkin-Psych-Online](https://github.com/Snirozu/Funkin-Psych-Online)（Snirozu，Apache-2.0），本仓库内为自研 Haxe 实现；完整署名见 [`NOTICE`](NOTICE) 与「制作人员」。

## 制作人员

- ![mo_hong](assets/preload/images/credits/mohong.png) **mo_hong** — 主要开发者和维护者，负责引擎的大量修改、性能优化、错误修复和中文本地化。还深入研究了无数指针和底层调试，确保稳定运行 lol · [哔哩哔哩](https://space.bilibili.com/672029688)

- ![Li.tmc](assets/preload/images/credits/Li.tmc.png) **Li.tmc** — 旧引擎图标（MohongEngine） · [哔哩哔哩](https://space.bilibili.com/3537117498051255)

### SeiunEngine 鸣谢名单

- ![CitriSnow](assets/preload/images/credits/CitriSnow.png) **CitriSnow** — 为引擎提供了部分脚本设计方案，并在开发引擎的这一段时间内一直提供支持 · [哔哩哔哩](https://space.bilibili.com/1951803423)

- ![MuXue](assets/preload/images/credits/muxue.png) **MuXue** — 为引擎找到了数不尽的 bug，为引擎的稳定性做出了重要贡献，并在开发引擎的这一段时间内一直提供支持 · [哔哩哔哩](https://space.bilibili.com/3493084289566971)

- ![Pico](assets/preload/images/credits/pico.png) **Pico（非 FNF 角色 Pico）** — 自 MohongEngine 时期起便持续支持本引擎的制作，并为引擎提供了若干宝贵的 Bug 反馈 · [哔哩哔哩](https://space.bilibili.com/3546752359598592)

- ![Wolf Yeying](assets/preload/images/credits/xiaolangyeying.jpg) **小狼夜瑛** — 为引擎发现了若干 Bug，为引擎的稳定运行作出了贡献 · [哔哩哔哩](https://space.bilibili.com/3493115727972533)

- ![一只可爱的bf呀](assets/preload/images/credits/bfya.png) **一只可爱的bf呀** — 提供了精神支持和一些想法 lol · [哔哩哔哩](https://space.bilibili.com/3546642993122123)

- ![Bonus-XK](assets/preload/images/credits/bonusxk.png) **Bonus-XK** — 另一款引擎（[FNF-MeteoricEngine](https://github.com/Bonus-XK/FNF-MeteoricEngine)）的作者，与 SeiunEngine 作者时常交流，并在引擎开发期间给予了重要的精神支持与鼓励 · [哔哩哔哩](https://space.bilibili.com/3461572190013717)

### Psych Engine 团队（基础引擎）

- ![Shadow Mario](assets/preload/images/credits/shadowmario.png) **Shadow Mario**
- ![RiverOaken](assets/preload/images/credits/river.png) **RiverOaken**
- ![Yoshubs](assets/preload/images/credits/shubs.png) **Yoshubs**

### 特别鸣谢

- ![bbpanzu](assets/preload/images/credits/bb.png) **bbpanzu**
- ![shubs](assets/preload/images/credits/shubs.png) **shubs**
- ![SqirraRNG](assets/preload/images/credits/sqirra.png) **SqirraRNG**
- ![KadeDev](assets/preload/images/credits/kade.png) **KadeDev**
- ![iFlicky](assets/preload/images/credits/flicky.png) **iFlicky**
- ![PolybiusProxy](assets/preload/images/credits/proxy.png) **PolybiusProxy**
- ![Keoiki](assets/preload/images/credits/keoiki.png) **Keoiki**
- ![Smokey](assets/preload/images/credits/smokey.png) **Smokey**
- ![Nebula the Zorua](assets/preload/images/credits/nebula.png) **Nebula the Zorua**

### Codename Engine 团队（[CodenameCrew](https://github.com/CodenameCrew)）

本引擎的 Mod 系统参考了 Codename Engine 的 Mod 格式（`pack.json`、`stateReplacements`/`substateReplacements`、谱面导入导出）。  
SeiunEngine **不是** Codename Engine 的分支，本仓库**不包含** Codename Engine 的任何源代码。  
Codename Engine 自身的条款请参阅 [Codename Engine 仓库](https://github.com/CodenameCrew/CodenameEngine)。

### Funkin-Psych-Online（[Snirozu](https://github.com/Snirozu/Funkin-Psych-Online)）

本引擎的联机菜单 UI、房间 / 协议模型与服务端房间语义**移植 / 参照**自 Funkin-Psych-Online 及其配套的 Funkin-Online-Server，二者以 Apache License 2.0 发布。  
本仓库内的联机实现是 SeiunEngine 自研的 Haxe 代码，**不包含**上述仓库的任何 TypeScript / Node 源码。  
完整署名见 [NOTICE](NOTICE)。

## License

见 LICENSE（Psych Engine 的开源许可）。
