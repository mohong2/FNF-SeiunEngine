# chartpack — 极限压缩的 FNF / Seiun Engine 谱面容器(我可懒得改这个文档)

## 一句话

把 1.4 GB 的雷霆谱面 JSON 压到 **64 KB**（约 2.2 万倍），解包后得到语义等价的 JSON；引擎可以直接读取 `.chartpack`，不需要把 JSON 还原到磁盘。

## 实测（Amphotercity-Reformed / amphotercity）

| 文件 | 原 JSON | chartpack | 压缩比 |
|---|---:|---:|---:|
| amphotercity-1.json | 198,247,925 B | 336,044 B | **590×** |
| amphotercity-2.json | 1,406,720,362 B | 64,098 B | **21,946×** |
| **全部 34 个文件实测** | **45,217,329,492 B (42.11 GiB)** | **2,535,680 B (2.42 MiB)** | **17,832×** |

为什么能这么小：这些谱面 99.69% 的 note 是完全重复的。part 2 有 64,224,528 条 note，但不同的
(time, lane, sustain, type) 只有 **196,544** 组；part 1 有 9,092,668 条 note，只有 2,081,946 组。
容器只存“组 + 重复次数”，再对组流做 zlib，重复次数和规律让压缩器几乎不花空间。

## 原理

1. **Skeleton（骨架）**：把原 JSON 中每个 `sectionNotes` 数组的内容挖掉，换成一个 NUL 字节占位；
   其余所有字节（顶层字段、section 字段、events、格式、字段顺序）原样保留并 deflate。
   解包时按 NUL 切开，把生成的 note 数组填回去。因此未知字段、事件、缩进都不会丢。
2. **Group stream（组流）**：每个 section 内按 `(time, lane, sustain, type)` 聚合，记录重复次数。
   - 时间：SNIFF 谱面的时间是 `60000 / bpm / 3072` 的整数倍（part 1 的 9,092,668 条全部验证通过），
     所以存 tick 的 varint 增量；不满足网格的普通谱面自动退回 float64 模式。
   - sustain / noteType 用字典 + 索引；lane 用 zigzag varint；count 用 varint。
   - 整个组流再 deflate。
3. **语义等价**：同一 section 内 note 的**多重集**完全一致（时间、lane、sustain、类型、重复次数）。
   同一时刻、同一 lane 的 note 顺序可能改变，但引擎的 GhostCollapser 按 lane 折叠，结果不变
   （已用 64M note 的 part 2 对比：原生 JSON 8,548 reps，pack 8,552 reps，差 4 个）。

## 用法

```powershell
# 单个文件
node tools/chartpack/chartpack.mjs pack   in.json   out.chartpack
node tools/chartpack/chartpack.mjs unpack out.chartpack  in.json
node tools/chartpack/chartpack.mjs info   out.chartpack

# 整个歌曲目录：把所有 *.json 打包（跳过 events.json / meta.json / *.parts.json）
node tools/chartpack/chartpack.mjs pack-dir "mods/.../data/amphotercity"

# 打包后删除原 JSON（确认备份/验证后再用）
node tools/chartpack/chartpack.mjs pack-dir "mods/.../data/amphotercity" --replace

# 已有 .chartpack 时强制重打
node tools/chartpack/chartpack.mjs pack-dir "mods/.../data/amphotercity" --force
```

验证语义等价（开发用）：

```powershell
node tools/chartpack/chartpack.mjs unpack x.chartpack x.unpacked.json
node tools/chartpack/compare.mjs x.json x.unpacked.json
# { badSections: 0, skeletonSame: true } 即通过
```

完整谱面（33 个 part、386,282 个 section、约 20.64 亿条 note）已用
`SEIUN_CHART_PROBE` 无头加载验证：

- **首次加载（cache miss）**：约 **6–8 秒**，**550,954 个 representatives**，峰值内存约 **1.7 GB**；
- **再次加载（cache hit）**：约 **4.7 秒**，峰值内存约 **1.5 GB**；
- note 时间范围实测 **26,033.898 – 400,228.814 ms**（修复了 tick 时间乘 1e6 导致 Int32 溢出的问题）。
- 单个 part 2（64,224,528 note）：**8,552 reps**（原生 JSON 路径为 8,548，差 4 个），
  fast path 下 `perNoteBody` 约 **0.036 秒**。

原 JSON 已在确认后删除，目录里只剩 34 个 pack + events.json；`bin/chart_cache` 里的
`.notes/.skel` 是加载缓存，不是 pack 转换产物。

## 引擎接入

源码已接入（`source/ChartPack.hx` 以及 `ChartStream` / `ChartParts` / `Song` / `PlayState` 的小改动）：

- `Song.tryLoadStreaming()` 先找 `<song>.chartpack`；编号 part 由 `ChartParts` 自动识别
  `<song>-1.chartpack`、`<song>-2.chartpack` …，并与 JSON part 混用。
- `ChartStream.scanPart()` 对 pack 调 `ChartPack.scan()`，返回 skeleton + 每个 section 的组索引。
- `ChartSectionReader.readNotes()` 对 pack 解码组，返回带 `repeat` 的 `ChartRawNote`；
  `PlayState.generateSong()` 的内层循环按 `repeat` 展开，所以 GhostCollapser / 判定 / 连击权重与
  原始 JSON 完全一致。
- pack 谱面自动跳过 ChartNative 的 JSON 扫描/折叠和 ChartPrefetch（它们面向 JSON 字节）；
  ChartCache 仍然可用。
- 组重复次数通过 `GhostCollapser.feedRepeat()` 一次性喂入（`density += count`），
  64 M 条重复 note 只走约 200 k 次组调用，而不是 64 M 次逐 note 循环。
- **引擎只读 `.chartpack`，从不写、也不会把 JSON 自动转成 pack**；转换只能由
  `tools/chartpack/chartpack.mjs` 手动执行。`ChartCache` 写的 `.notes/.skel` 只是加载缓存。

构建（本机已装 Haxe 4.3.7的情况下）：

```powershell
haxe export/release/windows/haxe/release.hxml
Set-Location export/release/windows/obj
haxelib run hxcpp Build.xml
Copy-Item ApplicationMain.exe ..\bin\SeiunEngine.exe -Force
```

已用 `SEIUN_CHART_PROBE` 无头验证（fast path 前）：

- 311 KB 的 `the-uprising-hard`（float 时间模式）：pack 与 JSON 都是 7,923 representatives。
- 32 MB / 1,521,362 note 的 amphotercity 切片（tick 时间模式）：
  pack 与 JSON 都是 1,522,410 representatives；pack 的 `songLoad` 0.04 s，JSON 2.73 s。

## 注意

- **不是逐字节还原**：解包后的 note 顺序在同一时刻内可能不同，但 note 集合、时间、lane、sustain、
  类型完全一致；游戏表现一致（已验证）。如果你需要“原文件字节级还原”，需要再加一条 order 流
  （约 2 bit/note，part 2 约 16 MB，仍然比 1.4 GB 小 88 倍），目前未实现。
- `--replace` 会删 JSON，建议先 `pack-dir`（保留 JSON）+ 抽样 `compare`，确认后再删。
- 引擎对 `<song>.json` 与 `<song>.chartpack` 同时存在时优先 pack；编号 part 两者同时存在时
  目录顺序决定，转换时最好删掉 JSON，避免歧义。
- pack 里的 `events` 在 skeleton 中，照常加载。
- 时间网格不匹配的普通谱面会自动用 float64 时间（压缩率会低一些，例如 311 KB → 19 KB，16×），
  不影响正确性。
