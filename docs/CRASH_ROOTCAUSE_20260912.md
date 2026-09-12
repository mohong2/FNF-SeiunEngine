# SeiunEngine 随机崩溃诊断报告 / Native Crash Investigation

分析对象：`O:\FNF-PsychEngine-0.6.3\FNF-PsychEngine-0.6.3\FNF-SeiunEngine`
崩溃样本：`export/release/windows/bin/crash/` 下 28 份 `native_crash_*.txt`

---

## 0. 结论速览

| # | 结论 | 证据强度 |
|---|------|---------|
| A | **崩溃报告自 2026-09-05 起全部失去符号解析能力**，堆栈里的 `<sprintf>+0x20413` 是导出表兜底符号，不是真实函数。这是"查不出原因"的直接原因。 | 确证 |
| B | **根因：exe 没有 CodeView (RSDS) 调试记录**，因为 `Project.xml` 里的 `HXCPP_DEBUG_LINK` 是注释掉的。dbghelp 无法按 GUID 把 PDB 与 exe 配对。 | 确证 |
| C | **PDB 与 exe 不同步**：`ApplicationMain.pdb` 停留在 2026-08-30 21:56，exe 是 2026-09-12 15:23。旧 PDB 解析新地址得到的是 *另一个函数*（不是同一个函数内的偏移），所以符号完全不可信。 | 确证 |
| D | **Lime 侧两个真实的内存缺陷**（SDL3 迁移引入 / 长期潜伏），其故障特征与 2026-08-28 ~ 08-30 的崩溃完全吻合（`param[1]` = 0x8 / 0x10 / 0x30 / 0xFFFFFFFF）。 | 确证（代码级） |
| E | **2026-09-05 ~ 09-12 的崩溃（8 次）属于另一个故障簇**，落在一段 0x22000 字节的代码窗口内，调用链高度一致（frame #02/#03/#04 的偏移跨构建稳定）。因为 A+B+C，目前无法定位到源码行。 | 需要重新采集 |

---

## 1. 为什么崩溃报告读不出来（P0，必须最先修）

### 1.1 实测证据

```
ApplicationMain.exe   29644800  bytes   2026-09-12 15:23:00
ApplicationMain.pdb  120393728  bytes   2026-08-30 21:56:32   <-- 旧了 13 天
```

反汇编/PE 检查结果：

* exe 的 Debug Directory 只有一条 `coffgrp`，**没有 `RSDS` (CodeView) 记录**。
* 因此 `dbghelp!SymInitialize(GetCurrentProcess(), NULL, TRUE)` 加载 `SeiunEngine.exe`
  时拿不到 PDB 的 GUID/Age，**不会去加载 PDB**，退化为读导出表。
* `SeiunEngine.exe` 只有 179 个导出符号，其中一个恰好是 `sprintf`。
  于是所有落在它后面 132KB 内的地址都被标成 `<sprintf>+0x20413` 这种形式。

### 1.2 为什么 08-30 的报告能解析、09-05 开始不能

`native_crash_20260830_205141.txt` / `_213223.txt` 是有完整符号的（函数名 + `PlayState.cpp:5862` 行号），
因为那两次崩溃时 exe 与 PDB 还是同一对。08-30 22:22 之后每次重新链接，PDB 就再没被更新过
（`-Fd` 只在编译期写 `obj/msvc1964-nc/vc.pdb`，链接器没有 `/DEBUG` 就不会产出/更新最终 PDB）。

### 1.3 修法

`Project.xml:209-212` 现在长这样：

```xml
<!--Emit full debug info (PDB next to the exe) even in release builds, so the
native crash handler in backend/native_crash.inc can symbolize stack frames.
Removable if binary size matters; cost is build time and a large .pdb file.
<haxedef name="HXCPP_DEBUG_LINK" />-->
```

`HXCPP_DEBUG_LINK` 在 hxcpp 里做两件事（`.haxelib/hxcpp/git/toolchain/msvc-toolchain.xml:77-81, 124, 145-150`）：

1. cl.exe 加 `-Zi`；
2. **link.exe 加 `-debug`** → 写入 RSDS 记录 + 生成/更新 PDB。

所以只要取消注释即可，**这不是"额外功能"，这是让现有崩溃处理器能工作的必要条件**：

```xml
<haxedef name="HXCPP_DEBUG_LINK" />
<haxedef name="HXCPP_MAP_FILE" value="ApplicationMain.map" />
```

`HXCPP_MAP_FILE` 额外产出 `.map` 文本符号表（`msvc-toolchain.xml:148`），
即使 PDB 将来再次过期，`.map` 也能离线定位。

> 代价：链接变慢、PDB 约 120MB。相对"崩溃查不出原因"，这个代价是值的。

### 1.4 崩溃报告还应补两样东西

1. **Build 指纹**：在报告头写入 exe 的 PE TimeDateStamp + SizeOfImage + 源文件修改时间，
   这样一眼就能判断"这份日志对应哪个构建、该配哪个 PDB"。
2. **Exe 旁边的 PDB 探测结果**：在 `seiun_dbghelp_init()` 里记录
   `SymGetModuleInfo64(...).SymType`，把 `SymNone`（=PDB 没配上）直接写进报告，
   以后不用猜。

---

## 2. 真实的代码缺陷（Lime / SDL3）

### C1 — `SDL_free(SDL_GetBasePath())`：释放 SDL 内部静态缓存 → use-after-free + 退出时 double free

文件：`.haxelib/lime/git/project/src/backend/sdl3/SDLSystem.cpp:184-191`

```cpp
const char* path = SDL_GetBasePath ();
...
SDL_free ((void*)path);          // <-- 191 行，SDL3 下非法
```

SDL3 改变了所有权：`SDL_GetBasePath` 返回的是**进程级静态缓存**
（`project/lib/sdl3/src/filesystem/SDL_filesystem.c:469-477`），只由
`SDL_QuitFilesystem`（`:511-516`，经 `SDL_Quit`）释放。
SDL2 时代它返回调用者拥有的字符串，迁移时只补了个 `(void*)` 强转。

后果：第二次调用 `System.GetDirectory(APPLICATION)` 会拿到已释放指针 → `from_bytes`/`strlen` 读已释放内存；
进程退出时 `SDL_Quit` 再 free 一次 → double free。

对照：同文件 `:198-205` 的 `SDL_GetPrefPath` **是正确的**（SDL3 里仍是调用者拥有），不要动。

**修法**：删除 191 行。

### C2 — 空窗口句柄导致 native 空指针解引用（**与已观测崩溃特征完全吻合**）

链路：

```
NativeWindow.close()          .haxelib/lime/git/src/lime/_internal/backend/native/NativeWindow.hx:191-213
    → handle = null                                     (:205)   ← 只清 handle，不清 context
NativeApplication.handleRenderEvent()                    (:355-377)
    → if (window.context != null)                       (:368)   ← 只检查 context，没检查 handle
        window.__backend.render()                       (:370)
        window.__backend.contextFlip()                  (:375)
NativeWindow.render()                                    (:407-410)
    → NativeCFFI.lime_window_context_make_current(handle)         ← 无 handle != null 保护
NativeWindow.contextFlip()                               (:215-229)
    → NativeCFFI.lime_window_context_flip(handle)                 ← 无 handle != null 保护
ExternalInterface.cpp:3160 / 3132
    → ((Window*)val_data(window))->ContextMakeCurrent()           ← this == NULL
```

`render()` 和 `contextFlip()` 是 `NativeWindow.hx` 里**唯二**没有 `handle != null` 保护的方法
（对比 `focus()` `:233-241` 有保护）。

**与崩溃样本的对应关系**（这是最有说服力的部分）：

| 崩溃文件 | `param[1]`（出错访问地址） | 解释 |
|---|---|---|
| `native_crash_20260829_122842.txt` | `0x10` | null-this 调用 `ContextMakeCurrent()`，成员访问在 +0x10 |
| `native_crash_20260830_134740.txt` | `0xFFFFFFFFFFFFFFFF` | 同一路径，`SDL_GL_*` 解引用 |
| `native_crash_20260829_165734.txt` | `0x30`（且 param[0]=1，**写**） | null-this 写成员 |
| `20260830_205141 / 213223 / 20260829_235802` | `0x8` | null-this 访问 +0x8 |

这些 `0x8 / 0x10 / 0x30` 正是"结构体成员偏移"的典型值 —— 即 `this == nullptr`。
而且可复现性极高（08-30 19:35/19:36/19:37/19:47/20:00 连续 5 次，寄存器状态几乎一致），
说明这是一个**确定性路径**，不是随机内存损坏。

**为什么和"切后台再切回前台"有关**：SDL3 只有在**最后一个可见顶层窗口**收到
`WINDOW_CLOSE_REQUESTED` 时才发 `SDL_EVENT_QUIT`（`sdl3/src/events/SDL_windowevents.c:250-264`），
而 `SDL_DestroyWindow` 只发 `WINDOW_DESTROYED`（`src/video/SDL_video.c:4143`）。
所以 `SDLApplication::active` 仍为 true，UPDATE/RENDER 循环继续派发事件 ——
窗口已经销毁、`handle` 已经是 null，渲染却还在跑。
本引擎确实会主动关窗：`source/Main.hx:584-585`、`:618-619`、`:713-714`（`allowWindowClose = true; window.close();` 之后没有 `Sys.exit`）。

**修法**（2 行）：

```haxe
public function render():Void
{
    if (handle == null) return;      // 新增
    #if (!macro && lime_cffi)
    ...
}

public function contextFlip():Void
{
    if (handle == null) return;      // 新增
    #if (!macro && lime_cffi)
    ...
}
```

更稳妥的做法是在 `NativeWindow.close()` 里同时把 `context` 置空，
但上面两行是最小且充分的止血。

### C3 — 销毁顺序 vs SDL3 卸载 GL 库（需要运行时确认）

`sdl3/SDLWindow.cpp:283-302`：析构时**先销毁 window，再销毁 GL context**。
SDL3 的 `SDL_DestroyWindow` 现在会调用 `SDL_GL_UnloadLibrary()`
（`SDL_video.c:4199-4201` → `SDL_UnloadObject(opengl32)`，`src/video/windows/SDL_windowsopengl.c:228-236`）。
而 Lime 的 GL 入口点是**每进程只解析一次**（`project/src/graphics/opengl/OpenGLBindings.cpp:5294-5300`
的 `static initialized`），于是任何"销毁窗口 → 重建窗口"之后，GL 调用会跳进已卸载的模块。

如果用户遇到过"窗口重建后随机崩溃"，这条就是原因。**需要一次运行时复现来确认**。

**修法**：反转析构顺序；`Close()` 时清空 `context`/`sdlRenderer`/`sdlTexture`；每次创建 context 重新解析 GL 绑定。

---

## 2b. 真实的代码缺陷（Flixel / 游戏层）

> 全部落在 exe 内 —— 而**所有近代崩溃报告的 faulting module 都是 `SeiunEngine.exe`**，
> 不是显卡驱动 / opengl32 / lime.ndll。这条证据把范围直接锁定在本节。

### F1 — 重建 strum 组后越界取 `members[idx]` → hxcpp 返回 null → AV（**最可疑**）

`source/states/PlayState.hx:9408-9410`

```haxe
var strumIdx:Int = Std.int(Math.abs(note.noteData));
if (strumIdx >= playerStrums.members.length) strumIdx %= playerStrums.members.length;
var strum:StrumNote = playerStrums.members[strumIdx];   // 9410
```

hxcpp release 构建下 `Array` 越界读返回 `null`（`.haxelib/hxcpp/git/include/Array.h:541-545`），
而本项目关掉了指针检查，于是 `strum.x` 直接空指针解引用 → `0xC0000005`。

这一类**已经在本项目崩过两次并被手工修补**（`PlayState.hx:9402-9413` 的注释就是证据），
但仍有 9 处未加保护：`EditorPlayState.hx:395-401,1091`、`ChartingState.hx:3837,3841`、
`NotesSubState.hx:244,383-384,412-413`、`ModsMenuState.hx:305`、`StoryMenuState.hx:576,793`、
`PauseSubState.hx:987`。触发路径：`PlayState.hx:3953 changeMania` → `:3978-3980` 清空 strum →
`:3991-3992` 重建。

「随机、不知道什么时候崩」和这个模式完全一致：只有在 strum 组正好处于空/重建态时才会命中。

### F2 — `strumIdx %= members.length` 在空组时是除零

`PlayState.hx:9409`（同 `:9393`）：`playerStrums.members.length == 0` 时 `%` 会抛
`0xC0000094 INTEGER_DIVIDE_BY_ZERO`。修法是先判长度：

```haxe
if (playerStrums.members.length == 0) return;
var strumIdx:Int = Std.int(Math.abs(note.noteData)) % playerStrums.members.length;
```

### F3 — 相机特效回调里销毁相机，随后无保护解引用 `flashSprite`

`.haxelib/flixel/git/flixel/FlxCamera.hx:1059-1064`

```haxe
updateFlash(elapsed);      // 1059 —— 完成回调可能执行 FlxG.cameras.remove(cam, true)
updateFade(elapsed);       // 1060
flashSprite.filters = ...; // 1062 —— destroy() 已把 flashSprite 置空 → AV
```

触发序列：`cam.fade(..., OnComplete, ...)` → `camera.update()` → OnComplete →
`CameraFrontEnd.hx:107-108` 移除并销毁相机 → `:1062` 解引用空 `flashSprite`。
本引擎的 `PsychCamera` / 转场代码大量使用相机特效，这条路径很可能被踩到。

### F4 — 跨 GL context 复用 Shader（相对上游的回归）

openfl 侧 `OpenGLRenderer.hx:66-68` 把默认 shader 改成 `static`，`:581-585` 等只在
`__context == null` 时重新初始化；而 `FlxGraphic.hx:347,430-432` 给每个 graphic 只配一个 shader。
窗口/context 重建后（`NativeApplication.hx:379-405` 的 RENDER_CONTEXT_LOST/RESTORED）
会继续用旧的 GL program 与旧的 attribute/uniform 索引。

*注意*：这条与 C3（SDL3 卸载 opengl32）是**同一类问题的两个面** ——
都指向"窗口/context 生命周期变化后，缓存的 GL 对象没有失效"。

### F5 — Lua 模组可以让 GPU 越界读顶点属性

`FunkinLua.hx:651-660 setShaderFloatArray` → `FlxRuntimeShader.hx:226` →
`prop.value = value`，长度不校验；`ShaderParameter.hx:622-623` 按 GLSL 声明类型推导取数，
不裁剪数组。对 `alpha`/`colorMultiplier`/`colorOffset`（`FlxRuntimeShader.hx:55-70`）
传入长度 ∉ {0, unit} 的数组会让驱动从按 `value.length` 分配的 VBO 里取
`4*length*numVertices` 字节 → `glDrawElements` 里 GPU 越界读。
`setFloat`（非数组）是安全的。这条是 mod 可达的，不是引擎自身的随机崩，但应该加长度校验。

### 关于被怀疑的顶点色批处理提交

`.haxelib/flixel/git` 的 `04c3e4c`（vertex-color batching）经审计是**四边形对齐且正确的**，
但建立在 openfl 一条没有余量的隐式约定上（`FlxDrawQuadsItem.hx:78-79,127-138` 的数组长度
恰好等于顶点数）。不要在没理解 `ShaderParameter.hx:622-623` 的情况下改动它。

---

## 3. 关于两个怀疑方向的核查结论

### 3.1 SDL3 迁移副作用 —— **成立，但不是"切后台"这条路径**

- 逐项核对了 SDL3 事件/联合体改名、`SDL_bool` 移除、`SDL_GL_MakeCurrent` 返回值语义翻转、
  `SDL_free` 所有权、`SDL_GetDisplays`/`SDL_GetFullscreenDisplayModes`/`SDL_GetJoysticks` 所有权、
  `PumpEvents` 哨兵值、主线程约束 —— 除 C1 之外**没有发现第二处所有权/语义迁移错误**。
- 聚焦到 focus gain/loss 本身：**没有找到一条"焦点事件 → 访问已释放内存"的路径**。
  SDL3 在窗口最小化时不发 RESIZE（`SDL_windowsevents.c:1668-1671`），
  `SDL_GL_SwapWindow` 对无效窗口做了完整校验（`SDL_video.c:5177-5190`），
  最小化渲染只会退化为错误而不是崩溃。
- 所以：**C2 / C3 才是真正的崩溃源，"切后台"只是触发时机之一**（用户主动关窗、退出动画等同样会走到）。

另外两条已确认但优先级较低的问题：

- `NativeApplication.hx:544-548, 560-563`：MINIMIZE/RESTORE 分支把 `__fullscreen = false`
  但没有调用 `SDL_SetWindowFullscreen` → 全屏状态在 Haxe 侧与实际不同步
  （`source/Main.hx:590` 依赖这个值）。
- `inBackground` 在桌面端是**死状态**：SDL3 只在 Android 上发出
  WILL/DID_ENTER_FOREGROUND/BACKGROUND（`SDL_video.c:5785-5816` 唯一调用方是
  `src/video/android/SDL_androidevents.c:178`），所以切到后台**不会**降帧/暂停渲染。

### 3.2 「更新与渲染分离」的 bug —— **这条线索大概率是错的**

`.haxelib/flixel/git/flixel/FlxGame.hx:104-109, 960-985` 确实有一套 `drawWrapper` 钩子，
但：

- `source/backend/RenderThread.hx` 明确写着 **"多线程渲染已移除，因为 OpenFL 的 OpenGL 渲染器不支持跨线程调用"**，
  `enabled = false`，`submitRender()` 直接同步调用 `drawFn()`，`start()` 恒返回 `false`。
- `FlxG.game.drawWrapper` 在 `source/Main.hx:269` 和 `source/ClientPrefs.hx:866` 都被置为 `null`。

也就是说**渲染仍然在单线程、单线程主循环里**，update/render 分离并未生效。
用户观察到的"随机崩"，不是这条路径造成的。

真正残留的风险是这个钩子的**存在**：任何 mod / 未来的开关只要给 `drawWrapper` 赋一个真异步实现，
就会立刻踩进 OpenFL 渲染器的非线程安全区（顶点缓冲、纹理绑定、GL 状态全在主线程之外被改）。
建议要么删掉 `drawWrapper`，要么给它加一道"仅允许同线程"的断言。

---

## 4. 崩溃样本分类

| 时间 | 特征 | 判定 |
|---|---|---|
| 08-27 23:06 / 23:09 / 23:16、08-28 00:06 | 4 次寄存器状态**完全相同**，`param[1]=0` | 同一确定性 bug（待定位） |
| 08-28 13:01 ×2 | `RIP=0x0` 且 `param[0]=8`（execute fault）→ 跳转到空函数指针 | 虚表/回调指针被清空 |
| 08-28 19:05 起 ~ 08-30 | `param[1] = 0x8 / 0x10 / 0x30 / -1`（成员偏移量本身就是出错地址） | **C2 空窗口句柄**（唯一一次 faulting module 是 `lime.ndll` 的 `20260829_235802` 也属此列） |
| 08-30 20:51、21:32 | **有完整符号**：`generateSong` 内 `safeSort` 的比较闭包，`PlayState.cpp:5862/6290` | 独立的歌曲生成排序崩溃（谱面/模组数据） |
| 09-05 ~ 09-12（8 次） | 全部落在 `0x131F020..0x1340289`；frame #02/#03/#04 偏移跨构建稳定；相邻两次 RVA 只差 0x79 字节（`0x1340210` vs `0x1340289`） | **新故障簇，需重新采集符号后定位** |

> ⚠️ 一个重要前提：**09-12 15:23 的重新链接之后，磁盘上的 exe 与当时崩溃的 exe 已经不是同一个构建**，
> 而 PDB 还停在 08-30。所以现在**无法**把这些偏移可靠地映射回源码 —— 强行映射会得到
> `FlxGamepad_HSX_obj::__Field + 0x969`、`<sprintf>+0x20429` 这种明显不合理的答案。
> 这正是第 1 节必须优先修复的原因。

09-05 那一簇之所以查不出来，就是第 1 节的符号问题。

---

## 5. 建议的修复顺序

| 顺序 | 动作 | 理由 |
|---|---|---|
| **1** | `Project.xml` 打开 `HXCPP_DEBUG_LINK` + `HXCPP_MAP_FILE`，重新构建 | P0：不修这个，之后所有崩溃日志都是废的 |
| **2** | C2：`NativeWindow.render/contextFlip` 各加一行 `if (handle == null) return;` | P0：已确证，与 08-28~08-30 崩溃特征精确吻合 |
| **3** | C1：删掉 `SDLSystem.cpp:191` 的 `SDL_free` | P0：use-after-free + 退出时 double free |
| **4** | F1/F2：`PlayState` 及另外 9 处 `members[idx]` 加长度判断 | P0：已在本项目崩过两次的同类 bug |
| **5** | F3：`FlxCamera.update()` 里先判 `flashSprite != null` | P1：相机特效 + 销毁的确定序列 |
| **6** | 崩溃报告补 build 指纹 + `SymType` 输出 | P1：让"日志↔PDB"能对号入座 |
| **7** | 复现并确认 C3（窗口重建 + GL 绑定）；同步修 F4（shader 随 context 重建） | P1：同一类生命周期失效 |
| **8** | F5：`setFloatArray` 加长度校验 | P2：mod 可达的 GPU 越界读 |
| **9** | MINIMIZE/RESTORE 全屏状态不同步；决定 `drawWrapper` 去留 | P2 |
| **10** | 用修好符号的下一份崩溃报告定位 09-05 那一簇 | 需要 1~3 先落地 |

---

## 6. 本次已落地的改动与构建验证

### 6.1 已应用的修复

| 文件 | 改动 |
|---|---|
| `Project.xml:209-222` | 新增 `HXCPP_MAP_FILE=ApplicationMain.map`；`HXCPP_DEBUG_LINK` **保持关闭**（正式构建不带调试信息） |
| `.haxelib/lime/git/project/src/backend/sdl3/SDLSystem.cpp:184-196` | 删除 `SDL_free((void*)SDL_GetBasePath())`，并写明 SDL3 的所有权语义 |
| `.haxelib/lime/git/src/lime/_internal/backend/native/NativeWindow.hx:215-222` | `contextFlip()` 增加 `if (handle == null) return;` |
| `.haxelib/lime/git/src/lime/_internal/backend/native/NativeWindow.hx:407-418` | `render()` 增加 `if (handle == null) return;` |
| `.haxelib/flixel/git/flixel/FlxCamera.hx:1058-1074` | `updateFlash/updateFade` 之后增加 `flashSprite == null` 检查 |
| `source/states/PlayState.hx:9391-9396` | `laneTotal <= 0` 时钳到 1，消除 `% 0` |
| `source/states/PlayState.hx:9408-9414` | 先取 `strumCount`，为 0 直接 return，再取模 |
| `source/backend/native_crash.inc` | 新增 `seiun_set_build_info()`、`seiun_module_build_stamp()`、`seiun_append_build_identity()`；SEH 与 SIGABRT 两条路径都写入构建指纹；dbghelp 改为动态取 `SymGetModuleInfo64` |
| `source/backend/NativeCrash.hx` | 新增 `setBuildInfo()`（exe/pdb 尺寸+mtime + exe 头尾各 64KB 的 FNV-1a 哈希） |
| `source/Main.hx:193-196` | 启动时调用 `NativeCrash.setBuildInfo()` |
| `tools/mapresolve.py` | 新增：用 `.map` 把 `Fault offset` 解析成真实函数名 |
| `tools/symbolize-crash.ps1` | 新增：扫 `crash/` 目录并批量解析的一键脚本 |
| `.github/actions/build-desktop/action.yml` | 新增「Collect crash symbols」步骤，收集 `.map` + 生成使用说明 |
| `.github/workflows/build-{windows,linux,macos}.yml` | 新增独立的 `*-symbols` artifact（保留 90 天） |
| `.github/workflows/build-all.yml`、`release.yml` | 符号包作为 `crash-symbols/*.zip` 单独挂到 Release，不进游戏压缩包 |

### 6.2 正式构建验证（`haxelib run lime build windows`，`HXCPP_DEBUG_LINK` 关闭）

```
ApplicationMain.exe   29649408   (= 原始正式构建体积，1 字节不差)
bin/SeiunEngine.exe   29649408   (与 obj 下 hash 一致)
ApplicationMain.map   44442017   (压缩后约 4.7 MB)
```

对比上一轮为验证符号链路而临时打开的 `HXCPP_DEBUG_LINK`：

| 配置 | exe | PDB | MAP |
|---|---|---|---|
| 原始正式构建 | 29,644,800 | 未产出 | 无 |
| `HXCPP_DEBUG_LINK` 打开 | 47,115,264 | 120 MB | 118 MB |
| **现在（正式构建 + MAP）** | **29,649,408** | 不再产出 | **44 MB** |

新 exe 中已确认包含构建指纹与符号诊断代码：

```
FOUND  SymNone - REPORT UNRELIABLE, PDB not matched
FOUND  Main module stamp: TimeDateStamp
FOUND  Matching PDB:
```

`mapresolve.py` 对当前构建的解析精度实测（用 `.map` 里已知的精确定位反过来验证）：

```
flixel::FlxGame_obj::switchState                     rva 0x1094EF0   +0x0  ✅
states::PlayState_obj::generateSong                  rva 0x6542E0    +0x0  ✅
backend::GfxLru_obj::park                            rva 0xC0FD80    +0x0  ✅
lime::...::NativeWindow_obj::render                  rva 0x44D650    +0x0  ✅
```

⚠️ **release 构建的布局与 debug 构建不同**（`NativeWindow_obj::render` 从 `0x7633C0`
变成 `0x44D650`），所以每个构建必须配自己的 `.map`——文件里已带 TimeDateStamp，
报告头部也有 `Main module stamp`，可以对号入座。

### 6.3 正式构建下怎么查崩溃（重要）

正式构建**没有** `/DEBUG`，exe 里没有 RSDS 记录，dbghelp 无法配对 PDB。因此：

- 崩溃报告里内联的 `<函数名>+0x...` 是**导出表兜底**，基本是错的。报告新增的
  `Symbols:` 行会明确写 `SymType=0 (SymNone - REPORT UNRELIABLE, PDB not matched)`。
- 能用的是 **`Fault offset`**，配合同构建的 `.map`：

```powershell
# 扫整个 crash 目录（会先列出每份报告的构建指纹，便于确认是否同一构建）
powershell -File tools\symbolize-crash.ps1

# 或直接给偏移
powershell -File tools\symbolize-crash.ps1 -Offset 0x1340289,0x133429A
```

- 如果某个偏移解析出的函数偏移量高达几十万字节（例如 `+0x5A8470`），说明该地址
  没落在 map 收录的函数里，结果不可信——release 构建的 map 不保证收录全部函数。

想要"报告里直接有函数名+行号"，只能出一个临时带 `HXCPP_DEBUG_LINK` 的调试构建
（exe 会到 47 MB）。

### 6.4 另外两个必须知道的坑

1. **不要为了"报告里有函数名"而打开 `HXCPP_DEBUG_LINK`**：MSVC 会把调试目录数据写进
   映像，Windows exe 从 29.6 MB 涨到 47.1 MB。正式构建请保持关闭，用 `.map` 离线解析。
   真要 `file:line` 级别的报告时，另出一个临时调试构建即可。

2. **踩到一个 hxcpp 增量构建的坑**：修改 `source/backend/native_crash.inc` 之后，
   构建**不会**重新编译 `src/backend/NativeCrash.cpp`（我用 `#error` 探针验证过：
   探针没触发，链接却报旧对象的符号错误）。原因是 hxcpp 的依赖时间戳只看生成的
   `.cpp`，而 `@:cppInclude` 的 `.inc` 不在依赖表里。
   **以后再改 `native_crash.inc`，必须手动删掉**
   `export/release/windows/obj/obj/msvc1964-<ver>-nc/*_NativeCrash.obj` 再构建，
   否则改动不会生效。本次已经这样处理过。

3. **子库是独立的 git 仓库**：`.haxelib/lime/git` 和 `.haxelib/flixel/git` 各自有自己的
   `.git`，这两处的改动属于"打补丁"，升级 haxelib 时会被覆盖，建议单独记录或上游化。
   CI 里 `setup` 会重新拉取这两个库，**所以这两处补丁必须同时上游化到
   `mohong2/lime` 与 `mohong2/flixel`**，否则 CI 构建出来的包又会带上 C1/C2/F3 缺陷。

4. **符号包不要放进游戏压缩包**：`.map` 有 44 MB（压缩后 4.7 MB），只有排查 bug 的人需要。
   CI 已经把它拆成独立的 `*-symbols.zip` 挂在 Release 的 `crash-symbols/` 下。

---

## 附录 A：保留的排查工具

* `tools/mapresolve.py` — 读 `.map`，把 `Fault offset` 解析成真实函数名；
  支持 `--crash-dir` 批量、`find <子串>` 反查
* `tools/symbolize-crash.ps1` — 一键封装：自动找 `.map`、先打印每份报告的构建指纹、
  再批量解析

正式构建的排查只需要这两个。排查过程中用到的临时工具（基于 PDB 的符号解析器、
dumpbin 反汇编提取脚本等）已在本轮清理中删除，需要时可用相同的思路重建：
核心是 `dbghelp!SymLoadModuleEx` 可以直接吃 PDB 文件（配合 PE 的 `SizeOfImage`），
不必依赖 exe 里的 RSDS 记录。

## 附录 B：子审计要点（原文已并入本节）

调查期间对两个 fork 做过逐文件的独立审计，原文已删除，结论如下。

### B.1 Lime / SDL3 迁移审计

**已确证的缺陷**（均已在本轮修复）：

| 编号 | 位置 | 问题 |
|---|---|---|
| C1 | `project/src/backend/sdl3/SDLSystem.cpp:191` | `SDL_free(SDL_GetBasePath())` → use-after-free + 退出时 double free |
| C2 | `src/lime/_internal/backend/native/NativeWindow.hx:215,407` | `contextFlip()` / `render()` 缺 `handle != null` 保护 → native 空指针 |
| C3 | `sdl3/SDLWindow.cpp:283-302` | 析构顺序为「先销毁 window 再销毁 GL context」，而 SDL3 的 `SDL_DestroyWindow` 会 `SDL_GL_UnloadLibrary()`；Lime 的 GL 入口点每进程只解析一次 → 窗口重建后调用进已卸载模块（**待运行时确认**） |
| C4 | `NativeApplication.hx:544-548,560-563` | MINIMIZE/RESTORE 把 `__fullscreen` 置 false 却没调 `SDL_SetWindowFullscreen` → 全屏状态不同步 |
| C5 | `NativeApplication.hx` / `SDLApplication.cpp:176,191` | `inBackground` 在桌面端是死状态：SDL3 只在 Android 发 WILL/DID_ENTER_* → 切后台不降帧 |

**逐项核对后确认无问题**：SDL3 事件/联合体改名已彻底完成、无残留 `SDL_bool`/`SDL_TRUE`/`SDL_FALSE`；
嵌套 `SDL_WINDOWEVENT` 拆分正确；`SDL_GL_MakeCurrent` 返回值语义翻转已处理；
drop-event 的 `SDL_free` 移除正确；`SDL_GetPrefPath` 的 free 正确；
`SDL_GetJoysticks` / `SDL_GetDisplays` / `SDL_GetFullscreenDisplayModes` 的所有权处理正确；
HWND 改用 `SDL_GetPointerProperty` 且有 NULL 保护；
`PumpEvents` 哨兵值不会被 `WaitEvent` 偷走；无跨线程 SDL 调用。

**关于「切后台」这个症状**：焦点增益/丢失路径上**没有**任何解引用已释放内存的代码。
SDL3 在窗口最小化时不发 RESIZE，`SDL_GL_SwapWindow` 对无效窗口做了完整校验，
最小化渲染只会退化为错误而不是崩溃。真正的崩溃源是 C2/C3，「切后台」只是触发时机之一。

### B.2 Flixel / openfl / lime 三层 fork 审计

先说结论：**「更新与渲染分离」不是崩溃原因。**
`drawWrapper` 是死代码（`RenderThread.hx:26` 同步执行 draw、`:29` 异步恒返回 false，
且 `Main.hx:268-269` 与 `ClientPrefs.hx:865-866` 都把 wrapper 置空）；
`separateUpdateDraw` 在绘制侧等价（`FlxGame.hx:663-675` 两个分支都调 `draw()`），
唯一实际差异是 `_drawAccumulator` 与 `_maxAccumulation`。
唯一真正的 update/draw 重排在原生层：lime 把 `SDLApplication::Update()` 改写成了
带主线程忙等的墙钟循环（`sdl3/SDLApplication.cpp:890-1005`）。

**风险清单**（按严重度）：

| 级别 | 问题 |
|---|---|
| 高 | 重建 strum 组后无保护取 `group.members[idx]` → hxcpp release 越界返回 null → AV（**已修**，同类仍有 9 处未保护：`EditorPlayState.hx:395-401,1091`、`ChartingState.hx:3837,3841`、`NotesSubState.hx:244,383-384,412-413`、`ModsMenuState.hx:305`、`StoryMenuState.hx:576,793`、`PauseSubState.hx:987`） |
| 高 | 相机特效完成回调里销毁相机后无保护解引用 `flashSprite`（**已修**） |
| 高 | 跨 GL context 复用 Shader：openfl `OpenGLRenderer.hx:66-68` 把默认 shader 改成 static，`:581-585` 仅在 `__context == null` 时重建；`FlxGraphic.hx:430-432` 每个 graphic 只有一个 shader → context 重建后用旧 program 与旧 attribute/uniform 索引 |
| 中 | `SDLApplication.cpp:983-992` 忙等且不泵事件；`:974-976`/`:999-1001` 消费并丢弃 `SDL_EVENT_USER` |
| 中 | `FlxText` 在 `draw()` 内部重建位图并销毁旧 `FlxGraphic`（`FlxText.hx:781-803,842-847`）—— 没成为 UAF 只是因为 `FlxDrawQuadsItem.hx:170-171` 在 `destroy()` 后提前退出 |
| 中 | Lua 可通过 `setShaderFloatArray` 给 `alpha`/`colorMultiplier`/`colorOffset` 传长度不合法的数组，导致 `glDrawElements` 里 GPU 越界读属性（`FunkinLua.hx:651-660` → `FlxRuntimeShader.hx:226` → `ShaderParameter.hx:622-623`），建议加长度校验 |
| 低 | `FlxFrame.paint()` 的 `-offset` 平移建立在一个不成立的前提上（`checkInputBitmap` 只按 `sourceSize` 定尺寸），trimmed frame 有写出目标位图的风险，值得加断言 |
| 低 | `insert(-1, obj)` 静默丢弃对象；`virtualPad`/`androidControls` 双重 destroy；`FlxBasic.get_camera()` 可能返回 null |

**逐项核对后确认无问题**：update/draw 调用顺序；`FlxDrawQuadsItem` 的 quad/stride 记账与池重置；
`FlxGraphicsShader` 片元数学与上游代数等价；openfl `__clearShader` 的五字段重置等价于 `__clearUseArray`；
**GL 缓冲全部在界内**（quad VBO、index buffer、paramData 的算术已逐项验算）；
共享 shader 的跨批次纹理状态**不会泄漏**（每批次纹理来自 `Shader.hx:873-886` 的快照）；
null/已释放纹理有保护，不会 AV；相机列表、组迭代、信号/补间/定时器、状态与子状态拆卸均正常。

被重点怀疑的顶点色批处理提交（flixel `04c3e4c`）经审计是**四边形对齐且正确的**，
但它建立在 openfl 一条没有余量的隐式约定上（数组长度恰好等于顶点数），改动前务必先读
`ShaderParameter.hx:622-623`。

