# SeiunEngine 更新日志 · Changelog

> 完整记录 2026年6月19日 至 11月7日 的所有改进、修复与突破
> A comprehensive record of every improvement, fix, and breakthrough from June 19 to November 7, 2026.

---

## 中文版

---

### 2026年6月19日

- 修复进入 Senpai 歌曲时前段 Note 消失的问题。
- 修复部分安卓设备在回放历史界面与游戏结束界面闪退的故障。
- 完全重构 Replay（回放）系统。
- 更新 Lua 库版本。
- 重构暂停界面，增加轻微 3D 视觉效果。
- 新增 Trace 控制台功能。
- 新增设置备份与恢复机制。

---

### 2026年7月18日（阶段性大更新）

#### 脚本与模组系统

- HScript 脚本已完善至可独立编写模组的程度，支持自定义图标等资源。
- Lua 兼容性进一步加强，API 处于早期阶段，允许修改（sub）state（未全覆盖测试，可能影响部分模组）。
- 提供两套 FPS 显示方案，可在模组配置中切换。
- 健康条（Health Bar）不再使用映射方式，改用 073 Bar.hx 原生创建，彻底修复显示异常。
- Lua 与 HScript 均可修改（sub）state（早期阶段）。

#### 编辑器与谱面

- 谱面编辑器支持导入/导出 Codename Engine（CNE）格式，保存功能整合为单一 Prompt 窗口。
- 修复编辑器内 Prompt 窗口在手机端缺少关闭按钮（X）的问题。
- 修复新版谱面编辑器中 Note 跑到对方判定区的问题。
- 修复旧版谱面编辑器中“保存并试玩”会强制写入谱面的问题（改为仅试玩不保存）。
- 重构新旧两个 ChartingState 的未保存警告逻辑，统一为退出/重载/试玩/预览前均弹窗确认，不再自动保存。
- 新增“谱面自动保存”设置（默认关闭），开启后定时自动备份。
- 修复谱面 0.6.3 转换时的兼容性问题（7.20 另有专项修复）。

#### 性能与渲染

- 优化大批量 Note（数万至数十万）的帧率与内存占用（图集帧缓存，提升加载速度）。
- 进一步优化同场景下大量 Note 的加载效率（缓存帧扫描结果，避免重复开销）。
- 清理 Note 构造时的自指环隐患（prevNote 不再自指）。
- 底层渲染微优化。
- 删除多线程更新（因 BUG 过多）。
- 修复 Note 从超慢速变超快速时长条异常变长的问题。

#### 界面与交互

- 重写设置界面（简化为单个类），支持模组通过 JSON + HScript + Lua 自定义菜单及动画。
- 重构模组加载流程：FreePlay 不再一股脑显示所有模组歌曲，改为 Tab 切换；主页面增加模组切换子状态（独立于 FreePlay）。
- 将 Combo 等图像生成优化，降低内存占用，避免粪谱卡顿。
- 暂停界面保留旧版（OldPauseSubState），可选用。
- 移植 PsychCamera 等 0.7.3 / 1.0.4 特有类。
- 修复 mustHitSection 影响玩家动作播放的问题。
- 修复练习模式准确率显示错误（仅为显示问题）。
- 修复 Replay 未记录手机端虚拟控件输入的问题。
- 修复只有一个模组时无法打开菜单的漏洞。

#### 兼容性与其他

- MusicBeat（sub）State 在电脑端增加手机虚拟按键空实现，便于 PC 支持触屏。
- 修复新版 Replay 记录缺失手机控件数据的问题。
- 修复安卓设备相关兼容性问题。

---

### 2026年7月19日

- 修复 Sparrow XML 帧中 rotated="true" 未正确应用角度旋转的问题。
- 增加全局模组列表选项。
- 安卓设置支持用户自定义文件存放类型，适配高版本 Android 的 data 目录限制。
- 修复人物无法正常翻转的问题。
- 优化歌曲进入速度。
- 代码清理（含移除冗余日志、恢复 CO 兼容性等）。

---

### 2026年7月20日

- 修复谱面 0.6.3 转换问题（独立修复）。

---

### 2026年7月21日

- 移除安卓激进优化设置。
- 修复所有场景均会加载 stage 图片的冗余问题。
- 修复兼容模式下 timeBar 的 cameras 为 null 导致崩溃的问题。

---

### 2026年7月31日（大量修复与改进）

#### 脚本与判定

- 修复 Botplay 下命中 Hurt / ignoreNote 音符无法触发 Lua / HScript 事件的问题。
- 修复未选择模组却错误加载其他模组 Main.hx 的渗透问题。
- 修复 pack.json 缺少 restart 字段导致崩溃的问题。
- 修复倒计时未结束歌曲提前开始的问题。
- 修复倒计时期间 Note 判定 ms 异常（现与正曲一致）。
- 新增“忽略循环报错脚本”设置（默认开启），并配套“脚本报错上限”（默认 50 次），持续报错的脚本将静默停用，避免刷屏。
- HScript 默认走错误上限逻辑，不再首次报错就弹窗关闭。

#### 编辑器与谱面

- 修复 MasterEditorMenu 选择模组后首次进入编辑器仍加载原版资源的问题。
- 彻底统一新旧编辑器的保存警告逻辑，不再自动保存。
- 新增“谱面自动保存”选项（默认关闭）。

#### 性能与 UI

- 再度优化大批量 Note 加载速度（缓存帧扫描、单次纹理加载）。
- KeyboardDisplay 全面软编码化（支持自定义键大小、间距、字体、颜色、透明度等），并提供 fullyCustom 开关及按压/释放/更新钩子。
- 游戏结束结算界面（Results）与回放历史界面（ScoreHistory）UI 现代化，采用弹性进场动画、鼠标悬停反馈、动态排版，修复文字重叠、截断等问题。
- 暂停界面提高透明度（黑底、亚克力、玻璃卡片均更透），参数可调。
- 优化回放系统（Replay）。

---

### 2026年8月18日

- 进一步优化 Note 性能：针对极限谱面（数十万级 Note）做了额外的加载与渲染加速，帧率更稳定。
- 修复 Vs slice 模组谱面转换时导致的崩溃问题：解决了该模组特定谱面在转换过程中因数据解析异常引发的程序崩溃。
- 修复若干已知问题：包括社区反馈的特定模组兼容性、偶发闪退及界面显示异常。
- 底层升级 SDL3：将原 SDL2 渲染后端迁移至 SDL3，提升跨平台图形性能及输入响应，为后续功能预留接口。
- 修复 Windows 图标错误：解决了因 Lime 构建图标注入错误导致的 Windows 可执行文件图标显示异常的问题。
- 补充制作人员名单：在相关界面中补全了参与本项目开发的贡献者信息。

---

### 2026年8月19日

- 修复 Replay 无法正常播放的问题，具体原因如下：
  1. ScoreHistorySubstate.playReplay() 直接调用 Song.loadFromJson() 时，未像 Freeplay 那样先切换至歌曲所属模组目录，导致 Paths.modsJson() 无法定位模组谱面，回退读取 assets/data/ 目录。
  2. 同步增强了 Replay 判定精度。
- 彻底移除了 GPUTextureManager 及“GPU纹理池化”设置，修复开启该选项后大图或全屏区域出现黑块的问题。
- 补全新版 Adobe Animate（spritemap1）角色支持。
- 修复 FlxAnimate 角色动画播放异常的问题。
- 修复 Lua playAnim 接口在特定场景下无法正确触发角色动画的问题。
- 修复 StageData 兼容性问题，解决部分模组舞台加载失败或显示错乱的现象。
- 修复相机缩放（camera zoom）相关逻辑，确保缩放行为与预期一致。
- 修复 healthBar.scale 读取异常，解决健康条在部分模组中缩放比例不正确的问题。

---

### 2026年8月20日 — SeiunEngine 0.7.3 兼容性全量修复

#### 新增 0.7.3 兼容层

- 新增 backend.Mods 兼容类（source/backend/Mods.hx），提供 0.7.3 模组 HScript 依赖的 Mods API：currentModDirectory、getGlobalMods、pushGlobalMods、getModDirectories、mergeAllTextsNamed、directoriesWithFile、getPack、parseList、updateModList、loadTopMod，全部委托给 Seiun 已有的 Paths 与 CoolUtil，避免重复维护。
- 修复 Lua 脚本 onCreate 期间无法被其他脚本回调注册的问题（source/script/lua/FunkinLua.hx）：现在 call('onCreate') 之前会把当前 Lua 脚本临时加入 PlayState.instance.luaArray，onCreate 结束后再移除。该修复解决了 Pause.lua 的 onCreate 调用 parseJson 时为 nil 的根因，同时修复了 jsonReader.hx 的 createGlobalCallback 注册不到当前脚本的问题。

#### 暂停菜单 / CustomSubstate

- CustomSubstate 的 Lua 全局改为安全值（source/script/lua/FunkinLua.hx）：Lua 侧 customSubstate 不再直接存放 CustomSubstate 实例，改为子状态名字符串（如 "NEW_pause_menu"）；HScript 侧仍保留真实 CustomSubstate 实例。消除了 "Convert: Haxe value ... not supported" 报错。

#### 版本 / 变量兼容

- version 全局跟随兼容模式（source/script/lua/FunkinLua.hx、source/script/hscript/HScript.hx）：version 现在等于 CompatEngine.current()，0.6.3 / 0.7.3 / 1.0.4 模式会返回对应版本号。
- opponentVocals 重命名（source/states/PlayState.hx、source/editors/ChartingState.hx）：原 vocalsOpponent 全部重命名为 0.7.3 的 opponentVocals。
- 新增 0.7.3 属性：PlayState.inst 指向 FlxG.sound.music 的 instrumental 别名；PlayState.stageUI 支持 stage json 的 stageUI 字段；PlayState.iconsAnimations 默认 true，供 iconShake 等脚本读取；StageData.StageFile 增加可选 stageUI 字段。
- noteSkinPostfix / splashSkinPostfix（source/script/lua/FunkinLua.hx）不再硬编码为空，改为读取 Note.getNoteSkinPostfix() 和 NoteSplash.getSplashSkinPostfix()。

#### 缺失回调补全

- 成就系统完整兼容（source/Achievements.hx）：保留旧版 Seiun 成就 API（achievementsStuff、achievementsMap、henchmenDeath、loadAchievements、unlockAchievement、isAchievementUnlocked、getAchievementIndex、AchievementObject、AttachedAchievement）；移植 0.7.3 成就系统（Achievement typedef、achievements、variables、achievementsUnlocked、getScore、setScore、addScore、unlock、isUnlocked、startPopup、createAchievement、reloadList、loadAchievementJson）；新增 Lua 回调（getAchievementScore、setAchievementScore、addAchievementScore、unlockAchievement、isAchievementUnlocked、achievementExists）。
- Discord 兼容别名（source/Discord.hx）：新增 clientID、_defaultID 静态变量；source/script/lua/FunkinLua.hx 新增 Lua 回调（changeDiscordPresence、changeDiscordClientID）。

#### 调用顺序修复

- PlayState 的 onCreatePost 顺序对齐 0.7.3（source/states/PlayState.hx）：Lua onCreatePost 在 super.create() 之前调用一次；HScript onCreatePost 由 super.create() 内部调用一次；删除原先重复的 callOnScripts('onCreatePost')，避免 HScript 执行两次。

#### 哨兵值兼容

- Function_Stop 等常量改为 0.7.3 字符串哨兵（source/script/lua/FunkinLua.hx、source/psychlua/LuaUtils.hx、source/editors/EditorLua.hx）：Function_Stop、Function_Continue、Function_StopLua、Function_StopHScript、Function_StopAll 全部改为 "##PSYCHLUA_*" 字符串，与 0.7.3 / 1.0.4 一致。

#### 控制器 / 输入兼容

- keyboardJustPressed 键盘 + 手柄回退（source/script/lua/FunkinLua.hx）：ENTER、SPACE、Z 键盘没按时回退到 Controls.ACCEPT；ESCAPE、BACKSPACE 回退到 Controls.BACK；W、UP、S、DOWN、A、LEFT、D、RIGHT 回退到 UI_*_P。keyboardPressed、keyboardReleased 也补了对应的按住/松开回退。
- keyJustPressed / keyPressed / keyReleased 补 default（source/script/lua/FunkinLua.hx）：未匹配的名字会走 controls.justPressed / pressed / justReleased，与 0.7.3 ExtraFunctions 行为一致。

#### 版本显示调整

- 主菜单 PE 版本显示（source/states/MainMenuState.hx）：显示 "Psych Engine v0.6.3+0.7.3+1.0.4 (Active: 当前兼容版本)"，所有版本文字改为右对齐，贴住屏幕右边缘，避免长文本溢出。
- 游戏内左下角 PE 版本显示（source/states/PlayState.hx）：左下角版本文字中的 PE 版本改为 CompatEngine.current()，跟随当前激活的兼容模式显示。

---

### 2026年8月21日

- 修复 Replay 若干遗留问题（回放难度锁定、回放数据完整性等）。
- 移除 OSU 尾判设置选项（gameplay 选项、ClientPrefs 与回放/判定相关代码一并清理）。

---

### 2026年8月22日（UI 架构统一重构 + 设置弹窗）

#### 通用 UI 基础（新增 source/backend/UIScreen.hx）

- 新增 UIScreen 工具类，统一各现代界面的玻璃/亚克力 UI 实现：
  - createScreenCamera()：创建独立的静态屏幕空间相机，子状态 UI 不再受 PlayState / Freeplay 相机滚动、缩放与 follow 影响，鼠标命中检测与界面位置稳定。
  - applyBlur() / clearBlur()：对底层游戏/菜单相机施加/移除真实 OpenFL 高斯模糊，受 ClientPrefs.data.shaders 开关控制。
  - makeGlassCard()：统一样式的半透明圆角玻璃卡片（微 1px 白描边、可自定义填充色）。
- 原各子状态手动创建的相机（Results / ScoreHistory / Pause / 设置弹窗）全部迁移到 UIScreen.createScreenCamera()。

#### 暂停界面（source/substates/PauseSubState.hx）

- 改用独立屏幕空间相机 + 背景高斯模糊（半径 8），暂停时背景更柔和。
- 修复 slideGroup 透视效果下鼠标命中偏移：命中检测现在考虑 scale / origin 变换（之前只补偿 x/y 偏移，缩放后按钮点击区域错位）。
- 微调 3D 视差参数（偏移 16/10 → 12/8，缩放系数 0.008 → 0.005）。
- 恢复暂停（resume）与 destroy 时还原背景相机滤镜，避免模糊残留。

#### 设置界面（source/options/OptionsState.hx、新增 source/options/OptionPopupSubState.hx）

- 新增模态弹窗 OptionPopupSubState：
  - 字符串选项：回车/点击打开下拉列表，方向键或鼠标悬停移动高亮，回车/点击确认，ESC/返回取消。
  - 数值选项：回车/点击打开滑条（Slider），左右键或鼠标拖动改变临时值，回车确认，ESC/返回取消。
  - 弹窗是真正的 FlxSubState，打开期间父设置视图暂停，鼠标与键盘输入不再互相争抢；带首帧输入跳过保护（避免打开弹窗的同一帧回车/点击立即确认或取消）。
  - 玻璃卡片面板 + 弹性进出动画，点击面板外区域可直接取消。
- 类别预览模式（updateCategoryPreview）暂时禁用并保留接口，等后续重新启用。
- 鼠标悬停/滚轮逻辑改为仅在未使用键盘时生效（keyboardUsed 判定），修复键鼠混用时选择冲突。

#### 结算界面（source/substates/PlayStateResultsSubstate.hx）

- 新增顶部“英雄卡”（Hero Card）：分数、准确率、评级、最大连击以大字号分区展示，带错峰上浮动画。
- 结算期间冻结底层 PlayState 更新（persistentUpdate = false）并施加背景模糊（半径 10），阻止结算时游戏相机继续平移/缩放；关闭时完整恢复。
- 命中条形图支持 Marvelous 评级：开启 magnificent/marvelousRatings 时 Marvelous 作为独立统计组显示（颜色金色、列在最前），Sick/Good/Bad/Shit/Miss 分布条按实际数量动态布局（行数 > 5 时自动压缩行高与间距）。
- 鼠标命中检测改用 getScreenBounds（考虑缩放与原点），悬停/点击热区不再错位。
- 面板统一改用 UIScreen.makeGlassCard；评分图标移至英雄卡右侧垂直居中。

#### 回放历史界面（source/substates/ScoreHistorySubstate.hx）

- 列表行重设计：行高 40 → 58，每行新增副文本（SubText）、判定图标与悬停行背景，悬停即选中，鼠标操作更直观。
- 双击行播放回放（400ms 内第二次点击同一行）；无回放数据时抖动详情卡提示。
- 删除改为两次 RESET 确认（2.5 秒内第二次按下 RESET 才执行删除，ESC / 超时取消），新增 deleteConfirm 多语言文案。
- 界面整体使用独立屏幕相机 + 背景模糊（半径 9），开启 shaders 时背景透明度自动降至 0.68。
- 修复删除条目后列表与选中状态刷新。

#### Trace 系统（source/mohong/TraceConsole.hx、source/mohong/TraceManager.hx）

- TraceManager 控制台输出改为默认关闭：Windows 上 Trace Console 为显式开关（启动时不再静默向终端刷屏），其他桌面 sys 目标保留原有 stdout 行为。
- 新增控制台可用性检测（setConsoleAvailable / isConsoleAvailable，Windows 经 Windows.hasConsole 探测），无输出目标时跳过格式化开销。
- 新增控制台突发限流（consoleRateLimit 默认 200 条 / consoleRateWindow 0.1 秒），超出部分仍记录环形缓冲但不再刷屏；已有 TraceConsole 监听器时不再重复输出。
- Main.hx / TitleState.hx：Windows 桌面在偏好加载完成后应用 Trace Console 开关（TraceManager.syncWithPrefs）。

#### 谱面与 Note（source/Note.hx、source/states/PlayState.hx）

- 0.6.3 自定义 Note 兼容：EventNote / PreloadedChartNote 新增 noteSplashTexture / noteSplashHue / noteSplashSat / noteSplashBrt 字段，Lua 可对单音符设置自定义溅射皮肤与颜色；仅在 Lua 显式设置时覆盖（null 表示未设置），未设置时保持 noteType setter 算出的轨道色溅射，避免普通 Note 被覆盖成全零颜色。写入顺序放在 noteType setter 之后，避免 setter 覆盖自定义溅射颜色。
- 修复 isGFSide 判定：旧版谱面（isNewVer = false）中 GF 场景音符的 isGF 计算错误（gfSec && rawData < noteAmmo 在 playOpponent 反转后判断失误），改为 isGFSide = gfSec && (gottaHitNote == mustHit)。
- 修复 0.7.3 / 1.0.4 兼容模式血条图标层级：073/104 的 Bar 是 FlxSpriteGroup，部分角色切换后图标会被血条背景盖住；新增 forceHealthIconsAboveBar()，在构建与角色切换（boyfriendName / dadName 变化）时把图标移到 healthBar 之后，确保图标始终在血条上层。

#### HScript 与其他

- Config.hx：导入白名单格式简化（去掉 #if !DOCUMENTATION 与 MODCHARTING_FEATURES 条件包裹），统一列出允许 import 的包前缀。
- 多语言：ScoreHistorySubstate 新增 deleteConfirm 文案，instructions 更新为“上/下/悬停选择、ENTER/双击播放、RESET×2 删除”。

---

### 2026年8月23日

- 修复安卓 Pad-Custom 按键自定义拖拽粘手/脱不掉的问题：将全局单点拖动状态重构为按触点（touch point）独立跟踪，支持多指同时拖动多个按键；只有发起拖动的触点释放才结束拖动，其他触点不再抢占。
- 修复拖动时按键可被拖出屏幕外导致丢失的问题：拖动与读取旧存档位置时均限制在屏幕范围内。
- 修复切换控件模式/Reset/退出时未清理拖动状态的问题，并增加异常触点/失效拖动残留的自动清理。
- AndroidControls 读取/写入自定义按钮位置时增加空值与长度兼容，避免旧存档或按钮数量变化导致异常；切换控件时清理残留的 virtualPad/hitbox 引用。

#### 音符与长条修复（2026-08-23 补充）

- 修复上滚（upscroll）时 TAP 与长条头部之间的空隙：移除非原版的上滚专用偏移（+55 / daPixelZoom*9.5），使上滚与 0.6.3 原版一致——原版对上滚长条不做额外偏移（仅靠 distance 摆放），已在 PC 与安卓双端验证正常。修复同步到游戏内（PlayState）与编辑器试玩（EditorPlayState）。
- 安卓下滚长条的亚像素接缝防护：非像素长条每段在构造时额外加约 2px 长度，使相邻段（含 TAP↔长条起始）必然重叠，避免分数 scale.y + 非 AA 时 GLES 上出现的细分缝；帧无关、无逐帧开销（保守防护，以安卓实测决定是否保留）。
- 修复 Hurt Note 长条在经过判定区（ARROWS）时即便未按下也会消失的问题：长条裁剪（clip）条件不再把 ignoreNote（Hurt）音符当作“已命中”而提前裁剪；只有必须按的轨道在真正命中（wasGoodHit）后才裁剪，与 0.6.3 原版行为一致。
- 修复“虚空按下”/幻按（未触碰屏幕却显示按键按下）：在释放轮询中增加反卡键复位——若某轨道当前确实未按住（多绑定/触摸释放丢失）但 strum 仍停在 'pressed'，则强制回 'static'；仅在确实未按住时才复位，因此不误伤长按/真按住。⚠ 尚未在安卓设备上验证，待实测确认。

---

### 2026年8月25日（万级 Note 极限性能优化 + 安卓触控修复）

#### 万级 Note 极限性能优化

针对上万 Note 密集谱面的掉帧问题，落地 H-Slice 风格优化体系（默认全关，可在「图形设置」按需开启）：

- 新增「性能模式」总开关及子项：批量跳过期 Note / 快速 Note 排序 / 最大同时音符数 / 游玩期禁用 GC；总开关开启后启用批量结算、弹窗与溅射合并、生成节流等极限优化；
- 离屏剔除（off-screen culling）+ 可视物化地平线 + 回池复用（object pooling）：屏外音符零更新零绘制，内存与 CPU 只随同时存活数增长；
- 命中与渲染热点全面降阶：存活紧凑列表、O(1) 组追加、下标/三角函数缓存、中性色免 shader 合批（同贴图数千音符合并为 1 次 draw call）；
- Botplay 到点音符走数据层批量结算，表现层按帧合并，极限 NPS 不再进入死亡螺旋；
- Change Mania 时间线缓存，谱面加载不再随事件数平方增长；
- 兼容性：有 Lua/HScript 时回调语义保持原版不变，关闭开关即回到 stock 行为。

#### 安卓触控修复（Hitbox 钢琴键「按下不松开」「无法按下」）

根因定位：Lime 底层切换到 SDL3 后，系统手势（导航条边缘滑动、预测性返回、防误触、通知栏下拉等）抢走触摸时，Android 会发出 ACTION_CANCEL，SDL3 将其映射为新增的 SDL_EVENT_FINGER_CANCELED 事件；而 Lime 的 SDL3 后端此前只处理 DOWN/UP/MOTION 三种手指事件，取消事件被整体丢弃。SDL 内部已删除该手指，但上层（lime → openfl → flixel）的触摸状态永久停留在「按下」——表现为按键不松开；此后同一指针 id 被系统复用再按时不再产生按下边沿——表现为无法按下。两个症状同源。（SDL2 时代无此问题：上游根本未定义 ACTION_CANCEL 的处理。）钢琴键 Hitbox 手指常驻屏幕底边手势区、多指连打触发掌压拒绝，使取消事件在高版本安卓上高频出现。

三层修复（纵深防御）：

- Android Java 模板（SDLSurface.java）：在进入 SDL 前把 ACTION_CANCEL 转译为 ACTION_UP，所有被取消的手指走正常释放路径，恢复与 SDL2 一致的行为；随下次 APK 构建直接生效，无需重编原生库。
- Lime SDL3 后端（SDLApplication.cpp）：补上 SDL_EVENT_FINGER_CANCELED 分支，按 TOUCH_END 分发给上层，根治取消事件丢失；下次重编 Lime 原生库后叠加生效。
- 引擎按钮层（android.flixel.FlxButton）：快速点击恢复——按下+抬起落在同一帧窗口内时，flixel 只剩 justReleased 边沿而无任何 justPressed 帧，原逻辑会丢掉整次点击（表现为有概率无法按下）；现补发一次完整的按下/抬起回调，快速连打不再丢键。仅触摸平台启用，多相机遍历防重复触发，槽位被占用时不干扰。Hitbox 与虚拟手柄共用该按钮类，一并受益。

（你知道吗？我是讨厌先更新公告的，还是交给AI吧）

---

### 2026年8月27日（渲染/帧率优化收尾）

- 修复 SDL3 帧调度超速与抖动，改用墙钟调度 + 高精度时钟。
- 增加 uniform 上传缓存、override 槽位缓存、drawQuads 可选快路径、顶点色合批。
- Android 剥离 GLES 非法 uniform 初始化；进歌前主动 GC 降低游玩首段卡顿。
- FlxText 按缩放倍率重栅格化，修复窗口放大后字体模糊

---

### 2026年8月27日（崩溃报告与诊断增强）

- 崩溃报告全面增强：新增 SystemDiag 报告构建器，崩溃 dump / 复制 / 保存统一包含系统信息（OS/CPU/内存/显示器）、Lime 渲染上下文（类型/版本/属性）、GPU 信息（Vendor / Renderer / GL Version / GLSL / 驱动版本 / 扩展列表）、运行时状态（draw call / FPS / 图形缓存 / 当前界面与歌曲）以及最近 400 条游戏日志；报告里的引擎名称统一为 SeiunEngine。
- 新增 GL 错误哨兵（GlErrorWatchdog）：渲染帧轮询 glGetError，渲染器驱动报错（如 GL_OUT_OF_MEMORY / GL_CONTEXT_LOST_WEBGL）会写入日志并随崩溃报告输出；相同错误去重，防止错误风暴刷爆日志。
- 新增原生崩溃钩子（NativeCrash）：Windows SEH 记录异常码、出错指令指针、访问目标内存指针、寄存器与出错模块；Linux/macOS 捕获 SIGSEGV/SIGABRT 等并记录 si_addr 内存指针与 backtrace —— 原生层硬崩溃不再无痕闪退，日志会被下一次报告原样收录。
- 新增心跳文件（crash/heartbeat.txt）：每 5 秒记录当前状态/帧率/内存/GL 错误（变化时才写盘），进程被驱动层直接杀掉时也能指认崩溃位置。
- 崩溃堆栈采集增强：非 FilePos 的栈项也保留进报告，为空时回退当前调用栈。

---

### 2026年8月28日（构建小修）

- 修好 macOS arm64 的工具链后，CI 里把 hxcpp 缓存重新打开了，Mac 构建能快一点。
- 顺手修了"性能模式"的锅：关掉性能模式（perfMode）时行为跟原版完全一致，不会因为之前的优化把 shader 或 off-screen culling 偷偷改掉。

---

### 2026年8月30日（0.2.1hotfix）

#### 大杂烩（fix bugs）

- 新增 **Turbo 模式**（默认关）：粪谱终极方案——开启后强制 botplay，高密度段落走预计算聚合 + ghost note 合并 + 数据级批量结算，不再真的物化几万个 sprite。顺带做了字符串驻留和 Note 字段重排（按类型连排省对齐空洞），百万级谱面能省几百 MB 内存。
- 图形缓存重做：AsyncGfxLoader / GfxLru / GfxPolicy 这一轮把解码和打包挪回主线程、按帧小批量处理，加载界面不再一顿一顿；缓存 key 和别名注册也理顺了，淘汰不再误杀还在用的图。
- 相机改动回退：camGame 用回 FlxCamera、camFollow 用回 FlxPoint，PsychCamera 的指数平滑和 freezeCamera 都撤了，回到 0.6.3 原版的相机行为。
- 联机侧：server.zip（15KB → 33MB）和 online.zip 更新；PlayState 联机逻辑加了一堆——spectate（观战）、角色 skin 替换 + 头顶 nameplate、start gate、房主暂停权限文案。
- ⚠ 先声明一下：目前的联机我压根就没想编译进游戏（ONLINE_ALLOWED 还是注释掉的），因为它真的太一坨了，你们别抱期待，也别问什么时候上。代码先放着占个坑而已。
- PlayState 按键检测改为预分配缓冲 + 防重入保护，安卓上不再每帧新建一堆数组。
- 修了 PsychUIDropDownMenu 在滚轮 / 重新挂载下的定位问题，顺带修了编辑器、暂停菜单、LoadingState 的一堆小问题。
- 新设置项：Turbo Mode、Note RGB Shader。

#### GitHub 更新检查重做（fix too）

- 新增 GitHubAPI.hx，封装了 GitHub REST API（releases / tags / commits / issues / PR 都能查），带版本号比较。
- 检查更新从拉 gitVersion.txt 改成查 GitHub Releases，新增 prerelease（是否接受预发布版）选项；主菜单显示"有新版本"，OutdatedState 也重写了。
- 版本号升到 0.2.1hotfix；CHECK_FOR_UPDATES 改为桌面 / 移动端都参与编译（之前只在联机开启时才编译）。

#### 安卓权限弹窗本地化（android）

- 安卓 All files access、悬浮窗（overlay）权限弹窗不再硬编码中英文，改为等语言加载完再用引擎自己的多语言对话框弹。
- Dialog 加 cancelable 支持，设置备份对话框改用新弹窗（"备份 / 稍后"按钮走本地化文案）。
- 新增 Android.json（简 / 繁 / 英）语言文件，SeiunOverlay.java 也精简了一圈。

#### 晚上加修（又修了几个 bug）

- 新增「清除图片缓存」按钮（图形设置里）：按 Enter 释放所有未被引用的缓存图片（包括 LRU 停靠池），弹窗报告释放了几张、多少 MB。
- 修复 copyKey 传 null 崩溃：键位缺失时返回空数组并记一条警告，不再直接炸。
- LuaJIT panic 钩子：Lua 脚本未受保护错误（无 pcall 边界）不再无声杀进程，会先写 crash 日志（Lua 错误信息 + 调用栈）再退出；Windows 上 CRT 的 abort / 纯虚调用也走 native crash 记录，SEH 路径补了 dbghelp 栈回溯（exe 旁放 PDB 就能解析出函数名和行号）。

（今天的活就这些……日志老规矩，还是 AI 代笔。）

---

### 2026年9月12日（0.2.2）

#### 崩溃排查链路（本次重点）

- **修好了"崩溃日志查不出东西"的根因**。9 月 5 日之后所有 `crash/native_crash_*.txt` 里的堆栈都变成了 `<sprintf>+0x20413` 这种鬼东西，一度让人以为是随机的内存损坏。实际原因有三个，串在一起：
  1. `Project.xml` 里的 `HXCPP_DEBUG_LINK` 从加上那天起就是**注释状态**，链接器拿不到 `/DEBUG`，exe 里没有 CodeView（RSDS）记录；
  2. 没有 RSDS，dbghelp 无法按 GUID 把 exe 和 PDB 配对，只能退化成读 PE 导出表 —— 而整个 exe 只有 179 个导出，恰好有个 `sprintf`，于是它后面 132KB 内的所有地址都被标成了 `<sprintf>+0x...`；
  3. `obj/ApplicationMain.pdb` 停留在 8 月 30 日，而 exe 每次改动都会重新链接，符号与代码早已不同步。
- **正式构建改为产出 `.map` 符号表**（`HXCPP_MAP_FILE=ApplicationMain.map`）。这是本次的关键取舍：`HXCPP_DEBUG_LINK` 会让 MSVC 把调试目录数据写进映像，Windows exe 体积从 29.6 MB 涨到 47.1 MB —— 对正式发布不可接受。而 `.map` 是链接器另出的文本文件，**exe 体积一字节不变**，却带着每个函数的精确地址，足够把报告里的 `Fault offset` 还原成真实函数名。实测 exe 为 29,649,408 字节，与改动前一致；`.map` 44 MB（压缩后 4.7 MB）。
- **崩溃报告新增构建指纹**：报告头现在会写 `Build:`（exe/pdb 的尺寸、mtime，以及 exe 头尾各 64KB 的 FNV-1a 哈希）、`Main module:`、`Main module stamp: TimeDateStamp=...`、`Matching PDB:` 是否存在，以及最关键的 `Symbols: SymType=...`。有了 `SymType`，报告自己就会声明符号是否可信 —— `SymType=0 (SymNone)` 时内联的帧名一律不可信，只能拿 `Fault offset` 去查 `.map`。这些信息对 SEH 与 SIGABRT 两条路径都会写入，并且放在磁盘写入的第一阶段，即使后面 dbghelp 自己崩了也留得下来。
- **新增两件排查工具**：`tools/mapresolve.py`（读 `.map` 把偏移解析成函数名，支持批量扫 crash 目录）与 `tools/symbolize-crash.ps1`（一键封装：自动定位 `.map`、先打印每份报告的构建指纹、再批量解析）。

#### CI：发布构建产出调试符号

- 桌面端三个构建（Windows / Linux / macOS）现在各自产出一个**独立的 `*-symbols` artifact**（保留 90 天），内容是 `.map` 加一份使用说明。
- 发布打包时符号包被单独分流到 Release 的 `crash-symbols/*.zip`，**绝不会混进玩家下载的游戏压缩包里** —— 游戏 zip 内仍然只有纯游戏文件。
- 故意**不收集 PDB**：正式构建链接器不跑 `/DEBUG`，`obj/` 里那个 PDB 是旧构建遗留的，带上只会让人拿去解析然后得到完全错误的函数名。

#### 修掉三个已确证的崩溃源

- **空窗口句柄导致的 native 空指针解引用**（`NativeWindow.close()` 清空了 `handle` 却没清 `context`，渲染循环继续对 NULL 调 `ContextFlip()`）。这条与 8 月 28–30 日的崩溃特征精确吻合：报告里 `param[1]` 恰好是 `0x8` / `0x10` / `0x30`，也就是结构体成员偏移量 —— `this == nullptr` 的签名；8 月 30 日那天 19:35 / 19:36 / 19:37 / 19:47 / 20:00 连续崩了 5 次且寄存器状态几乎一致，是确定性路径而非随机损坏。
- **SDL3 的 `SDL_GetBasePath()` 被错误 `SDL_free`**：SDL3 里这个返回值是 SDL 内部的进程级静态缓存，只由 `SDL_Quit` 释放。迁移时只补了个 `(void*)` 强转，导致第二次调用读已释放内存、退出时必然 double free。
- **strum 组越界取 `members[idx]`**：hxcpp 的 release 构建下越界读返回 `null` 而不是崩溃，随后解引用直接 AV。这一类在本项目已经崩过两次并手工补过，还有 9 处未加保护。顺带修掉空组时 `strumIdx %= members.length` 的除零。

#### 说明

- 「更新与渲染分离」这条怀疑方向经核查**不成立**：`RenderThread` 是空壳（多线程渲染早已移除），`drawWrapper` 在 `Main.hx` 与 `ClientPrefs.hx` 中都被置空，渲染始终在单线程主循环里。真正的 update/draw 重排发生在 lime 的原生帧循环，不在 flixel。
- 相机特效完成回调里销毁相机后无保护解引用 `flashSprite` 的问题也一并修了。
- 完整的排查记录（含证据、代码位置与取舍理由）保存在内部文档里，不随引擎仓库发布。
- ⚠ **lime / flixel 两处补丁必须上游化到 `mohong2/lime` 与 `mohong2/flixel`**，否则 CI 重新克隆依赖后，打出来的包又会带上这两个缺陷。

（2026-09-12，日志还是 AI 代笔。）

---

### 2026年9月26日 – 10月7日（0.2.2 Pre-Online.2）

> 本条目记录 0.2.2 Pre-Online.2 整个开发周期的最终成果；周期内被后续提交取代或撤销的中间状态不再单独记录。玩家向的完整公告见 `release-notes/0.2.2preonline2.md`。

#### 联机：SQLite 服务端、游戏内开服与局域网发现

- **服务端存储换成 SQLite**：WAL 模式、单连接 + 唯一数据库互斥锁、按 `user_version` 版本化的只增式建表（13 张表）；首次启动自动导入旧 JSON 并把原文件改名为 `*.imported-<时间戳>`（绝不删除）；token 只存 HMAC-SHA256 哈希、常量时间比较、支持过期与撤销；`/dev/urandom` 优先（无该设备的平台走 HMAC DRBG）；结构化 JSON Lines 日志按天切分；新增只读 `GET /api/health` 与 `--log-dir` / `--log-level`；可编译零运行时依赖的独立 `SeiunServer.exe`，neko 目标用法不变。HTTP 面的对外签名、错误串、排序、分页与 id 格式逐字保持。
- **管理控制台网页编译进服务端**（部署目录存在 `server/web/` 时仍以磁盘为准）；公告字数按字符截断（500 字符 + 2048 字节上限），磁盘上已损坏的值自动修复，同类 12 处字数上限全接口排查；持久化公告随 `GET /api/front` 返回，客户端固定区域渲染，CJK 折行按字符。
- **游戏内开服（LAN HOST）**：内嵌服务端在游戏进程内绑定 2567 / 2568，端口被占向上顺延、房间码带局域网 IP、免账号加入、本机只读网页控制台（独立服务端对应 `--console-local-readonly`）、Android 尽力而为开服；停止释放端口，可反复开停。
- **局域网发现**：服务器列表新增「搜索本网络中的服务器」——监听 UDP 2569 广播 4 秒列出发现的服务器，勾选后 Add Selected Servers 才写入列表（已存在的不可勾选，可整批丢弃）；删除了按网卡枚举本机 IPv4 的「Use This PC (LAN)」行（多网卡 / WSL / Hyper-V 虚拟网卡会各占一行，点了还会直接改掉当前选中条目的地址）。服务器地址探测三态：可达 / 超时 / 协议不符。Android 放行明文 `ws://` / `http://`；Windows 开服打印防火墙放行命令。
- **房间暂停策略**（仅房主 / 任一玩家默认 / 保留旧逻辑）由服务端唯一仲裁：暂停带发起者回显，恢复只对持有者生效，持有者离开 / 掉线 / 结束歌曲时自动广播恢复。双方各有自己的评分弹窗（远端锚定各自角色一侧并夹在 5%~95% 屏宽，同侧玩家横向拉开）。
- **开始闸门**：房主开始后全员进谱面等待页（按 ACCEPT / 手柄 A / 点提示文字算准备），触屏端出现 A 虚拟键，房主 start 到达才进倒计时。
- **联机界面导航统一**（OnlineNav / NavRepeat，键盘与触屏同一套）；联机对局逻辑从 PlayState 拆分到独立的 PlayOnline 模块；联机时全部运行期优化只改本局内存值、退出按快照恢复；分段谱面联机明确拒绝并提示；联机谱面分析按每个音符自己的 mania 快照取键数。
- **修复联机快速切换界面导致的原生崩溃（安卓端尤其高频）**：内嵌服务端的 HTTP 层原为「每个连接新开一个线程」，而游戏进程内嵌开服时（LAN HOST），客户端每切一次界面都会发起公告 / 在线人数等请求——玩家连按退出时短命线程以风暴频率生灭，命中 hxcpp 分代 GC 的 per-thread 引用记录块（`mOldReferrers`）与线程生灭的竞态，GC 写屏障随后解引用已损坏的块指针（三份现场崩溃栈一致指向 `StackContext::pushReferrer`）。双管齐下：其一，内嵌 HTTP 层改为固定 4 个连接工作线程 + 阻塞队列（`HttpServer`），线程数不再随玩家操作涨落，客户端侧的联机任务也收口到固定 8 线程池（`online.backend.Thread.run`），下载类长任务不再各起一线程；其二，关闭 `HXCPP_GC_GENERATIONAL`（Project.xml）——分代模式本就不是 hxcpp 上游默认，关闭后 GC 写屏障整体编译为空操作，本次崩溃的确切路径不复存在（代价：minor GC 退化为全堆标记，大谱面下 GC 停顿变长；独立服务端从未开过分代模式，同一套存储层压测十万请求稳定，旁证了这一选择）。

#### 谱面：缓存、流式与内存

- **巨谱缓存 `chart_cache/`**：流式谱面 Note 循环的输出（完整 DTO）按列压缩落盘（`.skel` / `.notes`），命中即回放、跳过骨架扫描 / 逐小节解析 / 折叠 / 排序；失效判据是「每个分段文件大小 + 修改时间 + 调用方配置串」，同一张列表 1.78 GB → 几 MB，读写最多持 1 MB 块。实测 45 GB 的 amphotercity（2,064,278,444 taps → 4,291,710 代表点）缓存为 `.skel` 14,215,997 B + `.notes` 12,855,326 B。设置：Huge Chart Cache / Compress the Chart Cache / Clear the Chart Cache（三语）。
- **选歌预览跳过**：流式尺寸的谱面不再为预览解析整张谱面（预览只需要歌名与 `needsVoices`）。
- **分段谱面识别放宽**：任意起始编号（0 / 1 / 5 / 100 均可）、断号只记录不作废、编号文件少于 2 个按单文件；`<song>.json` 闸与 `.parts.json` 清单不变；11 例回归（合成 7 + 真实 4）全部符合预期。同一首歌拆成多个 `<song>-<n>.json` 可以作为一首完整的歌游玩。
- **无 `events` 字段也可流式**：字节级特征判据，slide20（2,105,875,665 B / 153,955,328 notes）不再退回整份 DOM 解析（那正是 Freeplay 卡死的根因）。
- **Note 列式存储**：数值字段逐字段成列、全谱恒定的字段提升为标量（不分配列）、首次出现分歧才回填——每条 Note 约 358 B 的占用压到几十 B；列按倍增扩容、边解析边写入，hxcpp 块池不再被撑到全谱体量；`unspawnNotes` 的脚本写入经列存储照常生效。
- **计数器换 Int64**：谱面与命中计数超过二十亿不再溢出。
- **Note 材质复用判断免分配**：原先池化复用时每条 Note 都要现拼一个材质 key 字符串再比较；改为逐字段比较，重载路径不再产生字符串垃圾。
- **弹窗 / 溅射 / 物化 / 排水预算按时间计费**：这些预算原本是「60 fps 设计速率、按绘制帧重置」，帧率上限越高每秒实际预算越大（360 fps 上限下为设计值的 6 倍）；现在按 elapsed×60 累积、按整单位消耗、单帧封顶 —— 60 fps 及以下行为逐位不变，更高帧率每秒付出的速率与设计一致。
- **评分弹窗免分配化**：贴图键（评分 / 数字 / COMBO）构建一次缓存复用，不再每次命中每个精灵现拼字符串；连击数字写入复用缓冲；淡出不再依赖 FlxTween 全局管理器，改为池化记录由 PlayState 逐帧推进（暂停时与移动一致冻结，联机双方各自的弹窗各自推进），稳态零分配。
- **图形清理重构**：`purgeUnusedGraphics()` 由「每清一个 key 就重扫全部缓存」改为单遍收集 + 批量移除，长会话下原有的周期性主线程冻结消失；被清理图形注册的 Sparrow 图集帧缓存一并逐出，不再留下「僵尸图集」（此前模组动态生成的精灵会渲染成空白并陷入脚本报错循环）。

#### 图形与渲染

- **Haxe 4.3.7 工具链迁移**：编译器与 API 层 430 整体升级，hxcpp 用引擎维护的 haxe-4.3 分支，CI / 发布构建对齐；引擎代码适配 4.3.7 的 API 变化。
- **图集重打包加固**：像素写入统一走边界检查的 `blit()`（越界跳过并告警计数）；打包画布按请求尺寸校验（平台钳制分配即放弃重打包、保留原图）；CPU 副本已释放的源图不参与 `copyPixels`（整体放弃重打包，绝不产出透明图集）；跨线程发布由主线程持有；强制 GC 前静默异步工作线程——关掉「堆写坏、几秒后在 GC 线程崩溃」的一类隐患。
- **移除异步图片加载**：删除 AsyncGfxLoader 与「异步图片加载」设置，位图解码统一回主线程按帧小批量处理（GC 崩溃排查的最终结论：跨线程发布位图是堆损坏源，不再保留这条风险）。
- **分离 update / draw + 空闲帧跳过重绘**：无逻辑步的绘制帧直接重新呈现已录制的绘制命令，不再整帧重建；直写 `camera.canvas.graphics` 的代码请调用 `FlxGame.invalidateDrawCache()`。
- **窗口模式统一**：新增 `backend.WindowMode`（windowed / fullscreen=真实 SDL 显示模式切换 / borderless=去装饰+贴满+顶置），启动路径与设置页共用同一实现。
- **PsychUIDropDownMenu 重构**：滚轮 / 重新挂载下的定位等历史问题收敛到新实现；Dialog / NativeMem / TraceManager 配套调整。
- **回放录制输入检测 O(1)**：inputTick 单调计数器取代每帧 186 次按键探针（实测每帧 1547 ns → 0.9 ns）。
- **侧边 HUD 在 perfMode 下固定宽度 + 节流**：Botplay / Turbo 下计数每帧变化、按值跳过永不命中，比例字体的 autoSize 每次重排都会新分配一张位图与 GPU 纹理；现在侧边计数使用固定 fieldWidth（单行、永久复用同一位图），perfMode 开启且未强制原版重写时读数按 20 Hz 节流（perfMode 关闭或开启 `Stock HUD Text Rewrite` 时保持逐值精确刷新）。

#### 视频：播放与录制

- **播放**：接入 hxvlc 2.3.1（libVLC 3.0.23），移除树内影子副本；`startVideo` 支持 1.0.4 完整参数（canSkip / forMidSong / shouldLoop / playOnLoad）；保留 hxcodec 风格 FlxVideo / FlxVideoSprite / VideoSprite 包装层与 VideoPreloader，模组按老习惯调用。
- **录制（桌面端）**：F9 或「开歌自动录制」把游戏画面 + Inst / Voices 混音送进 ffmpeg 管道，输出到 `render_video/`；编码器 x264 / NVENC / AMF / QSV / x265 / VP9 / VP8，码控 CRF/CQP / VBR / CBR；**1 帧 = 1/fps 秒的歌时**（帧号从 Conductor 时钟推导，暂停 / seek / 变速自动对齐，掉帧不改时长）；渲染期钉死帧率 + fixedTimestep；环形缓冲满时等待编码器而不是丢帧；预览渲染跑全流程不写文件用于校时；RenderIndicator 状态角标；每次渲染旁写 `.log`（设定、帧数、速度与 ffmpeg 的 stderr）。新增「渲染」设置页（9 项，三语）。

#### 脚本：1.0.4 兼容、HScript 1.3.0 与诊断

- **1.0.4 Lua API 全量对齐**：Psych 1.0.4 放宽的 62 处参数签名全部跟进（doTween* / noteTween* 的 ease、mouseClicked/Pressed/Released 的 button、getMouseX/Y、makeLuaText、startVideo 四新参、precacheImage 的 allowGPU、setProperty 系的 allowInstances、getPropertyFromGroup / setPropertyFromGroup 的 allowMaps 等）；回调实参对齐（eventEarlyTrigger 收 `(event, value1, value2, strumTime)`、onTweenCompleted(tag, vars)）；新增 getFileTranslation / getTranslationPhrase 与 1.0.4 `data/<language>.lang` 读取器（与引擎 JSON 语言表合并、{1}/{2} 替换）；移植 Paths.getAtlas / Paths.getAsepriteAtlas（'auto' 真正自动探测图集格式）；HScript 侧新增 getModSetting 与可选参 keyJustPressed / keyPressed / keyReleased。类型放宽（addAnimation 接受数组或 '0,1,2' 字符串、动画帧率 Float、setGraphicSize Float）、removeFromGroup 同时支持两种方言、版本相关默认值（setHealth、setObjectCamera、loadFrames 等）统一走 CompatEngine——0.6.3 / 0.7.3 模式行为逐字不变。
- **模组 JSON 与 1.0.4 同口径解析**：pack.json、stages/*.json、data/settings.json、images/gfDanceTitle.json 走宽容优先解析（tjson 先、严格兜底），尾逗号与 `//` / `/* */` 注释不再炸；歌曲 / 角色 / 对话保持严格（与 1.0.4 一致）。实测修复某模组因 pack.json 尾逗号从未被注册为全局模组（全局模组列表 2 → 3）。
- **close() 不再关错脚本**：linc_luajit 的回调表静态共享，「后创建的实例」覆盖同名回调，close() 可能作用于别的脚本（某模组自定义菜单永不出现的根因）；回调执行期记录发起实例，close() 作用于它，日志留 `CLOSE() <script>`。
- **callMethodFromObject 空参数不再调用**：instanceArg 先解析 modchart 精灵 / 文本再回退变量表，未解析时跳过调用并警告——修复某模组 mouse.overlaps 传 null 的 0xC0000005 原生崩溃。
- **getDataFromSave 补上默认值**（0.7.3 / 1.0.4 语义：缺字段回退调用方默认；0.6.3 保持原样）——修复 1.0.4 模组「选项菜单建一半、ESC 无效」一类问题；allowMaps 读取恢复；tagged 音效按 `sound_<tag>` 双写；无 tag 的 stopSound / pauseSound / resumeSound / getSoundTime / setSoundTime 作用于 FlxG.sound.music；playSound 失败不再写 null 槽位。
- **脚本加固**：makeLuaSprite 等缺 tag 安全跳过；safeColor 统一十六进制转换（非法色 → 不透明白，严格校验仅 1.0.4 模式）；键盘名小写仅 0.7.3 / 1.0.4 生效；引擎软件光标进游玩前强制关闭、暂停菜单退出时恢复原值；KeyboardDisplay / 侧边 HUD 跟随 scoreTxt.visible 一起隐藏（玩家自己的隐藏 HUD 设置与联机路径除外）。
- **1.0.4 判定名映射**：新增设置「1.0.4 Judgement Names for Mods」（默认开、仅 1.0.4 模式生效）：脚本读到的 marvelous 改写为 sick（与 1.0.4 同窗命中的叫法一致），按名字映射判定的模组不再准确率 / 连击错乱；引擎自身判定、计分、结算、联机与回放不变，`Note.ratingRaw` 保留真实评级。
- **脚本报错不再停用整个脚本，且默认永不静默**：报错上限默认 0 —— 无论报错多少，每条都照常打印；设为正值后连续报错才触发静默（一条汇总 + 限流），其余回调照常运行；一次性回调报错只打印。原先「每帧回调错满 50 次整个脚本被关闭（连 onEndSong 都收不到）」的行为取消。
- **回调热路径**：onStepHit / onBeatHit / onSectionHit 对 HScript 的重复派发修复（基类与 PlayState 各派发一次 → 恰好一次，次数 / 位置 / 参数与旧实现一致）；TitleState.beatHit 同；RecalculateRating 每命中 7 次脚本变量推送合并为 2 次；节拍回调参数复用 backend.Scripts 槽；CompatEngine 版本判定 O(1) 缓存（isModern 不再每次线性扫描 + 双解析，另加 refresh()）。
- **音符排序默认快路径**：fastSort 更名 stockNoteSort 并反转默认——默认只排 living+visible（原 fasterNoteSort），仅联机显式要求原版全量排序；离线基准 500~8000 槽位相差 7~26 倍（2000 槽位 0.607ms → 0.083ms 每帧），400 组随机对照可见音符绘制顺序 0 例差异；旧存档的 `fastSort=false` 自动升级到快路径。
- **新「脚本优化」设置页**：Reuse Script Callback Arguments（默认开）、Stock Event Drain / Stock BPM Lookup Objects / Stock HUD Text Rewrite（默认关，为读写 eventNotes / 持有 BPM 对象 / 直接改 HUD 文本的脚本保留原版行为）。
- **脚本诊断 `logs/script_log.txt`**：每次启动重建、上限 2 万行；记录加载的 Lua 脚本路径、扫描的脚本目录（缺失标 MISSING）、每条脚本报错（脚本 + 回调 + 原始错误）、生命周期回调接收情况（onCreate / onCreatePost / onDestroy / onSongStart / onEndSong / onPause / onResume 等白名单）；[scan] 行写明 currentMod 与 globalMods（决定模组脚本搜不搜 `data/<song>/`）；[save] / [snd] 行分别诊断存档字段与 tagged 音效查找。
- **HScript 引擎 hscript-seiun 1.3.0**：解析器 / 解释器性能重写（解析约 +16%、执行约 +38%）；新语法 or-pattern、守卫通配 case、解构扩展、泛型函数、map comprehension、通配 import、对象展开；修复带参脚本类构造、super.new、Math / Std / Map 解析、ClassExtendMacro 弃用告警、hscript.Bytes（带版本号格式）、hscript.Async、Printer 11 处缺陷。

#### 玩法：Botplay NPS、结算与 Note 长条

- **Turbo / Botplay HUD**：Turbo 标签 `TURBO BOTPLAY`；分数行 `Notes: 对手 + bf = 合计 | NPS | HP`；NPS 用单调时钟 1 秒滑动窗口（100×10ms）+ 快起慢落弹道（一帧 5000 的突发约 1.47s 平滑回零），峰值取窗口真值，脚本写 opCombo 不伪造爆发；超长数字紧凑化保证单行。
- **结算界面**：超完美计入音符总数（不再落到 FALSE 兜底图）；评级图标统一装 240×90 框（兜底图 660×256 不再压满卡片）；统计图例 `fieldWidth = 0` 永不换行 + 数字紧凑化（修掉折行在自己文字域上画出的整块纯黑）；camOther 上的 side HUD 与 BOTPLAY / REPLAY / ms / 判定文字一并隐藏。
- **Note 长条几何（模组裁剪帧）**：自定义 arrowSkin 的 trimmed Sparrow 图集长条高度归一化改按图集可见区域高（新增 `Note.sustainContentHeight()` 统一 setupNoteData / initNote / recalcSustainScale / resetNoteScaleForMania 四处公式）；下落模式长条锚点的补偿符号修正（近端落点精确等于 `distance + swagWidth/2 + 0.45*stepCrochet`，与 BPM / 速度 / 是否裁剪无关——原先符号用反导致尾帽深埋长条、BPM 越高越偏）；裁剪上沿改用 `Note.contentTopInFrame()`。默认与内置皮肤逐位不变；实测 Paranoia 模组 `varelt-NOTE.png` 在 150/522 BPM × 1.0/2.6 速度四组组合下长条近端落点全部收敛到 56.0px，尾帽搭接由 69~121px（深埋）恢复到 2.3~5.1px（正常）。

#### 崩溃诊断与符号

- **默认安全模式**：Haxe 层报错自带源文件与行号（行号表生成 / 刷新链路修正，提供 tools/refresh_linemap.ps1）；符号流程与崩溃保护解耦，CI 与发布构建同样保持安全模式；新增 Android 符号化工具 tools/symbolize_android.py；`.map` 符号继续单独随 Release 发布（不进游戏包）。
- **崩溃报告保留 150 行游戏日志**（原约 30 行），原生缓冲扩到 32 KB，报告上下文带当次生效的图形设置。
- **组容器不再解引用已被回收的成员**：成员内存已释放时将其移出容器，而不是继续取用。

#### 设置、本地化与杂项

- 新设置页：「渲染」（录制 9 项）、「脚本优化」（4 项）；谱面缓存三项；各项简中 / 繁中 / 英文文案齐全。
- 选项布局校验脚本基线修好：登记新变量与新增页面、补齐繁中文案、删零引用死键、修掉英文 / 简中渲染页描述的字面 `\n`；三语言键集合一致。
- 三语联机文案同一套键；之前没有按键的 trace 行补上多语言。
- 文件对话框「上一次操作未结束又开新对话框」不再向主循环抛异常整进程崩溃：复位状态、记日志、走 onError 回调；谱面编辑器保存 / 打开链路加固。
- CI / 发布：发布资源写入真实版本号（不再出现空 app 版本）；haxelib git 认证可选且不致命；固定 lime 项目文件路径；Release 正文追加中国镜像与加速链接。

---

### 2026年10月11日 – 11月7日（0.2.2 Pre-Online.3）

> 本条目记录 0.2.2 Pre-Online.3 整个开发周期的最终成果；周期内被后续提交取代或撤销的中间状态（HUD 文本节流与命中表现按帧排队、图形 LRU 缓存与运行时贴图重排、崩溃报告里的自动诊断建议）不再单独记录。玩家向的完整公告见 `release-notes/0.2.2preonline3.md`。

#### 谱面：新容器、快速加载与 64 位计数

- **新增谱面容器 `.chartpack`（SEIUNPK1）**：谱面存成「骨架 + 组流」——骨架除每个 `sectionNotes` 数组的内容外逐字节保留（节对象、未知字段、events、格式都不动），数组位置留一个 NUL；组流按 section 内不同的 `(time, lane, sustain, type)` 各写一条记录加重复次数（varint + zlib）。引擎读 pack 时把一组展开成带 `repeat` 的原始 note，直接喂给折叠器，不再为每个重复音符分配对象。时间落在 BPM 网格上走 tick，否则退回 float64，判定容差 `1e-6 ms`。
- **实测**：工具侧 funeral 全 17 个 JSON `76,765,170,749 B（71.5 GiB）` → `20,834 B`（`3,684,610×`，23.47 s，峰值 392.8 MB）；引擎侧 amphotercity 的 34 个文件 `45,217,329,492 B（42.11 GiB）` → `2,535,680 B（2.42 MiB）`（`17,832×`），33 part / 386,282 section / 约 20.64 亿 note 首次加载 6–8 秒（550,954 代表点）、峰值约 1.7 GB，缓存命中 4.7 秒、约 1.5 GB；32 MB / 1,521,362 note 的切片 `songLoad` 0.04 s（同份 JSON 2.73 s）。
- **工具换代**：`tools/chartpack/chartpack.mjs` 改成流式字节解析（不把谱面读进内存），重复段用「指数倍增 + 二分」的 `memcmp` 快进，分组表用 typed array，并支持 ZIP 直读；新增界面 `chartpack-ui.exe`（中英双语、拖拽、实时压缩比、可选便携版）。容器格式仍为 v1，引擎不必重编；引擎只读 pack，不会自动把 JSON 转 pack。
- **原生扫描与折叠（`source/ChartNative.hx`）**：第一阶段按 part 并行扫描，产出合并骨架、每 section 的 `sectionNotes` 字节区间与精确 note 数；第二阶段按区间读取，worker 解码归一化、单消费线程按谱面顺序折叠，直接产出打包列，worker 上不创建 Haxe 对象。任何异常返回失败并**自动回退 Haxe 路径**。只在 Turbo 或 note 数 > 12,000,000 时启用，含 Change Mania 事件的谱面不走。
- **谱面 JSON 与寻址**：`sectionNotes` 里的垃圾字节不再抛错，改为跳到下一个数组并记录跳过量；单个 part 超过 2 GiB 改用 64 位 `seek` / `tell`（`_hx_std_file_seek64`），不再因偏移截断静默读错；折叠行数上限 6000 万 → 4 亿；骨架缓存升到 `chartstream-scan-v2`，缓存未被完整消费则判损坏重建。
- **游玩计数换 Int64**：分数、连击、各判定桶、Miss 数、总可玩数改 `haxe.Int64`，存档与回放按十进制字符串写、读取兼容旧档的 Int / Float / String。真正的根因不是溢出：`Int64` 交给 `haxe.Json` 会序列化成对象，反序列化抛 `Null Object Reference`，且发生在音频结束回调里、崩溃处理器够不到 —— 表现为「打完歌写成绩直接崩」；`details` 数组恢复成纯数字。Lua / HScript 边界统一转成 number（hxcpp 反射会把 ≥2^31 的 `Int64` box 成对象，Lua 收到 `nil`、HScript 当字符串拼接）。
- **Note 复用与内存**：池化时着色器对象跟着 Note 复用（只归零色相/饱和/亮度），轨道色数组按 `(mania, lane)` 记忆化（原实现每次新建三个 `Array<Float>`）；Turbo 单个可视代表的吸收上限 512 → 65536（与原生折叠器同值）；非流式谱面在 note ≥ 100,000 且由引擎从磁盘读入时，转成打包列后清空原始 `sectionNotes` 并记住重载配方。
- **Note 材质**：新增统一的材质应用入口，修复池化复用跳过 `reloadNote` 时「一部分 Note 不上色」；Hurt Note 的白底图集改走 RGB 色板染色（`0xFF101010` / `0xFFFF0000` / `0xFF990022`），不再无条件找不存在的 `HURTNOTE_assets` 把帧清空，Hurt 溅射也不再沿用轨道色。
- **strum 着色器按需挂载**：8 个空闲 strum 不再各带一个恒等 `ColorSwap`（flixel 按着色器实例分批，八个箭头就是八次 draw，也无法与从不挂着色器的下落音符合批），改为轨道色非中性时才挂、回中性即摘。

#### 图形：图集裁切、调色板与图片内存

- **内存后端重写**：删除 `GfxPolicy` / `GfxLru` / `GfxRepack`（持有强引用、销毁仍被引用的图、强制 GC、运行时重打包，并走出设备相关的 C++ 崩溃路径）。新的 `GfxMemory` 只在上传 GPU 后释放大图（≥512×512）的 CPU 像素副本，读像素时由 OpenFL 自动重解码；不销毁图片、不驱逐缓存、不碰 GC。`GfxSource` 在重解码后立刻移出 OpenFL 的位图缓存，避免「释放」名不副实。
- **图集裁边（第一步）**：把整张图裁到所有帧实际用到的区域，并按同样距离平移帧坐标，`offset` / `sourceSize` / 帧名 / 顺序不变；换图前后逐帧校验 `parent` / `uv` / `offset` / 采样像素，任一不符整体回滚；省不到 0.5% 就放弃。
- **图集重排（第二步：逐帧裁边 + 去重 + 紧排）**：每帧裁到自身不透明边界、相同的图块只留一份、紧密重排进新画布并改写帧坐标，`offset` 按 trim 补偿，精灵位置与大小不变；换图前逐 cell 逐字节比对、换图后逐帧校验并采样，失败整体回滚；省不到 5% 跳过。旋转 / 翻转帧整张回滚。
- **调色板纹理**：一张图不同颜色 ≤ 256 种时改成「8 位索引 + 256 色调色板」，调色板条目就是源位图的 premultiplied BGRA 原始字节，索引采样强制 `NEAREST`，批次数不变。超过 256 色、无 CPU 像素、已上传过纹理、无 8 位索引格式、shader 编译失败、采样校验不一致 —— 逐图退回 RGBA。
- **实测**（Windows debug 启动快照）：解码 85.9 → 82.7（裁边）→ 57.3 MB，GPU 85.4 → 79.4 → 55.6 MB；调色板本身解码 −17.5 MB（−23.4%）、GPU −15.9 ~ −20.8 MB（−22.2% ~ −29.1%），单张合格图 `166.3 → 41.6 MB（−75.0%）`；图集重排在启动 11 张里做了 8 张（−9.6% / −10.0%），代价约 0.50 s；三张真实 mod 图集 467.9 → 117.0 MB（省 350.9 MB）。省的是显存，工作集在噪声内（±3 MB）。
- **GL 提交开销**：openfl 侧缓存 viewport / 纹理绑定 / 属性数组位掩码，删掉冗余 `glEnable`，同一 95-draw 画面 GL 调用 3563 → 1746（−51%）；动态顶点缓冲改原地 `bufferSubData`（装不下才退回 `bufferData`），上到 GPU 的字节不变。
- **选项精简**：删「纹理复用缓存（LRU）」与「运行时纹理重打包」；「大纹理内存释放」改名「纹理内存释放」、阈值 2048px → 512px；「清除图片缓存」说明补上「仍在使用的图不会被动」。

#### 文本：HUD 保持高清，命中不掉帧

- **flixel fork**：`FlxText.regenGraphic()` 的描边从「每个偏移把 TextField 整画一遍」（1 + 8 × `int(borderSize × borderQuality)`，HUD 是 17 遍）改为「描边色栅格化一次 + 位图 blit 盖章」，17 遍变 2 遍且逐像素相同（14 组用例逐字节一致）；新增增量重绘，只重画新旧字符串差异对应的设备像素箱，证明不出安全箱时整行重画；新增输入签名比对，输入未变的重建直接跳过；签名稳定 750 ms 的静态文本合页到共享大图（菜单版本块 8 次 draw → 1 次，整个菜单 14 → 7 批次）。
- **openfl fork**：`TextField.setTextFormat()` 在「单 range、整字段、只改不影响度量的属性」时不再标脏布局。
- **实测**：分数行单次重画 `1594 → 1092 us`（中位 `2023 → 1278 us`）；harness p50/p90/p99 在 1.5x 下 `788/1076/1389 → 185/234/391 us`；颜色改动触发的排版 `148 → 0.3 us`；541 个样本逐像素 0 差异。
- **HUD 文本行为回到 0.6.3 原版**：命中表现按帧排队、各类文本节流、1x 栅格化全部撤销（脚本会读 `scoreTxt`，`onUpdateScore` 要求命中当帧就是新值；1x 会让高倍率窗口文字变软）。`Stock HUD Text Rewrite` 选项随之删除，「脚本优化」页 4 项变 3 项。省下来的性能全部来自上面的库侧补丁，不是「少画」。
- **溅射合批**：中性 `ColorSwap` 不再挂 shader，同屏多个溅射可合批。

#### 崩溃诊断：四条路径、符号文件与一个工具

- **四条路径、一个出口**：`native`（SEH / signal）、`haxe`（未捕获异常到顶层）、`lime:*`（窗口 / GL / 音频 / SDL 初始化失败，发生在 Haxe 之下）、`html5`（无原生对话框，报告渲染进页面）；报告首行带 `Kind:`，不靠文件名猜来源；原生层只留 `native_crash.pending`，下次启动消费后进崩溃恢复界面。
- **报告内容**：`Kind` / `Date`、构建身份（主模块尺寸与 PE `TimeDateStamp`、`Linemap` 是否存在）、原生诊断（系统、GPU 与驱动、环境、进程目录、真实 Win32 错误码，进报告前先快照 `LastError`）、`lime` 模块探针（ndll 存在性与位数、`LoadLibrary` 原始错误码）、已加载模块列表。报告 UTF-8 + BOM，Windows 对话框用 UTF-16。
- **符号包默认产出**：`Project.xml` 去掉 `hxcpp_symbols` 门控，`<postbuild>` 每次构建把本次链接的 `ApplicationMain.map` / `.pdb`（Android 为未剥离 `.so`）**移动**到 `export/symbols/<platform>-<mode>/`，旧产物进 `_stale/`，并写 `build-info.txt` / `build.json`（exe 尺寸 + PE `TimeDateStamp`）。报告因此带一行 `Build: 60396032B@1793431505s`，工具用同一对数字判断「这份 map 是否属于这个二进制」（整数比较，不看修改时间）。版本号改由 `BuildStampMacro` 编译期问 git 内联。
- **工具合并**：`tools/crash.py` 一个文件取代九个脚本（crash_triage / diag / mapresolve / verify_map / symbolize_android / gen_linemap / gen_linemap_msvc / linemap_compare / fnv1a），子命令覆盖 status / report / bundle / ui / symbols / prune / triage / resolve / verify-map / symbolize / linemap。拆开本身就是 bug 来源：报告可能对着另一个构建的 map 解析，每一帧都「解析成功」却全错。
- **删除自动诊断建议**：报告与弹窗里「什么 / 为什么 / 怎么修」那张固定表整段删除（没有一张表能覆盖所有失败，猜错比不猜更糟），报告只写事实，解释交给 issue 回复。
- **验证范围**：只有 Windows 链端到端验证（报告 → 清单 → 解析）；Android / iOS / macOS 的符号位置接好但未在真机重测。发布包默认不含内联 `[文件:行号]`（那需要第二遍构建），需要时用 `crash.py linemap` 现做。

#### 平台与启动

- **iOS / macOS 渲染缩放**：新增 `backend/RenderScale.hx`，按真实「舞台单位 ↔ 设备像素」映射摆放画布。旧 `RatioScaleMode` 在一个空间算 letterbox 偏移、在另一个空间应用，iOS/macOS 上画布右移 `offset × 像素比`、左侧黑边、右侧被裁；不一致时按可见区域布局并记 `trace.render.inconsistent`，一致时与旧版逐像素相同。
- **iOS 字体**：解包时 `.ttf/.otf` 不再走 `ByteArray.fromFile()`（iOS 工作目录正是待写入的 Documents），改读内置资源，完整性探针加入 `assets/fonts/vcr.ttf`；新增 `backend/FontRegistry.hx` 按绝对路径兜底注册，`Paths.font` / `languageFont` / `optionsfont` 接入并记录命中路径。
- **iOS / tvOS 换 SDL3**：`lime-sdl3` 扩到 `ios || tvos`，部署目标 13.0、设备 `universal`；不再定义 `SDL_MAIN_HANDLED`、帧循环改 display link 驱动、不再首帧阻塞、隐藏 home indicator；`DISPLAY_SCALE_CHANGED` 转发为 resize；iOS 设备信息报出真实版本与架构；`applyStorageDirectory()` 回读校验 cwd；启动日志与崩溃转储带 `Render scale: …`。切换平台需要 `lime rebuild <target>` 一次。
- **Android**：崩溃报告模块列表改用运行时 `dlsym` 取 `dl_iterate_phdr`（NDK 只在 API 21 以上声明，工程用 android-16，armv7 直接调用编不过），POSIX 补 `MAX_PATH`；联机聊天可收起软键盘，BACK 第一次只关输入法、不退出结算页，输入框有字时也能双击 B 取消。
- **评级顺序**：`buildRatingsData()` 恢复 0=sick / 1=good / 2=bad / 3=shit，marvelous 追加到 index 4 并新增「最优档在前」的判定优先级 —— 此前 marvelous 占 index 0 把整张表挪位，联机复算分数按错档位加权。
- **启动路径**：Windows 存储根改用可执行文件目录（原为进程工作目录），快捷方式 / cmd / 其他目录启动都能找对 `assets` / `mods` / `crash`。

#### 界面

- **切换过渡**：新增 `backend/transition/`（`TransitionDirector` / `TransitionStyle` / `WipeVisual` / `FadeVisual`），Wipe（0.25 s 扫入 + 0.03 s 黑屏 + 0.35 s 扫出）/ Fade / Off 三档，落成「视觉」页的 `transitionStyle` 选项。旧 `CustomFadeTransition` 类名与 `finishCallback` / `nextCamera` 保留，中途销毁补触发回调避免卡黑。
- **菜单特效移除**：极光、粒子、节拍脉冲、选中辉光、条目入场、选歌预览辉光 / now playing / EQ 条整套删除（`MenuFX.hx` 及三个菜单 state 的调用、`quickMenuTransition`、`seiuMenuFx` 选项与三语文案），共 −1004 行，HEAD 全仓零引用。
- **Credits**：新增 GitHub 贡献者段（最多 30 人，头像 150px / 6 小时缓存），取数顺序为磁盘缓存 → 在线接口 → 内置快照，离线时标题标注 `· offline` / `· cached`；`tools/gen_contributors.py` 刷新内置快照。

#### 分支库更改

- **hxcpp（`seiunengine-4.3.175`，自 4.3.2 重基到上游 v4.3.175）**：重基本身即本周期最大的性能变化（旧分支最大帧 57.9–66.9 ms / 停顿 53.5–62.9 ms，重基后 34.9–38.9 / 39.7–46.2 ms）。修 GC 行计数回归（`uint8_t` 在 `HXCPP_GC_BIG_BLOCKS` 的 508 行块上回绕，堆占用被低估、几乎每次要新块都回收）；采纳上游弱键 ephemeron；标记栈预取（x86-64）、finalizer 表重建再交换、碎片整理节奏调整（堆上限 1 GB → 512 MB，作者结论：只有节奏真正移动最大停顿 36.1–39.0 ms）；`hx::Boot()` 移进 `try` 并把异常汇入可选 `seiun_fatal_report()`、Windows 对话框改 `MessageBoxW`；新增 `_hx_std_file_seek64` / `tell64`；zlib 1.3.1 换 zlib-ng 2.3.90（`ZLIB_COMPAT`）并修掉 `haxe.zip` 流式解压返回累计计数；恢复并重做编译进度与本次重编译清单。
- **openfl**：GL 状态缓存与原地顶点缓冲（同画面 GL 调用 −51%）；`BitmapData` 的 `dropCPU` / `restoreCPU` / 8 位索引纹理 / 不透明 RGB 纹理；`Shader.gfxTryCompile` 与生成式 shader 参数表重新解析；`TextField.setTextFormat()` 颜色改动不重排版。
- **flixel**：`FlxText` 描边盖章、增量重绘、无变化跳过与静态文本合页；`FlxGraphic` 的 CPU 副本释放/恢复、调色板与重排计划挂载点、幂等销毁与活引用保护；相机画布跳过每批四边形边界重扫；重建中的 state 不再被销毁；预加载改为极简进度 + 启动画面绘制 logo。
- **lime**：新增 `FatalReport`（SDL / 窗口 / GL / 音频初始化失败自写 `crash/lime_<kind>_<时间>.txt`）；资源清单从可执行文件目录解析；原生重建默认 SDL3，避免一次 `lime rebuild` 用 SDL2 覆盖 SDL3 的 `lime.ndll`；Apple SDL3 后端接线。
- **hscript-seiun 1.4.0**：正则字面量 `~/pattern/flags`、对象 / 数组展开、结构化 switch 模式、`enum abstract` 与类泛型；运行时错误带脚本调用链与拼写提示。作者自述性能「中性到略快」，不按百分比宣传。
- **hxvlc 2.3.1**（libVLC 3.0.23）：macOS 的 `libvlc.dylib` / `libvlccore.dylib` 原本是两个 14 / 18 字节的「符号链接文本文件」，检出后链接必失败，换成真实 x86_64 + arm64 fat 二进制；无 Stage3D 上下文时恢复 CPU `BitmapData` 渲染路径；并发 `initAsync` 不再创建两个实例；视频实例泄漏防护。
- **linc_luajit**：15 个平台预编译库改为 CI 全量重建 + 架构自检（直接读 ELF / Mach-O / COFF 头）+ 每平台 sha256 清单；多 Lua state 的回调表串味修掉。
- **flixel-ui / flixel-addons**：`FlxUICursor` 里裸写的 `case ID:` 被解析成继承来的 `FlxBasic.ID` 而非 `SortMethod.ID`，被 Haxe 降级成 catch-all；改为显式 `SortMethod.ID`。`@:enum abstract` 换成 Haxe 4 的 `enum abstract`。

#### 注意事项 / 已知限制

- ⚠ **四个分支库的改动尚未发布到远端**（hxcpp 14 个提交在 `seiunengine-4.3.175`、lime 5 个、flixel 12 个、openfl 7 个），`hmm.json` 里 hxcpp 的 `ref` 仍写作 `haxe-4.3`。以现有远端状态在干净环境构建，拿到的是重基前的旧底座，而且不会报错：**能编译、能运行，只是 GC / 崩溃路由 / `seek64` / 进度条这些改进不在里面**。
- 图集裁切只保留每帧实际用到的区域：绕过帧、直接按绝对坐标读图集位图的模组会看到图外被切；走 `Paths.getSparrowAtlas / getAtlas / getAsepriteAtlas / getPackerAtlas` 的自动生效，自己 `FlxAtlasFrames.fromSparrow()` 的不经过。调色板采样为 `NEAREST`，缩放 / 旋转 + 抗锯齿时与 RGBA 的 LINEAR 结果不同。这条线没有玩家可见开关，只有 `FNF_GFX_ATLAS_CROP` / `FNF_GFX_ATLAS_REPACK` / `FNF_GFX_PALETTE` / `FNF_GFX_RGB` 环境变量。
- 原生折叠路径会丢 Alt Animation（`PlayState.nativeFoldToChartNotes` 先写 `'-alt'` 又被 `''` 覆盖），只影响走原生路径的 Turbo / 超巨谱，已记录未修。
- `.chartpack` 语义等价而非逐字节还原：同 section 内同刻 note 顺序与数字格式可能不同；基础 pack 存在时必须同时提供 `<song>.parts.json`，否则 2..N 不合并；打包器只接受 3 / 4 个标量字段的 note，5 个以上直接报错；工具需 Node 18+，界面需 .NET 4.8。
- Windows 存储根改为 exe 目录后，装进只读目录会写不进存档与崩溃报告；macOS 仍用 `../Resources/`、Linux 仍是工作目录。tvOS 只加了编译定义，无配置与 CI，未构建未验证。

---

### 鸣谢

感谢所有参与测试的人员，你们的宝贵反馈是推动引擎不断完善的重要力量。

---

---

## English Version

---

### June 19, 2026

- Fixed the issue where notes disappeared during the first section of the Senpai song.
- Fixed a crash on some Android devices when entering the Replay History or Game Over screens.
- Completely rewrote the Replay system.
- Updated Lua library to a newer version.
- Redesigned the Pause menu with a subtle 3D effect.
- Added a Trace console for debugging.
- Introduced settings backup and restore functionality.

---

### July 18, 2026 — Major Milestone Update

#### Scripting & Mod System

- HScript is now mature enough for building full-fledged mods, supporting custom icons and assets.
- Lua compatibility has been further improved (API still early-stage); both Lua and HScript can now modify (sub)states (not fully tested, may affect some mods).
- Added two FPS display options, configurable per mod.
- Health bar no longer uses mapping; now built natively with 073 Bar.hx, completely fixing display glitches.
- Lua and HScript both allow modifying (sub)state (early stage).

#### Editor & Charting

- Chart editor now supports importing/exporting Codename Engine (CNE) format, with save actions consolidated into a single Prompt window.
- Fixed missing close button (X) on Prompt windows for mobile devices.
- Fixed notes appearing on the opponent's side in the new chart editor.
- Fixed "Save and Playtest" in the old chart editor forcibly writing to disk (now it only playtests, no auto-save).
- Unified unsaved warning logic across both chart editors — now prompts before exit, reload, playtest, or preview; no more sneaky auto-saves.
- Added a "Chart Autosave" setting (off by default). When enabled, it creates timed backups.
- Fixed chart conversion issues specific to 0.6.3 format (separate fix on July 20).

#### Performance & Rendering

- Optimized frame rate and memory usage for charts with tens of thousands of notes (using atlas frame caching and faster loading).
- Further improved loading speed for massive note counts (cached frame scan results, single texture load per note).
- Fixed a self-referencing ring hazard in Note constructor (prevNote no longer points to itself).
- Minor rendering optimizations across the board.
- Removed multi-threading update due to persistent bugs.
- Fixed unusually long sustain notes when speed transitions from extremely slow to extremely fast.

#### UI & Interaction

- Rewrote the Settings menu (simplified to a single class), now allows mods to customize menus and animations via JSON + HScript + Lua.
- Overhauled mod loading: FreePlay now shows mods as tabs instead of dumping all songs; added a dedicated mod-switching substate (independent from FreePlay).
- Optimized combo sprite generation to reduce memory usage, preventing lag on messy charts.
- Kept the old Pause menu (OldPauseSubState) as an option.
- Backported PsychCamera and other classes from 0.7.3/1.0.4.
- Fixed mustHitSection blocking player character animations.
- Fixed practice mode accuracy display (display-only issue, no cheating).
- Fixed Replay not recording virtual controls on mobile, resulting in empty replays.
- Fixed menu not opening when only one mod is present.

#### Compatibility & Misc

- Added empty implementations of mobile virtual keys to MusicBeat(sub)State on PC builds, making PC support touchscreen-friendly.
- Fixed various Android-specific compatibility issues.

---

### July 19, 2026

- Fixed rotated="true" not correctly applying frame rotation in Sparrow XML animations.
- Added a global mod list option.
- Android: allowed users to choose custom file storage locations, adapting to Android's data directory restrictions on newer versions.
- Fixed character flipping not working correctly.
- Improved song loading speed.
- Code cleanup (removed HIM-related leftovers, restored CO compatibility, etc.).

---

### July 20, 2026

- Fixed chart conversion issues specific to 0.6.3 format (separate fix).

---

### July 21, 2026

- Removed the "Aggressive Android Optimization" setting.
- Fixed stage images being loaded in every scene unnecessarily.
- Fixed a crash when timeBar.cameras became null in compatibility mode.

---

### July 31, 2026 — Bulk Fixes & Enhancements

#### Scripting & Judgment

- Fixed Botplay not triggering Lua/HScript events for Hurt/ignoreNote hits.
- Fixed mod Main.hx leaking into other mods when no mod was explicitly selected.
- Fixed crash when pack.json lacked the restart field.
- Fixed songs starting before the countdown finished.
- Fixed note judgment ms being off during countdown (now consistent with normal play).
- Added "Ignore looping error scripts" setting (on by default) with a "Script error limit" (default 50). Scripts that repeatedly error will be silently disabled to prevent spam.
- HScript now follows the same error limit logic instead of showing a popup on first error.

#### Editor & Charting

- Fixed MasterEditorMenu loading vanilla resources instead of the selected mod's when first entering an editor.
- Unified unsaved warning logic across all editors (no more auto-saves).
- Added "Chart Autosave" toggle (off by default).

#### Performance & UI

- Even faster loading for massive note counts (cached frame scans, single texture load).
- KeyboardDisplay fully soft-coded: customizable key size, spacing, font, colors, transparency, etc., plus a fullyCustom mode with press/release/update hooks.
- Modernized Results and ScoreHistory screens with elastic (backOut) entrance animations, hover effects, and dynamic text layout — fixed overlapping and clipping issues.
- Pause menu now has higher transparency (black overlay, acrylic layer, glass cards are more see-through), with adjustable constants (BG_ALPHA, OVERLAY_ALPHA, etc.).
- Replay system further optimized.

---

### August 18, 2026

- Further note performance improvements: extra loading and rendering acceleration for extreme charts (hundreds of thousands of notes).
- Fixed a crash during chart conversion for the Vs Slice mod: resolves data parsing errors that caused program termination.
- Fixed various reported issues: mod compatibility, occasional crashes, and UI display glitches.
- Underlying upgrade to SDL3: migrated the render backend from SDL2 to SDL3, enhancing cross-platform graphics performance and input response, laying groundwork for future features.
- Fixed Windows icon error: resolved an issue where the Lime build process incorrectly injected the icon, causing display issues for the Windows executable.
- Added credits: supplementary contributor information has been added to the relevant in-game screens.

---

### August 19, 2026

- Fixed Replay playback failure. The specific causes are as follows:
  1. ScoreHistorySubstate.playReplay() invoked Song.loadFromJson() directly without switching to the mod directory of the song (unlike Freeplay), causing Paths.modsJson() to fail locating the mod chart and falling back to assets/data/.
  2. Replay judgment accuracy has been enhanced.
- Completely removed GPUTextureManager and the "GPU texture pooling" setting, fixing the issue where large images or full-screen areas would display as black blocks when the option was enabled.
- Added support for the new Adobe Animate (spritemap1) character format.
- Fixed FlxAnimate character animation playback issues.
- Fixed Lua playAnim interface failing to trigger character animations correctly in certain scenarios.
- Fixed StageData compatibility issues that caused mod stage loading failures or display errors.
- Fixed camera zoom logic to ensure scaling behavior matches expectations.
- Fixed healthBar.scale reading errors, resolving incorrect health bar scaling in certain mods.

---

### August 20, 2026 — SeiunEngine 0.7.3 Full Compatibility Patch

#### New 0.7.3 Compatibility Layer

- Added backend.Mods compatibility class (source/backend/Mods.hx), providing 0.7.3 mod HScript-dependent Mods APIs: currentModDirectory, getGlobalMods, pushGlobalMods, getModDirectories, mergeAllTextsNamed, directoriesWithFile, getPack, parseList, updateModList, loadTopMod. All delegated to Seiun's existing Paths and CoolUtil to avoid duplicate maintenance.
- Fixed Lua script onCreate being unable to register callbacks from other scripts (source/script/lua/FunkinLua.hx): the current Lua script is now temporarily added to PlayState.instance.luaArray before call('onCreate'), and removed after onCreate completes. This fixes the root cause of Pause.lua's parseJson returning nil during onCreate, and also fixes jsonReader.hx's createGlobalCallback failing to register with the current script.

#### Pause Menu / CustomSubstate

- CustomSubstate Lua global changed to safe value (source/script/lua/FunkinLua.hx): customSubstate on the Lua side no longer stores CustomSubstate instances directly; it now stores the substate name as a string (e.g., "NEW_pause_menu"). HScript side retains the actual CustomSubstate instance. Eliminates "Convert: Haxe value ... not supported" errors.

#### Version / Variable Compatibility

- version global now follows compatibility mode (source/script/lua/FunkinLua.hx, source/script/hscript/HScript.hx): version now equals CompatEngine.current() — 0.6.3 / 0.7.3 / 1.0.4 modes return the corresponding version string.
- opponentVocals renamed (source/states/PlayState.hx, source/editors/ChartingState.hx): all vocalsOpponent references renamed to opponentVocals to match 0.7.3.
- Added 0.7.3 properties: PlayState.inst as an instrumental alias pointing to FlxG.sound.music; PlayState.stageUI supporting the stageUI field from stage json; PlayState.iconsAnimations defaults to true for scripts like iconShake to read; StageData.StageFile now has an optional stageUI field.
- noteSkinPostfix / splashSkinPostfix (source/script/lua/FunkinLua.hx) no longer hardcoded to empty strings; now read from Note.getNoteSkinPostfix() and NoteSplash.getSplashSkinPostfix().

#### Missing Callback Completions

- Achievements system fully compatible (source/Achievements.hx): retained legacy Seiun achievement APIs (achievementsStuff, achievementsMap, henchmenDeath, loadAchievements, unlockAchievement, isAchievementUnlocked, getAchievementIndex, AchievementObject, AttachedAchievement); ported 0.7.3 achievement system (Achievement typedef, achievements, variables, achievementsUnlocked, getScore, setScore, addScore, unlock, isUnlocked, startPopup, createAchievement, reloadList, loadAchievementJson); added Lua callbacks (getAchievementScore, setAchievementScore, addAchievementScore, unlockAchievement, isAchievementUnlocked, achievementExists).
- Discord compatibility aliases (source/Discord.hx): added clientID and _defaultID static variables; source/script/lua/FunkinLua.hx added Lua callbacks (changeDiscordPresence, changeDiscordClientID).

#### Call Order Fixes

- PlayState onCreatePost order aligned with 0.7.3 (source/states/PlayState.hx): Lua onCreatePost called once before super.create(); HScript onCreatePost called once from within super.create(); removed the duplicate callOnScripts('onCreatePost') to prevent HScript from executing twice.

#### Sentinel Value Compatibility

- Function_Stop constants changed to 0.7.3 string sentinels (source/script/lua/FunkinLua.hx, source/psychlua/LuaUtils.hx, source/editors/EditorLua.hx): Function_Stop, Function_Continue, Function_StopLua, Function_StopHScript, Function_StopAll all changed to "##PSYCHLUA_*" strings, consistent with 0.7.3 / 1.0.4.

#### Controller / Input Compatibility

- keyboardJustPressed keyboard + gamepad fallback (source/script/lua/FunkinLua.hx): ENTER, SPACE, Z fall back to Controls.ACCEPT when keyboard not pressed; ESCAPE, BACKSPACE fall back to Controls.BACK; W, UP, S, DOWN, A, LEFT, D, RIGHT fall back to UI_*_P. keyboardPressed and keyboardReleased also have corresponding hold/release fallbacks.
- keyJustPressed / keyPressed / keyReleased default fallback (source/script/lua/FunkinLua.hx): unmatched names now fall through to controls.justPressed / pressed / justReleased, matching 0.7.3 ExtraFunctions behavior.

#### Version Display Adjustments

- Main menu PE version display (source/states/MainMenuState.hx): displays "Psych Engine v0.6.3+0.7.3+1.0.4 (Active: current compatibility version)"; all version text right-aligned against the screen edge to prevent overflow.
- In-game bottom-left PE version display (source/states/PlayState.hx): PE version in bottom-left corner changed to CompatEngine.current(), following the currently active compatibility mode.

---

### August 21, 2026

- Fixed several remaining issues with Replay (replay difficulty lock, replay data integrity, etc.).
- Removed the OSU tail judgment setting option (gameplay options, ClientPrefs and related replay/judgment code cleaned up).

---

### August 22, 2026 — Unified UI Architecture + Settings Popups

#### Shared UI Foundation (new source/backend/UIScreen.hx)

- Added UIScreen helper class unifying glass/acrylic UI across modern screens:
  - createScreenCamera(): creates a dedicated static screen-space camera, so substate UI is no longer shifted by PlayState/Freeplay camera scroll, zoom and follow; mouse hit testing stays accurate.
  - applyBlur() / clearBlur(): applies/removes a real OpenFL Gaussian-style blur on the underlying game/menu camera, gated by ClientPrefs.data.shaders.
  - makeGlassCard(): unified semi-transparent rounded glass card (subtle 1px white border, customizable fill).
- All hand-rolled cameras previously created by Results / ScoreHistory / Pause / settings popup now migrated to UIScreen.createScreenCamera().

#### Pause Menu (source/substates/PauseSubState.hx)

- Dedicated static screen-space camera + background Gaussian blur (radius 8) for a softer paused backdrop.
- Fixed mouse hit offset under the slideGroup perspective effect: hit testing now accounts for scale/origin transforms (previously only x/y offsets were compensated, so scaled button hitboxes were misaligned).
- Tuned 3D parallax parameters (offset 16/10 → 12/8, scale factor 0.008 → 0.005).
- Backdrop camera filters are restored on resume and destroy to avoid leftover blur.

#### Settings Menu (source/options/OptionsState.hx, new source/options/OptionPopupSubState.hx)

- New modal OptionPopupSubState:
  - String options: Enter/click opens a dropdown list; arrows or mouse hover move the highlight; Enter/click confirms; ESC/Back cancels.
  - Numeric options: Enter/click opens a slider; arrows or mouse drag change a temporary value; Enter confirms; ESC/Back cancels.
  - The popup is a real FlxSubState, so the parent settings view is paused while it is open — mouse and keyboard no longer fight; first-frame input skip prevents the triggering Enter/click from immediately confirming or cancelling.
  - Glass card panel with springy entrance animations; clicking outside the panel cancels.
- Category preview mode (updateCategoryPreview) temporarily disabled, interface kept for later re-enable.
- Mouse hover/wheel logic now only applies when no keyboard input is used (keyboardUsed check), fixing conflicts under mixed input.

#### Results Screen (source/substates/PlayStateResultsSubstate.hx)

- New top "Hero Card": score, accuracy, grade and max combo shown in large type with staggered lift-in animations.
- While results are open the underlying PlayState update is frozen (persistentUpdate = false) and a blur (radius 10) is applied, stopping the game camera from panning/zooming behind the UI; fully restored on close.
- Hit bar chart now supports Marvelous ratings: when enabled, Marvelous is its own gold-colored bucket at the front; Sick/Good/Bad/Shit/Miss bars lay out dynamically (row height/spacing auto-compresses when more than 5 rows).
- Mouse hit testing now uses getScreenBounds (honors scale/origin) so hover/click hotzones stay accurate.
- Panels switched to UIScreen.makeGlassCard; the grade icon moved to the hero card, vertically centered on the right.

#### Score History Screen (source/substates/ScoreHistorySubstate.hx)

- List rows redesigned: row height 40 → 58, each row now has subtitle text, a judgment icon and a hover row background; hovering selects the row.
- Double-click a row to play its replay (second click on the same row within 400ms); the detail card shakes if no replay data exists.
- Deletion now requires two RESET presses (second press within 2.5s actually deletes; ESC/timeout cancels), with a new deleteConfirm localization string.
- The whole screen uses a dedicated static camera + backdrop blur (radius 9); backdrop alpha auto-drops to 0.68 when shaders are enabled.
- Fixed list/selection state refresh after deleting an entry.

#### Trace System (source/mohong/TraceConsole.hx, source/mohong/TraceManager.hx)

- Console output is now off by default: on Windows the Trace Console is an explicit opt-in (no more silent console flooding when launched from a terminal); other desktop sys targets keep the historic stdout logging.
- Added console availability detection (setConsoleAvailable / isConsoleAvailable; Windows probes via Windows.hasConsole) to skip formatting when no output target is attached.
- Added console burst rate limiting (consoleRateLimit default 200 lines per consoleRateWindow 0.1s); excess lines stay in the ring buffer but are not flushed; output is not duplicated when a TraceConsole listener is live.
- Main.hx / TitleState.hx: Windows desktop applies the Trace Console preference after prefs are loaded (TraceManager.syncWithPrefs).

#### Charting & Notes (source/Note.hx, source/states/PlayState.hx)

- 0.6.3 custom note compatibility: EventNote / PreloadedChartNote gained noteSplashTexture / noteSplashHue / noteSplashSat / noteSplashBrt so Lua can set per-note splash skins and colors; only explicit Lua writes override (null = unset), otherwise the noteType setter's lane-color splash is kept — normal notes are no longer overridden to all-zero colors. Written after the noteType setter so the setter cannot stomp custom splashes.
- Fixed isGFSide detection: on old-format charts (isNewVer = false) isGF for GF-section notes was computed wrong (gfSec && rawData < noteAmmo broke after playOpponent reversal); now uses isGFSide = gfSec && (gottaHitNote == mustHit).
- Fixed health icon layering under the 0.7.3/1.0.4 compatibility Bar (a FlxSpriteGroup): custom icons could be covered by the bar background after character swaps. Added forceHealthIconsAboveBar(), re-inserting the icons right after healthBar on build and on boyfriendName/dadName changes.

#### HScript & Misc

- Config.hx: import whitelist simplified (dropped the #if !DOCUMENTATION and MODCHARTING_FEATURES conditional wrappers), allowed import packages listed uniformly.
- Localization: ScoreHistorySubstate gained deleteConfirm, and instructions updated to "UP/DOWN/HOVER: Select | ENTER/DOUBLE CLICK: Play | RESET x2: Delete | ESC: Back".

---

### August 23, 2026

- Fixed Android Pad-Custom key dragging getting stuck to a finger / unable to drop: rewrote the global single-button drag state into per-touch tracking (`Map<touch ID, FlxButton>`), so multiple buttons can be dragged simultaneously with multiple fingers, and a drag only ends when the touch that started it is released.
- Fixed buttons being draggable off screen: drag and saved-position loading are now clamped to the visible screen bounds.
- Fixed drag state not being cleared when switching control modes, Reset, or exiting; added stale-touch cleanup and safer handling of old/incomplete saved button arrays.
- Cleaned up leftover virtual pad / hitbox references when switching controls.

#### Note & Sustain Fixes (2026-08-23 follow-up)

- Fixed a gap between the TAP and the sustain head in upscroll: removed the non-vanilla upscroll-only offset (`+55` / `daPixelZoom*9.5`) so upscroll now matches 0.6.3 — vanilla applies no extra offset to upscroll sustains (positioned purely by `distance`) and is verified clean on both PC and Android. Applied to both gameplay (`PlayState`) and editor preview (`EditorPlayState`).
- Android sub-pixel seam guard for downscroll sustains: each non-pixel hold segment gets ~2px extra length at construction so adjacent segments (incl. the TAP↔sustain start) always overlap, avoiding hairline seams from fractional `scale.y` + non-AA on GLES. Frame-independent, no per-frame cost (conservative guard — keep only if still needed on Android).
- Fixed Hurt Note sustains disappearing as they pass through the receptors even when not pressed: the clip condition no longer treats `ignoreNote` (Hurt) notes as already-hit and clipping them early; a mustPress sustain is only clipped after it is actually hit (`wasGoodHit`), matching 0.6.3.
- Fixed a "phantom/virtual press" (a key showing as pressed with no touch): added an anti-stuck reset in the release poll — if a lane is genuinely not held (lost release from multi-binding/touch) but its strum is still `'pressed'`, it is forced back to `'static'`; it only fires when the lane truly is not held, so real holds are unaffected. ⚠ Not yet verified on device; awaiting an Android test.

---

### August 25, 2026 — Extreme 10k+ Note Performance + Android Touch Fixes

#### Extreme Performance for Massive Charts

An H-Slice-style optimization system for charts with tens of thousands of notes, targeting frame drops under extreme density (all off by default; enable per-option in Graphics Settings):

- New "Performance Mode" master switch with sub-options: batch-skip off-screen notes / fast note sorting / max concurrent notes / GC disable during gameplay; enabling the switch turns on batched hit resolution, merged popups & splashes, spawn throttling and other aggressive optimizations.
- Off-screen culling + visible-object horizon + object pooling: off-screen notes cost zero updates and zero draws; memory and CPU scale only with concurrently alive notes.
- Hot paths downgraded in complexity: compact alive lists, O(1) group appends, cached indices/trig, shader-free batching of neutral-color notes sharing one texture (thousands of notes merge into a single draw call).
- Botplay resolves due notes through the data layer in batches while presentation merges per frame, avoiding death spirals at extreme NPS.
- Change Mania event timeline caching: chart loading no longer scales quadratically with event count.
- Compatibility: Lua/HScript callback semantics remain vanilla when scripts are present; turning switches off restores stock behavior.

#### Android Touch Fixes (Hitbox piano keys stuck pressed / presses not registering)

Root cause: after switching Lime's backend to SDL3, when a system gesture steals an active touch (navigation-bar edge swipes, predictive back, palm rejection, notification shade, etc.) Android sends ACTION_CANCEL, which SDL3 maps to the new SDL_EVENT_FINGER_CANCELED event. Lime's SDL3 backend only handled FINGER DOWN/UP/MOTION and silently dropped the cancel. SDL had already removed the finger internally, but the upper layers (lime → openfl → flixel) kept the touch pressed forever — keys stopped releasing; afterwards, re-pressing on the same recycled pointer id produced no fresh just-pressed edge — presses stopped registering. Both symptoms share this root. (SDL2 was unaffected because upstream never handled ACTION_CANCEL at all.) Hitbox fingers rest along the bottom gesture zone and multi-finger drumming triggers palm rejection, so cancels occur frequently on modern Android.

Three-layer fix (defense in depth):

- Android Java template (SDLSurface.java): translates ACTION_CANCEL into ACTION_UP before it reaches SDL, so every canceled finger follows the normal release path — restoring SDL2-era behavior. Takes effect with the next APK build; no native library rebuild required.
- Lime SDL3 backend (SDLApplication.cpp): added the missing SDL_EVENT_FINGER_CANCELED case and dispatches it as TOUCH_END, fixing the lost-cancel at the source. Stacks in once the Lime native library is rebuilt.
- Engine button layer (android.flixel.FlxButton): fast-tap recovery — when a press+release both land within one frame window, flixel's FlxInput only keeps a justReleased edge with no justPressed frame, so the original logic dropped the entire tap ("sometimes can't press"). The button now synthesizes a full down/up callback pair so rapid drumming never loses hits. Enabled on touch platforms only, de-duplicated across multi-camera passes, and never interferes while another finger holds the lane. FlxHitbox and FlxVirtualPad share this button class and inherit the fix.

Bundled regression harness (temp/touch-fix-test/TouchFixTest.hx): replicates the FlxInput state machine, touch manager, lime event mapping and button logic layer by layer; 15 assertions cover stuck-key reproduction, reused-id missing edge, same-frame fast-tap loss/recovery, multi-camera deduplication and zero regression on normal press/hold/release — all passing. Full android-target Haxe compilation verified.

(You know what? I hate updating announcements first, so let's leave it to AI)

---

### August 27, 2026 — Rendering/Frame-rate Optimization Wrap-up

- Fixed SDL3 frame scheduling overspeed and jitter with wall-clock scheduling and high-resolution timing.
- Added uniform upload cache, override slot cache, optional drawQuads bounds fast path, and vertex-color batching.
- Android: strips invalid GLES uniform initializers; full GC before gameplay reduces first-hit stutter.
- FlxText re-rasterizes at the target scale to fix blurry text when the window is scaled up.
  
---

### August 27, 2026 — Crash Reporting & Diagnostics

- New SystemDiag report builder: every crash dump / copy / save now includes OS/CPU/memory/display info, Lime render context (type, version, attributes), GPU details (vendor, renderer, GL version, GLSL, driver, extension list), runtime state (draw calls, FPS, graphic cache, current state & song) and the last 400 game-log lines. Engine name is consistently "SeiunEngine".
- New GlErrorWatchdog: polls glGetError on render frames; renderer faults (GL_OUT_OF_MEMORY, GL_CONTEXT_LOST_WEBGL, ...) are logged and included in crash reports, de-duplicated to avoid log flooding.
- New NativeCrash hooks: Windows SEH captures exception code, faulting instruction pointer, access-target memory pointer, registers and faulting module; Linux/macOS catch SIGSEGV/SIGABRT/... with si_addr pointer and backtrace. Native hard crashes are no longer silent — the logs are attached verbatim to the next report.
- New heartbeat file (crash/heartbeat.txt): current state/fps/memory/GL error every ~5s (written only on real change), so even a process killed by the driver layer still leaves a location clue.
- Stack collection improved: non-FilePos entries are kept and the current call stack is used as fallback.

---

### August 28, 2026 — Build Fixes

- Re-enabled the hxcpp cache in CI for macOS arm64 after the toolchain fix, so Mac builds are faster again.
- Fixed perfMode regressions: with performance mode OFF, behavior is now exactly stock (no sneaky shader skipping / off-screen culling changes).

---

### August 30, 2026 (0.2.1hotfix)

#### The Big One (fix bugs)

- New **Turbo Mode** (off by default): the ultimate extreme-chart switch — forces botplay and turns high-density sections into precomputed aggregation + ghost-note collapsing + data-level bulk settlement instead of materializing tens of thousands of sprites. Also added string interning and Note field reordering (grouped by type to kill alignment holes), saving hundreds of MB on million-note charts.
- Graphics cache overhaul: AsyncGfxLoader / GfxLru / GfxPolicy now decode/repack on the main thread in small per-frame batches (no more stuttery loading screen), with stable canonical keys + alias registration so eviction can't kill textures still in use.
- Camera changes reverted: camGame back to FlxCamera, camFollow back to FlxPoint — PsychCamera's exponential smoothing and freezeCamera are gone, back to stock 0.6.3 camera behavior.
- Online: server.zip (15KB → 33MB) and online.zip refreshed; PlayState gained spectate mode, per-player skin replacement + nameplates, start gate, and host-only pause messaging.
- ⚠ Heads up: the current online code is NOT compiled into the game at all (ONLINE_ALLOWED is still commented out) — it's honestly a mess, so don't get your hopes up or ask when it ships. The code is just sitting there for now.
- PlayState key-check now uses pre-allocated buffers with reentrancy guards — no more per-frame array allocations on Android.
- Fixed PsychUIDropDownMenu positioning under wheel / re-parenting, plus a pile of small editor, pause-menu and LoadingState fixes.
- New settings: Turbo Mode, Note RGB Shader.

#### GitHub Update Check Rework (fix too)

- New GitHubAPI.hx wrapping the GitHub REST API (releases / tags / commits / issues / PRs) with version comparison.
- Update check now queries GitHub Releases instead of pulling gitVersion.txt; new "accept prereleases" option; main menu shows "update available"; OutdatedState rewritten.
- Version bumped to 0.2.1hotfix; CHECK_FOR_UPDATES now compiles on desktop/mobile (previously only with online).

#### Android Permission Prompt Localization (android)

- "All files access" and "overlay" permission prompts no longer hardcode Chinese/English — they wait for language load and use the engine's own localized dialogs.
- Dialog gained cancelable support; the settings backup prompt now uses the new dialog API ("Backup Now / Later" with localized strings).
- New Android.json language files (SC / TC / EN); SeiunOverlay.java slimmed down.

#### Evening Fixes (a few more bugs)

- New "Clear Image Cache" button (in Graphics settings): press ENTER to release every uncached image (incl. the LRU pool), with a popup reporting how many graphics / MB were freed.
- Fixed copyKey crash on null: missing keybinds now return an empty array with a warning log instead of crashing.
- LuaJIT panic hook: unprotected Lua errors (no pcall boundary) no longer kill the process silently — a crash log is written first (Lua error + backtrace). On Windows, CRT abort / pure-virtual calls also go through the native crash recorder, and the SEH path now uses dbghelp stack walking (drop a PDB next to the exe to resolve function names & lines).

(That's today's work... changelog written by AI as usual.)

---

### September 12, 2026 (0.2.2)

#### Crash diagnostics (the focus of this round)

- **Fixed the root cause of "crash logs tell us nothing".** Every `crash/native_crash_*.txt` after September 5 showed frames like `<sprintf>+0x20413`, which looked like random memory corruption. Three things had gone wrong at once:
  1. `HXCPP_DEBUG_LINK` in `Project.xml` had been **commented out** since the day it was added, so the linker never received `/DEBUG` and the exe carried no CodeView (RSDS) record.
  2. Without RSDS, dbghelp cannot pair the exe with a PDB by GUID and degrades to reading the PE export table — the exe exports only 179 symbols, one of which happens to be `sprintf`, so every address within 132 KB after it was labelled `<sprintf>+0x...`.
  3. `obj/ApplicationMain.pdb` was stuck at August 30 while the exe is relinked on every change, so the symbols no longer described the code.
- **Official builds now emit a `.map` symbol table** (`HXCPP_MAP_FILE=ApplicationMain.map`). This is the key trade-off: `HXCPP_DEBUG_LINK` makes MSVC write debug directory data into the image, growing the Windows exe from 29.6 MB to 47.1 MB — unacceptable for a release. The `.map` is a separate text file produced by the linker, **costs the exe exactly zero bytes**, and still carries every function's exact address, which is enough to turn a report's `Fault offset` back into a real function name. Measured exe: 29,649,408 bytes, identical to before; `.map`: 44 MB (4.7 MB zipped).
- **Crash reports now carry a build fingerprint**: `Build:` (exe/pdb size, mtime, plus an FNV-1a hash of the first and last 64 KB of the exe), `Main module:`, `Main module stamp: TimeDateStamp=...`, whether `Matching PDB:` exists, and most importantly `Symbols: SymType=...`. With `SymType` the report states for itself whether its symbols can be trusted — when it says `SymType=0 (SymNone)` the inline frame names are meaningless and only the `Fault offset` is usable, against the matching `.map`. This lands on both the SEH and SIGABRT paths and is written in the first disk phase, so it survives even if dbghelp later faults.
- **Two new triage tools**: `tools/mapresolve.py` (resolves offsets to function names from a `.map`, can scan a whole crash directory) and `tools/symbolize-crash.ps1` (one-shot wrapper: finds the `.map`, prints each report's build fingerprint first, then resolves in bulk).

#### CI: release builds now publish debug symbols

- All three desktop builds (Windows / Linux / macOS) produce a **separate `*-symbols` artifact** (90-day retention) containing the `.map` plus a usage note.
- Release packaging routes symbol artifacts into `crash-symbols/*.zip` on the GitHub Release, so they are **never mixed into the game archive players download** — the game zip still contains game files only.
- PDBs are deliberately **not** collected: with `HXCPP_DEBUG_LINK` off the linker never regenerates one, and the stale `.pdb` left in `obj/` would only mislead anyone who tried to resolve against it.

#### Three confirmed crash sources fixed

- **Null window handle causing a native null-pointer dereference** (`NativeWindow.close()` nulls `handle` but leaves `context` set, so the render loop keeps calling `ContextFlip()` on NULL). This matches the August 28–30 crashes exactly: the reports show `param[1]` values of `0x8` / `0x10` / `0x30` — struct member offsets, the signature of `this == nullptr` — and on August 30 it crashed five times in a row (19:35 / 19:36 / 19:37 / 19:47 / 20:00) with near-identical registers, i.e. a deterministic path rather than random corruption.
- **`SDL_GetBasePath()` freed with `SDL_free`**: in SDL3 that return value is a process-static cache owned by SDL and released only by `SDL_Quit`. The migration added a `(void*)` cast but kept the free, giving a use-after-free on the next call and a guaranteed double free at exit.
- **Out-of-bounds `members[idx]` on the strum group**: hxcpp's release builds return `null` for an out-of-bounds read instead of trapping, and the following dereference is an instant AV. This class had already crashed here twice and been hand-patched; nine more sites were still unguarded. The accompanying modulo-by-zero on an empty group (`strumIdx %= members.length`) is fixed too.

#### Notes

- The "update/render separation" theory was checked and **does not hold**: `RenderThread` is a stub (multi-threaded rendering was removed long ago) and `drawWrapper` is nulled in both `Main.hx` and `ClientPrefs.hx`, so rendering has always been single-threaded. The real update/draw rescheduling lives in lime's native frame loop, not in flixel.
- Also fixed: a camera could be destroyed from inside its own effect completion callback and then have `flashSprite` dereferenced unguarded.
- The full investigation (evidence, code locations, and the reasoning behind each trade-off) is kept in an internal document and is not shipped with the engine repository.
- ⚠ **The lime and flixel patches must be upstreamed to `mohong2/lime` and `mohong2/flixel`**, otherwise CI re-clones the dependencies and ships those two defects again.

(2026-09-12, changelog written by AI as usual.)

---

### September 26 – October 7, 2026 (0.2.2 Pre-Online.2)

> This entry records the final state of the whole Pre-Online.2 development cycle; intermediate states that later commits superseded or reverted are not listed separately. The player-facing announcement is `release-notes/0.2.2preonline2.md`.

#### Online: SQLite server, in-game hosting and LAN discovery

- **Server storage moved to SQLite**: WAL mode, a single connection plus one database mutex, an append-only schema versioned by `user_version` (13 tables); the legacy JSON files are imported once on first start and renamed to `*.imported-<timestamp>` (never deleted); tokens are stored only as HMAC-SHA256 hashes, compared in constant time, with expiry and revocation; `/dev/urandom` first (an HMAC DRBG where the device does not exist); structured JSON Lines logs rotated per day; a read-only `GET /api/health` plus `--log-dir` / `--log-level`; a standalone `SeiunServer.exe` with zero runtime dependencies can be built, and the neko target is unchanged. The external HTTP surface — signatures, error strings, ordering, pagination, id formats — is kept verbatim.
- **The admin console web page is compiled into the server** (a `server/web/` directory on disk still wins when present); announcement lengths are counted by characters (500 chars + a 2048-byte cap), already-corrupted values are repaired on load, and the same class of limit was swept across 12 user-visible endpoints; persisted announcements ride along with `GET /api/front`, the client renders them in a fixed area, and CJK wrapping counts characters.
- **In-game hosting (LAN HOST)**: the embedded server binds 2567 / 2568 inside the game process, ports increment upward when taken, the room code carries the host's LAN IP, guests join without an account, the local web console is login-free and read-only (`--console-local-readonly` is the standalone-server switch), and Android hosts on a best-effort basis; stopping releases the ports and hosting can be repeated in one session.
- **LAN discovery**: the server list gains "Search for Servers on This Network" — it listens for UDP 2569 broadcasts for 4 seconds and lists the servers it heard; ticking entries and pressing Add Selected Servers writes them into your list (existing entries cannot be ticked; the batch can be discarded). The per-NIC "Use This PC (LAN)" rows are gone (multi-NIC machines listed every IPv4 — including WSL / Hyper-V virtual adapters — and clicking one rewrote the currently selected server). Address probing reports three outcomes: reachable / timed out / protocol mismatch. Android allows plaintext `ws://` / `http://`; Windows hosting prints the firewall allow command.
- **Room pause policy** (host only / any player by default / legacy behaviour) is arbitrated solely by the server: pauses echo with the initiator's identity, resuming only works for the holder, and holder leaving / disconnecting / song end auto-broadcasts a resume. Both players get their own rating popup (the remote one anchors to that player's own character side, clamped to 5%–95% of screen width, same-side players spread apart horizontally).
- **Start gate**: after the host presses play everyone enters the chart and sees "Press ACCEPT to start" (ACCEPT / gamepad A / clicking the hint all count as ready); touch players get an A virtual button, and the countdown starts only when the host's start arrives.
- **The online menu navigation is unified** (OnlineNav / NavRepeat, one scheme for keyboard and touch); online gameplay logic moved from PlayState into a dedicated PlayOnline module; all runtime optimizations are switched off in memory for the current song online and restored from a snapshot on exit; sectioned charts are explicitly refused online; online chart analysis takes the key count from each note's own mania snapshot.
- **Fixed the native crash when quickly switching online screens (most frequent on Android)**: the embedded server's HTTP layer used to spawn one thread per connection, and while hosting in-process (LAN HOST) the client fires an announcement / player-count request on every screen switch — holding the back button made short-lived threads live and die at storm rate, racing hxcpp's generational-GC per-thread referrer chunk lifecycle (`mOldReferrers`), after which a GC write barrier dereferenced the corrupted chunk pointer (all three on-device crash stacks point at `StackContext::pushReferrer`). Fixed on both fronts: (1) the embedded HTTP layer now runs a fixed pool of 4 connection workers draining one blocking queue (`HttpServer`), and the client's online one-off tasks were funneled into a fixed 8-thread pool (`online.backend.Thread.run`) instead of one thread per request, so thread count no longer follows player input; (2) `HXCPP_GC_GENERATIONAL` is turned off (Project.xml) — generational mode was never hxcpp's upstream default, and with it off the GC write barriers compile to no-ops, removing the exact crashing code path (the cost: minor collections become full-heap marks, so GC pauses grow on huge charts; the standalone server binary has never run generational and survived a 100k-request stress of the same storage layer, which supports the choice).

#### Charts: cache, streaming and memory

- **Huge-chart cache `chart_cache/`**: the output of a streamed chart's note loop (complete DTOs) is written column-compressed (`.skel` / `.notes`); a hit replays the list and skips the skeleton scan, the per-section parse, the fold and the sort. Invalidation is "every section file's size + modification time + the caller's configuration string"; one 1.78 GB list became a few MB, with at most a 1 MB block held in memory. Measured: 45 GB amphotercity (2,064,278,444 taps → 4,291,710 representatives) caches to `.skel` 14,215,997 B + `.notes` 12,855,326 B. Settings: Huge Chart Cache / Compress the Chart Cache / Clear the Chart Cache (trilingual).
- **Song select skips preview parsing** for streaming-sized charts (the preview only needs the song name and `needsVoices`).
- **Sectioned-chart detection relaxed**: any starting index (0 / 1 / 5 / 100 all work), gaps are recorded instead of fatal, fewer than two numbered files is a single file; the `<song>.json` gate and the `.parts.json` manifest are unchanged; all 11 regression cases (7 synthetic + 4 real) behave as intended. A song split across several `<song>-<n>.json` files plays as one complete song.
- **Charts without an `events` field can stream too**: a byte-level feature test, so slide20 (2,105,875,665 B / 153,955,328 notes) no longer falls back to a whole-file DOM parse — the reason Freeplay used to freeze on it.
- **Note data moved to a column store**: one column per numeric field, chart-constant fields hoisted to a plain scalar (no column allocated) until the first divergence — the per-note footprint drops from about 358 B to a few tens of bytes; columns grow by doubling and can be filled while parsing, so hxcpp's block pool is no longer stretched to the chart's full size; script writes through `unspawnNotes` keep working on top of the column store.
- **Counters are Int64 now**: chart and hit counts beyond two billion no longer overflow.
- **Allocation-free note material reuse checks**: pooled note reloads used to build a material-key string per note just to compare it; the check is now field-by-field, so the reload path produces no string garbage at all.
- **Popup / splash / materialisation / drain budgets are charged by time**: these budgets were 60 fps design rates reset per *rendered* frame, so the per-second rate scaled with the fps cap (6x the design rate under a 360 fps cap); they now accumulate as elapsed x 60, are spent in whole units and are capped per frame — behaviour at 60 fps and below is bit-identical, and higher frame rates pay the same per-second rate as designed.
- **Allocation-free rating popups**: the image keys (rating / digits / COMBO) are built once and cached instead of concatenating strings for every sprite of every hit; combo digits go into a reused buffer; fades no longer depend on FlxTween's global manager — they are pooled records advanced by PlayState every frame (freezing on pause exactly like the movement does; online, each player's popup is ticked by its own instance), allocation-free in steady state.
- **Graphics purge reworked**: `purgeUnusedGraphics()` no longer re-scans every cache once per purged key — dead candidates are collected in one pass and removed in batches, ending the periodic multi-second main-thread freezes on long sessions; the Sparrow atlas frame caches registered by a purged graphic are evicted with it, so no "zombie atlas" is left behind (mods that spawn sprites dynamically used to render nothing and fall into a Lua error loop).

#### Graphics and rendering

- **Haxe 4.3.7 toolchain migration**: the compiler and API level 430 moved wholesale, hxcpp comes from this engine's maintained `haxe-4.3` branch, and CI / release builds are aligned; the engine code is adapted to 4.3.7's API changes.
- **Atlas repack hardening**: every pixel write goes through a bounds-checked `blit()` (invalid input is skipped and counted with a warning); the packed canvas is verified against the requested size (a clamped allocation abandons the repack and keeps the original); a source whose CPU copy was released never enters `copyPixels` (the whole repack aborts — never a transparent atlas); cross-thread results are published by the main thread; async workers are quieted before a forced GC — closing the class of "the heap got corrupted, and seconds later the GC thread crashed".
- **Async image loading removed**: `AsyncGfxLoader` and its setting are gone; bitmap decoding happens on the main thread in small per-frame batches (the GC-crash investigation's conclusion: the cross-thread bitmap publication path is a heap-corruption source, and the async win is not worth the risk).
- **Separate update / draw with idle-frame draw reuse**: a draw tick that ran no logic step re-presents the recorded draw commands instead of rebuilding the frame; code writing to `camera.canvas.graphics` directly should call `FlxGame.invalidateDrawCache()`.
- **Window modes unified**: the new `backend.WindowMode` handles windowed / fullscreen (a real SDL display-mode switch) / borderless (decorations off + fill + topmost) through one path shared by the boot flow and the options page.
- **PsychUIDropDownMenu reworked**: historical positioning problems (wheel / re-parenting) are folded into the new implementation; Dialog / NativeMem / TraceManager adjusted alongside.
- **O(1) input detection for replay recording**: a monotonic inputTick counter replaces 186 key probes per frame (measured 1547 ns → 0.9 ns per frame).
- **Side HUD: fixed field width + throttle under perfMode**: under Botplay / Turbo the counters change every frame, so the value-change skip never fires, and with a proportional font each autoSize re-layout allocated a brand-new bitmap + GPU texture into the bitmap cache; the side counters now use a fixed field width (single line, one bitmap reused forever), and with perfMode on (and Stock HUD Text Rewrite not forced) their readout is throttled to 20 Hz — exact per-value-change refresh stays when perfMode is off or `Stock HUD Text Rewrite` is on.

#### Video: playback and recording

- **Playback**: hxvlc 2.3.1 (libVLC 3.0.23) is in and the in-tree shadow copy is gone; `startVideo` accepts 1.0.4's full parameter set (canSkip / forMidSong / shouldLoop / playOnLoad); the hxcodec-style FlxVideo / FlxVideoSprite / VideoSprite wrappers and VideoPreloader are kept, so mods keep calling them the old way.
- **Recording (desktop)**: press F9 in a song (or enable Render on Song Start) to pipe the game frames plus the Inst / Voices mix into ffmpeg, writing to `render_video/`; encoders x264 / NVENC / AMF / QSV / x265 / VP9 / VP8 with CRF/CQP / VBR / CBR rate control; **1 frame = 1/fps of song time** (frame numbers derive from the Conductor clock, so pause / seek / speed changes align automatically and dropped frames never change the duration); rendering pins the frame rate with a fixed timestep; the ring buffer waits for the encoder instead of dropping frames; a preview render runs the whole pipeline without writing a file; a RenderIndicator badge shows the state; every render writes a `.log` next to the output. A new "Render" settings page (9 items, trilingual).

#### Scripting: 1.0.4 compatibility, HScript 1.3.0 and diagnostics

- **Full 1.0.4 Lua API alignment**: all 62 signatures Psych 1.0.4 relaxed are relaxed here too (`doTween*` / `noteTween*` `ease`, `mouseClicked/Pressed/Released` `button`, `getMouseX/Y`, `makeLuaText`, `startVideo`'s four new arguments, `precacheImage` `allowGPU`, `setProperty`-family `allowInstances`, `getPropertyFromGroup` / `setPropertyFromGroup` `allowMaps`, and so on); callback arguments match (`eventEarlyTrigger` gets `(event, value1, value2, strumTime)`, `onTweenCompleted(tag, vars)`); the missing `getFileTranslation` / `getTranslationPhrase` are added with a reader for 1.0.4's plain-text `data/<language>.lang` format (merged with the engine's JSON language tables, `{1}` / `{2}` substitution included); `Paths.getAtlas` / `Paths.getAsepriteAtlas` were ported so `'auto'` really auto-detects the atlas format; HScript gains `getModSetting` and optional-argument `keyJustPressed` / `keyPressed` / `keyReleased`. Types are widened (`addAnimation` takes an array or the `'0,1,2'` string form, framerates are `Float`, `setGraphicSize` takes `Float`), `removeFromGroup` answers both dialects, and version-dependent defaults (`setHealth`, `setObjectCamera`, `loadFrames`, …) go through `CompatEngine` — 0.6.3 / 0.7.3 modes stay byte-identical.
- **Mod JSON is parsed the way 1.0.4 parses it**: `pack.json`, `stages/*.json`, `data/settings.json` and `images/gfDanceTitle.json` use a tolerant-first parser (tjson, strict as fallback), so trailing commas and `//` / `/* */` comments no longer break loading; song / character / dialogue parsing stays strict, matching 1.0.4. Measured fix: one mod was never registered as a global mod because of a trailing comma in its `pack.json`; the global mod list goes 2 → 3.
- **`close()` no longer closes the wrong script**: linc_luajit's callback table is static and shared, so the last-created instance won and `close()` could act on a different script (the root cause of a mod's custom menu never appearing). The executing instance is recorded during dispatch, `close()` acts on it, and the log records `CLOSE() <script>`.
- **`callMethodFromObject` no longer calls with unresolved arguments**: `instanceArg(...)` resolves modchart sprites / texts before falling back to the variables map, and an unresolved argument skips the call with a logged warning — fixing a `0xC0000005` native crash from a mod passing null into `mouse.overlaps`.
- **`getDataFromSave` honours its default value** (0.7.3 / 1.0.4 semantics: an absent field returns the caller's default; 0.6.3 keeps the raw lookup) — fixing the "a 1.0.4 mod's options menu builds halfway and ESC stops working" class; `allowMaps` is honoured when reading again; tagged sounds are stored as `sound_<tag>`; tag-less `stopSound` / `pauseSound` / `resumeSound` / `getSoundTime` / `setSoundTime` act on `FlxG.sound.music`; a failed `playSound` no longer leaves a null slot.
- **Scripts are less able to kill the process**: `makeLuaSprite` and friends skip safely when the tag is missing; `safeColor()` replaces the hand-rolled hex conversions (a garbage colour yields opaque white; the strict validation applies in 1.0.4 mode only); key names are lower-cased in 0.7.3 / 1.0.4 modes only; the engine's software cursor is force-disabled before gameplay and restored by the pause menu; KeyboardDisplay and the side HUD hide together with `scoreTxt.visible` (the user's own hide-HUD setting and the online path are excluded).
- **1.0.4 judgement-name mapping**: a new option, "1.0.4 Judgement Names for Mods" (on by default, 1.0.4 compat mode only): the engine-private `marvelous` is rewritten to `sick` as scripts see it (what the same hit would have been called in 1.0.4), so judgement-by-name mods stop mis-counting accuracy / combo; the engine's own judgement, scoring, results, online and replays keep the real rating, and `Note.ratingRaw` preserves it for scripts that want it.
- **Script errors no longer disable the whole script, and silencing is off by default**: the error limit defaults to 0 — every error is printed no matter how many there are; with a positive limit, repeated errors only trigger silencing (one summary line, then rate-limited) while the script's other callbacks keep running; an error in a one-shot callback is just printed. The old behaviour — a per-frame callback erroring 50 times closing the whole script (so even `onEndSong` never arrived) — is gone.
- **Callback hot paths**: the double dispatch of `onStepHit` / `onBeatHit` / `onSectionHit` to HScript is fixed (the base class and `PlayState` each dispatched once — now exactly once, with the same count, position and arguments as the old implementation); the same fix applies to `TitleState.beatHit`; `RecalculateRating()` pushes its seven per-hit script globals in two sweeps instead of seven; the step / beat / section arguments reuse the pooled `backend.Scripts` slot; `CompatEngine` version resolution is cached O(1) (`isModern()` no longer linear-scans and resolves twice, plus an explicit `refresh()`).
- **Fast note sort by default**: `fastSort` is renamed `stockNoteSort` and its default is inverted — the living+visible-only sort (the old `fasterNoteSort`) is the default path, and only an online match asks for the stock full sort; the offline benchmark differs 7–26x at 500–8000 slots (2000 slots: 0.607ms → 0.083ms per frame), with zero observable draw-order differences for visible notes over 400 randomized comparisons; old saves storing `fastSort = false` are upgraded automatically.
- **A new "Script Optimization" settings page**: Reuse Script Callback Arguments (on by default) plus Stock Event Drain / Stock BPM Lookup Objects / Stock HUD Text Rewrite (off by default, preserving stock behaviour for scripts that read `eventNotes`, hold BPM objects, or write HUD text directly).
- **Script diagnostics `logs/script_log.txt`**: recreated each launch, capped at 20,000 lines; records every loaded Lua script's path, every scanned script folder (marked `MISSING` when absent), every script error (script + callback + raw error text), and which scripts received the lifecycle callbacks (`onCreate` / `onCreatePost` / `onDestroy` / `onSongStart` / `onEndSong` / `onPause` / `onResume`, from a fixed allow-list); `[scan]` lines state `currentMod` and `globalMods` (exactly what decides whether a mod's `data/<song>/` is searched); `[save]` / `[snd]` lines diagnose save-field and tagged-sound lookups.
- **The HScript engine hscript-seiun 1.3.0**: a profiled parser / interpreter rewrite (about 16% faster parsing, about 38% faster execution); new syntax — or-patterns, guarded wildcard cases, destructuring extensions, generic functions, map comprehensions, wildcard imports, object spread; fixes for script-class constructors with arguments, `super.new`, `Math` / `Std` / `Map` resolution, ClassExtendMacro deprecation warnings, `hscript.Bytes` (versioned format), `hscript.Async`, and eleven `Printer` defects.

#### Gameplay: Botplay NPS, results screen and note sustains

- **Turbo / Botplay HUD**: the Turbo label reads `TURBO BOTPLAY`; the score line reads `Notes: opponent + bf = total | NPS | HP`; NPS uses a monotonic-clock 1-second sliding window (100×10ms) with a fast rise / slow fall trajectory (a one-frame burst of 5000 decays over about 1.47 s), maxima keep the true window peaks, a script writing `opCombo` cannot fake a burst, and overly long numbers compact to stay on one line.
- **Results screen**: the perfect-plus bucket counts toward the note total (no more `FALSE` fallback icon); rating graphics fit a 240×90 frame (the 660×256 fallback no longer covers the card); the stats legend uses `fieldWidth = 0` so it never wraps, with graded shrinking (fixing the solid black block a wrapped row painted over its own field); the side HUD and the BOTPLAY / REPLAY / ms / judgement labels on camOther are hidden together.
- **Note sustain geometry (mod trimmed frames)**: sustain height normalization now uses the atlas's visible region height (a new `Note.sustainContentHeight()` unifies the four formulas in `setupNoteData` / `initNote` / `recalcSustainScale` / `resetNoteScaleForMania`); the falling-mode sustain anchor compensation sign is corrected (the near end lands exactly at `distance + swagWidth/2 + 0.45*stepCrochet`, independent of BPM / speed / trimming — the inverted sign used to bury the tail cap inside the sustain and grow the offset with BPM); the clip top edge uses the new `Note.contentTopInFrame()`. Default and built-in skins are bit-identical; measured on the Paranoia mod's `varelt-NOTE.png` across 150/522 BPM × 1.0/2.6 speed, the sustain's near end converges to 56.0 px in all four combinations, and tail-cap overlap goes from 69–121 px (buried) to 2.3–5.1 px (normal).

#### Crash diagnostics and symbols

- **Safe mode by default**: Haxe-level errors carry source file and line numbers out of the box (the linemap generation and refresh chain is fixed; `tools/refresh_linemap.ps1` is provided); the symbol flow is decoupled from the crash protection, so CI and release builds keep safe mode; a new `tools/symbolize_android.py` resolves Android crash addresses; `.map` symbols keep shipping separately on the Release, never inside the game archive.
- **Crash reports keep 150 lines of game log** (about 30 before), the native buffer grew to 32 KB, and the report context names the graphics settings in effect.
- **Group containers no longer dereference members whose memory is already gone**: such members are dropped from the container instead of being used.

#### Settings, localization and misc

- New settings pages: "Render" (the 9 recording options) and "Script Optimization" (4 options); the three chart-cache options; all strings ship in Simplified Chinese / Traditional Chinese / English.
- The options-layout check script baseline is fixed: new variables and pages registered, missing Traditional Chinese strings filled in, dead keys removed, and the literal `\n` in the English / Simplified Chinese render-page descriptions fixed; the three languages share one key set.
- Online strings use the same key set in all three languages; trace lines that previously had no key are localized.
- Opening a new file dialog while the previous one is still pending no longer throws into the main loop and kills the process: the state is reset, the attempt is logged, and `onError` runs; the chart editor's save / open paths were hardened accordingly.
- CI / releases: every release asset carries the real version (no more empty app versions); haxelib git auth is optional and non-fatal; the lime project file is pinned; the release body gains China mirror and accelerator links.

---

### October 11 - November 7, 2026 (0.2.2 Pre-Online.3)

> This entry records the final state of the whole Pre-Online.3 development cycle; intermediate states that later commits superseded or reverted (HUD text throttling and the hit-presentation queue, the graphics LRU and runtime atlas repack, the automatic diagnosis paragraph in crash reports) are not listed separately. The player-facing announcement is `release-notes/0.2.2preonline3.md`.

#### Charts: new container, fast loading, 64-bit counters

- **New chart container `.chartpack` (SEIUNPK1)**: a chart is stored as a skeleton plus a group stream — the skeleton keeps every byte except the contents of each `sectionNotes` array (section objects, unknown fields, events and formatting survive byte for byte) with a NUL where the array belongs; the group stream writes one record per distinct `(time, lane, sustain, type)` plus a repeat count (varint + zlib). Reading a pack expands a group into raw notes carrying `repeat`, so the folder never allocates per duplicate. Times on the BPM grid use tick deltas, otherwise float64, tested at a `1e-6 ms` tolerance.
- **Measured**: tool side, the 17 funeral JSONs `76,765,170,749 B (71.5 GiB)` become `20,834 B` (`3,684,610x`, 23.47 s, 392.8 MB peak); engine side, amphotercity's 34 files `45,217,329,492 B (42.11 GiB)` become `2,535,680 B (2.42 MiB)` (`17,832x`), and the full chart (33 parts / 386,282 sections / about 2.064 billion notes) loads in 6-8 s cold (550,954 representatives, ~1.7 GB peak) or 4.7 s from cache (~1.5 GB); a 32 MB / 1,521,362-note slice takes 0.04 s through `songLoad` against 2.73 s for the same JSON.
- **New tooling**: `tools/chartpack/chartpack.mjs` is now a streaming byte parser (never holds the chart in memory), fast-forwards repeated runs with exponent-doubling plus binary search over `memcmp`, keeps its group tables in typed arrays and reads straight out of a ZIP; a windowed `chartpack-ui.exe` (English + Chinese, drag and drop, live ratios, optional portable build) ships alongside. The container is still v1, so the engine does not need a rebuild, and the engine only reads packs — it never converts JSON on its own.
- **Native scan and fold (`source/ChartNative.hx`)**: phase one scans every part in parallel and produces the merged skeleton, each section's `sectionNotes` byte range and the exact note count; phase two reads those ranges, decodes on workers and folds on one consumer in chart order, emitting packed columns without creating a Haxe object on the workers. Any failure **falls back to the Haxe path**. It only runs under Turbo or above 12,000,000 notes, never for charts with Change Mania events.
- **Chart JSON and addressing**: a stray byte inside `sectionNotes` no longer throws — the parser skips to the next array and counts what it skipped; a part beyond 2 GiB uses 64-bit `seek` / `tell` (`_hx_std_file_seek64`) instead of silently reading from a truncated offset; the fold ceiling moves from 60 million to 400 million rows; the skeleton cache becomes `chartstream-scan-v2` and a cache that was not fully consumed is treated as corrupt and rebuilt.
- **Play counters become Int64**: score, combo, every judgement bucket, misses and total playable notes are `haxe.Int64`; saves and replays write decimal strings and read back Int / Float / String. The real root cause was not overflow — `Int64` handed to `haxe.Json` serialises as an object and deserialises into `Null Object Reference`, inside the audio-finished callback where the crash handler cannot reach it, which is why "writing the score at the end of a song crashed the game". The `details` array is plain numbers again. The Lua / HScript boundary converts everything to a number (hxcpp reflection boxes an `Int64` at or above 2^31, which arrived in Lua as `nil` and in HScript as string concatenation).
- **Note reuse and memory**: the shader object survives pooling (hue/saturation/brightness reset only), lane colours are memoised per `(mania, lane)` (the old code allocated three `Array<Float>` per call), and the Turbo representative ceiling moves from 512 to 65536 (matching the native folder). A non-streamed chart with at least 100,000 notes that the engine read from disk releases its raw `sectionNotes` after being converted and keeps a reload recipe.
- **Note materials**: one entry point now applies the material, fixing "some notes do not take their colour" when the pooled path skipped `reloadNote`; white-atlas Hurt Notes use the RGB palette (`0xFF101010` / `0xFFFF0000` / `0xFF990022`) instead of unconditionally looking for the absent `HURTNOTE_assets` and clearing the frames, and Hurt splashes stop inheriting the lane colour.
- **Strum shaders attach on demand**: eight idle strums no longer carry an identity `ColorSwap` (flixel batches by shader instance, so eight arrows were eight draws that could not merge with the falling notes); the shader attaches only while the lane colour is non-neutral and is dropped when it returns.

#### Graphics: atlas cropping, palettes and image memory

- **Memory backend rewritten**: `GfxPolicy` / `GfxLru` / `GfxRepack` are deleted (strong references, destroying still-referenced graphics, forced GC, runtime repacking, and device-specific C++ crash paths). The new `GfxMemory` only releases the CPU pixel copy of a large image (>=512x512) after upload, and OpenFL re-decodes on demand; it never destroys graphics, evicts the cache or touches GC. `GfxSource` removes the decoded bitmap from OpenFL's cache so the release is real.
- **Atlas crop (step 1)**: crops the atlas to the area its frames actually use and shifts frame coordinates by the same amount; `offset` / `sourceSize` / names / order are untouched and every frame's `parent` / `uv` / `offset` / sampled pixels are re-checked, rolling back on any mismatch. Less than 0.5% saved is skipped.
- **Atlas repack (step 2: per-frame trim, dedup, tight packing)**: each frame is trimmed to its opaque bounds, identical tiles are kept once and the rest is repacked into a new canvas with frame coordinates rewritten; `offset` is compensated so sprite position and size are unchanged. Cells are compared byte-for-byte before the swap and every frame is validated and sampled after it, rolling back on failure. Less than 5% saved is skipped. Rotated / flipped frames roll back entirely.
- **Palette textures**: an image with at most 256 distinct colours becomes an 8-bit index plus a 256-entry palette whose entries are the exact premultiplied BGRA bytes, sampled `NEAREST`, with the batch count unchanged. More than 256 colours, no CPU pixels, an already-uploaded texture, no 8-bit index format, a shader compile failure or a failed sample check falls back to RGBA per image.
- **Measured** (Windows debug boot snapshot): decoded 85.9 -> 82.7 (crop) -> 57.3 MB, GPU 85.4 -> 79.4 -> 55.6 MB; the palette alone is decoded -17.5 MB (-23.4%) and GPU -15.9 to -20.8 MB (-22.2% to -29.1%), with one eligible image at `166.3 -> 41.6 MB (-75.0%)`; Atlas repacking touched 8 of the 11 boot atlases (-9.6% / -10.0%) for about 0.50 s of load time; three real mod atlases went from 467.9 to 117.0 MB (350.9 MB saved). This saves VRAM, not resident memory — the working set stayed inside +-3 MB.
- **GL submission cost**: the openfl fork caches viewport, texture bindings and an attribute-array bitmask and drops redundant `glEnable` calls, taking a fixed 95-draw frame from 3563 to 1746 GL calls (-51%); dynamic vertex buffers refresh in place with `bufferSubData` (falling back to `bufferData` only when they do not fit), with identical bytes reaching the GPU.
- **Options simplified**: "Texture Reuse Cache (LRU)" and "Runtime Texture Repack" are gone; "Big Texture RAM Release" becomes "Texture RAM Release" with the threshold lowered from 2048px to 512px, and "Clear Image Cache" now says images still in use are never touched.

#### Text: the HUD stays crisp, hit frames stop dropping

- **flixel fork**: the border pass goes from drawing the whole TextField once per offset (1 + 8 x `int(borderSize x borderQuality)`, 17 passes for the HUD) to rasterising the border colour once and stamping it with bitmap blits — 17 passes to 2, pixel-identical across 14 cases (byte-for-byte). Incremental rebuilds redraw only the device-pixel box covering the changed span and fall back to a full line whenever a safe box cannot be proven. An input signature skips rebuilds that would not change a pixel, and text whose signature has been stable for 750 ms is packed into a shared page (the menu's version block goes from 8 draw calls to 1, the whole menu from 14 to 7 batches).
- **openfl fork**: `TextField.setTextFormat()` no longer dirties the layout for a single-range, whole-field change that only touches non-metric properties.
- **Measured**: a score-line rebuild goes from `1594 to 1092 us` (median `2023 -> 1278 us`); the harness p50/p90/p99 at 1.5x goes from `788/1076/1389 to 185/234/391 us`; the layout triggered by a colour-only change goes from `148 to 0.3 us`; 541 samples compared with zero differing pixels.
- **HUD text behaviour is back to 0.6.3**: the hit-presentation queue, all text throttling and the 1x rasterisation cap are reverted (scripts read `scoreTxt` and `onUpdateScore` must see the new value on the frame of the hit, and 1x made text soft at higher window scales). The `Stock HUD Text Rewrite` option is deleted and the Script Optimization page drops from 4 entries to 3. Every saving above comes from the library patches, not from drawing less.
- **Splashes batch**: a neutral `ColorSwap` no longer attaches a shader, so several splashes share one batch.

#### Crash diagnostics: four paths, symbol files, one tool

- **Four paths, one exit**: `native` (SEH / signal), `haxe` (an uncaught exception reaching the top), `lime:*` (window / GL / audio / SDL init failing below Haxe) and `html5` (no native dialog, so the report is rendered into the page). Every report starts with `Kind:`, so the origin is never guessed from the file name; the native layer only leaves a `native_crash.pending` marker that the next start consumes before showing the crash screen.
- **Report contents**: `Kind` / `Date`, build identity (main module size and PE `TimeDateStamp`, whether a linemap is loaded), native diagnostics (OS, GPU and driver, environment, process directory, the real Win32 error code, with `LastError` snapshotted before the report writes anything), a `lime` module probe (ndll presence and bitness, raw `LoadLibrary` error) and the loaded module list. Reports are UTF-8 + BOM; Windows dialogs are UTF-16.
- **Symbols are always published**: the `hxcpp_symbols` switch is gone and a `<postbuild>` **moves** this link's `ApplicationMain.map` / `.pdb` (an unstripped `.so` on Android) into `export/symbols/<platform>-<mode>/` on every build, parking older bundles in `_stale/` and writing `build-info.txt` / `build.json` (exe size and PE `TimeDateStamp`). A report therefore carries `Build: 60396032B@1793431505s`, and the tool compares the same pair to decide whether a map belongs to that binary — an integer comparison, not modification times. The revision is inlined by `BuildStampMacro` asking git while Haxe compiles.
- **Tooling collapsed**: `tools/crash.py` replaces nine scripts (crash_triage / diag / mapresolve / verify_map / symbolize_android / gen_linemap / gen_linemap_msvc / linemap_compare / fnv1a) with status / report / bundle / ui / symbols / prune / triage / resolve / verify-map / symbolize / linemap subcommands. Splitting them was itself the bug: a report could be resolved against a map from a different build and every frame would still "resolve", to the wrong function.
- **Automatic advice removed**: the fixed "what / why / how to fix it" table is deleted from reports and dialogs (no table covers every failure, and a wrong guess is worse than none); the file carries facts, and the explanation comes from the issue thread.
- **Scope of verification**: only the Windows chain is verified end to end (report -> manifest -> resolution); Android / iOS / macOS locations are wired but not re-tested on device. Release builds carry no inline `[file:line]` by default (that needs a second build pass); `crash.py linemap` builds the table on demand.

#### Platforms and boot

- **iOS / macOS render scale**: new `backend/RenderScale.hx` lays the canvas out from the real stage-units-to-device-pixels mapping. The old `RatioScaleMode` computed the letterbox offset in one space and applied it in another, so on iOS/macOS the canvas moved right by `offset x pixelRatio`, the left stayed black and the right was clipped; a mismatch lays out inside the visible rectangle and logs `trace.render.inconsistent`, and a consistent stage renders exactly as before.
- **iOS fonts**: `.ttf/.otf` no longer go through `ByteArray.fromFile()` during extraction (on iOS the working directory is the Documents folder being filled), the readiness probes include `assets/fonts/vcr.ttf`, and the new `backend/FontRegistry.hx` registers a bundled font by absolute path and returns the family name, wired into `Paths.font` / `languageFont` / `optionsfont` with the matched path logged.
- **iOS / tvOS move to SDL3**: `lime-sdl3` covers `ios || tvos`, deployment target 13.0, device `universal`; iOS no longer defines `SDL_MAIN_HANDLED`, the frame loop is display-link driven without the first-tick stall, the home indicator is hidden, `DISPLAY_SCALE_CHANGED` is forwarded as a resize, device info reports the real iOS version and architecture, `applyStorageDirectory()` verifies the working directory, and boot logs and crash dumps carry a `Render scale: ...` line. Switching a platform needs one `lime rebuild <target>`.
- **Android**: the crash report resolves `dl_iterate_phdr` at runtime with `dlsym` (the NDK only declares it at API 21 while this project builds with android-16, so a direct call did not compile on armv7) and POSIX gets `MAX_PATH`; the online chat box can close the soft keyboard, the first BACK press closes the IME instead of leaving the results screen, and a text prompt with typed text can be cancelled with a double B.
- **Judgement order**: `buildRatingsData()` is back to 0=sick / 1=good / 2=bad / 3=shit with marvelous appended at index 4 and a "best judgement first" priority — marvelous used to occupy index 0 and shift the whole table, so online score recalculation weighted the wrong tier.
- **Boot path**: on Windows the storage root becomes the executable's directory (it was the process working directory), so a shortcut, a cmd launch or a different working directory still finds `assets` / `mods` / `crash`.

#### Interface

- **State transitions**: new `backend/transition/` (`TransitionDirector` / `TransitionStyle` / `WipeVisual` / `FadeVisual`) with Wipe (0.25 s in + 0.03 s held + 0.35 s out), Fade and Off, exposed as the `transitionStyle` option on the Visuals page. The old `CustomFadeTransition` name and its `finishCallback` / `nextCamera` statics are kept, and a transition destroyed mid-flight fires the callback once so the switch cannot be lost to a black screen.
- **Menu effects removed**: the aurora, particles, beat pulses, selection glow, entry animations and the freeplay preview glow / now-playing label / EQ bars are gone (`MenuFX.hx` and its call sites in three menu states, `quickMenuTransition`, the `seiuMenuFx` option and its strings in three languages) — 1004 lines removed, with zero references left in HEAD.
- **Credits**: a GitHub contributors block (up to 30, 150px avatars cached for 6 hours) reads from the disk cache, then the live endpoint, then a bundled snapshot, marking the section `. offline` / `. cached` when offline; `tools/gen_contributors.py` refreshes the snapshot.

#### Forked library changes

- **hxcpp (`seiunengine-4.3.175`, rebased from 4.3.2 onto upstream v4.3.175)**: the rebase is the largest performance change this cycle (the old fork measured a 57.9-66.9 ms max frame and a 53.5-62.9 ms stall; after the rebase 34.9-38.9 / 39.7-46.2 ms). It fixes a GC row-count regression (`uint8_t` counters wrapping on the 508-row blocks of `HXCPP_GC_BIG_BLOCKS`, which under-reported heap usage and triggered a collection on nearly every new block), adopts the upstream weak-key ephemeron work, adds a marking-stack prefetch (x86-64 only), rebuilds the finalizer table instead of erasing while iterating, retunes compaction (maximum free space 1 GB -> 512 MB; the author's own conclusion is that only the cadence moves the worst stall, 36.1-39.0 ms), moves `hx::Boot()` inside the `try` and routes exceptions into an optional `seiun_fatal_report()`, switches Windows dialogs to `MessageBoxW`, adds `_hx_std_file_seek64` / `tell64`, swaps zlib 1.3.1 for zlib-ng 2.3.90 (`ZLIB_COMPAT`) and fixes `haxe.zip`'s streaming decompressor returning cumulative counts, and restores the build progress display with an end-of-build list of recompiled files.
- **openfl**: cached GL state and in-place vertex buffer updates (-51% GL calls on the same frame); `BitmapData` `dropCPU` / `restoreCPU` / 8-bit index textures / opaque RGB textures; `Shader.gfxTryCompile` and re-parsing of generated shader parameter tables; `TextField.setTextFormat()` no longer re-lays out for a colour-only change.
- **flixel**: `FlxText`'s border stamp, incremental rebuilds, no-op skipping and static-text page packing; `FlxGraphic`'s CPU-copy release and restore, palette and repack plan slots, idempotent destroy and live-reference guards; camera canvases skip the per-batch quad bounds rescan; a state being re-created is no longer destroyed; the preloader is a minimal progress screen with the boot state drawing the logo.
- **lime**: new `FatalReport` (SDL / window / GL / audio init failures write `crash/lime_<kind>_<time>.txt` themselves); asset manifests resolve from the executable's directory; native rebuilds default to SDL3 so one `lime rebuild` cannot overwrite an SDL3 `lime.ndll` with an SDL2 one; the Apple SDL3 backend wiring.
- **hscript-seiun 1.4.0**: regex literals `~/pattern/flags`, object and array spreads, structural switch patterns, `enum abstract` and class generics; runtime errors carry the script call stack and a spelling hint. The author's own note is "performance-neutral to slightly faster", so no percentage is claimed.
- **hxvlc 2.3.1** (libVLC 3.0.23): the macOS `libvlc.dylib` / `libvlccore.dylib` were 14- and 18-byte text files containing a symlink target, so every checkout failed to link; they are real x86_64 + arm64 fat binaries now. A CPU `BitmapData` render path returns for the no-Stage3D case, concurrent `initAsync` no longer creates two instances, and video instances get leak guards.
- **linc_luajit**: the 15 platform prebuilts are rebuilt entirely by CI with an architecture check that reads ELF / Mach-O / COFF headers, each with a sha256 manifest; the multi-state callback-table leak is fixed.
- **flixel-ui / flixel-addons**: a bare `case ID:` in `FlxUICursor` resolved to the inherited `FlxBasic.ID` instead of `SortMethod.ID` and Haxe degraded it to a catch-all; it is now explicit. `@:enum abstract` becomes Haxe 4's `enum abstract`.

#### Notes / known limitations

- ⚠ **The four fork changes are not published to the remote yet** (14 commits on hxcpp's `seiunengine-4.3.175`, 5 on lime, 12 on flixel, 7 on openfl), and `hmm.json` still names `haxe-4.3` for hxcpp. Built from the current remote state in a clean environment, the result is the pre-rebase base — and nothing complains: **it compiles and runs, the GC work, crash routing, `seek64` and the progress bar are simply not in it**.
- Atlas cropping keeps only the area each frame actually uses: a mod that reads an atlas bitmap directly at absolute coordinates loses what was outside. Atlases going through `Paths.getSparrowAtlas / getAtlas / getAsepriteAtlas / getPackerAtlas` are handled automatically; ones loaded with `FlxAtlasFrames.fromSparrow()` directly are not. Palette sampling is `NEAREST`, so a scaled, rotated, smoothed sprite filters differently from the RGBA LINEAR path. This pipeline has no player-facing switch, only the `FNF_GFX_ATLAS_CROP` / `FNF_GFX_ATLAS_REPACK` / `FNF_GFX_PALETTE` / `FNF_GFX_RGB` environment variables.
- The native fold path drops Alt Animation (`PlayState.nativeFoldToChartNotes` writes `'-alt'` and then overwrites it with `''`); it only affects Turbo / enormous charts on the native path. Recorded, not fixed.
- `.chartpack` is semantically equivalent, not byte-identical: note order within a section and number formatting can differ; when a base pack exists `<song>.parts.json` must ship with it or parts 2..N are not merged; the packer accepts only 3- or 4-scalar notes and errors on five or more; the tool needs Node 18+ and the UI needs .NET 4.8.
- With the Windows storage root now at the exe directory, installing into a read-only location fails to write saves and crash reports; macOS still uses `../Resources/` and Linux still uses the working directory. tvOS only has the define — no config and no CI, unbuilt and unverified.

---

### Acknowledgments

A huge thank you to all testers — your feedback has been invaluable in shaping SeiunEngine into what it is today.

---

*本日志覆盖 SeiunEngine 自 6.19 至 11.7 全部主要变动。*
*This changelog covers all significant changes from June 19 to November 7, 2026.*