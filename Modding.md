# RIGHT NOW THE MODS FOLDER DOES NOT WORK ENTIRELY JUST YET!!!
## THIS IS WORK IN PROGRESS!!!

# QUICK AND DIRTY MOD GUIDE

With the 0.2.6 update, I added a bit of a slightly nicer mod support backend.

It's POLYMOD, which is made by Lars Doucet: https://github.com/larsiusprime/polymod

You may have noticed that there's a new folder in the assets. MODS. Within it you will see 2 files. modList.txt, and a folder called introMod.
modList.txt will load any folder into the game. Put the folder you want to load into a new line in modList.txt, and reboot the game.

Now you may be wondering, what do I put in the folder? Well later down it'll get a bit more complicated, especially as I'll make the IN-GAME mod loader nicer.

# Close Animation Modding (Windows)

The window close animation (Alt+F4 / X button) exposes three hooks so mods can customize
or fully replace it. They only run on Windows.

## HScript (global scripts)

Add these functions to any global HScript:

```haxe
function onCloseAnimStart(style:String, speed:Float) {
	// Return a different style name ("squeeze", "zoom", "drop", "slide", "off"),
	// or {style: ..., duration: ...} to also change the total duration.
	return null; // keep current style
}

function onCloseAnimUpdate(progress:Float, style:String, speed:Float) {
	// progress goes 0 -> 1. Return {x, y, width, height} to take full control
	// of the window position/size every frame.
	return null; // use the built-in animation
}

function onCloseAnimEnd(style:String) {
	// Called right before the window actually closes.
}
```

## Lua (current state scripts)

Lua scripts attached to the current state (e.g. data/states/TitleState.lua,
data/states/MainMenuState.lua) can implement the same functions:

```lua
function onCloseAnimStart(style, speed)
	-- return "off" to close instantly, or {style = "zoom", duration = 0.5}
	return nil
end

function onCloseAnimUpdate(progress, style, speed)
	-- return {x = ..., y = ..., width = ..., height = ...} for full control
	return nil
end

function onCloseAnimEnd(style)
	-- cleanup if needed
end
```

Unknown/custom style names fall back to a center "zoom" animation; pair
`onCloseAnimUpdate` with a custom style name for a fully custom animation.

# SeiunEngine 脚本扩展：Lua require / import 与 hscript↔Lua 桥接
# SeiunEngine Scripting Extensions: Lua require / import and the hscript↔Lua bridge

本章节所有 API 与示例同时提供中文和英文说明。
All APIs and examples in this section come with both Chinese and English notes.

## Lua require()（模块缓存加载 / cached module loading）

所有 Lua 脚本现在都支持标准 `require()`，模块只执行一次并缓存
（`package.loaded` 语义）。搜索顺序：
All Lua scripts now support standard `require()`: modules run once and are
cached (`package.loaded` semantics). Search order:

1. 当前脚本所在目录（相对 require 的文件）
2. 当前模组的 `lua/` 与 `scripts/`
3. 全局模组的 `lua/` 与 `scripts/`
4. `mods/lua/` 与 `mods/scripts/`
5. 内置 `assets/lua/` 与 `assets/scripts/`

模块名按 Lua 惯例把 `.` 转成 `/`，同时支持 `?.lua` 与 `?/init.lua`。
Module names follow Lua conventions: `.` becomes `/`, and both `?.lua` and
`?/init.lua` are supported.

```lua
-- mods/<你的模组>/lua/mathlib.lua
local M = {}
M.double = function(x) return x * 2 end
return M
```

```lua
-- scripts/你的谱面.lua
local mathlib = require("mathlib")   -- 也支持 require("sub.folder.mod")
trace(mathlib.double(21))            -- 42
```

`require` 模块名里包含 `..` 会被拦截（防路径穿越）。找不到模块时给出标准
Lua 报错信息。
Module names containing `..` are blocked (path-traversal guard). A missing
module produces the standard Lua error.

## Lua import()（include 加载 / include-style loading）

`import()` 是 `require` 的兄弟函数，语义是 **include**：加载目标文件并
**立即执行**（每次调用都会重新执行，不缓存），返回文件的返回值，多返回值
也会原样保留。适合把公共片段拆成文件、希望每次执行都生效的场景。
`import()` is the sibling of `require`, with **include** semantics: the target
file is loaded and **run immediately** (re-executed on every call, no caching),
returning the file's return values (multiple returns preserved). Good for
splitting shared snippets into files that should re-run every time.

路径解析规则：

- 以 `.lua` 结尾、绝对路径、或带 `/`、`\` 分隔符的路径 → 按文件路径解析
  （允许相对脚本目录的 `../`，如 `import("../shared/util.lua")`）；
- 纯模块名（如 `lib.utils`）→ 按 require 的规则补 `.lua` / `init.lua`；
- 搜索根与 require 相同（脚本目录 → 模组 lua/scripts → assets）。
- Paths ending in `.lua`, absolute paths, or paths with `/` or `\` are resolved
  as file paths (`../` relative to the script folder is allowed);
- Bare module names (e.g. `lib.utils`) resolve like require, trying
  `.lua` / `init.lua`;
- Search roots match require (script folder → mod lua/scripts → assets).

```lua
-- lib/utils.lua
utils_loaded = (utils_loaded or 0) + 1
return { loadedCount = utils_loaded }

-- 任意脚本里
local u = import("lib/utils.lua")   -- 或 import("lib.utils")
trace(u.loadedCount)                -- 每次 import 都会 +1（不缓存）
```

找不到文件时报错：`import: file not found: <路径>`。
If the file cannot be found: `import: file not found: <path>`.

## hscript 函数管理（覆盖 / 重命名 / 恢复）
## hscript Function Management (override / rename / restore)

hscript 现在可以覆盖 / 重命名 / 恢复引擎预设的函数（`keyJustPressed`、
`getProperty` 等），也支持普通的 `名字 = function(...) {}` 直接赋值覆盖。
hscript can now override / rename / restore engine-preset functions
(`keyJustPressed`, `getProperty`, ...); plain `name = function(...) {}`
assignment overrides also work.

```haxe
// 覆盖（原函数自动备份）
overrideFunction("keyJustPressed", function(name) {
	// 自定义逻辑
	return false;
});

// 覆盖并同步到 Lua（可选）
overrideFunction("getProperty", myWrapper, true);

// 重命名：把 getProperty 复制到 getProp
renameFunction("getProperty", "getProp");

// 恢复原函数
restoreFunction("keyJustPressed");

// 查询
var fn = getFunction("keyJustPressed"); // Dynamic，可调用
var names = functionNames();            // Array<String>
```

## hscript → Lua 桥接（hscript → Lua bridge）

```haxe
// 调用 Lua 全局函数
var result = callLuaFunction("myLuaFunc", [1, 2]);

// 读写 Lua 全局变量
setLuaVariable("myVar", 42);
var v = getLuaVariable("myVar");

// 给 Lua 函数改名
renameLuaFunction("oldName", "newName");

// 直接使用 LuaApi 类
LuaApi.addLuaFunction("myFunc", function(x, y) return x + y;);
LuaApi.overrideLuaFunction("getProperty", function(original, variable, allowMaps) {
	trace('Intercepted: ' + variable);
	return original(variable, allowMaps); // 原函数代理可正常调用
});
LuaApi.restoreLuaFunction("getProperty");
```

`overrideLuaFunction` 的 wrapper 第一个参数是"原函数"代理：引擎内置回调
会直接调用引擎的 Haxe 闭包（不会死循环），Lua 里定义的函数则调用原 Lua
函数。恢复时引擎回调还原为引擎版本，Lua 函数还原为覆盖前的 Lua 全局。

## Lua → hscript 桥接（Lua → hscript bridge）

除了已有的 `runHaxeCode(code)` / `addHaxeLibrary(name, pkg)`，
新增了变量互访：

```lua
setHaxeVar("myVar", 123)          -- 写入共享 hscript 环境
local v = getHaxeVar("myVar")     -- 读取
```

`runHaxeCode` 的返回值现在也支持 Map/表（之前只有 Bool/Int/Float/String/Array）。
`runHaxeCode` return values now also support Map/table (previously only
Bool/Int/Float/String/Array).

## Lua 自定义 state / substate API（Lua custom state / substate API）

### CustomSubstate（脚本事件驱动的子状态 / script-event-driven substate）

```lua
openCustomSubstate("myName", true)     -- 第二个参数 true = 暂停游戏
closeCustomSubstate()
```

打开后当前 PlayState 的脚本会收到事件：
`onCustomSubstateCreate` / `onCustomSubstateCreatePost` /
`onCustomSubstateUpdate(name, elapsed)` / `onCustomSubstateUpdatePost` /
`onCustomSubstateDestroy`。期间可以用 `customSubstate`（对象实例）与
`customSubstateName`（名字）变量访问当前子状态。

把已创建的 Lua 对象（makeLuaSprite / makeLuaText 等）移进 CustomSubstate：

```lua
function onCustomSubstateCreate(name)
	makeLuaText("csTitle", "Hello", 400, 0, 0)
	addLuaText("csTitle")
	insertToCustomSubstate("csTitle", 0)  -- 第二个参数可选，默认追加到末尾
end
```

### ModState / ModSubState（脚本文件驱动的状态 / script-file-driven states）

ModState 会从 `data/states/<name>.lua`（或 `data/states/<name>/` 目录、
`lua/<name>/` 目录）加载脚本，事件与普通 MusicBeatState 相同
（onCreate / onCreatePost / onUpdate / onUpdatePost / onStepHit ...），
额外提供 `data` 变量（switch 时传入的数据）。

```lua
-- 从任意 Lua 脚本切换到自定义 state
switchToModState("MyState", { from = "PlayState" })

-- 打开自定义 substate / 关闭它
openModSubState("MySubState", { someData = 1 })
closeModSubState()
```

示例见 example_mods/data/states/SeiunLuaDemoState.lua 与
SeiunLuaDemoSubState.lua（example_mods 复制为 mods/ 下的模组后，
在 scripts/seiun_lua_demo.lua 里按 F6 可进入演示 state）。

### state 信息与导航（state info & navigation）

```lua
local name = getStateName()       -- 例如 "PlayState"
local sub = getSubStateName()     -- 当前子状态名，没有则为 ""
switchToState("MainMenuState")    -- 按类名切换到内置 state
```

注意：`switchToState` 只实例化无参构造函数的内置 state（states. 包）；
需要传参的状态请用 `runHaxeCode("MusicBeatState.switchState(new MyState(...))")`。
Note: `switchToState` only instantiates built-in states with no-arg
constructors (states. package); for states that need arguments use
`runHaxeCode("MusicBeatState.switchState(new MyState(...))")`.

## example_mods 里的 Lua 示例（Lua examples in example_mods）

- `lua/lib/utils.lua` — require / import 模块示例；
- `scripts/seiun_lua_demo.lua` — PlayState 里演示 require / import、
  CustomSubstate、switchToModState（F5 / F6 触发，不影响玩法）；
- `data/states/SeiunLuaDemoState.lua`、`SeiunLuaDemoSubState.lua` —
  自定义 state / substate 示例。

把 example_mods 整个复制成 `mods/<你的模组名>/` 再启用即可体验。
Copy the whole example_mods folder to `mods/<your-mod-name>/` and enable it to try.

# 分段谱面（一张谱面拆成多个文件）/ Segmented charts (one chart, several files)

一张谱面可以拆成多个文件而仍然作为**一首歌**播放。引擎自己找到这些分片并合并，不需要脚本、
不需要改 Song，也不需要任何拼接步骤。

A chart can be split across several files and still play as one song. The engine finds the parts
itself: no script, no Song patch, no concatenation step.

## 自动识别 / Automatic layout

把分片放在同一首歌的谱面目录下、按序号命名：

    mods/<mod>/data/<song>/<song>-0.json
    mods/<mod>/data/<song>/<song>-1.json
    ...
    mods/<mod>/data/<song>/<song>-28.json

自动识别的条件 / rules for the automatic form:

* 序号从 0 开始、**不能断号**，且至少两个文件。
  Numbered from 0 with **no gap**, and at least two files.
* 歌曲**不能**同时存在 `data/<song>/<song>.json`。那个文件永远优先，所以难度名刚好是数字的
  普通歌曲不会被误合并。
  The plain `data/<song>/<song>.json` must not exist; it always wins, so a normal song whose
  difficulty names happen to be numbers is never merged by accident.
* miragist 这类模组把 `<song>-0..28` 当成难度列表（week 里
  `"difficulties": "0,1,...,28"`），此时点进任意一个难度，播放的都是**全部分片合并后**的整首歌。
  In a mod like miragist, where `<song>-0..28` *is* the difficulty list, selecting any of those
  difficulties plays the whole song merged from every part.

## 显式清单 / Explicit manifest

分片名字不连续、不在同一目录时，用 `data/<song>/<song>.parts.json` 自己列出顺序：

    ["intro", "verse-1", "verse-2"]

或 / or

    {"parts": ["intro", "verse-1", "verse-2"]}

条目可以省略 `.json`，也可以带子目录。清单是显式声明，优先于自动识别，因此它和普通单文件谱面
可以共存。

Entries may omit `.json` and may point into a subdirectory. A manifest is explicit intent, so it
wins over the automatic form and can coexist with an ordinary one-file chart.

## 合并规则 / What the engine does with the parts

* `notes[]` 按分片顺序依次拼接（第 0 片的全部 section，然后第 1 片……）。
  `notes[]` is the concatenation of every part's `notes[]`, in part order.
* 歌曲级字段（`bpm`、`speed`、`stage`、`player1/player2`、`mania`、皮肤等）取自第 0 片。
  Song-level fields come from part 0.
* 各片谱面级 `events` 会合并并去重（完全相同的条目只保留一次），所以"每一片都塞了一份完整
  events"的谱面不会把事件触发 N 次。
  Chart-level `events` from all parts are merged with exact duplicates dropped.
* sectionNotes 不会常驻内存：演奏到哪一段就从**它所属的那个文件**里读出来（复用大谱面的
  `__seiunStream` + `ChartSectionReader` 流式路径）。
  Section notes are never held in memory: each section is read from the file that owns it.
* 每次进歌都会重新读盘，分片文件必须留在磁盘上。

## 玩家的选择 / The player's choice

引擎不会替玩家决定怎么用分段谱面。**Options → Advanced → Multi-file Charts** 有三个档：

* **Auto**（默认）：自动识别 `<song>-0..N.json`，同时认 `<song>.parts.json` 清单。miragist 这
  种把分段当难度列表的模组，点任意难度都会播放合并后的整首。
* **Manifest**：只认作者写的 `<song>.parts.json`，不把数字难度自动当成分段。
* **Off**：完全不合并（连清单也忽略），每个文件仍然是一个独立难度 —— 想单独玩某一段就切成这个。

### 每首歌当场切换 / Per-song override at song select

在 Freeplay 里对当前歌曲按 **M**（安卓是屏幕上的 **D** 键）就能当场切换，循环顺序是：

    跟随全局设置 -> 强制合并 -> 只播当前这段 -> 跟随全局设置

难度文字下面会显示当前状态（`MULTI-FILE: MERGED / SEGMENTS ONLY / MANIFEST ONLY`），带 `*`
表示这是这首歌单独的设置而不是全局设置。这是**本次运行内**的临时选择，重启游戏后回到全局设置。

Press **M** at song select (the on-screen **D** button on Android) to override the mode for the
selected song in place: follow-global → merge → segments only → follow-global. The state shows up
under the difficulty text; a `*` marks a per-song choice. The override lasts for the session.

The engine never decides on its own. **Options → Advanced → Multi-file Charts** offers:

* **Auto** (default): finds `<song>-0..N.json` automatically and also honours `<song>.parts.json`.
  A mod like miragist, whose difficulty list *is* the part list, plays the whole merged song from
  any difficulty.
* **Manifest**: only the author's `<song>.parts.json` is merged; numbered difficulties are left
  alone.
* **Off**: no merging at all, manifests included -- every chart file is its own difficulty again,
  which is how a single segment can still be played on its own.

## 注意事项 / Caveats

* 加载时会扫描全部文件一次：29 个 ~300MB 的分片要几十秒，音符总量是各片之和；这种规模靠 Turbo
  模式才能跑得动。
  The whole set is scanned once at load; 29 parts of ~300 MB take tens of seconds and the note
  count is the sum of all parts. Turbo mode is what keeps such a chart playable.
* 谱面编辑器（ChartingState / NewChartingState）和在线校验仍然只读**单个**文件，所以分段谱面目前
  是"可游玩"格式，不是"可编辑/可上传"格式。
  The chart editor and online verification still read a single file, so a segmented chart is a
  gameplay format today, not an editable/uploadable one.

---

# Psych Engine 1.0.4 模组兼容 / Psych Engine 1.0.4 mod compatibility

引擎本体基于 0.6.3，但内置三引擎兼容层 `backend/CompatEngine.hx`：在
**设置 → Gameplay → 兼容引擎** 里可以选 `Auto / 0.6.3 / 0.7.3 / 1.0.4`。
`Auto` 沿用旧行为 —— 老开关 `compatibility_mode` 开 = 0.7.3，关 = 0.6.3。

本轮把 1.0.4 一侧从"名义兼容"补成"真的能跑"：1.0.4 放宽过的可选参数
（这正是"参数缺省"导致脚本崩溃的根源）、1.0.4 新增的函数、以及 1.0.4 才引入的
宽容 JSON 解析，全部对齐；同时 0.6.3 / 0.7.3 的原生行为保持不变。

This round turns the 1.0.4 side of that switch from a label into an actual
implementation: every optional parameter Psych 1.0.4 relaxed, every function it
added, and the tolerant JSON parsing it introduced are now matched -- while the
native 0.6.3 / 0.7.3 behaviour is untouched.

## 1. Lua 回调参数：缺省不再崩 / Optional parameters no longer crash

Psych 1.0.4 把一批参数从"必填"放宽为"有默认值"，而本引擎仍按 0.6.3 的必填签名
注册。Lua 少传一个 `String` 参数时传进来的是 nil，引擎在 null 上调用方法就是一次
原生访问违例 —— Haxe 的 try/catch 抓不住，游戏直接闪退。本轮补齐的可选参数：

| 回调 | 1.0.4 起可省略的参数 |
|---|---|
| `doTweenX/Y/Angle/Alpha/Zoom/Color`、`noteTweenX/Y/Angle/Alpha/Direction` | `?ease = 'linear'` |
| `mouseClicked/Pressed/Released` | `?button = 'left'` |
| `getMouseX/Y`、`getScreenPositionX/Y` | `?camera = 'game'` |
| `keyJustPressed/Pressed/Released` | `?name = ''` |
| `makeLuaText` | `?text = ''`, `?width = 0`, `?x = 0`, `?y = 0` |
| `makeAnimatedLuaSprite`、`loadFrames` | `?spriteType`（1.0.4 = `'auto'`） |
| `playMusic` / `playSound` | `?volume = 1`；`playSound` 新增 `?loop` |
| `precacheImage` | `?allowGPU = true` |
| `triggerEvent` | `?value1 = ''`, `?value2 = ''` |
| `getObjectOrder` / `setObjectOrder` | `?group` |
| `removeLuaSprite` | `?group` |
| `deleteFile` | `?absolute = false` |
| `startVideo` | `?canSkip`, `?forMidSong`, `?shouldLoop`, `?playOnLoad` |
| `setProperty` / `setPropertyFromClass` / `setPropertyFromGroup` | `?allowInstances`（`instanceArg()` 还原成对象） |
| `getPropertyFromGroup` / `setPropertyFromGroup` | `?allowMaps` |
| `addAnimation` / `addAnimationByPrefix` / `addAnimationByIndices` | `frames` 放宽为 Any（数组或 `'0,1,2'`），帧率放宽为 Float |
| `setGraphicSize` | `x/y` 放宽为 Float |
| `removeFromGroup` | 1.0.4 签名 `(group, ?index, ?tag, ?destroy)`；第三个参数是 Bool 时自动按旧签名处理 |
| `startTween` / `callMethod` / `createInstance` … | 与 1.0.4 一致的可选性 |

版本相关的默认值（`setHealth()`、`setAchievementScore()`、`setObjectCamera()`、
`loadFrames()`）通过 `CompatEngine` 按当前模拟版本取：0.6.3 / 0.7.3 保留各自旧默认，
1.0.4 采用 1.0.4 的默认。

Version-dependent defaults go through `CompatEngine`, so 0.6.3 and 0.7.3 keep
their historical defaults and only the 1.0.4 mode follows 1.0.4.

## 2. 新增的 1.0.4 函数 / Functions that were missing

* `getFileTranslation(key)` 与 `getTranslationPhrase(key, ?defaultPhrase, ?values)` ——
  1.0.4 的翻译 API。本引擎额外读取 1.0.4 的纯文本 `data/<语言>.lang`
  （`key: "value"`），与原生 JSON 语言表合并，`{1}` / `{2}` 占位符照样替换。
* HScript 侧补上 `getModSetting(saveTag, ?modName)`，`keyJustPressed` /
  `keyPressed` / `keyReleased` 支持省略参数并统一小写。

## 3. 宽容 JSON：尾随逗号与注释 / Tolerant JSON

Psych 1.0.4 对模组数据统一使用 `tjson.TJSON.parse`，而 tjson **容忍对象/数组尾随
逗号、`//` 与 `/* */` 注释**；本引擎原先在这些位置用严格的 `haxe.Json.parse`，
于是非常常见的 1.0.4 模组（pack.json 结尾多一个逗号）直接解析失败 —— 实测日志里就是
`加载 pack.json 失败: Invalid char 125 at position 147`。现在这些位置统一走
`backend/JsonUtil.parseTolerant`（tjson 优先、严格解析兜底）：

`pack.json`（ModConfig / ModsMenuState / ModsMenuStateOld / ModSelectSubstate /
Paths 的全局模组扫描）、`stages/*.json`、`data/settings.json`、
`images/gfDanceTitle.json`。

1.0.4 自己用严格解析的地方（Song / Character / Dialogue 等）保持不变，避免引入与
1.0.4 不一致的解析行为。

## 4. 回调实参 / Callback arguments

`eventEarlyTrigger` 现在传完整实参 `(event, value1, value2, strumTime)`；
`doTween*` 的 `onTweenCompleted` 传 `(tag, vars)`。0.6.3 脚本只声明一个参数时，
多出来的实参在 Lua / HScript 里都会被忽略，所以旧脚本不受影响。

## 5. 脚本健壮性 / Script hardening

除了上面的参数补齐，几处最容易把游戏整个带崩的入口加了空值保护：

* `makeLuaSprite()` / `makeAnimatedLuaSprite()` / `makeLuaText()` /
  `makeFlxAnimateSprite()` / `createInstance()` 缺少 tag 时安全跳过；
* `safeColor()`：颜色字符串为 null / 空 / 非法时回落为不透明白色，
  覆盖 `getColorFromHex`、`cameraFlash`、`cameraFade`、`makeGraphic`、
  `setTextColor`、`setTextBorder`、`setHealthBarColors`、`setTimeBarColors`、
  `doTweenColor`；
* `safeInt()`：Float → Int 的安全转换（固定版 flixel 的
  `setGraphicSize` / `addByPrefix` 仍是 Int）；
* `playMusic` / `playSound` 缺少音效名时直接返回。

## 保持不变的 / Deliberately unchanged

* 0.6.3 与 0.7.3 模式下，本引擎原生默认值、UI 结构和回调时序照旧。
* 只让签名"更宽松"（增加可选参数），从不把原本可选的参数改成必填，所以没有
  0.6.3 / 0.7.3 模组会因此被拒。
* 编辑器的 Lua API（`editors/EditorLua.hx`）同样补上了 1.0.4 的可选参数与空值保护，
  但它仍是编辑器自有的 API 面。

## 已知限制 / Known limitations

* `LoadingState` 没有脚本上下文，所以 1.0.4 自定义加载界面用的 `getLoaded` /
  `getLoadMax` / `bar` / `barBack` 全局变量不提供 —— 本引擎的加载界面是另一套实现。
* `Song` / `Character` / `DialogueBoxPsych` 仍用严格 JSON 解析，与 1.0.4 行为一致
  （1.0.4 自己也这么解析），带尾随逗号的这类文件在两边都会失败。
* 1.0.4 的 Haxe 类绑定、stage JSON 的字段语义已可用，但 `ErrorHandledRuntimeShader`
  这类 1.0.4 独有的着色器类没有移植；着色器出错仍按本引擎原有的方式处理。
* **判定名 `marvelous`（超完美）是引擎扩展，Psych 三个版本都没有**（0.6.3 / 0.7.3 / 1.0.4 源码里
  `marvelous` 零命中，`Rating.loadDefault()` 只有 sick/good/bad/shit）。模组按名字映射判定时，
  超完美命中不落任何一档（SonicTheFunkChinese 的 `sonic UI.lua` 就是 `rating == 'sick'/'good'/
  `'bad'/'shit'`），表现为**准确率偏低 + 连击不涨**。1.0.4 兼容模式下引擎现在把**脚本读到的**
  `note.rating` 还原成 1.0.4 会给出的名字（≤25ms 在 1.0.4 就是 `sick`），引擎自己的 HUD / 结算 /
  计分 / hitsound / 在线仍用真实判定。**0.6.3 / 0.7.3 模式按你的要求没有改动**——同样的泄漏在
  那两个模式下也存在，需要的话说一声我一并开。
  这条映射是**独立设置项**：`option.judgementNameCompat`（`ClientPrefs.judgementNameCompat`，默认勾选），
  在游戏设置的判定一栏里可以随时关掉；关掉后脚本直接读到 `marvelous`。
  **开着的时候超完美也不会丢**：引擎内部判定、HUD、结算、计分、hitsound、在线全部照旧使用真实判定，
  并且 `Note` 新增了 `ratingRaw` 字段（与 `rating` 同时写入、`recycle()` 时一起复位），
  脚本可以 `getProperty('notes.members[i].ratingRaw')` 拿到原始判定名（如 `marvelous`），
  也可以读 `PlayState` 的 `marvelouses` 计数。
  注意：HScript 直接读字段，不走这条 Lua 反射通道，所以 HScript 脚本读 `rating` 时仍会看到 `marvelous`（`ratingRaw` 一样可读）。

## 兼容模式差异清单 / Compat-mode difference ledger

为了能回答"063 / 073 到底有没有被改动"，把所有改动分成四类。**第一到第三类在 0.6.3 / 0.7.3
下逐字节不变**；第四类是跨版本的真 bug 修复，旧行为本身就是错的。

### 1) 纯新增 —— 旧模式不可能被影响

* 所有"把必填参数改成可选"的改动（`?ease`、`?button`、`?camera`、`?spriteType`、`?group`、
  `?allowInstances`、`?loop`、`startVideo` 的四个新参数 …）。旧模组本来就会传这些参数。
* 新函数：`getFileTranslation`、`getTranslationPhrase`、`Paths.getAtlas`、
  `Paths.getAsepriteAtlas`、HScript 的 `getModSetting`。
* 只在 Psych 1.0.4 也用 tjson 的位置启用宽容 JSON（pack.json / stage / settings / title）。

### 2) 空值保护 —— 旧代码在这些输入上会崩

合法输入下行为完全一致，只有以前会触发空指针的输入现在安全跳过：

`makeLuaSprite` / `makeAnimatedLuaSprite` / `makeLuaText` / `makeFlxAnimateSprite` /
`createInstance` 缺 tag；`formatVariable(null)`；`cameraFromString(null)`；
`parseInstances` 里的非字符串元素；`removeFromGroup` 的下标越界；
`playMusic` / `playSound` 空名字；`safeColor(null / '')`。

### 3) 按 `CompatEngine` 分支 —— 旧模式走原代码

| 位置 | 0.6.3 | 0.7.3 | 1.0.4 |
|---|---|---|---|
| `setHealth()` 默认值 | 0 | 0 | 1 |
| `setAchievementScore()` 默认值 | 1 | 1 | 0 |
| `setObjectCamera()` 默认值 | 空串 | 空串 | game |
| `loadFrames` / `makeAnimatedLuaSprite` 默认 spriteType | sparrow | sparrow | auto |
| `keyJustPressed/Pressed/Released` 是否 toLowerCase | 否（原样） | 是 | 是 |
| `safeColor` 非法颜色 | 旧宽松解析（zzz→255） | 旧宽松解析 | 严格校验→白 |
| `deleteFile(path, ignoreModFolders, absolute)` | 旧实现（先查 modFolders） | 旧实现 | absolute 生效 |
| `startVideo` 结束时清 inCutscene | 否 | 否 | 是 |
| `getDataFromSave()` 存档里没有该字段 | 返回 null（原版） | 回退 `defaultValue` | 回退 `defaultValue` |
| 脚本读到的判定名（`note.rating`） | 超完美仍读作 `marvelous` | 超完美仍读作 `marvelous` | `marvelous` → `sick`（设置项 `judgementNameCompat`，默认开） |

### 4) 跨版本修复 —— 旧行为本身是 bug

* **`close()` 作用对象**：以前会关掉"最后注册的脚本"（见上文 SonicTheFunkChinese 案例）。
  三种模式都受益；旧行为不可能被正常模组依赖。
* **`getModSetting()` 的 modFolder**：以前取"最后注册实例"的模组，多全局模组并存时会读错。
* **`addAnimation` / `addAnimationByIndices` 的索引**：以前把 Lua 数组硬 cast 成
  `Array<Int>`，而 Lua 数字是 Float —— cpp 上会按错误的元素宽度读取。现在统一走
  `normalizeFrameIndices`。
* **`getObjectOrder` / `setObjectOrder` / `removeFromGroup` 的成员访问**：不再把
  `x.members` 硬 cast 成 `Array<Dynamic>`（同样会读错内存），改用 Dynamic 取值；对合法输入
  返回结果与旧实现一致。
* **进入游戏隐藏引擎光标**：0.6.3/0.7.3/1.0.4 的 PlayState 都不显示它（它们的菜单也不打开），
  是 Seiun 自己的菜单打开了却从不关 —— 属于回归原生观感，不是新增差异。
* **`PauseSubState` 退出时恢复光标可见性**（以前会一直留着）。
* **引擎自带的 side HUD / 键盘-KPS 面板跟随标准 HUD**：1.0.4 模组关 HUD 的写法是把
  `scoreTxt` / `healthBar` / `iconP1` 逐个设成不可见，而这两个 SE 独有的显示挂在 `camOther`
  上，那套写法覆盖不到 —— 于是它们会盖在模组自制界面上（用假歌曲当菜单/设置界面的模组最
  明显）。现在脚本关掉 `scoreTxt` 就等于关掉整块 HUD；用户自己的"隐藏 HUD"设置和在线模式的
  自己关法都不算，两个开关互不影响。
* **`getPropertyFromClass(..., allowMaps = true)` 读 Map**：`getVarInArray` 移植时漏掉了参考实现里
  的 `if(allowMaps && isMap(instance)) return instance.get(variable)`，于是任何
  `getPropertyFromClass('backend.ClientPrefs', 'keyBinds.note_left', true)` 都拿到 null ——
  模组的键位设置页整页显示 `- - -`。0.6.3 / 0.7.3 / 1.0.4 三份参考源码都有这一段，属于还原。
* **带 tag 的音效同时存进变量表 `sound_<tag>`**：1.0.4 的 `playSound` 把音效放进
  `MusicBeatState.getVariables()`，模组用 `getProperty('sound_xxx.time' / '.length' / '.playing')`
  读它；本引擎只存 `modchartSounds`，这些读取全是 nil。现在两个表都写（`modchartSounds` 保持
  不动，引擎自己的 sound API 继续用）。同时 `stopSound()` / `pauseSound()` / `resumeSound()` /
  `getSoundTime()` / `setSoundTime()` 不带 tag 时按 1.0.4 作用于当前背景音乐（以前是空操作）。
* **错误循环保护不再关掉整个脚本**：以前连续报错达到 `scriptErrorLimit`（默认 50）就把脚本
  `closed = true`，Lua 与 HScript 都一样。1.0.4 没有这种机制 —— 一个每帧报错的回调本来就每次
  中断在同一行，但 `onEndSong` / `onEvent` 这些回调必须照常工作。实测 SonicTheFunkChinese 的
  `results.lua` 在第一秒（它自己的 `accuracypercentresult` 要到 `onEndSong` 才有值）被关掉，
  `onEndSong` 永不执行 ⇒ 结算界面永远不出现。现在只是**安静下来**（不再打印/弹窗，每 600 次留
  一条汇总），脚本继续跑。日志上限与性能保护的初衷不变。

诊断日志（`logs/script_log.txt`）不参与游戏逻辑，只写文本；`[cb]` 只记生命周期回调，
不会造成逐帧 IO。


### 5) 列式 unspawnNotes 的脚本读写（2026-10-02）

unspawnNotes 自 4b7faf1 起是列式存储 ChartNotes（每行 get() 出一份一次性 DTO），而脚本桥当时没跟着改：

* getPropertyFromGroup('unspawnNotes', i, ...) 取不到行、setPropertyFromGroup(...) 写不回 —— Psych 的
  custom_notetypes/*.lua 正是靠这两个函数"注册"音符（texture / hitCausesMiss / missHealth / multAlpha /
  ignoreNote / noteSplashHue / noteSplashSat），于是贴图回到原版、每音符逻辑丢失。
* 现在桥认识 ChartNotesData：读走 store.get(i)，写走 store.liveAt(i) —— 第一次写就把这一行钉住，
  之后读取与出谱 setupNoteData 拿到的是同一个对象（旧版 Array<Note> 的别名语义）。
  wasHit / noteDensity 仍以列里的值为准（引擎状态优先）。
* 三种兼容模式一致：旧版 unspawnNotes 本来就是对象数组，受影响的是所有模式。
* 已知限制：HScript 里直接下标访问 PlayState.instance.unspawnNotes[i] 走反射，不经过这条桥，
  仍是列式存储语义；Lua 用 getPropertyFromGroup / setPropertyFromGroup 不受影响。

---

# 脚本诊断日志 / Script diagnostics log

排查"模组脚本没生效"时，画面本身说明不了问题：脚本根本没被加载？加载了但
`onCreate` 报错？回调没被分发到它？引擎现在把答案写进 **`logs/script_log.txt`**
（在 exe 旁边，每次启动重建）：

    [scan]     song=Menu path=menu currentMod=SonicTheFunkChinese globalMods=[...]
    [folder]   ok      ...\mods\SonicTheFunkChinese\data\menu\  lua=2
    [folder]   MISSING ...\mods\data\menu\  lua=0
    [load]     lua ok      ...\mods\SonicTheFunkChinese\data\menu\menu.lua
    [callback] onCreatePost -> ...\mods\SonicTheFunkChinese\data\menu\menu.lua
    [save]     missing-field    name=globalsave  field=littlebuddyX  default=800
    [error]    lua ...\menu.lua :: onCreatePost :: <原始 Lua 错误>
    [guard]    DEAD member dropped  <state>.members[2/8] container=... deadPtr=0x... siblings=[0:..., 1:..., 2:DEAD, ...]
    [gc]       async graphics worker still busy when the post-create forced GC ran (quiesce timed out)

怎么读：

* `[scan]` 说明这一首歌的脚本搜索用的 `currentMod` 与全局模组列表 —— 模组是不是
  "当前模组 / 全局模组"，直接决定 `data/<歌曲>/` 会不会被扫描。
* `[folder]` 逐个列出被扫描的目录与其中加载到的 lua 数量，`MISSING` 表示目录不存在。
* `[load]` 每个成功加载的脚本；失败会写成 `LUA FAILED ...` 并带上 Lua 的原始报错。
* `[callback]` 只记录 `onCreate` / `onCreatePost` 分发给了哪些脚本 —— 用来确认某个
  脚本到底有没有收到创建回调。
* `[error]` 每次脚本运行时报错（脚本 + 回调名 + 原始错误）。
* `[guard]` 组容器成员守卫（source/backend/GroupGuard.hx）在某个 state
  进入 update 之前发现了一个"已经死掉"的成员（指针还在、但它指向的内存头 8 字节已经是 0），
  于是把这个槽位置空并记下来。**这条日志同时意味着"本来会在 FlxTypedGroup.update 里原生崩溃"**：
  日志里的容器类名、下标/总数、坏指针与相邻成员类名就是唯一现场证据，请把它一起发出来。
  正常运行时不会有这一行。
* `[gc]` 强制 GC 前等待异步图形线程静默超时（罕见；只是提示那次收集期间
  还有 worker 在跑，不影响游戏逻辑）。
* `[save]` 只在 `getDataFromSave()` 遇到"存档里没有这个字段"或"存档未初始化"时记录
  （最多 40 条）。1.0.4 模组大量写 `x = getDataFromSave('save', 'field', 默认值)`，如果引擎
  不回退默认值，`x` 就会是 nil，紧接着的 `x + n` / `x < n` 会让整个回调在第 2 行就中断 ——
  表现是"设置界面缺件"或"某个键按了没反应"。日志里出现 `missing-field` 说明模组正在依赖
  这个回退。

单次运行最多 20000 行（`ScriptLog.maxLines`），超过后静默停止，不会因为报错风暴把磁盘
写爆；任何 IO 失败都只是停写，绝不影响游戏。

This is the fast way to answer "did the mod's script even load?" without guessing:
`[scan]` proves which `currentMod` / global-mod list the song used, `[folder]` proves whether
`data/<song>/` was scanned, `[load]` proves whether the file compiled, `[callback]` proves whether
it received `onCreate` / `onCreatePost`, and `[error]` gives the raw Lua error with its callback.


