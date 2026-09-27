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
