package states;

import substates.PauseSubState;
import substates.OldPauseSubState;
import substates.GameOverSubstate;
import substates.PlayStateResultsSubstate;
import script.hscript.HScript;
import backend.CompatEngine;
import backend.GfxPolicy;
import backend.GcState;
import haxe.display.Display.GotoDefinitionResult;
import flixel.graphics.FlxGraphic;
#if cpp
import Discord.DiscordClient;
#end

import Section.SwagSection;
import Song.SwagSong;
import WiggleEffect.WiggleEffectType;
import backend.seiun.ui.MenuFX;
import flixel.FlxBasic;
import flixel.FlxGame;
import flixel.FlxObject;
import flixel.FlxState;
import flixel.FlxSubState;
import flixel.addons.display.FlxGridOverlay;
import flixel.addons.effects.FlxTrail;
import flixel.addons.effects.FlxTrailArea;
import flixel.addons.effects.chainable.FlxEffectSprite;
import flixel.addons.effects.chainable.FlxWaveEffect;
import flixel.addons.transition.FlxTransitionableState;
import flixel.graphics.atlas.FlxAtlas;
import flixel.graphics.frames.FlxAtlasFrames;
import flixel.math.FlxRect;
import flixel.system.FlxSound;
import flixel.ui.FlxBar;
import flixel.util.FlxCollision;
import flixel.util.FlxSort;
import flixel.util.FlxStringUtil;
import haxe.Json;
import lime.utils.Assets;
import openfl.Lib;
import openfl.display.BlendMode;
import openfl.display.StageQuality;
import openfl.filters.BitmapFilter;
import openfl.utils.Assets as OpenFlAssets;
import editors.ChartingState;
import editors.CharacterEditorState;
import EKData.Keybinds;

import flixel.input.keyboard.FlxKey;
import Note.EventNote;
import Note.PreloadedChartNote;
import TurboDensity;
import openfl.events.KeyboardEvent;
import flixel.effects.particles.FlxEmitter;
import flixel.effects.particles.FlxParticle;
import flixel.util.FlxSave;
import flixel.animation.FlxAnimationController;
import animateatlas.AtlasFrameMaker;
import flash.media.Sound;
import Achievements;
import Replay;
import StageData;
import script.lua.FunkinLua;
import psychlua.LuaUtils;
import script.lua.DebugLuaText;
import DialogueBoxPsych;
import Conductor.Rating;
import backend.Ratings;
import mohong.TraceManager;
import popup.RatingPopup;
#if !flash
import flixel.addons.display.FlxRuntimeShader;
import openfl.filters.ShaderFilter;
#end

#if sys
import sys.FileSystem;
import sys.io.File;
#end
#if ONLINE_ALLOWED
import online.client.GameClient;
import online.client.OnlineSession;
import online.client.ProfileStore;
import online.shared.OnlineTypes;
import online.shared.SeiunProtocol;
#end


#if VIDEOS_ALLOWED
// hxvlc-backed hxCodec compatibility layer (see source/objects/hxcodec)
import vlc.MP4Handler as VideoHandler;
import backend.VideoPreloader;
#end

using StringTools;

// Stage backdrop system
import states.stages.StageBackdrop;
import states.stages.BaseStage;
import states.stages.SpookyStage;
import states.stages.PhillyStage;
import states.stages.LimoStage;
import states.stages.MallStage;
import states.stages.MallEvilStage;
import states.stages.SchoolStage;
import states.stages.SchoolEvilStage;
import states.stages.TankStage;

/**
 * 一趟数据层批量结算的累加器。
 * 同一个对象在一帧内被 fastSkipPastNotes 与物化路径共用, 帧末一次性交给
 * finishBulkFrame 做聚合表现 (避免逐条触发 popUpScore/RecalculateRating)。
 */
typedef BulkAccumulator = {
	var drainedHit:Int;
	var skippedHit:Int;
	var skippedHitHealth:Float;
	var skippedMiss:Int;
	var skippedMissHealth:Float;
	var oppDrained:Int;
}

@:allow(Replay)
class PlayState extends MusicBeatState
{

	public static var STRUM_X = 42;
	public static var STRUM_X_MIDDLESCROLL = -278;

	/** 多k: 当前谱面键数 (0 基, 3 = 4K, 8 = 9K, 17 = 18K)。 */
	public static var mania:Int = 3;

	public static var ratingStuff:Array<Dynamic> = [
		['F', 0.2], //From 0% to 19%
		['D', 0.4], //From 20% to 39%
		['C-', 0.5], //From 40% to 49%
		['C', 0.6], //From 50% to 59%
		['B', 0.69], //From 60% to 68%
		['A', 0.7], //69%
		['AA', 0.8], //From 70% to 79%
		['AAA', 0.9], //From 80% to 89%
		['AAAA', 1], //From 90% to 99%
		['AAAAA', 1] //The value on this one isn't used actually, since Perfect is always "1"
	];

	//public static var ratingStuff:Array<Dynamic> = [
	//	['You Suck!', 0.2], //From 0% to 19%
	//	['Shit', 0.4], //From 20% to 39%
	//	['Bad', 0.5], //From 40% to 49%
	//	['Bruh', 0.6], //From 50% to 59%
	//	['Meh', 0.69], //From 60% to 68%
	//	['Nice', 0.7], //69%
	//	['Good', 0.8], //From 70% to 79%
	//	['Great', 0.9], //From 80% to 89%
	//	['Sick!', 1], //From 90% to 99%
	//	['Perfect!!', 1] //The value on this one isn't used actually, since Perfect is always "1"
	//];

	//event variables
	private var isCameraOnForcedPos:Bool = false;

	var msTxtKade:FlxText;
	var msTween:FlxTween;
	var atkText:FlxText;


	#if (haxe >= "4.0.0")
	public var boyfriendMap:Map<String, Boyfriend> = new Map();
	public var dadMap:Map<String, Character> = new Map();
	public var gfMap:Map<String, Character> = new Map();
	#else
	public var boyfriendMap:Map<String, Boyfriend> = new Map<String, Boyfriend>();
	public var dadMap:Map<String, Character> = new Map<String, Character>();
	public var gfMap:Map<String, Character> = new Map<String, Character>();
	#end

	public var BF_X:Float = 770;
	public var BF_Y:Float = 100;
	public var DAD_X:Float = 100;
	public var DAD_Y:Float = 100;
	public var GF_X:Float = 400;
	public var GF_Y:Float = 130;

	public var songSpeedTween:FlxTween;
	public var songSpeed(default, set):Float = 1;
	public var songSpeedType:String = "multiplicative";
	public var noteKillOffset:Float = 350;

	public var playbackRate(default, set):Float = 1;

	public var boyfriendGroup:FlxSpriteGroup;
	public var dadGroup:FlxSpriteGroup;
	public var gfGroup:FlxSpriteGroup;
	public static var curStage:String = '';
	public static var isPixelStage:Bool = false;
	/** 0.7.3 兼容：当前 UI 风格，例如 "normal" / "pixel" / 自定义 stageUI。 */
	public static var stageUI:String = "normal";
	public static var SONG:SwagSong = null;

	/** Stage backdrop handler — manages background sprites, anims, and stage-specific logic. */
	public var stageBackdrop:StageBackdrop;
	public static var isStoryMode:Bool = false;
	public static var storyWeek:Int = 0;
	public static var storyPlaylist:Array<String> = [];
	public static var storyDifficulty:Int = 1;
	/** SeiunEngine 联机对局标记 (离线路径永远为 false)。 */
	public static var seiunOnline:Bool = false;
	public static var seiunSpectate:Bool = false;
	/** 联机服务器已发 GAME_START：跳过本地 ready/set/go，按服务器 3-2-1 开局。 */
	public static var seiunSkipLocalCountdown:Bool = false;
	#if ONLINE_ALLOWED
	static var prevOnlineJudgement:Array<Int> = null;
	static var prevOnlineJudgementPreset:String = "Leather Engine";
	static var prevOnlineMarvelous:Bool = true;
	// osu! 尾判已随离线侧一并移除 (原 prevOnlineTailOn / prevOnlineTailMult)。
	static var prevOnlineCompat:Bool = false;
	static var prevOnlineCompatEngine:String = "Auto";
	#end

	/** Difficulty text for HUD/pause: prefers the chart's own difficulty
	 *  name (imported osu!/Malody charts), falls back to the current
	 *  difficulty list entry. */
	public static function displayDifficultyString():String
	{
		if (PlayState.SONG != null && PlayState.SONG.difficultyName != null
			&& StringTools.trim(PlayState.SONG.difficultyName).length > 0)
			return StringTools.trim(PlayState.SONG.difficultyName).toUpperCase();
		return CoolUtil.difficultyString();
	}

	public var spawnTime:Float = 2000;

	public var vocals:FlxSound;
	public var vocalsPlayer:FlxSound;
	public var opponentVocals:FlxSound;

	/** 旧名兼容：0.6.3/0.7.3 的 vocalsOpponent == 现在的 opponentVocals。 */
	public var vocalsOpponent(get, set):FlxSound;
	function get_vocalsOpponent():FlxSound return opponentVocals;
	function set_vocalsOpponent(v:FlxSound):FlxSound return opponentVocals = v;

	/** 1.0.4 兼容：playerVocals == 现在的 vocalsPlayer。 */
	public var playerVocals(get, set):FlxSound;
	function get_playerVocals():FlxSound return vocalsPlayer;
	function set_playerVocals(v:FlxSound):FlxSound return vocalsPlayer = v;

	/** 0.7.3 兼容：独立 instrumental 音轨别名，指向当前音乐。 */
	public var inst(get, set):FlxSound;
	function get_inst():FlxSound return FlxG.sound.music;
	function set_inst(v:FlxSound):FlxSound return FlxG.sound.music = v;


	public var dad:Character = null;
	public var gf:Character = null;
	public var boyfriend:Boyfriend = null;

	public var notes:FlxTypedGroup<Note>;
	public var sustainNotes:FlxTypedGroup<Note>; // Kept for Lua compatibility (empty)
	public var unspawnNotes:Array<PreloadedChartNote> = [];
	public var eventNotes:Array<EventNote> = [];

	public var notesAddedCount:Int = 0;
	/** Last materialized Note per lane/side, used to rebuild prevNote/nextNote chains on lazy spawn. */
	private var lastSpawnedNote:Map<Int, Note> = new Map<Int, Note>();
	/** Per-state recycled Note pool. Dead notes stay in notes.members and are revived in place. */
	private var notePool:Array<Note> = [];
	/** Reusable buffers for fasterSort (only visible/alive notes are sorted; dead slots keep their position). */
	private var _noteSortArr:Array<Note> = [];
	private var _noteSortIdx:Array<Int> = [];
	private var _noteSortRange:Int = 0;
	/** 缓存的排序比较器 (每 state 只创建一次, 避免每帧 lambda 分配)。 */
	private var _cmpNoteY:Note->Note->Int = null;
	private var _cmpIntAsc:Int->Int->Int = null;
	/** True while this PlayState has disabled the hxcpp GC (restored in destroy). */
	private var _gcDisabledForSong:Bool = false;
	/** H-Slice 风格离屏剔除: 每帧重算的滚动方向可视距离 (世界像素, 含缩放/旋转余量)。 */
	private var _cullDistPlayer:Float = 2200;
	private var _cullDistOpponent:Float = 2200;
	/** 存活 Note 计数: 由每帧 update 钩子刷新, 生成循环 O(1) 读取 (替代 countLiving 全表扫描)。 */
	private var _frameAliveTally:Int = 0;
	private var _lastAliveTally:Int = 0;
	/** notes.members 空槽扫描游标: 让追加 Note 从 O(n) (indexOf+getFirstNull) 降为均摊 O(1)。 */
	private var _noteSlotCursor:Int = 0;

	// ── 命中表现层合并 (万级 NPS 降阶核心): 分数文本/评级弹窗/ms 文本 每帧最多刷新一次 ──
	/** 无脚本时 updateScore 只置脏标记, 帧末 flushScoreText() 统一重建一次文本。 */
	var _scoreTextDirty:Bool = false;
	var _scoreZoomDirty:Bool = false;
	/** ms 判定文本 (kadems) 同帧合并: 只保留最后一次命中的差值。 */
	var _msTextDirty:Bool = false;
	var _pendingMsText:String = null;
	var _pendingMsColor:FlxColor = 0xFFFFFFFF;
	/** 评级弹窗合并: 高密度命中帧只展示最新一次 (低密度帧保持原版逐击弹窗)。 */
	var _popupPending:Bool = false;
	var _pendingRatingImage:String = null;
	/** 每帧前 POPUP_IMMEDIATE_HITS 个命中保持原版逐击弹窗 (正常谱面行为完全不变)。 */
	static inline var POPUP_IMMEDIATE_HITS:Int = 8;
	var _popupImmediateBudget:Int = POPUP_IMMEDIATE_HITS;
	/** 每帧溅射生成预算 + 存活硬上限 (手动连击风暴下池化不再无界膨胀)。 */
	static inline var SPLASH_FRAME_BUDGET:Int = 16;
	public static inline var MAX_SPLASH_ALIVE:Int = 256;
	var _splashBudgetLeft:Int = SPLASH_FRAME_BUDGET;
	/** botplay 下角色 sing 动画 / strum 静态化的"每轨每帧一次"门控 (与 strumsHit 同步重置)。 */
	var _botCharAnim:Array<Bool> = [false, false, false, false, false, false, false, false];
	var _botStrumStatic:Array<Bool> = [false, false, false, false, false, false, false, false];
	/** 对手侧同理: sing 动画与 confirm 动画每轨每帧一次; static 化整帧一次。 */
	var _oppCharAnim:Array<Bool> = [false, false, false, false, false, false, false, false];
	var _oppStrumConfirm:Array<Bool> = [false, false, false, false, false, false, false, false];
	var _oppStaticSet:Bool = false;
	/** 当前处于离屏剔除驻留状态的 Note 数 (trace 观测用)。 */
	var _culledCount:Int = 0;
	/** 本帧数据级批量结算中累计的 Hurt Note 数 (finishBulkFrame 消费后清零)。 */
	var bulkHurtCount:Int = 0;
	/** 存活音符紧凑列表: 物化时追加, 回收时 O(1) swap-remove; 每帧只需遍历它。 */
	var activeNotes:Array<Note> = [];
	/** Reusable key-state buffers for keysCheck (avoid per-frame allocations on Android). */
	private var _keyHold:Array<Bool> = [];
	private var _keyPress:Array<Bool> = [];
	private var _keyRelease:Array<Bool> = [];
	private var _keyAnyHeld:Bool = false;
	/** Reusable pressed-lane buffer so multi-press batching doesn't allocate every frame. */
	private var _pressedLanes:Array<Int> = [];
	/** Reentrancy guard: scripts may call keysCheck() from callbacks; nested calls use fallback locals. */
	private var _keysCheckDepth:Int = 0;
	/** Reentrancy guard for keyPressed/keyPressBatch scratch arrays: nested script-driven presses use fresh locals. */
	private var _pressScratchDepth:Int = 0;
	/** Reusable keyPressed scratch arrays (outer-most call only; nested calls fall back to fresh arrays). */
	private var _keyPressedPressNotes:Array<Note> = [];
	private var _keyPressedSortedNotes:Array<Note> = [];
	/** Reusable keyPressBatch scratch arrays (outer-most call only; nested calls fall back to fresh arrays). */
	private var _batchLaneDown:Array<Bool> = [];
	private var _batchPressNotes:Array<Note> = [];
	private var _batchLaneNotes:Array<Array<Note>> = [];
	private var _batchLocalPress:Array<Note> = [];
	/** Same-frame mobile hitbox press queue for multiK batching (key + touch-time for online reporting). */
	private var _mobilePressQueue:Array<Int> = [];
	private var _mobilePressTimes:Array<Float> = [];
	/** Same-frame mobile release queue: preserve press→release order when a fast tap down+up lands in one frame. */
	private var _mobileReleaseQueue:Array<Int> = [];
	/**
	 * 可视物化地平线 (ms): 超出该时长的音符从物化到被离屏剔除之间根本不会进入屏幕,
	 * 构造精灵纯属浪费。由 refreshNoteCullRanges() 按真实屏幕几何 + 当前流速推导。
	 *
	 * 初值刻意取小: 倒计时开始前 refreshNoteCullRanges 还没跑过, 若沿用 2000ms,
	 * 低流速谱面第一帧就会按整整 2 秒的窗口把成千上万条 Note 全部物化。
	 */
	var _visHorizonMs:Float = 250;
	/** 上一次数据级批量推进消费的条目数 —— 引擎"是否跟不上到达速率"的过载信号。 */
	var _bulkDrainedLast:Int = 0;
	/** 过载状态滞回计数: drain 显著非零时置满, 之后逐帧衰减 —— 防止模式来回抖动。 */
	var _overloadFrames:Int = 0;

	// ── Turbo 模式: 屏幕像素级谱面合并 ──
	/** Turbo 总开关是否在本局生效。 */
	public var turboModeActive:Bool = false;
	/** 进入歌曲前保存的 perfMode/bulkSkip/fastSort, 退出时恢复 (Turbo 不持久篡改用户设置)。 */
	private var _turboPrevPerf:Bool = false;
	private var _turboPrevBulk:Bool = false;
	private var _turboPrevFastSort:Bool = false;
	/**
	 * Turbo 预处理把"屏幕上分不开"的 tap 折叠成代表 Note, 每条代表携带折叠数量
	 * (noteDensity)。同时存活精灵数因此只由流速与屏幕几何决定, 与谱面密度无关。
	 */
	/** 本局参与合并的 tap 条数 (未折叠前), 日志/诊断用。 */
	private var _turboRawTapCount:Int = 0;
	/** 每轨 cos/sin 缓存: 万级音符逐帧 trig → 每轨每帧一次 (方向本就按轨道常量)。 */
	var _playerLaneCos:Array<Float> = [];
	var _playerLaneSin:Array<Float> = [];
	var _oppLaneCos:Array<Float> = [];
	var _oppLaneSin:Array<Float> = [];
	/**
	 * 运行时像素级归属闸门状态 (每条 lane+side 一组) + 共享的数据层结算累加器。
	 *
	 * 加载期折叠已经按"屏幕像素间距"把重叠的 tap 收进代表 Note; 运行时闸门是第二道:
	 * 若运行中 songSpeed 被事件/缓动改写, 折叠结果与当前流速不再匹配时仍然有界。
	 */
	static inline var TURBO_KEEP_GAP_PX:Float = 4.0;
	private var _laneLastKeptTime:Array<Float> = [];
	private var _laneLastKeptRate:Array<Float> = [];
	private var _laneLastKeptSlow:Array<Float> = [];
	private var _bulkAcc:BulkAccumulator = {
		drainedHit: 0,
		skippedHit: 0,
		skippedHitHealth: 0,
		skippedMiss: 0,
		skippedMissHealth: 0,
		oppDrained: 0
	};

	public var limitNC:Int = 0;
	/** True if the loaded chart contains holds/sustains. Fast bulk-skip is disabled for such charts to avoid orphan sustain tails. */
	private var _chartHasHolds:Bool = false;
	public var noteLimit:Int = 1000;
	/** True once the music file reached its end but chart notes remain. */
	public var musicEnded:Bool = false;
	/** Virtual playhead time (ms) accumulated after the music ended. */
	public var postMusicTime:Float = 0;
	/** Strum time of the very last note, used to delay song end until it plays out. */
	public var lastChartNoteTime:Float = 0;

	private var strumLine:FlxSprite;

	//Handles the new epic mega sexy cam code that i've done
	public var camFollow:FlxPoint;
	public var camFollowPos:FlxObject;
	private static var prevCamFollow:FlxPoint;
	private static var prevCamFollowPos:FlxObject;

	public var strumLineNotes:FlxTypedGroup<StrumNote>;
	public var opponentStrums:FlxTypedGroup<StrumNote>;
	public var playerStrums:FlxTypedGroup<StrumNote>;
	public var grpNoteSplashes:FlxTypedGroup<NoteSplash>;

	public var camZooming:Bool = false;
	public var camZoomingMult:Float = 1;
	public var camZoomingDecay:Float = 1;
	private var curSong:String = "";

	public var gfSpeed:Int = 1;
	public var health:Float = 1;
	// Displayed health used for smooth healthbar transitions
	public var displayHealth:Float = 1;
	/** 0.7.3 兼容：图标受伤动画开关（iconShake 等脚本会读取）。 */
	public var iconsAnimations:Bool = true;
	public var combo:Int = 0;

	public var healthBarBG:AttachedSprite;
	public var healthBar:Dynamic;
	var songPercent:Float = 0;

	public var timeBarBG:AttachedSprite; //草你妈的LUA
	public var timeBar:Dynamic;


	public var keyboardDisplay:KeyboardDisplay;

	public var ratingsData:Array<Rating> = [];
	public var marvelouses:Int = 0;
	public var sicks:Int = 0;
	public var goods:Int = 0;
	public var bads:Int = 0;
	public var shits:Int = 0;

	public var sustainNotescore:Int = 0;
	private var sideHUDVisible:Bool = false;
	private var notehitlol:Int = 0;
	private var tnh:FlxText;
	private var cm:FlxText;
	private var sick:FlxText;
	private var good:FlxText;
	private var bad:FlxText;
	private var shit:FlxText;
	private var marv:FlxText;
	private var miss:FlxText;
	private static final tnhx:Int = -10;
	private static final cmoffset:Int = -4;
	private static final cmy:Int = 20;

	private var generatedMusic:Bool = false;
	public var endingSong:Bool = false;
	public var startingSong:Bool = false;
	private var updateTime:Bool = true;
	public static var changedDifficulty:Bool = false;
	public static var chartingMode:Bool = false;

	public var guitarHeroSustains:Bool = false;

	//Gameplay settings
	public var healthGain:Float = 1;
	public var healthLoss:Float = 1;
	public var instakillOnMiss:Bool = false;
	public var cpuControlled(default, set):Bool = false;
	inline function set_cpuControlled(value:Bool):Bool {
		if (ClientPrefs.data.turboMode) value = true; // Turbo 模式强制锁死 botplay
		cpuControlled = value;
		if (botplayTxt != null)
			botplayTxt.visible = (!ClientPrefs.data.hideHud) ? cpuControlled : false;
		return cpuControlled;
	}
	public var playOpponent:Bool = false;
	public var reverseNoteHit:Bool = false;
	public var practiceMode:Bool = false;

	public static var replayMode:Bool = false;

	public var botplaySine:Float = 0;
	public var botplayTxt:FlxText;
	public var replaySine:Float = 0;
	public var replayTxt:FlxText;
	#if ONLINE_ALLOWED
	public var onlineBadgeTxt:FlxText;
	var onlineWaitSyncTxt:FlxText = null;
	/** 起跑门闩: 本机玩家是否已按下 空格/回车 确认 (确认后等其他人)。 */
	var onlineGateConfirmed:Bool = false;
	/** 观战: 被跟随玩家 (右侧主角色) 的会话 id / 设备 id。 */
	var onlineFollowedId:String = "";
	var onlineFollowedDeviceId:String = "";
	/** 起跑门闩进度 [已确认, 总人数], 由服务器广播刷新。 */
	var onlineGateConfirmedCount:Int = 0;
	var onlineGateTotalCount:Int = 0;
	/** 本机谱面时间轴是否已上报 (上报后进入门闩确认阶段)。 */
	var onlineTimelineSent:Bool = false;
	/** PsychOnline 式: 玩家 id → 对局内角色实例 (自己 + 对手主角色 + 额外玩家角色)。 */
	public var onlinePlayerChars:Map<String, Character> = new Map<String, Character>();
	/** 玩家 id → 头顶用户名铭牌。 */
	public var onlineNameplates:Map<String, FlxText> = new Map<String, FlxText>();
	var onlineNameplateGroup:FlxTypedGroup<FlxText> = null;
	/** 左侧主角色 (对手) 的玩家 id; 其余远端玩家渲染为额外角色。 */
	var onlineMainOpponentId:String = "";
	/** 额外角色在左侧的排列序号 (决定 x 偏移)。 */
	var onlineExtraCharIndex:Int = 0;
	/** 对手实时分数 HUD (PsychOnline 式: 右上显示远端玩家分数)。 */
	public var remoteScoreTxt:FlxText;
	public var remoteScores:Map<String, Dynamic> = new Map<String, Dynamic>();
	var remoteScoreSig:String = "";
	#end

	/** LeatherEngine 移植: 回放判定手感还原提示 */
	public var judgeRestoreTxt:FlxText;
	/** osu! 尾判: HUD 开启标识 (一眼确认开关与构建生效) */
	//public var tailBadgeTxt:FlxText;
	var botplayUsed:Bool = false;
	var strumsHit:Array<Bool> = [false, false, false, false, false, false, false, false];
	var _suppressNoteAnim:Bool = false;
	public var replayExam:Replay;
	/** 回放模式按键状态数组 (由 replayApplyInput 设置) */
	private var _hold:Array<Bool> = [];
	private var _press:Array<Bool> = [];
	private var _release:Array<Bool> = [];

	// ---- osu! 尾判: 每轨当前按住的"长条头部"与尾端时间 ----
	/** 每轨活动长条的尾端时间 (0 = 无活动长条) */
	//private var activeTailEnd:Array<Float> = [];
	/** 每轨活动长条的头部 Note (取 hitHealth/missHealth 用) */
	//private var activeHoldNote:Array<Note> = [];
	/** 尾判判定窗口 = 普通判定窗口 × 倍率 (ClientPrefs.tailWindowMult, 默认 2.0; 兜底常量仅防异常值) */
	//private static final TAIL_WINDOW_MULT:Float = 2.0;

	/** 读取当前生效的尾判窗口倍率 (设置异常时回退默认 2.0)。 */
	//static inline function tailWindowMult():Float
	//{
	//	var m:Float = ClientPrefs.data.tailWindowMult;
	//	if (Math.isNaN(m) || m <= 0 || m > 8)
	//		return TAIL_WINDOW_MULT;
	//	return m;
	//}

	#if ONLINE_ALLOWED
	/** 当前联机对局的暂停策略 (everyone / hostOnly / disabled; 离线/无房间恒为 everyone)。 */
	public static function onlinePausePolicy():String
	{
		if (!OnlineSession.active || OnlineSession.settings == null)
			return online.shared.OnlineTypes.OnlineConst.PAUSE_EVERYONE;
		var p:String = OnlineSession.pausePolicy;
		if (p == null || p.length == 0)
			return online.shared.OnlineTypes.OnlineConst.PAUSE_EVERYONE;
		return p;
	}

	/** 本地玩家是否允许主动暂停 (仅房主/禁止暂停时, 非房主不允许)。 */
	public static function onlineCanPauseLocally():Bool
	{
		if (!seiunOnline || !OnlineSession.active)
			return true;
		var p:String = onlinePausePolicy();
		if (p == online.shared.OnlineTypes.OnlineConst.PAUSE_DISABLED)
			return false;
		if (p == online.shared.OnlineTypes.OnlineConst.PAUSE_HOST_ONLY && !OnlineSession.isHost)
			return false;
		return true;
	}

	/** 暂停被策略拦截时的短暂提示 (HUD 顶部, 1.8 秒后淡出)。 */
	var onlinePauseNoticeTxt:FlxText = null;
	var onlinePauseNoticeTimer:Float = 0;
	function showOnlinePauseNotice(text:String):Void
	{
		if (onlinePauseNoticeTxt == null)
		{
			onlinePauseNoticeTxt = new FlxText(0, 68, FlxG.width, "", 16);
			onlinePauseNoticeTxt.setFormat(Paths.languageFont(), 16, FlxColor.fromRGB(255, 200, 120), CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
			onlinePauseNoticeTxt.scrollFactor.set();
			onlinePauseNoticeTxt.cameras = [camHUD];
			add(onlinePauseNoticeTxt);
		}
		onlinePauseNoticeTxt.text = text;
		onlinePauseNoticeTxt.alpha = 1;
		onlinePauseNoticeTimer = 1.8;
	}
	#end


	public var iconP1:HealthIcon;
	public var iconP2:HealthIcon;
	public var camHUD:FlxCamera;
	public var camGame:FlxCamera;
	public var camOther:FlxCamera;
	public var cameraSpeed:Float = 1;

	var dialogue:Array<String> = ['blah blah blah', 'coolswag'];
	var dialogueJson:DialogueFile = null;

	public var dadbattleBlack:BGSprite;
	public var dadbattleLight:BGSprite;
	public var dadbattleSmokes:FlxSpriteGroup;

	public var halloweenBG:BGSprite;
	public var halloweenWhite:BGSprite;

	public var phillyLightsColors:Array<FlxColor>;
	public var phillyWindow:BGSprite;
	public var phillyStreet:BGSprite;
	public var phillyTrain:BGSprite;
	public var blammedLightsBlack:FlxSprite;
	public var phillyWindowEvent:BGSprite;
	public var trainSound:FlxSound;

	public var phillyGlowGradient:PhillyGlow.PhillyGlowGradient;
	public var phillyGlowParticles:FlxTypedGroup<PhillyGlow.PhillyGlowParticle>;

	public var limoKillingState:Int = 0;
	public var limo:BGSprite;
	public var limoMetalPole:BGSprite;
	public var limoLight:BGSprite;
	public var limoCorpse:BGSprite;
	public var limoCorpseTwo:BGSprite;
	public var bgLimo:BGSprite;
	public var grpLimoParticles:FlxTypedGroup<BGSprite>;
	public var grpLimoDancers:FlxTypedGroup<BackgroundDancer>;
	public var fastCar:BGSprite;

	public var upperBoppers:BGSprite;
	public var bottomBoppers:BGSprite;
	public var santa:BGSprite;
	public var heyTimer:Float;

	public var bgGirls:BackgroundGirls;
	public var wiggleShit:WiggleEffect = new WiggleEffect();
	public var bgGhouls:BGSprite;

    public var trackBackground:FlxSprite;
    public var trackColor:String = '000000';
    public var trackAlpha:Float = 0.3;
    public var scaleFactor:Float = 0.3;

	public var tankWatchtower:BGSprite;
	public var tankGround:BGSprite;
	public var tankmanRun:FlxTypedGroup<TankmenBG>;
	public var foregroundSprites:FlxTypedGroup<BGSprite>;

	public var songScore:Int = 0;
	public var songHits:Int = 0;
	public var songMisses:Int = 0;
	public var scoreTxt:FlxText;
	public var timeTxt:FlxText;
	public var scoreTxtTween:FlxTween;

	public static var campaignScore:Int = 0;
	public static var campaignMisses:Int = 0;
	public static var seenCutscene:Bool = false;
	public static var deathCounter:Int = 0;

	public var defaultCamZoom:Float = 1.05;

	// how big to stretch the pixel art assets
	public static var daPixelZoom:Float = 6;
	private var singAnimations:Array<String> = ['singLEFT', 'singDOWN', 'singUP', 'singRIGHT'];

	/** 多k: 按 Note 的快照 k 值/轨道取角色动作, 支持 Lua 自定义 (customCharAnim)。 */
	inline function getSingAnim(note:Note):String
	{
		if (note.customCharAnim != null && note.customCharAnim.length > 0) return note.customCharAnim;
		return 'sing' + EKData.getAnim(note.mania, note.laneData());
	}

	/** 多k: 按当前 k 值/轨道取角色动作。 */
	inline function getSingAnimDir(dir:Int):String
	{
		return 'sing' + EKData.getAnim(mania, Std.int(Math.abs(dir)) % Note.ammo[mania]);
	}

	public var inCutscene:Bool = false;
	public var skipCountdown:Bool = false;
	public var songLength:Float = 0;

	public var boyfriendCameraOffset:Array<Float> = null;
	public var opponentCameraOffset:Array<Float> = null;
	public var girlfriendCameraOffset:Array<Float> = null;

	#if cpp
	// Discord RPC variables
	var storyDifficultyText:String = "";
	var detailsText:String = "";
	var detailsPausedText:String = "";
	#end

	//Achievement shit
	var keysPressed:Array<Bool> = [];
	/** 多k 移动端: 触摸当前按住的轨道 (FlxHitbox 直接驱动, 供 keysCheck 长条按住判定用)。 */
	public var mobileHeld:Array<Bool> = [];
	var boyfriendIdleTime:Float = 0.0;
	var boyfriendIdled:Bool = false;

	// Lua shit
	public static var instance:PlayState;
	public var introSoundsSuffix:String = '';

	// Debug buttons
	private var debugKeysChart:Array<FlxKey>;
	private var debugKeysCharacter:Array<FlxKey>;

	// Less laggy controls
	public var keysArray:Array<Dynamic>;
	public var controlArray:Array<String>;
	//
	public var score:Int = 0;
	public var maxcombo:Int = 0;
	//
	public var precacheList:Map<String, String> = new Map<String, String>();

	// stores the last judgement object
	public static var lastRating:FlxSprite;
	// stores the last combo sprite object
	public static var lastCombo:FlxSprite;
	// stores the last combo score objects in an array
	public static var lastScore:Array<FlxSprite> = [];

	/** 评级弹窗对象池 */
	var ratingPopup:RatingPopup;

	/** 错键时间点 (用于联机结算展示)。 */
	public var wrongLaneTimes:Array<Float> = [];
	public var NoteMs:Array<Float> = [];
	public var NoteTime:Array<Float> = [];

	/** Frame counter for batched note cleanup — every N frames instead of every frame. */
	var _noteCleanupFrameCounter:Int = 0;
	/** Interval for batched note cleanup (in frames). Soft-coded for tuning. */
	static final NOTE_CLEANUP_INTERVAL:Int = 3;
	/** Frame counter for periodic unused-graphic purges (see Paths.purgeUnusedGraphics). */
	var _memoryPurgeFrameCounter:Int = 0;
	/** Purge useCount<=0 graphics roughly every 15 seconds (60fps x 900 frames). */
	static final MEMORY_PURGE_INTERVAL:Int = 900;

	/**
	 * Create the appropriate StageBackdrop for the current stage.
	 * Public fields on PlayState (halloweenBG, phillyWindow, etc.)
	 * are assigned inside each stage handler's create().
	 */
	function createStageHandler(stage:String):StageBackdrop
	{
		return switch (stage)
		{
			case 'stage':    new BaseStage(this);
			case 'spooky':   new SpookyStage(this);
			case 'philly':   new PhillyStage(this);
			case 'limo':     new LimoStage(this);
			case 'mall':     new MallStage(this);
			case 'mallEvil': new MallEvilStage(this);
			case 'school':   new SchoolStage(this);
			case 'schoolEvil': new SchoolEvilStage(this);
			case 'tank':     new TankStage(this);
			default:         new StageBackdrop(this, stage);
		}
	}


	override public function create()
	{
		// Entering play directly from the chart editor (or anywhere else)
		// may leave the difficulty list empty — fall back to the defaults so
		// difficulty displays never come out blank.
		if (CoolUtil.difficulties.length < 1)
			CoolUtil.difficulties = CoolUtil.defaultDifficulties.copy();
		#if ONLINE_ALLOWED
		// 离线路径必须复位联机标记, 防止上一局联机状态污染单机成绩。
		if (!online.client.OnlineSession.active)
			seiunOnline = false;
		if (seiunSkipLocalCountdown)
		{
			seiunSkipLocalCountdown = false;
			skipCountdown = true;
		}
		#end


		//trace('Playback Rate: ' + playbackRate);
		// Register song entry before clearing cache to allow LRU tracking
		GfxPolicy.onPlayStateCreate(SONG != null && SONG.song != null ? SONG.song : 'unknown');
		Paths.clearStoredMemory();
		// 旧 state 已在 switchState 中 destroy，useCount 已归零；
		// 这里立即清掉上一局残留的 currentTrackedAssets，避免反复重开/换歌后图片缓存只增不减。
		Paths.clearUnusedMemory();
		// for lua
		instance = this;
		debugKeysChart = ClientPrefs.copyKey(ClientPrefs.keyBinds.get('debug_1'));
		debugKeysCharacter = ClientPrefs.copyKey(ClientPrefs.keyBinds.get('debug_2'));
		PauseSubState.songName = null; //Reset to default
		playbackRate = ClientPrefs.getGameplaySetting('songspeed', 1);
		// replay 模式下 playbackRate 将在 replayExam.loadFromFile() 时从 StateRecord 恢复
		// H-Slice 风格 Note 上限: 0 = 无限 (仅高级用户)
		noteLimit = ClientPrefs.data.limitNotes;
		if (noteLimit <= 0) noteLimit = 2147483647;


		EKData.loadConfig();
		mania = (SONG.mania == null) ? Note.defaultMania : EKData.clampMania(SONG.mania);
		SONG.mania = mania; // 写回钳制结果, 避免谱面/编辑器与游戏不一致
		// 0.7.3/1.0.4 兼容: 每条新谱面重置全局 RGB 色板, 避免跨谱面/跨 mod 串色
		Note.globalRgbShaders = [];
		var allKeybinds:Array<Array<Dynamic>> = Keybinds.fill();
		keysArray = (mania >= 0 && mania < allKeybinds.length) ? allKeybinds[mania] : allKeybinds[3];
		setOnScripts('mania', mania);
		setOnScripts('keys', mania + 1);

		controlArray = [
			'NOTE_LEFT',
			'NOTE_DOWN',
			'NOTE_UP',
			'NOTE_RIGHT'
		];

		//Ratings — LeatherEngine 移植: 判定窗口由 judgementTimings 驱动
		buildRatingsData();

		#if ONLINE_ALLOWED
		onlineApplyRoomSettings();
		#end

		// For the "Just the Two of Us" achievement
		for (i in 0...keysArray.length)
		{
			keysPressed.push(false);
			mobileHeld.push(false);
		}

		if (FlxG.sound.music != null)
			FlxG.sound.music.stop();

		// Gameplay settings
		healthGain = ClientPrefs.getGameplaySetting('healthgain', 1);
		healthLoss = ClientPrefs.getGameplaySetting('healthloss', 1);
		instakillOnMiss = ClientPrefs.getGameplaySetting('instakill', false);
		practiceMode = ClientPrefs.getGameplaySetting('practice', false);
		turboModeActive = ClientPrefs.data.turboMode;
		if (turboModeActive)
		{
			// Turbo = 强制锁定 botplay, 无需考虑手动/回放/联机分支。
			cpuControlled = true;
			playOpponent = false;
			practiceMode = false;
			replayMode = false;
			// 内存中强制 perfMode/bulkSkip/fastSort, 退出歌曲时恢复, 不写入用户设置。
			_turboPrevPerf = ClientPrefs.data.perfMode;
			_turboPrevBulk = ClientPrefs.data.bulkSkip;
			_turboPrevFastSort = ClientPrefs.data.fastSort;
			ClientPrefs.data.perfMode = true;
			ClientPrefs.data.bulkSkip = true;
			ClientPrefs.data.fastSort = true;
			// Turbo 硬上限：真实 Note 最多同时存活 4096 个，保证高密度谱仍走真实 Note
			// 渲染但不会物化 7 万/秒的完整可见窗口。
			if (noteLimit > 4096) noteLimit = 4096;
		}
		cpuControlled = ClientPrefs.getGameplaySetting('botplay', false);
        playOpponent = ClientPrefs.getGameplaySetting('playOpponent', false);
        reverseNoteHit = ClientPrefs.getGameplaySetting('reverseNoteHit', false);
		guitarHeroSustains = ClientPrefs.data.guitarHeroSustains;
    	        if (cpuControlled) playOpponent = false;
                if (turboModeActive) { cpuControlled = true; playOpponent = false; practiceMode = false; }
                guitarHeroSustains = ClientPrefs.data.guitarHeroSustains;
		#if ONLINE_ALLOWED
		// 联机封堵: 屏蔽离线预设的 botplay/practice/instakill 读路径, 并强制关闭 (对手是远端真人, playOpponent 一并关)。
		ClientPrefs.onlineMaskCheats = seiunOnline;
		if (seiunOnline)
		{
			cpuControlled = false;
			practiceMode = false;
			instakillOnMiss = false;
			playOpponent = false;
		}
		#end
                replayExam = new Replay();
                add(replayExam);
                if (replayMode) {
                        Replay.dbgLog('[DEBUG-rpl] PlayState.create replayMode, preparedPath=' + Replay.preparedPath);
                        replayExam.loadFromFile(Replay.preparedPath);
                        Replay.dbgLog('[DEBUG-rpl] PlayState.create frames=' + replayExam.getFrameData().length);
			buildRatingsData();
			if (replayExam.judgementRestoredDifferent)
			{
				var rInfo:String = (replayExam.judgementRestoreInfo != null && replayExam.judgementRestoreInfo.length > 0)
					? replayExam.judgementRestoreInfo
					: Language.get("replayJudgeRestored", "Replay Judgement:");
				backend.Dialog.show(
					Language.get("replaySettingsRestoredTitle", "Replay Settings Restored"),
					Language.get("replaySettingsRestoredMsg", "This replay restores the original judgement settings used when it was recorded, so the score stays accurate.\n\n") + rInfo,
					'Warning');
			}
			// 回放模式下强制关闭 botplay/practice 防止冲突
			cpuControlled = false;
			practiceMode = false;
                } else if(!playOpponent) {
                        #if ONLINE_ALLOWED
                          // 联机局始终录制回放 (供结算页查看/保存回放, 异步模式随成绩上报)。
                          if (ClientPrefs.data.saveReplayData || seiunOnline)
                          #else
                          if (ClientPrefs.data.saveReplayData)
                          #end
                              replayExam.startRecording();
                }


		// var gameCam:FlxCamera = FlxG.camera;
		camGame = new FlxCamera();
		camHUD = new FlxCamera();
		camOther = new FlxCamera();
		camHUD.bgColor.alpha = 0;
		camOther.bgColor.alpha = 0;

		FlxG.cameras.reset(camGame);
		FlxG.cameras.add(camHUD, false);
		FlxG.cameras.add(camOther, false);
		grpNoteSplashes = new FlxTypedGroup<NoteSplash>();
		NoteSplash.liveCount = 0; // 新一局: 溅射存活计数归零 (上一局实例随 state 销毁)

		FlxG.cameras.setDefaultDrawTarget(camGame, true);
		CustomFadeTransition.nextCamera = camOther;

		persistentUpdate = true;
		persistentDraw = true;

		if (SONG == null)
			SONG = Song.loadFromJson('tutorial');

		Conductor.mapBPMChanges(SONG);
		Conductor.changeBPM(SONG.bpm);

		#if desktop
		storyDifficultyText = CoolUtil.difficulties[storyDifficulty];

		// String that contains the mode defined here so it isn't necessary to call changePresence for each mode
		if (isStoryMode)
		{
			detailsText = "Story Mode: " + WeekData.getCurrentWeek().weekName;
		}
		else
		{
			detailsText = "Freeplay";
		}

		// String for when the game is paused
		detailsPausedText = "Paused - " + detailsText;
		#end

		GameOverSubstate.resetVariables();
		var songName:String = Paths.formatToSongPath(SONG.song);

		curStage = SONG.stage;
		//trace('stage is: ' + curStage);
		if(SONG.stage == null || SONG.stage.length < 1) {
			switch (songName)
			{
				case 'spookeez' | 'south' | 'monster':
					curStage = 'spooky';
				case 'pico' | 'blammed' | 'philly' | 'philly-nice':
					curStage = 'philly';
				case 'milf' | 'satin-panties' | 'high':
					curStage = 'limo';
				case 'cocoa' | 'eggnog':
					curStage = 'mall';
				case 'winter-horrorland':
					curStage = 'mallEvil';
				case 'senpai' | 'roses':
					curStage = 'school';
				case 'thorns':
					curStage = 'schoolEvil';
				case 'ugh' | 'guns' | 'stress':
					curStage = 'tank';
				default:
					curStage = 'stage';
			}
		}
		SONG.stage = curStage;
		#if ONLINE_ALLOWED
		// 联机房间舞台覆盖: 房主指定的房间舞台优先于歌曲自带舞台
		if (online.client.OnlineSession.active
			&& online.client.OnlineSession.stageName != null
			&& online.client.OnlineSession.stageName.length > 0)
			curStage = online.client.OnlineSession.stageName;
		#end

		var stageData:StageFile = StageData.getStageFile(curStage);
		if(stageData == null) { //Stage couldn't be found, create a dummy stage for preventing a crash
			stageData = {
				directory: "",
				defaultZoom: 0.9,
				isPixelStage: false,
				stageUI: null,

				boyfriend: [770, 100],
				girlfriend: [400, 130],
				opponent: [100, 100],
				hide_girlfriend: false,

				camera_boyfriend: [0, 0],
				camera_opponent: [0, 0],
				camera_girlfriend: [0, 0],
				camera_speed: 1
			};
		}

		defaultCamZoom = stageData.defaultZoom;
		isPixelStage = stageData.isPixelStage;
		if (stageData.stageUI != null && stageData.stageUI.length > 0)
			stageUI = stageData.stageUI;
		else
			stageUI = isPixelStage ? "pixel" : "normal";
		BF_X = stageData.boyfriend[0];
		BF_Y = stageData.boyfriend[1];
		GF_X = stageData.girlfriend[0];
		GF_Y = stageData.girlfriend[1];
		DAD_X = stageData.opponent[0];
		DAD_Y = stageData.opponent[1];

		if(stageData.camera_speed != null)
			cameraSpeed = stageData.camera_speed;

		boyfriendCameraOffset = stageData.camera_boyfriend;
		if(boyfriendCameraOffset == null) //Fucks sake should have done it since the start :rolling_eyes:
			boyfriendCameraOffset = [0, 0];

		opponentCameraOffset = stageData.camera_opponent;
		if(opponentCameraOffset == null)
			opponentCameraOffset = [0, 0];

		girlfriendCameraOffset = stageData.camera_girlfriend;
		if(girlfriendCameraOffset == null)
			girlfriendCameraOffset = [0, 0];

		boyfriendGroup = new FlxSpriteGroup(BF_X, BF_Y);
		dadGroup = new FlxSpriteGroup(DAD_X, DAD_Y);
		gfGroup = new FlxSpriteGroup(GF_X, GF_Y);

		keyboardDisplay = new KeyboardDisplay(ClientPrefs.data.comboOffset[4], ClientPrefs.data.comboOffset[5]);
		keyboardDisplay.antialiasing = ClientPrefs.data.globalAntialiasing;
		keyboardDisplay.visible = ClientPrefs.data.keyboardDisplay;
		add(keyboardDisplay);
		keyboardDisplay.cameras = [camOther];

		// Create stage backdrop handler and build background sprites
		stageBackdrop = createStageHandler(curStage);
		stageBackdrop.create();

		#if android
		// Upload/keep large stage textures early and drop their CPU copies.
		// Opt-in only: FNF_EARLY_CPU_RELEASE=1.
		if (Sys.getEnv("FNF_EARLY_CPU_RELEASE") == "1")
			backend.GfxPolicy.preloadWarm();
		#end

		switch(Paths.formatToSongPath(SONG.song))
		{
			case 'stress':
				GameOverSubstate.characterName = 'bf-holding-gf-dead';
		}

		if(isPixelStage) {
			introSoundsSuffix = '-pixel';
		}

		add(gfGroup); //Needed for blammed lights

		// Shitty layering but whatev it works LOL
		if (curStage == 'limo')
			add(limo);

		add(dadGroup);
		add(boyfriendGroup);

		switch(curStage)
		{
			case 'spooky':
				add(halloweenWhite);
			case 'tank':
				add(foregroundSprites);
		}

		#if LUA_ALLOWED
		luaDebugGroup = new FlxTypedGroup<DebugLuaText>();
		luaDebugGroup.cameras = [camOther];
		add(luaDebugGroup);
		#end

		// ---- GLOBAL SCRIPTS (single pass over folders for both Lua & HScript) ----
		// 0.6.3/0.7.3 保持旧顺序：在角色创建前加载；
		// 1.0.4 模式延后到角色/谱面生成后，兼容 104 风格脚本在顶层访问 dad/boyfriend/notes。
		if (!CompatEngine.is104())
			loadGlobalAndStageScripts();

		var gfVersion:String = SONG.gfVersion;
		if(gfVersion == null || gfVersion.length < 1)
		{
			switch (curStage)
			{
				case 'limo':
					gfVersion = 'gf-car';
				case 'mall' | 'mallEvil':
					gfVersion = 'gf-christmas';
				case 'school' | 'schoolEvil':
					gfVersion = 'gf-pixel';
				case 'tank':
					gfVersion = 'gf-tankmen';
				default:
					gfVersion = 'gf';
			}

			switch(Paths.formatToSongPath(SONG.song))
			{
				case 'stress':
					gfVersion = 'pico-speaker';
			}
			SONG.gfVersion = gfVersion; //Fix for the Chart Editor
		}

		if (!stageData.hide_girlfriend)
		{
			gf = new Character(0, 0, gfVersion);
			startCharacterPos(gf);
			gf.scrollFactor.set(0.95, 0.95);
			gfGroup.add(gf);
			startCharacterLua(gf.curCharacter);

			if(gfVersion == 'pico-speaker')
			{
				if(!ClientPrefs.data.lowQuality)
				{
					var firstTank:TankmenBG = new TankmenBG(20, 500, true);
					firstTank.resetShit(20, 600, true);
					firstTank.strumTime = 10;
					tankmanRun.add(firstTank);

					for (i in 0...TankmenBG.animationNotes.length)
					{
						if(FlxG.random.bool(16)) {
							var tankBih = tankmanRun.recycle(TankmenBG);
							tankBih.strumTime = TankmenBG.animationNotes[i][0];
							tankBih.resetShit(500, 200 + FlxG.random.int(50, 100), TankmenBG.animationNotes[i][1] < 2);
							tankmanRun.add(tankBih);
						}
					}
				}
			}
		}

		dad = new Character(0, 0, SONG.player2);
		startCharacterPos(dad, true);
		dadGroup.add(dad);
		startCharacterLua(dad.curCharacter);

		boyfriend = new Boyfriend(0, 0, SONG.player1);
		startCharacterPos(boyfriend);
		boyfriendGroup.add(boyfriend);
		startCharacterLua(boyfriend.curCharacter);

		#if ONLINE_ALLOWED
		// 联机对局 (PsychOnline 式): 全员按各自 skinData 替换角色 + 头顶铭牌。
		if (online.client.OnlineSession.active)
			onlineInitPlayerCharacters();
		#end

		var camPos:FlxPoint = new FlxPoint(girlfriendCameraOffset[0], girlfriendCameraOffset[1]);
		if(gf != null)
		{
			camPos.x += gf.getGraphicMidpoint().x + gf.cameraPosition[0];
			camPos.y += gf.getGraphicMidpoint().y + gf.cameraPosition[1];
		}

		if(dad.curCharacter.startsWith('gf')) {
			dad.setPosition(GF_X, GF_Y);
			if(gf != null)
				gf.visible = false;
		}

		switch(curStage)
		{
			case 'limo':
				if (fastCar != null) {
					if (stageBackdrop is LimoStage)
						cast(stageBackdrop, LimoStage).resetFastCar();
					addBehindGF(fastCar);
				}
			case 'schoolEvil':
				if (stageBackdrop is SchoolEvilStage)
					cast(stageBackdrop, SchoolEvilStage).addEvilTrail();
		}

		var file:String = Paths.json(songName + '/dialogue'); //Checks for json/Psych Engine dialogue
		if (OpenFlAssets.exists(file)) {
			dialogueJson = DialogueBoxPsych.parseDialogue(file);
		}

		var file:String = Paths.txt(songName + '/' + songName + 'Dialogue'); //Checks for vanilla/Senpai dialogue
		if (OpenFlAssets.exists(file)) {
			dialogue = CoolUtil.coolTextFile(file);
		}
		var doof:DialogueBox = new DialogueBox(false, dialogue);
		// doof.x += 70;
		// doof.y = FlxG.height * 0.5;
		doof.scrollFactor.set();
		doof.finishThing = startCountdown;
		doof.nextDialogueThing = startNextDialogue;
		doof.skipDialogueThing = skipDialogue;
		if (CompatEngine.isModern()) {
			comboGroup = new FlxSpriteGroup();
			add(comboGroup);
			noteGroup = new FlxTypedGroup<FlxBasic>();
			add(noteGroup);
			uiGroup = new FlxSpriteGroup();
			add(uiGroup);
		}

		Conductor.songPosition = -5000;
		// 进入游玩时重置全局音频偏移，避免编辑器里残留的 Conductor.offset 带进来
		var songOff:Dynamic = (PlayState.SONG != null && Reflect.hasField(PlayState.SONG, 'offset'))
			? Reflect.field(PlayState.SONG, 'offset') : null;
		Conductor.offset = (songOff != null && !Math.isNaN(Std.parseFloat(Std.string(songOff))))
			? Std.parseFloat(Std.string(songOff)) : 0;

		strumLine = new FlxSprite(ClientPrefs.data.middleScroll ? STRUM_X_MIDDLESCROLL : STRUM_X, 50).makeGraphic(FlxG.width, 10);
		if(ClientPrefs.data.downScroll) strumLine.y = FlxG.height - 150;
		strumLine.scrollFactor.set();

		var showTime:Bool = (ClientPrefs.data.timeBarType != 'Disabled');
		timeTxt = new FlxText(STRUM_X + (FlxG.width / 2) - 248, 18, 400, "", 32);
		timeTxt.setFormat(Paths.font("vcr.ttf"), 20, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		timeTxt.scrollFactor.set();
		timeTxt.alpha = 0;
		timeTxt.borderSize = 2;
		timeTxt.visible = showTime;
		if(ClientPrefs.data.downScroll) timeTxt.y = FlxG.height - 44;

		if(ClientPrefs.data.timeBarType == 'Song Name')
		{
			timeTxt.text = SONG.song;
		}
		updateTime = showTime;

		timeBarBG = new AttachedSprite('timeBar');
		timeBarBG.x = timeTxt.x;
		timeBarBG.y = timeTxt.y + (timeTxt.height / 4);
		timeBarBG.scrollFactor.set();
		timeBarBG.alpha = 0;
		timeBarBG.visible = showTime;
		timeBarBG.color = FlxColor.BLACK;
		timeBarBG.xAdd = -4;
		timeBarBG.yAdd = -4;
		if (CompatEngine.isModern())
			uiGroup.add(timeBarBG);
		else
			add(timeBarBG);

		// 兼容模式使用 0.7.3 Bar 类，非兼容模式使用原始 FlxBar
		if (CompatEngine.isModern()) {
			var compatTimeBar:objects.Bar = new objects.Bar(0, timeTxt.y + (timeTxt.height / 4), 'timeBar', function() return songPercent, 0, 1);
			compatTimeBar.scrollFactor.set();
			compatTimeBar.screenCenter(X);
			compatTimeBar.alpha = 0;
			compatTimeBar.visible = showTime;
			timeBar = compatTimeBar;
			timeBarBG.visible = false; // Bar 自带背景
			uiGroup.add(timeBar);
			uiGroup.add(timeTxt);
		} else {
			timeBar = new FlxBar(timeBarBG.x + 4, timeBarBG.y + 4, LEFT_TO_RIGHT, Std.int(timeBarBG.width - 8), Std.int(timeBarBG.height - 8), this,
				'songPercent', 0, 1);
			timeBar.scrollFactor.set();
			timeBar.createFilledBar(0xFF000000, 0xFFFFFFFF);
			timeBar.numDivisions = 800; //How much lag this causes?? Should i tone it down to idk, 400 or 200?
			timeBar.alpha = 0;
			timeBar.visible = showTime;
			add(timeBar);
			add(timeTxt);
			timeBarBG.sprTracker = timeBar;
		}

		strumLineNotes = new FlxTypedGroup<StrumNote>();
		if (CompatEngine.isModern()) {
			noteGroup.add(strumLineNotes);
		} else {
			add(strumLineNotes);
			add(grpNoteSplashes);
		}

		if(ClientPrefs.data.timeBarType == 'Song Name')
		{
			timeTxt.size = 24;
			timeTxt.y += 3;
		}

		var splash:NoteSplash = new NoteSplash(100, 100, 0);
		grpNoteSplashes.add(splash);
		// 1.0.4 加载顺序: alpha 不能为 0 (否则 Flixel 会跳过渲染, 图集/配置不会真正预加载),
		// 用 0.000001 让这个 splash 在 create 阶段就把溅射图集 + txt/json 配置读进缓存,
		// 避免第一次击键时才加载导致卡顿。
		splash.alpha = 0.000001;

		opponentStrums = new FlxTypedGroup<StrumNote>();
		playerStrums = new FlxTypedGroup<StrumNote>();

		// 评级弹窗对象池 — 预分配精灵复用，替换 popUpScore 中频繁 new/destroy 的开销
		ratingPopup = new RatingPopup();
		ratingPopup.targetCameras = [camHUD];
		ratingPopup.antialiasing = isPixelStage ? false : ClientPrefs.data.globalAntialiasing;
		ratingPopup.isPixel = isPixelStage;
		ratingPopup.daPixelZoom = daPixelZoom;
		if (CompatEngine.isModern())
		{
			// 兼容模式: container 指向 comboGroup
			// 用 Std.int() + 类型检查避免 cast 返回 null
			ratingPopup.container = comboGroup;
			add(ratingPopup.container);
		}
		else
		{
			// 非兼容模式: container 是独立 FlxSpriteGroup（无相机）。
			// 必须显式指定 camHUD，否则该组不会设置 Flixel 的 _defaultCameras，
			// 子精灵若未自带相机就会渲染到默认游戏相机（场景）中。
			ratingPopup.container.cameras = [camHUD];
			insert(members.indexOf(strumLineNotes), ratingPopup.container);
		}

		addAndroidControls(false, true);

		generateSong(SONG.song);
		#if ONLINE_ALLOWED
		if (seiunSpectate)
		{
			// 轻量观战: 不生成音符流, 仅由判定/分数/血量广播驱动角色动画与 HUD。
			unspawnNotes = [];
			lastChartNoteTime = 0;
		}
		#end
		// 1.0.4 模式：全局/舞台脚本延后到角色与谱面生成之后加载
		if (CompatEngine.is104())
			loadGlobalAndStageScripts();
		#if ONLINE_ALLOWED
		onlineGameStart();
		#end

		if (CompatEngine.isModern()) {
			noteGroup.add(grpNoteSplashes);
		}

		// After all characters being loaded, it makes then invisible 0.01s later so that the player won't freeze when you change characters
		// add(strumLine);

		camFollow = new FlxPoint();
		camFollowPos = new FlxObject(0, 0, 1, 1);

		snapCamFollowToPos(camPos.x, camPos.y);
		if (prevCamFollow != null)
		{
			camFollow = prevCamFollow;
			prevCamFollow = null;
		}
		if (prevCamFollowPos != null)
		{
			camFollowPos = prevCamFollowPos;
			prevCamFollowPos = null;
		}
		add(camFollowPos);

		FlxG.camera.follow(camFollowPos, LOCKON, 1);
		// FlxG.camera.setScrollBounds(0, FlxG.width, 0, FlxG.height);
		FlxG.camera.zoom = defaultCamZoom;
		// Reset any camera scroll left over from menu transitions so the
		// gameplay camera always starts from the correct position.
		FlxG.camera.scroll.set(0, 0);
		FlxG.camera.focusOn(camFollow);

		FlxG.worldBounds.set(0, 0, FlxG.width, FlxG.height);

		FlxG.fixedTimestep = false;
		moveCameraSection();

		// 兼容模式使用 0.7.3 Bar 类，非兼容模式使用原始 FlxBar
		if (CompatEngine.isModern()) {
			var barY:Float = FlxG.height * (!ClientPrefs.data.downScroll ? 0.89 : 0.11);
			var compatBar:objects.Bar = new objects.Bar(0, barY, 'healthBar', function() return displayHealth, 0, 2);
			compatBar.scrollFactor.set();
			compatBar.screenCenter(X);
			compatBar.visible = !ClientPrefs.data.hideHud;
			compatBar.alpha = ClientPrefs.data.healthBarAlpha;
			compatBar.leftToRight = false;
			healthBar = compatBar;
			healthBarBG = null;
		} else {
			healthBarBG = new AttachedSprite('healthBar');
			healthBarBG.y = FlxG.height * 0.89;
			healthBarBG.screenCenter(X);
			healthBarBG.scrollFactor.set();
			healthBarBG.visible = !ClientPrefs.data.hideHud;
			healthBarBG.xAdd = -4;
			healthBarBG.yAdd = -4;
			add(healthBarBG);
			if(ClientPrefs.data.downScroll) healthBarBG.y = 0.11 * FlxG.height;

			healthBar = new FlxBar(healthBarBG.x + 4, healthBarBG.y + 4, RIGHT_TO_LEFT, Std.int(healthBarBG.width - 8), Std.int(healthBarBG.height - 8), this,
				'displayHealth', 0, 2);
			healthBar.scrollFactor.set();
			healthBar.visible = !ClientPrefs.data.hideHud;
			healthBar.alpha = ClientPrefs.data.healthBarAlpha;
			Reflect.setProperty(healthBar, 'numDivisions', 10000);
			add(healthBar);
			healthBarBG.sprTracker = healthBar;
		}

		if (CompatEngine.isModern())
			uiGroup.add(healthBar);

		iconP1 = new HealthIcon(boyfriend.healthIcon, true);
		iconP1.y = healthBar.y - 75;
		iconP1.x = healthBar.x + healthBar.width + 12;
		iconP1.visible = !ClientPrefs.data.hideHud;
		iconP1.alpha = ClientPrefs.data.healthBarAlpha;
		if (CompatEngine.isModern())
			uiGroup.add(iconP1);
		else
			add(iconP1);

		iconP2 = new HealthIcon(dad.healthIcon, false);
		iconP2.y = healthBar.y - 75;
		iconP2.x = healthBar.x - 150;
		iconP2.visible = !ClientPrefs.data.hideHud;
		iconP2.alpha = ClientPrefs.data.healthBarAlpha;
		if (CompatEngine.isModern())
			uiGroup.add(iconP2);
		else
			add(iconP2);
		reloadHealthBarColors();
		forceHealthIconsAboveBar();

		var scoreY:Float = (healthBarBG != null) ? (healthBarBG.y + 36) : (healthBar.y + 40);
		scoreTxt = new FlxText(0, scoreY, FlxG.width, "", 20);
		scoreTxt.setFormat(Paths.languageFont(), 20, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		scoreTxt.scrollFactor.set();
		scoreTxt.borderSize = 2;
		scoreTxt.visible = !ClientPrefs.data.hideHud;
		if (CompatEngine.isModern())
			uiGroup.add(scoreTxt);
		else
			add(scoreTxt);

		botplayTxt = new FlxText(400, timeBarBG.y + 55, FlxG.width - 800, "BOTPLAY", 32);
		botplayTxt.setFormat(Paths.font("vcr.ttf"), 32, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		botplayTxt.scrollFactor.set();
		botplayTxt.borderSize = 2;
		botplayTxt.visible = cpuControlled && !ClientPrefs.data.hideHud;
		if (!cpuControlled && practiceMode) {
			botplayTxt.text = 'Practice Mode';
			botplayTxt.visible = !ClientPrefs.data.hideHud;
		}
		if (CompatEngine.isModern())
			uiGroup.add(botplayTxt);
		else
			add(botplayTxt);
		if(ClientPrefs.data.downScroll) {
			botplayTxt.y = timeBarBG.y - 78;
		}

		replayTxt = new FlxText(400, timeBarBG.y + 55, FlxG.width - 800, "REPLAY", 32);
		replayTxt.setFormat(Paths.font("vcr.ttf"), 32, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		replayTxt.scrollFactor.set();
		replayTxt.borderSize = 2;
		replayTxt.visible = replayMode;
		if (CompatEngine.isModern())
			uiGroup.add(replayTxt);
		else
			add(replayTxt);
		if(ClientPrefs.data.downScroll) {
			replayTxt.y = timeBarBG.y - 78;
		}
		#if ONLINE_ALLOWED
		if (seiunOnline)
		{
			onlineBadgeTxt = new FlxText(0, 40, FlxG.width,
				OnlineSession.dedicated
					? Language.get('online.badgePlayingDedicated', '专用服务器')
					: Language.get('online.badgePlayingLan', '局域网 · 本机托管'), 18);
			onlineBadgeTxt.setFormat(Paths.languageFont(), 18, FlxColor.fromRGB(120, 220, 255), CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
			onlineBadgeTxt.scrollFactor.set();
			onlineBadgeTxt.cameras = [camHUD];
			add(onlineBadgeTxt);

			// 右上: 对手实时分数 (PsychOnline scoreboard 等价物)。
			// 先按房间玩家列表播种 0 分, 这样开局立刻能看到每一位对手,
			// 之后每次本地/远端判定广播都会带当前分数并即时刷新。
			remoteScores = new Map<String, Dynamic>();
			remoteScoreSig = "";
			for (p in OnlineSession.players)
			{
				if (p == null)
					continue;
				var dev:String = Reflect.field(p, "deviceId");
				if (dev == null || dev == ProfileStore.deviceId)
					continue;
				var nick:String = Reflect.field(p, "nickname");
				if (nick == null || nick.length == 0)
					nick = dev;
				var ping:Float = Reflect.field(p, "pingMs") == null ? 0 : Std.parseFloat(Std.string(Reflect.field(p, "pingMs")));
				remoteScores.set(dev, {name: nick, score: 0, misses: 0, maxCombo: 0, accuracy: 0, ratingName: "", ratingFC: "", ping: ping});
			}
			// 右上对手分数面板: 右边贴屏 (FlxG.width - 20), 不再假定 1280 宽。
			var scoreW:Float = Math.min(360, FlxG.width * 0.3);
			remoteScoreTxt = new FlxText(FlxG.width - scoreW - 20, 64, scoreW, "", 14);
			remoteScoreTxt.setFormat(Paths.languageFont(), 14, FlxColor.fromRGB(255, 220, 150), RIGHT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
			remoteScoreTxt.scrollFactor.set();
			remoteScoreTxt.cameras = [camHUD];
			remoteScoreTxt.visible = OnlineSession.mode == online.shared.OnlineTypes.OnlineConst.MODE_REALTIME && !ClientPrefs.data.hideHud;
			add(remoteScoreTxt);
		}
		#end


		// LeatherEngine 移植: 回放判定手感提示 (仅当与当前设置不同时显示)
		judgeRestoreTxt = new FlxText(400, replayTxt.y + 45, FlxG.width - 800, "", 20);
		judgeRestoreTxt.setFormat(Paths.font("vcr.ttf"), 20, 0xFFFFD700, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		judgeRestoreTxt.scrollFactor.set();
		judgeRestoreTxt.borderSize = 2;
		judgeRestoreTxt.cameras = [camHUD];
		judgeRestoreTxt.visible = (replayMode && replayExam != null && replayExam.judgementRestoredDifferent);
		if (judgeRestoreTxt.visible && replayExam.judgementRestoreInfo != null && replayExam.judgementRestoreInfo.length > 0)
			judgeRestoreTxt.text = Language.get("replayJudgeRestored", "Replay Judgement:") + " " + replayExam.judgementRestoreInfo;
		add(judgeRestoreTxt);

		if (CompatEngine.isModern()) {
			comboGroup.cameras = [camHUD];
			noteGroup.cameras = [camHUD];
			uiGroup.cameras = [camHUD];
		} else {
			strumLineNotes.cameras = [camHUD];
			grpNoteSplashes.cameras = [camHUD];
			notes.cameras = [camHUD];
			Reflect.setProperty(healthBar, "cameras", [camHUD]);
			healthBarBG.cameras = [camHUD];
			iconP1.cameras = [camHUD];
			iconP2.cameras = [camHUD];
			scoreTxt.cameras = [camHUD];
			botplayTxt.cameras = [camHUD];
			replayTxt.cameras = [camHUD];
			Reflect.setProperty(timeBar, "cameras", [camHUD]);
			timeBarBG.cameras = [camHUD];
			timeTxt.cameras = [camHUD];
		}
		doof.cameras = [camHUD];

		// if (SONG.song == 'South')
		// FlxG.camera.alpha = 0.7;
		// UI_camera.zoom = 1;

		// cameras = [FlxG.cameras.list[1]];
		startingSong = true;

		#if LUA_ALLOWED
		for (notetype in noteTypeMap.keys())
		{
			#if MODS_ALLOWED
			var luaToLoad:String = Paths.modFolders('custom_notetypes/' + notetype + '.lua');
			if(FileSystem.exists(luaToLoad))
			{
				luaArray.push(new FunkinLua(luaToLoad));
			}
			else
			{
				luaToLoad = Paths.getPreloadPath('custom_notetypes/' + notetype + '.lua');
				if(FileSystem.exists(luaToLoad))
				{
					luaArray.push(new FunkinLua(luaToLoad));
				}
			}
			#elseif sys
			var luaToLoad:String = Paths.getPreloadPath('custom_notetypes/' + notetype + '.lua');
			if(OpenFlAssets.exists(luaToLoad))
			{
				luaArray.push(new FunkinLua(luaToLoad));
			}
			#end
		}

		for (event in eventPushedMap.keys())
		{
			#if MODS_ALLOWED
			var luaToLoad:String = Paths.modFolders('custom_events/' + event + '.lua');
			if(FileSystem.exists(luaToLoad))
			{
				luaArray.push(new FunkinLua(luaToLoad));
			}
			else
			{
				luaToLoad = Paths.getPreloadPath('custom_events/' + event + '.lua');
				if(FileSystem.exists(luaToLoad))
				{
					luaArray.push(new FunkinLua(luaToLoad));
				}
			}
			#elseif sys
			var luaToLoad:String = Paths.getPreloadPath('custom_events/' + event + '.lua');
			if(OpenFlAssets.exists(luaToLoad))
			{
				luaArray.push(new FunkinLua(luaToLoad));
			}
			#end
		}
		#end

#if HSCRIPT_ALLOWED
		for (notetype in noteTypeMap.keys())
		{
			try {
			#if MODS_ALLOWED
			var hscriptToLoad:String = Paths.modFolders('custom_notetypes/' + notetype + '.hx');
			if(FileSystem.exists(hscriptToLoad))
			{
				hscriptArray.push(new HScript(hscriptToLoad));
			}
			else
			{
				hscriptToLoad = Paths.getPreloadPath('custom_notetypes/' + notetype + '.hx');
				if(FileSystem.exists(hscriptToLoad))
				{
					hscriptArray.push(new HScript(hscriptToLoad));
				}
			}
			#elseif sys
			var hscriptToLoad:String = Paths.getPreloadPath('custom_notetypes/' + notetype + '.hx');
			if(OpenFlAssets.exists(hscriptToLoad))
			{
				hscriptArray.push(new HScript(hscriptToLoad));
			}
			#end
			} catch (e:Dynamic) {
				TraceManager.error('trace.playState.notetypeHscriptFailed', 'Failed to load notetype hscript {}: {}', [notetype, e]);
			}
		}

		for (event in eventPushedMap.keys())
		{
			try {
			#if MODS_ALLOWED
			var hscriptToLoad:String = Paths.modFolders('custom_events/' + event + '.hx');
			if(FileSystem.exists(hscriptToLoad))
			{
				hscriptArray.push(new HScript(hscriptToLoad));
			}
			else
			{
				hscriptToLoad = Paths.getPreloadPath('custom_events/' + event + '.hx');
				if(FileSystem.exists(hscriptToLoad))
				{
					hscriptArray.push(new HScript(hscriptToLoad));
				}
			}
			#elseif sys
			var hscriptToLoad:String = Paths.getPreloadPath('custom_events/' + event + '.hx');
			if(OpenFlAssets.exists(hscriptToLoad))
			{
				hscriptArray.push(new HScript(hscriptToLoad));
			}
			#end
			} catch (e:Dynamic) {
				TraceManager.error('trace.playState.eventHscriptFailed', 'Failed to load event hscript {}: {}', [event, e]);
			}
		}
		#end


		noteTypeMap.clear();
		noteTypeMap = null;
		eventPushedMap.clear();
		eventPushedMap = null;

		// SONG SPECIFIC SCRIPTS
		#if LUA_ALLOWED
		var filesPushed:Array<String> = [];
		var foldersToCheck:Array<String> = [Paths.getPreloadPath('data/' + Paths.formatToSongPath(SONG.song) + '/')];

		#if MODS_ALLOWED
		foldersToCheck.insert(0, Paths.mods('data/' + Paths.formatToSongPath(SONG.song) + '/'));
		if(Paths.currentModDirectory != null && Paths.currentModDirectory.length > 0)
			foldersToCheck.insert(0, Paths.mods(Paths.currentModDirectory + '/data/' + Paths.formatToSongPath(SONG.song) + '/'));

		for(mod in Paths.getGlobalMods())
			foldersToCheck.insert(0, Paths.mods(mod + '/data/' + Paths.formatToSongPath(SONG.song) + '/' ));// using push instead of insert because these should run after everything else
		#end

		for (folder in foldersToCheck)
		{
			if(FileSystem.exists(folder))
			{
				for (file in FileSystem.readDirectory(folder))
				{
					if(file.endsWith('.lua') && !filesPushed.contains(file))
					{
						luaArray.push(new FunkinLua(folder + file));
						filesPushed.push(file);
					}
				}
			}
		}
		#end

		// SONG SPECIFIC HSCRIPTS
		#if HSCRIPT_ALLOWED
		var hscriptSongFilesPushed:Array<String> = [];
		var hscriptSongFolders:Array<String> = [Paths.getPreloadPath('data/' + Paths.formatToSongPath(SONG.song) + '/')];

		#if MODS_ALLOWED
		hscriptSongFolders.insert(0, Paths.mods('data/' + Paths.formatToSongPath(SONG.song) + '/'));
		if(Paths.currentModDirectory != null && Paths.currentModDirectory.length > 0)
			hscriptSongFolders.insert(0, Paths.mods(Paths.currentModDirectory + '/data/' + Paths.formatToSongPath(SONG.song) + '/'));

		for(mod in Paths.getGlobalMods())
			hscriptSongFolders.insert(0, Paths.mods(mod + '/data/' + Paths.formatToSongPath(SONG.song) + '/'));
		#end

		for (folder in hscriptSongFolders)
		{
			if(FileSystem.exists(folder))
			{
				for (file in FileSystem.readDirectory(folder))
				{
					if(HScript.isHscriptFile(file) && !hscriptSongFilesPushed.contains(file))
					{
						try {
							var hscript = new HScript(folder + file);
							if(hscript != null) {
								hscriptArray.push(hscript);
								hscriptSongFilesPushed.push(file);
							}
						} catch (e:Dynamic) {
							TraceManager.error('trace.playState.songHscriptFailed', 'Failed to load song hscript: {} - {}', [file, e]);
						}
					}
				}
			}
		}
		#end

		var daSong:String = Paths.formatToSongPath(curSong);
		if (isStoryMode && !seenCutscene)
		{
			switch (daSong)
			{
				case "monster":
					var whiteScreen:FlxSprite = new FlxSprite(0, 0).makeGraphic(Std.int(FlxG.width * 2), Std.int(FlxG.height * 2), FlxColor.WHITE);
					add(whiteScreen);
					whiteScreen.scrollFactor.set();
					whiteScreen.blend = ADD;
					camHUD.visible = false;
					snapCamFollowToPos(dad.getMidpoint().x + 150, dad.getMidpoint().y - 100);
					inCutscene = true;

					FlxTween.tween(whiteScreen, {alpha: 0}, 1, {
						startDelay: 0.1,
						ease: FlxEase.linear,
						onComplete: function(twn:FlxTween)
						{
							camHUD.visible = true;
							remove(whiteScreen);
							startCountdown();
						}
					});
					FlxG.sound.play(Paths.soundRandom('thunder_', 1, 2));
					if(gf != null) gf.playAnim('scared', true);
					boyfriend.playAnim('scared', true);

				case "winter-horrorland":
					var blackScreen:FlxSprite = new FlxSprite().makeGraphic(Std.int(FlxG.width * 2), Std.int(FlxG.height * 2), FlxColor.BLACK);
					add(blackScreen);
					blackScreen.scrollFactor.set();
					camHUD.visible = false;
					inCutscene = true;

					FlxTween.tween(blackScreen, {alpha: 0}, 0.7, {
						ease: FlxEase.linear,
						onComplete: function(twn:FlxTween) {
							remove(blackScreen);
						}
					});
					FlxG.sound.play(Paths.sound('Lights_Turn_On'));
					snapCamFollowToPos(400, -2050);
					FlxG.camera.focusOn(camFollow);
					FlxG.camera.zoom = 1.5;

					new FlxTimer().start(0.8, function(tmr:FlxTimer)
					{
						camHUD.visible = true;
						remove(blackScreen);
						FlxTween.tween(FlxG.camera, {zoom: defaultCamZoom}, 2.5, {
							ease: FlxEase.quadInOut,
							onComplete: function(twn:FlxTween)
							{
								startCountdown();
							}
						});
					});
				case 'senpai' | 'roses' | 'thorns':
					if(daSong == 'roses') FlxG.sound.play(Paths.sound('ANGRY'));
					schoolIntro(doof);

				case 'ugh' | 'guns' | 'stress':
					tankIntro();

				default:
					startCountdown();
			}
			seenCutscene = true;
		}
		else
		{
			startCountdown();
		}
		RecalculateRating();
			if (ClientPrefs.data.sidehud) {
			var totalNotesText = Language.get("totalNotesText", "Total Notes Hit: 0") + "0",
			combosText = Language.get("combosText", "Combos: 0")+ "0",
			marvelousesText = Language.get("marvelousesText", "Marvelouses: 0") + "0",
			sicksText = Language.get("sicksText", "Sicks: 0") + "0",
			goodsText = Language.get("goodsText", "Goods: 0") + "0",
			badsText = Language.get("badsText", "Bads: 0") + "0",
			shitsText = Language.get("shitsText", "Shits: 0") + "0",
			missesText = Language.get("missesText", "Misses: 0") + "0";


			tnh = new FlxText(tnhx + 10, 259, 250, totalNotesText, 20);
			tnh.setFormat(20, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
			tnh.cameras = [camOther];
			tnh.font = Paths.languageFont();
			tnh.borderSize = 2;
			add(tnh);

			cm = new FlxText(-tnh.x + cmoffset, tnh.y + cmy, 200, combosText, 20);
			cm.setFormat(20, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
			cm.cameras = [camOther];
			cm.font = Paths.languageFont();
			cm.borderSize = 2;
			add(cm);

			if (ClientPrefs.data.marvelousRatings)
			{
				marv = new FlxText(cm.x, cm.y + 30, 200, marvelousesText, 20);
				marv.setFormat(20, FlxColor.fromRGB(255, 215, 0), LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
				marv.cameras = [camOther];
				marv.font = Paths.languageFont();
				marv.borderSize = 2;
				add(marv);
			}

			sick = new FlxText(cm.x, (marv != null ? marv.y : cm.y) + 30, 200, sicksText, 20);
			sick.setFormat(20, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
			sick.cameras = [camOther];
			sick.font = Paths.languageFont();
			sick.borderSize = 2;
			add(sick);

			good = new FlxText(cm.x, sick.y + 30, 200, goodsText, 20);
			good.setFormat(20, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
			good.cameras = [camOther];
			good.font = Paths.languageFont();
			good.borderSize = 2;
			add(good);

			bad = new FlxText(cm.x, good.y + 30, 200, badsText, 20);
			bad.setFormat(20, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
			bad.cameras = [camOther];
			bad.font = Paths.languageFont();
			bad.borderSize = 2;
			add(bad);

			shit = new FlxText(cm.x, bad.y + 30, 200, shitsText, 20);
			shit.setFormat(20, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
			shit.cameras = [camOther];
			shit.font = Paths.languageFont();
			shit.borderSize = 2;
			add(shit);

			miss = new FlxText(cm.x, shit.y + 30, 200, missesText, 20);
			miss.setFormat(20, FlxColor.RED, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
			miss.cameras = [camOther];
			miss.font = Paths.languageFont();
			miss.borderSize = 2;
			add(miss);
			}


		msTxtKade = new FlxText(ClientPrefs.data.comboOffset[6], ClientPrefs.data.comboOffset[7], 0, "", 19);
		msTxtKade.alpha = 0;
		msTxtKade.scrollFactor.set();
		msTxtKade.cameras = [camHUD];
		msTxtKade.visible = !ClientPrefs.data.hideHud;
		msTxtKade.setFormat(19, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		msTxtKade.borderSize = 2;
		msTxtKade.font = Paths.font("kadems.ttf");
		add(msTxtKade);

		/*
		tailBadgeTxt = new FlxText(ClientPrefs.data.comboOffset[6], ClientPrefs.data.comboOffset[7] + 26, 0, "", 14);
		tailBadgeTxt.text = Language.get("osuTailBadge", "TAIL");
		tailBadgeTxt.scrollFactor.set();
		tailBadgeTxt.cameras = [camHUD];
		tailBadgeTxt.visible = ClientPrefs.data.osuTailJudgement && !ClientPrefs.data.hideHud;
		tailBadgeTxt.color = 0xFFFFD700;
		tailBadgeTxt.setFormat(14, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		tailBadgeTxt.borderSize = 1.5;
		tailBadgeTxt.font = Paths.font("kadems.ttf");
		add(tailBadgeTxt);
		*/

		var songName:String = PlayState.SONG.song;
		var difficultyName:String = displayDifficultyString();
		var seiunEngineVersion:String = MainMenuState.seiunengineVersion;
		var psychEngineVersion:String = CompatEngine.current();

        var versionText:String = 'SE $seiunEngineVersion + PE $psychEngineVersion';
		atkText = new FlxText(0, 700, 600, "", 15);
       atkText.text = '$songName $difficultyName - $versionText';
        atkText.cameras = [camHUD];
		atkText.borderSize = 2;
		atkText.setFormat(15, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		atkText.font = Paths.font("vcr.ttf");
        add(atkText);
		if(replayMode)
			atkText.text += '(Replay)';

		//PRECACHING MISS SOUNDS BECAUSE I THINK THEY CAN LAG PEOPLE AND FUCK THEM UP IDK HOW HAXE WORKS
		if(ClientPrefs.data.hitsoundVolume > 0) precacheList.set('hitsound', 'sound');
		precacheList.set('missnote1', 'sound');
		precacheList.set('missnote2', 'sound');
		precacheList.set('missnote3', 'sound');

		if (PauseSubState.songName != null) {
			precacheList.set(PauseSubState.songName, 'music');
		} else if(ClientPrefs.data.pauseMusic != 'None') {
			precacheList.set(Paths.formatToSongPath(ClientPrefs.data.pauseMusic), 'music');
		}

		precacheList.set('alphabet', 'image');

		#if cpp
		// Updating Discord Rich Presence.
		if(iconP2 != null) DiscordClient.changePresence(detailsText, SONG.song + " (" + storyDifficultyText + ")", iconP2.getCharacter());
		#end

		// Track background — lazy small initial allocation, resized in update()
		trackAlpha = ClientPrefs.data.trackAlpha;
		trackBackground = new FlxSprite(0, -50).makeGraphic(64, 64, FlxColor.fromString('#' + trackColor));
		trackBackground.alpha = trackAlpha;
		trackBackground.cameras = [camHUD];
		trackBackground.scrollFactor.set();
		trackBackground.visible = (trackAlpha > 0);
		// 0.7.3/1.0.4 兼容：Lua 的 onCreatePost 在 super.create() 之前调用，
		// HScript 的 onCreatePost 由 super.create() 内部调用，避免重复。
		callOnLuas('onCreatePost', []);
		super.create();
		if (CompatEngine.isModern())
			insert(members.indexOf(noteGroup), trackBackground);
		else
			insert(members.indexOf(strumLineNotes), trackBackground);

		cacheCountdown();
		cachePopUpScore();

		// Batch-precache: iterate once, skip already-loaded assets
		for (key => type in precacheList)
		{
			switch(type)
			{
				case 'image': Paths.image(key);
				case 'sound': Paths.sound(key);
				case 'music': Paths.music(key);
			}
		}

		initHitsound();

		Paths.clearUnusedMemory();

		// SeiunEngine P6.x：预加载阶段一次性完成大纹理的显存提交与 CPU 副本释放，
		// 避免进歌后 5 秒内分批提交造成的偶发卡顿。
		GfxPolicy.preloadWarm();

		#if cpp
		if (ClientPrefs.data.disableGC)
		{
			_gcDisabledForSong = true;
			GcState.setDisabled(false);
			cpp.vm.Gc.run(true);
			cpp.vm.Gc.compact();
			GcState.setDisabled(true);
		}
		#end

		#if cpp
		// Force a full GC after creation so the load-time collection does not
		// hit first gameplay. Disable with FNF_GC_FULL_ON_PLAY_CREATE=0.
		if (!ClientPrefs.data.disableGC && Sys.getEnv("FNF_GC_FULL_ON_PLAY_CREATE") != "0")
		{
			cpp.vm.Gc.run(true);
			// major 回收后压缩堆, 空闲块归还 OS (纯 GC 操作, 无逻辑影响)。
			cpp.vm.Gc.compact();
		}
		#end

		CustomFadeTransition.nextCamera = camOther;
	}

	/**
	 * 加载全局 scripts/ 与当前 stage 的脚本（Lua + HScript）。
	 * 0.6.3/0.7.3 模式在角色创建前调用；1.0.4 模式在角色/谱面生成后调用。
	 */
	function loadGlobalAndStageScripts():Void
	{
		#if (LUA_ALLOWED || HSCRIPT_ALLOWED)
		var filesPushed:Array<String> = [];
		var scriptFolders:Array<String> = [];

		scriptFolders.push(Paths.getPreloadPath('scripts/'));
		#end

		#if MODS_ALLOWED
		scriptFolders.push(Paths.mods('scripts/'));
		if(Paths.currentModDirectory != null && Paths.currentModDirectory.length > 0)
			scriptFolders.push(Paths.mods(Paths.currentModDirectory + '/scripts/'));

		for(mod in Paths.getGlobalMods())
			scriptFolders.push(Paths.mods(mod + '/scripts/'));
		#end

		for (folder in scriptFolders)
		{
			#if (LUA_ALLOWED || HSCRIPT_ALLOWED || sys)
			if (!FileSystem.exists(folder)) continue;
			var dirContents:Array<String> = FileSystem.readDirectory(folder);
			#end

			#if LUA_ALLOWED
			for (file in dirContents)
			{
				if(file.endsWith('.lua') && !filesPushed.contains(file))
				{
					luaArray.push(new FunkinLua(folder + file));
					filesPushed.push(file);
				}
			}
			#end

			#if HSCRIPT_ALLOWED
			for (file in dirContents)
			{
				if(HScript.isHscriptFile(file) && !filesPushed.contains(file))
				{
					try {
						var script = new HScript(folder + file);
						if(script != null) {
							hscriptArray.push(script);
							filesPushed.push(file);
						}
					} catch (e:Dynamic) {
						TraceManager.error('trace.playState.hscriptFailed', 'Failed to load hscript: {} - {}', [file, e]);
					}
				}
			}
			#end
		}

		// ---- STAGE-SPECIFIC SCRIPTS ----
		#if LUA_ALLOWED
		(function() {
			var luaFile:String = 'stages/' + curStage + '.lua';
			#if MODS_ALLOWED
			if(FileSystem.exists(Paths.modFolders(luaFile)))
				luaFile = Paths.modFolders(luaFile);
			else
				luaFile = Paths.getPreloadPath(luaFile);
			#else
			luaFile = Paths.getPreloadPath(luaFile);
			#end
			#if sys
			if(FileSystem.exists(luaFile))
				luaArray.push(new FunkinLua(luaFile));
			#end
		})();
		#end

		#if HSCRIPT_ALLOWED
		(function() {
			var hscriptFile:String = 'stages/' + curStage + '.hx';
			#if MODS_ALLOWED
			if(FileSystem.exists(Paths.modFolders(hscriptFile)))
				hscriptFile = Paths.modFolders(hscriptFile);
			else
				hscriptFile = Paths.getPreloadPath(hscriptFile);
			#else
			hscriptFile = Paths.getPreloadPath(hscriptFile);
			#end
			if(FileSystem.exists(hscriptFile)) {
				try {
					hscriptArray.push(new HScript(hscriptFile));
				} catch (e:Dynamic) {
					TraceManager.error('trace.playState.hscriptStageFailed', 'Failed to load stage hscript: {} - {}', [hscriptFile, e]);
				}
			}
		})();
		#end
	}

	/** Cached reflect property getters for Dynamic healthBar. */
	var _healthBarWidth(get, never):Float;
	inline function get__healthBarWidth():Float return Reflect.getProperty(healthBar, "width");
	var _healthBarPercent(get, never):Float;
	inline function get__healthBarPercent():Float return Reflect.getProperty(healthBar, "percent");

	public dynamic function updateIconsPosition(elapsed:Float)
	{
		// Smoothly move icons towards target positions computed from the healthbar's displayed percent
		var iconOffset:Int = 26;
		var barWidth:Float = _healthBarWidth;
		var barPercent:Float = _healthBarPercent;
		var targetBase:Float = healthBar.x + (barWidth * (FlxMath.remapToRange(barPercent, 0, 100, 100, 0) * 0.01));
		var target1:Float = targetBase + (150 * iconP1.scale.x - 150) / 2 - iconOffset;
		var target2:Float = targetBase - (150 * iconP2.scale.x) / 2 - iconOffset * 2;
		// Interpolation factor (higher = faster)
		var t:Float = Math.min(1, elapsed * 10);
		var lerpX1:Float = (target1 - iconP1.x) * t;
		var lerpX2:Float = (target2 - iconP2.x) * t;
		iconP1.x += lerpX1;
		iconP2.x += lerpX2;
		// Also smoothly follow vertical changes of the healthbar
		var targetY:Float = healthBar.y - 75;
		iconP1.y += (targetY - iconP1.y) * t;
		iconP2.y += (targetY - iconP2.y) * t;
	}


	private function forceHealthIconsAboveBar():Void
	{
		if (!CompatEngine.isModern() || uiGroup == null || healthBar == null || iconP1 == null || iconP2 == null)
			return;

		var barIdx:Int = uiGroup.members.indexOf(healthBar);
		uiGroup.remove(iconP1);
		uiGroup.remove(iconP2);

		if (barIdx >= 0)
		{
			uiGroup.insert(barIdx + 1, iconP1);
			uiGroup.insert(barIdx + 2, iconP2);
		}
		else
		{
			uiGroup.add(iconP1);
			uiGroup.add(iconP2);
		}
	}

	function set_songSpeed(value:Float):Float
	{
		if(generatedMusic)
		{
			// 直接按新 songSpeed 重算长条 scale.y，避免乘法累积导致的浮点误差和极端值渲染异常。
			// 未物化的 unspawnNotes 只是轻量数据，spawn 时 setupNoteData 会用当前 songSpeed 生成。
			for (note in notes) if(note != null && note.exists) note.recalcSustainScale(value);
		}
		songSpeed = value;
		noteKillOffset = 350 / songSpeed;
		return value;
	}

	function set_playbackRate(value:Float):Float
	{
		if(generatedMusic)
		{
			if(vocals != null) vocals.pitch = value;
			if(vocalsPlayer != null) vocalsPlayer.pitch = value;
			if(opponentVocals != null) opponentVocals.pitch = value;
			FlxG.sound.music.pitch = value;
		}
		playbackRate = value;
		FlxAnimationController.globalSpeed = value;
		TraceManager.debug('trace.playState.animSpeed', 'Anim speed: {}', [FlxAnimationController.globalSpeed]);
		Conductor.safeZoneOffset = (ClientPrefs.data.safeFrames / 60) * 1000 * value;
		setOnScripts('playbackRate', playbackRate);
		return value;
	}

	override public function addTextToDebug(text:String, color:FlxColor) {
		#if LUA_ALLOWED
		luaDebugGroup.forEachAlive(function(spr:DebugLuaText) {
			spr.y += 20;
		});

		if(luaDebugGroup.members.length > 34) {
			var blah = luaDebugGroup.members[34];
			blah.destroy();
			luaDebugGroup.remove(blah);
		}
		luaDebugGroup.insert(0, new DebugLuaText(text, luaDebugGroup, color));
		#end
	}

	public function reloadHealthBarColors() {
		if (CompatEngine.isModern()) {
			// Bar.setColors
			healthBar.setColors(
				FlxColor.fromRGB(dad.healthColorArray[0], dad.healthColorArray[1], dad.healthColorArray[2]),
				FlxColor.fromRGB(boyfriend.healthColorArray[0], boyfriend.healthColorArray[1], boyfriend.healthColorArray[2])
			);
		} else {
			healthBar.createFilledBar(FlxColor.fromRGB(dad.healthColorArray[0], dad.healthColorArray[1], dad.healthColorArray[2]),
				FlxColor.fromRGB(boyfriend.healthColorArray[0], boyfriend.healthColorArray[1], boyfriend.healthColorArray[2]));
			healthBar.updateBar();
		}
	}

	public function addCharacterToList(newCharacter:String, type:Int) {
		switch(type) {
			case 0:
				if(!boyfriendMap.exists(newCharacter)) {
					var newBoyfriend:Boyfriend = new Boyfriend(0, 0, newCharacter);
					boyfriendMap.set(newCharacter, newBoyfriend);
					boyfriendGroup.add(newBoyfriend);
					startCharacterPos(newBoyfriend);
					newBoyfriend.alpha = 0.00001;
					startCharacterLua(newBoyfriend.curCharacter);
				}

			case 1:
				if(!dadMap.exists(newCharacter)) {
					var newDad:Character = new Character(0, 0, newCharacter);
					dadMap.set(newCharacter, newDad);
					dadGroup.add(newDad);
					startCharacterPos(newDad, true);
					newDad.alpha = 0.00001;
					startCharacterLua(newDad.curCharacter);
				}

			case 2:
				if(gf != null && !gfMap.exists(newCharacter)) {
					var newGf:Character = new Character(0, 0, newCharacter);
					newGf.scrollFactor.set(0.95, 0.95);
					gfMap.set(newCharacter, newGf);
					gfGroup.add(newGf);
					startCharacterPos(newGf);
					newGf.alpha = 0.00001;
					startCharacterLua(newGf.curCharacter);
				}
		}
	}

	function startCharacterLua(name:String)
	{
		#if LUA_ALLOWED
		var doPush:Bool = false;
		var luaFile:String = 'characters/' + name + '.lua';
		#if MODS_ALLOWED
		if(FileSystem.exists(Paths.modFolders(luaFile))) {
			luaFile = Paths.modFolders(luaFile);
			doPush = true;
		} else {
			luaFile = Paths.getPreloadPath(luaFile);
			if(FileSystem.exists(luaFile)) {
				doPush = true;
			}
		}
		#else
		luaFile = Paths.getPreloadPath(luaFile);
		if(Assets.exists(luaFile)) {
			doPush = true;
		}
		#end

		if(doPush)
		{
			for (script in luaArray)
			{
				if(script.scriptName == luaFile) return;
			}
			luaArray.push(new FunkinLua(luaFile));
		}
		#end
	}

	function startCharacterPos(char:Character, ?gfCheck:Bool = false) {
		if(gfCheck && char.curCharacter.startsWith('gf')) { //IF DAD IS GIRLFRIEND, HE GOES TO HER POSITION
			char.setPosition(GF_X, GF_Y);
			char.scrollFactor.set(0.95, 0.95);
			char.danceEveryNumBeats = 2;
		}
		char.x += char.positionArray[0];
		char.y += char.positionArray[1];
	}
	#if VIDEOS_ALLOWED
	var video:VideoHandler = null;
	var videoPlaying:Bool = false;
	#end
	public function startVideo(name:String)
	{
		#if VIDEOS_ALLOWED
		inCutscene = true;
		videoPlaying = true;

		var filepath:String = Paths.video(name);
		#if sys
		if(!FileSystem.exists(filepath))
		#else
		if(!OpenFlAssets.exists(filepath))
		#end
		{
			FlxG.log.warn('Couldnt find video file: ' + name);
			startAndEnd();
			return;
		}

		// First-time LibVLC initialization can be expensive (plugin cache scan).
		// Wait for it asynchronously instead of letting `new VideoHandler()`
		// block the main thread and freeze the cutscene.
		VideoPreloader.whenReady(function()
		{
			if (PlayState.instance != this)
				return;

			video = new VideoHandler();
			video.finishCallback = function()
			{
				videoPlaying = false;
				startAndEnd();
				return;
			}
			video.playVideo(filepath);
		});
		#else
		FlxG.log.warn('Platform not supported!');
		startAndEnd();
		return;
		#end
	}

	function startAndEnd()
	{
		#if VIDEOS_ALLOWED
		videoPlaying = false;
		#end
		if(endingSong)
			endSong();
		else
			startCountdown();
	}

	var dialogueCount:Int = 0;
	public var psychDialogue:DialogueBoxPsych;
	//You don't have to add a song, just saying. You can just do "startDialogue(dialogueJson);" and it should work
	public function startDialogue(dialogueFile:DialogueFile, ?song:String = null):Void
	{
		// TO DO: Make this more flexible, maybe?
		if(psychDialogue != null) return;

		if(dialogueFile.dialogue.length > 0) {
			inCutscene = true;
			precacheList.set('dialogue', 'sound');
			precacheList.set('dialogueClose', 'sound');
			psychDialogue = new DialogueBoxPsych(dialogueFile, song);
			psychDialogue.scrollFactor.set();
			if(endingSong) {
				psychDialogue.finishThing = function() {
					psychDialogue = null;
					endSong();
				}
			} else {
				psychDialogue.finishThing = function() {
					psychDialogue = null;
					startCountdown();
				}
			}
			psychDialogue.nextDialogueThing = startNextDialogue;
			psychDialogue.skipDialogueThing = skipDialogue;
			psychDialogue.cameras = [camHUD];
			add(psychDialogue);
		} else {
			FlxG.log.warn('Your dialogue file is badly formatted!');
			if(endingSong) {
				endSong();
			} else {
				startCountdown();
			}
		}
	}

	function schoolIntro(?dialogueBox:DialogueBox):Void
	{
		inCutscene = true;
		var black:FlxSprite = new FlxSprite(-100, -100).makeGraphic(FlxG.width * 2, FlxG.height * 2, FlxColor.BLACK);
		black.scrollFactor.set();
		add(black);

		var red:FlxSprite = new FlxSprite(-100, -100).makeGraphic(FlxG.width * 2, FlxG.height * 2, 0xFFff1b31);
		red.scrollFactor.set();

		var senpaiEvil:FlxSprite = new FlxSprite();
		senpaiEvil.frames = Paths.getSparrowAtlas('weeb/senpaiCrazy');
		senpaiEvil.animation.addByPrefix('idle', 'Senpai Pre Explosion', 24, false);
		senpaiEvil.setGraphicSize(Std.int(senpaiEvil.width * 6));
		senpaiEvil.scrollFactor.set();
		senpaiEvil.updateHitbox();
		senpaiEvil.screenCenter();
		senpaiEvil.x += 300;

		var songName:String = Paths.formatToSongPath(SONG.song);
		if (songName == 'roses' || songName == 'thorns')
		{
			remove(black);

			if (songName == 'thorns')
			{
				add(red);
				camHUD.visible = false;
			}
		}

		new FlxTimer().start(0.3, function(tmr:FlxTimer)
		{
			black.alpha -= 0.15;

			if (black.alpha > 0)
			{
				tmr.reset(0.3);
			}
			else
			{
				if (dialogueBox != null)
				{
					if (Paths.formatToSongPath(SONG.song) == 'thorns')
					{
						add(senpaiEvil);
						senpaiEvil.alpha = 0;
						new FlxTimer().start(0.3, function(swagTimer:FlxTimer)
						{
							senpaiEvil.alpha += 0.15;
							if (senpaiEvil.alpha < 1)
							{
								swagTimer.reset();
							}
							else
							{
								senpaiEvil.animation.play('idle');
								FlxG.sound.play(Paths.sound('Senpai_Dies'), 1, false, null, true, function()
								{
									remove(senpaiEvil);
									remove(red);
									FlxG.camera.fade(FlxColor.WHITE, 0.01, true, function()
									{
										add(dialogueBox);
										camHUD.visible = true;
									}, true);
								});
								new FlxTimer().start(3.2, function(deadTime:FlxTimer)
								{
									FlxG.camera.fade(FlxColor.WHITE, 1.6, false);
								});
							}
						});
					}
					else
					{
						add(dialogueBox);
					}
				}
				else
					startCountdown();

				remove(black);
			}
		});
	}

	function tankIntro()
	{
		var cutsceneHandler:CutsceneHandler = new CutsceneHandler();

		var songName:String = Paths.formatToSongPath(SONG.song);
		dadGroup.alpha = 0.00001;
		camHUD.visible = false;
		//inCutscene = true; //this would stop the camera movement, oops

		var tankman:FlxSprite = new FlxSprite(-20, 320);
		tankman.frames = Paths.getSparrowAtlas('cutscenes/' + songName);
		tankman.antialiasing = ClientPrefs.data.globalAntialiasing;
		addBehindDad(tankman);
		cutsceneHandler.push(tankman);

		var tankman2:FlxSprite = new FlxSprite(16, 312);
		tankman2.antialiasing = ClientPrefs.data.globalAntialiasing;
		tankman2.alpha = 0.000001;
		cutsceneHandler.push(tankman2);
		var gfDance:FlxSprite = new FlxSprite(gf.x - 107, gf.y + 140);
		gfDance.antialiasing = ClientPrefs.data.globalAntialiasing;
		cutsceneHandler.push(gfDance);
		var gfCutscene:FlxSprite = new FlxSprite(gf.x - 104, gf.y + 122);
		gfCutscene.antialiasing = ClientPrefs.data.globalAntialiasing;
		cutsceneHandler.push(gfCutscene);
		var picoCutscene:FlxSprite = new FlxSprite(gf.x - 849, gf.y - 264);
		picoCutscene.antialiasing = ClientPrefs.data.globalAntialiasing;
		cutsceneHandler.push(picoCutscene);
		var boyfriendCutscene:FlxSprite = new FlxSprite(boyfriend.x + 5, boyfriend.y + 20);
		boyfriendCutscene.antialiasing = ClientPrefs.data.globalAntialiasing;
		cutsceneHandler.push(boyfriendCutscene);

		cutsceneHandler.finishCallback = function()
		{
			var timeForStuff:Float = Conductor.crochet / 1000 * 4.5;
			FlxG.sound.music.fadeOut(timeForStuff);
			FlxTween.tween(FlxG.camera, {zoom: defaultCamZoom}, timeForStuff, {ease: FlxEase.quadInOut});
			moveCamera(true);
			startCountdown();

			dadGroup.alpha = 1;
			camHUD.visible = true;
			boyfriend.animation.finishCallback = null;
			gf.animation.finishCallback = null;
			gf.dance();
		};

		camFollow.set(dad.x + 280, dad.y + 170);
		switch(songName)
		{
			case 'ugh':
				cutsceneHandler.endTime = 12;
				cutsceneHandler.music = 'DISTORTO';
				precacheList.set('wellWellWell', 'sound');
				precacheList.set('killYou', 'sound');
				precacheList.set('bfBeep', 'sound');

				var wellWellWell:FlxSound = new FlxSound().loadEmbedded(Paths.sound('wellWellWell'));
				FlxG.sound.list.add(wellWellWell);

				tankman.animation.addByPrefix('wellWell', 'TANK TALK 1 P1', 24, false);
				tankman.animation.addByPrefix('killYou', 'TANK TALK 1 P2', 24, false);
				tankman.animation.play('wellWell', true);
				FlxG.camera.zoom *= 1.2;

				// Well well well, what do we got here?
				cutsceneHandler.timer(0.1, function()
				{
					wellWellWell.play(true);
				});

				// Move camera to BF
				cutsceneHandler.timer(3, function()
				{
					camFollow.x += 750;
					camFollow.y += 100;
				});

				// Beep!
				cutsceneHandler.timer(4.5, function()
				{
					boyfriend.playAnim('singUP', true);
					boyfriend.specialAnim = true;
					FlxG.sound.play(Paths.sound('bfBeep'));
				});

				// Move camera to Tankman
				cutsceneHandler.timer(6, function()
				{
					camFollow.x -= 750;
					camFollow.y -= 100;

					// We should just kill you but... what the hell, it's been a boring day... let's see what you've got!
					tankman.animation.play('killYou', true);
					FlxG.sound.play(Paths.sound('killYou'));
				});

			case 'guns':
				cutsceneHandler.endTime = 11.5;
				cutsceneHandler.music = 'DISTORTO';
				tankman.x += 40;
				tankman.y += 10;
				precacheList.set('tankSong2', 'sound');

				var tightBars:FlxSound = new FlxSound().loadEmbedded(Paths.sound('tankSong2'));
				FlxG.sound.list.add(tightBars);

				tankman.animation.addByPrefix('tightBars', 'TANK TALK 2', 24, false);
				tankman.animation.play('tightBars', true);
				boyfriend.finishAnimation();

				cutsceneHandler.onStart = function()
				{
					tightBars.play(true);
					FlxTween.tween(FlxG.camera, {zoom: defaultCamZoom * 1.2}, 4, {ease: FlxEase.quadInOut});
					FlxTween.tween(FlxG.camera, {zoom: defaultCamZoom * 1.2 * 1.2}, 0.5, {ease: FlxEase.quadInOut, startDelay: 4});
					FlxTween.tween(FlxG.camera, {zoom: defaultCamZoom * 1.2}, 1, {ease: FlxEase.quadInOut, startDelay: 4.5});
				};

				cutsceneHandler.timer(4, function()
				{
					gf.playAnim('sad', true);
					gf.animation.finishCallback = function(name:String)
					{
						gf.playAnim('sad', true);
					};
				});

			case 'stress':
				cutsceneHandler.endTime = 35.5;
				tankman.x -= 54;
				tankman.y -= 14;
				gfGroup.alpha = 0.00001;
				boyfriendGroup.alpha = 0.00001;
				camFollow.set(dad.x + 400, dad.y + 170);
				FlxTween.tween(FlxG.camera, {zoom: 0.9 * 1.2}, 1, {ease: FlxEase.quadInOut});
				foregroundSprites.forEach(function(spr:BGSprite)
				{
					spr.y += 100;
				});
				precacheList.set('stressCutscene', 'sound');

				tankman2.frames = Paths.getSparrowAtlas('cutscenes/stress2');
				addBehindDad(tankman2);

				if (!ClientPrefs.data.lowQuality)
				{
					gfDance.frames = Paths.getSparrowAtlas('characters/gfTankmen');
					gfDance.animation.addByPrefix('dance', 'GF Dancing at Gunpoint', 24, true);
					gfDance.animation.play('dance', true);
					addBehindGF(gfDance);
				}

				gfCutscene.frames = Paths.getSparrowAtlas('cutscenes/stressGF');
				gfCutscene.animation.addByPrefix('dieBitch', 'GF STARTS TO TURN PART 1', 24, false);
				gfCutscene.animation.addByPrefix('getRektLmao', 'GF STARTS TO TURN PART 2', 24, false);
				gfCutscene.animation.play('dieBitch', true);
				gfCutscene.animation.pause();
				addBehindGF(gfCutscene);
				if (!ClientPrefs.data.lowQuality)
				{
					gfCutscene.alpha = 0.00001;
				}

				picoCutscene.frames = AtlasFrameMaker.construct('cutscenes/stressPico');
				picoCutscene.animation.addByPrefix('anim', 'Pico Badass', 24, false);
				addBehindGF(picoCutscene);
				picoCutscene.alpha = 0.00001;

				boyfriendCutscene.frames = Paths.getSparrowAtlas('characters/BOYFRIEND');
				boyfriendCutscene.animation.addByPrefix('idle', 'BF idle dance', 24, false);
				boyfriendCutscene.animation.play('idle', true);
				boyfriendCutscene.animation.curAnim.finish();
				addBehindBF(boyfriendCutscene);

				var cutsceneSnd:FlxSound = new FlxSound().loadEmbedded(Paths.sound('stressCutscene'));
				FlxG.sound.list.add(cutsceneSnd);

				tankman.animation.addByPrefix('godEffingDamnIt', 'TANK TALK 3', 24, false);
				tankman.animation.play('godEffingDamnIt', true);

				var calledTimes:Int = 0;
				var zoomBack:Void->Void = function()
				{
					var camPosX:Float = 630;
					var camPosY:Float = 425;
					camFollow.set(camPosX, camPosY);
					camFollowPos.setPosition(camPosX, camPosY);
					FlxG.camera.zoom = 0.8;
					cameraSpeed = 1;

					calledTimes++;
					if (calledTimes > 1)
					{
						foregroundSprites.forEach(function(spr:BGSprite)
						{
							spr.y -= 100;
						});
					}
				}

				cutsceneHandler.onStart = function()
				{
					cutsceneSnd.play(true);
				};

				cutsceneHandler.timer(15.2, function()
				{
					FlxTween.tween(camFollow, {x: 650, y: 300}, 1, {ease: FlxEase.sineOut});
					FlxTween.tween(FlxG.camera, {zoom: 0.9 * 1.2 * 1.2}, 2.25, {ease: FlxEase.quadInOut});

					gfDance.visible = false;
					gfCutscene.alpha = 1;
					gfCutscene.animation.play('dieBitch', true);
					gfCutscene.animation.finishCallback = function(name:String)
					{
						if(name == 'dieBitch') //Next part
						{
							gfCutscene.animation.play('getRektLmao', true);
							gfCutscene.offset.set(224, 445);
						}
						else
						{
							gfCutscene.visible = false;
							picoCutscene.alpha = 1;
							picoCutscene.animation.play('anim', true);

							boyfriendGroup.alpha = 1;
							boyfriendCutscene.visible = false;
							boyfriend.playAnim('bfCatch', true);
							boyfriend.animation.finishCallback = function(name:String)
							{
								if(name != 'idle')
								{
									boyfriend.playAnim('idle', true);
									boyfriend.finishAnimation(); //Instantly goes to last frame
								}
							};

							picoCutscene.animation.finishCallback = function(name:String)
							{
								picoCutscene.visible = false;
								gfGroup.alpha = 1;
								picoCutscene.animation.finishCallback = null;
							};
							gfCutscene.animation.finishCallback = null;
						}
					};
				});

				cutsceneHandler.timer(17.5, function()
				{
					zoomBack();
				});

				cutsceneHandler.timer(19.5, function()
				{
					tankman2.animation.addByPrefix('lookWhoItIs', 'TANK TALK 3', 24, false);
					tankman2.animation.play('lookWhoItIs', true);
					tankman2.alpha = 1;
					tankman.visible = false;
				});

				cutsceneHandler.timer(20, function()
				{
					camFollow.set(dad.x + 500, dad.y + 170);
				});

				cutsceneHandler.timer(31.2, function()
				{
					boyfriend.playAnim('singUPmiss', true);
					boyfriend.animation.finishCallback = function(name:String)
					{
						if (name == 'singUPmiss')
						{
							boyfriend.playAnim('idle', true);
							boyfriend.finishAnimation(); //Instantly goes to last frame
						}
					};

					camFollow.set(boyfriend.x + 280, boyfriend.y + 200);
					cameraSpeed = 12;
					FlxTween.tween(FlxG.camera, {zoom: 0.9 * 1.2 * 1.2}, 0.25, {ease: FlxEase.elasticOut});
				});

				cutsceneHandler.timer(32.2, function()
				{
					zoomBack();
				});
		}
	}

	var startTimer:FlxTimer;
	var finishTimer:FlxTimer = null;

	// For being able to mess with the sprites on Lua
	public var countdownReady:FlxSprite;
	public var countdownSet:FlxSprite;
	public var countdownGo:FlxSprite;
	public static var startOnTime:Float = 0;

	function cacheCountdown()
	{
		var introAssets:Map<String, Array<String>> = new Map<String, Array<String>>();
		introAssets.set('default', ['ready', 'set', 'go']);
		introAssets.set('pixel', ['pixelUI/ready-pixel', 'pixelUI/set-pixel', 'pixelUI/date-pixel']);

		var introAlts:Array<String> = introAssets.get('default');
		if (isPixelStage) introAlts = introAssets.get('pixel');

		for (asset in introAlts)
			Paths.image(asset);

		Paths.sound('intro3' + introSoundsSuffix);
		Paths.sound('intro2' + introSoundsSuffix);
		Paths.sound('intro1' + introSoundsSuffix);
		Paths.sound('introGo' + introSoundsSuffix);
	}

	public function startCountdown():Void
	{
		if(startedCountdown) {
			callOnScripts('onStartCountdown', []);
			return;
		}

		if (Conductor.crochet <= 0 || !Math.isFinite(Conductor.crochet))
			Conductor.changeBPM((SONG != null && SONG.bpm > 0 && Math.isFinite(SONG.bpm)) ? SONG.bpm : 100);

		#if ONLINE_ALLOWED
		// 实时对战统一起跑: 没收到 MSG_GAME_SYNC 前冻结在等待状态,
		// 收到后把 startOnTime 换算到所有端共同的服务器时刻。
		if (seiunOnline && OnlineSession.active
			&& OnlineSession.mode == online.shared.OnlineTypes.OnlineConst.MODE_REALTIME
			&& !tryConsumeRealtimeSync())
		{
			showOnlineSyncWait();
			return;
		}
		#end

		inCutscene = false;
		var ret:Dynamic = callOnScripts('onStartCountdown', [], false);
		if(ret != FunkinLua.Function_Stop) {
			if (skipCountdown || startOnTime > 0) skipArrowStartTween = true;
			if (androidControls != null) androidControls.visible = true;
			generateStaticArrows(0);
			generateStaticArrows(1);
			                        // If the player is controlling the opponent side, swap the static arrow
                        // positions/properties so arrows match the active side.
            if (playOpponent) {
                var maxSwap:Int = Std.int(Math.min(playerStrums.length, opponentStrums.length));
                for (i in 0...maxSwap) {
                    var p:StrumNote = playerStrums.members[i];
                    var o:StrumNote = opponentStrums.members[i];
					if (!ClientPrefs.data.middleScroll) {
					var tmpX:Float = p.x;
					p.x = o.x;
					o.x = tmpX;

					var tmpY:Float = p.y;
					p.y = o.y;
					o.y = tmpY;
					}


                    var tmpAngle:Float = p.angle;
                    p.angle = o.angle;
                    o.angle = tmpAngle;

                	var tmpDir:Float = p.direction;
                    p.direction = o.direction;
                     o.direction = tmpDir;

                    var tmpAlpha:Float = p.alpha;
                    p.alpha = o.alpha;
                    o.alpha = tmpAlpha;

                    var tmpDown:Bool = p.downScroll;
                    p.downScroll = o.downScroll;
                    o.downScroll = tmpDown;
					var tmpSustain:Bool = p.sustainReduce;
                    p.sustainReduce = o.sustainReduce;
                    o.sustainReduce = tmpSustain;

                    p.updateHitbox();
                    o.updateHitbox();
                }
            }
			for (i in 0...playerStrums.length) {
				setOnScripts('defaultPlayerStrumX' + i, playerStrums.members[i].x);
				setOnScripts('defaultPlayerStrumY' + i, playerStrums.members[i].y);
			}
			for (i in 0...opponentStrums.length) {
				setOnScripts('defaultOpponentStrumX' + i, opponentStrums.members[i].x);
				setOnScripts('defaultOpponentStrumY' + i, opponentStrums.members[i].y);
				//if(ClientPrefs.data.middleScroll) opponentStrums.members[i].visible = false;
			}

			startedCountdown = true;
			Conductor.songPosition = -Conductor.crochet * 5;
			setOnScripts('startedCountdown', true);
			callOnScripts('onCountdownStarted', []);

			var swagCounter:Int = 0;

			if(startOnTime < 0) startOnTime = 0;

			if (startOnTime > 0) {
				clearNotesBefore(startOnTime);
				setSongTime(startOnTime - 350);
				return;
			}
			else if (skipCountdown)
			{
				setSongTime(0);
				return;
			}

			startTimer = new FlxTimer().start(Conductor.crochet / 1000 / playbackRate, function(tmr:FlxTimer)
			{
				if (gf != null && tmr.loopsLeft % Math.round(gfSpeed * gf.danceEveryNumBeats) == 0 && !gf.isAnimationNull() && !gf.getAnimationName().startsWith("sing") && !gf.stunned)
				{
					gf.dance();
				}
				if (tmr.loopsLeft % boyfriend.danceEveryNumBeats == 0 && !boyfriend.isAnimationNull() && !boyfriend.getAnimationName().startsWith('sing') && !boyfriend.stunned)
				{
					boyfriend.dance();
				}
				if (tmr.loopsLeft % dad.danceEveryNumBeats == 0 && !dad.isAnimationNull() && !dad.getAnimationName().startsWith('sing') && !dad.stunned)
				{
					dad.dance();
				}

				var introAssets:Map<String, Array<String>> = new Map<String, Array<String>>();
				introAssets.set('default', ['ready', 'set', 'go']);
				introAssets.set('pixel', ['pixelUI/ready-pixel', 'pixelUI/set-pixel', 'pixelUI/date-pixel']);

				var introAlts:Array<String> = introAssets.get('default');
				var antialias:Bool = ClientPrefs.data.globalAntialiasing;
				if(isPixelStage) {
					introAlts = introAssets.get('pixel');
					antialias = false;
				}

				// head bopping for bg characters on Mall
				if(curStage == 'mall') {
					if(!ClientPrefs.data.lowQuality)
						upperBoppers.dance(true);

					bottomBoppers.dance(true);
					santa.dance(true);
				}

				switch (swagCounter)
				{
					case 0:
						FlxG.sound.play(Paths.sound('intro3' + introSoundsSuffix), 0.6);
					case 1:
						countdownReady = new FlxSprite().loadGraphic(Paths.image(introAlts[0]));
						countdownReady.cameras = [camHUD];
						countdownReady.scrollFactor.set();
						countdownReady.updateHitbox();

						if (PlayState.isPixelStage)
							countdownReady.setGraphicSize(Std.int(countdownReady.width * daPixelZoom));

						countdownReady.screenCenter();
						countdownReady.antialiasing = antialias;
						insert(CompatEngine.isModern() ? members.indexOf(noteGroup) : members.indexOf(notes), countdownReady);
						FlxTween.tween(countdownReady, {/*y: countdownReady.y + 100,*/ alpha: 0}, Conductor.crochet / 1000, {
							ease: FlxEase.cubeInOut,
							onComplete: function(twn:FlxTween)
							{
								remove(countdownReady);
								countdownReady.destroy();
							}
						});
						FlxG.sound.play(Paths.sound('intro2' + introSoundsSuffix), 0.6);
					case 2:
						countdownSet = new FlxSprite().loadGraphic(Paths.image(introAlts[1]));
						countdownSet.cameras = [camHUD];
						countdownSet.scrollFactor.set();

						if (PlayState.isPixelStage)
							countdownSet.setGraphicSize(Std.int(countdownSet.width * daPixelZoom));

						countdownSet.screenCenter();
						countdownSet.antialiasing = antialias;
						insert(CompatEngine.isModern() ? members.indexOf(noteGroup) : members.indexOf(notes), countdownSet);
						FlxTween.tween(countdownSet, {/*y: countdownSet.y + 100,*/ alpha: 0}, Conductor.crochet / 1000, {
							ease: FlxEase.cubeInOut,
							onComplete: function(twn:FlxTween)
							{
								remove(countdownSet);
								countdownSet.destroy();
							}
						});
						FlxG.sound.play(Paths.sound('intro1' + introSoundsSuffix), 0.6);
					case 3:
						countdownGo = new FlxSprite().loadGraphic(Paths.image(introAlts[2]));
						countdownGo.cameras = [camHUD];
						countdownGo.scrollFactor.set();

						if (PlayState.isPixelStage)
							countdownGo.setGraphicSize(Std.int(countdownGo.width * daPixelZoom));

						countdownGo.updateHitbox();

						countdownGo.screenCenter();
						countdownGo.antialiasing = antialias;
						insert(CompatEngine.isModern() ? members.indexOf(noteGroup) : members.indexOf(notes), countdownGo);
						FlxTween.tween(countdownGo, {/*y: countdownGo.y + 100,*/ alpha: 0}, Conductor.crochet / 1000, {
							ease: FlxEase.cubeInOut,
							onComplete: function(twn:FlxTween)
							{
								remove(countdownGo);
								countdownGo.destroy();
							}
						});
						FlxG.sound.play(Paths.sound('introGo' + introSoundsSuffix), 0.6);
					case 4:
				}

				notes.forEachAlive(function(note:Note) {
					if(ClientPrefs.data.opponentStrums || note.mustPress)
					{
						note.copyAlpha = false;
						note.alpha = note.multAlpha;
						if(ClientPrefs.data.middleScroll && !note.mustPress) {
							note.alpha *= 0.35;
						}
					}
				});
				callOnScripts('onCountdownTick', [swagCounter]);

				swagCounter += 1;
				// generateSong('fresh');
			}, 5);
		}
	}

	public function addBehindGF(obj:FlxObject)
	{
		insert(members.indexOf(gfGroup), obj);
	}
	public function addBehindBF(obj:FlxObject)
	{
		insert(members.indexOf(boyfriendGroup), obj);
	}
	public function addBehindDad(obj:FlxObject)
	{
		insert(members.indexOf(dadGroup), obj);
	}

	public function clearNotesBefore(time:Float)
	{
		var i:Int = unspawnNotes.length - 1;
		while (i >= 0) {
			var daNote:PreloadedChartNote = unspawnNotes[i];
			if(daNote.strumTime - 350 < time)
			{
				daNote.wasHit = true;
			}
			--i;
		}

		i = notes.length - 1;
		while (i >= 0) {
			var daNote:Note = notes.members[i];
			if(daNote.strumTime - 350 < time)
			{
				recycleNote(daNote);
			}
			--i;
		}


	}
	//var lerpSongScore:Float = 0;
	public function updateScore(miss:Bool = false)
	{
		if (hasActiveScripts())
		{
			// 有脚本: 保留原逐次回调语义 (preUpdateScore 可拦截, onUpdateScore 每次触发)
			var preResult:Dynamic = callOnScripts('preUpdateScore', [miss], true);
			if (preResult == LuaUtils.Function_Stop || preResult == FunkinLua.Function_Stop)
				return;

			scoreTxt.text = buildScoreText();
			if(ClientPrefs.data.scoreZoom && !miss && !cpuControlled)
				bounceScoreTxt();
			callOnScripts('onUpdateScore', [miss]);
			return;
		}

		if (!ClientPrefs.data.perfMode)
		{
			scoreTxt.text = buildScoreText();
			if(ClientPrefs.data.scoreZoom && !miss && !cpuControlled)
				bounceScoreTxt();
			return;
		}
		_scoreTextDirty = true;
		if (!miss && ClientPrefs.data.scoreZoom && !cpuControlled)
			_scoreZoomDirty = true;
	}

	/** 拼接分数 HUD 文本 (updateScore 的纯构建部分)。 */
	inline function buildScoreText():String
	{
		return Language.get("scorelangtxt", "Score") + ': $songScore'
		+ " | " + Language.get("combobtxt", "Combo Breaks") + ': $songMisses'
		+  " | " + Language.get("acclangtxt", "Accuracy") + ':' + (ratingName != '?' ? ' ${Highscore.floorDecimal(ratingPercent * 100, 2)}% | $ratingFC ' : '') + '($ratingName)';
	}

	/** 分数文本弹跳 (原 updateScore 内的 zoom tween 块)。 */
	function bounceScoreTxt():Void
	{
		if(scoreTxtTween != null) {
			scoreTxtTween.cancel();
		}
		scoreTxt.scale.x = 1.075;
		scoreTxt.scale.y = 1.075;
		scoreTxtTween = FlxTween.tween(scoreTxt.scale, {x: 1, y: 1}, 0.2, {
			onComplete: function(twn:FlxTween) {
				scoreTxtTween = null;
			}
		});
	}


	function flushHitPresentation():Void
	{
		if (_scoreTextDirty)
		{
			_scoreTextDirty = false;
			scoreTxt.text = buildScoreText();
			if (_scoreZoomDirty)
			{
				_scoreZoomDirty = false;
				bounceScoreTxt();
			}
		}

		if (_msTextDirty)
		{
			_msTextDirty = false;
			msTxtKade.color = _pendingMsColor;
			msTxtKade.text = _pendingMsText;
			msTxtKade.alpha = 1;
			if (msScaleTween != null) msScaleTween.cancel();
			msTxtKade.scale.set(1.15, 1.15);
			msScaleTween = FlxTween.tween(msTxtKade.scale, {x: 1, y: 1}, 0.15, {ease: FlxEase.backOut});
			if (msTween != null) msTween.cancel();
			msTween = FlxTween.tween(msTxtKade, {alpha: 0}, 0.5, {ease: FlxEase.quintIn});
		}

		if (_popupPending)
		{
			_popupPending = false;
			showComboNum = (combo >= 10);
			ratingPopup.show(_pendingRatingImage, combo, playbackRate, FlxG.width * 0.35,
				ClientPrefs.data.hideHud, showRating, showCombo, showComboNum,
				[for (v in ClientPrefs.data.comboOffset) Std.int(v)], Conductor.crochet,
				ClientPrefs.data.comboStacking);
		}
	}

	public function setSongTime(time:Float)
	{
		if(time < 0) time = 0;

		FlxG.sound.music.pause();
		vocals.pause();
		vocalsPlayer.pause();
		opponentVocals.pause();

		FlxG.sound.music.time = time;
		FlxG.sound.music.pitch = playbackRate;
		FlxG.sound.music.play();

		if (Conductor.songPosition <= vocals.length)
		{
			vocals.time = time;
			vocals.pitch = playbackRate;
		}

		if (Conductor.songPosition <= opponentVocals.length)
		{
			opponentVocals.time = time;
			opponentVocals.pitch = playbackRate;
		}

		if (Conductor.songPosition <= vocalsPlayer.length)
		{
			vocalsPlayer.time = time;
			vocalsPlayer.pitch = playbackRate;
		}
		vocals.play();
		vocalsPlayer.play();
		opponentVocals.play();

		Conductor.songPosition = time;
		songTime = time;
	}

	function startNextDialogue() {
		dialogueCount++;
		callOnScripts('onNextDialogue', [dialogueCount]);
	}

	function skipDialogue() {
		callOnScripts('onSkipDialogue', [dialogueCount]);
	}

	var previousFrameTime:Int = 0;
	var lastReportedPlayheadPosition:Int = 0;
	var songTime:Float = 0;
	var songStartTicks:Int = -1;

	/**
	 * 静音预滚歌曲音频 (keep-playing):
	 * 加载阶段就以 0 音量开始播放并保持 AudioSource 存活。
	 * PCM 解码 (mp3 尤其慢)、OpenAL 缓冲上传、vorbis 流式初始化全部提前完成,
	 * 倒计时结束时只需"归零 + 恢复音量", 不再新建音频通道,
	 * 彻底消除首次播放的卡顿 (模组 ogg 长歌尤其明显)。
	 */
	function prebufferSongAudio():Void
	{
		// 音乐轨: 直接复用 FlxG.sound.music, 0 音量播放
		try { FlxG.sound.playMusic(Paths.inst(PlayState.SONG.song), 0, false); } catch (e:Dynamic) {}

		var tracks:Array<FlxSound> = [vocals, vocalsPlayer, opponentVocals];
		for (snd in tracks)
		{
			if (snd == null || !snd.exists) continue;
			snd.volume = 0;
			try { snd.play(); } catch (e:Dynamic) {}
		}

		// 预热完成后立即在 lime 层暂停所有音源:
		// AudioSource 保持存活 (倒计时结束时恢复无任何新建开销),
		// 但暂停中的音源完全不输出, 倒计时期间物理上不可能漏音。
		pauseAudioSource(FlxG.sound.music);
		pauseAudioSource(vocals);
		pauseAudioSource(vocalsPlayer);
		pauseAudioSource(opponentVocals);
	}

	/** 在 lime 层暂停音源 (保留通道与缓冲, 暂停即静音) */
	function pauseAudioSource(snd:FlxSound):Void
	{
		if (snd == null || !snd.exists) return;

		@:privateAccess
		if (snd._channel != null && snd._channel.__source != null)
		{
			try
			{
				@:privateAccess
				snd._channel.__source.pause();
			}
			catch (e:Dynamic) {}
		}
	}

	/**
	 * 把音轨归零并恢复播放 (复用现有 AudioSource, 不新建通道)。
	 * 找不到活动通道时回退为 stop+play。
	 */
	function seekAudioToZero(snd:FlxSound):Void
	{
		if (snd == null || !snd.exists) return;

		@:privateAccess
		if (snd._channel != null && snd._channel.__source != null)
		{
			try
			{
				@:privateAccess
				snd._channel.__source.currentTime = 0;
				@:privateAccess
				snd._channel.__source.play();
				return;
			}
			catch (e:Dynamic) {}
		}

		try { snd.stop(); } catch (e:Dynamic) {}
		try { snd.play(); } catch (e:Dynamic) {}
	}

	/** 倒计时结束: 恢复音量并归零, 正式开始播放 */
	function resumeSongAudio():Void
	{
		if (FlxG.sound.music != null && FlxG.sound.music.exists)
		{
			seekAudioToZero(FlxG.sound.music);
		}
		else
		{
			// 兜底: 预滚失败时按原逻辑播放
			try { FlxG.sound.playMusic(Paths.inst(PlayState.SONG.song), 1, false); } catch (e:Dynamic) {}
		}

		seekAudioToZero(vocals);
		seekAudioToZero(vocalsPlayer);
		seekAudioToZero(opponentVocals);

		// 全部归零完成后再恢复音量, 并做 80ms 极短淡入,
		// 把倒带/重启瞬间任何残留的杂音或漏音都遮掉
		FlxG.sound.music.volume = 0;
		vocals.volume = 0;
		vocalsPlayer.volume = 0;
		opponentVocals.volume = 0;

		FlxTween.num(0, 1, 0.08, {
			onComplete: function(t:FlxTween)
			{
				FlxG.sound.music.volume = 1;
				vocals.volume = 1;
				vocalsPlayer.volume = 1;
				opponentVocals.volume = 1;
			}
		}, function(v:Float)
		{
			FlxG.sound.music.volume = v;
			vocals.volume = v;
			vocalsPlayer.volume = v;
			opponentVocals.volume = v;
		});

		// 通道已存在, 重新应用倍速音高
		vocals.pitch = playbackRate;
		vocalsPlayer.pitch = playbackRate;
		opponentVocals.pitch = playbackRate;
	}

	function startSong():Void
	{
		startingSong = false;
		#if ONLINE_ALLOWED
		// 防对局中途脚本把作弊开关改回: 开唱瞬间再强制一次。
		if (seiunOnline)
		{
			cpuControlled = false;
			practiceMode = false;
			instakillOnMiss = false;
			playOpponent = false;
		}
		#end
		// Countdown time is advanced independently of the music clock. If the
		// frame that finishes the countdown is long, songPosition may already be
		// hundreds of milliseconds past zero. Anchor normal playback at the
		// actual audio start so the first note is judged against the right clock.
		if (startOnTime <= 0)
		{
			Conductor.songPosition = 0;
			Conductor.lastSongPos = 0;
		}

		previousFrameTime = FlxG.game.ticks;
		lastReportedPlayheadPosition = 0;

		MenuFX.markMenuMusicStopped();
		resumeSongAudio();
		FlxG.sound.music.pitch = playbackRate;
		FlxG.sound.music.onComplete = onMusicComplete;
		songStartTicks = FlxG.game.ticks;

		if(startOnTime > 0)
		{
			setSongTime(startOnTime - 500);
		}
		startOnTime = 0;

		if(paused) {
			//trace('Oopsie doopsie! Paused sound');
			FlxG.sound.music.pause();
		vocals.pause();
		vocalsPlayer.pause();
		opponentVocals.pause();
		}

		// Song duration in a float, useful for the time left feature
		songLength = FlxG.sound.music.length;
		FlxTween.tween(timeBar, {alpha: 1}, 0.5, {ease: FlxEase.circOut});
		FlxTween.tween(timeTxt, {alpha: 1}, 0.5, {ease: FlxEase.circOut});

		if (stageBackdrop != null)
			stageBackdrop.songStart();

		#if cpp
		// Updating Discord Rich Presence (with Time Left)
		if(iconP2 != null) DiscordClient.changePresence(detailsText, SONG.song + " (" + storyDifficultyText + ")", iconP2.getCharacter(), true, songLength);
		#end
		setOnScripts('songLength', songLength);
		callOnScripts('onSongStart', []);
	}

	var debugNum:Int = 0;
	private var noteTypeMap:Map<String, Bool> = new Map<String, Bool>();
	private var eventPushedMap:Map<String, Bool> = new Map<String, Bool>();

	/** Pre-allocated reusable fields for Note creation to reduce GC pressure. */
	static var NOTE_HIT_HEALTH:Float = 0.023;
	private function generateSong(dataPath:String):Void
	{
		songSpeedType = ClientPrefs.getGameplaySetting('scrolltype','multiplicative');
		if (!(replayMode && replayExam != null)) {
			switch(songSpeedType) {
				case "multiplicative":
					songSpeed = SONG.speed * ClientPrefs.getGameplaySetting('scrollspeed', 1);
				case "constant":
					songSpeed = ClientPrefs.getGameplaySetting('scrollspeed', 1);
			}
		}

		var songData = SONG;
		Conductor.changeBPM(songData.bpm);
		curSong = songData.song;

		// Load vocals
		if (SONG.needsVoices) {
			var songPath:String = Paths.formatToSongPath(PlayState.SONG.song);
			#if sys
			vocals = new FlxSound().loadEmbedded(Paths.voices(PlayState.SONG.song));
			vocalsPlayer = new FlxSound().loadEmbedded(Paths.playervoices(PlayState.SONG.song));
			opponentVocals = new FlxSound().loadEmbedded(Paths.opponentvoices(PlayState.SONG.song));
			#else
			var hasPlayerVoice:Bool = Assets.exists('songs:' + Paths.getPreloadPath('songs/$songPath/Voices-Player.' + Paths.SOUND_EXT), lime.utils.AssetType.SOUND);
			var hasOpponentVoice:Bool = Assets.exists('songs:' + Paths.getPreloadPath('songs/$songPath/Voices-Opponent.' + Paths.SOUND_EXT), lime.utils.AssetType.SOUND);
			vocals = new FlxSound().loadEmbedded(Paths.voices(PlayState.SONG.song));
			vocalsPlayer = hasPlayerVoice ? new FlxSound().loadEmbedded(Paths.playervoices(PlayState.SONG.song)) : vocals;
			opponentVocals = hasOpponentVoice ? new FlxSound().loadEmbedded(Paths.opponentvoices(PlayState.SONG.song)) : vocals;
			#end
		} else {
			vocals = new FlxSound();
			vocalsPlayer = new FlxSound();
			opponentVocals = new FlxSound();
		}
		vocals.pitch = playbackRate;
		vocalsPlayer.pitch = playbackRate;
		opponentVocals.pitch = playbackRate;
		FlxG.sound.list.add(vocals);
		FlxG.sound.list.add(vocalsPlayer);
		FlxG.sound.list.add(opponentVocals);
		FlxG.sound.list.add(new FlxSound().loadEmbedded(Paths.inst(PlayState.SONG.song)));

		// 预滚歌曲音频: 在加载阶段静音播放一遍再停止, 强制完成 PCM 解码与
		// OpenAL 缓冲上传 (mp3 尤其明显), 避免倒计时结束时首次播放卡顿。
		prebufferSongAudio();

		notes = new FlxTypedGroup<Note>();
		sustainNotes = new FlxTypedGroup<Note>(); // Empty group for Lua compatibility
		if (CompatEngine.isModern())
			noteGroup.add(notes);
		else
			add(notes);

		notesAddedCount = 0;
		limitNC = 0;
		_frameAliveTally = 0;
		_lastAliveTally = 0;
		_noteSlotCursor = 0;

		var preloadedNotes:Array<PreloadedChartNote> = [];
		var noteData:Array<SwagSection> = songData.notes;
		var songName:String = Paths.formatToSongPath(SONG.song);

		// Load event notes from events.json
		var file:String = Paths.json(songName + '/events');
		#if MODS_ALLOWED
		if (FileSystem.exists(Paths.modsJson(songName + '/events')) || FileSystem.exists(file)) {
		#else
		if (OpenFlAssets.exists(file)) {
		#end
			var loadedEvents:SwagSong = Song.loadFromJson('events', songName);
			var eventsData:Array<Dynamic> = (loadedEvents != null) ? loadedEvents.events : null;
			if (eventsData != null)
			{
				for (event in eventsData)
				{
					if (event == null || event[1] == null) continue;
					for (i in 0...event[1].length)
					{
						var subEvent:EventNote = {
							strumTime: event[0] + ClientPrefs.data.noteOffset,
							event: event[1][i][0],
							value1: event[1][i][1],
							value2: event[1][i][2]
						};
						subEvent.strumTime -= eventNoteEarlyTrigger(subEvent);
						eventNotes.push(subEvent);
						eventPushed(subEvent);
						// 0.7.3+/1.0.4: onEventPushed（事件入列时触发）
						// 0.7.3+/1.0.4: onEventPushed (fires when an event is queued)
						callOnScripts('onEventPushed', [subEvent.event, subEvent.value1 != null ? subEvent.value1 : '', subEvent.value2 != null ? subEvent.value2 : '', subEvent.strumTime]);
					}
				}
			}
		}

		var stepCrochet:Float = Conductor.stepCrochet;
		var isNewVer:Bool = Song.isNewVersion;

		// 预构建 Change Mania 时间线: 每条 Note 的键数查询由全事件扫描 O(E)
		// 降为二分查找 O(log M) —— 万级 Note 谱面的加载耗时不再随事件数平方增长。
		EKData.maniaTimelineBuild(songData.events, mania);

		// noteType 字符串驻留表 (本函数内有效): JSON 解析会给每条 note 的 type
		// 新建 String 实例, 百万级谱面下内容重复的字符串常驻数百 MB。
		var typeIntern:Map<String, String> = new Map<String, String>();

		var turboStripDOM:Bool = false;

		// 多k: Change Mania 事件会把事件后的谱面按新键数解释/编码: 这里按每个 Note 自身
		// 时间点的生效键数解释轨道, 保证事件前后的 Note 各归各的键数 (无事件时与旧行为一致)。
		for (section in noteData)
		{
			if (section.changeBPM && section.bpm > 0 && Math.isFinite(section.bpm))
			{
				Conductor.changeBPM(section.bpm);
				stepCrochet = Conductor.stepCrochet;
			}

			var mustHit:Bool = section.mustHitSection;
			var gfSec:Bool = section.gfSection;

			for (songNotes in section.sectionNotes)
			{
				var rawStrum:Float = songNotes[0];
				var rawData:Int = Std.int(songNotes[1]);
				var noteMania:Int = EKData.maniaAtTimeCached(rawStrum);
				var noteAmmo:Int = Note.ammo[noteMania];
				var noteDataIdx:Int = rawData % noteAmmo;

				var gottaHitNote:Bool = isNewVer ? (rawData < noteAmmo) : (rawData >= noteAmmo ? !mustHit : mustHit);
				var isGFSide:Bool = gfSec && (gottaHitNote == mustHit);
				if (playOpponent) gottaHitNote = !gottaHitNote;

				var noteType:String = songNotes[3];
				if (!Std.isOfType(songNotes[3], String))
					noteType = Note.defaultNoteTypes[Std.int(songNotes[3])];
				else
				{
					// 驻留为共享实例并回写 DOM: 字符串不可变且内容不变,
					// 引擎/脚本读到的值完全一致, 仅消除重复对象 (无损)。
					var interned:String = typeIntern.get(noteType);
					if (interned == null)
						typeIntern.set(noteType, noteType);
					else
					{
						noteType = interned;
						songNotes[3] = interned;
					}
				}

				if (!noteTypeMap.exists(noteType))
					noteTypeMap.set(noteType, true);

				var isAlt:Bool = (noteType == 'Alt Animation');
				var isHurt:Bool = (noteType == 'Hurt Note');
				var isGF:Bool = isGFSide || noteType == 'GF Sing';
				var isNoAnim:Bool = (noteType == 'No Animation');
				var isAltSuffix:String = isAlt ? '-alt' : '';

				// Build PreloadedChartNote (lightweight data transfer object)
				var swagNote:PreloadedChartNote = {
					strumTime: rawStrum,
					noteData: noteDataIdx,
					mania: noteMania,
					mustPress: gottaHitNote,
					oppNote: playOpponent ? gottaHitNote : !gottaHitNote,
					noteType: noteType,
					animSuffix: isAltSuffix,
					gfNote: isGF,
					noAnimation: isNoAnim,
					noMissAnimation: isNoAnim,
					isSustainNote: false,
					isSustainEnd: false,
					sustainLength: songNotes[2],
					hitHealth: 0.023,
					missHealth: isHurt ? 0.3 : 0.0475,
					hitCausesMiss: isHurt,
					ignoreNote: isHurt && gottaHitNote,
					multSpeed: 1,
					multAlpha: 1,
					noteDensity: 1,
					noteskin: '',
					texture: '',
					blockHit: false,
					lowPriority: false,
					wasHit: false,
					offsetX: 0,
					offsetY: 0,
					parentST: 0,
					parentSL: 0,
					stepCrochet: stepCrochet,
					noteSplashDisabled: false,
					noteSplashTexture: null,
					noteSplashHue: null,
					noteSplashSat: null,
					noteSplashBrt: null,
					hitsoundDisabled: false
				};
				preloadedNotes.push(swagNote);

				var susLen:Float = swagNote.sustainLength;
				if (susLen < 1) continue;

				var floorSus:Int = Math.floor(susLen / stepCrochet);
				if (floorSus < 1) continue;

				var susBaseOffset:Float = stepCrochet / FlxMath.roundDecimal(songSpeed, 2);
				for (susNote in 0...floorSus + 1)
				{
					var sustainNote:PreloadedChartNote = {
						strumTime: rawStrum + (stepCrochet * susNote) + susBaseOffset,
						noteData: noteDataIdx,
						mania: noteMania,
						mustPress: gottaHitNote,
						oppNote: swagNote.oppNote,
						noteType: noteType,
						animSuffix: isAltSuffix,
						gfNote: isGF,
						noAnimation: isNoAnim,
						noMissAnimation: isNoAnim,
						isSustainNote: true,
						isSustainEnd: (susNote == floorSus),
						sustainLength: susLen,
						parentST: rawStrum,
						parentSL: susLen,
						stepCrochet: stepCrochet,
						hitHealth: 0.023,
						missHealth: isHurt ? 0.1 : 0.0475,
						hitCausesMiss: isHurt,
						ignoreNote: isHurt && gottaHitNote,
						multSpeed: 1,
						multAlpha: 1,
						noteDensity: 1,
						noteskin: '',
						texture: '',
						blockHit: false,
						lowPriority: false,
						wasHit: false,
						offsetX: 0,
						offsetY: 0,
						noteSplashDisabled: false,
						noteSplashTexture: null,
						noteSplashHue: null,
						noteSplashSat: null,
						noteSplashBrt: null,
						hitsoundDisabled: false
					};
					preloadedNotes.push(sustainNote);
				}
			}

			// Turbo 专属: 本节逐 note 数据已全部转换为 PreloadedChartNote, 立即释放本节数组,
			// 使 DOM 释放与生成同步进行 (降低生成期峰值内存); 非 Turbo 不动 DOM。
			if (turboStripDOM)
				section.sectionNotes = [];
		}

		// Load song events (legacy format)
		if (songData.events != null)
		{
			for (event in songData.events)
			{
				if (event == null || event[1] == null) continue;
				for (i in 0...event[1].length)
				{
					var subEvent:EventNote = {
						strumTime: event[0] + ClientPrefs.data.noteOffset,
						event: event[1][i][0],
						value1: event[1][i][1],
						value2: event[1][i][2]
					};
					subEvent.strumTime -= eventNoteEarlyTrigger(subEvent);
					eventNotes.push(subEvent);
					eventPushed(subEvent);
					// 0.7.3+/1.0.4: onEventPushed（事件入列时触发）
					// 0.7.3+/1.0.4: onEventPushed (fires when an event is queued)
					callOnScripts('onEventPushed', [subEvent.event, subEvent.value1 != null ? subEvent.value1 : '', subEvent.value2 != null ? subEvent.value2 : '', subEvent.strumTime]);
				}
			}
		}

		// Turbo 专属: 事件已全部入列 eventNotes (mania 时间线也已构建), 释放 DOM 事件数组,
		// 并在 SONG 上记录重载参数, 重开时由 create 的守卫从磁盘无损重载。
		if (turboStripDOM)
		{
			Reflect.setField(songData, '__seiunStripped', true);
			Reflect.setField(songData, '__seiunReloadJson', Song.lastChartReloadJson);
			Reflect.setField(songData, '__seiunReloadFolder', Song.lastChartReloadFolder);
			songData.events = [];
		}

		// Sort preloaded notes by time
		// 防护: 数组若在生成阶段被异常破坏出现 null 槽位, sort 闭包解引用会直接原生
		// 崩溃 (AV@0x8, hxcpp 对 null this 无检查, 曾在重开关卡时概率性触发)。
		// 正常路径只有一次 O(n) 指针扫描; 检出 null 时重建数组剔除毒槽, 闭包内再兜底。
		//果然hxcpp就是一坨屎
		var hasNullSlot:Bool = false;
		for (n in preloadedNotes)
		{
			if (n == null)
			{
				hasNullSlot = true;
				break;
			}
		}
		if (hasNullSlot)
			preloadedNotes = preloadedNotes.filter(function(n) return n != null);
		preloadedNotes.sort(function(a, b) {
			if (a == null || b == null)
				return 0;
			return FlxSort.byValues(FlxSort.ASCENDING, a.strumTime, b.strumTime);
		});
		lastChartNoteTime = 0;
		if (preloadedNotes.length > 0 && preloadedNotes[preloadedNotes.length - 1] != null)
			lastChartNoteTime = preloadedNotes[preloadedNotes.length - 1].strumTime;

		// Turbo: 按"屏幕像素间距"折叠 tap —— 低流速下屏幕可视频段会被拉长到数秒,
		// 几千万 Note 的谱面在这个窗口里能塞进六位数条 Note; 其中绝大多数在屏幕上
		// 完全重叠 (同一轨道同向, 间距不足几个像素), 全部物化纯粹是浪费。
		// 折叠后同时存活精灵数只由"流速 × 屏幕几何 × 轨道数"决定, 与谱面密度无关。
		// 这一步是纯数据变换: 不改写入参对象, 不落盘, 重复调用结果一致。
		_turboRawTapCount = 0;
		if (turboModeActive)
		{
			_turboRawTapCount = preloadedNotes.length;
			preloadedNotes = TurboDensity.collapseGhostNotes(preloadedNotes, Note.ammo[mania], 1.0, songSpeed, mania);
		}

		// 轻量谱面数据：不再提前物化成 Note 对象。
		// Note 只在进入生成窗口时由 spawn 循环物化，峰值内存 = 同时存活 Note，而不是整张谱面。
		unspawnNotes = preloadedNotes;
		lastSpawnedNote = new Map<Int, Note>();
		_chartHasHolds = false;
		for (pn in preloadedNotes)
		{
			if (pn.isSustainNote || pn.sustainLength > 0)
			{
				_chartHasHolds = true;
				break;
			}
		}

		if (turboModeActive)
		{
			trace('Turbo: chart notes ' + _turboRawTapCount + ' -> ' + unspawnNotes.length
				+ ' representatives (represented=' + TurboDensity.representedTotal(unspawnNotes)
				+ ', speed=' + FlxMath.roundDecimal(songSpeed, 2) + ', mania=' + mania + ')');
		}

		if (eventNotes.length > 1)
			eventNotes.sort(sortByTime);

		checkEventNote();

		if (Math.isNaN(songData.bpm) || songData.bpm <= 0)
			Conductor.changeBPM(100);
		else
			Conductor.changeBPM(songData.bpm);

		generatedMusic = true;
	}

	// ─────────────────────────────────────────────────────────────
	// Turbo 谱面预处理
	// ─────────────────────────────────────────────────────────────
	// 高密度段的处理全部在加载期完成 (TurboDensity.collapseGhostNotes):
	// 屏幕上分不开的 tap 折叠成代表 Note, 其 noteDensity = 折叠数量,
	// 运行时按簇批量结算 (见 bulkSettleNote)。
	//
	// 这里刻意不再有"高密度聚合区"侧车缓存:
	//   - 缓存内容是 unspawnNotes 的**下标区间**, 属于位置相关状态。任何一次折叠
	//     口径变化都会让它整体错位, 而写坏的索引不会崩, 只会静默算错区间;
	//   - 旧折叠实现会直接改写共享对象 (prev.noteDensity += 1), 因此对同一数组
	//     重复调用会得到不同结果 —— 也就是同一张谱面会不停生成新的缓存文件。
	//     实测 turbo_cache/ 里同一首歌、同一 Note 数留下了 5 份不同指纹的缓存;
	//   - 折叠口径改为像素级之后, 物化量已由流速与屏幕几何定量约束, 区间缓存
	//     带来的收益 (省一次 O(n) 扫描) 远小于它引入的失效风险。

	function eventPushed(event:EventNote) {
		switch(event.event) {
			case 'Change Character':
				var charType:Int = 0;
				switch(event.value1.toLowerCase()) {
					case 'gf' | 'girlfriend' | '1':
						charType = 2;
					case 'dad' | 'opponent' | '0':
						charType = 1;
					default:
						charType = Std.parseInt(event.value1);
						if(Math.isNaN(charType)) charType = 0;
				}

				var newCharacter:String = event.value2;
				addCharacterToList(newCharacter, charType);

			case 'Dadbattle Spotlight':
				dadbattleBlack = new BGSprite(null, -800, -400, 0, 0);
				dadbattleBlack.makeGraphic(Std.int(FlxG.width * 2), Std.int(FlxG.height * 2), FlxColor.BLACK);
				dadbattleBlack.alpha = 0.25;
				dadbattleBlack.visible = false;
				add(dadbattleBlack);

				dadbattleLight = new BGSprite('spotlight', 400, -400);
				dadbattleLight.alpha = 0.375;
				dadbattleLight.blend = ADD;
				dadbattleLight.visible = false;

				dadbattleSmokes.alpha = 0.7;
				dadbattleSmokes.blend = ADD;
				dadbattleSmokes.visible = false;
				add(dadbattleLight);
				add(dadbattleSmokes);

				var offsetX = 200;
				var smoke:BGSprite = new BGSprite('smoke', -1550 + offsetX, 660 + FlxG.random.float(-20, 20), 1.2, 1.05);
				smoke.setGraphicSize(Std.int(smoke.width * FlxG.random.float(1.1, 1.22)));
				smoke.updateHitbox();
				smoke.velocity.x = FlxG.random.float(15, 22);
				smoke.active = true;
				dadbattleSmokes.add(smoke);
				var smoke:BGSprite = new BGSprite('smoke', 1550 + offsetX, 660 + FlxG.random.float(-20, 20), 1.2, 1.05);
				smoke.setGraphicSize(Std.int(smoke.width * FlxG.random.float(1.1, 1.22)));
				smoke.updateHitbox();
				smoke.velocity.x = FlxG.random.float(-15, -22);
				smoke.active = true;
				smoke.flipX = true;
				dadbattleSmokes.add(smoke);


			case 'Philly Glow':
				blammedLightsBlack = new FlxSprite(FlxG.width * -0.5, FlxG.height * -0.5).makeGraphic(Std.int(FlxG.width * 2), Std.int(FlxG.height * 2), FlxColor.BLACK);
				blammedLightsBlack.visible = false;
				insert(members.indexOf(phillyStreet), blammedLightsBlack);

				phillyWindowEvent = new BGSprite('philly/window', phillyWindow.x, phillyWindow.y, 0.3, 0.3);
				phillyWindowEvent.setGraphicSize(Std.int(phillyWindowEvent.width * 0.85));
				phillyWindowEvent.updateHitbox();
				phillyWindowEvent.visible = false;
				insert(members.indexOf(blammedLightsBlack) + 1, phillyWindowEvent);


				phillyGlowGradient = new PhillyGlow.PhillyGlowGradient(-400, 225); //This shit was refusing to properly load FlxGradient so fuck it
				phillyGlowGradient.visible = false;
				insert(members.indexOf(blammedLightsBlack) + 1, phillyGlowGradient);
				if(!ClientPrefs.data.flashing) phillyGlowGradient.intendedAlpha = 0.7;

				precacheList.set('philly/particle', 'image'); //precache particle image
				phillyGlowParticles = new FlxTypedGroup<PhillyGlow.PhillyGlowParticle>();
				phillyGlowParticles.visible = false;
				insert(members.indexOf(phillyGlowGradient) + 1, phillyGlowParticles);
		}

		if(!eventPushedMap.exists(event.event)) {
			eventPushedMap.set(event.event, true);
		}
	}

	function eventNoteEarlyTrigger(event:EventNote):Float {
		var returnedValue:Float = callOnScripts('eventEarlyTrigger', [event.event]);
		if(returnedValue != 0) {
			return returnedValue;
		}

		switch(event.event) {
			case 'Kill Henchmen': //Better timing so that the kill sound matches the beat intended
				return 280; //Plays 280ms before the actual position
		}
		return 0;
	}

	function sortByShit(Obj1:Note, Obj2:Note):Int
	{
		return FlxSort.byValues(FlxSort.ASCENDING, Obj1.strumTime, Obj2.strumTime);
	}

	public static function sortByTime(Obj1:Dynamic, Obj2:Dynamic):Int
	{
		return FlxSort.byValues(FlxSort.ASCENDING, Obj1.strumTime, Obj2.strumTime);
	}

	public var skipArrowStartTween:Bool = false; //for lua
	private function generateStaticArrows(player:Int):Void
	{
		for (i in 0...Note.ammo[mania])
		{
			// FlxG.log.add(i);
			var targetAlpha:Float = 1;
			if (player < 1)
			{
				if(!ClientPrefs.data.opponentStrums) targetAlpha = 0;
				else if(ClientPrefs.data.middleScroll) targetAlpha = 0.35;
			}

			var babyArrow:StrumNote = new StrumNote(ClientPrefs.data.middleScroll ? STRUM_X_MIDDLESCROLL : STRUM_X, strumLine.y, i, player);
			babyArrow.downScroll = ClientPrefs.data.downScroll;
			if (!isStoryMode && !skipArrowStartTween)
			{
				//babyArrow.y -= 10;
				babyArrow.alpha = 0;
				var twnDuration:Float = (mania == 3) ? 1 : Math.max(0.4, 4 / Math.max(mania, 1));
				var twnStart:Float = (mania == 3) ? 0.5 + (0.2 * i) : 0.5 + ((0.8 / Math.max(mania, 1)) * i);
				FlxTween.tween(babyArrow, {/*y: babyArrow.y + 10,*/ alpha: targetAlpha}, twnDuration, {ease: FlxEase.circOut, startDelay: twnStart});
			}
			else
			{
				babyArrow.alpha = targetAlpha;
			}

			if (player == 1)
			{
				playerStrums.add(babyArrow);
			}
			else
			{
				if(ClientPrefs.data.middleScroll)
				{
					var separator:Int = Note.separator[mania];
					babyArrow.x += 310;
					if(i > separator) { //Up and Right
						babyArrow.x += FlxG.width / 2 + 25;
					}
				}
				opponentStrums.add(babyArrow);
			}

		strumLineNotes.add(babyArrow);
		babyArrow.postAddedToGroup();
		// 多k: middleScroll 时对手 strum 自适应屏幕两侧, 避免与玩家 strum 重叠
		if (player == 0 && ClientPrefs.data.middleScroll && Note.ammo[mania] > 4)
		{
			var separator:Int = Note.separator[mania];
			var ammo:Int = Note.ammo[mania];
			var step:Float = babyArrow.width - EKData.lessX[mania];
			if (i <= separator)
				babyArrow.x = 30 + i * step;
			else
				babyArrow.x = FlxG.width - 30 - (ammo - i) * step;
		}
		}
	}

	/**
	 * 多k: 中途切换谱面键数 (Change Mania 事件 / Lua / HScript 调用)。
	 * 旧 strum 过渡 -> 重建 strum -> 新 k 值生效。已生成的 Note 保留其生成时
	 * 的 k 值快照继续渲染/判定, 直到被销毁; 之后新生成的 Note 使用新 k 值。
	 *
	 * 过渡动画支持 Lua/HScript 自定义:
	 * - 动画开始前触发 onChangeManiaStart 脚本回调, 脚本可返回 true / Function_Stop
	 *   完全接管动画 (引擎跳过内置过渡, 脚本自行用 noteTweenX/doTweenX 等补间)。
	 * - 未接管时按 animStyle 播放内置动画, 内置动画至少 3 种:
	 *   fade (淡出淡入) / slide (向两侧滑出滑入) / zoom (缩放淡出) / spin (旋转淡出)。
	 * - 动画样式可通过 Lua/HScript setMania(k, skip, "样式名") 或事件 Value 2 指定,
	 *   脚本也可 setVar('maniaChangeAnimStyle', '样式名') 预设。
	 *
	 * @param skipStrumFadeOut 为 true 时跳过过渡动画
	 * @param animStyle 内置动画样式名 (fade/slide/zoom/spin), 为空时取脚本变量, 默认 fade
	 */
	public function changeMania(newValue:Int, skipStrumFadeOut:Bool = false, ?animStyle:String = null)
	{
		newValue = EKData.clampMania(newValue);
		if (newValue == mania && strumLineNotes != null && strumLineNotes.length == Note.ammo[mania] * 2)
			return;

		var daOldMania:Int = mania;

		// 动画样式: 参数 > 脚本预设变量 > 默认 fade
		if (animStyle == null || animStyle.length < 1)
			animStyle = Std.string(getScriptManiaAnimStyle());
		if (animStyle == null || animStyle.length < 1) animStyle = 'fade';

		// 允许 Lua/HScript 接管动画: onChangeManiaStart 返回 true/Function_Stop 则跳过内置过渡
		var customAnim:Bool = false;
		var scriptResult:Dynamic = callOnScripts('onChangeManiaStart', [newValue, daOldMania, animStyle]);
		if (scriptResult == true || scriptResult == FunkinLua.Function_Stop)
			customAnim = true;

		mania = newValue;

		// 内置过渡: 旧 strum 按动画样式退场 (可被 skip / 脚本接管跳过)
		if (!skipStrumFadeOut && !customAnim && strumLineNotes != null)
			playManiaStrumOutAnim(animStyle);

		playerStrums.clear();
		opponentStrums.clear();
		strumLineNotes.clear();

		// 同步新 k 值的键位绑定
		var allKeybinds:Array<Array<Dynamic>> = Keybinds.fill();
		keysArray = (mania >= 0 && mania < allKeybinds.length) ? allKeybinds[mania] : allKeybinds[3];
		setOnScripts('mania', mania);
		setOnScripts('keys', mania + 1);

		// 暂时禁用 generateStaticArrows 内部的入场 tween, 由内置动画接管 (脚本接管时保持原有行为)
		var prevSkipArrowTween:Bool = skipArrowStartTween;
		if (!skipStrumFadeOut && !customAnim) skipArrowStartTween = true;
		generateStaticArrows(0);
		generateStaticArrows(1);
		skipArrowStartTween = prevSkipArrowTween;

		// 内置过渡: 新 strum 入场动画
		if (!skipStrumFadeOut && !customAnim)
			playManiaStrumInAnim(animStyle);

		// 多k: 切 K 后同步重建小键盘显示 (键数/键名/统计条)
		if (keyboardDisplay != null)
			keyboardDisplay.rebuild();

		// 多k: 实时重置已生成 Note 的缩放大小, 与新的 strum 大小保持同步
		// 仅重置属于新 k 段 (mania 快照 == 当前 k) 的 Note, 避免覆盖其他 k 段 Note 的缩放
		// (>9K 时 strum 显著缩小, 已生成 Note 若保持旧缩放会与 strum 错位)
		// 未物化的 unspawnNotes 是轻量数据，spawn 时 setupNoteData 会用各自的 mania 快照生成，无需在此调整。
		for (note in notes.members)
			if (note != null && note.exists && note.noteData > -1 && note.mania == mania) note.resetNoteScaleForMania(mania);

		callOnScripts('onChangeMania', [mania, daOldMania]);
	}

	/**
	 * 读取脚本预设的切 K 动画样式。
	 * HScript: 可通过 `maniaChangeAnimStyle = "slide";` 预设 (引擎读取全局变量)。
	 * Lua: 推荐直接调用 `setMania(k, skip, "样式名")` / `changeMania(k, skip, "样式名")` 传样式。
	 */
	function getScriptManiaAnimStyle():String
	{
		var v:Dynamic = null;
		#if HSCRIPT_ALLOWED
		for (script in hscriptArray) { if (script != null && !script.closed) { v = script.get('maniaChangeAnimStyle'); if (v != null) break; } }
		#end
		return (v != null) ? Std.string(v) : '';
	}

	/** 旧 strum 退场动画: fade 淡出 / slide 滑出 / zoom 缩小淡出 / spin 旋转淡出。 */
	function playManiaStrumOutAnim(animStyle:String):Void
	{
		if (strumLineNotes == null) return;
		var ammo:Int = Note.ammo[mania];
		for (i in 0...strumLineNotes.members.length)
		{
			var oldStrum:StrumNote = strumLineNotes.members[i];
			if (oldStrum == null) continue;
			var ghost:FlxSprite = oldStrum.clone();
			ghost.x = oldStrum.x;
			ghost.y = oldStrum.y;
			ghost.alpha = oldStrum.alpha;
			ghost.scrollFactor.set();
			ghost.cameras = [camHUD];
			add(ghost);
			switch(animStyle.toLowerCase())
			{
				case 'slide':
					// 玩家侧向右、对手侧向左滑出
					var dir:Float = (i < ammo) ? -1 : 1;
					FlxTween.tween(ghost, {x: ghost.x + dir * FlxG.width * 0.5, alpha: 0}, 0.35, {
						ease: FlxEase.circIn,
						onComplete: function(_) { remove(ghost); ghost.destroy(); }
					});
				case 'zoom':
					FlxTween.tween(ghost.scale, {x: 0.05, y: 0.05}, 0.3, {ease: FlxEase.backIn});
					FlxTween.tween(ghost, {alpha: 0}, 0.3, {
						ease: FlxEase.circIn,
						onComplete: function(_) { remove(ghost); ghost.destroy(); }
					});
				case 'spin':
					FlxTween.tween(ghost, {angle: 360, alpha: 0}, 0.4, {
						ease: FlxEase.circIn,
						onComplete: function(_) { remove(ghost); ghost.destroy(); }
					});
				default: // fade
					FlxTween.tween(ghost, {alpha: 0}, 0.3, {
						ease: FlxEase.circOut,
						onComplete: function(_) { remove(ghost); ghost.destroy(); }
					});
			}
		}
	}

	/** 新 strum 入场动画: fade 淡入 / slide 从两侧滑入 / zoom 放大进入 / spin 旋转进入。 */
	function playManiaStrumInAnim(animStyle:String):Void
	{
		if (strumLineNotes == null) return;
		var ammo:Int = Note.ammo[mania];
		for (i in 0...strumLineNotes.members.length)
		{
			var strum:StrumNote = strumLineNotes.members[i];
			if (strum == null) continue;
			var targetX:Float = strum.x;
			var targetAlpha:Float = strum.alpha;
			var targetScaleX:Float = strum.scale.x;
			var targetScaleY:Float = strum.scale.y;
			switch(animStyle.toLowerCase())
			{
				case 'slide':
					var dir:Float = (i < ammo) ? -1 : 1;
					strum.x = targetX - dir * FlxG.width * 0.5;
					strum.alpha = 0;
					FlxTween.tween(strum, {x: targetX, alpha: targetAlpha}, 0.4, {ease: FlxEase.circOut});
				case 'zoom':
					strum.alpha = 0;
					strum.scale.set(0.05, 0.05);
					FlxTween.tween(strum, {alpha: targetAlpha}, 0.35, {ease: FlxEase.circOut});
					FlxTween.tween(strum.scale, {x: targetScaleX, y: targetScaleY}, 0.35, {ease: FlxEase.backOut});
				case 'spin':
					strum.angle = -360;
					strum.alpha = 0;
					FlxTween.tween(strum, {angle: 0, alpha: targetAlpha}, 0.4, {ease: FlxEase.circOut});
				default: // fade
					strum.alpha = 0;
					FlxTween.tween(strum, {alpha: targetAlpha}, 0.3, {ease: FlxEase.circOut});
			}
		}
	}

	/** 多k HScript API: 当前键数 (1 基)。 */
	public function getManiaK():Int
	{
		return mania + 1;
	}

	/** 多k HScript API: 修改指定 Note 的材质。 */
	public function setNoteTextureByIndex(noteIndex:Int, texture:String):Bool
	{
		if (texture == null || noteIndex < 0 || noteIndex >= notes.length) return false;
		var note:Note = notes.members[noteIndex];
		if (note == null || !note.exists || note.noteData < 0) return false;
		// 自定义纹理不应用多k 调色 (默认/空纹理恢复轨道色)
		note.applyLaneColorShader = (texture.length < 1 || texture == 'NOTE_assets');
		note.texture = texture;
		note.reloadNote('', texture);
		if (note.applyLaneColorShader) note.applyLaneColor();
		return true;
	}

	/** 多k HScript API: 修改指定 Note 命中时的角色动作。 */
	public function setNoteCharAnimByIndex(noteIndex:Int, anim:String):Bool
	{
		if (noteIndex < 0 || noteIndex >= notes.length) return false;
		var note:Note = notes.members[noteIndex];
		if (note == null || !note.exists) return false;
		note.customCharAnim = (anim == null || anim.length < 1) ? null : anim;
		return true;
	}

	/** 多k HScript API: 直接修改指定 Note 的颜色 (hue/sat/brt, 0~360/0~100/0~100)。 */
	public function setNoteColorByIndex(noteIndex:Int, hue:Float, sat:Float, brt:Float):Bool
	{
		if (noteIndex < 0 || noteIndex >= notes.length) return false;
		var note:Note = notes.members[noteIndex];
		if (note == null || !note.exists || note.colorSwap == null) return false;
		note.noteColorOverride = [hue / 360, sat / 100, brt / 100];
		note.applyLaneColor();
		return true;
	}

	override function openSubState(SubState:FlxSubState)
	{
		if (paused)
		{
			if (FlxG.sound.music != null)
			{
				FlxG.sound.music.pause();
			vocals.pause();
			vocalsPlayer.pause();
			opponentVocals.pause();
			}

			if (startTimer != null && !startTimer.finished)
				startTimer.active = false;
			if (finishTimer != null && !finishTimer.finished)
				finishTimer.active = false;
			if (songSpeedTween != null)
				songSpeedTween.active = false;

			if (limoStage != null && limoStage.carTimer != null) limoStage.carTimer.active = false;

			var chars:Array<Character> = [boyfriend, gf, dad];
			for (char in chars) {
				if(char != null && char.colorTween != null) {
					char.colorTween.active = false;
				}
			}

			for (tween in modchartTweens) {
				tween.active = false;
			}
			for (timer in modchartTimers) {
				timer.active = false;
			}
		}

		super.openSubState(SubState);
	}

	override function closeSubState()
	{
		if (paused)
		{
			if (FlxG.sound.music != null && !startingSong)
			{
				resyncVocals();
			}

			if (startTimer != null && !startTimer.finished)
				startTimer.active = true;
			if (finishTimer != null && !finishTimer.finished)
				finishTimer.active = true;
			if (songSpeedTween != null)
				songSpeedTween.active = true;

			if (limoStage != null && limoStage.carTimer != null) limoStage.carTimer.active = true;

			var chars:Array<Character> = [boyfriend, gf, dad];
			for (char in chars) {
				if(char != null && char.colorTween != null) {
					char.colorTween.active = true;
				}
			}

			for (tween in modchartTweens) {
				tween.active = true;
			}
			for (timer in modchartTimers) {
				timer.active = true;
			}
			paused = false;
			callOnScripts('onResume', []);

			#if desktop
			if (startTimer != null && startTimer.finished)
			{
				if(iconP2 != null) DiscordClient.changePresence(detailsText, SONG.song + " (" + storyDifficultyText + ")", iconP2.getCharacter(), true, songLength - Conductor.songPosition - ClientPrefs.data.noteOffset);
			}
			else
			{
				if(iconP2 != null) DiscordClient.changePresence(detailsText, SONG.song + " (" + storyDifficultyText + ")", iconP2.getCharacter());
			}
			#end
		}

		super.closeSubState();
	}

	override public function onFocus():Void
	{
		#if desktop
		if (health > 0 && !paused && iconP2 != null)
		{
			if (Conductor.songPosition > 0.0)
			{
				DiscordClient.changePresence(detailsText, SONG.song + " (" + storyDifficultyText + ")", iconP2.getCharacter(), true, songLength - Conductor.songPosition - ClientPrefs.data.noteOffset);
			}
			else
			{
				DiscordClient.changePresence(detailsText, SONG.song + " (" + storyDifficultyText + ")", iconP2.getCharacter());
			}
		}
		#end

		super.onFocus();
	}

	override public function onFocusLost():Void
	{
		#if desktop
		if (health > 0 && !paused && iconP2 != null)
		{
			DiscordClient.changePresence(detailsPausedText, SONG.song + " (" + storyDifficultyText + ")", iconP2.getCharacter());
		}
		#end

		super.onFocusLost();
	}

	function resyncVocals():Void
	{
		if(finishTimer != null || startingSong || FlxG.sound.music == null) return;

		vocals.pause();
		vocalsPlayer.pause();
		opponentVocals.pause();

		FlxG.sound.music.play();
		FlxG.sound.music.pitch = playbackRate;
		Conductor.songPosition = FlxG.sound.music.time;
		if (Conductor.songPosition <= vocals.length)
		{
			vocals.time = Conductor.songPosition;
			vocals.pitch = playbackRate;
		}
		if (Conductor.songPosition <= vocalsPlayer.length)
		{
			vocalsPlayer.time = Conductor.songPosition;
			vocalsPlayer.pitch = playbackRate;
		}
		if (Conductor.songPosition <= opponentVocals.length)
		{
			opponentVocals.time = Conductor.songPosition;
			opponentVocals.pitch = playbackRate;
		}
		vocals.play();
		vocalsPlayer.play();
		opponentVocals.play();
	}

	public var paused:Bool = false;
	public var canReset:Bool = true;
	var startedCountdown:Bool = false;
	var canPause:Bool = true;

	override public function update(elapsed:Float)
	{
		// perfMode 关闭: 预算视为无限 —— 弹窗/溅射回到原版逐击直显, 无存活上限。
		if (ClientPrefs.data.perfMode)
		{
			_popupImmediateBudget = POPUP_IMMEDIATE_HITS;
			_splashBudgetLeft = SPLASH_FRAME_BUDGET;
		}
		else
		{
			_popupImmediateBudget = 999999;
			_splashBudgetLeft = 999999;
		}
		var _phaseT:Float = haxe.Timer.stamp();
		#if seiun_lua_perf
		// 埋点（默认关闭）：本窗口测量的是「一次 update 步」内的耗时。
		// 注意 FlxG.fixedTimestep = true（见 flixel/FlxG.hx:78），所以 update() 每渲染帧
		// 可能被调用 0..N 次；这里绝不能放每秒一次的逻辑（落盘由 SystemDiag 心跳负责）。
		// English: measures one update *step*; update() may run 0..N times per drawn
		// frame under fixed timestep, so no once-per-frame work belongs here.
		var _perfFrameT0:Float = LuaPerf.now();
		var _perfLuaT0:Float = _perfFrameT0;
		#end
		/*if (FlxG.keys.justPressed.NINE)
		{
			iconP1.swapOldIcon();
		}*/
		callOnScripts('onUpdate', [elapsed]);
		#if ONLINE_ALLOWED
		updateOnline(elapsed);
		#end

		keyboardDisplay.dataUpdate(elapsed);
		/*
		lerpSongScore = FlxMath.lerp(lerpSongScore, songScore, CoolUtil.boundTo(elapsed * 10, 0, 1));
   		if (Math.abs(lerpSongScore - songScore) <= 10) lerpSongScore = songScore;
		scoreTxt.text = Language.get("scorelangtxt", "Score") + ': ${Math.floor(lerpSongScore)}'
		+ " | " + Language.get("combobtxt", "Combo Breaks") + ': $songMisses'
		+  " | " + Language.get("acclangtxt", "Accuracy") + ':' + (ratingName != '?' ? ' ${Highscore.floorDecimal(ratingPercent * 100, 2)}% | $ratingFC ' : '') + '($ratingName)';
		*/

		// Delegate per-frame stage update to the backdrop handler
		if (stageBackdrop != null)
			stageBackdrop.update(elapsed);

		if(!inCutscene) {
			var lerpVal:Float = CoolUtil.boundTo(elapsed * 2.4 * cameraSpeed * playbackRate, 0, 1);
			camFollowPos.setPosition(FlxMath.lerp(camFollowPos.x, camFollow.x, lerpVal), FlxMath.lerp(camFollowPos.y, camFollow.y, lerpVal));
			if(!startingSong && !endingSong && !boyfriend.isAnimationNull() && boyfriend.getAnimationName().startsWith('idle')) {
				boyfriendIdleTime += elapsed;
				if(boyfriendIdleTime >= 0.15) { // Kind of a mercy thing for making the achievement easier to get as it's apparently frustrating to some playerss
					boyfriendIdled = true;
				}
			} else {
				boyfriendIdleTime = 0;
			}
		}
		if (combo > maxcombo){
		maxcombo = combo;
		}
		super.update(elapsed);


		// Track background: reposition and resize to follow player strum lanes
		if (playerStrums != null && playerStrums.length >= 2 && trackBackground != null)
		{
			var minX:Float = 999999;
			var maxX:Float = -999999;
			for (strum in playerStrums.members)
			{
				if (strum == null) continue;
				if (strum.x < minX) minX = strum.x;
				if (strum.x > maxX) maxX = strum.x;
			}
			if (minX > maxX) { minX = playerStrums.members[0].x; maxX = minX; }
			var extraWidth:Float = scaleFactor * 15;
			trackBackground.x = minX - extraWidth;
			var newWidth:Float = (maxX + 112) - minX + (extraWidth * 2);
			if (Math.abs(trackBackground.width - newWidth) > 1)
				trackBackground.makeGraphic(Std.int(newWidth), 820, FlxColor.fromString('#' + trackColor));

			// Ensure track bg is behind notes
			if (strumLineNotes != null) {
				var bgIdx:Int = members.indexOf(trackBackground);
				var notesIdx:Int = CompatEngine.isModern()
					? members.indexOf(noteGroup)
					: members.indexOf(strumLineNotes);
				if (bgIdx > notesIdx) {
					remove(trackBackground, true);
					insert(notesIdx, trackBackground);
				}
			}
		}


		if (ClientPrefs.data.sidehud) {
			tnh.text = Language.get("totalNotesText", "Total Notes Hit:") + notehitlol;
			cm.text = Language.get("combosText", "Combos") + combo + '($maxcombo)';
			if (marv != null) marv.text = Language.get("marvelousesText", "Marvelouses:") + marvelouses;
			sick.text = Language.get("sicksText", "Sicks:") + sicks;
			good.text = Language.get("goodsText", "Goods:") + goods;
			bad.text = Language.get("badsText", "Bads:") + bads;
			shit.text = Language.get("shitsText", "Shits:") + shits;
			miss.text = Language.get("missesText", "Misses:") + songMisses;
		}

		setOnScripts('curDecStep', curDecStep);
		setOnScripts('curDecBeat', curDecBeat);

		if(botplayTxt.visible) {
			botplaySine += 180 * elapsed;
			botplayTxt.alpha = 1 - Math.sin((Math.PI * botplaySine) / 180 * playbackRate);
		}
		if(botplayTxt != null && cpuControlled && !botplayUsed) botplayUsed = true;
		if(replayTxt.visible) {
			replaySine += 180 * elapsed;
			replayTxt.alpha = 1 - Math.sin((Math.PI * replaySine) / 180);
		}


		if ((controls.PAUSE	#if android || FlxG.android.justReleased.BACK #end) && (startedCountdown #if ONLINE_ALLOWED || onlineGateWaiting() #end) && canPause)
		{
			var ret:Dynamic = callOnScripts('onPause', [], false);
			if(ret != FunkinLua.Function_Stop#if VIDEOS_ALLOWED && !videoPlaying #end)  {
				#if ONLINE_ALLOWED
				if (seiunOnline && !onlineCanPauseLocally() && !onlineGateWaiting())
				{
					// 暂停策略限制 (仅房主可暂停 / 禁止暂停): 拦截并提示, 不弹暂停菜单。
					// 但统一起跑前的等待阶段例外: 即使房主禁止暂停, 玩家也需要能退出对局/房间。
					FlxG.sound.play(Paths.sound('cancelMenu'));
					showOnlinePauseNotice(Language.get('online.pauseBlocked' + (onlinePausePolicy() == online.shared.OnlineTypes.OnlineConst.PAUSE_DISABLED ? 'Disabled' : 'HostOnly'),
						onlinePausePolicy() == online.shared.OnlineTypes.OnlineConst.PAUSE_DISABLED ? '房主禁止了对局暂停' : '只有房主可以暂停对局'));
				}
				else
				#end
				openPauseMenu();
			}
		}

		if (FlxG.keys.anyJustPressed(debugKeysChart) && !endingSong && !inCutscene && !seiunOnline)
		{
			openChartEditor();
		}


		if (cpuControlled && (songScore != 0 || songHits != 0)) {
			songScore = 0;
			songHits = 0;
			RecalculateRating();
			updateScore();
		}

		// Clamp health
		if (health > 2) health = 2;

		// Update health icon frames based on bar percent (use cached getter)
		var hpPercent:Float = _healthBarPercent;
		var p1frame:Int = iconP1.animation.curAnim.curFrame;
		var p2frame:Int = iconP2.animation.curAnim.curFrame;
		if (hpPercent < 20) {
			if (p1frame != 1) iconP1.animation.curAnim.curFrame = 1;
			if (p2frame != 2) iconP2.animation.curAnim.curFrame = 2;
		} else if (hpPercent > 80) {
			if (p1frame != 2) iconP1.animation.curAnim.curFrame = 2;
			if (p2frame != 1) iconP2.animation.curAnim.curFrame = 1;
		} else {
			if (p1frame != 0) iconP1.animation.curAnim.curFrame = 0;
			if (p2frame != 0) iconP2.animation.curAnim.curFrame = 0;
		}

		if (FlxG.keys.anyJustPressed(debugKeysCharacter) && !endingSong && !inCutscene) {
			persistentUpdate = false;
			paused = true;
			cancelMusicFadeTween();
			MusicBeatState.switchState(new CharacterEditorState(SONG.player2));
		}

		if (startedCountdown)
		{
			Conductor.songPosition += FlxG.elapsed * 1000 * playbackRate;
		}

		updateIconsScale(elapsed);
		// Smoothly interpolate displayed health towards actual health for a smooth bar transition
		var smoothSpeed:Float = 8; // tweakable smoothing speed
		displayHealth += (health - displayHealth) * Math.min(1, elapsed * smoothSpeed);
		healthBar.updateBar();
		// Update icon positions smoothly
		updateIconsPosition(elapsed);

		if (startingSong)
		{
			if (startedCountdown && Conductor.songPosition >= 0)
				startSong();
			else if(!startedCountdown)
				Conductor.songPosition = -Conductor.crochet * 5;
		}
		else
		{
			if (!paused)
			{
				songTime += FlxG.game.ticks - previousFrameTime;
				previousFrameTime = FlxG.game.ticks;

				// Interpolation type beat
				if (Conductor.lastSongPos != Conductor.songPosition)
				{
					songTime = (songTime + Conductor.songPosition) / 2;
					Conductor.lastSongPos = Conductor.songPosition;
					// Conductor.songPosition += FlxG.elapsed * 1000;
					// trace('MISSED FRAME');
				}

				if(updateTime) {
					var curTime:Float = Conductor.songPosition - ClientPrefs.data.noteOffset;
					if(curTime < 0) curTime = 0;
					songPercent = (curTime / songLength);

					var songCalc:Float = (ClientPrefs.data.timeBarType == 'Time Elapsed') ? curTime : (songLength - curTime);
					var secondsTotal:Int = Math.floor(songCalc / 1000);
					if(secondsTotal < 0) secondsTotal = 0;

					if(ClientPrefs.data.timeBarType != 'Song Name')
						timeTxt.text = FlxStringUtil.formatTime(secondsTotal, false);
				}
			}

			// Conductor.lastSongPos = FlxG.sound.music.time;
		}

		if (camZooming)
		{
			FlxG.camera.zoom = FlxMath.lerp(defaultCamZoom, FlxG.camera.zoom, CoolUtil.boundTo(1 - (elapsed * 3.125 * camZoomingDecay * playbackRate), 0, 1));
			camHUD.zoom = FlxMath.lerp(1, camHUD.zoom, CoolUtil.boundTo(1 - (elapsed * 3.125 * camZoomingDecay * playbackRate), 0, 1));
		}

		FlxG.watch.addQuick("secShit", curSection);
		FlxG.watch.addQuick("beatShit", curBeat);
		FlxG.watch.addQuick("stepShit", curStep);

		// RESET = Quick Game Over Screen
		if (!ClientPrefs.data.noReset && controls.RESET && canReset && !inCutscene && startedCountdown && !endingSong)
		{
			health = 0;
			TraceManager.debug('trace.playState.resetTrue', 'RESET = True');
		}
		doDeathCheck();

		// Music ended but chart notes remain: keep the virtual playhead running
		// so unspawned notes still appear and can be played, then end the song.
		if (musicEnded && !endingSong)
		{
			postMusicTime += elapsed * 1000 * playbackRate;
			Conductor.songPosition = FlxG.sound.music.length + postMusicTime;
			if (notesAddedCount >= unspawnNotes.length && Conductor.songPosition > lastChartNoteTime + Conductor.safeZoneOffset)
			{
				musicEnded = false;
				finishSong();
			}
		}

		if (notesAddedCount < unspawnNotes.length)
		{
			var time:Float = spawnTime;
			if(songSpeed < 1) time /= songSpeed;
			if(unspawnNotes[notesAddedCount].multSpeed < 1) time /= unspawnNotes[notesAddedCount].multSpeed;

			fastSkipPastNotes(elapsed);
			var targetData:PreloadedChartNote = (notesAddedCount < unspawnNotes.length) ? unspawnNotes[notesAddedCount] : null;
			// 精确存活数: perfMode 关闭时与提交前一致，用 FlxTypedGroup 的 countLiving()，
			// 避免脚本额外加入 notes 的音符不被计数；perfMode 开启时读紧凑列表 (O(1))。
			limitNC = ClientPrefs.data.perfMode ? activeNotes.length : notes.countLiving();

			// 自适应物化预算: 帧时间越长允许生成越多 (掉帧后自动追赶积压, 恢复流畅);
			// 同时判定线前的音符 (hardDeadline 内) 无视预算强制生成 —— 保证可玩性优先于削峰。
			var hardDeadline:Float = Conductor.songPosition + Conductor.safeZoneOffset;
			var spawnBudget:Int = Std.int(Math.max(2048, Math.min(20000, elapsed * 1000 * 30)));
			// 过载判定用"本帧数据级 drain 量": drain 显著非零说明到达速率超过了物化能力,
			// 此刻到点音符由数据级路径结算, 物化只保留小额度维持近线可视, 且判定线硬时限
			// 不再强制追加 —— 落后状态下强物化等于为注定被数据层结算的音符白付构造费。
			// 滞回: 本帧 drain 显著非零 → 置满 30 帧; 否则逐帧衰减。
			// 光标被长条头临时钉住等场景下 drain 会短暂归零, 滞回避免节流模式反复开关。
			if (_bulkDrainedLast >= 128) _overloadFrames = 30;
			else if (_overloadFrames > 0) _overloadFrames--;
			var perfOn:Bool = ClientPrefs.data.perfMode;
			// 关键修复: 物化节流只允许存在于 botplay。手动模式没有数据层吸收路径
			// (fastSkipPastNotes 的 softCut 恒为 -∞), 节流的唯一效果是让生成光标
			// 落后于可视地平线 —— 落后的毫秒数 × 流速 = 音符在屏内"凭空出现"的像素
			// 深度 (流速越大越深入屏幕), 长条头已生成而尾段未跟上则表现为"吞长条"。
			// 手动模式恢复原版无限物化吞吐, 仅保留 noteLimit 上限与可视地平线准入。
			var behind:Bool = perfOn && cpuControlled && _overloadFrames > 0;
			var manualUnthrottled:Bool = !cpuControlled;
			if (behind)
				spawnBudget = 1024;
			// 可视物化地平线: 超出剔除距离的音符只会被驻留或数据层结算, 构造它们是纯浪费。
			// (spawnTime=2000ms 的旧窗口在 speed=10 时是可视视距的 ~10 倍。)
			// perfMode 关闭: 回到原版完整 spawnTime 窗口, 不做地平线收缩。
			var effTime:Float = perfOn ? Math.min(time, _visHorizonMs) : time;
			var spawnedThisFrame:Int = 0;

			_phaseT = haxe.Timer.stamp();
			// Turbo: 每帧重置运行时归属闸门 (见 turboKeepNote)。
			if (turboModeActive)
				resetTurboKeepGate();
			// perfMode 关闭: 无预算节流、无硬时限追加 —— 与原版逐条无条件物化一致。
			// 手动模式 (manualUnthrottled): 同样不节流, 保证屏外滑入的正确性优先。
			while (targetData != null && targetData.strumTime - Conductor.songPosition < effTime
				&& limitNC < noteLimit
				&& (!perfOn || manualUnthrottled || spawnedThisFrame < spawnBudget
					|| (!behind && targetData.strumTime <= hardDeadline && spawnedThisFrame < spawnBudget + 4096)))
			{
				if (targetData.wasHit)
				{
					notesAddedCount++;
					if (notesAddedCount < unspawnNotes.length)
						targetData = unspawnNotes[notesAddedCount];
					else
						break;
					continue;
				}

				if (turboModeActive && !turboKeepNote(targetData) && bulkSettleNote(targetData, _bulkAcc))
				{
					notesAddedCount++;
					if (notesAddedCount < unspawnNotes.length)
						targetData = unspawnNotes[notesAddedCount];
					else
						break;
					continue;
				}

				var newNote:Note;
				var reusedNote:Bool = notePool.length > 0;
				if (reusedNote)
				{
					newNote = notePool.pop();
					newNote.pooled = false;
					newNote.revive();
				}
				else
				{
					newNote = new Note(targetData.strumTime, targetData.noteData, null, targetData.isSustainNote, false, true);
				}
				newNote.sourceIndex = notesAddedCount;
				newNote.setupNoteData(targetData);
				newNote.spawned = true;
				// 进入存活紧凑列表 (limitNC 读取精确存活数的关键)
				newNote.activeIdx = activeNotes.length;
				activeNotes.push(newNote);

				// 重建 prevNote/nextNote 链（只链已生成的 Note；未生成的 sustain 尾段由数据扫描兜底）。
				var linkKey:Int = newNote.noteData + (newNote.mustPress ? 10000 : 0);
				var prev:Note = lastSpawnedNote.get(linkKey);
				if (prev != null) {
					newNote.prevNote = prev;
					prev.nextNote = newNote;
				}
				lastSpawnedNote.set(linkKey, newNote);

				if (!reusedNote)
					appendNoteFast(newNote);
				if (hasActiveScripts()) {
					if (CompatEngine.isModern()) {
						callOnScripts('onSpawnNote', [
							noteIndexFast(newNote),
							newNote.noteData,
							newNote.noteType,
							newNote.isSustainNote,
							newNote.strumTime
						]);
					} else {
						callOnScripts('onSpawnNote', [
							noteIndexFast(newNote),
							newNote.noteData,
							newNote.noteType,
							newNote.isSustainNote
						]);
					}
				}

				notesAddedCount++;
				limitNC++;
				spawnedThisFrame++;
				if (notesAddedCount < unspawnNotes.length)
					targetData = unspawnNotes[notesAddedCount];
				else
					break;
			}
		}

		if (generatedMusic && !inCutscene)
		{
			// 回放模式: 由 replayExam.replayUpdate() 处理按键; 非回放模式: 由 keysCheck() 处理
			if (replayMode) {
				if (replayExam != null) replayExam.replayUpdate(elapsed);
			} else if(!cpuControlled) {
				keysCheck();
			} else if(!boyfriend.isAnimationNull() && boyfriend.holdTimer > Conductor.stepCrochet * (0.0011 / FlxG.sound.music.pitch) * boyfriend.singDuration && boyfriend.getAnimationName().startsWith('sing') && !boyfriend.getAnimationName().endsWith('miss')) {
				boyfriend.dance();
			}

			if(startedCountdown)
			{
				// perfMode 关闭时不做离屏剔除，也不使用每帧 trig 缓存，
				// 这两项都属于 H-Slice 优化，关闭时应保持提交前逐音符实时计算。
				if (ClientPrefs.data.perfMode)
				{
					refreshNoteCullRanges(elapsed);
					refreshLaneTrigCaches();
				}
				_frameAliveTally = 0;

				// 复用 strumsHit 数组，避免每帧分配新数组（密集谱面下是主要的每帧垃圾来源之一）
				var laneCount:Int = Note.ammo[mania] * 2;
				if (strumsHit.length != laneCount)
					strumsHit = [for (i in 0...laneCount) false];
				else
					for (i in 0...laneCount)
						strumsHit[i] = false;
				// botplay/对手侧的"每轨每帧一次"门控同步重置
				resetBotGateArrays();

				_phaseT = haxe.Timer.stamp();
				bulkHitDueMaterialized(); // botplay 到点已物化音符的批量命中 (合并逐击调用链)
				if (ClientPrefs.data.perfMode)
				{
					// 遍历存活紧凑列表 (O(存活数), 不再扫全量 members 槽位)。
					// 正向遍历 + swap-remove 补偿: updateDaNote 可能回收当前元素,
					// 尾元素补位到当前下标, 此时 i 不前进即可补上新换入的元素。
					var ai:Int = 0;
					while (ai < activeNotes.length)
					{
						var an:Note = activeNotes[ai];
						var lenBefore:Int = activeNotes.length;
						updateDaNote(an);
						if (activeNotes.length == lenBefore && ai < activeNotes.length && activeNotes[ai] == an)
							ai++;
					}
				}
				else
				{
					// 关闭性能模式时保持提交前行为: 遍历 notes 全组 alive 成员，
					// 脚本额外加入/移动的 Note 也会被正常更新。
					notes.forEachAlive(updateDaNote);
				}
				_lastAliveTally = _frameAliveTally;

				// 回池复用后不再批量 remove/destroy；dead Note 保留在 members 中供槽位复用。
				// 只清理被脚本/外部直接 destroy 的壳（scale == null），避免异常路径堆积。
				_noteCleanupFrameCounter++;
				if (_noteCleanupFrameCounter >= NOTE_CLEANUP_INTERVAL)
				{
					_noteCleanupFrameCounter = 0;
					// 单趟压缩清除被脚本 destroy 的空壳 (scale == null),
					// 替代逐个 notes.remove(.., true) 的 O(n) splice。
					var m:Array<Note> = notes.members;
					var total:Int = m.length;
					var wI:Int = 0;
					for (rI in 0...total)
					{
						var cleanNote:Note = m[rI];
						if (cleanNote != null && cleanNote.scale == null)
							continue;
						m[wI] = cleanNote;
						if (cleanNote != null) cleanNote.memberIndex = wI; // 同步下标缓存
						wI++;
					}
					@:privateAccess notes.length = wI;
					// 关键修复: 必须直接截断数组, 保持与旧版 notes.remove(splice) 相同的
					// "members 无 null 槽位" 不变量 —— FlxTypedGroup.sort 是不加过滤的
					// members.sort(), fastSort 关闭时每帧 notes.sort(FlxSort.byY) 会把
					// null 槽位送入比较器解引用 Obj1.y → 按下长条(留壳)后数帧内直接崩溃。
					if (wI < total)
						m.resize(wI);
					if (_noteSlotCursor > wI) _noteSlotCursor = wI;

					// 同步压缩存活列表 (脚本 destroy 的壳可能残留在活跃列表)
					var wA:Int = 0;
					for (aI in 0...activeNotes.length)
					{
						var an:Note = activeNotes[aI];
						if (an == null || !an.exists || an.scale == null)
							continue;
						an.activeIdx = wA;
						activeNotes[wA] = an;
						wA++;
					}
					activeNotes.resize(wA);
				}

				// Periodically release unused graphics to bound memory on long runs / mod-heavy sets.
				_memoryPurgeFrameCounter++;
				if (_memoryPurgeFrameCounter >= MEMORY_PURGE_INTERVAL)
				{
					_memoryPurgeFrameCounter = 0;
					Paths.purgeUnusedGraphics();
				}

				// Periodic scan to release CPU copies of large graphics meeting memory policy requirements
				GfxPolicy.onPlayUpdate(elapsed);

				// Sort for correct draw order (closer to strum on top).
				// fasterNoteSort 对长条同样安全: 只重排存活且可见的 Note, 死槽位保持原位,
				// 绘制顺序与全表 sort 完全一致; 密集长条谱面不再退回 O(n log n) 全排序。
				var sortOrder:Int = ClientPrefs.data.downScroll ? FlxSort.ASCENDING : FlxSort.DESCENDING;
				_phaseT = haxe.Timer.stamp();
				if (ClientPrefs.data.fastSort)
					fasterNoteSort(sortOrder);
				else
				{
					notes.sort(noteDrawOrder, sortOrder);
					rebuildMemberIndexes(notes.members, notes.members.length); // 全表重排后单趟重建下标缓存
				}
			}
			else
			{
				_frameAliveTally = 0;
				if (ClientPrefs.data.perfMode)
				{
					for (rn in activeNotes)
						resetNote(rn);
				}
				else
				{
					notes.forEachAlive(resetNote);
				}
				_lastAliveTally = _frameAliveTally;
				// 倒计时前同样不 remove/destroy，dead Note 留在 members 中复用。
			}
		}
		checkEventNote();

		#if debug
		if(!endingSong && !startingSong) {
			if (FlxG.keys.justPressed.ONE) {
				KillNotes();
				FlxG.sound.music.onComplete();
			}
			if(FlxG.keys.justPressed.TWO) { //Go 10 seconds into the future :O
				setSongTime(Conductor.songPosition + 10000);
				clearNotesBefore(Conductor.songPosition);
			}
		}
		#end

		// 表现层帧末统一刷新 (分数文本/ms 文本/合并弹窗), 随后写 watch 计数面板。
		// 放在 onUpdatePost 之前: 脚本在本帧回调里读到的分数/文本已是最终值。
		_phaseT = haxe.Timer.stamp();
		flushHitPresentation();

		setOnScripts('cameraX', camFollowPos.x);
		setOnScripts('cameraY', camFollowPos.y);
		setOnScripts('botPlay', cpuControlled);
		callOnScripts('onUpdatePost', [elapsed]);
		#if seiun_lua_perf
		LuaPerf.noteFrame(LuaPerf.now() - _perfFrameT0, LuaPerf.now() - _perfLuaT0);
		#end
	}
	// Health icon updaters(like 073?)
	public dynamic function updateIconsScale(elapsed:Float){
		var mult:Float = FlxMath.lerp(1, iconP1.scale.x, CoolUtil.boundTo(1 - (elapsed * 9 * playbackRate), 0, 1));
		iconP1.scale.set(mult, mult);
		iconP1.updateHitbox();

		var mult:Float = FlxMath.lerp(1, iconP2.scale.x, CoolUtil.boundTo(1 - (elapsed * 9 * playbackRate), 0, 1));
		iconP2.scale.set(mult, mult);
		iconP2.updateHitbox();
	}


	function openPauseMenu(?sendNetworkPause:Bool = true)
	{
		persistentUpdate = false;
		persistentDraw = true;
		paused = true;
		#if ONLINE_ALLOWED
		if (sendNetworkPause)
		{
			// 自己主动暂停: 清除"对方暂停"标记 (远程暂停走 openPauseMenu(false) 并单独设置)。
			OnlineSession.pauseNickname = "";
			// 暂停策略: 只有允许本地暂停时才广播 (仅房主/禁止暂停时, 非房主不发暂停消息)。
			// 观战者: 暂停纯属本地画面, 绝不广播 (会把整场对局挂起)。
			if (onlineCanPauseLocally() && seiunOnline && !seiunSpectate && OnlineSession.active && OnlineSession.mode == online.shared.OnlineTypes.OnlineConst.MODE_REALTIME && GameClient.instance != null)
				GameClient.instance.send(SeiunProtocol.MSG_GAME_PAUSE, SeiunProtocol.CHANNEL_GAME, {at: Date.now().getTime()});
		}
		#end


		keyboardDisplay.save();
		for (i in 0...4)
			keyboardDisplay.released(i);


		// 1 / 1000 chance for Gitaroo Man easter egg
		/*if (FlxG.random.bool(0.1))
		{
			// gitaroo man easter egg
			cancelMusicFadeTween();
			MusicBeatState.switchState(new GitarooPause());
		}
		else {*/
		if(FlxG.sound.music != null) {
			FlxG.sound.music.pause();
			vocals.pause();
			vocalsPlayer.pause();
			opponentVocals.pause();
		}
		#if HSCRIPT_ALLOWED
		// 联机模式强制使用新版暂停菜单: 旧版没有联机暂停/恢复/退出房间的处理逻辑。
		var usePause:Bool = seiunOnline ? false : ((Main.useOldPause != null) ? Main.useOldPause : ClientPrefs.data.oldPauseMenu);
		if (usePause)
			openSubState(new OldPauseSubState(boyfriend.getScreenPosition().x, boyfriend.getScreenPosition().y));
		else
			openSubState(new PauseSubState(boyfriend.getScreenPosition().x, boyfriend.getScreenPosition().y));
		#else
		openSubState(new PauseSubState(boyfriend.getScreenPosition().x, boyfriend.getScreenPosition().y));
		#end
		//}

		#if desktop
		if(iconP2 != null) DiscordClient.changePresence(detailsPausedText, SONG.song + " (" + storyDifficultyText + ")", iconP2.getCharacter());
		#end
	}

	public function openChartEditor()
	{
		persistentUpdate = false;
		paused = true;
		cancelMusicFadeTween();
        if(ClientPrefs.data.newchartingstate)
            MusicBeatState.switchState(new editors.NewChartingState());
                        else
            MusicBeatState.switchState(new editors.ChartingState());
		chartingMode = true;

		#if desktop
		DiscordClient.changePresence("Chart Editor", null, null, true);
		#end
	}

	public var isDead:Bool = false; //Don't mess with this on Lua!!!
	function doDeathCheck(?skipHealthCheck:Bool = false) {
		#if ONLINE_ALLOWED
		if (seiunOnline && OnlineSession.active
			&& OnlineSession.mode == online.shared.OnlineTypes.OnlineConst.MODE_REALTIME)
			return false;
		#end
		if (((skipHealthCheck && instakillOnMiss) || (playOpponent ? health >= 2 : health <= 0)) && !practiceMode && !isDead && !replayMode && !cpuControlled)
		{
			var ret:Dynamic = callOnScripts('onGameOver', [], false);
			if(ret != FunkinLua.Function_Stop) {
				boyfriend.stunned = true;
				deathCounter++;

				paused = true;

				vocals.stop();
				vocalsPlayer.stop();
				opponentVocals.stop();
				FlxG.sound.music.stop();

				persistentUpdate = false;
				persistentDraw = false;
				for (tween in modchartTweens) {
					tween.active = true;
				}
				for (timer in modchartTimers) {
					timer.active = true;
				}
				openSubState(new GameOverSubstate(boyfriend.getScreenPosition().x - boyfriend.positionArray[0], boyfriend.getScreenPosition().y - boyfriend.positionArray[1], camFollowPos.x, camFollowPos.y));

				// MusicBeatState.switchState(new GameOverState(boyfriend.getScreenPosition().x, boyfriend.getScreenPosition().y));

				#if desktop
				// Game Over doesn't get his own variable because it's only used here
				if(iconP2 != null) DiscordClient.changePresence("Game Over - " + detailsText, SONG.song + " (" + storyDifficultyText + ")", iconP2.getCharacter());
				#end
				isDead = true;
				return true;
			}
		}
		return false;
	}

	public function checkEventNote() {
		var safety:Int = 0;
		while(eventNotes.length > 0 && safety < 512) {
			safety++;
			var leStrumTime:Float = eventNotes[0].strumTime;
			if(Conductor.songPosition < leStrumTime) {
				break;
			}

			var value1:String = '';
			try {
				if(eventNotes[0].value1 != null)
					value1 = eventNotes[0].value1;

				var value2:String = '';
				if(eventNotes[0].value2 != null)
					value2 = eventNotes[0].value2;

				triggerEventNote(eventNotes[0].event, value1, value2, leStrumTime);
			}
			catch (e:Dynamic)
			{
				// 单个事件执行失败不阻塞后续事件 (防卡顿/异常吞事件)
				FlxG.log.error('Event failed: ${eventNotes[0].event} - $e');
			}
			eventNotes.shift();
		}
	}

	public function getControl(key:String) {
		var pressed:Bool = Reflect.getProperty(controls, key);
		//trace('Control result: ' + pressed);
		return pressed;
	}

	public function triggerEventNote(eventName:String, value1:String, value2:String, ?strumTime:Float = 0) {
		switch(eventName) {
			case 'Dadbattle Spotlight':
				var val:Null<Int> = Std.parseInt(value1);
				if(val == null) val = 0;

				switch(Std.parseInt(value1))
				{
					case 1, 2, 3: //enable and target dad
						if(val == 1) //enable
						{
							dadbattleBlack.visible = true;
							dadbattleLight.visible = true;
							dadbattleSmokes.visible = true;
							defaultCamZoom += 0.12;
						}

						var who:Character = dad;
						if(val > 2) who = boyfriend;
						//2 only targets dad
						dadbattleLight.alpha = 0;
						new FlxTimer().start(0.12, function(tmr:FlxTimer) {
							dadbattleLight.alpha = 0.375;
						});
						dadbattleLight.setPosition(who.getGraphicMidpoint().x - dadbattleLight.width / 2, who.y + who.height - dadbattleLight.height + 50);

					default:
						dadbattleBlack.visible = false;
						dadbattleLight.visible = false;
						defaultCamZoom -= 0.12;
						FlxTween.tween(dadbattleSmokes, {alpha: 0}, 1, {onComplete: function(twn:FlxTween)
						{
							dadbattleSmokes.visible = false;
						}});
				}

			case 'Hey!':
				var value:Int = 2;
				switch(value1.toLowerCase().trim()) {
					case 'bf' | 'boyfriend' | '0':
						value = 0;
					case 'gf' | 'girlfriend' | '1':
						value = 1;
				}

				var time:Float = Std.parseFloat(value2);
				if(Math.isNaN(time) || time <= 0) time = 0.6;

				if(value != 0) {
					if(dad.curCharacter.startsWith('gf')) { //Tutorial GF is actually Dad! The GF is an imposter!! ding ding ding ding ding ding ding, dindinding, end my suffering
						dad.playAnim('cheer', true);
						dad.specialAnim = true;
						dad.heyTimer = time;
					} else if (gf != null) {
						gf.playAnim('cheer', true);
						gf.specialAnim = true;
						gf.heyTimer = time;
					}

					if(curStage == 'mall') {
						bottomBoppers.animation.play('hey', true);
						heyTimer = time;
					}
				}
				if(value != 1) {
					boyfriend.playAnim('hey', true);
					boyfriend.specialAnim = true;
					boyfriend.heyTimer = time;
				}

			case 'Set GF Speed':
				var value:Int = Std.parseInt(value1);
				if(Math.isNaN(value) || value < 1) value = 1;
				gfSpeed = value;

			case 'Philly Glow':
				if (stageBackdrop != null) stageBackdrop.eventTrigger(eventName, value1, value2);

			case 'Kill Henchmen':
				if (stageBackdrop != null) stageBackdrop.eventTrigger(eventName, value1, value2);

			case 'Add Camera Zoom':
				if(ClientPrefs.data.camZooms && FlxG.camera.zoom < 1.35) {
					var camZoom:Float = Std.parseFloat(value1);
					var hudZoom:Float = Std.parseFloat(value2);
					if(Math.isNaN(camZoom)) camZoom = 0.015;
					if(Math.isNaN(hudZoom)) hudZoom = 0.03;

					FlxG.camera.zoom += camZoom;
					camHUD.zoom += hudZoom;
				}

			case 'Trigger BG Ghouls':
				if(curStage == 'schoolEvil' && !ClientPrefs.data.lowQuality) {
					bgGhouls.dance(true);
					bgGhouls.visible = true;
				}

			case 'Play Animation':
				//trace('Anim to play: ' + value1);
				var char:Character = dad;
				switch(value2.toLowerCase().trim()) {
					case 'bf' | 'boyfriend':
						char = boyfriend;
					case 'gf' | 'girlfriend':
						char = gf;
					default:
						var val2:Int = Std.parseInt(value2);
						if(Math.isNaN(val2)) val2 = 0;

						switch(val2) {
							case 1: char = boyfriend;
							case 2: char = gf;
						}
				}

				if (char != null)
				{
					char.playAnim(value1, true);
					char.specialAnim = true;
				}

			case 'Camera Follow Pos':
				if(camFollow != null)
				{
					var val1:Float = Std.parseFloat(value1);
					var val2:Float = Std.parseFloat(value2);
					if(Math.isNaN(val1)) val1 = 0;
					if(Math.isNaN(val2)) val2 = 0;

					isCameraOnForcedPos = false;
					if(!Math.isNaN(Std.parseFloat(value1)) || !Math.isNaN(Std.parseFloat(value2))) {
						camFollow.x = val1;
						camFollow.y = val2;
						isCameraOnForcedPos = true;
					}
				}

			case 'Change Mania':
				var newMania:Int = Std.parseInt(value1);
				if (Math.isNaN(newMania)) newMania = Note.defaultMania + 1; // 缺省 4K (1 基)
				// 事件 Value 2: 'true'/'skip' 跳过过渡动画; 其他值作为动画样式名
				// (内置: fade/slide/zoom/spin, 脚本也可自定义样式)
				var skipTween:Bool = (value2 != null && (value2 == 'true' || value2 == 'skip'));
				var animStyle:String = null;
				if (!skipTween && value2 != null && value2.length > 0)
					animStyle = value2;
				// 事件 Value 1 使用 1 基键数 (9 = 9K), 内部 mania 为 0 基
				changeMania(newMania - 1, skipTween, animStyle);

			case 'Alt Idle Animation':
				var char:Character = dad;
				switch(value1.toLowerCase().trim()) {
					case 'gf' | 'girlfriend':
						char = gf;
					case 'boyfriend' | 'bf':
						char = boyfriend;
					default:
						var val:Int = Std.parseInt(value1);
						if(Math.isNaN(val)) val = 0;

						switch(val) {
							case 1: char = boyfriend;
							case 2: char = gf;
						}
				}

				if (char != null)
				{
					char.idleSuffix = value2;
					char.recalculateDanceIdle();
				}

			case 'Screen Shake':
				var valuesArray:Array<String> = [value1, value2];
				var targetsArray:Array<FlxCamera> = [camGame, camHUD];
				for (i in 0...targetsArray.length) {
					var split:Array<String> = valuesArray[i].split(',');
					var duration:Float = 0;
					var intensity:Float = 0;
					if(split[0] != null) duration = Std.parseFloat(split[0].trim());
					if(split[1] != null) intensity = Std.parseFloat(split[1].trim());
					if(Math.isNaN(duration)) duration = 0;
					if(Math.isNaN(intensity)) intensity = 0;

					if(duration > 0 && intensity != 0) {
						targetsArray[i].shake(intensity, duration);
					}
				}


			case 'Change Character':
				var charType:Int = 0;
				switch(value1.toLowerCase().trim()) {
					case 'gf' | 'girlfriend':
						charType = 2;
					case 'dad' | 'opponent':
						charType = 1;
					default:
						charType = Std.parseInt(value1);
						if(Math.isNaN(charType)) charType = 0;
				}

				switch(charType) {
					case 0:
						if(boyfriend.curCharacter != value2) {
							if(!boyfriendMap.exists(value2)) {
								addCharacterToList(value2, charType);
							}

							var lastAlpha:Float = boyfriend.alpha;
							boyfriend.alpha = 0.00001;
							boyfriend = boyfriendMap.get(value2);
							boyfriend.alpha = lastAlpha;
							iconP1.changeIcon(boyfriend.healthIcon);
							// 073/104 的 Bar 是 FlxSpriteGroup，部分自定义图标切图后会被
							// 血条背景盖住；把图标重新放到 healthBar 之后，确保始终在血条上层。
							forceHealthIconsAboveBar();
						}
						setOnScripts('boyfriendName', boyfriend.curCharacter);

					case 1:
						if(dad.curCharacter != value2) {
							if(!dadMap.exists(value2)) {
								addCharacterToList(value2, charType);
							}

							var wasGf:Bool = dad.curCharacter.startsWith('gf');
							var lastAlpha:Float = dad.alpha;
							dad.alpha = 0.00001;
							dad = dadMap.get(value2);
							if(!dad.curCharacter.startsWith('gf')) {
								if(wasGf && gf != null) {
									gf.visible = true;
								}
							} else if(gf != null) {
								gf.visible = false;
							}
							dad.alpha = lastAlpha;
							iconP2.changeIcon(dad.healthIcon);
							forceHealthIconsAboveBar();
						}
						setOnScripts('dadName', dad.curCharacter);

					case 2:
						if(gf != null)
						{
							if(gf.curCharacter != value2)
							{
								if(!gfMap.exists(value2))
								{
									addCharacterToList(value2, charType);
								}

								var lastAlpha:Float = gf.alpha;
								gf.alpha = 0.00001;
								gf = gfMap.get(value2);
								gf.alpha = lastAlpha;
							}
							setOnScripts('gfName', gf.curCharacter);
						}
				}
				reloadHealthBarColors();

			case 'BG Freaks Expression':
				if(bgGirls != null) bgGirls.swapDanceType();

			case 'Change Scroll Speed':
				if (songSpeedType == "constant")
					return;
				var val1:Float = Std.parseFloat(value1);
				var val2:Float = Std.parseFloat(value2);
				if(Math.isNaN(val1)) val1 = 1;
				if(Math.isNaN(val2)) val2 = 0;

				var newValue:Float = SONG.speed * ClientPrefs.getGameplaySetting('scrollspeed', 1) * val1;

				if(val2 <= 0)
				{
					songSpeed = newValue;
				}
				else
				{
					songSpeedTween = FlxTween.tween(this, {songSpeed: newValue}, val2 / playbackRate, {ease: FlxEase.linear, onComplete:
						function (twn:FlxTween)
						{
							songSpeedTween = null;
						}
					});
				}

			case 'Set Property':
				var killMe:Array<String> = value1.split('.');
				if(killMe.length > 1) {
					FunkinLua.setVarInArray(FunkinLua.getPropertyLoopThingWhatever(killMe, true, true), killMe[killMe.length-1], value2);
				} else {
					FunkinLua.setVarInArray(this, value1, value2);
				}
			case 'Play Sound':
				var val2:Float = Std.parseFloat(value2);
				if(Math.isNaN(val2)) val2 = 1;
				FlxG.sound.play(Paths.sound(value1), val2);

		}
		if (CompatEngine.isModern()) {
			callOnScripts('onEvent', [eventName, value1, value2, strumTime]);
		} else {
			callOnScripts('onEvent', [eventName, value1, value2]);
		}
	}

	function moveCameraSection():Void {
		if(SONG.notes[curSection] == null) return;

		if (gf != null && SONG.notes[curSection].gfSection)
		{
			camFollow.set(gf.getMidpoint().x, gf.getMidpoint().y);
			camFollow.x += gf.cameraPosition[0] + girlfriendCameraOffset[0];
			camFollow.y += gf.cameraPosition[1] + girlfriendCameraOffset[1];
			tweenCamIn();
			callOnScripts('onMoveCamera', ['gf']);
			return;
		}

		if (!SONG.notes[curSection].mustHitSection)
		{
			moveCamera(true);
			callOnScripts('onMoveCamera', ['dad']);
		}
		else
		{
			moveCamera(false);
			callOnScripts('onMoveCamera', ['boyfriend']);
		}
	}

	var cameraTwn:FlxTween;
	public function moveCamera(isDad:Bool)
	{
		if(isDad)
		{
			camFollow.set(dad.getMidpoint().x + 150, dad.getMidpoint().y - 100);
			camFollow.x += dad.cameraPosition[0] + opponentCameraOffset[0];
			camFollow.y += dad.cameraPosition[1] + opponentCameraOffset[1];
			tweenCamIn();
		}
		else
		{
			camFollow.set(boyfriend.getMidpoint().x - 100, boyfriend.getMidpoint().y - 100);
			camFollow.x -= boyfriend.cameraPosition[0] - boyfriendCameraOffset[0];
			camFollow.y += boyfriend.cameraPosition[1] + boyfriendCameraOffset[1];

			if (Paths.formatToSongPath(SONG.song) == 'tutorial' && cameraTwn == null && FlxG.camera.zoom != 1)
			{
				cameraTwn = FlxTween.tween(FlxG.camera, {zoom: 1}, (Conductor.stepCrochet * 4 / 1000), {ease: FlxEase.elasticInOut, onComplete:
					function (twn:FlxTween)
					{
						cameraTwn = null;
					}
				});
			}
		}
	}

	function tweenCamIn() {
		if (Paths.formatToSongPath(SONG.song) == 'tutorial' && cameraTwn == null && FlxG.camera.zoom != 1.3) {
			cameraTwn = FlxTween.tween(FlxG.camera, {zoom: 1.3}, (Conductor.stepCrochet * 4 / 1000), {ease: FlxEase.elasticInOut, onComplete:
				function (twn:FlxTween) {
					cameraTwn = null;
				}
			});
		}
	}

	function snapCamFollowToPos(x:Float, y:Float) {
		camFollow.set(x, y);
		camFollowPos.setPosition(x, y);
	}

	/**
	 * Called when the music file reaches its end. If chart notes are still
	 * waiting to spawn (imported charts may be longer than their audio), keep
	 * the virtual playhead running so those notes get played out before the
	 * song ends.
	 */
	function onMusicComplete():Void
	{
		if (notesAddedCount >= unspawnNotes.length)
			finishSong();
		else
			musicEnded = true;
	}

	public function finishSong(?ignoreNoteOffset:Bool = false):Void
	{
		var finishCallback:Void->Void = endSong; //In case you want to change it in a specific song.

		updateTime = false;
		FlxG.sound.music.volume = 0;
		vocals.volume = 0;
		vocalsPlayer.volume = 0;
		opponentVocals.volume = 0;
		vocals.pause();
		vocalsPlayer.pause();
		opponentVocals.pause();
		if(ClientPrefs.data.noteOffset <= 0 || ignoreNoteOffset) {
			finishCallback();
		} else {
			finishTimer = new FlxTimer().start(ClientPrefs.data.noteOffset / 1000, function(tmr:FlxTimer) {
				finishCallback();
			});
		}
	}


	public var transitioning = false;
	public function endSong():Void
	{
		//Should kill you if you tried to cheat
		if(!startingSong) {
			function drainHealth(daNote:Note):Void {
				if(daNote.strumTime < songLength - Conductor.safeZoneOffset) {
					if (playOpponent)
						health += 0.05 * healthLoss;
					else
						health -= 0.05 * healthLoss;
				}
			}
			notes.forEachAlive(drainHealth);

			// Only drain truly unspawned notes (past notesAddedCount cursor)
			var i:Int = notesAddedCount;
			while (i < unspawnNotes.length) {
				var dn = unspawnNotes[i];
				if(dn.strumTime < songLength - Conductor.safeZoneOffset) {
					if (playOpponent)
						health += 0.05 * healthLoss;
					else
						health -= 0.05 * healthLoss;
				}
				i++;
			}

			if(doDeathCheck()) {
				return;
			}
		}
		keyboardDisplay.save();
		// Song end: perform final graphic release scan and flush memory ledger to log
		GfxPolicy.onSongEnd();
		if (androidControls != null) androidControls.visible = true;
		timeBarBG.visible = false;
		timeBar.visible = false;
		timeTxt.visible = false;

		canPause = false;
		endingSong = true;
		camZooming = false;
		inCutscene = false;
		updateTime = false;

		deathCounter = 0;
		seenCutscene = false;

		#if ACHIEVEMENTS_ALLOWED
		if(achievementObj != null) {
			return;
		} else {
			var achieve:String = checkForAchievement(['week1_nomiss', 'week2_nomiss', 'week3_nomiss', 'week4_nomiss',
				'week5_nomiss', 'week6_nomiss', 'week7_nomiss', 'ur_bad',
				'ur_good', 'line_blue','hype', 'two_keys', 'toastie', 'debugger']);

			if(achieve != null) {
				startAchievement(achieve);
				return;
			}
		}
		#end

		var ret:Dynamic = callOnScripts('onEndSong', [], false);
		trace(SONG.validScore);
		if(ret != FunkinLua.Function_Stop && !transitioning) {
			if (SONG.validScore || SONG.validScore == null)
			{
				#if !switch
				var percent:Float = ratingPercent;
				if(Math.isNaN(percent)) percent = 0;
				if (!replayMode && !practiceMode && !cpuControlled && !chartingMode && !seiunOnline)
				{
				// 准备回放帧数据 (转为 Dynamic 以存入 Allscore)
				var replayFrameData:Array<Dynamic> = (replayExam != null && ClientPrefs.data.saveReplayData)
					? Replay.framesToDynamic(replayExam.getFrameData()) : null;

				var details:Array<Dynamic> = [
					Paths.formatToSongPath(SONG.song),
					songScore,
					songLength,
					songHits,
					songMisses,
					ratingPercent,
					ratingFC,
					ratingName,
					maxcombo,
					NoteTime,
					NoteMs,
					songSpeed,
					playbackRate,
					healthGain,
					healthLoss,
					cpuControlled,
					practiceMode,
					instakillOnMiss,
					Date.now().toString(),
					songSpeedType,
					ClientPrefs.data.sickWindow,
					ClientPrefs.data.goodWindow,
					ClientPrefs.data.badWindow,
					ClientPrefs.data.safeFrames,
					ClientPrefs.data.judgementTimings,
					ClientPrefs.data.marvelousRatings,
					ClientPrefs.data.judgementPreset,
					// osu! 尾判 + 判定相关手感 (27-30, 回放/成绩详情强制还原用)
					null, // 占位: osu! 尾判已禁用，保留 details[27] 索引，避免后续字段错位
					ClientPrefs.data.ratingOffset,
					ClientPrefs.data.guitarHeroSustains,
					ClientPrefs.data.marvelousWindow
				];
				Highscore.saveScore(SONG.song, songScore, storyDifficulty, percent,sicks, goods, bads, shits, songMisses, maxcombo);
				Allscore.addEntry(
				SONG.song, storyDifficulty,
				percent, ratingFC, ratingName,
				songScore,
				marvelouses, sicks, goods, bads, shits, songMisses, maxcombo,
				replayFrameData,
				details,
				null,
    			songSpeed, playbackRate, songSpeedType
			);
				#end
				}
			}
			if (chartingMode)
			{
				openChartEditor();
				return;
			}
			#if ONLINE_ALLOWED
			if (seiunOnline)
			{
				onlineSubmitResult();
				MusicBeatState.switchState(new online.states.OnlineResultsState(buildOnlineScore()));
				transitioning = true;
				return;
			}
			#end


			prevCamFollow = camFollow;
			prevCamFollowPos = camFollowPos;

			openSubState(new PlayStateResultsSubstate());
			transitioning = true;
		}
	}

	#if ACHIEVEMENTS_ALLOWED
	var achievementObj:AchievementObject = null;
	public function startAchievement(achieve:String) {
		achievementObj = new AchievementObject(achieve, camOther);
		achievementObj.onFinish = achievementEnd;
		add(achievementObj);
		TraceManager.info('trace.playState.givingAchievement', 'Giving achievement {}', [achieve]);
	}
	function achievementEnd():Void
	{
		achievementObj = null;
		if(endingSong && !inCutscene) {
			endSong();
		}
	}
	#end

	public function KillNotes() {
			var i:Int = notes.members.length - 1;
			while (i >= 0) {
				var daNote:Note = notes.members[i];
				if (daNote != null) {
					daNote.active = false;
					daNote.visible = false;
					daNote.kill();
					notes.remove(daNote, true);
					if (daNote.scale != null)
						daNote.destroy();
				}
				i--;
			}
			notePool = [];
			activeNotes.resize(0);

			unspawnNotes = [];
			_chartHasHolds = false;
			notesAddedCount = 0;
			limitNC = 0;
			_frameAliveTally = 0;
			_lastAliveTally = 0;
			_noteSlotCursor = 0;
			lastSpawnedNote = new Map<Int, Note>();
			eventNotes = [];
	}

	public var totalPlayed:Int = 0;
	public var totalNotesHit:Float = 0.0;

	public var showCombo:Bool = false;
	public var showComboNum:Bool = true;
	public var showRating:Bool = true;

	// Stores Ratings and Combo Sprites in a group(Psych 0.7.3 compat)
	public var comboGroup:FlxSpriteGroup;
	// Stores Note Objects in a Group (Psych 0.7.3 compat)
	public var noteGroup:FlxTypedGroup<FlxBasic>;
	// Stores HUD Objects in a Group (Psych 0.7.3 compat)
	public var uiGroup:FlxSpriteGroup;


	private function cachePopUpScore()
	{
		var pixelShitPart1:String = '';
		var pixelShitPart2:String = '';
		if (isPixelStage)
		{
			pixelShitPart1 = 'pixelUI/';
			pixelShitPart2 = '-pixel';
		}

		if (ClientPrefs.data.marvelousRatings)
			Paths.image(pixelShitPart1 + "marvelous" + pixelShitPart2);

		Paths.image(pixelShitPart1 + "sick" + pixelShitPart2);
		Paths.image(pixelShitPart1 + "good" + pixelShitPart2);
		Paths.image(pixelShitPart1 + "bad" + pixelShitPart2);
		Paths.image(pixelShitPart1 + "shit" + pixelShitPart2);
		Paths.image(pixelShitPart1 + "combo" + pixelShitPart2);

		for (i in 0...10) {
			Paths.image(pixelShitPart1 + 'num' + i + pixelShitPart2);
		}
	}

	/**
	 * LeatherEngine 移植: 按 judgementTimings / marvelousRatings 重建评级数据。
	 * 回放加载后也会重新调用, 保证恢复的判定手感立即生效。
	 */
	private function buildRatingsData():Void
	{
		ratingsData = [];

		// 判定窗口以 judgementTimings 为准, 同步到 Psych 窗口字段
		Ratings.syncWindows();

		if (ClientPrefs.data.marvelousRatings)
		{
			var rating:Rating = new Rating('marvelous');
			rating.ratingMod = 1;
			rating.score = 400;
			rating.noteSplash = true;
			ratingsData.push(rating);
		}

		ratingsData.push(new Rating('sick')); //default rating

		var rating:Rating = new Rating('good');
		rating.ratingMod = 0.7;
		rating.score = 200;
		rating.noteSplash = false;
		ratingsData.push(rating);

		var rating:Rating = new Rating('bad');
		rating.ratingMod = 0.4;
		rating.score = 0;
		rating.noteSplash = false;
		ratingsData.push(rating);

		var rating:Rating = new Rating('shit');
		rating.ratingMod = 0;
		rating.score = 0;
		rating.noteSplash = false;
		ratingsData.push(rating);
	}

	private function popUpScore(note:Note = null, ?time:Float = -999999):Void
	{
		var noteDiff:Float = 0;
		if (!cpuControlled) {
			noteDiff = Math.abs(note.strumTime - Conductor.songPosition + ClientPrefs.data.ratingOffset);
			NoteMs.push(noteDiff / playbackRate);
			NoteTime.push(note.strumTime);
		}

		// boyfriend.playAnim('hey');
		// set_volume 会触发 soundTransform 原生写入, 峰值下每击×3 路是纯浪费;
		// 已是 1 时跳过 (语义等价)。
		if (vocals.volume != 1) vocals.volume = 1;
		if (vocalsPlayer.volume != 1) vocalsPlayer.volume = 1;
		if (opponentVocals.volume != 1) opponentVocals.volume = 1;

		var score:Int = 350;
		var daRating:Rating = Conductor.judgeNote(note, noteDiff / playbackRate);
		//tryna do MS based judgment due to popular demand


		totalNotesHit += daRating.ratingMod;
		note.ratingMod = daRating.ratingMod;
		if(!note.ratingDisabled) daRating.increase();
		note.rating = daRating.name;
		score = daRating.score;
		if(daRating.noteSplash && !note.noteSplashDisabled)
		{
			spawnNoteSplashOnNote(note);
		}

		if(!practiceMode) {
		 // 分数仍保持 vanilla botplay 语义 (botplay 不加分); 命中数则与批量路径
		 // 同口径计入, 避免 HUD/结算里"击中数"只剩逐对象路径处理的少数音符。
		 if(!cpuControlled) songScore += score;
		 if(!note.ratingDisabled)
		 {
			 songHits++;
		 }
		}
		if(!note.ratingDisabled) {
			totalPlayed++;
			RecalculateRating(false);
		}

		if (_popupImmediateBudget > 0)
		{
			_popupImmediateBudget--;
			showComboNum = (combo >= 10);
			ratingPopup.show(daRating.image, combo, playbackRate, FlxG.width * 0.35,
				ClientPrefs.data.hideHud, showRating, showCombo, showComboNum,
				[for (v in ClientPrefs.data.comboOffset) Std.int(v)], Conductor.crochet,
				ClientPrefs.data.comboStacking);
		}
		else
		{
			_popupPending = true;
			_pendingRatingImage = daRating.image;
		}
	}

	public var strumsBlocked:Array<Bool> = [];
		private function onKeyPress(event:KeyboardEvent):Void
		{
			if (replayMode)
				return;
			var eventKey:FlxKey = event.keyCode;
			var key:Int = getKeyFromEvent(eventKey);
			if (!cpuControlled && startedCountdown && !paused && key > -1 && (FlxG.keys.checkStatus(eventKey, JUST_PRESSED) || ClientPrefs.data.controllerMode))
			{
				keyPressed(key);
			}
		}

		public function keyPressed(key:Int, ?time:Float = -999999):Void
		{
			if (cpuControlled || paused || key < 0)
				return;

			if (!generatedMusic || endingSong || boyfriend.stunned)
				return;

			// 0.7.3+/1.0.4: onKeyPressPre（返回 Function_Stop 可拦截本次按键）
			// 0.7.3+/1.0.4: onKeyPressPre (return Function_Stop to block the press)
			var preResult:Dynamic = callOnScripts('onKeyPressPre', [key]);
			if (preResult == LuaUtils.Function_Stop || preResult == FunkinLua.Function_Stop)
				return;

			// Notes at the beginning of a song can be inside the judgement window
			// while the countdown is still running. Do not start the audio from an
			// input event; use the countdown clock and let update() start the song.
			// Save the real position so the countdown clock isn't broken on restore.
			var lastTime:Float = Conductor.songPosition;
			var hitTime:Float = (replayMode && time != -999999) ? time : lastTime;
			var startedByInput:Bool = false;
			if (startingSong)
			{
				// Judge against the real countdown position so early presses get a
				// normal ms (like mid-song), not a forced zero point. Keyboard events
				// can run before Note.update(), so refresh canBeHit here.
				if (!hasActiveScripts())
				{
					for (daNote in activeNotes)
					{
						if (daNote == null) continue;
						if (daNote.mustPress && !daNote.isSustainNote)
						{
							daNote.canBeHit = daNote.strumTime > Conductor.songPosition - (Conductor.safeZoneOffset * daNote.lateHitMult)
								&& daNote.strumTime < Conductor.songPosition + (Conductor.safeZoneOffset * daNote.earlyHitMult);
							if (daNote.canBeHit) daNote.tooLate = false;
						}
					}
				}
				else
				{
					notes.forEachAlive(function(daNote:Note)
					{
						if (daNote.mustPress && !daNote.isSustainNote)
						{
							daNote.canBeHit = daNote.strumTime > Conductor.songPosition - (Conductor.safeZoneOffset * daNote.lateHitMult)
								&& daNote.strumTime < Conductor.songPosition + (Conductor.safeZoneOffset * daNote.earlyHitMult);
							if (daNote.canBeHit) daNote.tooLate = false;
						}
					});
				}
			}

			// 回放模式: 让脚本/按键处理都基于录制帧的精确时间。
			if (replayMode && time != -999999)
				Conductor.songPosition = hitTime;

		keyboardDisplay.pressed(key);


			callOnScripts('preKeyPress', [key]);
		if(!boyfriend.stunned && generatedMusic && !endingSong)
			{
				//more accurate hit time for the ratings?
				// FlxSound.time can include the platform audio buffer delay during
				// the first frames after playback starts. Use the frame clock until
				// that startup window has passed, otherwise the first hit can report
				// hundreds of milliseconds even when the key was pressed on time.
				var audioClockReady:Bool = songStartTicks >= 0 && FlxG.game.ticks - songStartTicks >= 1000;
				if (replayMode && time != -999999)
					Conductor.songPosition = hitTime;
				else if (!startedByInput && audioClockReady && FlxG.sound.music != null)
					Conductor.songPosition = FlxG.sound.music.time;

				var canMiss:Bool = !ClientPrefs.data.ghostTapping;

				// heavily based on my own code LOL if it aint broke dont fix it
				// 复用 keyPressed 的临时数组: 最外层调用零分配; 脚本重入时用新数组防止污染外层。
				var useScratch:Bool = _pressScratchDepth == 0;
				var pressNotes:Array<Note> = useScratch ? _keyPressedPressNotes : [];
				var sortedNotesList:Array<Note> = useScratch ? _keyPressedSortedNotes : [];
				if (useScratch)
				{
					pressNotes.resize(0);
					sortedNotesList.resize(0);
				}
				_pressScratchDepth++;
				var notesStopped:Bool = false;
			if (!hasActiveScripts())
			{
				// 无脚本: 只扫紧凑存活列表, 避开 notes 组里的死槽位与 forEachAlive 闭包。
				for (daNote in activeNotes)
				{
					if (daNote == null) continue;
					if (strumsBlocked[daNote.noteData] != true && daNote.canBeHit && daNote.mustPress && !daNote.tooLate && !daNote.wasGoodHit && !daNote.isSustainNote && !daNote.blockHit)
					{
						if (daNote.noteData == key)
						{
							sortedNotesList.push(daNote);
							//notesDatas.push(daNote.noteData);
						}
						canMiss = true;
					}
				}
			}
			else
			{
				notes.forEachAlive(function(daNote:Note)
				{
					if (strumsBlocked[daNote.noteData] != true && daNote.canBeHit && daNote.mustPress && !daNote.tooLate && !daNote.wasGoodHit && !daNote.isSustainNote && !daNote.blockHit)
					{
						if(daNote.noteData == key)
						{
							sortedNotesList.push(daNote);
							//notesDatas.push(daNote.noteData);
						}
						canMiss = true;
					}
				});
			}
				sortedNotesList.sort(sortHitNotes);

				if (sortedNotesList.length > 0) {
					for (epicNote in sortedNotesList)
					{
						for (doubleNote in pressNotes) {
							if (Math.abs(doubleNote.strumTime - epicNote.strumTime) < 1) {
								recycleNote(doubleNote);
							} else
								notesStopped = true;
						}

						// eee jack detection before was not super good
						if (!notesStopped) {
							goodNoteHit(epicNote);
							pressNotes.push(epicNote);
						}

					}
				}
				else{
					callOnScripts('onGhostTap', [key]);
					if (canMiss) {
						noteMissPress(key);
					}
				}

				// I dunno what you need this for but here you go
				//									- Shubs

				// Shubs, this is for the "Just the Two of Us" achievement lol
				//									- Shadow Mario
				keysPressed[key] = true;
				#if ONLINE_ALLOWED
				if (seiunOnline)
					// 上报按键时间用 keyPressed 入口处的帧时钟 (lastTime), 不能用上面同步后的
					// music.time: 音频时钟相对帧时钟滞后 (声卡缓冲) 且不含 Conductor.offset,
					// 会把所有按键报早几百毫秒, 被服务器判成 "illegal press outside chart window"。
					if (!seiunSpectate)
						OnlineSession.sendInput(key, true, lastTime);
				#end


				//more accurate hit time for the ratings? part 2 (Now that the calculations are done, go back to the time it was before for not causing a note stutter)
			Conductor.songPosition = lastTime;
			}


			var spr:StrumNote = playerStrums.members[key];
			if(strumsBlocked[key] != true && spr != null && spr.animation.curAnim.name != 'confirm')
			{
				spr.playAnim('pressed');
				spr.resetAnim = 0;
			}
			callOnScripts('onKeyPress', [key]);
			_pressScratchDepth--;
			}

		/**
		 * 多k: 多键同时按下时批量判定 (只遍历一次 Note 表, 避免每个键全表扫描导致掉帧)。
		 * 逻辑与 keyPressed 一致: 按轨道分组处理 jack、幽灵键、strum 动画, 并逐键触发脚本回调。
		 */
		public function keyPressBatch(keys:Array<Int>, time:Float, ?suppressAllButLast:Int = -1, ?pressTimes:Array<Float> = null):Void
		{
			if (cpuControlled || paused || keys == null || keys.length < 2) return;
			if (!generatedMusic || endingSong || boyfriend.stunned) return;

			// 预先构建轨道按下位图, 避免每个存活 Note 都做 keys.indexOf (O(N*K) -> O(N))
			// 复用 keyPressBatch 的临时数组: 最外层调用零分配; 脚本重入时用新数组防止污染外层。
			var useScratch:Bool = _pressScratchDepth == 0;
			var laneCount:Int = Note.ammo[mania];
			var laneDown:Array<Bool> = useScratch ? _batchLaneDown : [for (i in 0...laneCount) false];
			if (useScratch)
			{
				laneDown.resize(laneCount);
				for (i in 0...laneCount) laneDown[i] = false;
			}
			for (k in keys)
				if (k >= 0 && k < laneDown.length)
					laneDown[k] = true;

			var canMiss:Bool = !ClientPrefs.data.ghostTapping;
			var pressNotes:Array<Note> = useScratch ? _batchPressNotes : [];
			if (useScratch) pressNotes.resize(0);
			_pressScratchDepth++;
			if (!hasActiveScripts())
			{
				for (daNote in activeNotes)
				{
					if (daNote == null) continue;
					if (strumsBlocked[daNote.noteData] != true && daNote.canBeHit && daNote.mustPress
						&& !daNote.tooLate && !daNote.wasGoodHit && !daNote.isSustainNote && !daNote.blockHit)
					{
						if (daNote.noteData >= 0 && daNote.noteData < laneDown.length && laneDown[daNote.noteData])
							pressNotes.push(daNote);
						canMiss = true;
					}
				}
			}
			else
			{
				notes.forEachAlive(function(daNote:Note)
				{
					if (strumsBlocked[daNote.noteData] != true && daNote.canBeHit && daNote.mustPress
						&& !daNote.tooLate && !daNote.wasGoodHit && !daNote.isSustainNote && !daNote.blockHit)
					{
						if (daNote.noteData >= 0 && daNote.noteData < laneDown.length && laneDown[daNote.noteData])
							pressNotes.push(daNote);
						canMiss = true;
					}
				});
			}

			// 按轨道分组 (同轨 jack 检测互不影响); 最外层用预分配桶, 避免每批新建 Map/数组。
			var laneNotes:Array<Array<Note>>;
			if (useScratch)
			{
				_batchLaneNotes.resize(laneCount);
				for (i in 0...laneCount)
				{
					var bucket:Array<Note> = _batchLaneNotes[i];
					if (bucket == null)
					{
						bucket = [];
						_batchLaneNotes[i] = bucket;
					}
					bucket.resize(0);
				}
				laneNotes = _batchLaneNotes;
			}
			else
				laneNotes = [for (i in 0...laneCount) []];
			for (n in pressNotes)
			{
				if (n.noteData >= 0 && n.noteData < laneNotes.length)
					laneNotes[n.noteData].push(n);
			}

			for (i in 0...keys.length)
			{
				var key:Int = keys[i];
				var reportTime:Float = (pressTimes != null && i < pressTimes.length && pressTimes[i] != -999999) ? pressTimes[i] : Conductor.songPosition;
				keyboardDisplay.pressed(key);
				callOnScripts('preKeyPress', [key]);

				var spr:StrumNote = (key >= 0 && key < playerStrums.members.length) ? playerStrums.members[key] : null;
				if (strumsBlocked[key] != true && spr != null && spr.animation.curAnim != null && spr.animation.curAnim.name != 'confirm')
				{
					spr.playAnim('pressed');
					spr.resetAnim = 0;
				}

				var list:Array<Note> = (key >= 0 && key < laneNotes.length) ? laneNotes[key] : null;
				if (list == null || list.length < 1)
				{
					callOnScripts('onGhostTap', [key]);
					if (canMiss) noteMissPress(key);
					keysPressed[key] = true;
					#if ONLINE_ALLOWED
					if (seiunOnline)
						if (!seiunSpectate)
							OnlineSession.sendInput(key, true, reportTime);
					#end

					callOnScripts('onKeyPress', [key]);
					continue;
				}

				list.sort(sortHitNotes);
				var localPress:Array<Note>;
				if (useScratch)
				{
					_batchLocalPress.resize(0);
					localPress = _batchLocalPress;
				}
				else
					localPress = [];
				var notesStopped:Bool = false;
				var suppress:Bool = (suppressAllButLast >= 0 && key != suppressAllButLast);
				for (epicNote in list)
				{
					for (doubleNote in localPress)
					{
						if (Math.abs(doubleNote.strumTime - epicNote.strumTime) < 1)
						{
							recycleNote(doubleNote);
						}
						else
							notesStopped = true;
					}
					if (!notesStopped)
					{
						_suppressNoteAnim = suppress;
						goodNoteHit(epicNote);
						_suppressNoteAnim = false;
						localPress.push(epicNote);
					}
				}
				keysPressed[key] = true;
				#if ONLINE_ALLOWED
				if (seiunOnline && !seiunSpectate)
					OnlineSession.sendInput(key, true, reportTime);
				#end

				callOnScripts('onKeyPress', [key]);
			}
			_pressScratchDepth--;
		}

		/** 多k: 供安卓 Hitbox 直接触发额外轨道 (4K 以上)。 */
		public function mobileKeyPressed(key:Int):Void
		{
			if (key < 0 || key >= Note.ammo[mania] || key >= mobileHeld.length)
				return;
			// 触摸按住状态: 即使暂停/回放也如实记录, keysCheck 才能持续命中长条段
			mobileHeld[key] = true;
			if (replayMode || cpuControlled || paused)
				return;
			// 同帧多指按下先入队, 由 keysCheck 合并成 keyPressBatch, 避免每指全表扫 Note。
			if (_mobilePressQueue.indexOf(key) == -1)
			{
				_mobilePressQueue.push(key);
				_mobilePressTimes.push(Conductor.songPosition);
			}
		}

		/** 多k: 供安卓 Hitbox 直接释放额外轨道 (4K 以上)。 */
		public function mobileKeyReleased(key:Int):Void
		{
			if (key < 0 || key >= Note.ammo[mania] || key >= mobileHeld.length)
				return;
			mobileHeld[key] = false;
			// 若同一帧内还有未处理的按下，先入队释放，keysCheck 按 按下→释放 顺序处理，
			// 避免快速点按在同帧 down+up 时出现“先 release 后 press”导致按键状态卡住。
			if (_mobilePressQueue.indexOf(key) != -1)
				_mobileReleaseQueue.push(key);
			else
				keyReleased(key);
		}



		function sortHitNotes(a:Note, b:Note):Int
		{
			if (a.lowPriority && !b.lowPriority)
				return 1;
			else if (!a.lowPriority && b.lowPriority)
				return -1;

			return FlxSort.byValues(FlxSort.ASCENDING, a.strumTime, b.strumTime);
		}

		private function onKeyRelease(event:KeyboardEvent):Void
		{
			if (replayMode)
				return;
			var eventKey:FlxKey = event.keyCode;
			var key:Int = getKeyFromEvent(eventKey);
			if (key > -1)
				keyReleased(key);
		}

		public function keyReleased(key:Int, ?time:Float = -999999):Void
		{
			// 回放模式必须对称处理按下/释放：keyPressed 不要求 startedCountdown，
			// 如果这里仍要求 startedCountdown，倒计时/开场的释放会被吞掉，导致按键一直按住。
			if (cpuControlled || paused || (!replayMode && !startedCountdown))
				return;
			keyboardDisplay.released(key);

			// 0.7.3+/1.0.4: onKeyReleasePre（返回 Function_Stop 可拦截本次松键）
			// 0.7.3+/1.0.4: onKeyReleasePre (return Function_Stop to block the release)
			var preResult:Dynamic = callOnScripts('onKeyReleasePre', [key]);
			if (preResult == LuaUtils.Function_Stop || preResult == FunkinLua.Function_Stop)
				return;

			/** osu! 尾判: 松键时按释放时机相对长条尾端判定
			if (ClientPrefs.data.osuTailJudgement
				&& key >= 0 && key < activeTailEnd.length
				&& activeTailEnd[key] > 0
				&& (strumsBlocked.length <= key || strumsBlocked[key] != true))
			{
				var releaseTime:Float = (time != -999999) ? time : Conductor.songPosition;
				judgeTailRelease(key, releaseTime);
			}
			*/

			var spr:StrumNote = playerStrums.members[key];
			if (spr != null)
			{
				spr.playAnim('static');
				spr.resetAnim = 0;
			}
			callOnScripts('onKeyRelease', [key]);
			#if ONLINE_ALLOWED
			if (seiunOnline)
				if (!seiunSpectate)
					OnlineSession.sendInput(key, false, Conductor.songPosition);
			#end

		}

		// ======================== osu! 尾判 ========================

		/** osu! 尾判: 初始化轨道数组 (mania 可能变化)
		private function ensureTailArrays():Void
		{
			var laneCount:Int = Note.ammo[mania];
			if (activeTailEnd.length != laneCount)
			{
				activeTailEnd = [for (i in 0...laneCount) 0.0];
				activeHoldNote = [for (i in 0...laneCount) null];
			}
		}
			*/

		/** osu! 尾判: 清除指定轨道的活动长条
		private function clearActiveHold(lane:Int):Void
		{
			if (lane >= 0 && lane < activeTailEnd.length)
			{
				activeTailEnd[lane] = 0;
				activeHoldNote[lane] = null;
			}
		}
			*/

		/** osu! 尾判: 长条头部命中时注册活动长条 (记录尾端时间与头部 Note)
		private function registerActiveHold(note:Note):Void
		{
			if (note == null || cpuControlled || playOpponent || note.isSustainNote || note.sustainLength < 1) return;
			if (!note.mustPress) return;
			ensureTailArrays();
			var lane:Int = Std.int(Math.abs(note.noteData));
			if (lane < 0 || lane >= activeTailEnd.length) return;

			// 长条链: 上一根长条还挂着就按下新头部 → 上一根视为按住完成, 结算其长条分数
			if (activeTailEnd[lane] > 0)
			{
				if (!practiceMode)
				{
					songScore += sustainNotescore;
					updateScore();
				}
				sustainNotescore = 0;
				clearActiveHold(lane);
			}

			activeTailEnd[lane] = computeTailEnd(note);
			activeHoldNote[lane] = note;
		}
			*/

		/**
		 * osu! 尾判: 计算长条的视觉尾端时间。
		 * 不能直接用 strumTime + sustainLength —— 谱面生成时尾段会额外偏移
		 * (stepCrochet / songSpeed), 玩家松手是对着屏幕上的尾段松的。
		 * 沿 nextNote 链找到最后一个 sustain 段 (isSustainEnd) 用它的 strumTime;
		 * 短到没生成尾段的兜底用 chart 时长。

		private function computeTailEnd(head:Note):Float
		{
			var fallback:Float = head.strumTime + head.sustainLength;
			if (head.sourceIndex < 0 || head.sourceIndex >= unspawnNotes.length)
				return fallback;
			var headParentST:Float = head.strumTime - ClientPrefs.data.noteOffset;
			var endPieceTime:Float = fallback;
			var i:Int = head.sourceIndex + 1;
			while (i < unspawnNotes.length)
			{
				var d:PreloadedChartNote = unspawnNotes[i];
				// 只扫描属于同一根长条的 sustain 片段；遇到其它 Note 就停止。
				if (!d.isSustainNote || d.parentST != headParentST)
					break;
				endPieceTime = d.strumTime;
				if (d.isSustainEnd)
					break;
				i++;
			}
			return endPieceTime;
		}
	 */
		/**
		 * osu! 尾判: 松键判定 (由 keyReleased 调用)。
		 * - 松键误差 = 松键时间 - 尾端时间, 与普通音符一样按 |误差| 使用同一套判定窗口
		 * - 误差超出安全区 → miss (早放/晚放都算)
		 * - 按住超过尾端 + 安全区仍不松 → 由每帧超时检查判 miss (osu: 超过晚 miss 窗口仍按住 = miss)

		private function judgeTailRelease(lane:Int, releaseTime:Float):Void
		{
			if (lane < 0 || lane >= activeTailEnd.length) return;
			var tailEnd:Float = activeTailEnd[lane];
			if (tailEnd <= 0) return;

			var diff:Float = releaseTime - tailEnd;
			var rating:String = tailRatingFor(diff);
			if (rating == 'miss')
				*/
				//tailMiss(lane, tailEnd, releaseTime);
			//else
				//tailHit(lane, tailEnd, diff, rating);
			//clearActiveHold(lane);
		//}

		/**
		 * osu! 尾判: 松键评级 (完全还原 osu!mania: 早放/晚放对称使用同一套窗口)。
		 * - |误差| ≤ marvelous/sick/good/bad 窗口 → 对应评级
		 * - bad 窗口 < |误差| ≤ 安全区 → shit
		 * - |误差| > 安全区 → miss

		private function tailRatingFor(diff:Float):String
		{
			var absDiff:Float = Math.abs(diff);
			var mult:Float = tailWindowMult();
			if (absDiff > Conductor.safeZoneOffset * mult) return 'miss';
			// 尾判窗口按倍率放宽 (默认 2 倍)
			return backend.Ratings.getRating(absDiff / mult);
		}
			*/

		/** osu! 尾判: 松键命中 → 结算长条分数 + 评级分数, 显示延迟与评级图标
		private function tailHit(lane:Int, tailEnd:Float, diff:Float, rating:String):Void
		{
			var head:Note = (lane < activeHoldNote.length) ? activeHoldNote[lane] : null;

			// 回放时优先使用录制的高精度尾判, 100% 还原评分与 ms
			var recordedJ = null;
			if (replayMode && replayExam != null && replayExam.hasJudgments)
				recordedJ = replayExam.getRecordedJudgment(tailEnd, lane);

			if (recordedJ != null) rating = recordedJ.rating;

			if (!replayMode && replayExam != null)
				replayExam.recordJudgment(tailEnd, lane, diff, rating, true);

			// 尾判命中: 剩余长条段直接作废, 不再逐段判定
			if (head != null) invalidateRemainingSustain(lane, head);

			if (rating == 'marvelous') msTxtKade.color = 0xFFFFD700;
			else if (rating == 'sick') msTxtKade.color = 0x00FFFF;
			else if (rating == 'good') msTxtKade.color = 0x006400;
			else if (rating == 'bad') msTxtKade.color = 0xEEFF00;
			else msTxtKade.color = 0xFF0000;

			var showMs:Float = (recordedJ != null) ? recordedJ.hitDiff : diff;
			msTxtKade.text = Std.string(FlxMath.roundDecimal(showMs, 3)) + "ms";
			msTxtKade.alpha = 1;
			if (msScaleTween != null) msScaleTween.cancel();
			msTxtKade.scale.set(1.15, 1.15);
			msScaleTween = FlxTween.tween(msTxtKade.scale, {x: 1, y: 1}, 0.15, {ease: FlxEase.backOut});
			if (msTween != null) msTween.cancel();
			msTween = FlxTween.tween(msTxtKade, {alpha: 0}, 0.5, {ease: FlxEase.quintIn});

			var score:Int = backend.Ratings.getScore(rating);
			if (!practiceMode && !cpuControlled)
			{
				// 尾判命中才结算长条按住期间累积的分数 (osu: 断条不结算)
				songScore += sustainNotescore;
				songScore += score;
				songHits++;
				// 尾判命中计入评级计数 (marvelouses/sicks/goods/bads/shits), 与准确率一致
				var counterName:String = (rating == 'marvelous') ? 'marvelouses' : rating + 's';
				Reflect.setField(this, counterName, Reflect.field(this, counterName) + 1);
			}
			sustainNotescore = 0;
			updateScore();
			totalPlayed++;
			// 尾判命中按评级计入准确率 (与普通音符一致), 否则全 perfect 也会被长条拉低准确率
			var tailMod:Float = 1;
			if (rating == 'good') tailMod = 0.7;
			else if (rating == 'bad') tailMod = 0.4;
			else if (rating == 'shit') tailMod = 0;
			totalNotesHit += tailMod;
			RecalculateRating(false);
			*/

			// 评级弹窗 (只显示评级图, 不叠 combo 数字: 连击由头部音符负责)
			/**if (ratingPopup != null)
				ratingPopup.show(rating, combo, playbackRate, FlxG.width * 0.35,
					ClientPrefs.data.hideHud, showRating, false, false,*/
					//[for (v in ClientPrefs.data.comboOffset) Std.int(v)], Conductor.crochet,
					//ClientPrefs.data.comboStacking);
		//}

		/** osu! 尾判: 提前过多松键 → 尾判失误 (断连/扣血/计 miss)
		private function tailMiss(lane:Int, tailEnd:Float, releaseTime:Float):Void
		{
			var head:Note = (lane < activeHoldNote.length) ? activeHoldNote[lane] : null;
			var diff:Float = releaseTime - tailEnd;

			if (!replayMode && replayExam != null)
				replayExam.recordJudgment(tailEnd, lane, diff, 'miss', true);

			// miss: 长条段恢复未按住状态, 让它们像普通 miss 一样划过接收器 (只计一次失误)
			if (head != null) markRemainingSustainMissed(lane, head);

			combo = 0;
			if (!endingSong) songMisses++;
			totalPlayed++;
			sustainNotescore = 0;
			NoteMs.push(167);
			NoteTime.push(tailEnd);
			RecalculateRating(true);

			if (head != null)
			{
				if (playOpponent) health += head.missHealth * healthLoss;
				else health -= head.missHealth * healthLoss;
			}
			else
			{
				if (playOpponent) health += 0.05 * healthLoss;
				else health -= 0.05 * healthLoss;
			}
*/
			// 模拟普通 miss 效果: 角色 miss 动画 / gf 难过
			/**if (head != null && !head.noMissAnimation)
			{
				var missChar:Character = playOpponent ? dad : boyfriend;
				if (head.gfNote) missChar = gf;
				if (missChar != null && missChar.hasMissAnimations)
				{
					var animToPlay:String = getSingAnim(head) + 'miss' + head.animSuffix;
					missChar.playAnim(animToPlay, true);
				}
			}
			if (combo > 5 && gf != null && gf.animOffsets.exists('sad'))
				gf.playAnim('sad');
*/
/**
			msTxtKade.color = 0xFF0000;
			msTxtKade.text = 'Miss';
			msTxtKade.alpha = 1;
			if (msTween != null) msTween.cancel();
			msTween = FlxTween.tween(msTxtKade, {alpha: 0}, 0.5, {ease: FlxEase.quintIn});

/**
			if (instakillOnMiss)
			{
				vocals.volume = 0;
				vocalsPlayer.volume = 0;
				doDeathCheck(true);
			}*/
			//FlxG.sound.play(Paths.soundRandom('missnote', 1, 3), FlxG.random.float(0.1, 0.2));
			//clearActiveHold(lane);
		//}

			// it's bad , yes?

		/** osu! 尾判: 命中时丢弃长条剩余未命中段, 防止松键后被逐段判 miss
		private function invalidateRemainingSustain(lane:Int, head:Note):Void
		{
			if (head == null) return;
			var headParentST:Float = head.strumTime - ClientPrefs.data.noteOffset;
			notes.forEachAlive(function(n:Note)
			{
				if (n != null && n.isSustainNote && n.mustPress && n.noteData == lane}
					&& n.parentST == headParentST && !n.wasGoodHit && !n.missed && !n.ignoreNote)
				{
					n.missed = true;
					n.ignoreNote = true;
					n.wasGoodHit = true;
					n.tooLate = true;
					invalidateNote(n);
				}*/
			//});



		/** osu! 尾判: 判 miss 时把长条剩余段恢复为未按住状态, 让它们像普通 miss 一样划过接收器
		private function markRemainingSustainMissed(lane:Int, head:Note):Void
		{
			if (head == null) return;
			var headParentST:Float = head.strumTime - ClientPrefs.data.noteOffset;
			notes.forEachAlive(function(n:Note)
			{
				if (n != null && n.isSustainNote && n.mustPress && n.noteData == lane
					&& n.parentST == headParentST && !n.missed)
				{
					n.wasGoodHit = false; // 恢复未按住状态
					n.missed = true;
					n.ignoreNote = true;
					n.tooLate = true;
					n.multAlpha = 0.3;
					n.alpha = 0.3;
				}
			});
		}*/

	/**
	 * @param frameTime 当前帧对应的歌曲时间
	 * @param pressLanes 按下的轨道列表
	 * @param releaseLanes 释放的轨道列表
	 * @param heldLanes 保持按下的轨道数组
	 */
	public function replayApplyInput(frameTime:Float, pressLanes:Array<Int>, releaseLanes:Array<Int>, heldLanes:Array<Bool>):Void
	{
		var laneCount:Int = keysArray.length;
		for (i in 0...laneCount)
		{
			_hold[i] = (heldLanes != null && i < heldLanes.length) ? heldLanes[i] : false;
			_press[i] = false;
			_release[i] = false;
		}
		if (pressLanes != null)
		{
			for (lane in pressLanes)
			{
				if (lane >= 0 && lane < laneCount) _press[lane] = true;
			}
		}
		if (releaseLanes != null)
		{
			for (lane in releaseLanes)
			{
				if (lane >= 0 && lane < laneCount) _release[lane] = true;
			}
		}

		// 处理按下
		if (_press.contains(true))
		{
			for (i in 0..._press.length)
			{
				if (_press[i] && strumsBlocked[i] != true)
					keyPressed(i, frameTime);
			}
		}

		// 处理长条 (hold)
		if (startedCountdown && !boyfriend.stunned && generatedMusic && !endingSong)
		{
			if (notes.length > 0)
			{
				notes.forEachAlive(function(daNote:Note)
				{
					if (strumsBlocked[daNote.noteData] != true
						&& daNote.isSustainNote
						&& _hold[daNote.noteData]
						&& daNote.canBeHit
						&& daNote.mustPress
						&& !daNote.tooLate
						&& !daNote.wasGoodHit
						&& !daNote.blockHit)
						goodNoteHit(daNote);
				});
			}
		}

		// 角色空闲动画
		if (!_hold.contains(true) && !endingSong && generatedMusic)
		{
			var danceChar:Character = playOpponent ? dad : boyfriend;
			if (!danceChar.isAnimationNull()
				&& danceChar.holdTimer > Conductor.stepCrochet * (0.0011 / FlxG.sound.music.pitch) * danceChar.singDuration
				&& danceChar.getAnimationName().startsWith('sing')
				&& !danceChar.getAnimationName().endsWith('miss'))
				danceChar.dance();
		}

		// 处理释放
		if (_release.contains(true))
		{
			for (i in 0..._release.length)
			{
				if (_release[i] || strumsBlocked[i] == true)
					keyReleased(i, frameTime);
			}
		}

		// osu! 尾判: 回放中按住超过尾端 + 安全区仍不松 → 按太久 miss (与实机判定一致)
		//if (ClientPrefs.data.osuTailJudgement && activeTailEnd.length > 0)
		//{
		//	for (i in 0..._hold.length)
		//	{
		//		if (activeTailEnd[i] > 0 && _hold[i]
		//			&& frameTime > activeTailEnd[i] + Conductor.safeZoneOffset * tailWindowMult())
		//			tailMiss(i, activeTailEnd[i], frameTime);
		//	}
		//}
	}


		private function getKeyFromEvent(key:FlxKey):Int
		{
			if(key != NONE)
			{
				for (i in 0...keysArray.length)
				{
					for (j in 0...keysArray[i].length)
					{
						if(key == keysArray[i][j])
						{
							return i;
						}
					}
				}
			}
			return -1;
		}

	#if ONLINE_ALLOWED
	/** 进入联机对局时应用房间统一判定/兼容模式, 离开时恢复。 */
	function onlineApplyRoomSettings():Void
	{
		if (!OnlineSession.active)
			return;
		var s = OnlineSession.settings;
		if (s != null)
		{
			if (prevOnlineJudgement == null)
				prevOnlineJudgement = ClientPrefs.data.judgementTimings.copy();
			prevOnlineJudgementPreset = ClientPrefs.data.judgementPreset;
			prevOnlineMarvelous = ClientPrefs.data.marvelousRatings;
			//prevOnlineTailOn = ClientPrefs.data.osuTailJudgement;
			//prevOnlineTailMult = ClientPrefs.data.tailWindowMult;
			prevOnlineCompat = ClientPrefs.data.compatibility_mode;
			prevOnlineCompatEngine = ClientPrefs.data.compatEngine;
			if (s.judgementTimings != null && s.judgementTimings.length >= 4)
			{
				ClientPrefs.data.judgementTimings = s.judgementTimings.copy();
				ClientPrefs.data.judgementPreset = s.judgementPreset == null ? "Custom" : s.judgementPreset;
				ClientPrefs.data.marvelousRatings = s.marvelousRatings;
				backend.Ratings.syncWindows();
			}
			// 房间统一尾判参数 (osu! 尾判开关 + 窗口倍率)
			//if (Reflect.hasField(s, "osuTailJudgement"))
			//	ClientPrefs.data.osuTailJudgement = s.osuTailJudgement == true;
			//if (Reflect.hasField(s, "tailWindowMult") && s.tailWindowMult != null
			//	&& !Math.isNaN(s.tailWindowMult) && s.tailWindowMult > 0 && s.tailWindowMult <= 8)
			//	ClientPrefs.data.tailWindowMult = s.tailWindowMult;
			// 房间统一兼容模式 (四值: Auto/0.6.3/0.7.3/1.0.4)
			var ce:String = OnlineSession.compatEngine;
			if (ce != null && ce.length > 0 && backend.CompatEngine.VALUES.contains(ce))
				ClientPrefs.data.compatEngine = ce;
			else
				ClientPrefs.data.compatibility_mode = s.compatibilityMode;
		}
		buildRatingsData();
	}

	function onlineRestoreRoomSettings():Void
	{
		if (prevOnlineJudgement != null)
		{
			ClientPrefs.data.judgementTimings = prevOnlineJudgement;
			ClientPrefs.data.judgementPreset = prevOnlineJudgementPreset;
			ClientPrefs.data.marvelousRatings = prevOnlineMarvelous;
			//ClientPrefs.data.osuTailJudgement = prevOnlineTailOn;
			//ClientPrefs.data.tailWindowMult = prevOnlineTailMult;
			ClientPrefs.data.compatibility_mode = prevOnlineCompat;
			ClientPrefs.data.compatEngine = prevOnlineCompatEngine;
			backend.Ratings.syncWindows();
			prevOnlineJudgement = null;
		}
	}

	/** 尝试消费服务器统一起跑信号; 成功则写入 startOnTime 并允许 startCountdown 继续。 */
	function tryConsumeRealtimeSync():Bool
	{
		if (!seiunOnline || !OnlineSession.active || OnlineSession.mode != online.shared.OnlineTypes.OnlineConst.MODE_REALTIME)
			return true;
		var wait:Float = OnlineSession.consumePendingRealtimeSync();
		if (wait < 0)
			return false;
		PlayState.startOnTime = wait;
		skipCountdown = true;
		hideOnlineSyncWait();
		return true;
	}

	/** 起跑门闩是否仍在等待 (倒计时冻结中): 时间轴上报后、统一起跑帧到达前。 */
	function onlineGateWaiting():Bool
	{
		return seiunOnline && !seiunSpectate && OnlineSession.active
			&& OnlineSession.mode == online.shared.OnlineTypes.OnlineConst.MODE_REALTIME
			&& onlineTimelineSent
			&& !startedCountdown && !endingSong
			&& OnlineSession.pendingRealtimeSyncServerStartMs <= 0;
	}

	function refreshOnlineSyncWaitText():Void
	{
		if (onlineWaitSyncTxt == null)
			return;
		// 起跑改为自动: 全员加载完成后服务器立即广播统一起跑帧, 无需再按确认。
		var prog:String = onlineGateTotalCount > 0
			? " (" + onlineGateConfirmedCount + "/" + onlineGateTotalCount + ")"
			: "";
		onlineWaitSyncTxt.text = Language.get('online.gateWaitingStart', '已就绪，等待其他玩家加载，服务器将自动开始') + prog;
	}

	function showOnlineSyncWait():Void
	{
		if (onlineWaitSyncTxt == null)
		{
			onlineWaitSyncTxt = new FlxText(0, 86, FlxG.width, "", 18);
			onlineWaitSyncTxt.setFormat(Paths.languageFont(), 18, FlxColor.fromRGB(255, 220, 150), CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
			onlineWaitSyncTxt.scrollFactor.set();
			onlineWaitSyncTxt.cameras = [camHUD];
			add(onlineWaitSyncTxt);
		}
		refreshOnlineSyncWaitText();
		onlineWaitSyncTxt.visible = true;
		onlineWaitSyncTxt.alpha = 1;
	}

	function hideOnlineSyncWait():Void
	{
		if (onlineWaitSyncTxt != null)
			onlineWaitSyncTxt.visible = false;
	}

	/** 起跑门闩: 每帧检查本机玩家的确认按键 (空格/回车, 走 controls.ACCEPT)。 */
	function updateOnlineStartGate():Void
	{
		if (!onlineGateWaiting())
			return;
		if (!onlineGateConfirmed)
		{
			showOnlineSyncWait();
			if (controls != null && controls.ACCEPT)
			{
				onlineGateConfirmed = true;
				onlineGateConfirmedCount = Std.int(Math.max(1, onlineGateConfirmedCount));
				OnlineSession.sendStartAck();
				FlxG.sound.play(Paths.sound('confirmMenu'), 0.7);
				refreshOnlineSyncWaitText();
			}
		}
		else
		{
			// 已确认但还没收到统一起跑帧: 保持等待文本可见。
			showOnlineSyncWait();
		}
	}

	/** 谱面加载完成后把 note 时间轴交给服务器做输入合法性校验。 */
	function onlineGameStart():Void
	{
		if (!seiunOnline || !OnlineSession.active || GameClient.instance == null || GameClient.instance.state != online.client.GameClient.ClientState.Ready)
			return;
		#if ONLINE_ALLOWED
		// 观战: 不上传时间轴/开工信号, 起跑由 MSG_GAME_SYNC 广播驱动 (服务器只等游玩者)。
		if (seiunSpectate)
		{
			onlineTimelineSent = true;
			return;
		}
		#end
		if (OnlineSession.mode == online.shared.OnlineTypes.OnlineConst.MODE_ASYNC)
		{
			// 异步排名: 各打各的, 只上报"我开始打了", 不参与统一起跑。
			OnlineSession.sendAsyncStart();
			return;
		}
		var notesPayload:Array<Dynamic> = [];
		if (unspawnNotes != null)
		{
			for (n in unspawnNotes)
			{
				if (n == null)
					continue;
				// 结构体：头 Note 自带长条总长（长条片段延迟生成，不再逐片段上报）
				notesPayload.push({timeMs: n.strumTime, lane: Std.int(Math.abs(n.noteData) % Note.ammo[n.mania]), lengthMs: n.sustainLength > 0 ? n.sustainLength : 0});
			}
		}
		// 实时对战: 时间轴同时兼作"我加载完成"信号。服务器收到全部真人玩家的
		// 时间轴后立即自动广播 MSG_GAME_SYNC, 不再等手动空格/回车确认。
		// 这里同时自动发送一次 START_ACK 作为兼容信号: 即使某个玩家的时间轴
		// 因故没被服务器登记, 只要全员 ACK 到达, 服务器也会强制发令, 避免僵死。
		// chartNotes 可能超过 64 KiB, 走 FILE 通道 (上限 64 MiB), 服务器端同样解析 JSON。
		onlineTimelineSent = true;
		GameClient.instance.send(SeiunProtocol.MSG_GAME_START, SeiunProtocol.CHANNEL_FILE, {
			song: OnlineSession.chart,
			chartNotes: notesPayload,
			startedAt: Date.now().getTime()
		});
		onlineGateConfirmed = true;
		onlineGateConfirmedCount = 1;
		OnlineSession.sendStartAck();
	}

	/**
		PsychOnline 式联机角色初始化 (对局开始):
		- 自己 (右侧主角色) 用 ProfileStore.skinData 替换 BF;
		- 第一个远端玩家 (左侧主角色) 用其 skinData 替换 Dad;
		- 其余远端玩家 (2v2+) 在左侧渲染额外角色, 按 judge 事件做 sing 动画;
		- 每个玩家头顶生成用户名铭牌。
		角色缺失时逐级回退 (OnlineSkinUtil), 最终回退谱面原角色。
	**/
	function onlineInitPlayerCharacters():Void
	{
		onlinePlayerChars = new Map<String, Character>();
		onlineNameplates = new Map<String, FlxText>();
		onlineNameplateGroup = new FlxTypedGroup<FlxText>();
		onlineMainOpponentId = "";
		onlineExtraCharIndex = 0;

		// 观战: 右侧主角色 = 被跟随玩家 (第一个游玩者), 其判定广播驱动该角色。
		var followed:Dynamic = null;
		if (seiunSpectate)
		{
			for (p in OnlineSession.players)
			{
				if (p != null && !(Reflect.hasField(p, "isSpectator") && Reflect.field(p, "isSpectator") == true))
				{
					followed = p;
					break;
				}
			}
			onlineFollowedId = followed != null && Reflect.field(followed, "id") != null ? Std.string(Reflect.field(followed, "id")) : "";
			onlineFollowedDeviceId = followed != null && Reflect.field(followed, "deviceId") != null ? Std.string(Reflect.field(followed, "deviceId")) : "";
		}

		// 自己: 右侧主角色 (观战时=被跟随玩家)
		var selfSd:online.shared.OnlineTypes.OnlineSkinData = (seiunSpectate && followed != null)
			? cast Reflect.field(followed, "skinData")
			: ProfileStore.skinData;
		var selfSkin:String = online.client.OnlineSkinUtil.resolveSkin(selfSd, true, curStage);
		if (selfSkin != null && selfSkin != SONG.player1)
		{
			var modDir:String = online.client.OnlineSkinUtil.resolveModDir(selfSd, true, curStage);
			var oldDir:String = backend.Mods.currentModDirectory;
			if (modDir.length > 0)
				backend.Mods.currentModDirectory = modDir;
			var nb:Boyfriend = null;
			try { nb = new Boyfriend(0, 0, selfSkin); } catch (e:Dynamic) { nb = null; }
			backend.Mods.currentModDirectory = oldDir;
			if (nb != null)
			{
				boyfriendGroup.remove(boyfriend);
				boyfriend.destroy();
				boyfriend = nb;
				startCharacterPos(boyfriend);
				boyfriendGroup.add(boyfriend);
				startCharacterLua(boyfriend.curCharacter);
			}
		}
		var selfMapId:String = (seiunSpectate && onlineFollowedId.length > 0) ? onlineFollowedId : OnlineSession.selfId;
		onlinePlayerChars.set(selfMapId, boyfriend);
		onlineMakeNameplate(selfMapId,
			(seiunSpectate && followed != null && Reflect.field(followed, "nickname") != null && Std.string(Reflect.field(followed, "nickname")).length > 0)
				? Std.string(Reflect.field(followed, "nickname"))
				: ProfileStore.nickname);

		// 远端玩家: 第一个替换左侧主角色 (Dad), 其余为额外角色 (观战者跳过)
		for (p in OnlineSession.players)
		{
			if (p == null)
				continue;
			var pid:String = Reflect.field(p, "id");
			if (pid == null || pid == OnlineSession.selfId)
				continue;
			// 观战: 其它观战者与被跟随者 (已在右侧) 都不建角色。
			if (Reflect.hasField(p, "isSpectator") && Reflect.field(p, "isSpectator") == true)
				continue;
			if (seiunSpectate && pid == onlineFollowedId)
				continue;
			var nick:String = Reflect.field(p, "nickname");
			if (nick == null || nick.length == 0)
				nick = pid;
			var sd:online.shared.OnlineTypes.OnlineSkinData = cast Reflect.field(p, "skinData");
			if (onlineMainOpponentId.length == 0)
			{
				onlineMainOpponentId = pid;
				var skinName:String = online.client.OnlineSkinUtil.resolveSkin(sd, false, curStage);
				if (skinName != null && skinName != SONG.player2)
				{
					var modDir:String = online.client.OnlineSkinUtil.resolveModDir(sd, false, curStage);
					var oldDir:String = backend.Mods.currentModDirectory;
					if (modDir.length > 0)
						backend.Mods.currentModDirectory = modDir;
					var nd:Character = null;
					try { nd = new Character(0, 0, skinName, false); } catch (e:Dynamic) { nd = null; }
					backend.Mods.currentModDirectory = oldDir;
					if (nd != null)
					{
						dadGroup.remove(dad);
						dad.destroy();
						dad = nd;
						startCharacterPos(dad, true);
						dadGroup.add(dad);
						startCharacterLua(dad.curCharacter);
					}
				}
				onlinePlayerChars.set(pid, dad);
			}
			else
				onlineMakeExtraCharacter(pid, sd, SONG.player2);
			onlineMakeNameplate(pid, nick);
		}
	}

	/** 生成玩家头顶铭牌 (半透明, 跟随角色, 不参与摄像机缩放以外的变换)。 */
	function onlineMakeNameplate(pid:String, nick:String):Void
	{
		if (onlineNameplateGroup == null || onlineNameplates.exists(pid))
			return;
		// 铭牌字体随语言包 (中文昵称用 vcrcn, 不再豆腐块) —— UI 重构修复。
		var plate:FlxText = new FlxText(0, 0, 0, nick, 20);
		plate.setFormat(Paths.languageFont(), 20, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		plate.borderSize = 1.5;
		plate.alpha = 0.9;
		plate.scrollFactor.set(0.9, 0.9);
		onlineNameplates.set(pid, plate);
		onlineNameplateGroup.add(plate);
	}

	/** 为第 N 位远端玩家在左侧主角色旁创建额外角色 (2v2+ 可视化)。 */
	function onlineMakeExtraCharacter(pid:String, sd:online.shared.OnlineTypes.OnlineSkinData, fallbackName:String):Void
	{
		var skinName:String = online.client.OnlineSkinUtil.resolveSkin(sd, false, curStage);
		var modDir:String = skinName != null ? online.client.OnlineSkinUtil.resolveModDir(sd, false, curStage) : "";
		if (skinName == null)
			skinName = fallbackName;
		var oldDir:String = backend.Mods.currentModDirectory;
		if (modDir.length > 0)
			backend.Mods.currentModDirectory = modDir;
		var char:Character = null;
		try { char = new Character(0, 0, skinName, false); } catch (e:Dynamic) { char = null; }
		backend.Mods.currentModDirectory = oldDir;
		if (char == null)
			return;
		// 排布在主角色左侧, 稍靠后, 避免完全重叠
		onlineExtraCharIndex++;
		if (dad != null)
		{
			char.x = dad.x - 90 * onlineExtraCharIndex;
			char.y = dad.y + 10 * (onlineExtraCharIndex % 2 == 0 ? 1 : -1);
		}
		char.active = false; // 不自行跳舞, 由 judge 事件驱动 sing 动画
		dadGroup.add(char);
		onlinePlayerChars.set(pid, char);
	}

	/** 每帧把铭牌贴到对应角色头顶。 */
	function onlineUpdateNameplates():Void
	{
		if (onlineNameplateGroup == null)
			return;
		for (pid in onlinePlayerChars.keys())
		{
			var c:Character = onlinePlayerChars.get(pid);
			var plate:FlxText = onlineNameplates.get(pid);
			if (c == null || plate == null)
				continue;
			plate.x = c.x + c.width / 2 - plate.width / 2;
			plate.y = c.y - plate.height - 16;
			plate.visible = c.visible;
		}
	}

	/** 对局中换肤: 重建该玩家的角色实例 (保留位置), 更新铭牌颜色提示。 */
	function onlineApplySkinChange(pid:String, sd:online.shared.OnlineTypes.OnlineSkinData):Void
	{
		var old:Character = onlinePlayerChars.get(pid);
		if (old == null)
			return;
		var isSelf:Bool = pid == OnlineSession.selfId;
		var isMainOpponent:Bool = pid == onlineMainOpponentId;
		var skinName:String = online.client.OnlineSkinUtil.resolveSkin(sd, isSelf, curStage);
		if (skinName == null)
			return; // 换肤目标不存在: 保持原角色
		var modDir:String = online.client.OnlineSkinUtil.resolveModDir(sd, isSelf, curStage);
		var oldDir:String = backend.Mods.currentModDirectory;
		if (modDir.length > 0)
			backend.Mods.currentModDirectory = modDir;
		var nc:Character = null;
		try
		{
			if (isSelf)
				nc = new Boyfriend(0, 0, skinName);
			else
				nc = new Character(0, 0, skinName, false);
		}
		catch (e:Dynamic)
		{
			nc = null;
		}
		backend.Mods.currentModDirectory = oldDir;
		if (nc == null)
			return;
		nc.x = old.x;
		nc.y = old.y;
		if (isSelf)
		{
			boyfriendGroup.remove(boyfriend);
			boyfriend.destroy();
			boyfriend = cast nc;
			boyfriendGroup.add(boyfriend);
			onlinePlayerChars.set(pid, boyfriend);
		}
		else if (isMainOpponent)
		{
			dadGroup.remove(dad);
			dad.destroy();
			dad = nc;
			dadGroup.add(dad);
			onlinePlayerChars.set(pid, dad);
		}
		else
		{
			dadGroup.remove(old);
			old.destroy();
			dadGroup.add(nc);
			onlinePlayerChars.set(pid, nc);
		}
	}

	/** 额外角色 (非主 Dad) 的 sing 动画: 按 judge 事件的 lane 播放对应方向。 */
	function onlineAnimatePlayerByDevice(deviceId:String, lane:Int):Void
	{
		if (onlinePlayerChars == null || lane < 0)
			return;
		// 观战: 被跟随玩家的判定直接驱动右侧主角色动画。
		if (seiunSpectate && onlineFollowedDeviceId.length > 0 && deviceId == onlineFollowedDeviceId)
		{
			var fc:Character = onlinePlayerChars.get(onlineFollowedId);
			if (fc != null)
			{
				var fanims:Array<String> = ['singLEFT', 'singDOWN', 'singUP', 'singRIGHT'];
				var fanim:String = fanims[lane % fanims.length];
				if (fc.animation.getByName(fanim) != null)
				{
					fc.playAnim(fanim, true);
					fc.holdTimer = 0;
				}
			}
			return;
		}
		for (pid in onlinePlayerChars.keys())
		{
			if (pid == OnlineSession.selfId || pid == onlineMainOpponentId)
				continue;
			var p:Dynamic = null;
			for (pp in OnlineSession.players)
				if (pp != null && Reflect.field(pp, "id") == pid)
				{
					p = pp;
					break;
				}
			if (p == null || Reflect.field(p, "deviceId") != deviceId)
				continue;
			var c:Character = onlinePlayerChars.get(pid);
			if (c == null)
				continue;
			var anims:Array<String> = ['singLEFT', 'singDOWN', 'singUP', 'singRIGHT'];
			var anim:String = anims[lane % anims.length];
			if (c.animation.getByName(anim) != null)
			{
				c.playAnim(anim, true);
				c.holdTimer = 0;
			}
		}
	}

	function updateOnline(elapsed:Float):Void
	{
		var client:GameClient = GameClient.instance;
		if (client == null || !seiunOnline || !OnlineSession.active)
			return;
		// 暂停拦截提示的淡出计时。
		if (onlinePauseNoticeTimer > 0)
		{
			onlinePauseNoticeTimer -= elapsed;
			if (onlinePauseNoticeTimer <= 0 && onlinePauseNoticeTxt != null)
				onlinePauseNoticeTxt.alpha = 0;
		}
		client.update(elapsed);
		updateOnlineStartGate();
		onlineUpdateNameplates();
		// 消费对局中收到的皮肤变更 (重建对应玩家角色)。
		if (OnlineSession.pendingSkinChanges.iterator().hasNext())
		{
			for (pid in OnlineSession.pendingSkinChanges.keys())
				onlineApplySkinChange(pid, OnlineSession.pendingSkinChanges.get(pid));
			OnlineSession.pendingSkinChanges = new Map<String, online.shared.OnlineTypes.OnlineSkinData>();
		}
		var ev = client.pollEvent();
		while (ev != null)
		{
			switch (ev.type)
			{
				case SeiunProtocol.MSG_GAME_SYNC:
					// 服务器统一起跑: 存锚点后立即尝试开始; 若 PlayState 仍在
					// create 流程中, startCountdown 的在线闸门稍后也会消费它。
					if (OnlineSession.mode == online.shared.OnlineTypes.OnlineConst.MODE_REALTIME
						&& ev.data != null && !startedCountdown && !endingSong && !inCutscene)
					{
						OnlineSession.setPendingRealtimeSync(
							Std.parseFloat(Std.string(Reflect.field(ev.data, "serverNow"))),
							Std.parseFloat(Std.string(Reflect.field(ev.data, "startDelayMs"))));
						if (tryConsumeRealtimeSync())
							startCountdown();
					}
				case SeiunProtocol.MSG_GAME_START_ACK:
					// 其他玩家按下了确认键: 刷新门闩进度显示。
					if (ev.data != null)
					{
						var cf:Float = Std.parseFloat(Std.string(Reflect.field(ev.data, "confirmed")));
						var tt:Float = Std.parseFloat(Std.string(Reflect.field(ev.data, "total")));
						if (!Math.isNaN(cf))
							onlineGateConfirmedCount = Std.int(cf);
						if (!Math.isNaN(tt) && tt > 0)
							onlineGateTotalCount = Std.int(tt);
						refreshOnlineSyncWaitText();
					}
				case SeiunProtocol.MSG_ROOM_PLAYER_SKIN:
					// 对局中有人换肤: 更新会话数据, 渲染层 (消费 pendingSkinChanges) 负责换角色。
					if (ev.data != null)
					{
						var skinSid:String = Std.string(Reflect.field(ev.data, "id"));
						var sd:Dynamic = Reflect.field(ev.data, "skinData");
						var skinData:online.shared.OnlineTypes.OnlineSkinData = online.shared.OnlineTypes.SkinDataUtil.fromDynamic(sd);
						for (p in OnlineSession.players)
						{
							if (Std.string(Reflect.field(p, "id")) == skinSid)
							{
								Reflect.setField(p, "skinData", sd);
								Reflect.setField(p, "skin", skinData != null ? skinData.char : "");
								break;
							}
						}
						if (skinSid != OnlineSession.selfId)
							OnlineSession.pendingSkinChanges.set(skinSid, skinData);
					}
				case SeiunProtocol.MSG_GAME_INPUT:
					if (OnlineSession.mode != online.shared.OnlineTypes.OnlineConst.MODE_REALTIME)
						break;
					if (ev.data != null && ev.data.id != OnlineSession.selfId)
					{
						var laneValue:Null<Int> = Std.parseInt(Std.string(Reflect.field(ev.data, "lane")));
						var lane:Int = laneValue == null ? -1 : laneValue;
						var pressed:Bool = Reflect.field(ev.data, "pressed") == true;
						if (pressed && opponentStrums != null && lane >= 0 && lane < opponentStrums.members.length)
						{
							var strum:StrumNote = opponentStrums.members[lane];
							if (strum != null)
							{
								strum.playAnim('pressed', true);
								strum.resetAnim = 0;
							}
						}
					}
				case SeiunProtocol.MSG_GAME_PAUSE:
					// 联机暂停是全局的: 对方暂停/恢复都同步; 倒计时/结算中不弹暂停。
					// 暂停策略 disabled 时服务器不会转发, 这里再兜底一次。
					if (ev.data != null && ev.data.id != OnlineSession.selfId && !paused
						&& startedCountdown && canPause && !endingSong && !transitioning
						&& onlinePausePolicy() != online.shared.OnlineTypes.OnlineConst.PAUSE_DISABLED)
					{
						OnlineSession.pauseNickname = Reflect.field(ev.data, "nickname") == null
							? "" : Std.string(Reflect.field(ev.data, "nickname"));
						openPauseMenu(false);
					}
				case SeiunProtocol.MSG_GAME_RESUME:
					OnlineSession.pauseNickname = "";
					if (ev.data != null && ev.data.id != OnlineSession.selfId && paused
						&& subState != null
						&& (Std.isOfType(subState, substates.PauseSubState) || Std.isOfType(subState, substates.OldPauseSubState)))
						closeSubState();
				case SeiunProtocol.MSG_GAME_JUDGE:
					if (OnlineSession.mode != online.shared.OnlineTypes.OnlineConst.MODE_REALTIME)
						break;
					if (ev.data != null)
					{
						#if ONLINE_ALLOWED
						// 共享血量 (PsychOnline room.state.health 等价物):
						// 远端判定带来的血量直接同步到本地血条; 实时模式不因血量归零
						// 单独 Game Over, 双方都打完以成绩排名结算。
						var remoteHealth:Dynamic = Reflect.field(ev.data, "health");
						var remoteDev0:String = Reflect.field(ev.data, "deviceId");
						// 观战时血量只跟随被跟随玩家 (否则全房任意广播都会拉动本地血条)。
						if (remoteHealth != null && remoteDev0 != null && remoteDev0 != ProfileStore.deviceId
							&& (!seiunSpectate || remoteDev0 == onlineFollowedDeviceId))
						{
							var hv:Float = Std.parseFloat(Std.string(remoteHealth));
							// -1 = 旧客户端未携带血量, 忽略而不是把共享血量压到 0。
							if (!Math.isNaN(hv) && hv >= 0)
								health = Math.max(0, Math.min(2, hv));
						}
						// 对手实时分数 (PsychOnline 式): 本地判定/假人判定广播都带 score 与实时统计。
						var judgeDev:String = Reflect.field(ev.data, "deviceId");
						var judgeScore:Dynamic = Reflect.field(ev.data, "score");
						if (judgeScore != null && judgeDev != null && judgeDev != ProfileStore.deviceId)
						{
							var nick:String = judgeDev;
							for (p in OnlineSession.players)
								if (p != null && Reflect.field(p, "deviceId") == judgeDev)
								{
									nick = Reflect.field(p, "nickname");
									break;
								}
							var oldEntry:Dynamic = remoteScores.get(judgeDev);
							var ping:Float = oldEntry != null && Reflect.field(oldEntry, "ping") != null ? Std.parseFloat(Std.string(Reflect.field(oldEntry, "ping"))) : 0;
							remoteScores.set(judgeDev, {
								name: nick,
								score: judgeScore,
								misses: Reflect.field(ev.data, "misses"),
								maxCombo: Reflect.field(ev.data, "maxCombo"),
								accuracy: Reflect.field(ev.data, "accuracy"),
								ratingName: Reflect.field(ev.data, "ratingName"),
								ratingFC: Reflect.field(ev.data, "ratingFC"),
								ping: Reflect.field(ev.data, "pingMs") == null ? ping : Reflect.field(ev.data, "pingMs")
							});
						}
						// 额外联机角色 (2v2+): 按该玩家判定事件的 lane 播 sing 动画。
						var judgeLane:Float = Std.parseFloat(Std.string(Reflect.field(ev.data, "lane")));
						if (!Math.isNaN(judgeLane) && judgeLane >= 0)
							onlineAnimatePlayerByDevice(judgeDev, Std.int(judgeLane));
						#end
						OnlineSession.incomingJudges.push(ev.data);
					}
				case SeiunProtocol.MSG_GAME_RESULT:
					// 自己还在打时, 其他玩家可能已经先提交成绩。先缓存到
					// OnlineSession, 结算页创建时合并, 避免事件在 PlayState 被消费后丢失。
					if (ev.data != null && OnlineSession.mode == online.shared.OnlineTypes.OnlineConst.MODE_REALTIME)
					{
						var resultDev:String = Reflect.field(ev.data, "deviceId");
						if (resultDev != null && resultDev != OnlineSession.selfId)
						{
							OnlineSession.pendingRealtimeResults.set(resultDev, ev.data);
							#if ONLINE_ALLOWED
							// 最终成绩也即时反映到右上 HUD。
							var nick:String = resultDev;
							for (p in OnlineSession.players)
								if (p != null && Reflect.field(p, "deviceId") == resultDev)
								{
									nick = Reflect.field(p, "nickname");
									break;
								}
							var oldEntry:Dynamic = remoteScores.get(resultDev);
							var ping:Float = oldEntry != null && Reflect.field(oldEntry, "ping") != null ? Std.parseFloat(Std.string(Reflect.field(oldEntry, "ping"))) : 0;
							remoteScores.set(resultDev, {
								name: nick,
								score: Reflect.field(ev.data, "score"),
								misses: Reflect.field(ev.data, "misses"),
								maxCombo: Reflect.field(ev.data, "maxCombo"),
								accuracy: Reflect.field(ev.data, "accuracy"),
								ratingName: Reflect.field(ev.data, "ratingName"),
								ratingFC: Reflect.field(ev.data, "ratingFC"),
								ping: ping
							});
							#end
						}
					}
				case SeiunProtocol.MSG_GAME_END:
					if (ev.data != null && ev.data.results != null && Std.isOfType(ev.data.results, Array))
						OnlineSession.pendingRealtimeRanking = cast ev.data.results;
				case SeiunProtocol.MSG_ROOM_ANNOUNCE:
					if (ev.data != null)
					{
						var noticeText:String = Std.string(Reflect.field(ev.data, "text"));
						if (noticeText.indexOf("房主退出") >= 0 || noticeText.indexOf("房间已关闭") >= 0 || noticeText.indexOf("房主断开") >= 0)
						{
							// 房主退出/房间关闭: 本局作废, 提示后回联机主界面。
							OnlineSession.recordDisconnect(noticeText);
							client.disconnect(true);
							OnlineSession.clear();
							seiunOnline = false;
							onlineRestoreRoomSettings();
							MusicBeatState.switchState(new online.states.OnlineState());
							return;
						}
					}
				case SeiunProtocol.MSG_ROOM_PLAYER_LEAVE:
					if (ev.data != null)
						OnlineSession.recordDisconnect(Std.string(Reflect.field(ev.data, "nickname")));
				case SeiunProtocol.MSG_ERROR:
					if (ev.data != null)
					{
						OnlineSession.recordDisconnect(Std.string(Reflect.field(ev.data, "message")));
						var msg:String = ev.data.message == null ? "" : Std.string(ev.data.message);
						if (msg.indexOf("移出房间") >= 0 || msg.indexOf("请出服务器") >= 0 || msg.indexOf("封禁") >= 0)
						{
							client.disconnect(true);
							OnlineSession.clear();
							seiunOnline = false;
							onlineRestoreRoomSettings();
							MusicBeatState.switchState(new online.states.OnlineState());
							return;
						}
					}
			}
			ev = client.pollEvent();
		}
		while (OnlineSession.mode == online.shared.OnlineTypes.OnlineConst.MODE_REALTIME && OnlineSession.incomingJudges.length > 0)
		{
			var judge:Dynamic = OnlineSession.incomingJudges.shift();
			if (judge == null || judge.deviceId == ProfileStore.deviceId)
				continue;
			#if ONLINE_ALLOWED
			handleRemoteJudgeVisual(judge);
			#end
		}
		if (client.state == online.client.GameClient.ClientState.Failed && !endingSong && !paused)
		{
			OnlineSession.recordDisconnect(client.lastError);
			openPauseMenu();
		}
		#if ONLINE_ALLOWED
		refreshRemoteScoreText();
		#end
	}

	#if ONLINE_ALLOWED
	/** 刷新右上对手分数 HUD (PsychOnline 式: 名字/分数/漏键/准确率/评级, 按分数降序, 最多 6 人)。 */
	function refreshRemoteScoreText():Void
	{
		if (remoteScoreTxt == null)
			return;
		remoteScoreTxt.visible = OnlineSession.mode == online.shared.OnlineTypes.OnlineConst.MODE_REALTIME && !ClientPrefs.data.hideHud;
		if (!remoteScoreTxt.visible)
			return;
		var list:Array<Dynamic> = [];
		for (k in remoteScores.keys())
			list.push(remoteScores.get(k));
		list.sort(function(a:Dynamic, b:Dynamic):Int
		{
			var sa:Float = Std.parseFloat(Std.string(a.score));
			var sb:Float = Std.parseFloat(Std.string(b.score));
			return sa == sb ? 0 : (sb > sa ? 1 : -1);
		});
		var lines:Array<String> = [];
		for (i in 0...Std.int(Math.min(list.length, 6)))
		{
			var e = list[i];
			var acc:Float = Std.parseFloat(Std.string(e.accuracy == null ? 0 : e.accuracy));
			var missParsed:Null<Int> = Std.parseInt(Std.string(e.misses == null ? 0 : e.misses));
			var miss:Int = missParsed == null ? 0 : missParsed;
			var comboParsed:Null<Int> = Std.parseInt(Std.string(e.maxCombo == null ? 0 : e.maxCombo));
			var combo:Int = comboParsed == null ? 0 : comboParsed;
			var rating:String = Std.string(e.ratingName == null ? "" : e.ratingName);
			var fc:String = Std.string(e.ratingFC == null ? "" : e.ratingFC);
			var ping:Float = Std.parseFloat(Std.string(e.ping == null ? 0 : e.ping));
			lines.push(Std.string(e.name) + "  " + Std.string(e.score)
				+ "  " + miss + "M " + combo + "C"
				+ (rating.length > 0 ? " " + rating + (fc.length > 0 ? " [" + fc + "]" : "") : "")
				+ " " + Highscore.floorDecimal(acc * 100, 2) + "%"
				+ (ping > 0 ? " " + Std.int(ping) + "ms" : ""));
		}
		var sig:String = lines.join("\n");
		if (sig == remoteScoreSig)
			return;
		remoteScoreSig = sig;
		remoteScoreTxt.text = sig;
	}

	/** 远端判定可视化: 让对手的实时输入打在本地对手侧音符上 (PsychOnline 的 noteHit/noteMiss 等价物)。 */
	function handleRemoteJudgeVisual(judge:Dynamic):Void
	{
		if (judge == null)
			return;
		var laneValue:Null<Int> = Std.parseInt(Std.string(Reflect.field(judge, "lane")));
		var lane:Int = laneValue == null ? -1 : Std.int(Math.abs(laneValue));
		var strumTime:Float = Std.parseFloat(Std.string(Reflect.field(judge, "strumTime")));
		var isSustain:Bool = Reflect.field(judge, "isSustain") == true;
		var rating:String = Std.string(Reflect.field(judge, "rating"));

		if (lane >= 0 && opponentStrums != null && lane < opponentStrums.members.length)
		{
			var strum:StrumNote = opponentStrums.members[lane];
			if (strum != null)
			{
				strum.playAnim(rating == "shit" ? 'static' : 'confirm', true);
				strum.resetAnim = 0;
			}
		}

		var found:Note = null;
		if (notes != null)
		{
			for (note in notes.members)
			{
				if (note == null || !note.alive || note.mustPress)
					continue;
				if (note.isSustainNote != isSustain)
					continue;
				if (Math.abs(note.strumTime - strumTime) > 100)
					continue;
				var noteLane:Int = Std.int(Math.abs(note.noteData)) % Note.ammo[mania];
				if (noteLane != lane % Note.ammo[mania])
					continue;
				found = note;
				break;
			}
		}
		if (found == null)
			return;

		if (rating == "shit")
		{
			// 远端漏键: 只移除音符/表现 miss, 不改本地血量与成绩。
			recycleNote(found);
		}
		else
		{
			opponentNoteHit(found);
		}
	}
	#end
	/** 生成联机成绩对象 (结算页与异步排名共用)。实时模式不带大回放, 避免超过游戏通道消息上限。 */
	function buildOnlineScore(?includeReplay:Bool = true):Dynamic
	{
		ProfileStore.ensureLoaded();
		var replayJson:String = "";
		if (includeReplay && replayExam != null && replayExam.getFrameData().length > 0)
			replayJson = haxe.Json.stringify({frameData: Replay.framesToDynamic(replayExam.getFrameData())});
		if (replayJson.length > 3 * 1024 * 1024)
			replayJson = ""; // 超过异步消息上限时放弃回放, 成绩标记为未校验而不是断开连接
		return {
			deviceId: ProfileStore.deviceId,
			nickname: ProfileStore.nickname,
			avatar: ProfileStore.avatar,
			score: songScore,
			accuracy: Math.isNaN(ratingPercent) ? 0 : ratingPercent,
			maxCombo: maxcombo,
			misses: songMisses,
			marvelous: marvelouses,
			sick: sicks,
			good: goods,
			bad: bads,
			shit: shits,
			completed: true,
			nps: songLength > 0 ? totalNotesHit / (songLength / 1000.0) : 0,
			missTimes: NoteTime.copy(),
			wrongLaneHits: wrongLaneTimes.copy(),
			replayJson: replayJson
		};
	}

	function onlineSubmitResult():Void
	{
		// 观战者不提交任何成绩 (服务器也不把观战者计入排名)。
		if (seiunSpectate)
			return;
		var client:GameClient = GameClient.instance;
		if (client == null || !OnlineSession.active)
			return;
		if (OnlineSession.mode == online.shared.OnlineTypes.OnlineConst.MODE_ASYNC)
		{
			OnlineSession.submitAsyncScore(buildOnlineScore(true));
		}
		else
		{
			var realtimeScore:Dynamic = buildOnlineScore(false);
			// 先传回放再传成绩: 服务器以成绩消息触发 GAME_END 汇总,
			// 保证最终排名广播时回放已经挂到该玩家记录上。
			var replayUpload:Dynamic = buildOnlineScore(true);
			if (replayUpload != null && replayUpload.replayJson != null && replayUpload.replayJson.length > 0)
				client.send(SeiunProtocol.MSG_ASYNC_REPLAY_UPLOAD, SeiunProtocol.CHANNEL_ASYNC, {replayJson: replayUpload.replayJson});
			// 反作弊已移除: 成绩一律由客户端上报, 服务器转发/汇总。
			client.send(SeiunProtocol.MSG_GAME_RESULT, SeiunProtocol.CHANNEL_GAME, realtimeScore);
			// 不再由房主单方面发 GAME_END: 服务器会等所有玩家提交成绩后
			// 自动汇总并广播最终排名 (与 PsychOnline 的 playerEnded 收尾一致)。
		}
	}

	#end


		// Hold notes
		public function keysCheck(?keyCount:Int, time:Float = -999999):Void
		{
			var nested:Bool = _keysCheckDepth > 0;
			var holdArray:Array<Bool> = nested ? [] : _keyHold;
			var pressArray:Array<Bool> = nested ? [] : _keyPress;
			var releaseArray:Array<Bool> = nested ? [] : _keyRelease;
			var pressedLanes:Array<Int> = nested ? [] : _pressedLanes;
			var anyHeld:Bool = false;
			var laneCount:Int = Note.ammo[mania];
			_keysCheckDepth++;

			// 复用预分配数组, 避免每帧 3 个新 Array + 后续 expand (Android GC 压力)。
			if (holdArray.length < laneCount) holdArray.resize(laneCount);
			if (pressArray.length < laneCount) pressArray.resize(laneCount);
			if (releaseArray.length < laneCount) releaseArray.resize(laneCount);

			for (i in 0...laneCount)
			{
				holdArray[i] = false;
				pressArray[i] = false;
				releaseArray[i] = false;
			}

			// 非回放模式: 从 controls 读取按键状态
			for (i in 0...laneCount)
			{
				// 4K: 沿用原版 controls 动作 (键盘/手柄/安卓按键)
				// 多k: 全部轨道直接读键盘 (0-3 轨也读多k键位, 保证用户改绑的多k键生效)
				if (mania == Note.defaultMania && i < controlArray.length && controlArray[i] != null)
				{
					var held:Bool = false;
					var pressed:Bool = false;
					var released:Bool = false;
					switch (controlArray[i])
					{
						case 'NOTE_LEFT':
							held = controls.NOTE_LEFT;
							pressed = controls.NOTE_LEFT_P;
							released = controls.NOTE_LEFT_R;
						case 'NOTE_DOWN':
							held = controls.NOTE_DOWN;
							pressed = controls.NOTE_DOWN_P;
							released = controls.NOTE_DOWN_R;
						case 'NOTE_UP':
							held = controls.NOTE_UP;
							pressed = controls.NOTE_UP_P;
							released = controls.NOTE_UP_R;
						case 'NOTE_RIGHT':
							held = controls.NOTE_RIGHT;
							pressed = controls.NOTE_RIGHT_P;
							released = controls.NOTE_RIGHT_R;
						default:
							// 自定义扩展轨道名仍走动态读取, 保持与旧 Reflect 行为一致。
							held = Reflect.getProperty(controls, controlArray[i]);
							pressed = Reflect.getProperty(controls, controlArray[i] + '_P');
							released = Reflect.getProperty(controls, controlArray[i] + '_R');
					}
					holdArray[i] = held;
					pressArray[i] = pressed;
					releaseArray[i] = released;
					if (held) anyHeld = true;
				}
				else
				{
					// 直接读该轨道的键位 (多k: 全部轨道; 4K: 兜底)
					var held:Bool = false;
					var pressed:Bool = false;
					var released:Bool = false;
					if (i < keysArray.length)
					{
						var binds:Array<FlxKey> = keysArray[i];
						if (binds != null)
						{
							for (j in 0...binds.length)
							{
								if (FlxG.keys.checkStatus(binds[j], PRESSED)) held = true;
								if (FlxG.keys.checkStatus(binds[j], JUST_PRESSED)) pressed = true;
								if (FlxG.keys.checkStatus(binds[j], JUST_RELEASED)) released = true;
							}
						}
					}
					// 多k 移动端: 触摸按住的轨道也算"按住", 否则 FlxHitbox 按下的长条段
					// 永远收不到 goodNoteHit (4K 走 Controls 通路所以正常)
					if (i < mobileHeld.length && mobileHeld[i])
						held = true;
					holdArray[i] = held;
					pressArray[i] = pressed;
					releaseArray[i] = released;
					if (held) anyHeld = true;
				}
			}

			if (!cpuControlled && startedCountdown && !paused && !endingSong && !boyfriend.stunned && generatedMusic && !replayMode)
			{
				if (ClientPrefs.data.lastNoteAnimation)
				{
					// lastNoteAnimation: 保持旧的多K触摸逐键语义（不合并/不抑制），
					// 先清同帧触摸队列，再走键盘原路径，避免改变“最后一键播动画”的视觉行为。
					if (_mobilePressQueue.length > 0)
					{
						for (mi in 0..._mobilePressQueue.length)
						{
							var mKey:Int = _mobilePressQueue[mi];
							if (mKey >= 0 && mKey < laneCount && strumsBlocked[mKey] != true)
								keyPressed(mKey, time);
						}
						_mobilePressQueue.resize(0);
						_mobilePressTimes.resize(0);
					}
					if (_mobileReleaseQueue.length > 0)
					{
						for (r in _mobileReleaseQueue)
							keyReleased(r);
						_mobileReleaseQueue.resize(0);
					}

					// 多键时同样走批量扫描, 只保留原版"最后一键播动画"的语义
					pressedLanes.resize(0);
					for (i in 0...laneCount)
						if (pressArray[i] && strumsBlocked[i] != true)
							pressedLanes.push(i);

					if (pressedLanes.length == 1)
						keyPressed(pressedLanes[0], time);
					else if (pressedLanes.length > 1)
						keyPressBatch(pressedLanes, time, pressedLanes[pressedLanes.length - 1]);
				}
				else
				{
					// 多k: 多键同时按下时走批量判定, 避免每个键都全表扫描 Note 造成掉帧；
					// 同帧触摸与键盘一起合并，触摸原始时间随 pressTimes 交给批量上报。
					pressedLanes.resize(0);
					var mobileTimes:Array<Float> = null;
					if (_mobilePressQueue.length > 0)
					{
						mobileTimes = [];
						for (mi in 0..._mobilePressQueue.length)
						{
							var mKey:Int = _mobilePressQueue[mi];
							if (mKey >= 0 && mKey < laneCount && strumsBlocked[mKey] != true && pressedLanes.indexOf(mKey) == -1)
							{
								pressedLanes.push(mKey);
								mobileTimes.push(_mobilePressTimes[mi]);
							}
						}
					}
					for (i in 0...laneCount)
					{
						if (pressArray[i] && strumsBlocked[i] != true)
						{
							if (pressedLanes.indexOf(i) == -1)
							{
								pressedLanes.push(i);
								if (mobileTimes != null) mobileTimes.push(-999999);
							}
						}
					}
					if (_mobilePressQueue.length > 0)
					{
						_mobilePressQueue.resize(0);
						_mobilePressTimes.resize(0);
					}
					if (pressedLanes.length == 1)
						keyPressed(pressedLanes[0], time);
					else if (pressedLanes.length > 1)
						keyPressBatch(pressedLanes, time, -1, mobileTimes);
					if (_mobileReleaseQueue.length > 0)
					{
						for (r in _mobileReleaseQueue)
							keyReleased(r);
						_mobileReleaseQueue.resize(0);
					}
				}

				// 没有任何轨道按住时, 长条不可能被命中, 跳过整次全表扫描。
				// 无脚本时用紧凑存活列表 (activeNotes), 避免扫全量 members 死槽位；
				// 有脚本时保持 notes.forEachAlive 原语义 (脚本额外加入的 Note 也参与)。
				if (anyHeld)
				{
					if (!hasActiveScripts())
					{
						var ai:Int = 0;
						while (ai < activeNotes.length)
						{
							var daNote:Note = activeNotes[ai];
							var lenBefore:Int = activeNotes.length;
							if (daNote != null
								&& strumsBlocked[daNote.noteData] != true && daNote.isSustainNote && holdArray[daNote.noteData] && daNote.canBeHit
								&& daNote.mustPress && !daNote.tooLate && !daNote.wasGoodHit && !daNote.blockHit)
								goodNoteHit(daNote, time);
							if (activeNotes.length == lenBefore && ai < activeNotes.length && activeNotes[ai] == daNote)
								ai++;
						}
					}
					else
					{
						notes.forEachAlive(function(daNote:Note)
						{
							if (strumsBlocked[daNote.noteData] != true && daNote.isSustainNote && holdArray[daNote.noteData] && daNote.canBeHit
								&& daNote.mustPress && !daNote.tooLate && !daNote.wasGoodHit && !daNote.blockHit)
								goodNoteHit(daNote, time);
						});
					}
				}
			}
			else
			{
				// 非游戏输入帧（暂停/结束/回放/锁定等）不应保留同帧触摸队列。
				_mobilePressQueue.resize(0);
				_mobilePressTimes.resize(0);
				_mobileReleaseQueue.resize(0);
			}

			if (!anyHeld && !endingSong && generatedMusic)
			{
				var danceChar:Character = playOpponent ? dad : boyfriend;
				if (!danceChar.isAnimationNull() && danceChar.holdTimer > Conductor.stepCrochet * (0.0011 / FlxG.sound.music.pitch) * danceChar.singDuration && danceChar.getAnimationName().startsWith('sing') && !danceChar.getAnimationName().endsWith('miss'))
					danceChar.dance();
				if (playOpponent && !boyfriend.isAnimationNull() && boyfriend.holdTimer > Conductor.stepCrochet * (0.0011 / FlxG.sound.music.pitch) * boyfriend.singDuration && boyfriend.getAnimationName().startsWith('sing') && !boyfriend.getAnimationName().endsWith('miss'))
					boyfriend.dance();
			}
			for (i in 0...laneCount)
			{
				if (releaseArray[i])
					keyReleased(i, time);
				
				var spr:StrumNote = playerStrums.members[i];
				// 反卡键 (多绑定/触摸释放丢失的幻按): 该轨道当前确实没有按住, 但 strum 仍停在 'pressed',
				// 说明释放事件被吞, 强制回 'static'。只在"确实未按住"时才复位, 因此不误伤长按/真按住。
				var stuckPressed:Bool = (spr != null && !holdArray[i]
					&& spr.animation.curAnim != null && spr.animation.curAnim.name == 'pressed');
				if (strumsBlocked[i] == true || stuckPressed)
				{
					if (spr != null)
					{
						spr.playAnim('static');
						spr.resetAnim = 0;
					}
					keyboardDisplay.released(i);
				}
			}
			// osu! 尾判: 按住超过尾端 + 安全区仍不松 → 按太久 miss (osu: 超过晚 miss 窗口仍按住 = miss)
			//if (ClientPrefs.data.osuTailJudgement && activeTailEnd.length > 0)
			//{
			//	for (i in 0...laneCount)
			//	{
			//		if (activeTailEnd[i] > 0 && holdArray[i]
			//			&& Conductor.songPosition > activeTailEnd[i] + Conductor.safeZoneOffset * tailWindowMult())
			//			tailMiss(i, activeTailEnd[i], Conductor.songPosition);
			//	}
			//}
			_keyAnyHeld = anyHeld;
			_keysCheckDepth--;
	}


	private function parseKeys(?suffix:String = ''):Array<Bool>
	{
		var ret:Array<Bool> = [];
		var laneCount:Int = Note.ammo[mania];
		for (i in 0...laneCount)
		{
			if (mania == Note.defaultMania && i < controlArray.length && controlArray[i] != null)
				ret[i] = Reflect.getProperty(controls, controlArray[i] + suffix);
			else
			{
				var val:Bool = false;
				if (i < keysArray.length)
				{
					var binds:Array<FlxKey> = keysArray[i];
					if (binds != null)
					{
						for (j in 0...binds.length)
						{
							if (FlxG.keys.checkStatus(binds[j], PRESSED)) val = true;
						}
					}
				}
				ret[i] = val;
			}
		}
		return ret;
	}

	function noteMiss(daNote:Note):Void { //You didn't hit the key and let it go offscreen, also used by Hurt Notes
			//Dupe note remove
		if (guitarHeroSustains) {
			if (daNote.parent == null) {

				if (daNote.missed) return;
				if (daNote.tail.length > 0) {
					for (childNote in daNote.tail) {
						childNote.alpha = daNote.alpha;
						childNote.missed = true;
						childNote.canBeHit = false;
						childNote.ignoreNote = true;
						childNote.tooLate = true;
						childNote.multAlpha = 0.3;
						childNote.alpha = 0.3;
					}
					daNote.missed = true;
					daNote.canBeHit = false;
				}
			} else if (daNote.parent != null && daNote.isSustainNote) {
				if (daNote.missed) return;
				var parentNote:Note = daNote.parent;
				if (parentNote.tail.length > 0) {
					for (child in parentNote.tail) {
						if (child != daNote) {
							child.missed = true;
							child.canBeHit = false;
							child.ignoreNote = true;
							child.tooLate = true;
							child.multAlpha = 0.3;
							child.alpha = 0.3;
						}
					}
					if (daNote == parentNote.tail[0]) {
						return;
					}
				}
			}
		}
		NoteMs.push(167);
		NoteTime.push(daNote.strumTime);
		notes.forEachAlive(function(note:Note) {
				if (daNote != note && daNote.mustPress && daNote.noteData == note.noteData && daNote.isSustainNote == note.isSustainNote && Math.abs(daNote.strumTime - note.strumTime) < 1) {
					recycleNote(note);
				}
			});
			combo = 0;
			if (playOpponent)
				health += daNote.missHealth * healthLoss;
			else
				health -= daNote.missHealth * healthLoss;
			msTxtKade.color = 0xFF0000;
			msTxtKade.text = 'Miss';
			msTxtKade.alpha = 1;
		if (msTween != null) msTween.cancel();
		msTween = FlxTween.tween(msTxtKade, {alpha: 0}, 0.5, {ease: FlxEase.quintIn});
			if(instakillOnMiss)
			{
				vocals.volume = 0;
				vocalsPlayer.volume = 0;
				doDeathCheck(true);
			}

			if (daNote != null && !daNote.isSustainNote)
			{
				NoteMs.push(167);
				NoteTime.push(daNote.strumTime);
			}
		//For testing purposes
		//trace(daNote.missHealth);
		songMisses++;
		if (!replayMode && replayExam != null)
			replayExam.recordJudgment(daNote.strumTime, daNote.noteData, 0, 'miss', daNote.isSustainNote);
		#if ONLINE_ALLOWED
		if (seiunOnline && !cpuControlled)
			OnlineSession.sendLocalJudge(daNote.strumTime, Std.int(Math.abs(daNote.noteData)), "shit", 0, daNote.isSustainNote,
				songScore, songMisses, maxcombo, ratingPercent, ratingName, ratingFC, 0, health);
		#end

		vocals.volume = 0;
		vocalsPlayer.volume = 0;
		if(!practiceMode) songScore -= 0;

		totalPlayed++;
		RecalculateRating(true);

		var char:Character = playOpponent ? dad : boyfriend;
		if(daNote.gfNote) {
			char = gf;
		}

		if(char != null && !daNote.noMissAnimation && char.hasMissAnimations)
		{
			var animToPlay:String = getSingAnim(daNote) + 'miss' + daNote.animSuffix;
			char.playAnim(animToPlay, true);
		}

		if (hasActiveScripts())
			callOnScripts('noteMiss', [noteIndexFast(daNote), daNote.noteData, daNote.noteType, daNote.isSustainNote]);
	}

	function noteMissPress(direction:Int = 1):Void //You pressed a key when there was no notes to press for this key
	{
		if(ClientPrefs.data.ghostTapping) return; //fuck it

		if (!boyfriend.stunned)
		{
			if (playOpponent)
				health += 0.05 * healthLoss;
			else
				health -= 0.05 * healthLoss;
			if(instakillOnMiss)
			{
				vocals.volume = 0;
				vocalsPlayer.volume = 0;
				doDeathCheck(true);
			}

			if (combo > 5 && gf != null && gf.animOffsets.exists('sad'))
			{
				gf.playAnim('sad');
			}
			combo = 0;

			if(!practiceMode) songScore -= 0;
			if(!endingSong) {
				songMisses++;
			}
			totalPlayed++;
			#if ONLINE_ALLOWED
			if (seiunOnline)
				wrongLaneTimes.push(Conductor.songPosition);
			#end
			RecalculateRating(true);

			FlxG.sound.play(Paths.soundRandom('missnote', 1, 3), FlxG.random.float(0.1, 0.2));
			// FlxG.sound.play(Paths.sound('missnote1'), 1, false);
			// FlxG.log.add('played imss note');

			/*boyfriend.stunned = true;

			// get stunned for 1/60 of a second, makes you able to
			new FlxTimer().start(1 / 60, function(tmr:FlxTimer)
			{
				boyfriend.stunned = false;
			});*/

            var missChar:Character = playOpponent ? dad : boyfriend;
            if(missChar.hasMissAnimations) {
                     missChar.playAnim(getSingAnimDir(direction) + 'miss', true);
            }
			vocals.volume = 0;
			vocalsPlayer.volume = 0;
		}
		if (hasActiveScripts())
			callOnScripts('noteMissPress', [direction]);
	}

	function opponentNoteHit(note:Note):Void
	{

		if (Paths.formatToSongPath(SONG.song) != 'tutorial')
			camZooming = true;

		// 对手侧降阶: sing 动画与 strum confirm 同样"每轨每帧一次" (对手轨道在
		// 万级 NPS 谱面下同样每帧数千次命中, 逐击 playAnim 是纯浪费)。
		var oppLane:Int = Std.int(Math.abs(note.noteData));
		var laneTotal:Int = Note.ammo[mania];
		if (oppLane >= laneTotal) oppLane %= laneTotal;
		var allowCharAnim:Bool = true;
		if (oppLane >= 0 && oppLane < _oppCharAnim.length)
		{
			allowCharAnim = !_oppCharAnim[oppLane];
			_oppCharAnim[oppLane] = true;
		}

        if(note.noteType == 'Hey!' && dad.animOffsets.exists('hey') && !playOpponent && allowCharAnim) {
            dad.playAnim('hey', true);
            dad.specialAnim = true;
            dad.heyTimer = 0.6;
		    } else if(note.noteType == 'Hey!' && boyfriend.animOffsets.exists('hey') && playOpponent && allowCharAnim) {
                boyfriend.playAnim('hey', true);
                boyfriend.specialAnim = true;
                boyfriend.heyTimer = 0.6;
                } else if(!note.noAnimation && allowCharAnim) {
                var altAnim:String = note.animSuffix;

                 if (SONG.notes[curSection] != null)
				 {
                    if (SONG.notes[curSection].altAnim && !SONG.notes[curSection].gfSection) {
                                        altAnim = '-alt';
                        }
                    }

            var char:Character = playOpponent ? boyfriend : dad;
            var animToPlay:String = getSingAnim(note) + altAnim;
            if(note.gfNote) {
                    char = gf;
        	}

            if(char != null)
            {
                char.playAnim(animToPlay, true);
                char.holdTimer = 0;
                    }
            }

		if (SONG.needsVoices && vocals.volume != 1)
			vocals.volume = 1;
			if (vocalsPlayer.volume != 1) vocalsPlayer.volume = 1;
			if (opponentVocals.volume != 1) opponentVocals.volume = 1;
		if (oppLane >= 0 && oppLane < _oppStrumConfirm.length && !_oppStrumConfirm[oppLane])
		{
			_oppStrumConfirm[oppLane] = true;
			var time:Float = 0.15;
			if(note.isSustainNote && !note.animation.curAnim.name.endsWith('end')) {
				time += 0.15;
			}
			StrumPlayAnim(true, Std.int(Math.abs(note.noteData)), time);
		}
		note.hitByOpponent = true;

if (CompatEngine.isModern() && hasActiveScripts()) {
			// 0.7.3+/1.0.4: opponentNoteHitPre / goodNoteHitPre 回调
			var preName:String = reverseNoteHit ? 'goodNoteHitPre' : 'opponentNoteHitPre';
			var preResult:Dynamic = callOnLuas(preName, [noteIndexFast(note), Math.abs(note.noteData), note.noteType, note.isSustainNote]);
			if(preResult != FunkinLua.Function_Stop && preResult != FunkinLua.Function_StopHScript && preResult != FunkinLua.Function_StopAll)
				callOnHScript(preName, [note]);
			if (CompatEngine.stopOnPreHitStop() && preResult == FunkinLua.Function_Stop)
			{
				return;
			}
		}

		if (hasActiveScripts())
		{
			var scriptName:String = reverseNoteHit ? 'goodNoteHit' : 'opponentNoteHit';
			var result:Dynamic;
			if (CompatEngine.isModern()) {
				// 0.7.3 格式: 与 opponentNoteHit 一致使用 Math.abs
				result = callOnLuas(scriptName, [noteIndexFast(note), Math.abs(note.noteData), note.noteType, note.isSustainNote]);
			} else if (reverseNoteHit) {
				// 0.6.3 格式, 但因 reverseNoteHit 实际调用了 goodNoteHit, 需传原始 noteData
				result = callOnLuas(scriptName, [noteIndexFast(note), note.noteData, note.noteType, note.isSustainNote]);
			} else {
				// 0.6.3 opponentNoteHit 本身使用 Math.abs
				result = callOnLuas(scriptName, [noteIndexFast(note), Math.abs(note.noteData), note.noteType, note.isSustainNote]);
			}
			if(result != FunkinLua.Function_Stop && result != FunkinLua.Function_StopHScript && result != FunkinLua.Function_StopAll) callOnHScript(scriptName, [note]);
		}
		if (!note.isSustainNote)
			recycleNote(note);
		if (!ClientPrefs.data.opponentfe) {
			// 对手侧降阶: 原实现每击把全部轨道 static 化一次 (万级 NPS 下 = 命中数×轨道数次
			// playAnim); 改为整帧一次, 同帧内重复设置不可见。
			if (!_oppStaticSet)
			{
				_oppStaticSet = true;
				for (i in 0...Note.ammo[mania]) {
				setOpponentStrumStatic(i);
				}
			}
		}
}
	function invalidateNote(daNote:Note):Void
	{
		recycleNote(daNote);
	}



	/** 击杀 Note 并回收到本 state 的 notePool；不 remove、不 destroy，members 保持有界。 */
	private function recycleNote(daNote:Note):Void
	{
		if (daNote == null || daNote.pooled) return;
		if (daNote.scale == null) return; // 已 destroy 的壳直接丢弃
		if (daNote.culled) { daNote.culled = false; if (_culledCount > 0) _culledCount--; }
		activeRemove(daNote);

		// Long-note pieces and hold heads are not pooled; destroying them keeps the
		// prev/next chain and clipping semantics identical to the original engine.
		if (daNote.isSustainNote || daNote.sustainLength > 0)
		{
			daNote.active = false;
			daNote.visible = false;
			daNote.kill();
			daNote.destroy();
			return;
		}

		var linkKey:Int = daNote.noteData + (daNote.mustPress ? 10000 : 0);
		daNote.active = false;
		daNote.visible = false;
		daNote.kill();
		if (daNote.resetForReuse())
		{
			// 简单 tap 回池后不再作为后续 Note 的 prevNote，避免复用后链到错误对象。
			if (lastSpawnedNote.get(linkKey) == daNote)
				lastSpawnedNote.remove(linkKey);
			daNote.pooled = true;
			notePool.push(daNote);
		}
	}

	/**
	 * 每帧重算离屏剔除距离 (世界像素):
	 * - 由接收器组与 HUD 相机的真实几何推导: 距最远接收器到屏幕上下边的余量
	 *   (再留 140px 给长条裁剪/offset 抖动)。被剔除的音符必然不可见。
	 * - 覆盖 HUD 相机缩放 (zoom<1 时可见世界范围更大)
	 * - 除以轨道滚动方向的 |sin|: 即使模组旋转了接收器也保证正确; 纯水平滚动放弃剔除。
	 *
	 * 同时推导可视物化地平线: "音符还能停多久才越过剔除边界"的毫秒数。
	 * 这是决定物化量的唯一闸门 ——
	 *   可视频段(ms) = 屏幕像素带 / (0.45 * songSpeed * maniaScale)
	 * speed=1 时约 3 秒, speed=0.5 时约 6 秒; 几十万 NPS 的谱面在这个窗口里
	 * 能塞进六位数条 Note。把物化窗口钉在真实像素带上, 物化量就由屏幕几何决定,
	 * 而不是由谱面密度决定 (再叠加 Turbo 的像素级折叠, 两者互相独立地兜底)。
	 */
	function refreshNoteCullRanges(elapsed:Float):Void
	{
		var zoom:Float = (camHUD != null && camHUD.zoom > 0 && camHUD.zoom < 32) ? camHUD.zoom : 1;
		var viewTop:Float = (camHUD != null) ? camHUD.scroll.y : 0;
		var viewBottom:Float = viewTop + FlxG.height / zoom;
		// 关键修复: 余量必须覆盖"帧量化超冲" —— 驻留/解除驻留的判定每帧只做一次,
		// 低帧率下一帧内音符会多走 帧时长×流速 像素, 固定 140px 余量会被直接冲过,
		// 音符/长条尾段在屏内闪现 (流速越大越深入屏幕)。余量随帧时长与流速放大。
		var quantizeMs:Float = Math.max(120.0, elapsed * 1000 * 1.5);
		var cullMargin:Float = 140 + 0.45 * songSpeed * quantizeMs;
		_cullDistPlayer = noteCullDistFor(playerStrums, viewTop, viewBottom, cullMargin);
		_cullDistOpponent = noteCullDistFor(opponentStrums, viewTop, viewBottom, cullMargin);

		// 可视物化地平线 (ms): 距离换算 px/ms = 0.45 * songSpeed * maniaScale
		// (与 updateDaNote 的位置公式同源)。用真实屏幕像素带 + 剔除余量, 余量本身
		// 已含帧量化超冲, 因此这个窗口里物化出来的音符一定能在屏内被看到,
		// 也一定能等到下一次更新的机会 —— 不会在屏内凭空出现。
		// 上限仍是 spawnTime (原版生成窗口), 下限防止极端值把窗口压成 0。
		var cullMin:Float = Math.min(_cullDistPlayer, _cullDistOpponent);
		var speedFactor:Float = 0.45 * songSpeed * Note.getManiaScale(mania);
		if (speedFactor <= 0.0001) speedFactor = 0.45;
		_visHorizonMs = Math.min(spawnTime, Math.max(120.0, (cullMin + cullMargin) / speedFactor));
	}

	/**
	 * 每轨 cos/sin 缓存: 音符位置 = strum + (cos,sin)(direction) * distance。
	 * direction 属于 strum (每轨常量), 原实现对每个音符每帧算两次 trig ——
	 * 屏内 ~3200 音符时是 ~6400 次/帧; 缓存后每轨每帧只算一次。
	 */
	function refreshLaneTrigCaches():Void
	{
		cacheLaneTrig(playerStrums, _playerLaneCos, _playerLaneSin);
		cacheLaneTrig(opponentStrums, _oppLaneCos, _oppLaneSin);
	}

	static function cacheLaneTrig(group:FlxTypedGroup<StrumNote>, cosOut:Array<Float>, sinOut:Array<Float>):Void
	{
		var members:Array<StrumNote> = group.members;
		var len:Int = members.length;
		if (cosOut.length < len) cosOut.resize(len);
		if (sinOut.length < len) sinOut.resize(len);
		for (i in 0...len)
		{
			var st:StrumNote = members[i];
			if (st == null) continue;
			var rad:Float = st.direction * Math.PI / 180;
			cosOut[i] = Math.cos(rad);
			sinOut[i] = Math.sin(rad);
		}
	}

	/** 存活列表 O(1) 移除 (swap-remove; 尾元素补位并修正其下标)。 */
	function activeRemove(n:Note):Void
	{
		var i:Int = n.activeIdx;
		if (i < 0 || i >= activeNotes.length || activeNotes[i] != n)
			return;
		var last:Note = activeNotes[activeNotes.length - 1];
		activeNotes.pop();
		if (last != n)
		{
			activeNotes[i] = last;
			last.activeIdx = i;
		}
		n.activeIdx = -1;
	}

	/** 重置 botplay/对手侧"每轨每帧一次"门控数组 (与 strumsHit 同步, 大小随 k 值调整)。 */
	function resetBotGateArrays():Void
	{
		var laneCount:Int = Note.ammo[mania] * 2;
		if (_botCharAnim.length != laneCount)
			_botCharAnim = [for (i in 0...laneCount) false];
		else
			for (i in 0...laneCount) _botCharAnim[i] = false;

		if (_botStrumStatic.length != laneCount)
			_botStrumStatic = [for (i in 0...laneCount) false];
		else
			for (i in 0...laneCount) _botStrumStatic[i] = false;

		if (_oppCharAnim.length != laneCount)
			_oppCharAnim = [for (i in 0...laneCount) false];
		else
			for (i in 0...laneCount) _oppCharAnim[i] = false;

		if (_oppStrumConfirm.length != laneCount)
			_oppStrumConfirm = [for (i in 0...laneCount) false];
		else
			for (i in 0...laneCount) _oppStrumConfirm[i] = false;

		_oppStaticSet = false;
	}

	/**
	 * O(1) 读取 Note 在 notes.members 的下标 (脚本回调参数用), 替代每击
	 * notes.members.indexOf 的 O(n) 全表扫描 —— 万级成员 × 上万命中/帧 时是秒级开销。
	 * 下标由 appendNoteFast/fasterNoteSort/压缩清理增量维护; 校验失败 (脚本/外部
	 * 直接改过 members) 时回退一次 indexOf 并自愈缓存。
	 */
	function noteIndexFast(note:Note):Int
	{
		if (note == null) return -1;
		var m:Array<Note> = notes.members;
		var idx:Int = note.memberIndex;
		if (idx >= 0 && idx < m.length && m[idx] == note)
		{
			return idx;
		}
		idx = m.indexOf(note);
		if (idx >= 0) note.memberIndex = idx;
		return idx;
	}

	/** 全量重建 memberIndex 缓存 (notes.sort 等整体重排路径后调用, 单趟 O(n))。 */
	static function rebuildMemberIndexes(m:Array<Note>, len:Int):Void
	{
		for (i in 0...len)
		{
			var n:Note = m[i];
			if (n != null) n.memberIndex = i;
		}
	}

	/**
	 * O(1) 均摊追加 Note 到 notes 组, 槽位选择与 FlxTypedGroup.add 一致
	 * (优先填第一个空洞, 否则尾部追加)。add() 内部的 members.indexOf 去重检查
	 * 与 getFirstNull 都是 O(n): 万级成员 + 密集生成时每帧浪费数十毫秒。
	 * 仅用于本 state 的延迟物化路径 (同一 Note 绝不会重复添加)。
	 */
	@:privateAccess
	function appendNoteFast(note:Note):Void
	{
		var m:Array<Note> = notes.members;
		var len:Int = m.length;

		// 从游标向后找第一个空洞
		var idx:Int = _noteSlotCursor;
		while (idx < len && m[idx] != null) idx++;

		if (idx >= len)
		{
			// 游标之前可能有清理产生的空洞, 补扫前段
			idx = 0;
			while (idx < _noteSlotCursor && idx < len && m[idx] != null) idx++;
		}

		if (idx < len)
		{
			m[idx] = note;
			note.memberIndex = idx;
			if (idx >= notes.length)
				notes.length = idx + 1;
			_noteSlotCursor = idx + 1;
			return;
		}

		if (notes.maxSize > 0 && notes.length >= notes.maxSize)
			return; // 组已满: 与 add() 行为一致, 丢弃

		m.push(note);
		note.memberIndex = m.length - 1;
		notes.length++;
		_noteSlotCursor = m.length;
	}

	static function noteCullDistFor(group:FlxTypedGroup<StrumNote>, viewTop:Float, viewBottom:Float, margin:Float):Float
	{
		var minY:Float = 1e9;
		var maxY:Float = -1e9;
		var members:Array<StrumNote> = group.members;
		for (i in 0...members.length)
		{
			var st:StrumNote = members[i];
			if (st == null) continue;
			if (st.y < minY) minY = st.y;
			if (st.y > maxY) maxY = st.y;
		}
		if (minY > maxY) return 2200; // 接收器未就绪: 保守默认值

		var below:Float = viewBottom - maxY + margin; // 向屏幕下方还能滚多远
		var above:Float = minY - viewTop + margin;    // 向屏幕上方还能滚多远
		var dist:Float = (below > above) ? below : above;

		// 旋转/异形轨道: 按 |sin(滚动角)| 收紧阈值, 保证 "距离超限 ⇒ 必然出屏"
		var s0:StrumNote = members[0];
		var sinY:Float = (s0 == null) ? 1 : Math.abs(Math.sin(s0.direction * Math.PI / 180));
		return (sinY < 0.35) ? 1e12 : dist / sinY;
	}

	/** H-Slice style fasterSort: only alive+visible notes participate in the Y sort; dead slots keep their positions. */
	/**
	 * Note 绘制顺序比较器 (签名匹配 FlxTypedGroup.sort 的 Function.bind(Order) 约定)。
	 * 分层规则: 长条段永远先画 (下层), TAP 后画 (上层), 同层内再按 y 排序
	 * (靠近判定线者在顶)。
	 * 背景: downscroll 的 Y 排序 (ASCENDING, y 大者后画) 会让长条段 (y 比 tap 大)
	 * 盖住自己的 tap —— 本引擎段高致密 (自带 2px 重叠, 是原版段高的 1.43 倍),
	 * tap 矩形与前几段大量重叠, 0.6 透明度的段压在箭头上, 表现为
	 * "tap 被卡在长条中间 / 被压到最后"。原版没暴露是因为原版段很短,
	 * 与 tap 的重叠可忽略。长条段必须与 tap 重叠才能衔接, 所以只能在
	 * 绘制顺序上保证 tap 可见。
	 */
	public static function noteDrawOrder(order:Int, a:Note, b:Note):Int
	{
		final la:Bool = a.isSustainNote;
		final lb:Bool = b.isSustainNote;
		if (la != lb) return la ? -1 : 1;
		return FlxSort.byY(order, a, b);
	}

	private function fasterNoteSort(order:Int):Void
	{
		_noteSortRange = 0;
		var members = notes.members;
		for (i in 0...members.length)
		{
			var n:Note = members[i];
			if (n != null && n.exists && n.visible)
			{
				if (_noteSortArr.length <= _noteSortRange)
					_noteSortArr.push(n);
				else
					_noteSortArr[_noteSortRange] = n;
				if (_noteSortIdx.length <= _noteSortRange)
					_noteSortIdx.push(i);
				else
					_noteSortIdx[_noteSortRange] = i;
				_noteSortRange++;
			}
		}

		if (_noteSortArr.length > _noteSortRange)
		{
			_noteSortArr.resize(_noteSortRange);
			_noteSortIdx.resize(_noteSortRange);
		}

		if (_noteSortRange > 1)
		{
			// 比较器闭包只创建一次 (原实现每帧两个 lambda 分配, 高帧率下是稳定的 GC 压力源);
			// 排序方向在比较器内部实时读取, 与外部 order 参数保持一致。
			if (_cmpNoteY == null)
				_cmpNoteY = function(a:Note, b:Note):Int {
					return noteDrawOrder(ClientPrefs.data.downScroll ? FlxSort.ASCENDING : FlxSort.DESCENDING, a, b);
				};
			if (_cmpIntAsc == null)
				_cmpIntAsc = function(a:Int, b:Int):Int { return a - b; };
			_noteSortArr.sort(_cmpNoteY);
			_noteSortIdx.sort(_cmpIntAsc);
			for (k in 0..._noteSortRange)
			{
				members[_noteSortIdx[k]] = _noteSortArr[k];
				// 同步维护 memberIndex 缓存 (排序重排是缓存失效的主要来源)
				_noteSortArr[k].memberIndex = _noteSortIdx[k];
			}
		}
	}

	/** Per-alive-note update hook (method reference, avoids allocating a closure every frame). */
	private function updateDaNote(daNote:Note):Void
	{
		if (daNote == null || !daNote.exists) return;

		_frameAliveTally++;

		// H-Slice 风格离屏剔除: 音符 y 完全由 strumTime 线性派生, 远离屏幕的音符
		// 无需逐帧三角函数/裁剪/绘制 (visible=false 让 group.draw 直接跳过)。
		// 只对位置完全由引擎派生 (copyX&&copyY) 的音符生效; 已过击杀窗口的音符
		// 永不驻留 —— 它们必须走正常 miss/kill 流程。
		// perfMode 关闭时完全不剔除，保持提交前“所有 alive Note 都参与更新/绘制”的逻辑。
		if (ClientPrefs.data.perfMode)
		{
			if (daNote.copyX && daNote.copyY && !daNote.inEditor)
			{
				if (!(Conductor.songPosition > noteKillOffset + daNote.strumTime))
				{
					var distPx:Float = Conductor.songPosition - daNote.strumTime;
					if (distPx < 0) distPx = -distPx;
					distPx *= 0.45 * songSpeed * daNote.multSpeed * Note.getManiaScale(daNote.mania);
					if (distPx > (daNote.mustPress ? _cullDistPlayer : _cullDistOpponent))
					{
						if (!daNote.culled)
						{
							daNote.culled = true;
							daNote.visible = false;
							daNote.active = false;
							_culledCount++;
						}
						return;
					}
				}
			}
		}
		// 如果从 perfMode 开启切回关闭，或既有 culled 标记需要恢复，统一在这里解除驻留。
		if (daNote.culled)
		{
			daNote.culled = false;
			daNote.visible = true;
			daNote.active = true;
			_culledCount--;
		}

		// Auto-hit opponent notes
		if (!daNote.mustPress && !daNote.hitByOpponent && !daNote.ignoreNote && daNote.strumTime <= Conductor.songPosition)
			opponentNoteHit(daNote);

		// CPU auto-hit player notes
		if (daNote.mustPress && cpuControlled && !daNote.wasGoodHit && daNote.strumTime <= Conductor.songPosition && !daNote.ignoreNote && !daNote.blockHit)
			goodNoteHit(daNote);

		if (!daNote.exists) return;

		var strumGroup:FlxTypedGroup<StrumNote> = daNote.mustPress ? playerStrums : opponentStrums;
		var strumIdx:Int = Std.int(Math.abs(daNote.noteData));
		if (strumIdx >= strumGroup.members.length) strumIdx %= strumGroup.members.length;
		var strum:StrumNote = strumGroup.members[strumIdx];
		if (strum == null) return;

		var strumX:Float = strum.x + daNote.offsetX;
		var strumY:Float = strum.y + daNote.offsetY;
		var strumAngle:Float = strum.angle + daNote.offsetAngle;
		var strumDirection:Float = strum.direction;
		var strumAlpha:Float = strum.alpha * daNote.multAlpha;
		var strumScroll:Bool = strum.downScroll;

		if (strumScroll)
			daNote.distance = (0.45 * (Conductor.songPosition - daNote.strumTime) * songSpeed * daNote.multSpeed) * Note.getManiaScale(daNote.mania);
		else
			daNote.distance = (-0.45 * (Conductor.songPosition - daNote.strumTime) * songSpeed * daNote.multSpeed) * Note.getManiaScale(daNote.mania);

		// 每轨 cos/sin 缓存 (refreshLaneTrigCaches 每帧刷新); 缓存未覆盖时回退实时计算。
		var angleDir:Float = strumDirection * Math.PI / 180;
		var cosDir:Float = Math.cos(angleDir);
		var sinDir:Float = Math.sin(angleDir);
		if (ClientPrefs.data.perfMode)
		{
			var cosArr:Array<Float> = daNote.mustPress ? _playerLaneCos : _oppLaneCos;
			var sinArr:Array<Float> = daNote.mustPress ? _playerLaneSin : _oppLaneSin;
			if (strumIdx < cosArr.length && strumIdx < sinArr.length)
			{
				cosDir = cosArr[strumIdx];
				sinDir = sinArr[strumIdx];
			}
		}

		if (daNote.copyAngle)
			daNote.angle = strumDirection - 90 + strumAngle;

		if (daNote.copyAlpha)
			daNote.alpha = strumAlpha;

		if (daNote.copyX)
			daNote.x = strumX + cosDir * daNote.distance;

				if (daNote.copyY)
		{
			daNote.y = strumY + sinDir * daNote.distance;

			if (daNote.isSustainNote && strumScroll)
			{
				var maniaScale:Float = Note.getManiaScale(daNote.mania);

				if (PlayState.isPixelStage)
				{
					// 像素阶段：保留 0.6.3 原修正，本次不改动，避免像素回归。
					var fakeCrochet:Float = (60 / PlayState.SONG.bpm) * 1000;
					var isEnd:Bool = (daNote.animation.curAnim != null
						&& (daNote.animation.curAnim.name.endsWith('end') || daNote.animation.curAnim.name.endsWith('holdend')));
					if (isEnd)
					{
						daNote.y += (10.5 * (fakeCrochet / 400) * 1.5 * songSpeed + (46 * (songSpeed - 1))) * maniaScale;
						daNote.y -= (46 * (1 - (fakeCrochet / 600)) * songSpeed) * maniaScale;
						daNote.y += (8 + (6 - daNote.originalHeightForCalcs) * PlayState.daPixelZoom) * maniaScale;
					}
					daNote.y += ((Note.swagWidth / 2) - (60.5 * (songSpeed - 1))) * maniaScale;
					daNote.y += (27.5 * ((PlayState.SONG.bpm / 100) - 1) * (songSpeed - 1)) * maniaScale;
				}
				else
				{
					//操你妈的傻逼，怎么又让我修一遍？
					var stepCrochet:Float = (daNote.genStepCrochet > 0) ? daNote.genStepCrochet : Conductor.stepCrochet;
					var anchor:Float = (Note.swagWidth / 2) * maniaScale
						+ 0.45 * stepCrochet * daNote.multSpeed * maniaScale
						- daNote.height;
					var contentOffsetY:Float = (daNote.frame != null) ? daNote.frame.offset.y * daNote.scale.y : 0.0;
					daNote.y += anchor - contentOffsetY;
				}
			}
		}

		var center:Float = strumY + (Note.swagWidth / 2) * Note.getManiaScale(daNote.mania);
		if (strum.sustainReduce && daNote.isSustainNote
			&& (!daNote.mustPress || daNote.wasGoodHit))
		{
			var drawnTop:Float = daNote.y - daNote.offset.y + daNote.origin.y * (1 - daNote.scale.y)
				+ daNote.frame.offset.y * daNote.scale.y;
			var drawnBottom:Float = drawnTop + daNote.height;
			var swagRect:FlxRect = daNote.clipRect;
			if (swagRect == null)
				swagRect = new FlxRect(0, 0, daNote.frameWidth, daNote.frameHeight);
			swagRect.x = 0;
			swagRect.width = daNote.frameWidth;
			if (strumScroll)
			{
				if (drawnBottom >= center)
				{
					swagRect.height = (center - drawnTop) / daNote.scale.y;
					swagRect.y = daNote.frameHeight - swagRect.height;
					daNote.clipRect = swagRect;
				}
			}
			else
			{
				if (drawnTop <= center)
				{
					swagRect.y = (center - drawnTop) / daNote.scale.y;
					swagRect.height = daNote.frameHeight - swagRect.y;
					daNote.clipRect = swagRect;
				}
			}
		}

		// Kill late notes
		if (Conductor.songPosition > noteKillOffset + daNote.strumTime)
		{
			if (daNote.mustPress && !cpuControlled && !daNote.ignoreNote && !endingSong && !daNote.wasGoodHit)
				noteMiss(daNote);

			invalidateNote(daNote);
		}
	}

	/** Countdown light reset hook (method reference). */
	private function resetNote(daNote:Note):Void
	{
		_frameAliveTally++;
		daNote.canBeHit = false;
		daNote.wasGoodHit = false;
	}

	/**
	 * H-Slice 风格数据级批量推进 —— 万级 NPS 的结构性降阶。
	 *
	 * 核心思想: 音符密度超过"逐对象处理"能力时, 把到点/过期的未物化音符在数据层
	 * 直接结算 (PreloadedChartNote.wasHit = true), 不再为它们构造精灵。
	 * 结算口径与逐击路径一致 (combo/maxcombo/totalPlayed/totalNotesHit/判定计数/血量);
	 * 表现层合并到帧末或按轨去重。
	 *
	 * 两层 cutoff:
	 * - softCut (= songPosition, 仅 botplay): 已到点的未物化 tap 音符按自动命中在
	 *   数据层结算。帧率健康时光标跑在演唱位置前面 (~2s 提前物化), 此层无事可做;
	 *   帧率跟不上到达速率时光标落后, 溢出部分在这里被吸收 —— 打破"越卡越积、
	 *   越积越卡"的死亡螺旋。
	 * - hardCut (= songPosition - noteKillOffset): 过期音符 drain (原行为)。
	 *
	 * 含长条的谱面不再整体禁用: 扫描在第一条未结算长条处停下 (长条仍走逐对象路径,
	 * 保留尾段/裁剪语义); 其后的 tap 在长条解决后继续 drain。
	 *
	 * 门控: 无 Lua/HScript、非回放、非联机 (脚本语义保持逐字节不变)。
	 */
	function fastSkipPastNotes(elapsed:Float):Void
	{
		if (!ClientPrefs.data.perfMode || !ClientPrefs.data.bulkSkip) { _bulkDrainedLast = 0; return; }
		if ((hasActiveScripts() && !turboModeActive) || replayMode || seiunOnline || endingSong) { _bulkDrainedLast = 0; return; }
		if (notesAddedCount >= unspawnNotes.length) { _bulkDrainedLast = 0; return; }

		var pos:Float = Conductor.songPosition;
		var hardCut:Float = pos - noteKillOffset;
		// 关键修复: 原写法 "-Math.NEGATIVE_INFINITY" 是正无穷 —— 手动模式下 softCut
		// 变 +∞, 扫描永不停且 "strumTime <= softCut" 对所有未生成音符恒真,
		// 全部被数据层提前自动命中 (combo/回血/strum confirm 全触发), 即
		// "没开 botplay 却部分 Note 自己按下且提前" 的根因。禁用 softCut 应取 -∞。
		var softCut:Float = cpuControlled ? pos : Math.NEGATIVE_INFINITY;
		// 过载 (上一帧 drain 显著非零) 时把数据层结算线推进到可视带内沿:
		// 物化预算不足时, 近半带的音符只会在判定线附近闪现一帧就被回收,
		// 与其白付构造费不如直接数据层结算; 物化因此集中到外半带 ——
		// 每个精灵存活整个下落过程 (多帧可见), 视觉变成连续稀疏流而非贴线闪烁。
		// (结算口径不变: 该自动命中的照常计入 combo/判定/血量, 只是提前几毫秒。
		//  Turbo 的像素级折叠已把物化量按屏幕几何定量约束, 这里不再需要
		//  "高密度聚合区"之类的特例分支。)
		if (cpuControlled && _overloadFrames > 0)
			softCut = pos + _visHorizonMs * 0.5;
		var drainTotal:Int = 0;

		// 累加器由"帧末消费点"归零 (finishBulkFrame -> resetBulkAccumulator):
		// 物化路径在 fastSkipPastNotes 之前就把折叠组结算进同一个累加器,
		// 这里必须沿用它的内容, 否则同帧的命中会漏进表现层。
		var acc:BulkAccumulator = _bulkAcc;

		// Turbo 模式专用自适应每帧预算: 约 100 条/ms 帧时间, 上限 65536。
		// 70k NPS 在 60fps 约 1167 条/帧, 这个预算既跟得上极密尾杀,
		// 又避免单帧一次性 drain 数万条造成尖峰; 低配帧率下自动放大追补。
		// 非 Turbo 模式保持原版一次性 drain 行为 (关闭 Turbo 时行为不变)。
		// 折叠组按"组"计一次预算: 组内成员是同一像素带里的重叠 Note,
		// 与旧实现消费折叠组时的口径一致。
		var drainBudget:Int = turboModeActive ? Std.int(Math.max(4096, Math.min(65536, elapsed * 1000 * 100))) : 0x7FFFFFFF;
		var processed:Int = 0;

		while (notesAddedCount < unspawnNotes.length)
		{
			if (processed >= drainBudget)
				break;
			processed++;

			var d:PreloadedChartNote = unspawnNotes[notesAddedCount];
			if (d.strumTime > hardCut && d.strumTime > softCut) break;
			// 长条与长条头 (isSustainNote=false 但 sustainLength>0) 都留给逐对象路径:
			// 头被数据层消费会让尾段失去 prevNote/parent 链, 破坏长条渲染。
			if (d.isSustainNote || d.sustainLength > 0) break;

			if (d.wasHit)
			{
				notesAddedCount++;
				continue;
			}

			// 数据层结算 (含 Turbo 折叠组的一次性展开)。未到点/非玩家/长条一律
			// 返回 false 且保持游标不动 —— 这里也是唯一能推进结算游标的路径,
			// 任何"提前消费却不推进游标"的分支都会把后续 Note 永久卡死。
			if (!bulkSettleNote(d, acc))
				break;
			drainTotal++;
			notesAddedCount++;
		}

		_bulkDrainedLast = drainTotal;
		if (acc.drainedHit > 0 || acc.skippedHit > 0 || acc.skippedMiss > 0 || bulkHurtCount > 0 || acc.oppDrained > 0)
			finishBulkFrame(acc.drainedHit, acc.skippedHit, acc.skippedHitHealth, acc.skippedMiss, acc.skippedMissHealth, acc.oppDrained);
	}

	/** 每帧重置 Turbo 运行时归属闸门 (每条 lane+side 一份"上一条已物化"记录)。 */
	function resetTurboKeepGate():Void
	{
		var slots:Int = Note.ammo[mania] * 2;
		if (_laneLastKeptTime.length != slots)
		{
			_laneLastKeptTime = [for (i in 0...slots) -1e30];
			_laneLastKeptRate = [for (i in 0...slots) 0.0];
			_laneLastKeptSlow = [for (i in 0...slots) 0.0];
		}
		else
		{
			for (i in 0...slots)
			{
				_laneLastKeptTime[i] = -1e30;
				_laneLastKeptRate[i] = 0.0;
				_laneLastKeptSlow[i] = 0.0;
			}
		}
	}

	/**
	 * Turbo 运行时归属闸门: 判断这条 tap 是否值得为它构造精灵。
	 *
	 * 判据与加载期折叠一致 (同 lane + 同侧 + 同 multSpeed, 屏幕像素间距小于阈值),
	 * 但用的是**当前** songSpeed: 加载期折叠用的是进入歌曲时的流速, 若运行中
	 * songSpeed 被事件/缓动改写, 折叠结果就不再匹配, 这道闸门保证物化量仍然有界。
	 *
	 * 返回 false 表示"屏幕上与上一条已物化 Note 完全重叠", 调用方应直接数据层结算。
	 * 长条/长条头一律放行 (尾段链与裁剪语义不允许被跳过)。
	 */
	function turboKeepNote(pn:PreloadedChartNote):Bool
	{
		if (pn.isSustainNote || pn.sustainLength > 0)
			return true;

		var laneTotal:Int = Note.ammo[mania];
		var lane:Int = Std.int(Math.abs(pn.noteData));
		if (lane >= laneTotal)
			lane = lane % laneTotal;
		var idx:Int = (pn.mustPress ? 1 : 0) * laneTotal + lane;
		if (idx < 0 || idx >= _laneLastKeptTime.length)
			return true;

		var maniaScale:Float = Note.getManiaScale(mania);
		if (!Math.isFinite(maniaScale) || maniaScale <= 0)
			maniaScale = 1.0;
		var rate:Float = 0.45 * songSpeed * maniaScale * (pn.multSpeed > 0 ? pn.multSpeed : 1.0);

		var keep:Bool = true;
		if (_laneLastKeptSlow[idx] > 0)
		{
			var dt:Float = pn.strumTime - _laneLastKeptTime[idx];
			// 以较慢的那条为准 (lastSlow): 保证"两条 Note 在任何时刻都不会分开到
			// 可分辨程度"这个结论对 multSpeed 不同的音符同样成立。
			if (dt >= 0 && dt * _laneLastKeptSlow[idx] < TURBO_KEEP_GAP_PX)
				keep = false;
		}

		if (keep)
		{
			// 速率不变时保持取较小值; 速率变了就重新以当前速率为准。
			var prevRate:Float = _laneLastKeptRate[idx];
			var slow:Float = (prevRate == rate && _laneLastKeptSlow[idx] < rate) ? _laneLastKeptSlow[idx] : rate;
			_laneLastKeptTime[idx] = pn.strumTime;
			_laneLastKeptRate[idx] = rate;
			_laneLastKeptSlow[idx] = slow;
		}
		return keep;
	}

	/**
	 * 数据层结算一条未物化 Note, 不构造精灵。
	 *
	 * Turbo 折叠后一条代表 Note 代表 noteDensity 条原始 tap (屏幕像素间距小于阈值,
	 * 任何时刻都互相重叠)。它们必须在同一时刻一起结算:
	 *   - 少结算 -> 命中数与 totalPlayed 对不上, 命中率/评级算错;
	 *   - 分帧结算 -> 同一像素带里的音符会把 combo 拆成好几段。
	 * 因此这里一次性展开整组, 并按"组"计一次每帧预算。
	 *
	 * @return 是否结算成功 (调用方可以推进游标)。
	 */
	function bulkSettleNote(d:PreloadedChartNote, acc:BulkAccumulator):Bool
	{
		if (d == null || d.wasHit)
			return false;
		// 长条/长条头: 逐对象路径专有 (尾段链与裁剪语义)。
		if (d.isSustainNote || d.sustainLength > 0)
			return false;

		var pos:Float = Conductor.songPosition;
		var onTime:Bool = d.strumTime <= pos;

		var den:Int = Std.int(Math.max(1, Math.round(d.noteDensity)));

		if (!d.mustPress)
		{
			d.wasHit = true;
			acc.oppDrained += den;
			// 到点的对手音符补一次表现门控, 与原逐对象路径一致。
			if (onTime) gateOppLaneAnim(laneOf(d.noteData));
			return true;
		}

		if (onTime)
		{
			d.wasHit = true;
			if (d.blockHit)
			{
				// 卡键音符从不参与判定: 静默消费 (与原路径最终效果一致)
			}
			else if (d.ignoreNote)
			{
				// botplay 下原路径仅触发脚本 (此处无脚本): 静默消费
			}
			else if (d.hitCausesMiss)
			{
				bulkHurtCount += den;
				combo = 0;
				if (playOpponent)
					health += d.missHealth * healthLoss * den;
				else
					health -= d.missHealth * healthLoss * den;
				songMisses += den;
				totalPlayed += den;
			}
			else
			{
				acc.drainedHit += den;
				combo += den;
				if (combo > maxcombo) maxcombo = combo;
				totalPlayed += den;
				songHits += den;
				notehitlol += den; // HUD 总命中数口径与 totalPlayed 同源
				totalNotesHit += den; // botplay 判定恒为 ratingsData[0], ratingMod=1
				if (ClientPrefs.data.marvelousRatings)
					marvelouses += den;
				else
					sicks += den;
				if (playOpponent)
					health -= d.hitHealth * healthGain * den;
				else
					health += d.hitHealth * healthGain * den;
				gateBotLaneAnim(laneOf(d.noteData));
			}
			return true;
		}

		// 尚未到点: 只有 botplay 的玩家 tap 可以在数据层提前自动命中
		// (等价旧实现 cpuControlled 的 skippedHit 分支)。手动模式返回 false,
		// 保持"外轨音符不被提前结算"的原语义。
		if (!cpuControlled)
			return false;

		d.wasHit = true;
		if (!d.ignoreNote && !d.blockHit)
		{
			acc.skippedHit += den;
			acc.skippedHitHealth += d.hitHealth * den;
		}
		return true;
	}

	inline function laneOf(noteData:Int):Int
	{
		var lane:Int = Std.int(Math.abs(noteData));
		var laneTotal:Int = Note.ammo[mania];
		return (lane >= laneTotal) ? lane % laneTotal : lane;
	}

	/** botplay 到点对手音符的表现门控 (sing/confirm 动画, 每轨每帧一次)。 */
	function gateOppLaneAnim(lane:Int, allowAnim:Bool = true):Void
	{
		camZooming = true;
		if (SONG.needsVoices && vocals.volume != 1) vocals.volume = 1;
		if (vocalsPlayer.volume != 1) vocalsPlayer.volume = 1;
		if (opponentVocals.volume != 1) opponentVocals.volume = 1;
		var oIdx:Int = lane + Note.ammo[mania];
		if (oIdx < 0 || oIdx >= _oppCharAnim.length) return;
		if (!_oppCharAnim[oIdx])
		{
			_oppCharAnim[oIdx] = true;
			var char:Character = playOpponent ? boyfriend : dad;
			if (char != null && allowAnim)
				char.playAnim(getSingAnimDir(lane), true);
		}
		if (lane < _oppStrumConfirm.length && !_oppStrumConfirm[lane])
		{
			_oppStrumConfirm[lane] = true;
			StrumPlayAnim(true, lane, 0.15);
		}
	}

	/**
	 * botplay 到点命中的轨道表现门控: 角色 sing 动画 + 玩家侧 strum confirm,
	 * 均为每轨每帧一次 —— 与逐击路径的表现完全一致。
	 */
	function gateBotLaneAnim(lane:Int):Void
	{
		// strum confirm (与逐击路径的 strumsHit 门控同口径, 保证击中特效不丢)
		var shIdx:Int = lane + Note.ammo[mania];
		if (shIdx >= 0 && shIdx < strumsHit.length && !strumsHit[shIdx])
		{
			strumsHit[shIdx] = true;
			StrumPlayAnim(false, lane, calculateResetTime());
		}

		var aIdx:Int = shIdx;
		if (aIdx < 0 || aIdx >= _botCharAnim.length) return;
		if (_botCharAnim[aIdx]) return;
		_botCharAnim[aIdx] = true;
		var playChar:Character = playOpponent ? dad : boyfriend;
		playChar.playAnim(getSingAnimDir(lane), true);
		playChar.holdTimer = 0;
	}

	/**
	 * 已物化音符的到点批量命中 (仅 botplay): 把逐击 goodNoteHit 的调用链
	 * (judgeNote/popUpScore/RecalculateRating/回收) 合并为一次聚合 + O(存活数)
	 * 的单趟扫描。结算口径与逐击路径一致; 长条/长条头仍走原路径 (裁剪/尾段语义)。
	 * 视觉等价: 音符在判定线处消失的时机不变, 轨道动画保持每轨每帧一次。
	 */
	function bulkHitDueMaterialized():Void
	{
		if (!ClientPrefs.data.perfMode || !cpuControlled || replayMode || seiunOnline || (hasActiveScripts() && !turboModeActive)) return;

		var pos:Float = Conductor.songPosition;
		var hitCount:Int = 0;
		var hurtCount:Int = 0;
		var oppCount:Int = 0;

		// 遍历存活紧凑列表; recycleNote 会 swap-remove 当前元素并把尾元素补位到
		// 当前下标 —— 未处理的新元素需要原地复查, 因此只在"长度未变"时前进。
		var i:Int = 0;
		while (i < activeNotes.length)
		{
			var n:Note = activeNotes[i];
			var lenBefore:Int = activeNotes.length;
			var removed:Bool = false;

			{
				if (n == null || n.pooled || !n.exists)
				{
					// 幽灵槽位: 不可能出现在活跃列表, 防御性跳过
				}
				else if (n.isSustainNote || n.sustainLength > 0)
				{
					// 长条与长条头走逐对象路径 (裁剪/尾段链语义)
					removed = false;
				}
				else if (n.strumTime <= pos && !n.wasGoodHit && !n.hitByOpponent)
				{
					if (n.mustPress)
					{
						var den:Int = Std.int(Math.max(1, Math.round(n.noteDensity)));
						if (n.blockHit || n.ignoreNote)
						{
							recycleNote(n); // 从不参与判定的音符: 直接回收
							removed = true;
						}
						else if (n.hitCausesMiss)
						{
							hurtCount += den;
							combo = 0;
							if (playOpponent)
								health += n.missHealth * healthLoss * den;
							else
								health -= n.missHealth * healthLoss * den;
							songMisses += den;
							totalPlayed += den;
							recycleNote(n);
							removed = true;
						}
						else
						{
							hitCount += den;
							combo += den;
							if (combo > maxcombo) maxcombo = combo;
							totalPlayed += den;
							songHits += den;
							notehitlol += den; // HUD 总命中数口径同源
							totalNotesHit += den; // botplay 判定恒为 ratingsData[0], ratingMod=1
							if (ClientPrefs.data.marvelousRatings)
								marvelouses += den;
							else
								sicks += den;
							if (playOpponent)
								health -= n.hitHealth * healthGain * den;
							else
								health += n.hitHealth * healthGain * den;
							var nMania:Int = (n.mania >= 0) ? n.mania : mania;
							gateBotLaneAnim(Std.int(Math.abs(n.noteData)) % Note.ammo[nMania]);
							recycleNote(n);
							removed = true;
						}
					}
					else
					{
						// 对手到点: opponentNoteHit 的表现门控 + 回收
						oppCount++;
						camZooming = true;
						if (SONG.needsVoices && vocals.volume != 1) vocals.volume = 1;
						if (vocalsPlayer.volume != 1) vocalsPlayer.volume = 1;
						if (opponentVocals.volume != 1) opponentVocals.volume = 1;
						gateOppLaneAnim(laneOf(n.noteData), !n.noAnimation);
						recycleNote(n);
						removed = true;
					}
				}
			}

			if (!removed && activeNotes.length == lenBefore)
				i++;
			// removed 或长度变化: 尾元素已补位到当前下标, 原地下标复查
		}

		if (hitCount > 0)
		{
			if (SONG.needsVoices && vocals.volume != 1) vocals.volume = 1;
			if (vocalsPlayer.volume != 1) vocalsPlayer.volume = 1;
			if (opponentVocals.volume != 1) opponentVocals.volume = 1;
			_popupPending = true;
			var r:Rating = (ratingsData.length > 0) ? ratingsData[0] : null;
			_pendingRatingImage = (r != null) ? r.image : 'sick';
			RecalculateRating(false);
		}
		if (hurtCount > 0)
		{
			vocals.volume = 0; vocalsPlayer.volume = 0;
			_msTextDirty = true;
			_pendingMsText = 'Miss';
			_pendingMsColor = 0xFF0000;
			RecalculateRating(true);
			if (instakillOnMiss) doDeathCheck(true);
		}
	}

	/**
	 * 本帧数据级批量结算收尾: 统一一次 RecalculateRating / 弹窗合并标记 / 音量。
	 * 结束时清零共用累加器 (物化路径与 fastSkipPastNotes 在帧内共用同一个对象)。
	 */
	function finishBulkFrame(drainedHit:Int, skippedHit:Int, skippedHitHealth:Float,
		skippedMiss:Int, skippedMissHealth:Float, oppDrained:Int):Void
	{
		if (skippedHit > 0)
		{
			combo += skippedHit;
			if (combo > maxcombo) maxcombo = combo;
			totalPlayed += skippedHit;
			songHits += skippedHit; // 口径修复: 结算 hits 此前漏加聚合命中
			notehitlol += skippedHit; // 口径修复: HUD 总命中数此前只统计逐对象路径
			totalNotesHit += skippedHit;
			if (ClientPrefs.data.marvelousRatings)
				marvelouses += skippedHit;
			else
				sicks += skippedHit;
			if (playOpponent)
				health -= skippedHitHealth * healthGain;
			else
				health += skippedHitHealth * healthGain;
		}

		if (skippedMiss > 0)
		{
			combo = 0;
			if (!endingSong) songMisses += skippedMiss;
			totalPlayed += skippedMiss;
			if (playOpponent)
				health += skippedMissHealth * healthLoss;
			else
				health -= skippedMissHealth * healthLoss;
		}

		if (drainedHit > 0 || skippedHit > 0)
		{
			if (SONG.needsVoices && vocals.volume != 1) vocals.volume = 1;
			if (vocalsPlayer.volume != 1) vocalsPlayer.volume = 1;
			if (opponentVocals.volume != 1) opponentVocals.volume = 1;
		}

		if (bulkHurtCount > 0)
		{
			vocals.volume = 0; vocalsPlayer.volume = 0;
			_msTextDirty = true;
			_pendingMsText = 'Miss';
			_pendingMsColor = 0xFF0000;
		}

		if (drainedHit > 0)
		{
			_popupPending = true;
			var r:Rating = (ratingsData.length > 0) ? ratingsData[0] : null;
			_pendingRatingImage = (r != null) ? r.image : 'sick';
		}

		if (drainedHit > 0 || skippedHit > 0)
			RecalculateRating(false);
		else if (skippedMiss > 0 || bulkHurtCount > 0)
			RecalculateRating(true);

		if (instakillOnMiss && (skippedMiss > 0 || bulkHurtCount > 0))
			doDeathCheck(true);

		bulkHurtCount = 0;
		resetBulkAccumulator();
	}

	/** 清零每帧复用的数据层结算累加器 (finishBulkFrame 消费完就归零)。 */
	inline function resetBulkAccumulator():Void
	{
		_bulkAcc.drainedHit = 0;
		_bulkAcc.skippedHit = 0;
		_bulkAcc.skippedHitHealth = 0;
		_bulkAcc.skippedMiss = 0;
		_bulkAcc.skippedMissHealth = 0;
		_bulkAcc.oppDrained = 0;
	}

public function setOpponentStrumStatic(direction:Int) {
    var strum = opponentStrums.members[direction];
    if (strum != null) {
        strum.playAnim('static', true);
        strum.resetAnim = 0;
    }
}
public function setgoodnoteStrumStatic(direction:Int) {
    var strum = playerStrums.members[direction];
    if (strum != null) {
        strum.playAnim('static', true);
        strum.resetAnim = 0;
    }
}


var msScaleTween:FlxTween;

/** LeatherEngine 移植: 当前选择的击打音效 (预加载, 避免每帧解析路径) */
var hitsoundSnd:FlxSound = null;

/**
 * LeatherEngine 移植: 预加载当前选择的击打音效。
 * 音效文件放在 sounds/hitsounds/ 下 (可用 mod 覆盖), 缺失时回退到默认 hitsound。
 */
function initHitsound():Void
{
	var hs:String = ClientPrefs.data.hitsound;
	if (hs == null || hs.length == 0 || hs.toLowerCase() == 'none' || ClientPrefs.data.hitsoundVolume <= 0)
	{
		hitsoundSnd = null;
		return;
	}

	var loaded:Sound = null;
	try { loaded = Paths.sound('hitsounds/' + hs); } catch (e:Dynamic) {}
	if (loaded == null)
	{
		try { loaded = Paths.sound('hitsound'); } catch (e:Dynamic) {}
	}

	hitsoundSnd = (loaded != null) ? FlxG.sound.load(loaded) : null;
}

/** LeatherEngine 移植: 播放击打音效 (支持 'none' 关闭与自定义音效) */
function playHitsound():Void
{
	if (ClientPrefs.data.hitsoundVolume <= 0) return;

	var hs:String = ClientPrefs.data.hitsound;
	if (hs == null || hs.length == 0 || hs.toLowerCase() == 'none') return;

	if (hitsoundSnd == null)
		initHitsound();

	if (hitsoundSnd != null)
	{
		hitsoundSnd.volume = ClientPrefs.data.hitsoundVolume;
		hitsoundSnd.play(true);
	}
}

function goodNoteHit(note:Note, ?time:Float = -999999):Void
{
#if ONLINE_ALLOWED
var onlineHitDiff:Float = 0;
#end
// osu! 尾判: 长条头部命中 → 注册活动长条; 尾段命中 → 长条完成
//if (!note.isSustainNote)
//	registerActiveHold(note);
//else if (note.isSustainEnd && !ClientPrefs.data.osuTailJudgement)
//{
//	var lane:Int = Std.int(Math.abs(note.noteData));
//	if (lane >= 0 && lane < activeTailEnd.length && activeTailEnd[lane] > 0)
//		clearActiveHold(lane);
//}

if (note.isSustainNote) {
sustainNotescore += 10;
}
 var rating:String = 'sick';

if (!note.isSustainNote && !(note.ignoreNote || note.hitCausesMiss))  {
notehitlol++;
if (!cpuControlled) {
	// 回放时优先使用录制的高精度判定，100% 还原原始评分与 ms（旧回放无判定数据时回退实时判定）
	var recordedJ = null;
	if (replayMode && replayExam != null && replayExam.hasJudgments)
		recordedJ = replayExam.getRecordedJudgment(note.strumTime, note.noteData);

	var noteDiff:Float = (recordedJ != null)
		? Math.abs(recordedJ.hitDiff)
		: Math.abs(note.strumTime - Conductor.songPosition + ClientPrefs.data.ratingOffset);
	sustainNotescore = 0;
	if (recordedJ != null) {
	    rating = recordedJ.rating;
	} else {
	    // LeatherEngine 移植: 判定窗口由 judgementTimings 驱动 (marvelous/sick/good/bad/shit)
	    rating = backend.Ratings.getRating(noteDiff);
	}

	if (rating == 'marvelous') {
		msTxtKade.color = 0xFFFFD700;
	} else if (rating == 'sick') {
		msTxtKade.color = 0x00FFFF;
	} else if (rating == 'good') {
		msTxtKade.color  = 0x006400;
	} else if (rating == 'bad') {
		msTxtKade.color = 0xEEFF00;
	} else if (rating == 'shit') {
		msTxtKade.color = 0xFF0000;
	}

	if (!replayMode && replayExam != null)
	{
		var signedDiff:Float = note.strumTime - Conductor.songPosition + ClientPrefs.data.ratingOffset;
		replayExam.recordJudgment(note.strumTime, note.noteData, signedDiff, rating, note.isSustainNote);
	}

	var strumTime:Float = note.strumTime;
	var songPos:Float = Conductor.songPosition;
	var rOffset:Float = ClientPrefs.data.ratingOffset;
	var diff:Float = (recordedJ != null) ? recordedJ.hitDiff : (strumTime - songPos + rOffset);
#if ONLINE_ALLOWED
	onlineHitDiff = diff;
#end

	// 万级 NPS 降阶: ms 文本同帧合并 —— 只保留本帧最后一次命中的差值,
	// 帧末 flushHitPresentation() 统一重建一次文本 + 一对 tween。
	// 原实现每击一次 text setter (整段字形网格重建) + 两次 tween 分配。
	// perfMode 关闭: 保持原版逐击直写文本 + tween, 不做合并。
	if (!ClientPrefs.data.perfMode)
	{
		if (rating == 'marvelous') msTxtKade.color = 0xFFFFD700;
		else if (rating == 'sick') msTxtKade.color = 0x00FFFF;
		else if (rating == 'good') msTxtKade.color = 0x006400;
		else if (rating == 'bad') msTxtKade.color = 0xEEFF00;
		else msTxtKade.color = 0xFF0000;
		msTxtKade.text = Std.string(FlxMath.roundDecimal(-diff, 3)) + "ms";
		msTxtKade.alpha = 1;
		if (msScaleTween != null) msScaleTween.cancel();
		msTxtKade.scale.set(1.15, 1.15);
		msScaleTween = FlxTween.tween(msTxtKade.scale, {x: 1, y: 1}, 0.15, {ease: FlxEase.backOut});
		if (msTween != null) msTween.cancel();
		msTween = FlxTween.tween(msTxtKade, {alpha: 0}, 0.5, {ease: FlxEase.quintIn});
	}
	else
	{
	_msTextDirty = true;
	_pendingMsText = Std.string(FlxMath.roundDecimal(-diff, 3)) + "ms";
	if (rating == 'marvelous') {
		_pendingMsColor = 0xFFFFD700;
	} else if (rating == 'sick') {
		_pendingMsColor = 0x00FFFF;
	} else if (rating == 'good') {
		_pendingMsColor = 0x006400;
	} else if (rating == 'bad') {
		_pendingMsColor = 0xEEFF00;
	} else if (rating == 'shit') {
		_pendingMsColor = 0xFF0000;
	}
	}
} else {
	sustainNotescore = 0;
}
	}

if (!note.wasGoodHit)
		{
			// 0.7.3+/1.0.4: goodNoteHitPre / opponentNoteHitPre 回调
if (CompatEngine.isModern() && hasActiveScripts()) {
				var preName:String = reverseNoteHit ? 'opponentNoteHitPre' : 'goodNoteHitPre';
				var preIsSus:Bool = note.isSustainNote;
				var preLeData:Int = Math.round(Math.abs(note.noteData));
				var preLeType:String = note.noteType;
				var preResult:Dynamic = callOnLuas(preName, [noteIndexFast(note), preLeData, preLeType, preIsSus]);
				if(preResult != FunkinLua.Function_Stop && preResult != FunkinLua.Function_StopHScript && preResult != FunkinLua.Function_StopAll)
					callOnHScript(preName, [note]);
				if (CompatEngine.stopOnPreHitStop() && preResult == FunkinLua.Function_Stop)
				{
					return;
				}
			}

			// Fire scripts for ignore/hurt notes in botplay instead of skipping them.
			if(cpuControlled && (note.ignoreNote || note.hitCausesMiss)) {
				if (hasActiveScripts())
				{
					var botScriptName:String = reverseNoteHit ? 'opponentNoteHit' : 'goodNoteHit';
					var botResult:Dynamic = FunkinLua.Function_Continue;
					if (CompatEngine.isModern())
						botResult = callOnLuas(botScriptName, [noteIndexFast(note), Math.round(Math.abs(note.noteData)), note.noteType, note.isSustainNote]);
					else
						botResult = callOnLuas(botScriptName, [noteIndexFast(note), note.noteData, note.noteType, note.isSustainNote]);
					if(botResult != FunkinLua.Function_Stop && botResult != FunkinLua.Function_StopHScript && botResult != FunkinLua.Function_StopAll)
						callOnHScript(botScriptName, [note]);
				}
				note.wasGoodHit = true;
				return;
			}

			if (!cpuControlled && ClientPrefs.data.hitsoundVolume > 0 && !note.hitsoundDisabled)
			{
				// LeatherEngine 移植: 播放当前选择的击打音效
				playHitsound();
			}

			if(note.hitCausesMiss) {
				noteMiss(note);
				if(!note.noteSplashDisabled && !note.isSustainNote) {
					spawnNoteSplashOnNote(note);
				}

			if(!note.noMissAnimation)
			{
                switch(note.noteType) {
                case 'Hurt Note': //Hurt note
                var hurtChar:Character = playOpponent ? dad : boyfriend;
                if(hurtChar.animation.getByName('hurt') != null) {
                hurtChar.playAnim('hurt', true);
                hurtChar.specialAnim = true;
                	}
            	}
        	}

				note.wasGoodHit = true;
				if (!note.isSustainNote)
					recycleNote(note);
				return;
			}
			if (!note.isSustainNote)
			{
				combo += 1;
				popUpScore(note, time);
			}
			if (note.isSustainEnd && /*!ClientPrefs.data.osuTailJudgement && */!cpuControlled && !practiceMode) {
			songScore += sustainNotescore;
			updateScore();
			sustainNotescore = 0;
			if(ClientPrefs.data.noteSplashes && note != null && !cpuControlled) {
			var strum:StrumNote = playerStrums.members[note.noteData];
			if(strum != null) {
				spawnNoteSplash(strum.x, strum.y, note.noteData, note);
			}
		}

			}
			var gainHealth:Bool = true;
			if (guitarHeroSustains && note.isSustainNote)
				gainHealth = false;
			if (gainHealth) {
				if (playOpponent)
					health -= note.hitHealth * healthGain;
				else
					health += note.hitHealth * healthGain;
			}

			if(!note.noAnimation && !_suppressNoteAnim) {
				var animToPlay:String = getSingAnim(note);

				// botplay 降阶: 角色动画改为"每轨每帧一次"。峰值下每帧数千次命中
				// 原本会触发数千次 playAnim (字符串拼接 + 动画查找 + 重启), 而同轨
				// 同帧的重启只有第一次可见; 手动模式保持逐击播放不变。
				var allowCharAnim:Bool = true;
				if (cpuControlled)
				{
					var aIdx:Int = note.laneData() + Note.ammo[mania];
					if (aIdx >= 0 && aIdx < _botCharAnim.length)
					{
						allowCharAnim = !_botCharAnim[aIdx];
						_botCharAnim[aIdx] = true;
					}
				}
				if (allowCharAnim)
				{
					if(note.gfNote)
					{
						if(gf != null)
						{
							gf.playAnim(animToPlay + note.animSuffix, true);
							gf.holdTimer = 0;
						}
					}
					else
						{
							var playChar:Character = playOpponent ? dad : boyfriend;
							playChar.playAnim(animToPlay + note.animSuffix, true);
							playChar.holdTimer = 0;
						}

						if(note.noteType == 'Hey!') {
						var heyChar:Character = playOpponent ? dad : boyfriend;
						if(heyChar.animOffsets.exists('hey')) {
						heyChar.playAnim('hey', true);
						heyChar.specialAnim = true;
						heyChar.heyTimer = 0.6;
					}

						if(gf != null && gf.animOffsets.exists('cheer')) {
							gf.playAnim('cheer', true);
							gf.specialAnim = true;
							gf.heyTimer = 0.6;
						}
					}
				}
			}

			if(cpuControlled) {
				var shIdx:Int = note.laneData() + Note.ammo[mania];
				if (shIdx < strumsHit.length && !strumsHit[shIdx]) {
					strumsHit[shIdx] = true;
					var time:Float = calculateResetTime();
					if(note.isSustainNote && !note.animation.curAnim.name.endsWith('end')) {
						time += 0.15;
					}
					StrumPlayAnim(false, Std.int(Math.abs(note.noteData)), time);
				}
			} else {
				var spr = playerStrums.members[note.noteData];
				if(spr != null)
				{
					spr.playAnim('confirm', true);
				}
			}
						note.wasGoodHit = true;
			#if ONLINE_ALLOWED
			if (seiunOnline && !cpuControlled && OnlineSession.mode == online.shared.OnlineTypes.OnlineConst.MODE_REALTIME)
			{
				// 每次本地判定都广播当前分数/实时统计 (PsychOnline 的 addScore 等价物),
				// 对手 HUD 因此能实时刷新, 而不是只有漏键时才更新一次。
				OnlineSession.sendLocalJudge(note.strumTime, Std.int(Math.abs(note.noteData)), rating, onlineHitDiff, note.isSustainNote,
					songScore, songMisses, maxcombo, ratingPercent, ratingName, ratingFC, 0, health);
			}
			#end
			if (vocals.volume != 1) vocals.volume = 1;
			if (vocalsPlayer.volume != 1) vocalsPlayer.volume = 1;
			if (opponentVocals.volume != 1) opponentVocals.volume = 1;

			if (hasActiveScripts())
			{
				var scriptName:String = reverseNoteHit ? 'opponentNoteHit' : 'goodNoteHit';
				var result:Dynamic = FunkinLua.Function_Continue;
				if (!cpuControlled) {
					if (CompatEngine.isModern()) {
						// 0.7.3 格式: 传递 Math.round(Math.abs(noteData))
						var isSus:Bool = note.isSustainNote;
						var leData:Int = Math.round(Math.abs(note.noteData));
						var leType:String = note.noteType;
						result = callOnLuas(scriptName, [noteIndexFast(note), leData, leType, isSus]);
					} else {
						// 0.6.3 格式: 传递原始 noteData (可能为负数)
						result = callOnLuas(scriptName, [noteIndexFast(note), note.noteData, note.noteType, note.isSustainNote]);
					}
				}
				// Botplay still represents a real hit. Do not skip custom note/event
				// scripts just because keyboard judgement was bypassed.
				if (cpuControlled) {
					if (CompatEngine.isModern())
						result = callOnLuas(scriptName, [noteIndexFast(note), Math.round(Math.abs(note.noteData)), note.noteType, note.isSustainNote]);
					else
						result = callOnLuas(scriptName, [noteIndexFast(note), note.noteData, note.noteType, note.isSustainNote]);
				}
				if(result != FunkinLua.Function_Stop && result != FunkinLua.Function_StopHScript && result != FunkinLua.Function_StopAll)
					callOnHScript(scriptName, [note]);
			}

			if (!note.isSustainNote)
				recycleNote(note);
		}
		if (cpuControlled && !ClientPrefs.data.opponentfe) {
			// botplay 降阶: static 化同样"每轨每帧一次" (原为每击一次 playAnim)
			var stIdx:Int = Std.int(Math.abs(note.noteData));
			var laneTotal:Int = Note.ammo[mania];
			if (laneTotal <= 0) laneTotal = 1; // 防 % 0
			if (stIdx >= laneTotal) stIdx %= laneTotal;
			if (stIdx >= 0 && stIdx < _botStrumStatic.length && !_botStrumStatic[stIdx])
			{
				_botStrumStatic[stIdx] = true;
				setgoodnoteStrumStatic(stIdx);
			}
		}
}

	public function spawnNoteSplashOnNote(note:Note) {
		if(ClientPrefs.data.noteSplashes && note != null && !cpuControlled) {
			// 0.6.3 原版: 直接 playerStrums.members[note.noteData]。
			// laneData() 的 % ammo 会把 lua 模组 (如 Holofunk 第5键) 改出的
			// noteData=4 折叠回 0, 溅射错误落在第 0 轨; 与 update 里的
			// strum 索引修复保持同一策略。
			var strumIdx:Int = Std.int(Math.abs(note.noteData));
			var strumCount:Int = playerStrums.members.length;
			if (strumCount <= 0) return; // 重建/清空 strum 组期间没有轨道可取
			if (strumIdx >= strumCount) strumIdx %= strumCount;
			var strum:StrumNote = playerStrums.members[strumIdx];
			if(strum != null) {
				spawnNoteSplash(strum.x, strum.y, note.noteData, note);
			}
		}
	}

	public function spawnNoteSplash(x:Float, y:Float, data:Int, ?note:Note = null, ?strum:StrumNote = null) {
		if (_splashBudgetLeft <= 0 || (ClientPrefs.data.perfMode && NoteSplash.liveCount >= MAX_SPLASH_ALIVE))
			return;

		var skin:String = 'noteSplashes';
		if(PlayState.SONG != null && PlayState.SONG.splashSkin != null && PlayState.SONG.splashSkin.length > 0) skin = PlayState.SONG.splashSkin;
		else
		{
			// 用户自定义溅射皮肤任意模式生效; 默认皮肤跟随兼容模式路径
			var postfix:String = NoteSplash.getSplashSkinPostfix();
			if (postfix.length > 0) skin = 'noteSplashes/noteSplashes' + postfix;
			else if (CompatEngine.isModern()) skin = NoteSplash.defaultNoteSplash;
			else skin = 'noteSplashes';
		}

		var hue:Float = 0;
		var sat:Float = 0;
		var brt:Float = 0;
		if (data > -1)
		{
			if(note != null) {
				skin = note.noteSplashTexture;
				hue = note.noteSplashHue;
				sat = note.noteSplashSat;
				brt = note.noteSplashBrt;
			}
			else
			{
				// 多k: 无 Note 时按当前 k 值轨道色
				var lane:Int = Std.int(Math.abs(data)) % Note.ammo[mania];
				var delta:Array<Float> = EKData.getLaneColorSwap(mania, lane);
				var colorIdx:Int = EKData.letterColorIndex.get(EKData.getLetter(mania, lane));
				if (colorIdx < 0) colorIdx = lane;
				var hsv:Array<Int> = (colorIdx < ClientPrefs.data.arrowHSV.length) ? ClientPrefs.data.arrowHSV[colorIdx] : [0, 0, 0];
				hue = delta[0] + hsv[0] / 360;
				sat = delta[1] + hsv[1] / 100;
				brt = delta[2] + hsv[2] / 100;
				while (hue < 0) hue += 1;
				while (hue >= 1) hue -= 1;
			}
		}

		var splash:NoteSplash = grpNoteSplashes.recycle(NoteSplash);
		splash.setupNoteSplash(x, y, data, skin, hue, sat, brt, note);
		grpNoteSplashes.add(splash);
		_splashBudgetLeft--;
	}

	// Stage-specific private methods moved to stage/*.hx handlers.

	/** @return the stage handler cast to LimoStage, or null. */
	var limoStage(get, never):LimoStage;
	inline function get_limoStage():LimoStage
		return (stageBackdrop is LimoStage) ? cast stageBackdrop : null;

	override function destroy() {
		#if ONLINE_ALLOWED
		ClientPrefs.onlineMaskCheats = false;
		#end
		for (lua in luaArray) {
			lua.call('onDestroy', []);
			lua.stop();
		}
		luaArray = [];

		// Fallback memory ledger flush for exit paths that skip endSong (e.g. death exit)
		GfxPolicy.onPlayStateDestroy();

		#if hxvlc
		// Safety net: mods often create video objects from Lua/HScript and
		// forget to dispose them. Every leaked FlxInternalVideo keeps a
		// libVLC media player decoding frames, so clean up anything that is
		// still alive when the level is destroyed. Idempotent - videos that
		// were already disposed (including by scripts' onDestroy) are skipped.
		hxvlc.flixel.FlxInternalVideo.disposeAll();
		#end

		#if HSCRIPT_ALLOWED
		if(FunkinLua.hscript != null) FunkinLua.hscript = null;
		#end

		#if HSCRIPT_ALLOWED
		if (hscriptArray != null) {
			for (script in hscriptArray) {
				script.stop();
			}
			hscriptArray = null;
		}
		#end

		#if cpp
		if (_gcDisabledForSong)
		{
			_gcDisabledForSong = false;
			GcState.setDisabled(false);
			cpp.vm.Gc.run(true);
		}
		#end

		FlxAnimationController.globalSpeed = 1;
		if (FlxG.sound.music != null) FlxG.sound.music.pitch = 1;
		if (ratingPopup != null) ratingPopup.destroyAll();

		// Clear NoteMs/NoteTime arrays to free memory
		if (NoteMs != null) NoteMs = [];
		if (NoteTime != null) NoteTime = [];

		// unspawnNotes 现在是轻量 PreloadedChartNote 数据，不持有 Note 对象。
		if (unspawnNotes != null)
			unspawnNotes = [];
		lastSpawnedNote = new Map<Int, Note>();

		// 销毁仍然存活的 Note；已 destroy 的壳直接移除。
		if (notes != null)
		{
			var i:Int = notes.members.length - 1;
			while (i >= 0) {
				var note:Note = notes.members[i];
				if (note != null) {
					notes.remove(note, true);
					if (note.scale != null)
						note.destroy();
				}
				i--;
			}
			notes.clear();
		}
		notePool = [];
		activeNotes.resize(0);
		_frameAliveTally = 0;
		_lastAliveTally = 0;
		_noteSlotCursor = 0;

		// 清空跨歌曲静态 Note 池，释放池中 Note 的动画/ColorSwap 等常驻内存。
		if (Note.pool != null)
			Note.pool.clear(function(note) { if (note != null && note.scale != null) note.destroy(); });

		// 1.0.4: 清理溅射配置缓存, 防止跨谱面/换模组时串配置
		NoteSplash.configs.clear();
		if (eventNotes != null) eventNotes = [];

		// Destroy stage backdrop
		if (stageBackdrop != null)
		{
			stageBackdrop.destroy();
			stageBackdrop = null;
		}


		// 恢复 Turbo 强制改写的 perfMode/bulkSkip。
		if (turboModeActive)
		{
			ClientPrefs.data.perfMode = _turboPrevPerf;
			ClientPrefs.data.bulkSkip = _turboPrevBulk;
			ClientPrefs.data.fastSort = _turboPrevFastSort;
		}

		instance = null;
		#if ONLINE_ALLOWED
		onlineRestoreRoomSettings();
		#end

		super.destroy();
	}

	public static function cancelMusicFadeTween() {
		if(FlxG.sound.music.fadeTween != null) {
			FlxG.sound.music.fadeTween.cancel();
		}
		FlxG.sound.music.fadeTween = null;
	}

	var lastStepHit:Int = -1;
	override function stepHit()
	{
		super.stepHit();
		if (!startingSong && FlxG.sound.music != null
			&& (Math.abs(FlxG.sound.music.time - (Conductor.songPosition - Conductor.offset)) > (20 * playbackRate)
			|| (SONG.needsVoices && Math.abs(vocals.time - (Conductor.songPosition - Conductor.offset)) > (20 * playbackRate))))
		{
			resyncVocals();
		}

		if(curStep == lastStepHit) {
			return;
		}

		lastStepHit = curStep;
		setOnScripts('curStep', curStep);
		callOnScripts('onStepHit', []);
	}

	var lastBeatHit:Int = -1;

	override function beatHit()
	{
		super.beatHit();

		if(lastBeatHit >= curBeat) {
			//trace('BEAT HIT: ' + curBeat + ', LAST HIT: ' + lastBeatHit);
			return;
		}

		if (generatedMusic)
		{
			if (ClientPrefs.data.fastSort)
				fasterNoteSort(ClientPrefs.data.downScroll ? FlxSort.ASCENDING : FlxSort.DESCENDING);
			else
			{
				notes.sort(noteDrawOrder, ClientPrefs.data.downScroll ? FlxSort.ASCENDING : FlxSort.DESCENDING);
				rebuildMemberIndexes(notes.members, notes.members.length);
			}
		}

		iconP1.scale.set(1.2, 1.2);
		iconP2.scale.set(1.2, 1.2);

		iconP1.updateHitbox();
		iconP2.updateHitbox();

		if (gf != null && curBeat % Math.round(gfSpeed * gf.danceEveryNumBeats) == 0 && !gf.isAnimationNull() && !gf.getAnimationName().startsWith("sing") && !gf.stunned)
		{
			gf.dance();
		}
		if (curBeat % boyfriend.danceEveryNumBeats == 0 && !boyfriend.isAnimationNull() && !boyfriend.getAnimationName().startsWith('sing') && !boyfriend.stunned)
		{
			boyfriend.dance();
		}
		if (curBeat % dad.danceEveryNumBeats == 0 && !dad.isAnimationNull() && !dad.getAnimationName().startsWith('sing') && !dad.stunned)
		{
			dad.dance();
		}

		// Delegate per-beat stage animation
		if (stageBackdrop != null)
			stageBackdrop.beatHit();
		lastBeatHit = curBeat;

		setOnScripts('curBeat', curBeat); //DAWGG?????
		callOnScripts('onBeatHit', []);
	}

	override function sectionHit()
	{
		super.sectionHit();

		if (SONG.notes[curSection] != null)
		{
			if (generatedMusic && !endingSong && !isCameraOnForcedPos)
			{
				moveCameraSection();
			}

			if (camZooming && FlxG.camera.zoom < 1.35 && ClientPrefs.data.camZooms)
			{
				FlxG.camera.zoom += 0.015 * camZoomingMult;
				camHUD.zoom += 0.03 * camZoomingMult;
			}

			if (SONG.notes[curSection].changeBPM && SONG.notes[curSection].bpm > 0 && Math.isFinite(SONG.notes[curSection].bpm))
			{
				Conductor.changeBPM(SONG.notes[curSection].bpm);
				setOnScripts('curBpm', Conductor.bpm);
				setOnScripts('crochet', Conductor.crochet);
				setOnScripts('stepCrochet', Conductor.stepCrochet);
			}
			setOnScripts('mustHitSection', SONG.notes[curSection].mustHitSection);
			setOnScripts('altAnim', SONG.notes[curSection].altAnim);
			setOnScripts('gfSection', SONG.notes[curSection].gfSection);
		}

		setOnScripts('curSection', curSection);
		callOnScripts('onSectionHit', []);
	}
	/** True when any Lua/HScript runtime may have callback handlers. Used to skip pure no-op callback+indexOf work in the hot paths. */
	inline function hasActiveScripts():Bool
	{
		#if LUA_ALLOWED
		if (luaArray != null && luaArray.length > 0) return true;
		#end
		#if HSCRIPT_ALLOWED
		if (hscriptArray != null && hscriptArray.length > 0) return true;
		#end
		return false;
	}


	public function callOnScripts(funcToCall:String, args:Array<Dynamic> = null, ignoreStops = false, exclusions:Array<String> = null, excludeValues:Array<Dynamic> = null):Dynamic {
		var returnVal:Dynamic = FunkinLua.Function_Continue;
		if(args == null) args = [];
		if(exclusions == null) exclusions = [];
		if(excludeValues == null) excludeValues = [FunkinLua.Function_Continue];

		var result:Dynamic = callOnLuas(funcToCall, args, ignoreStops, exclusions, excludeValues);
		if(result == null || excludeValues.contains(result)) result = callOnHScript(funcToCall, args, ignoreStops, exclusions, excludeValues);
		return result;
	}

	#if HSCRIPT_ALLOWED
	/**
	 * MusicBeatState.initHScripts() 现已使用 concat 追加而非重置数组，
	 * 因此 PlayState 在 create() 中手动加载的 scripts/ 脚本得以保留。
	 * data/states/PlayState/ 与 hscripts/PlayState/ 的脚本由父类补充加载。
	 */
	override function initHScripts():Void {
		super.initHScripts();
	}
	#end

	#if HSCRIPT_ALLOWED
	/**
	 * 0.7.3+/1.0.4 addHScript 用：按完整路径加载一个 hscript 文件。
	 * English: used by the 0.7.3+/1.0.4 addHScript Lua function —
	 * loads an HScript file by full path.
	 */
	public function initHScript(scriptPath:String):Void {
		if (scriptPath == null || scriptPath.length == 0) return;
		try {
			if (!FileSystem.exists(scriptPath)) return;
			var script:HScript = new HScript(scriptPath);
			if (script != null)
				hscriptArray.push(script);
		} catch (e:Dynamic) {
			TraceManager.error('trace.playState.initHScriptFailed', 'Failed to load hscript {}: {}', [scriptPath, e]);
		}
	}
	#end

	public function callOnHScript(funcToCall:String, args:Array<Dynamic> = null, ?ignoreStops:Bool = false, exclusions:Array<String> = null, excludeValues:Array<Dynamic> = null):Dynamic {
		var returnVal:Dynamic = FunkinLua.Function_Continue;

	#if HSCRIPT_ALLOWED
		if(exclusions == null) exclusions = new Array();
		if(excludeValues == null) excludeValues = new Array();
		excludeValues.push(FunkinLua.Function_Continue);

		var len:Int = hscriptArray.length;
		if (len < 1)
			return returnVal;
		for(i in 0...len) {
			var script:HScript = hscriptArray[i];
			if(script == null || script.closed || !script.exists(funcToCall))
				continue;

			var myValue:Dynamic = null;
			try {
				myValue = script.call(funcToCall, args);
				if(myValue == FunkinLua.Function_StopHScript || myValue == FunkinLua.Function_StopAll)
				{
					if(!excludeValues.contains(myValue) && !ignoreStops)
					{
						returnVal = myValue;
						break;
					}
				}
				else if(myValue != null && !excludeValues.contains(myValue))
				{
					returnVal = myValue;
				}
			} catch (e:Dynamic) {
				TraceManager.error('trace.playState.hscriptCallFailed', 'HScript call "{}" failed on {}: {}', [funcToCall, script.scriptName, e]);
			}
		}
		#end
		return returnVal;
	}

	public function setOnScripts(variable:String, arg:Dynamic, exclusions:Array<String> = null) {
		if(exclusions == null) exclusions = [];
		setOnLuas(variable, arg, exclusions);
		setOnHScript(variable, arg, exclusions);
	}

	override public function setOnLuas(variable:String, arg:Dynamic, exclusions:Array<String> = null) {
		#if LUA_ALLOWED
		if(exclusions == null) exclusions = [];
		for (script in luaArray) {
			if(exclusions.contains(script.scriptName))
				continue;

			script.set(variable, arg);
		}
		#end
	}

	public function setOnHScript(variable:String, arg:Dynamic, exclusions:Array<String> = null) {
		#if HSCRIPT_ALLOWED
		if(exclusions == null) exclusions = [];
		HScript.setOnGlobalScript(variable, arg);
		for (script in hscriptArray) {
			if (!script.closed) {
				script.set(variable, arg);
			}
		}
		#end
	}


	override public function callOnLuas(funcToCall:String, args:Array<Dynamic> = null, ignoreStops = false, exclusions:Array<String> = null, excludeValues:Array<Dynamic> = null):Dynamic {
		var returnVal:Dynamic = FunkinLua.Function_Continue;
		#if LUA_ALLOWED
		if (luaArray == null || luaArray.length == 0) return returnVal;
		if(args == null) args = [];
		if(exclusions == null) exclusions = [];
		if(excludeValues == null) excludeValues = [FunkinLua.Function_Continue];

		var arr:Array<FunkinLua> = [];
		for (script in luaArray)
		{
			if(script.closed)
			{
				arr.push(script);
				continue;
			}

			if(exclusions.contains(script.scriptName))
				continue;

			var myValue:Dynamic = script.call(funcToCall, args);
			if((myValue == FunkinLua.Function_StopLua || myValue == FunkinLua.Function_StopAll) && !excludeValues.contains(myValue) && !ignoreStops)
			{
				returnVal = myValue;
				break;
			}

			if(myValue != null && !excludeValues.contains(myValue))
				returnVal = myValue;

			if(script.closed) arr.push(script);
		}

		if(arr.length > 0)
			for (script in arr)
				luaArray.remove(script);
		#end
		return returnVal;
	}



	function calculateResetTime():Float {
		return (Conductor.stepCrochet * 1.5 / 1000) / playbackRate;
	}

	function StrumPlayAnim(isDad:Bool, id:Int, time:Float) {
		var spr:StrumNote = null;
		if(isDad) {
			spr = (id >= 0 && id < strumLineNotes.members.length) ? strumLineNotes.members[id] : null;
		} else {
			spr = (id >= 0 && id < playerStrums.members.length) ? playerStrums.members[id] : null;
		}
		if(spr != null) {
			spr.playAnim('confirm', true);
			spr.resetAnim = time;
		}
	}

	public var ratingName:String = '?';
	public var ratingPercent:Float;
	public var ratingFC:String;
	public function RecalculateRating(badHit:Bool = false) {
		// 万级 NPS 降阶: setOnScripts/callOnScripts 在无脚本时本就是空转, 但
		// 每击 7 次 set + 1 次回调的调用链在峰值下仍有可观开销, 统一收进
		// hasActiveScripts() 门控 —— 有脚本时语义逐字节保留 (含 Stop 跳过计算,
		// 但 set 变量仍照常同步)。
		var scriptStopped:Bool = false;
		if (hasActiveScripts())
		{
			setOnScripts('score', songScore);
			setOnScripts('misses', songMisses);
			setOnScripts('hits', songHits);
			setOnScripts('combo', combo);

			scriptStopped = (callOnScripts('onRecalculateRating', [], false) == FunkinLua.Function_Stop);
		}

		if (!scriptStopped)
		{
			if(totalPlayed < 1) //Prevent divide by 0
				ratingName = '?';
			else
			{
				// Rating Percent
				ratingPercent = Math.min(1, Math.max(0, totalNotesHit / totalPlayed));
				//trace((totalNotesHit / totalPlayed) + ', Total: ' + totalPlayed + ', notes hit: ' + totalNotesHit);

				// Botplay forces perfect accuracy
				if(cpuControlled) ratingPercent = 1;

				// Rating Name
				if(ratingPercent >= 1)
				{
					ratingName = ratingStuff[ratingStuff.length-1][0]; //Uses last string
				}
				else
				{
					for (i in 0...ratingStuff.length-1)
					{
						if(ratingPercent < ratingStuff[i][1])
						{
							ratingName = ratingStuff[i][0];
							break;
						}
					}
				}
			}

			// Rating FC
			ratingFC = "";
			// LeatherEngine 移植: marvelous 命中计入 FC 徽章 (MFC > SFC > GFC > FC)
			if (marvelouses > 0) ratingFC = "MFC";
			if (sicks > 0) ratingFC = "SFC";
			if (goods > 0) ratingFC = "GFC";
			if (bads > 0 || shits > 0) ratingFC = "FC";
			if (songMisses > 0 && songMisses < 10) ratingFC = "SDCB";
			else if (songMisses >= 10) ratingFC = "Clear";
		}
		updateScore(badHit); // score will only update after rating is calculated, if it's a badHit, it shouldn't bounce -Ghost
		if (hasActiveScripts())
		{
			setOnScripts('rating', ratingPercent);
			setOnScripts('ratingName', ratingName);
			setOnScripts('ratingFC', ratingFC);
		}
	}

	#if ACHIEVEMENTS_ALLOWED
	public function checkForAchievement(achievesToCheck:Array<String> = null):String
	{
		if(chartingMode) return null;

		var usedPractice:Bool = (ClientPrefs.getGameplaySetting('practice', false) || ClientPrefs.getGameplaySetting('botplay', false));
		for (i in 0...achievesToCheck.length) {
			var achievementName:String = achievesToCheck[i];
			if(!Achievements.isAchievementUnlocked(achievementName) && !cpuControlled) {
				var unlock:Bool = false;
				switch(achievementName)
				{
					case 'week1_nomiss' | 'week2_nomiss' | 'week3_nomiss' | 'week4_nomiss' | 'week5_nomiss' | 'week6_nomiss' | 'week7_nomiss':
						if(isStoryMode && campaignMisses + songMisses < 1 && CoolUtil.difficultyString() == 'HARD' && storyPlaylist.length <= 1 && !changedDifficulty && !usedPractice)
						{
							var weekName:String = WeekData.getWeekFileName();
							switch(weekName) //I know this is a lot of duplicated code, but it's easier readable and you can add weeks with different names than the achievement tag
							{
								case 'week1':
									if(achievementName == 'week1_nomiss') unlock = true;
								case 'week2':
									if(achievementName == 'week2_nomiss') unlock = true;
								case 'week3':
									if(achievementName == 'week3_nomiss') unlock = true;
								case 'week4':
									if(achievementName == 'week4_nomiss') unlock = true;
								case 'week5':
									if(achievementName == 'week5_nomiss') unlock = true;
								case 'week6':
									if(achievementName == 'week6_nomiss') unlock = true;
								case 'week7':
									if(achievementName == 'week7_nomiss') unlock = true;
							}
						}
					case 'ur_bad':
						if(ratingPercent < 0.2 && !practiceMode) {
							unlock = true;
						}
					case 'line_blue':
						if(goods == 1 && bads == 0 && shits == 0 && songMisses == 0 && sicks > 0 && !usedPractice){
							unlock = true;
						}
					case 'ur_good':
						if(ratingPercent >= 1 && !usedPractice) {
							unlock = true;
						}
					case 'roadkill_enthusiast':
						if(Achievements.henchmenDeath >= 100) {
							unlock = true;
						}
					case 'oversinging':
						if(boyfriend.holdTimer >= 10 && !usedPractice) {
							unlock = true;
						}
					case 'hype':
						if(!boyfriendIdled && !usedPractice) {
							unlock = true;
						}
					case 'two_keys':
						if(!usedPractice) {
							var howManyPresses:Int = 0;
							for (j in 0...keysPressed.length) {
								if(keysPressed[j]) howManyPresses++;
							}

							if(howManyPresses <= 2) {
								unlock = true;
							}
						}
					case 'toastie':
						if(/*ClientPrefs.data.framerate <= 60 && !ClientPrefs.data.cacheOnGPU &&*/!ClientPrefs.data.shaders && ClientPrefs.data.lowQuality && !ClientPrefs.data.globalAntialiasing) {
							unlock = true;
						}
					case 'debugger':
						if(Paths.formatToSongPath(SONG.song) == 'test' && !usedPractice) {
							unlock = true;
						}
				}

				if(unlock) {
					Achievements.unlockAchievement(achievementName);
					return achievementName;
				}
			}
		}
		return null;
	}
	#end

	public var curLight:Int = -1;
	public var curLightEvent:Int = -1;
}
