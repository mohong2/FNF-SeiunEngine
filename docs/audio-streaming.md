# 流式音频（Ogg Vorbis / MP3）

这份文档记录「音频不再整段解码常驻」这件事：为什么要做、data path 长什么样、和全解码版本在听感上是否一致、引擎侧怎么用，以及踩过的坑。

所有数据都在 Windows / x64 / release 实测，素材是仓库自带的 `assets/preload/music/freakyMenu.ogg`（112.95 s，2,040,005 B）和 `assets/songs/bopeebo`。

## 1. 结论

| | 全解码（原路径） | 流式（现在） |
|---|---|---|
| 常驻 PCM | 19,924,992 B（19.0 MiB，freakyMenu） | 0 B |
| 解码缓冲 | — | 16 × 8192 帧 × 4 B ≈ 512 KiB |
| 加载耗时 | 234 ms（解码整首） | 0–6 ms（只读头部） |
| 播放中 seek | 直接改 AL 缓冲偏移 | 解码器 seek + 重填队列 |
| 输出 PCM | 与 libvorbis `ov_read` 一致 | **逐字节相同**（见 §4） |

引擎内实测（同一份 bopeebo 谱面、同一台机器、进入歌曲后 6 秒取工作集平均值）：

- 全解码：**364.5 MB**
- 流式：**281.3 MB**

差 **83 MB**。这次会话里流过的 4 条 PCM 合计约 90 MB（`freakyMenu` 19.9 MB + `bopeebo/Inst` 13.5 MB + `bopeebo/Voices` 13.5 MB + 暂停音乐 `tea-time` 42.7 MB，按字节换算），采样时其中一部分已经被释放，所以实测差值是 83 MB；`generateSong` 内的加载耗时也从 249 ms 降到 4 ms。

## 2. 为什么不是 SDL_AudioStream

Lime 的播放链是 **OpenAL**：`AudioBuffer` → `AudioSource` → `NativeAudioSource` → OpenAL source/buffer。SDL3 的 `SDL_AudioStream` 是「格式转换 + 队列」层，不是 Ogg/MP3 解码器；把 SDL3 整套音频搬进来会换掉混音、pan、gain、pitch、监听器和 Haxe/OpenFL 的既有语义，也会让「和完全加载听感一致」变成一件要靠重采样猜的事。

所以实现是：**feeder 线程解码 → OpenAL 环形队列**。解码仍用 Lime 自带的 libvorbis（和全解码同一条 `ov_read` 路径），MP3 用 vendored dr_mp3，输出的 PCM 与全解码版本完全一致，混音路径一个字都没改。

## 3. 结构

```
Paths.inst()/voices()/music()
  └─ AudioBuffer.fromStreamFile(path)          只读头部：channels / sampleRate / 总帧数
       └─ Sound.fromAudioBuffer()              普通 Sound，data == null
            └─ Sound.play() → new AudioSource(buffer)
                 └─ NativeAudioSource.init()   streamHandle >= 0，不再创建静态 AL buffer
                      └─ lime_stream_source_create_file(path)
                           └─ StreamSource（C++，feeder 线程）
                                ├─ StreamDecoder（libvorbis / dr_mp3）每块 8192 帧
                                └─ 16 个 AL buffer 的环形队列（≈2.97 s @44.1 kHz）
```

- **预填 3 块**（≈0.56 s）后 `alSourcePlay`，之后 feeder 每 5 ms 醒一次：`AL_BUFFERS_PROCESSED` 回收 → 解码补满到 16 块。
- **时间**：`queueInfo` 记录每个已入队块的起始帧，`currentTime = queueInfo.front().startFrame + AL_SAMPLE_OFFSET`（偏移是相对**队首**的，见 §6），精确到样本；seek 期间先返回目标值（`seekInFlight`），feeder 应用后切回真实时间，所以拖动进度条不会出现「时间往回跳」。上报值再经过一次单调钳制：只有 seek 或循环回绕（跨度大于一块）才允许后退。
- **循环**：不用 `AL_LOOPING`（队列源上它无效），由 feeder 在 EOF 时把解码器 seek 回 0 继续填，语义等于 `Sound.play(loops)`，播完最后一轮才置 FINISHED。
- **完成**：队列排空 + EOF → `state = FINISHED`；Haxe 侧 25 ms 轮询一次派发 `AudioSource.onComplete`（`SoundChannel` 的 `SOUND_COMPLETE` 由此照常触发）。
- **控制**：play / pause / stop / seek / loops / gain / pitch / position 全部转发到原生源，静音、淡入淡出、`FlxSound.volume`、`pitch`（变速）行为与静态路径一致。

## 4. 和全解码是否一致

不一致是这次最不能接受的结果，所以做了逐字节对比：

1. 全解码：`AudioBuffer.fromFile` 后把 `data` 存成 `full.raw`（19,924,992 B）。
2. 流式：让 feeder 把每个交给 OpenAL 的块（块头记录起始帧）dump 出来，播放中途 seek 到 60 s。
3. 用 39 个块（0 s → 64 s，含 seek 之后）逐块和 `full.raw` 对比：

```
blocks: 39  mismatched: 0  maxdiff: 0
```

包括 seek 之后的块。也就是说：同一段音频，流式路径交给 OpenAL 的 PCM 与全解码完全相同，听感差异只可能来自「播放时序」，不可能来自采样值。

## 5. 引擎侧策略

- `Paths.music()` / `inst()` / `voices()` / `playervoices()` / `opponentvoices()` 默认 `streaming = true`；只有 **ogg / mp3** 走流式，wav / m4a 仍然全解码。
- **图表编辑器例外**：波形要读 `AudioBuffer.data`，所以 `ChartingState` / `NewChartingState` 显式传 `streaming = false`，并且波形代码补了 `data != null` 判断——编辑器自己的那份是全解码，游戏内那份是流式，二者用不同的缓存键共存。
- 缓存键加 `stream:` 前缀，避免「编辑器加载过的全解码副本」被游戏内误用（反之亦然）。
- MP3 不再必须先转 WAV：`Paths.inst` 对 mp3 直接建流，`DrMp3Tools.decodeFileToWav` 只作为探测失败时的兜底。
- 音效（`Paths.sound`）保持全解码：它们短、频繁触发，流式只会增加线程和队列开销。

## 6. 踩过的坑（重要）

**feeder 线程不是 hxcpp 线程。** 最初版本用 `lime::fread / lime::fseek` 解码，结果播放 5 块后整个进程卡死 5 秒然后 0xC0000005。原因是 Lime 的文件封装在每次读写外层套了 `System::GCEnterBlocking ()` / `GCExitBlocking ()`，那是给 hxcpp 线程用的；在自建 std::thread 上调用会破坏 GC 的线程状态。

修法：解码器改用纯 CRT stdio（`StreamOpenFile` 在 Windows 上用 `_wfopen`，保留 UTF-8 路径能力），整条 feeder 线程不再碰任何 hxcpp 运行时。内存流仍然用 `alloc_root` 保住 `Bytes`。

**dispose 与时间查询的竞态。** Haxe 侧每 25 ms 轮询一次时间，可能在 `dispose()` 摧毁原生源的同一刻进来。注册表因此改成 `shared_ptr`：查询拿到自己的引用，对象不会在调用中途被释放；`Destroy()` 置 `destroyed` 标记，之后的查询立即返回 0。

**`AL_SAMPLE_OFFSET` 是相对「队列起点」的，不是相对「正在播放的缓冲」。** OpenAL Soft 的 `GetSourceOffset ()` 把当前缓冲之前的每个已入队缓冲长度都加进 `readPos`（`project/lib/openal/OpenAL32/alSource.c` 里那行 `if(!readFin) readPos += BufferList->max_samples;`）。最初的实现拿 `AL_BUFFERS_PROCESSED` 当索引取「正在播放的那块」的起始帧，再叠加这个偏移，等于把「已经放完、但 feeder 还没出队」的块算了两遍：Mixer 每放完一块（8192 帧 ≈ 186 ms），`music.time` 就往前跳一整块，feeder 出队（≤5 ms 后）再掉回去。

游戏里这就是「打击判定忽前忽后」：`PlayState.update` 每帧把 `Conductor.songPosition = FlxG.sound.music.time`，位置跳 186 ms 时音符判定窗口整体错位，直接 miss；而 `PlayState.stepHit` 的 20 ms 漂移检查会被误触发，每步都调一次 `resyncVocals()`，把 Inst 与几条人声流全部 seek 一遍——听感上就是音频卡顿。音频本身没有断流（feeder 从未让队列跑空），卡顿来自这些多余的 seek。

修法是把基准换成**队列里最老的一块** `queueInfo.front().startFrame`（它和 `AL_SAMPLE_OFFSET` 的零点严格对齐），并把上报值做成单调：只有 seek（`FlushQueue` 清空并重置下限）或循环回绕（跨度大于一块）才允许后退，混音周期量化造成的几毫秒回退则被钳住。实测同一份 bopeebo、24 s、8594 次查询：修前 63 次 +205.8 ms / −185.8 ms 的来回跳，修后 0 次，残差 p99 = 17 ms（就是混音周期本身的量化），与全解码路径同一个时间源。

## 7. 限制

- 每条流一个解码线程 + 16 个 AL buffer；一首歌有 Inst、Voices（可能还有 Player/Opponent）时就是 2–4 条，仍然远小于整首 PCM。
- 只支持 Ogg Vorbis 与 MP3；其他容器/编码回退到全解码（`AudioBuffer.fromStreamFile` 返回 null）。
- 编辑器波形、以及任何需要 `buffer.data` 的地方必须显式要求全解码。
- 本机只验证了 Windows/x64；Android 的 asset 路径走 `lime::fopen`（非 stdio）时，`StreamOpenFile` 需要按平台补 `AAsset` 分支。

## 8. 关键文件

Lime（`.haxelib/lime/git`）：

- `project/include/media/StreamDecoder.h`、`project/src/media/StreamDecoder.cpp` — 拉式解码器（vorbis / dr_mp3）
- `project/src/media/StreamSource.cpp` — feeder 线程、环形队列、CFFI 入口
- `project/lib/drmp3/dr_mp3.h` — vendored dr_mp3
- `src/lime/media/AudioBuffer.hx` — `fromStreamFile` / `fromStreamBytes` / `duration`
- `src/lime/_internal/backend/native/NativeAudioSource.hx` — 原生源代理
- `src/lime/_internal/backend/native/NativeCFFI.hx` — CFFI 声明
- `project/Build.xml` — 编译单元与 include

OpenFL（`.haxelib/openfl/git`）：

- `src/openfl/media/Sound.hx` — `length` 改读 `AudioBuffer.duration`

引擎：

- `source/Paths.hx` — 流式策略与缓存键
- `source/editors/ChartingState.hx`、`source/editors/NewChartingState.hx` — 编辑器强制全解码
