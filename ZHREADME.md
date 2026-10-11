<div align="center">
  <img src="art/iconOG.png" width="280" alt="SeiunEngine 标志" />
  <h1>Friday Night Funkin' - SeiunEngine（星云引擎）</h1>
  <p>基于 <b>Psych Engine 0.6.3</b> 的 Friday Night Funkin' 引擎，<br/>最初为 <i>Mandela Funkin Night</i> 模组而构建 —— 专注于性能、模组系统与联机功能。</p>

  <p>
    <a href="https://github.com/mohong2/FNF-SeiunEngine/releases"><img src="https://img.shields.io/github/v/release/mohong2/FNF-SeiunEngine?include_prereleases&label=Release&logo=github" alt="Release" /></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache--2.0-blue.svg" alt="License: Apache-2.0" /></a>
    <a href="https://haxe.org"><img src="https://img.shields.io/badge/Haxe-4.3.7-EA8220?logo=haxe&logoColor=white" alt="Haxe 4.3.7" /></a>
    <a href="https://github.com/ShadowMario/FNF-PsychEngine"><img src="https://img.shields.io/badge/Base-Psych%20Engine%200.6.3-blue" alt="Base: Psych Engine 0.6.3" /></a>
    <img src="https://img.shields.io/badge/Platform-Windows%20%7C%20macOS%20%7C%20Linux%20%7C%20Android%20%7C%20iOS-brightgreen" alt="Platforms" />
    <a href="https://github.com/mohong2/FNF-SeiunEngine/stargazers"><img src="https://img.shields.io/github/stars/mohong2/FNF-SeiunEngine?style=flat&logo=github" alt="Stars" /></a>
    <a href="https://github.com/mohong2/FNF-SeiunEngine/commits/main"><img src="https://img.shields.io/github/last-commit/mohong2/FNF-SeiunEngine/main?label=Last%20Commit&logo=github" alt="Last Commit" /></a>
  </p>

  <p><a href="./README.md"><b>English</b></a> | <b>简体中文</b></p>

  <p><b>作者：</b><a href="https://github.com/mohong2">mo_hong</a></p>
</div>

---

## 简介

SeiunEngine（星云引擎，前身为 MohongEngine）是由 mo_hong 开发的 Friday Night Funkin' 引擎。它从 **Psych Engine 0.6.3** 分支而来，最初为 *Mandela Funkin Night* 模组而构建，之后逐步演进为一个拥有自身特性体系的通用引擎：重构的回放与联机系统、升级的脚本体系，以及面向海量 Note 谱面的深度性能优化。

> [!NOTE]
> 本项目在开发过程中使用了 AI 工具辅助。

> [!NOTE]
> **关于催更。** 去催促开发者更新你想要的内容和优化，等来的可能不是你想要的更新，而是停更。SeiunEngine 是由一名开发者利用业余时间维护的兴趣项目，请合理期待。Bug 反馈与功能建议随时欢迎通过 [Issues](https://github.com/mohong2/FNF-SeiunEngine/issues) 提出。

完整的开发历史请见[更新日志](CHANGELOG_SeiunEngine.md)。

## 功能特性

### 性能与渲染

- 针对超大 Note 数量优化 —— 数万至数十万 Note 的谱面依然可玩，得益于图集帧缓存与谱面缓存 / 流式加载。
- 针对 Note 密集场景的渲染与内存微优化。
- 桌面端与安卓端默认使用 **SDL3** 后端（删除 `Project.xml` 中的 `lime-sdl3` 定义可回退到 SDL2）。
- 提供两套可切换的 FPS 显示方案。

### 脚本与模组

- 增强版 **HScript**（内置 1.3.0）—— 强大到足以独立编写模组，包括自定义图标等资源。
- **Lua** 兼容性进一步增强，包括早期阶段的 (sub)state 访问能力。
- 内置 **Psych Engine 0.7.3 兼容层**，并对 Psych 1.0.4 的脚本提供部分兼容，照顾现有模组。
- Codename Engine 风格的模组格式：`pack.json`、`stateReplacements`/`substateReplacements`，以及编辑器内的 CNE 谱面导入导出。

### 谱面编辑

- 谱面编辑器支持 **Codename Engine（CNE）谱面格式**的导入 / 导出。
- 可选的谱面自动保存（默认关闭），以及统一的未保存更改确认（退出 / 重载 / 试玩 / 预览前均会弹窗）。

### 玩法与界面

- 完全重构的**回放系统**，附带回放 / 成绩历史界面。
- **Botplay HUD**，带实时 NPS（每秒音符数）显示。
- 重新设计的暂停菜单（带轻微 3D 效果）与重做的结算界面。
- **Trace 控制台**，方便脚本 / 日志的实时调试。
- 设置备份与恢复，以及全新的「渲染」「脚本优化」设置页。

### 联机

- 内置联机功能（Colyseus 兼容协议），桌面构建默认开启。
- **客户端内置开服（LAN HOST）**—— 一名玩家直接在联机菜单里开服，然后分享房间码。
- 独立的**专用服务器**（Haxe/neko 或原生可执行文件），使用 SQLite 持久化。
- 也提供完全**离线**的构建版本，不含任何联机代码。

### 诊断与本地化

- 崩溃报告自带 Haxe 源码文件 / 行号信息（安全模式），并提供安卓崩溃地址符号化工具。
- 引擎及全部设置页面均支持**简体中文 / 繁体中文 / 英文**三语。

## 支持的平台

| 平台 | 状态 |
| --- | --- |
| Windows | 支持（主要目标） |
| macOS | 支持 |
| Linux | 支持 |
| Android | 支持（含触控操作） |
| iOS | 能编译，但未测试 —— 不保证能运行 |
| HTML5 / 网页 | 不提供 |

## 构建

> [!IMPORTANT]
> 需要 **Haxe 4.3.7**（最低 4.3.0），以及按 4.3 API 构建的 hxcpp（`haxelib setup` 会自动装好）。旧的 4.2.1 hxcpp 分叉会被拒绝并提示 *"Hxcpp is out of date - please update"*。4.2.5 基线不再是本仓库支持的编译工具链：游戏客户端与联机服务端都以 4.3.7 构建并做类型检查（见 [`server/README.md`](server/README.md)）。

```sh
haxelib setup .haxelib
haxe -cp ./setup -main Main --interp
lime build windows
```

其他平台：

```sh
lime build mac
lime build linux
lime build android
lime build ios -arm64
```

也可以直接在 GitHub Actions 里手动触发 **Build** workflow，选好平台，跑完下载产物即可。

## 依赖

所有库依赖都管理在 [`hmm.json`](hmm.json) 中。其中七个是作者自己的 fork：

- flixel
- hxvlc
- extension-androidtools
- linc_luajit-rewriten
- openfl
- lime
- hscript

## 模组

把模组放进 `mods/` 文件夹即可。完整文档见 [`Modding.md`](Modding.md)，现成的示例模组在 [`example_mods/`](example_mods) 中。

> [!WARNING]
> SeiunEngine 以 Psych Engine 0.6.3 模组为目标，提供 0.7.3 兼容层和部分 1.0.4 脚本兼容 —— 但**任何引擎都无法保证所有模组都能运行**。请通过官方渠道支持原模组的作者们，他们真的做得很棒。

## 联机 / 多人

桌面构建默认开启联机（主菜单 → 联机）；除非使用 `-D SEIUN_NO_ONLINE` 构建，`Project.xml` 中 `ONLINE_ALLOWED` 恒为开启。

| 场景 | 服务端 | 客户端 |
| --- | --- | --- |
| **局域网**（最常用） | 房主运行 `server/start.ps1 -Lan`，或直接使用客户端内置的 **LAN HOST** | 其他人：联机 → 服务器列表 → 填房主**内网 IP**（裸 IP 会自动补 `:2567`） |
| **同机双开**（自测） | 服务端加 `--disable-ip-lock` | 两个客户端都填 `127.0.0.1:2567` |
| **专用 / 公网服务器** | `server/start.ps1`（或 `server/build.ps1` 后运行 `server/bin/server.n` / `server/bin/SeiunServer.exe`） | 填对外地址（`wss://` 走 443，不要补端口） |

- 客户端地址栏只填 **HTTP 端口（默认 2567）**；房间 WebSocket 端口（默认 2568）由服务端推导下发。
- 数据持久化使用 SQLite；旧 JSON 数据在首次启动时自动导入。
- 离线构建：`art/build_x64_offline.bat`（等价于 `lime build windows -release -D SEIUN_NO_ONLINE`），不含联机代码与内嵌服务端。

完整使用说明见 [`docs/online-usage.md`](docs/online-usage.md)；网络协议细节见 [`docs/multiplayer-protocol.md`](docs/multiplayer-protocol.md)，服务端说明见 [`server/README.md`](server/README.md)。

## 第三方代码说明

- **Codename Engine**（[CodenameCrew](https://github.com/CodenameCrew)）—— 本引擎的模组系统遵循 Codename Engine 的模组**格式**（`pack.json`、`stateReplacements`/`substateReplacements`、谱面导入导出）。SeiunEngine **不是** Codename Engine 的分支，本仓库**不包含** Codename Engine 的任何源代码。Codename Engine 自身的条款请参阅其仓库。
- **Funkin-Psych-Online**（[Snirozu](https://github.com/Snirozu/Funkin-Psych-Online)）—— 本引擎的联机菜单 UI、房间 / 协议模型与服务端房间语义**移植 / 参照**自 Funkin-Psych-Online 及其配套的 Funkin-Online-Server，二者以 Apache License 2.0 发布。本仓库内的联机实现是 SeiunEngine 自研的 Haxe 代码，**不包含**上述仓库的任何 TypeScript / Node 源码。完整署名见 [`NOTICE`](NOTICE)。

## 制作人员

### SeiunEngine 团队

| 头像 | 成员 | 贡献 | 链接 |
| --- | --- | --- | --- |
| <img src="assets/preload/images/credits/mohong.png" width="64" /> | **mo_hong** | 主要开发者和维护者 —— 负责引擎的大量修改、性能优化、错误修复和中文本地化 | [哔哩哔哩](https://space.bilibili.com/672029688) |
| <img src="assets/preload/images/credits/Li.tmc.png" width="64" /> | **Li.tmc** | 旧引擎图标（MohongEngine 时期） | [哔哩哔哩](https://space.bilibili.com/3537117498051255) |
| <img src="assets/preload/images/credits/none.png" width="64" /> | **None** | 安卓移植 | [哔哩哔哩](https://space.bilibili.com/392851046) |

### SeiunEngine 鸣谢名单

| 头像 | 成员 | 贡献 | 链接 |
| --- | --- | --- | --- |
| <img src="assets/preload/images/credits/CitriSnow.png" width="64" /> | **CitriSnow** | 为引擎提供了部分脚本设计方案，并在开发期间一直提供支持 | [哔哩哔哩](https://space.bilibili.com/1951803423) |
| <img src="assets/preload/images/credits/muxue.png" width="64" /> | **MuXue** | 为引擎找到了数不尽的 Bug，为引擎的稳定性做出了重要贡献 | [哔哩哔哩](https://space.bilibili.com/3493084289566971) |
| <img src="assets/preload/images/credits/pico.png" width="64" /> | **Pico**（非 FNF 角色 Pico） | 自 MohongEngine 时期起持续支持本引擎的制作，并提供了若干宝贵的 Bug 反馈 | [哔哩哔哩](https://space.bilibili.com/3546752359598592) |
| <img src="assets/preload/images/credits/xiaolangyeying.jpg" width="64" /> | **小狼夜瑛** | 为引擎发现了若干 Bug，为引擎的稳定运行作出了贡献 | [哔哩哔哩](https://space.bilibili.com/3493115727972533) |
| <img src="assets/preload/images/credits/bfya.png" width="64" /> | **一只可爱的bf呀** | 提供了精神支持和一些想法 | [哔哩哔哩](https://space.bilibili.com/3546642993122123) |
| <img src="assets/preload/images/credits/bonusxk.png" width="64" /> | **Bonus-XK** | [FNF-MeteoricEngine](https://github.com/Bonus-XK/FNF-MeteoricEngine) 的作者，与 SeiunEngine 作者时常交流，并给予了重要的精神支持与鼓励 | [哔哩哔哩](https://space.bilibili.com/3461572190013717) |

### Psych Engine 团队（基础引擎）

| 头像 | 成员 |
| --- | --- |
| <img src="assets/preload/images/credits/shadowmario.png" width="64" /> | **Shadow Mario** |
| <img src="assets/preload/images/credits/river.png" width="64" /> | **RiverOaken** |
| <img src="assets/preload/images/credits/shubs.png" width="64" /> | **Yoshubs** |

### Funkin 本体团队

| 头像 | 成员 | 职责 |
| --- | --- | --- |
| <img src="assets/preload/images/credits/ninjamuffin99.png" width="64" /> | **ninjamuffin99** | 程序 |
| <img src="assets/preload/images/credits/phantomarcade.png" width="64" /> | **PhantomArcade** | 动画 |
| <img src="assets/preload/images/credits/evilsk8r.png" width="64" /> | **Evilsk8r** | 美术 |
| <img src="assets/preload/images/credits/kawaisprite.png" width="64" /> | **KawaiSprite** | 音乐 |

### 特别鸣谢

| 头像 | 成员 |
| --- | --- |
| <img src="assets/preload/images/credits/bb.png" width="64" /> | **bbpanzu** |
| <img src="assets/preload/images/credits/sqirra.png" width="64" /> | **SqirraRNG** |
| <img src="assets/preload/images/credits/kade.png" width="64" /> | **KadeDev** |
| <img src="assets/preload/images/credits/flicky.png" width="64" /> | **iFlicky** |
| <img src="assets/preload/images/credits/proxy.png" width="64" /> | **PolybiusProxy** |
| <img src="assets/preload/images/credits/keoiki.png" width="64" /> | **Keoiki** |
| <img src="assets/preload/images/credits/smokey.png" width="64" /> | **Smokey** |
| <img src="assets/preload/images/credits/nebula.png" width="64" /> | **Nebula the Zorua** |

## 许可证

本项目基于 **Apache License 2.0** 授权 —— 与 Psych Engine 相同的开源许可。完整文本见 [`LICENSE`](LICENSE)，第三方署名见 [`NOTICE`](NOTICE)。
