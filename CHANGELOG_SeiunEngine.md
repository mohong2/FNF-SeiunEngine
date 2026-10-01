# SeiunEngine 更新日志 · Changelog

> 完整记录 2026年6月19日 至 10月1日 的所有改进、修复与突破
> A comprehensive record of every improvement, fix, and breakthrough from June 19 to October 1, 2026.

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

### 2026年10月1日（0.2.2 Pre-Online.2 · 第一部分）

> 本次更新**尚未完成**：下面是 0.2.2 Pre-Online.2 已经落地的第一部分，后续提交会继续追加。完整公告见 `release-notes/0.2.2preonline2.md`。

#### 谱面缓存

- 新增 `chart_cache/`（可执行文件旁）：把流式谱面 Note 循环的**输出**（完整 DTO）按列压缩落盘，第二次进同一张谱面直接回放，跳过骨架扫描 / 逐小节解析 / 折叠 / 排序。
- 失效判据是「每个分段文件的大小 + 修改时间 + 调用方配置串」，任何一项变化即 miss 并重写。
- 实测：12,608,616 条 Note 的列表里 7/12 个 Float 列、5/5 个 String 列与 splash 块恒定 ⇒ 1.78 GB 压到几 MB（设置项实测 290 MB → 2 MB），读写时最多持 1 MB 块；45 GB 的 amphotercity（2,064,278,444 taps → 4,291,710 代表点）缓存为 `.skel` 14,215,997 B + `.notes` 12,855,326 B。
- 新增设置：Huge Chart Cache / Compress the Chart Cache / Clear the Chart Cache（三语）。

#### 谱面加载

- 选歌预览不再解析整张谱面：`PRELOAD_ALL` 下每次选中都会 `loadFromJson()`，2 GB 谱面要几秒；现在识别为流式尺寸就跳过预览解析并 trace。
- 没有 `events` 字段的谱面也能流式加载（字节级负索引判据），slide20（2,105,875,665 B / 153,955,328 notes）不再退回整份 DOM 解析 —— 那正是 Freeplay 卡死的原因。
- 分段谱面识别放宽：任意起始编号（miragist 从 0、amphotercity 从 1，以后从 5 或 100 起同理），断号只 trace 不作废，编号文件少于 2 个仍按单文件；`<song>.json` 闸与 `.parts.json` 清单不变。11 例回归（合成 7 + 真实 4）全部符合预期。

#### Turbo / Botplay 与结算界面

- Turbo 下 Botplay 标签显示 `TURBO BOTPLAY`；分数行改为 H-Slice 风格：对手命中 + bf 命中 = 合计、两侧 NPS（当前/峰值）与合计、HP（仅自动打谱，手动模式逐字节不变）。
- NPS 用 1 秒滑动窗口（100×10ms）+ 快起慢落弹道：一帧 5000 的突发约 1.47 秒平滑回零；峰值取窗口真值；脚本写 `opCombo` 不会伪造爆发。
- 结算界面：评分图标把「超完美」计入总数（此前 Turbo 全判超完美 ⇒ 总数 0 ⇒ 落到 `FALSE` 兜底图）并按 240×90 的框缩放（兜底图 660×256 不再压满卡片）；统计图例改 `fieldWidth = 0` 永不换行（此前折行还会在文字域上画出一块 155×46 的纯黑），数字过长自动紧凑化；顺带隐藏 camOther 上的 side HUD 与 BOTPLAY/REPLAY/ms/判定文字。

#### Lua / HScript 兼容

- 补上 `addWiggleEffect` / `removeWiggleEffect`（H-Slice 签名）。
- `setProperty` 写未知 state 字段不再抛 `Invalid field:...` 中断回调，改为存为脚本变量 + trace。
- `cameraFade` 补上第 5 个 `?fadeOut` 参数（4 参数行为不变，实测 mod 里 8 处调用只有 1 处用 5 参数）。
- 脚本错误循环保护：只有每帧 / 每步回调计入连续错误计数。

（2026-10-01，日志还是 AI 代笔。）

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

### October 1, 2026 (0.2.2 Pre-Online.2, first slice)

> The update is **not finished yet**: this is the first slice of 0.2.2 Pre-Online.2 that has landed, and later commits keep appending to it. Full announcement: `release-notes/0.2.2preonline2.md`.

#### Chart cache

- New `chart_cache/` next to the executable: the *output* of a streamed chart's note loop (complete DTOs) is written column-compressed, so the next load replays it and skips the skeleton scan, the per-section parse, the fold and the sort.
- Validity is "every chart part's size and modification time plus the caller's configuration string"; anything else is a miss and the file is rewritten.
- Measured: on a 12,608,616-note list 7/12 Float columns, all 5 String columns and the splash block were constant, so 1.78 GB became a few MB (the option text measures 290 MB against 2 MB compressed); at most one 1 MB block is held in memory. amphotercity (45 GB, 2,064,278,444 taps -> 4,291,710 representatives) caches to `.skel` 14,215,997 B + `.notes` 12,855,326 B.
- New options: Huge Chart Cache / Compress the Chart Cache / Clear the Chart Cache (three languages).

#### Chart loading

- Song select no longer parses a whole chart to preview it: under `PRELOAD_ALL` every selection ran `loadFromJson()` (seconds for a 2 GB chart); a streaming-sized chart now skips the preview parse and traces the skip.
- Charts without an `events` field can stream too (byte-level negative-index test), so slide20 (2,105,875,665 B / 153,955,328 notes) no longer falls back to a whole-file DOM parse -- the reason Freeplay used to freeze on it.
- Split-chart detection accepts any starting number (miragist from 0, amphotercity from 1, and 5 or 100 would work the same), a hole is only traced instead of refusing the set, and fewer than two numbered files still means a single chart. The `<song>.json` gate and the `.parts.json` manifest are unchanged. All 11 regression cases (7 synthetic + 4 real) behave as intended.

#### Turbo / Botplay and the results screen

- Turbo's botplay label reads `TURBO BOTPLAY`; the score line became H-Slice style: opponent hits + bf hits = total, per-side NPS (current/max) and the combined pair, plus HP (botplay only; manual play is byte-identical).
- NPS uses a one-second sliding window (100 x 10 ms) with fast attack / slow release: a single-frame burst of 5000 fades out over about 1.47 s, the maxima keep the exact window peaks, and a script writing `opCombo` cannot fake a burst.
- Results screen: the rating icon now counts the marvelous bucket (Turbo judged everything marvelous, so the total was zero and the icon fell back to the `FALSE` asset) and is fitted into a 240x90 box (the 660x256 fallback no longer covers the card); the hit legend uses `fieldWidth = 0` so it never wraps (a wrapped row painted a 155x46 pure-black box over its own field) and compacts long counts; the side HUD and the BOTPLAY/REPLAY/ms/judge labels on camOther are hidden too.

#### Lua / HScript compatibility

- `addWiggleEffect` / `removeWiggleEffect` added with H-Slice's signature.
- `setProperty` on an unknown state field no longer throws `Invalid field:...` and aborts the callback; the value is kept as a script variable and traced.
- `cameraFade` gained the fifth `?fadeOut` argument (the four-argument form is unchanged; only 1 of the 8 calls in the installed mods uses five).
- Script error-loop protection: only per-frame / per-step callbacks count towards the consecutive-error counter.

(2026-10-01, changelog written by AI as usual.)

### October 2, 2026 — Psych Engine 1.0.4 compatibility pass

> The engine has always been a 0.6.3 fork with a `compatEngine` switch, but the 1.0.4 side of that
> switch was mostly a label. Psych 1.0.4 relaxed a batch of Lua parameters from required to optional;
> this engine kept registering the old, required signature, so a 1.0.4 mod that omitted one got
> `nil` for a `String` parameter, called a method on it, and took the process down with a native
> access violation that no Haxe `try/catch` can trap. This round makes the 1.0.4 API complete.

#### Lua API surface: 62 divergent signatures closed, 2 functions added

- Every callback Psych 1.0.4 relaxed is now relaxed here too: `doTween*` / `noteTween*` `ease`,
  `mouseClicked/Pressed/Released` `button`, `getMouseX/Y` + `getScreenPositionX/Y` `camera`,
  `keyJustPressed/Pressed/Released` `name`, `makeLuaText` (all four), `makeAnimatedLuaSprite` /
  `loadFrames` `spriteType`, `playMusic` / `playSound` `volume` (+ `playSound` `loop`),
  `precacheImage` `allowGPU`, `triggerEvent` `value1/value2`, `getObjectOrder` /
  `setObjectOrder` / `removeLuaSprite` `group`, `deleteFile` `absolute`,
  `setProperty` / `setPropertyFromClass` / `setPropertyFromGroup` `allowInstances`,
  `getPropertyFromGroup` / `setPropertyFromGroup` `allowMaps`, `startVideo` (all four new):
  `canSkip`, `forMidSong`, `shouldLoop`, `playOnLoad`.
- Types that blocked real mods are widened: `addAnimation` takes `Any` frames (array *or* the
  `'0,1,2'` string form 1.0.4 accepts) with the `prefix == null` branch; animation framerates are
  `Float`; `setGraphicSize` takes `Float` x/y. The vendored flixel still wants `Int` there, so
  conversion goes through a NaN-safe `safeInt()`.
- `removeFromGroup` now answers both dialects: `(group, ?index, ?tag, ?destroy)` when the third
  argument is not a Bool, and the historical `(group, index, dontDestroy)` when it is -- no 0.6.3
  mod changes meaning.
- Version-dependent defaults moved behind `CompatEngine` instead of being copied from 1.0.4:
  `setHealth()` is 0 on 0.6.3/0.7.3 and 1 on 1.0.4, `setAchievementScore()` is 1 vs 0,
  `setObjectCamera()` is `''` vs `'game'`, `loadFrames`/`makeAnimatedLuaSprite` default to
  `sparrow` vs `auto`.
- Added the two missing 1.0.4 functions, `getFileTranslation` and `getTranslationPhrase`, backed
  by a new reader for 1.0.4's plain-text `data/<language>.lang` format (merged with the engine's
  native JSON language tables, `{1}`/`{2}` substitution included). `Paths.getAtlas` /
  `Paths.getAsepriteAtlas` were ported so `'auto'` really auto-detects the atlas format
  (sparrow XML → texture-packer/aseprite JSON → packer TXT). HScript gained `getModSetting` and
  optional-argument `keyJustPressed` / `keyPressed` / `keyReleased`.

#### Mod JSON is parsed the way 1.0.4 parses it (the "many 1.0.4 mods don't fit" half)

- Psych 1.0.4 reads mod data with `tjson.TJSON.parse`, and tjson **tolerates trailing commas and
  `//` / `/* */` comments**. This engine used strict `haxe.Json.parse` in the same places, so a
  `pack.json` ending in `"color": [0, 0, 0],\n}` simply failed to load. The shipped crash logs
  had it six times per session: `加载 pack.json 失败: Invalid char 125 at position 147` (125 is
  `}`), and 2 of the 21 pack.json files in the installed mods have exactly that trailing comma.
- **Measured on a real mod**: `mods/SonicTheFunkChinese/pack.json` ends with `"color": [0, 0, 0],\n}`.
  `tjson` parses it (`runsGlobally=true`), strict JSON throws `Invalid char 125 at position 147`.
  `Paths.pushGlobalMods()` sits inside a `try/catch` that only logs, so the throw meant the mod was
  **never registered as a global mod** -- before the fix the engine listed 2 global mods, after it
  lists 3, and the third one is `SonicTheFunkChinese`. Everything that resolves through
  `Paths.modFolders` (global-mod assets, `data/<song>/` scripts, `scripts/`) was affected.
- New `backend/JsonUtil.parseTolerant` (tjson first, strict parser as fallback) is now used at the
  sites where 1.0.4 uses tjson: `pack.json` (ModConfig, ModsMenuState, ModsMenuStateOld,
  ModSelectSubstate, and Paths' global-mod scan), `stages/*.json`, `data/settings.json`
  (`getModSetting`), and `images/gfDanceTitle.json`. Song / Character / Dialogue keep strict
  parsing, because 1.0.4 is strict there too.

#### Callback arguments

- `eventEarlyTrigger` is called with `(event, value1, value2, strumTime)` and `doTween*` reports
  `onTweenCompleted(tag, vars)`, both matching 1.0.4. 0.6.3 scripts that declare one parameter are
  unaffected -- extra arguments are ignored by both Lua and HScript.

#### Script hardening (fewer ways for a script to kill the process)

- `makeLuaSprite()` / `makeAnimatedLuaSprite()` / `makeLuaText()` / `makeFlxAnimateSprite()` /
  `createInstance()` skip safely when the tag is missing instead of dereferencing `null`; the
  installed `SonicTheFunkChinese/data/menu/menu.lua` literally contains a bare `makeLuaSprite()`.
- `safeColor()` replaces the twelve hand-rolled hex conversions, so `setTextBorder('scoreTxt', 4)`
  landing on a `null` colour (present in the installed Deathmatch mod) yields opaque white rather
  than an access violation. `cameraFromString(null)` no longer calls `toLowerCase()` on `null`.

#### Fixed: `close()` closed the wrong script (the reason SonicTheFunkChinese's custom menu never appeared)

- `Lua_helper.callbacks` is a **static** name→function map in linc_luajit: every Lua state registers
  its same-named callbacks into one shared table, so **the last-created instance wins**. Our
  `addLocalCallback` passed the real closure into that global table (Psych 1.0.4 passes `null` and
  keeps the function in its own per-instance map), so the `this` captured by `close()` was not
  necessarily the script that called it.
- Measured consequence on SonicTheFunkChinese: the mod ships 19 Lua scripts; `data/menu/menu.lua`
  is loaded **last**, and `scripts/MetalJet.lua` / `scripts/PEELOUTlegs.lua` call `close()` inside
  their `onCreatePost`. Those calls set `closed = true` on `menu.lua` instead of on themselves, so
  `callOnLuas('onCreatePost')` skipped it. The custom menu was never built, the game sat in the
  empty `Menu` chart with the engine HUD visible, and the only surviving evidence was the `cursor`
  sprite its `onCreate` had already created. The log showed it exactly: 18 scripts loaded,
  `luaArray=11` before the dispatch, and `onCreatePost` reaching the other 10.
- Fix: `FunkinLua.executing` now records the instance whose callback is running (`call()` became a
  thin wrapper around `callInner()`, restoring the previous value so nested dispatch still works),
  and `close()` acts on **that** script. `getModSetting` reads `modFolder` from the same pointer,
  because with several global mods loaded the "last registered" instance could belong to another mod.
- `close()` now also logs `CLOSE() <script>` so this class of bug is visible in `script_log.txt`.

#### Fixed: native crash in `callMethodFromClass(... 'mouse.overlaps' ...)` (SonicTheFunkChinese `Extras`)

- Crash report `0xC0000005 read at 0x0` in `states.PlayState | song=Extras`. The map-resolved backtrace
  was unambiguous: `flixel::input::FlxPointer_obj::overlaps + 0x246` ←
  `FunkinLua_obj::callMethodFromObject` ← `Lua_helper_obj::callback_handler` ← `PlayState_obj::callOnLuas`.
  A mod passed a null object into a flixel method:
  `callMethodFromClass('flixel.FlxG', 'mouse.overlaps', {instanceArg('tag'), instanceArg('camHUD')})`.
- **Root cause: `instanceArg()` never resolved modchart objects.** Psych keeps modchart sprites, modchart
  texts and script variables in one `MusicBeatState.getVariables()` map, so
  `instanceArg('someSprite')` resolves naturally. This engine keeps them in three separate maps
  (`modchartSprites` / `modchartTexts` / `variables`) and `parseInstances` only consulted
  `getVarInArray`, i.e. the variables map plus reflection -- so **every** `instanceArg('modchartTag')`
  came back `null`. The null then went straight into `FlxPointer.overlaps` and faulted.
- Fixes: `parseInstances` resolves the first segment through `PlayState.getLuaObject()` (modchart
  sprites/texts) before falling back to `getVarInArray`, and `callMethodFromObject` now skips the call
  with a logged warning when an `instanceArg` did not resolve, instead of invoking a method with null.
  `callMethod` / `callMethodFromClass` were changed to hand it the raw argument array so that
  distinction is still available.
- Two tolerance aliases were added for scripts that use a name Psych never had:
  `doesLuaSpriteExist` / `doesLuaTextExist` (`squaretransition.lua` in the same mod calls the former
  and errored on every `onTimerCompleted`, spamming the log). They forward to the existing
  `luaSpriteExists` / `luaTextExists`; the API gate now reports 295 callbacks.

#### Fixed: the engine mouse cursor leaked into gameplay

- SeiunEngine's own menus turn Flixel's software cursor on (`FreeplayState`, `MainMenuState`,
  `ModsMenuState`, `OptionsState`), and `PauseSubState` turns it on for its clickable items -- but
  nothing ever turned it back **off**. A mod that draws its own cursor (SonicTheFunkChinese's
  `data/menu/menu.lua` positions a `cursor` sprite at `getMouseX('other')` every frame) therefore
  showed two cursors at once, and the software one stayed on screen after unpausing.
- PlayState 0.6.3/0.7.3/1.0.4 never display it (their menus never enable it), so `PlayState.create()`
  now sets `FlxG.mouse.visible = false` before any script runs -- identical to vanilla in all three
  compat modes, and a mod can still turn it back on from `onCreate`. `PauseSubState` now saves the
  previous value and restores it in `destroy()` instead of leaving the cursor on.

#### Performance: the script log no longer traces high-frequency callbacks

- The first version of the diagnostics logged **every** non-loop callback, which meant an
  open+write+close of `logs/script_log.txt` for `onEvent` / `onNoteHit` / `onKeyPress` -- measurable
  frame cost on a dense chart. `[cb]` is now restricted to a lifecycle allow-list
  (`onCreate`, `onCreatePost`, `onDestroy`, `onStartCountdown`, `onCountdownStarted`,
  `onSongStart`, `onEndSong`, `onGameOver`, `onGameOverStart`, `onPause`, `onResume`), which is
  exactly what is needed to answer "did this script get its callback?" and is written about ten
  times per song instead of thousands.

#### Strict 0.6.3 / 0.7.3 parity restored for two earlier changes

- `keyJustPressed` / `keyPressed` / `keyReleased` (Lua **and** HScript) only lower-case the key name
  when the simulated engine is 0.7.3 or 1.0.4. 0.7.3 and 1.0.4 both do `name.toLowerCase()`, 0.6.3
  does not, so the conversion is now gated on `!CompatEngine.is063()` and 0.6.3 behaves exactly as
  before.
- `safeColor()` keeps the historical lenient path outside 1.0.4: `'0xff' + color` followed by
  `Std.parseInt` (which partially parses, so `'zzz'` still yields 255 exactly like the old code).
  Only the 1.0.4 branch adds the hex validation that rejects garbage. `null` / empty is opaque
  white in every mode, because the old code crashed there.

#### Script diagnostics: `logs/script_log.txt`

- New `backend/ScriptLog`: a bounded, always-on text log next to the executable (recreated each
  launch, capped at 20,000 lines, any IO failure just stops writing). It records every loaded Lua
  script with its absolute path, every script folder that was scanned (with `MISSING` when the
  directory does not exist), every script error with its script name + callback name + raw Lua
  error, and which scripts received `onCreate` / `onCreatePost`.
- It also logs the line that matters most for "my mod's script never ran": `[scan] song=... path=...
  currentMod=... globalMods=[...]`, because whether a mod counts as the *current* or a *global* mod
  is exactly what decides whether `data/<song>/` is searched at all.
- Unit-tested for the append path and the line cap (`ScriptLog.write` uses `File.append(path)` +
  `writeString`; the two-argument form is `(path, binary:Bool)`, which silently breaks the log).

#### Fixed: `getDataFromSave()` threw away its default value (the reason the options screen was half-built and ESC did nothing)

- 0.7.3 and 1.0.4 resolve a missing save field to the caller's default; 0.6.3 returns the raw
  `Reflect.field(...)`, i.e. `null`. This engine had kept the 0.6.3 body, so any 1.0.4 mod that
  writes `x = getDataFromSave('save', 'field', 800)` got `nil` whenever *another* script had already
  called `initSaveData` for that save but the field itself was not written yet.
- Measured on SonicTheFunkChinese: `scripts/difficultyChanges.lua:3` runs `initSaveData('globalsave')`
  at load, and global scripts load before `data/options/options.lua`. So `options.lua:106`
  (`littlebuddyX = getDataFromSave('globalsave', 'littlebuddyX', 800)`) came back `nil`.
  `onCreatePost` then died at line 297 (`arithmetic on littlebuddyX`), which is why **the whole
  options menu was never built** after that point, and `onUpdatePost` died at line 1410
  (`getProperty('selectionOptions2.alpha') > 0` -> compare number with nil) **before** reaching the
  `keyJustPressed('BACK')` branch at line 1416 -- which is exactly why ESC could not leave the menu.
- Fix: non-0.6.3 modes use `Reflect.hasField(saveData, field) ? field : defaultValue`, matching the
  0.7.3 / 1.0.4 reference bodies line for line. `CompatEngine.is063()` keeps the historical raw
  lookup, so 0.6.3 mode is untouched.
- `getDataFromSave` is the only callback in the whole 1.0.4 Lua API with this "absent field ->
  default" contract (verified by grepping `psychlua/` for `hasField` / `?defaultValue`), so this
  closes the whole class rather than one symptom.
- `logs/script_log.txt` now records up to 40 `[save]` lines for the `missing-field` /
  `not-initialized` branches, so the next mod that depends on this fallback is diagnosable from the
  log instead of from a screenshot.

#### Fixed: the engine's own HUD extras ignored a mod's "hide the HUD" calls

- `KeyboardDisplay` (the key/KPS panel) and the side HUD (总命中数 / 连击 / 判定统计) are
  SeiunEngine-only widgets that live on `camOther`. A 1.0.4 mod hides the HUD by setting
  `scoreTxt` / `healthBar` / `iconP1` invisible one by one, which cannot reach them -- so they stayed
  drawn on top of the mod's own screen. Measured on SonicTheFunkChinese, whose main menu and options
  screen are fake songs: the options screenshot carried the full 8-line side HUD on the left and the
  KPS panel on the right, none of which exist in Psych 1.0.4.
- `PlayState.syncHudExtras()` now ties them to the standard HUD: a script setting `scoreTxt.visible`
  to false hides them too, and re-showing it brings them back. The user's own `hideHud` setting and
  online mode (which hides `scoreTxt` because it draws per-player score texts) are explicitly
  excluded, so those two paths behave exactly as before.
- `hideTransientHud()` (the results screen) sets a suppression flag, so the follow logic cannot
  re-light the widgets the results screen deliberately hides.

#### Fixed: keybind readout, tagged-sound properties, and the error loop killing whole scripts

- **`allowMaps` was ignored when reading.** All three reference engines contain
  `if(allowMaps && isMap(instance)) return instance.get(variable);` in `getVarInArray`; the port had
  dropped it (while `setVarInArray` kept it). So `getPropertyFromClass('backend.ClientPrefs',
  'keyBinds.note_left', true)` ran `Reflect.getProperty` on a `Map` and returned null -- the mod's
  whole keybind page printed `- - -` for every control. Restored.
- **Tagged sounds are stored as `sound_<tag>` again.** Psych 1.0.4's `playSound` puts the sound in
  `MusicBeatState.getVariables()` under `sound_<tag>`, which is how mods read
  `getProperty('sound_pausemus.time' / '.length' / '.playing')`. This engine only stored
  `modchartSounds`, so those reads were nil: SonicTheFunkChinese's `pauseMenu.lua:401`
  (`math.floor(currentTime / beatLength)`) aborted **on the first line of `onCustomSubstateUpdate`**,
  i.e. the pause menu's navigation and its item layout code never ran -- exactly the "pause menu
  cannot move + first item misaligned" report. Both maps are written now.
- **`stopSound()` / `pauseSound()` / `resumeSound()` / `getSoundTime()` / `setSoundTime()` without a
  tag now act on `FlxG.sound.music`**, as in 1.0.4. They were no-ops, so `stopSound()` (used by the
  mod to kill the previous fake-song menu's music) did nothing.
- **The error-loop guard no longer disables a whole script.** Once a per-frame callback errored
  `scriptErrorLimit` (50) times, the engine set `closed = true` and every later callback was dropped
  -- `onEndSong` included. Measured: SonicTheFunkChinese's `results.lua` errors at line 487 from the
  first frame (its own `accuracypercentresult` is only assigned in `onEndSong`), so the script was
  dead within a second and its results screen could never appear. 1.0.4 has no such mechanism: an
  erroring callback already aborts at the same line every frame, while the other callbacks keep
  working. The guard now only **silences** the repeated report (one summary line at the limit and
  one every 600 after), for Lua and HScript alike; the log cap and the perf win are unchanged.
- `getObjectDirectly()` now checks the state's shared variables map before the typed
  `getLuaObject()` (which returns `FlxSprite`), matching Psych's order and avoiding handing a
  `FlxSound` to something that expects a sprite.
- `logs/script_log.txt`'s `[save]` diagnostics now print each `(save, field)` pair once instead of
  spending the whole budget on the same entry every frame.
- For the record, the previously reported fixes are confirmed in the new log: no `options.lua`
  errors remain, `[save] missing-field ... default=800` shows the default now being honoured, and
  the mod's options/keybind screens build and render.

#### Crash triage: a GC-thread crash during a heavy song load, and the diagnostics for it

- A native crash was reported while entering `Break Down` (SonicTheFunkChinese). Resolved with the
  published map (`tools/verify_map.py` -> MATCH), the backtrace is **hxcpp's garbage collector**, not
  game code: `GlobalAllocator::SThreadLoop` -> `MarkContext::processMarkStack` ->
  `Array<Dynamic>::__Mark` -> `hx::MarkObjectArray`, faulting on a read at `0xFFFFFFFFFFFFFFFF`.
  That signature means the marker followed a bad element pointer inside an `Array<Dynamic>`; it is
  the classic result of a dangling pointer or of raw (unboxed) values living in a container the GC
  walks as objects.
- Evidence that it is not the script layer: the session's `logs/script_log.txt` has **zero Lua
  errors** (the new `[save]` diagnostics are all it contains), and `git status` shows the graphics
  pipeline in that window (`GfxRepack`, `AsyncGfxLoader`, `GfxLru`, `GfxPolicy`) carries none of this
  work -- those files are untouched by the compatibility pass.
- Because the crash report kept only ~30 log lines, the ones that matter (the texture that was just
  decoded / repacked / released) were missing. Diagnostics widened: the report now keeps 150 lines
  and the native buffer was raised to 32 KB, `AsyncGfxLoader` logs every decode (key, size, ms) and
  where the bitmap landed (tracked graphic vs pending), `GfxPolicy` logs every CPU-copy release with
  the image's dimensions, and the crash context line now carries `asyncGfx` / `cpuRelease` /
  `lowQuality` so the next report says which graphics settings were active.
- The suspects that pipeline exposes are the settings a player can toggle without a rebuild:
  `异步图片加载` (async decode on worker threads) and `大图内存释放` (CPU-copy release of images
  >= 2048px). Reproducing with each one off isolates whether the corruption comes from the async
  path or from the release path.

#### Hardening: the graphics pipeline can no longer write outside a texture

The GC-thread crash above is the classic *symptom* of either a dangling pointer or an out-of-bounds
write (the heap gets a bad container element, and the marker trips over it seconds later). The crash
was not reproducible, so instead of guessing at a fix, every path in that window that can produce one
was closed off:

- **Every pixel write now goes through `GfxRepack.blit()`.** The destination rectangle must fit
  completely inside the packed canvas and the source rectangle completely inside the source sheet,
  otherwise the blit is skipped and counted (`GfxRepack.boundsSkips`, with a warning the first time it
  happens). For valid input this is bit-for-bit the same call as before; for invalid input it can no
  longer touch memory outside a texture buffer.
- **The packed canvas is verified after allocation.** `new BitmapData(canvasW, canvasH)` is checked
  against the requested size before a single pixel is copied: if the platform clamped the allocation
  (the packer allows up to 16384px, which is not every driver's limit), the repack is abandoned and the
  caller keeps the original texture. Previously the copy loop trusted `canvasW/canvasH` locals and would
  have written past a smaller real buffer -- the exact "corrupt the heap, crash in the GC later" pattern.
- **A source whose CPU copy was released is never `copyPixels`ed.** Skipping every blit would have handed
  the game a fully transparent atlas, so `process()` now aborts the whole repack (`source-not-readable`)
  and the original texture stays. `blit()` carries the same check as a second line of defence.
- **Cross-thread publication is main-thread-owned.** `AsyncGfxLoader` used to allocate the result record
  *on the worker* and only then attach it to the shared map; now `enqueue()` allocates it, publishes it
  immediately, and the worker only fills its fields inside the mutex (`done` is the release barrier).
  The only object still created on a worker thread is the decoded `Bytes`, and it goes straight into an
  already-rooted record.
- **Release/cleanup failures no longer escape.** `GfxPolicy.tryRelease` records a CPU release only if
  `disposeImage()` actually succeeded, and the decoded bitmap's `dispose()` in `drain()` is wrapped, so a
  double free/late free cannot abort the loading state.

If a player still wants the most conservative path, the two existing settings do it without a rebuild:
turn off `异步图片加载` (slower load, identical rendering) and, if wanted, `大图内存释放` as well.

#### Fixed: `marvelous` leaked into the judgement name scripts read (accuracy + combo were both wrong)

- **Measured**: `marvelous` appears **zero** times in the Psych 1.0.4 tree (and 0.6.3/0.7.3); its ratings are
  `sick/good/bad/shit` (`Rating.loadDefault()`, `ratingsData[0].hits` = sicks). This engine inserts
  `new Rating('marvelous')` at `ratingsData[0]` and defaults `marvelousRatings = true` with a 25 ms window,
  so a well-timed hit sets `note.rating = 'marvelous'`.
- **Consequence in SonicTheFunkChinese**: `scripts/sonic UI.lua` maps judgements by name
  (`registerNoteHit`: `rating == 'sick' / 'good' / 'bad' / 'shit'`). A `marvelous` hit still increments
  `numnoteshit` but lands in no bucket, so `newaccuracy = (sick*100 + good*67 + bad*34) / numnoteshit`
  collapses, and `combocounterNEW` (only incremented inside `ratingAnim()`) stops growing. One leaked
  string explains both "the accuracy is wrong" and "the combo count is wrong".
- **Fix**: `FunkinLua.ratingForScripts()` rewrites the name **as scripts see it** (`marvelous` -> `sick`,
  exactly what the same <=25 ms hit would have been called in 1.0.4) in the dotted branch of
  `getProperty()` and in `getGroupStuff()` (which `getPropertyFromGroup` uses).
- **It is its own setting**: `ClientPrefs.judgementNameCompat` / `option.judgementNameCompat`,
  "1.0.4 Judgement Names for Mods" (Gameplay options, Judgement section), **on by default**. Turn it off
  and scripts read the raw `marvelous` again. It is declared in `assets/preload/data/options/gameplay.json`
  like every other option, so it needs no engine change to toggle and old saves keep the default.
- **With it on, marvelouse is still delivered**: the engine's own judgement -- side HUD, results screen,
  scoring, Leather hitsound, online, replays -- keeps using the real rating, and `Note` gained a
  `ratingRaw` field (written next to `rating`, reset by `recycle()`) so a script that *wants* the
  Marvelous tier can read `getProperty('notes.members[i].ratingRaw')` (or `PlayState.marvelouses`).
- Still gated on `CompatEngine.is104()` to honour the "0.6.3/0.7.3 modes must not change" rule; the same
  leak exists in those modes and the identical mapping can be enabled there on request. HScript reads the
  field directly rather than through these helpers, so an HScript mod sees `marvelous` either way
  (`ratingRaw` is readable there too).

#### Hardened: tagged-sound lookups, and diagnostics for them

- `playSound(name, vol, tag)` no longer stores a `null` in the `sound_<tag>` slot when the sound failed to
  build (a key present with a `null` value made `getProperty('sound_x.time')` read as "nothing here"
  instead of "no such tag"), and `stopSound`/completion remove the slot.
- `[snd]` lines in `logs/script_log.txt` (deduped, max 30) record every tagged `playSound`/`stopSound`
  with the active state, plus every `sound_<tag>` miss with the state and the variable-map size. That is
  what will pin down `gameOver.lua:117` (`getProperty('sound_gameovermusic.time')` was nil for the whole
  game-over screen -- 1472 occurrences) if it survives the next run.

### Acknowledgments

A huge thank you to all testers — your feedback has been invaluable in shaping SeiunEngine into what it is today.

---

*本日志覆盖 SeiunEngine 自 6.19 至 10.1 全部主要变动。*
*This changelog covers all significant changes from June 19 to October 1, 2026.*
