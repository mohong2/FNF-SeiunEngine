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
