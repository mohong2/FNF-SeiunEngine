# SeiunEngine

**Author / 作者：mo_hong** — [github.com/mohong2/FNF-SeiunEngine](https://github.com/mohong2/FNF-SeiunEngine)

**你知道吗：** 如果你去催促一个开发者更新你想要的内容和优化，你可能等来的并不是你想要的更新，而是停更。我很想把这一个引擎做好，但我的实力就摆在那儿，请不要过度期待。

A Friday Night Funkin' engine, forked from Psych Engine 0.6.3. Built for the Mandela Funkin Night mod.

**Note:** This project uses AI-assisted tools in its development.

**中文版：[ZHREADME.md](./ZHREADME.md)**

## Supported platforms

- Windows

- macOS
- Linux
- Android
- iOS — builds, but untested. No idea if it actually runs.

No HTML5 build.

## Building

You need Haxe **4.3.7** (minimum 4.3.0), plus the hxcpp that `haxelib setup`
installs for you: Haxe 4.3 requires an hxcpp built against the 4.3 API, and the
old 4.2.1 fork is rejected with "Hxcpp is out of date - please update". The
Haxe 4.2.5 baseline still type-checks this tree, so either compiler works for
the source side.

```sh
haxelib setup .haxelib
haxe -cp ./setup -main Main --interp
lime build windows
```

Other targets: `lime build mac`, `lime build linux`, `lime build android`, `lime build ios -arm64`.

You can also build via the Build workflow on GitHub Actions (manual trigger, pick a platform, download the artifact).

## Dependencies

See `hmm.json`. Seven of them are forks of mine:

- flixel
- hxvlc
- extension-androidtools
- linc_luajit-rewriten
- openfl
- lime
- hscript

### Classpath overrides (engine patches, tracked in `source/`)

The engine patches a few library classes by overriding them on the `source/`
classpath. Apart from the online set described right below, the libraries
themselves are **not** vendored into this repo.

> **Exception — online client dependencies (`source/_online_libs/`)**
>
> The Colyseus online port vendors its third-party dependency sources
> (`io.colyseus`, `org.msgpack`, `tink`, `json2object`, `hxjsonast`,
> `htmlparser`, `httpstatus`, `haxe/net`) because the engine's pinned haxelib set
> does not contain them and no new haxelib entries were added.
>
> They live on their **own classpath root**, declared in `Project.xml` as
> `<classpath name="source/_online_libs" />` — never under `source/`, because
> `source/import.hx` applies to a directory *and all its subdirectories* and would
> leak engine imports into those third-party root packages.
>
> See `source/_online_libs/README.md`.

| override file | patches |
|---|---|
| `source/flixel/system/FlxSound.hx` | flixel (mohong2/flixel) |
| `source/flixel/animation/FlxAnimationController.hx` | flixel (mohong2/flixel) |
| `source/flixel/system/ui/FlxSoundTray.hx` | flixel (mohong2/flixel) |
| `source/flixel/addons/display/FlxRuntimeShader.hx` | engine-added class |
| `source/flixel/addons/ui/FlxInputText.hx` | flixel-ui |
| `source/flixel/addons/ui/FlxUIInputText.hx` | flixel-ui |
| `source/lime/_internal/backend/native/NativeAudioSource.hx` | lime |
| `source/openfl/display/FPS.hx` | openfl |
| `source/openfl/display/OldFPS.hx` | engine-added class |

> TODO: push these patches to their upstream repos (mohong2/flixel, etc.) and
> drop the `source/` overrides once the forks carry them.

## Mods

Drop mods into `mods/`. See `Modding.md`.

## Credits

- ![mo_hong](assets/preload/images/credits/mohong.png) **mo_hong** — Lead developer and maintainer, responsible for extensive engine modifications, performance optimizations, bug fixes, and Chinese localization. Also dove into countless pointers and low-level debugging to keep everything stable and running smoothly lol · [Bilibili](https://space.bilibili.com/672029688)

- ![Li.tmc](assets/preload/images/credits/Li.tmc.png) **Li.tmc** — Old engine icon (MohongEngine) · [Bilibili](https://space.bilibili.com/3537117498051255)

### SeiunEngine Acknowledgements

- ![CitriSnow](assets/preload/images/credits/CitriSnow.png) **CitriSnow** — Provided some scripting design solutions and offered continuous support throughout the engine's development · [Bilibili](https://space.bilibili.com/1951803423)

- ![MuXue](assets/preload/images/credits/muxue.png) **MuXue** — Identified countless bugs, made significant contributions to the engine's stability and quality, and provided continuous support throughout the development process · [Bilibili](https://space.bilibili.com/3493084289566971)

- ![Pico](assets/preload/images/credits/pico.png) **Pico** (not the FNF character Pico) — Has supported the engine's development since the MohongEngine era and provided valuable bug feedback · [Bilibili](https://space.bilibili.com/3546752359598592)

- ![Wolf Yeying](assets/preload/images/credits/xiaolangyeying.jpg) **Wolf Yeying** — Found and reported several bugs, contributing to the engine's stable operation · [Bilibili](https://space.bilibili.com/3493115727972533)

- ![一只可爱的bf呀](assets/preload/images/credits/bfya.png) **一只可爱的bf呀** — Provided moral support and some ideas lol · [Bilibili](https://space.bilibili.com/3546642993122123)

- ![Bonus-XK](assets/preload/images/credits/bonusxk.png) **Bonus-XK** — The developer of another engine ([FNF-MeteoricEngine](https://github.com/Bonus-XK/FNF-MeteoricEngine)), who regularly exchanges ideas with the SeiunEngine author and offered valuable moral support and encouragement throughout development · [Bilibili](https://space.bilibili.com/3461572190013717)

### Psych Engine Team (Base Engine)

- ![Shadow Mario](assets/preload/images/credits/shadowmario.png) **Shadow Mario**
- ![RiverOaken](assets/preload/images/credits/river.png) **RiverOaken**
- ![Yoshubs](assets/preload/images/credits/shubs.png) **Yoshubs**

### Special Thanks

- ![bbpanzu](assets/preload/images/credits/bb.png) **bbpanzu**
- ![shubs](assets/preload/images/credits/shubs.png) **shubs**
- ![SqirraRNG](assets/preload/images/credits/sqirra.png) **SqirraRNG**
- ![KadeDev](assets/preload/images/credits/kade.png) **KadeDev**
- ![iFlicky](assets/preload/images/credits/flicky.png) **iFlicky**
- ![PolybiusProxy](assets/preload/images/credits/proxy.png) **PolybiusProxy**
- ![Keoiki](assets/preload/images/credits/keoiki.png) **Keoiki**
- ![Smokey](assets/preload/images/credits/smokey.png) **Smokey**
- ![Nebula the Zorua](assets/preload/images/credits/nebula.png) **Nebula the Zorua**

### Codename Engine Team ([CodenameCrew](https://github.com/CodenameCrew))

This engine's mod system follows Codename Engine's mod format (`pack.json`, `stateReplacements`/`substateReplacements`, chart import/export).  
SeiunEngine is **not** a fork of Codename Engine and contains **no Codename Engine source code**.  
Please refer to the [Codename Engine repository](https://github.com/CodenameCrew/CodenameEngine) for their own terms.

### Funkin-Psych-Online ([Snirozu](https://github.com/Snirozu/Funkin-Psych-Online))

The online menu UI, the room / protocol model and the server-side room semantics were ported from / modelled after Funkin-Psych-Online and its companion Funkin-Online-Server, distributed under the Apache License, Version 2.0.  
The online slice bundled with this engine is SeiunEngine's own Haxe implementation — **no TypeScript or Node source** from those repositories is included.  
See [NOTICE](NOTICE) for the full attribution.

## License

See LICENSE (Psych Engine's open source license).
