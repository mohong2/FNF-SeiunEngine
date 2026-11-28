# 文本渲染流水线（FlxText / OpenFL TextField）

这份文档记录 `FlxText` 一次「文字变了」到底做了什么、钱花在哪、已经改掉了什么，以及还没改的部分。
所有数字都是 Windows / x64 / release、1280×720、渲染倍率 1x 下的 `haxe.Timer.stamp()` 采样（p50，200 次/组，先跑 20 次热身）。

## 1. 一次更新的完整路径

```
FlxText.text = s
  └─ set_text()                         字符串相同则直接返回
FlxText.draw() / updateHitbox()
  └─ regenGraphic()
       ├─ contentSignature()            输入签名（文本/格式/字段宽/渲染倍率）
       ├─ textField.textHeight          触发 OpenFL 排版（TextEngine.update）
       ├─ computeDirtyRect()            能否只重画一段
       ├─ graphic.bitmap.fillRect()     清空（整块或脏区）
       ├─ renderText()
       │    ├─ cache.draw(textField)    TextField 整行栅格化进 scratch
       │    ├─ FlxTextStamp.border()    描边色栅格按 8 个偏移盖章
       │    └─ FlxTextStamp.fill()      用栅格 alpha 作 mask 画填充色
       └─ rememberRaster()
  └─ 渲染器下一帧上传这张位图（GL 纹理）
```

## 2. 上游（HaxeFlixel dev）的情况

截至 2026-11-28 的 `dev`（8438eb1），`FlxText.regenGraphic()` 仍是：

- 每个 `text`/格式/尺寸变化 → `graphic.bitmap.fillRect()` 清空整块，再 `drawTextFieldTo()` 把 TextField 整个重画一遍；
- 描边 `OUTLINE` 走 `applyBorderStyle()`，每个偏移都重新 `drawTextFieldTo()`，一次重建 `1 + 8 × int(borderSize × borderQuality)` 次整画（本引擎 HUD 的 `borderSize = 2` 就是 17 次）；
- 没有「输入没变就跳过」、没有增量区域、没有字形/位图缓存。

唯一相关的是 #3532「`FlxText`: Avoid redundant image regen in setters」——只是让 setter 重复赋值时不重画，和「文字变了」这条路径无关。#2717 里作者自述 FlxText 性能很糟，但只是 issue。
结论：这条路径上游没有修，本 fork 自己维护。

## 3. 本 fork 已经做的（按落地顺序）

1. **描边盖章**（flixel）：描边色只栅格化一次，再按 8 个偏移 blit，17 遍整画 → 2 遍，逐字节等价（14 组用例）。
2. **增量重绘**（flixel）：只重画新旧字符串差异对应的设备像素箱；证明不出安全箱时整行重画。
3. **无变化跳过**（flixel）：内容签名未变的重建直接返回。
4. **静态文本合页**（flixel）：签名稳定 750 ms 后把位图塞进共享大图，减少批次。
5. **排版不再 hinting**（openfl，本轮）：`TextEngine.shapeHinting = false`。
6. **形状缓存有上限**（openfl，本轮）：`ShapeCache` 超过 1024 条整体丢弃。
7. **重复赋值直接返回**（flixel，本轮）：`set_text()` 相同字符串不动 TextField。
8. **签名只算一次**（flixel，本轮）：`regenGraphic()` 里算出的签名传给 `rememberRaster()`。

## 4. 关键测量

排版是剩下的大头，而且和文本长度几乎无关——它是**按新字形数**计费的：

| 项目 | 改前 | 改后 |
| --- | --- | --- |
| `TextEngine` 排版（60 字符分数行） | 186.8 us | 20.6 us |
| 其中 `HB.shape()` | 179.6 us | 7.5 us |
| 其中 `getPositions` 调用数 | 13 次/排版 | 13 次/排版 |
| 分数行单次更新 | 0.36 ms | 0.19 ms |
| 分数行（无描边） | 0.25 ms | 0.09 ms |
| 命中帧（分数 + 3 个侧边计数） | 0.70 ms | 0.32 ms |
| 自动宽度文本（`ms` 计时） | 0.26 ms | 0.09 ms |

根因：`FlxText` 构造时 `textField.sharpness = 100`，OpenFL 据此把 `TextLayout.autoHint` 设为 `true`，FreeType 在 `HB.shape()` 里对每个字形执行 hinting 字节码。Source Han Sans CN Heavy 上约 **15 us/字形**；HUD 一行每次更新要重新排版 10–20 个新字形（数字是最常变的），于是 0.15–0.3 ms 全花在「把小数 advance 四舍五入成整数」上。而 Cairo 光栅化本来就用 `CairoHintMetrics.OFF`，字形落点一直是小数。

关掉后 advance 变成小数，行宽最多窄 0.5%（62 字符分数行 627.06 → 623.78 px），字形栅格化路径完全不变。需要旧间距时设环境变量 `SEIUN_TEXT_HINTING=1`。

## 5. 还没做的

- **自动宽度文本的位图重建**：`fieldWidth = 0` 的文本（`msTxtKade`、`tailBadgeTxt`、脚本 `AttachedText`）宽度一变就 `makeGraphic()` 新位图 + 新 `FlxGraphic` + 新纹理键，约 20% 的更新会走到。要做成「只增不减的位图 + 子帧」，牵涉 `frames`/`frameWidth`/`offset`，风险高于收益，留到下一轮。
- **多段增量重绘**：分数行每次同时改分数、准确率、断连三处，单段脏箱横跨大半行，于是退化成整行。拆成多段需要逐段证明「未变段的 x 没动」（即比较新旧每段宽度），否则会留下错位像素。
- **纹理上传**：每次重绘仍会整张上传（分数行 1280×29 ≈ 148 KB）。要省得让位图贴合字形盒而不是字段宽，同样牵涉 `width`/`offset` 语义。

## 6. 怎么复现这组数字

1. 在 `FlxText.regenGraphic()` 各阶段前后插 `haxe.Timer.stamp()`，或在状态里直接对同一批文本做 `text = s; updateHitbox()` 循环；
2. 写一个 env 触发的临时状态（跑完即退）循环 200 次，取 p50/p90；
3. OpenFL 侧同理：`TextEngine.update()` 的 `getLineBreaks/getLayoutGroups/getLineMeasurements/setTextAlignment/getBounds` 分别计时，`TextLayout.__position()` 里对 `HB.shape()` 单独计时。

注意：测 FlxText 时不要在同一帧里既改文本又依赖 `draw()` 触发重绘——`draw()` 走的是渲染循环，计时会把相机/批处理算进去。用 `updateHitbox()`（内部就是 `regenGraphic()`）更干净。

## 7. 第二轮：把剩余成本拆开（2026-11-28）

上面第 4 节的数字是 1x 下测的。实际游玩时窗口 1080p，`FlxText` 的 `_textRenderScale` 是 **1.5**，位图按 1.5 倍分配（分数行 1921×49），所有面积相关成本 ×2.25。所以这一轮直接测真实 HUD 的四种文本。

### 7.1 怎么测（已经落到仓库里）

- `source/states/TextBenchState.hx`：`SEIUN_TEXT_BENCH=1` 启动时直接进这个状态，用和 `PlayState` 完全相同的字体/字号/描边/字段宽/对齐建 5 组文本，逐帧改一次、同步 `calcFrame(true)` 触发重建，跑完打印 p50/p90 并退出。
  - `SEIUN_TEXT_BENCH_FRAMES=<n>` 每组样本数（默认 100）；`SEIUN_TEXT_BENCH_TAG=<label>` 报告标签。
  - `SEIUN_TEXT_BENCH_VERIFY=1`：每组样本都再强制整行重画一次，和正常路径逐像素比较，打印差异像素数与所在 x 区间。**改动文本流水线必须先跑这个，`diffPixels` 必须是 0。**
  - `SEIUN_TEXT_BENCH_DETAIL=1`：打开 `RenderProf` 的逐 draw 计时，只为拿 `uploadMs`（`texImage2D` 本身）；它会给其它阶段带来额外开销，看阶段耗时时不要开。
- `flixel/text/FlxTextProf.hx`：`FlxText` 重建的分项计时（`total/layout/alloc/clear/render/raster/stamp`），默认关闭，关闭时每个阶段只是一次静态读。

### 7.2 现在的构成（1280×720 游戏、1920 宽窗口、renderScale 1.5、p50 ms/次）

| 用例 | total | raster | stamp | clear | alloc | 上传(texImage2D) |
| --- | --- | --- | --- | --- | --- | --- |
| 分数行（语气字体 20、OUTLINE 2、字段宽 1280） | 0.866 | 0.212 | **0.594** | 0.043 | 0 | 0.029 |
| 分数行（无描边） | 0.248 | 0.223 | 0 | 0.025 | 0 | 0.031 |
| 自动宽度（语言字体 28） | 0.499 | 0.086 | 0.286 | 0.009 | **0.112** | 0.007 |
| 侧边计数 ×3 | 0.127 | 0.059 | 0.049 | 0.012 | 0 | 0.008 |
| 计时器（vcr 20、`2:12`） | 0.155 | 0.072 | 0.060 | 0.016 | 0 | 0.012 |

读数：

- **描边盖章是分数行的 68%**（0.594 ms）。它是 17 遍 `cairo` 合成，成本跟着**栅格（source）面积**走，而不是跟着 clip 走 —— 实测把 clip 从整行 1921 宽缩到墨迹 823 宽，时间一点没变。所以「脏区裁剪」对这条路径省不到钱，除非连栅格化本身也只做改动的字段。
- **字形栅格化**（`cache.draw(textField)`）在有/无描边两种用例里都是 ~0.21–0.22 ms，和字段宽无关、和字形数有关（55 字形 ≈ 3.8 us/字形，Source Han CN Heavy @1.5x）。
- **纹理上传很便宜**：376 KB 的 `texImage2D` 只有 0.029 ms。真正的上传侧成本是 `BitmapData.__getTexture()` 在 `texImage2D` 之前对整张位图做的 premultiply clone（`submit` 增量 − 阶段和 ≈ 0.1 ms）。
- **自动宽度重建 0.112 ms** 是纯分配（新 `BitmapData` + 新 `FlxGraphic` + 新纹理键），占该用例 22%。

合起来，真实游玩时 HUD 文本大约每帧 0.15 ms（计时器）+ 每次命中 0.87（分数行）+ 0.38（三个侧边计数），按 144 BPM 约 1–2% 的单核时间。

### 7.3 这一轮试过、但**没有**落地的东西

| 实验 | 结果 | 结论 |
| --- | --- | --- |
| 整行重画只重绘「墨迹箱」 | 像素完全一致（`diffPixels=0`），耗时 0.866→0.890 | Cairo 成本跟 source 面积走，省不到；已回滚，避免白留复杂度 |
| 只上传脏区（`texSubImage2D`） | `texImage2D` 本来只有 0.03 ms | 不值得动 OpenFL 的纹理上传协议 |
| 增量重建只栅格化改动的字段（scratch 缩到脏区） | 盖章降到 ~1/3，但侧边计数用例出现 5 px 竖缝（`x=206..210`，150 帧累计 1278 像素） | **未通过像素校验**，已回滚；现有的「整行栅格 + 脏区裁剪」自身是逐像素正确的（150 帧 0 差异） |

那条竖缝在扩大边距（+14 px）后只是变窄没有消失，说明不是简单的邻居描边够不到，更像 scratch 作为 source surface 在边缘取样时与整行 scratch 的行为不同；要修得先把它缩成一个确定的最小用例，下一轮再做。

### 7.4 更新后的「还没做的」

- **描边盖章**仍是最大单项。想再降只能换算法（字形级 SDF/描边贴图，或按字形缓存「描边+填充」拼字），两者都会改变像素，必须先定验收标准。
- **自动宽度文本的位图重建**（0.11 ms + GC）：做成「只增不减的位图 + 子帧」。
- **多段增量重绘**：分数行一次改三处，单段脏箱跨大半行；拆段要逐段证明宽度未变。
- **premultiply clone**：每次上传前整张位图 clone 一次做预乘（≈0.1 ms/次），改成复用一块预乘影子缓冲、只更新脏区，是上传侧唯一还有价值的改动。

## 8. 真机测量：把 `FlxTextProf` 接到真实对局上

合成基准能说明每个阶段多贵，但说明不了**游戏实际多久重建一次、重建的是哪一行**。这一轮把 profiler 接到真实对局上：

- `SEIUN_TEXT_PROF=1`：`FlxTextProf` 在第一次 `set_text()` 时读环境变量打开自己，此后每次重建往 `SEIUN_TEXT_PROF_LOG`（默认 `textprof.csv`）追加一行 `t,total,layout,alloc,clear,render,raster,stamp,chars,text`。行里的时间都是**这一次重建自己的**各项耗时（`beginRebuild()` 打点，`endRebuild()` 求差）。
- `SEIUN_BOTPLAY=1`：`ChartLoadProbe` 置 `botPlay`，配合 `SEIUN_CHART_PROBE` + `SEIUN_CHART_PROBE_STAY=1` 直接进对局并让机器自己打，HUD 才会按命中节奏刷新。

复现（在 `export/release/windows/bin` 下）：

```
set SEIUN_CHART_PROBE=bopeebo:bopeebo
set SEIUN_CHART_PROBE_STAY=1
set SEIUN_BOTPLAY=1
set SEIUN_TEXT_PROF=1
SeiunEngine.exe     :: 跑 ~30s 后结束进程，textprof.csv 就是全部样本
```

### 8.1 结果（bopeebo / botplay / 30 s / 281 次重建）

| 阶段 | 合计 | 占比 |
| --- | --- | --- |
| 栅格化（`raster`） | 54.5 ms | 60% |
| 描边 + 填充（`stamp`） | 19.2 ms | 21% |
| 分配（`alloc`） | 11.1 ms | 12% |
| 清脏区（`clear`） | 4.3 ms | 5% |
| 排版（`layout`） | ≈0 ms | 0% |
| **合计** | **90.8 ms / 29.1 s = 0.31% 墙钟** | |

- 单次 p50 **0.210 ms**、p90 0.727 ms、p99 1.303 ms、最大 2.661 ms。
- 0–10 s 基本是加载画面（大字号标题，1.5 ms/次栅格）；**对局阶段（t≥15 s）69 次重建 / 14.1 s ≈ 4.9 次/秒、23.2 ms ≈ 0.16% 墙钟**，按 60 fps 是每帧 0.027 ms。
- 最贵的一次是对局第一帧的 `Notes: 0 + 0 = 0 | NPS: …`：2.66 ms，其中栅格 1.50 ms（49 字符的一行在 1.5x 下首次构建）。
- 稳定态最贵的是分数行（botplay 下 `Notes: … | NPS: …`，约 1.0–1.3 ms/次，描边 0.8–1.0），和合成基准的 0.866 对得上；侧边计数与计时器更小。
- **排版实测为 0**：对局里这些文本的 `fieldWidth` 固定，`textWidth` 读取不再触发 OpenFL 重新排版，hinting 那轮省下的 166 µs/次在真机上直接消失。

原始数据：`docs/data/textprof-bopeebo-botplay.csv`（281 行，带文本前缀）。

### 8.2 结论：这条流水线可以收了

1. **文本重建已经不是性能问题**：对局阶段 0.16% 墙钟，20 notes/s 的密集段也只有 ~1.4% 单核。用户报的「文本改了 → 整块重来」已经被前三轮的改动消化掉：描边从 `1+8*iterations` 次 TextField 绘制变成 1 次栅格 + 16 次 Cairo 合成；`set_text` 的内容守卫把每帧重写的空操作挡掉（计时器每秒被写 60 次，只有 1 次真的重建）。
2. **成本结构决定了收益上限**：栅格 60% + 描边 21%。把描边整个干掉也只省 `0.16% × 21% ≈ 0.03%` 墙钟。所以 7.4 里剩的三项（描边换算法、premultiply clone、自动宽度位图）**按现在的收益比都不值得做**，除非目标变成 4K / 更高 `renderScale`（那时面积 ×2.25 再 ×4，描边才会重新变成大头）。
3. **还值得投入的只有回归保护**：`SEIUN_TEXT_BENCH_VERIFY=1`（像素）和 `SEIUN_TEXT_PROF=1`（真机成本）都是可复算的，以后动 `FlxText` 先跑这两个，再谈优化。
