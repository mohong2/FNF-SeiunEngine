<div align="center">
  <img src="art/iconOG.png" width="280" alt="SeiunEngine logo" />
  <h1>Friday Night Funkin' - SeiunEngine</h1>
  <p>A Friday Night Funkin' engine forked from <b>Psych Engine 0.6.3</b>,<br/>originally built for the <i>Mandela Funkin Night</i> mod — focused on performance, modding and online multiplayer.</p>

  <p>
    <a href="https://github.com/mohong2/FNF-SeiunEngine/releases"><img src="https://img.shields.io/github/v/release/mohong2/FNF-SeiunEngine?include_prereleases&label=Release&logo=github" alt="Release" /></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache--2.0-blue.svg" alt="License: Apache-2.0" /></a>
    <a href="https://haxe.org"><img src="https://img.shields.io/badge/Haxe-4.3.7-EA8220?logo=haxe&logoColor=white" alt="Haxe 4.3.7" /></a>
    <a href="https://github.com/ShadowMario/FNF-PsychEngine"><img src="https://img.shields.io/badge/Base-Psych%20Engine%200.6.3-blue" alt="Base: Psych Engine 0.6.3" /></a>
    <img src="https://img.shields.io/badge/Platform-Windows%20%7C%20macOS%20%7C%20Linux%20%7C%20Android%20%7C%20iOS-brightgreen" alt="Platforms" />
    <a href="https://github.com/mohong2/FNF-SeiunEngine/stargazers"><img src="https://img.shields.io/github/stars/mohong2/FNF-SeiunEngine?style=flat&logo=github" alt="Stars" /></a>
    <a href="https://github.com/mohong2/FNF-SeiunEngine/commits/main"><img src="https://img.shields.io/github/last-commit/mohong2/FNF-SeiunEngine/main?label=Last%20Commit&logo=github" alt="Last Commit" /></a>
  </p>

  <p><b>English</b> | <a href="./ZHREADME.md"><b>简体中文</b></a></p>

  <p><b>Author / 作者：</b><a href="https://github.com/mohong2">mo_hong</a></p>
</div>

---

## Introduction

SeiunEngine (formerly known as MohongEngine) is a Friday Night Funkin' engine developed by mo_hong. It is forked from **Psych Engine 0.6.3** and was originally created for the *Mandela Funkin Night* mod, then evolved into a general-purpose engine with its own feature set: rebuilt replay and online systems, an upgraded scripting stack, and deep performance work for note-heavy charts.

> [!NOTE]
> This project uses AI-assisted tools in its development.

> [!NOTE]
> **A word on update requests.** Pressuring a developer for the content or optimizations you want often gets you not the update you hoped for, but the end of updates altogether. SeiunEngine is a hobby project maintained by one person in their spare time — please keep expectations reasonable. Bug reports and feature suggestions are always welcome in the [issue tracker](https://github.com/mohong2/FNF-SeiunEngine/issues).

For the complete development history, see the [changelog](CHANGELOG_SeiunEngine.md).

## Features

### Performance & Rendering

- Optimized for extremely large note counts — tens of thousands to hundreds of thousands of notes stay playable, thanks to atlas frame caching and chart caching/streaming.
- Rendering and memory micro-optimizations for note-heavy scenes.
- Ships with an **SDL3** backend by default on desktop and Android (remove the `lime-sdl3` define in `Project.xml` to fall back to SDL2).
- Two selectable FPS display styles.

### Scripting & Modding

- Enhanced **HScript** (bundled as 1.3.0) — capable enough to write standalone mods, including custom icons and assets.
- Improved **Lua** compatibility, including early-stage access to (sub)states from scripts.
- Built-in **Psych Engine 0.7.3 compatibility layer** and partial Psych 1.0.4 script compatibility for existing mods.
- Codename Engine-style mod format: `pack.json`, `stateReplacements`/`substateReplacements`, and CNE chart import/export in the editor.

### Charting

- Chart editor supports **Codename Engine (CNE) chart format** import/export.
- Optional chart autosave (off by default) and a unified unsaved-changes confirmation for exit/reload/test-play/preview.

### Gameplay & UI

- Fully rebuilt **replay system** with a replay / score history screen.
- **Botplay HUD** with a live NPS (notes-per-second) readout.
- Redesigned pause menu with subtle 3D effects and a reworked results screen.
- **Trace console** for live script/log debugging.
- Settings backup & restore, plus new "Render" and "Script Optimization" option pages.

### Online Multiplayer

- Built-in online multiplayer (Colyseus-compatible protocol), enabled by default on desktop builds.
- **In-client LAN host** — one player starts a server straight from the online menu and shares a room code.
- Standalone **dedicated server** (Haxe/neko or a native executable) with SQLite persistence.
- Fully **offline builds** without any online code are also available.

### Diagnostics & Localization

- Crash reports carry Haxe source file/line info out of the box (safe mode), with Android symbolization tooling.
- Full **Simplified Chinese / Traditional Chinese / English** localization across the engine and its settings pages.

## Supported Platforms

| Platform | Status |
| --- | --- |
| Windows | Supported (primary target) |
| macOS | Supported |
| Linux | Supported |
| Android | Supported (touch controls included) |
| iOS | Builds, but untested — no guarantee it actually runs |
| HTML5 / Web | Not available |

## Building

> [!IMPORTANT]
> You need **Haxe 4.3.7** (minimum 4.3.0) plus an hxcpp built against the 4.3 API (what `haxelib setup` installs for you). The old 4.2.1 hxcpp fork is rejected with *"Hxcpp is out of date - please update"*. The 4.2.5 baseline is no longer a supported toolchain here: both the game client and the online server are built and type-checked on 4.3.7 (see [`server/README.md`](server/README.md)).

```sh
haxelib setup .haxelib
haxe -cp ./setup -main Main --interp
lime build windows
```

Other targets:

```sh
lime build mac
lime build linux
lime build android
lime build ios -arm64
```

Alternatively, trigger the **Build** workflow manually in GitHub Actions, pick a platform, and download the resulting artifact.

## Dependencies

All library dependencies are managed in [`hmm.json`](hmm.json). Seven of them are the author's own forks:

- flixel
- hxvlc
- extension-androidtools
- linc_luajit-rewriten
- openfl
- lime
- hscript

## Mods

Drop mods into the `mods/` folder. Full documentation lives in [`Modding.md`](Modding.md), and ready-made examples can be found in [`example_mods/`](example_mods).

> [!WARNING]
> SeiunEngine targets Psych Engine 0.6.3 mods, with a 0.7.3 compatibility layer and partial 1.0.4 script compatibility — but **no engine can guarantee that every mod runs**. Please support the original mods through their official channels; the mod creators really did an amazing job.

## Online / Multiplayer

Desktop builds ship with online play enabled by default (main menu → Online); `ONLINE_ALLOWED` is always on in `Project.xml` unless you build with `-D SEIUN_NO_ONLINE`.

| Scenario | Server side | Client side |
| --- | --- | --- |
| **LAN** (most common) | Host runs `server/start.ps1 -Lan`, or uses the in-client **LAN HOST** option | Others: Online → Server List → enter the host's LAN IP (a bare IP auto-appends `:2567`) |
| **Same-PC dual client** (self-test) | Add `--disable-ip-lock` to the server | Both clients connect to `127.0.0.1:2567` |
| **Dedicated / public server** | `server/start.ps1` (or `server/build.ps1`, then run `server/bin/server.n` / `server/bin/SeiunServer.exe`) | Enter the public address (`wss://` goes through 443, no extra port) |

- The client address field only takes the **HTTP port (default 2567)**; the room WebSocket port (default 2568) is derived server-side.
- Persistence uses SQLite; legacy JSON data is auto-imported on first start.
- Offline build: `art/build_x64_offline.bat` (equivalent to `lime build windows -release -D SEIUN_NO_ONLINE`) contains no online code or embedded server.

For full instructions see [`docs/online-usage.md`](docs/online-usage.md); the wire protocol is documented in [`docs/multiplayer-protocol.md`](docs/multiplayer-protocol.md), and the server is described in [`server/README.md`](server/README.md).

## Notes on Third-Party Code

- **Codename Engine** ([CodenameCrew](https://github.com/CodenameCrew)) — this engine's mod system follows Codename Engine's mod *format* (`pack.json`, `stateReplacements`/`substateReplacements`, chart import/export). SeiunEngine is **not** a fork of Codename Engine and contains **no** Codename Engine source code. Their own terms apply to their repository.
- **Funkin-Psych-Online** ([Snirozu](https://github.com/Snirozu/Funkin-Psych-Online)) — the online menu UI, room/protocol model and server-side room semantics were ported from / modelled after Funkin-Psych-Online and its companion Funkin-Online-Server, distributed under the Apache License 2.0. The online code bundled here is SeiunEngine's own Haxe implementation — **no** TypeScript or Node source from those repositories is included. See [`NOTICE`](NOTICE) for the full attribution.

## Credits

### SeiunEngine Team

| Avatar | Member | Contribution | Link |
| --- | --- | --- | --- |
| <img src="assets/preload/images/credits/mohong.png" width="64" /> | **mo_hong** | Lead developer and maintainer — extensive engine modifications, performance optimizations, bug fixes, and Chinese localization | [Bilibili](https://space.bilibili.com/672029688) |
| <img src="assets/preload/images/credits/Li.tmc.png" width="64" /> | **Li.tmc** | Old engine icon (MohongEngine era) | [Bilibili](https://space.bilibili.com/3537117498051255) |
| <img src="assets/preload/images/credits/none.png" width="64" /> | **None** | Android port | [Bilibili](https://space.bilibili.com/392851046) |

### SeiunEngine Acknowledgements

| Avatar | Member | Contribution | Link |
| --- | --- | --- | --- |
| <img src="assets/preload/images/credits/CitriSnow.png" width="64" /> | **CitriSnow** | Provided scripting design solutions and continuous support throughout development | [Bilibili](https://space.bilibili.com/1951803423) |
| <img src="assets/preload/images/credits/muxue.png" width="64" /> | **MuXue** | Found countless bugs, contributed heavily to the engine's stability and quality | [Bilibili](https://space.bilibili.com/3493084289566971) |
| <img src="assets/preload/images/credits/pico.png" width="64" /> | **Pico** (not the FNF character Pico) | Supporting the engine since the MohongEngine era, plus valuable bug feedback | [Bilibili](https://space.bilibili.com/3546752359598592) |
| <img src="assets/preload/images/credits/xiaolangyeying.jpg" width="64" /> | **Wolf Yeying (小狼夜瑛)** | Found and reported several bugs, contributing to the engine's stable operation | [Bilibili](https://space.bilibili.com/3493115727972533) |
| <img src="assets/preload/images/credits/bfya.png" width="64" /> | **一只可爱的bf呀** | Moral support and ideas | [Bilibili](https://space.bilibili.com/3546642993122123) |
| <img src="assets/preload/images/credits/bonusxk.png" width="64" /> | **Bonus-XK** | Developer of [FNF-MeteoricEngine](https://github.com/Bonus-XK/FNF-MeteoricEngine); regular exchange of ideas and continuous encouragement | [Bilibili](https://space.bilibili.com/3461572190013717) |

### Psych Engine Team (Base Engine)

| Avatar | Member |
| --- | --- |
| <img src="assets/preload/images/credits/shadowmario.png" width="64" /> | **Shadow Mario** |
| <img src="assets/preload/images/credits/river.png" width="64" /> | **RiverOaken** |
| <img src="assets/preload/images/credits/shubs.png" width="64" /> | **Yoshubs** |

### Funkin Crew

| Avatar | Member | Role |
| --- | --- | --- |
| <img src="assets/preload/images/credits/ninjamuffin99.png" width="64" /> | **ninjamuffin99** | Programmer |
| <img src="assets/preload/images/credits/phantomarcade.png" width="64" /> | **PhantomArcade** | Animator |
| <img src="assets/preload/images/credits/evilsk8r.png" width="64" /> | **Evilsk8r** | Artist |
| <img src="assets/preload/images/credits/kawaisprite.png" width="64" /> | **KawaiSprite** | Composer |

### Special Thanks

| Avatar | Member |
| --- | --- |
| <img src="assets/preload/images/credits/bb.png" width="64" /> | **bbpanzu** |
| <img src="assets/preload/images/credits/sqirra.png" width="64" /> | **SqirraRNG** |
| <img src="assets/preload/images/credits/kade.png" width="64" /> | **KadeDev** |
| <img src="assets/preload/images/credits/flicky.png" width="64" /> | **iFlicky** |
| <img src="assets/preload/images/credits/proxy.png" width="64" /> | **PolybiusProxy** |
| <img src="assets/preload/images/credits/keoiki.png" width="64" /> | **Keoiki** |
| <img src="assets/preload/images/credits/smokey.png" width="64" /> | **Smokey** |
| <img src="assets/preload/images/credits/nebula.png" width="64" /> | **Nebula the Zorua** |

## License

Licensed under the **Apache License 2.0** — the same open-source license as Psych Engine. See [`LICENSE`](LICENSE) for the full text, and [`NOTICE`](NOTICE) for third-party attributions.
