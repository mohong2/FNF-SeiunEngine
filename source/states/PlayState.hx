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
 * Accumulator for one data-level batch settlement pass.
 * The same object is shared within a frame by fastSkipPastNotes and the materialisation path,
 * then handed to finishBulkFrame once per frame for the aggregated presentation (avoids per-hit popUpScore/RecalculateRating).
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

	/** Multi-key: key count of the current chart (0-based; 3 = 4K, 8 = 9K, 17 = 18K). */
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
	/** 0.7.3 compatibility: current UI style, e.g. "normal" / "pixel" / a custom stageUI. */
	public static var stageUI:String = "normal";
	public static var SONG:SwagSong = null;

	/** Stage backdrop handler — manages background sprites, anims, and stage-specific logic. */
	public var stageBackdrop:StageBackdrop;
	public static var isStoryMode:Bool = false;
	public static var storyWeek:Int = 0;
	public static var storyPlaylist:Array<String> = [];
	public static var storyDifficulty:Int = 1;

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

	/** Legacy alias: 0.6.3/0.7.3 vocalsOpponent == the current opponentVocals. */
	public var vocalsOpponent(get, set):FlxSound;
	function get_vocalsOpponent():FlxSound return opponentVocals;
	function set_vocalsOpponent(v:FlxSound):FlxSound return opponentVocals = v;

	/** 1.0.4 compatibility: playerVocals == the current vocalsPlayer. */
	public var playerVocals(get, set):FlxSound;
	function get_playerVocals():FlxSound return vocalsPlayer;
	function set_playerVocals(v:FlxSound):FlxSound return vocalsPlayer = v;

	/** 0.7.3 compatibility: standalone instrumental alias pointing at the current music. */
	public var inst(get, set):FlxSound;
	function get_inst():FlxSound return FlxG.sound.music;
	function set_inst(v:FlxSound):FlxSound return FlxG.sound.music = v;


	public var dad:Character = null;
	public var gf:Character = null;
	public var boyfriend:Boyfriend = null;

	public var notes:FlxTypedGroup<Note>;
	public var sustainNotes:FlxTypedGroup<Note>; // Kept for Lua compatibility (empty)
	public var unspawnNotes:ChartNotes = ChartNotes.empty();
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
	/** Cached sort comparator (created once per state to avoid a per-frame lambda allocation). */
	private var _cmpNoteY:Note->Note->Int = null;
	private var _cmpIntAsc:Int->Int->Int = null;
	/** True while this PlayState has disabled the hxcpp GC (restored in destroy). */
	private var _gcDisabledForSong:Bool = false;
	/** Off-screen cull distance along the scroll direction, recomputed every frame (world pixels, including zoom/rotation slack). */
	private var _cullDistPlayer:Float = 2200;
	private var _cullDistOpponent:Float = 2200;
	/** Living note count, refreshed by the per-frame update hook so the spawn loop reads it in O(1) instead of scanning countLiving(). */
	private var _frameAliveTally:Int = 0;
	private var _lastAliveTally:Int = 0;
	/** Scan cursor for empty notes.members slots: turns appending notes from O(n) (indexOf + getFirstNull) into amortised O(1). */
	private var _noteSlotCursor:Int = 0;

	// ── hit presentation merging (the core dense-chart optimization): score text / rating popup / ms text refresh at most once per frame ──
	/** Without scripts updateScore() only sets a dirty flag; flushScoreText() rebuilds the text once at frame end. */
	var _scoreTextDirty:Bool = false;
	var _scoreZoomDirty:Bool = false;
	/** ms judgement text (kadems) merged per frame: only the last hit difference of the frame is kept. */
	var _msTextDirty:Bool = false;
	var _pendingMsText:String = null;
	var _pendingMsColor:FlxColor = 0xFFFFFFFF;
	/** Rating popup merging: dense frames show only the newest popup (sparse frames keep the stock per-hit popup). */
	var _popupPending:Bool = false;
	var _pendingRatingImage:String = null;
	/** The first POPUP_IMMEDIATE_HITS hits of a frame keep the stock per-hit popup (normal charts are unaffected). */
	static inline var POPUP_IMMEDIATE_HITS:Int = 8;
	var _popupImmediateBudget:Int = POPUP_IMMEDIATE_HITS;
	/** Per-frame splash spawn budget and living cap (pooling cannot grow without bound during manual combo storms). */
	static inline var SPLASH_FRAME_BUDGET:Int = 16;
	public static inline var MAX_SPLASH_ALIVE:Int = 256;
	var _splashBudgetLeft:Int = SPLASH_FRAME_BUDGET;

	// ---- F8 hit-cost probe: read-only diagnostics, never feeds back into gameplay ----
	/**
	 * Ring of the last PROBE_FRAMES frames, PROBE_STRIDE floats each. F8 dumps it to
	 * ./crash/hitprobe.txt, so a 100k-NPS run can be compared before/after a change.
	 */
	static inline var PROBE_FRAMES:Int = 600;
	static inline var PROBE_STRIDE:Int = 13;
	static inline var PROBE_TOTAL:Int = 0;    // whole PlayState.update()
	static inline var PROBE_BULK:Int = 1;     // bulkHitDueMaterialized()
	static inline var PROBE_NOTES:Int = 2;    // per-object note update loop
	static inline var PROBE_SORT:Int = 3;     // note sort
	static inline var PROBE_PRESENT:Int = 4;  // flushHitPresentation()
	static inline var PROBE_POPUP:Int = 5;    // ms inside RatingPopup.show()
	static inline var PROBE_SHOWS:Int = 6;    // popup show() calls this frame
	static inline var PROBE_MEMBERS:Int = 7;  // ratingPopup.container.length (stale-length canary)
	static inline var PROBE_COMBO:Int = 8;
	/** Per-frame script dispatch cost: the four fixed update() dispatch sites (onUpdate, the two
	 * engine-variable sweeps, onUpdatePost). Per-hit callbacks are charged to notes/sort instead. */
	static inline var PROBE_SCRIPT:Int = 9;
	/** callOnLuas/callOnHScript/setOnLuas/setOnHScript entries this frame (one entry = one array sweep). */
	static inline var PROBE_SWEEPS:Int = 10;
	/** luaArray.length + hscriptArray.length, sampled once per frame. */
	static inline var PROBE_SCOUNT:Int = 11;
	/** require() filesystem misses + import() calls this frame (counted inside FunkinLua). */
	static inline var PROBE_REQIMP:Int = 12;

	var _probeBuf:Array<Float> = null;
	var _probeIdx:Int = 0;
	var _probeFrames:Int = 0;
	var _probeFrameStart:Float = 0;
	var _probeBulkMs:Float = 0;
	var _probeNotesMs:Float = 0;
	var _probeSortMs:Float = 0;
	var _probePresentMs:Float = 0;
	var _probeTotalMs:Float = 0;
	var _probePopupMs:Float = 0;
	var _probeShows:Int = 0;
	var _probeScriptMs:Float = 0;
	var _probeSweeps:Int = 0;
	var _probeReqImpPrev:Int = 0;
	/** Once-per-lane-per-frame gates for botplay character sing animations / strum static resets (reset with strumsHit). */
	var _botCharAnim:Array<Bool> = [false, false, false, false, false, false, false, false];
	var _botStrumStatic:Array<Bool> = [false, false, false, false, false, false, false, false];
	/** Same for the opponent side: sing and confirm animations once per lane per frame; static resets once per frame. */
	var _oppCharAnim:Array<Bool> = [false, false, false, false, false, false, false, false];
	var _oppStrumConfirm:Array<Bool> = [false, false, false, false, false, false, false, false];
	var _oppStaticSet:Bool = false;
	/** Notes currently culled off-screen (trace diagnostics). */
	var _culledCount:Int = 0;
	/** Hurt notes accumulated in this frame's data-level settlement (cleared after finishBulkFrame consumes them). */
	var bulkHurtCount:Int = 0;
	/** Compact list of living notes: appended on materialisation, swap-removed on recycle; the frame iterates only this. */
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
	 * Visible materialisation horizon (ms): notes further away than this never reach the screen between
 * materialisation and the off-screen cull, so building a sprite for them is pure waste. Derived by
 * refreshNoteCullRanges() from the real screen geometry and the current scroll speed.
 *
 * The initial value is deliberately small: refreshNoteCullRanges() has not run before the countdown,
 * and a 2000ms default would materialise thousands of notes on the first frame of a slow chart.
	 */
	var _visHorizonMs:Float = 250;
	/** Entries consumed by the previous data-level advance -- the overload signal ("is the engine falling behind?"). */
	var _bulkDrainedLast:Int = 0;
	/** Overload hysteresis counter: set high when drain is clearly non-zero, then decays -- prevents mode flapping. */
	var _overloadFrames:Int = 0;

	// ── Turbo: screen-pixel-level chart merging ──
	/** Whether Turbo is active for this play. */
	public var turboModeActive:Bool = false;

	// ── Streamed-chart load budget ──
	/**
	 * Notes a streamed chart may materialise as PreloadedChartNote objects. One such object is
	 * 358 bytes (64-bit), so this budget is ~4.3 GB of note list. A chart above it is not refused:
	 * its notes are folded to screen-distinguishable representatives the way Turbo does (see the
	 * collapser setup in generateSong), which keeps memory bounded and the chart playable.
	 */
	public static inline final MAX_CHART_NOTES:Float = 12000000;
	/**
	 * Workers ChartPrefetch uses. 1 on purpose: it is an async pipeline, not a parallel reader --
	 * one worker parses the next chunk while this thread consumes the previous one, which already
	 * hides the parse behind the note-list build. More workers allocate concurrently against the
	 * collector and were measured to stall well before they help, so re-measure before raising it.
	 */
	public static inline final PREFETCH_WORKERS:Int = 1;
	/** Streamed payload below this stays on the inline single-threaded read path. */
	public static inline final PREFETCH_MIN_PAYLOAD_BYTES:Float = 16 * 1024 * 1024;
	/** perfMode/bulkSkip/fastSort saved before the song and restored afterwards (Turbo never persists its overrides). */
	private var _turboPrevPerf:Bool = false;
	private var _turboPrevBulk:Bool = false;
	private var _turboPrevFastSort:Bool = false;
	#if ONLINE_ALLOWED
	/** User values of the runtime Note optimisations, saved while silenced online. */
	private var _onlinePrevPerf:Bool = false;
	private var _onlinePrevBulk:Bool = false;
	private var _onlinePrevFastSort:Bool = false;
	private var _onlineNoteOptsOff:Bool = false;
	#end
	/**
	 * Turbo pre-processing folds taps that cannot be told apart on screen into representative notes, each carrying
 * its merged count (noteDensity). The living sprite count then depends only on scroll speed and screen geometry.
	 */
	/**
	 * Raw tap count of this play before folding (per unmerged tap), for logs/diagnostics.
	 *
	 * Int64: one chart can pass 2^31 raw taps at the chart sizes this store targets, and the value
	 * is also what fills the second 8-byte slot of the ChartCache header -- which is already
	 * Int64, so an Int here would wrap first. The field is private and never exposed to
	 * Lua/HScript, so a script reading it through getPropertyFromClass gets a boxed Int64.
	 */
	private var _turboRawTapCount:haxe.Int64 = 0;
	/** Per-lane cos/sin cache: per-note per-frame trig becomes once per lane per frame (the direction is a lane constant anyway). */
	var _playerLaneCos:Array<Float> = [];
	var _playerLaneSin:Array<Float> = [];
	var _oppLaneCos:Array<Float> = [];
	var _oppLaneSin:Array<Float> = [];
	/**
	 * Runtime pixel-level keep-gate state (one per lane+side) plus the shared data-level settlement accumulator.
	 *
 * Load-time folding already packed overlapping taps into representatives by screen pixel gap; the runtime
 * gate is the second line of defence if songSpeed is rewritten mid-song by an event or tween.
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
	/** 0.7.3 compatibility: icon hurt animation toggle (read by scripts such as iconShake). */
	public var iconsAnimations:Bool = true;
	public var combo:Int = 0;

	// ── Botplay / Turbo side readout (H-Slice-style score text) ──
	/** Opponent-side notes hit so far. Turbo fold groups add their whole noteDensity, so this counts original taps. */
	public var opCombo:Float = 0;
	/** NPS window: NPS_BUCKETS buckets of NPS_BUCKET_MS each (100 * 10 ms = 1 s; 10 ms resolution). */
	static inline var NPS_BUCKET_MS:Float = 10;
	static inline var NPS_BUCKETS:Int = 100;
	var _npsOp:Array<Float> = null;
	var _npsBf:Array<Float> = null;
	var _npsOpVal:Float = 0;
	var _npsBfVal:Float = 0;
	var _npsOpMax:Float = 0;
	var _npsBfMax:Float = 0;
	var _npsSumMax:Float = 0;
	var _npsSlot:Int = -1;
	var _npsSeenOp:Float = 0;
	var _npsSeenBf:Float = 0;
	/**
	 * Private, monotone copy of the opponent-side hit count. The NPS window reads this instead of
	 * `opCombo`, because scripts can write the public field (H-Slice parity) and an upward write
	 * would otherwise be indistinguishable from a burst of real hits. Only addOpponentHit() bumps it.
	 */
	var _opHitCount:Float = 0;
	/**
	 * Display ballistics for the readout (see updateBotplayReadout). The window value is exact, but
	 * Turbo settles a whole burst into one bucket, so when that bucket leaves the window the raw
	 * value snaps to 0 in a single frame. Fast attack + slow release: it rises with the real rate
	 * and falls back smoothly (a stopped burst fades out over ~1.5 s instead of blinking to zero).
	 */
	static inline var NPS_ATTACK_PER_SEC:Float = 14;
	static inline var NPS_RELEASE_PER_SEC:Float = 6;
	var _npsOpShown:Float = 0;
	var _npsBfShown:Float = 0;

	public var healthBarBG:AttachedSprite;
	public var healthBar:Dynamic;
	var songPercent:Float = 0;

	public var timeBarBG:AttachedSprite; // curse this Lua API
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
		if (ClientPrefs.data.turboMode) value = true; // Turbo forces botplay on
		#if ONLINE_ALLOWED
		// set_cpuControlled() tells the room when this client turns botplay on (`send` is a no-op
		// while disconnected, and `!cpuControlled` mirrors the early return for an already-
		// botplayed player).
		if (value && !cpuControlled)
			online.GameClient.send("botplay");
		#end
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

	/** Replay judging-feel hint (from LeatherEngine). */
	public var judgeRestoreTxt:FlxText;
	/** osu! tail judgement: HUD badge showing that the option is enabled. */
	//public var tailBadgeTxt:FlxText;
	var botplayUsed:Bool = false;
	var strumsHit:Array<Bool> = [false, false, false, false, false, false, false, false];
	var _suppressNoteAnim:Bool = false;
	public var replayExam:Replay;
	/** Replay-mode key state array (filled by replayApplyInput). */
	private var _hold:Array<Bool> = [];
	private var _press:Array<Bool> = [];
	private var _release:Array<Bool> = [];

	// ---- osu! tail judgement: per-lane active sustain head and tail end time ----
	/** Tail end time of the active sustain on this lane (0 = none). */
	//private var activeTailEnd:Array<Float> = [];
	/** Head note of the active sustain on this lane (for hitHealth/missHealth). */
	//private var activeHoldNote:Array<Note> = [];
	/** Tail window = normal judgement window x multiplier (ClientPrefs.tailWindowMult, default 2.0; the constant is only a guard). */
	//private static final TAIL_WINDOW_MULT:Float = 2.0;

	/** Current tail window multiplier (falls back to 2.0 on an invalid setting). */
	//static inline function tailWindowMult():Float
	//{
	//	var m:Float = ClientPrefs.data.tailWindowMult;
	//	if (Math.isNaN(m) || m <= 0 || m > 8)
	//		return TAIL_WINDOW_MULT;
	//	return m;
	//}


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
	/**
	 * Lua wiggle effects (addWiggleEffect), keyed by the sprite tag they were requested for. Only the
	 * uTime advance needs the map -- the shader itself sits on the sprite -- so a re-add on the same
	 * tag replaces its entry and removeLuaSprite drops it (same shape as H-Slice's wiggleMap).
	 */
	public var wiggleMap:Map<String, WiggleEffect> = new Map<String, WiggleEffect>();
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

	/** Multi-key: character animation from the note's snapshot key count/lane, with Lua customCharAnim support. */
	inline function getSingAnim(note:Note):String
	{
		if (note.customCharAnim != null && note.customCharAnim.length > 0) return note.customCharAnim;
		return 'sing' + EKData.getAnim(note.mania, note.laneData());
	}

	/** Multi-key: character animation for the current key count/lane. */
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
	/** Multi-key touch: currently held touch lanes (driven by FlxHitbox, used by keysCheck for sustains). */
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

	/** Rating popup pool. */
	var ratingPopup:RatingPopup;

	/** Wrong-lane press times (shown in the online results). */
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
		backend.ScriptLog.write('state', 'PlayState.create() ENTER  instance=' + Std.string(this)
			+ '  luaArray=' + (luaArray == null ? 'null' : Std.string(luaArray.length))
			+ '  song=' + (SONG == null ? 'null' : SONG.song));
		// 诊断: create() 中途抛异常会让 onCreatePost 永远不执行 (表现就是"模组脚本没生效")。
		// 这里把异常与调用栈写进 script_log.txt 再原样抛出, 不改变任何行为。
		try {

		// 引擎自带的 Flixel 鼠标光标：菜单（MainMenu/Freeplay/Mods/Pause）会把它打开，
		// 而 PlayState 以前从没关掉过，于是自定义鼠标的模组会在游戏里同时看到两个光标。
		// 0.6.3/0.7.3/1.0.4 的 PlayState 都不会显示它（那些版本的菜单也不打开它），
		// 所以这里统一关掉就等于恢复三个版本的原生观感；模组仍可在 onCreate 里自己打开。
		FlxG.mouse.visible = false;

		// The build watermark is a menu affordance: keep it off the playfield entirely.
		// destroy() puts it back for the menus (the option toggle still wins).
		backend.Watermark.setVisible(false);

		// Entering play directly from the chart editor (or anywhere else)
		// may leave the difficulty list empty — fall back to the defaults so
		// difficulty displays never come out blank.
		if (CoolUtil.difficulties.length < 1)
			CoolUtil.difficulties = CoolUtil.defaultDifficulties.copy();


		//trace('Playback Rate: ' + playbackRate);
		// Register song entry before clearing cache to allow LRU tracking
		GfxPolicy.onPlayStateCreate(SONG != null && SONG.song != null ? SONG.song : 'unknown');
		Paths.clearStoredMemory();
		// The old state was destroyed by switchState, so its useCount is already zero;
		// clear the previous song's currentTrackedAssets here so repeated restarts/song switches cannot grow the image cache.
		Paths.clearUnusedMemory();
		// for lua
		instance = this;
		debugKeysChart = ClientPrefs.copyKey(ClientPrefs.keyBinds.get('debug_1'));
		debugKeysCharacter = ClientPrefs.copyKey(ClientPrefs.keyBinds.get('debug_2'));
		PauseSubState.songName = null; //Reset to default
		playbackRate = ClientPrefs.getGameplaySetting('songspeed', 1);
		// In replay mode playbackRate is restored from the StateRecord by replayExam.loadFromFile()
		// Note cap: 0 = unlimited (advanced users only)
		noteLimit = ClientPrefs.data.limitNotes;
		if (noteLimit <= 0) noteLimit = 2147483647;


		EKData.loadConfig();
		mania = (SONG.mania == null) ? Note.defaultMania : EKData.clampMania(SONG.mania);
		SONG.mania = mania; // write the clamped value back so chart/editor and gameplay agree
		// 0.7.3/1.0.4 compatibility: reset the global RGB palettes per chart to avoid colour bleed across charts/mods
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

		//Ratings - judgement windows are driven by judgementTimings (from LeatherEngine).
		buildRatingsData();

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
		#if ONLINE_ALLOWED
		// Online play needs real per-note hit reporting: Turbo forces cpuControlled and settles through
		// bulkSettleNote without noteHit, which conflicts with the shared health bar and per-sid
		// scoring. Disable it for this session only, leaving the persisted preference untouched.
		// Single-player uses the persisted setting again after leaving the online session.
		if (turboModeActive && online.GameClient.isConnected()) turboModeActive = false;
		// Online: silence the runtime Note optimisations too (perfMode / bulkSkip / fastSort).
		// They bypass the only two reporting points (goodNoteHit / noteMiss), so the room
		// would see the local player standing still while combo and health keep growing.
		// Memory only: user settings are saved here and restored in destroy().
		if (online.GameClient.isConnected())
		{
			_onlinePrevPerf = ClientPrefs.data.perfMode;
			_onlinePrevBulk = ClientPrefs.data.bulkSkip;
			_onlinePrevFastSort = ClientPrefs.data.fastSort;
			_onlineNoteOptsOff = true;
			ClientPrefs.data.perfMode = false;
			ClientPrefs.data.bulkSkip = false;
			ClientPrefs.data.fastSort = false;
		}
		#end
		if (turboModeActive)
		{
			// Turbo forces botplay, so manual/replay/online branches do not apply.
			cpuControlled = true;
			playOpponent = false;
			practiceMode = false;
			replayMode = false;
			// Force perfMode/bulkSkip/fastSort in memory only; restored on song exit, never written to the user's settings.
			_turboPrevPerf = ClientPrefs.data.perfMode;
			_turboPrevBulk = ClientPrefs.data.bulkSkip;
			_turboPrevFastSort = ClientPrefs.data.fastSort;
			ClientPrefs.data.perfMode = true;
			ClientPrefs.data.bulkSkip = true;
			ClientPrefs.data.fastSort = true;
			// Turbo hard cap: at most 4096 living real notes, so dense charts still render real notes
			// without materialising the full visible window at 70k notes/s.
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
                // Online must pick which side owns the local chart from the local bfSide. The
                // equivalent is playOpponent, but it only ever read the single-player 'playOpponent'
                // setting, so a dad-side player (bfSide=false) still played the BF chart, while dad
                // charts are never auto-hit online (opponentAutoHitAllowed=false), leaving that
                if (online.GameClient.isConnected()) {
                        var onlineSelf = online.GameClient.getPlayerSelf();
                        if (onlineSelf != null)
                                playOpponent = !onlineSelf.bfSide;
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
			// Botplay and practice mode are forced off in replay mode to avoid conflicts
			cpuControlled = false;
			practiceMode = false;
                } else if(!playOpponent) {
                          if (ClientPrefs.data.saveReplayData)
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
		NoteSplash.liveCount = 0; // new play: reset the living splash count (the previous instances were destroyed with the state)

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
		// 0.6.3/0.7.3 keep the legacy order: loaded before the characters;
		// 1.0.4 defers them until after the characters and chart exist, so 104-style scripts can access dad/boyfriend/notes at the top level.
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
		if (online.GameClient.isConnected())
		{
			syncOnlineCharacters();
			// Ready gating + message registration: while connected the countdown is held until the room
			// broadcasts "startSong". registerMessages() is installed here so no room message can be
			// missed while the chart is still loading.
			canStart = false;
			spawnWaitReadyOverlay();
			registerMessages();
		}
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
		// Reset the global audio offset on entering gameplay so a leftover Conductor.offset from the editor cannot leak in
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

		// Compatibility mode uses the 0.7.3 Bar class; otherwise the stock FlxBar
		if (CompatEngine.isModern()) {
			var compatTimeBar:objects.Bar = new objects.Bar(0, timeTxt.y + (timeTxt.height / 4), 'timeBar', function() return songPercent, 0, 1);
			compatTimeBar.scrollFactor.set();
			compatTimeBar.screenCenter(X);
			compatTimeBar.alpha = 0;
			compatTimeBar.visible = showTime;
			timeBar = compatTimeBar;
			timeBarBG.visible = false; // the Bar class draws its own background
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
		// 1.0.4 loading order: alpha must not be 0 (Flixel would skip rendering and never preload the atlas/config),
		// so 0.000001 makes this splash load the splash atlas and its txt/json config into the cache during create()
		// instead of stalling on the first key press.
		splash.alpha = 0.000001;

		opponentStrums = new FlxTypedGroup<StrumNote>();
		playerStrums = new FlxTypedGroup<StrumNote>();

		// Rating popup pool: preallocated sprites replace the frequent new/destroy inside popUpScore
		ratingPopup = new RatingPopup();
		ratingPopup.targetCameras = [camHUD];
		ratingPopup.antialiasing = isPixelStage ? false : ClientPrefs.data.globalAntialiasing;
		ratingPopup.isPixel = isPixelStage;
		ratingPopup.daPixelZoom = daPixelZoom;
		if (CompatEngine.isModern())
		{
			// Compatibility mode: the container is comboGroup
			// Std.int() plus a type check avoid a null cast result
			ratingPopup.container = comboGroup;
			add(ratingPopup.container);
		}
		else
		{
			// Non-compatibility mode: the container is a standalone FlxSpriteGroup (no camera).
			// camHUD must be assigned explicitly, otherwise the group never sets Flixel's _defaultCameras
			// and children without their own camera render on the default game camera (the stage).
			ratingPopup.container.cameras = [camHUD];
			insert(members.indexOf(strumLineNotes), ratingPopup.container);
		}

		addAndroidControls(false, true);

		generateSong(SONG.song);

		// Do not add a Gc.run()/compact() here: hxcpp only returns block groups when
		// HXCPP_GC_MOVING is on (it is not), and create() holds live state reachable only from
		// native code, so a major collect here can sweep it and leave a dangling pointer.

		// 1.0.4: global/stage scripts are loaded after the characters and chart are generated
		if (CompatEngine.is104())
			loadGlobalAndStageScripts();

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

		// Compatibility mode uses the 0.7.3 Bar class; otherwise the stock FlxBar
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

		#if ONLINE_ALLOWED
		// Per-player score texts. This engine builds its HUD inline, so the same block runs right after
		// the local scoreTxt is built. All of it is behind GameClient.isConnected() and inside the
		// macro guard, so the single-player HUD is untouched.
		if (online.GameClient.isConnected()) {
			scoreTxt.visible = false;
			scoreTxtOriginY = ClientPrefs.data.downScroll ? 120 : 700;

			function createScoreText(isRight:Bool, ?ox:Int = 0, ?isOnline:Bool = false):FlxText {
				var scoreTxtPlayer = new FlxText(0, 0, FlxG.width, "", 20);
				scoreTxtPlayer.setFormat(Paths.languageFont(), (!isPixelStage ? 18 : 16) - (isOnline ? 2 : 0), FlxColor.WHITE, isRight ? RIGHT : LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
				scoreTxtPlayer.scrollFactor.set();
				scoreTxtPlayer.borderSize = 1.25;
				scoreTxtPlayer.visible = !ClientPrefs.data.hideHud;
				// flixel 5 uses `camera = camOther`; on 4.11 cameras is the array form.
				scoreTxtPlayer.cameras = [camOther];
				if (CompatEngine.isModern())
					uiGroup.add(scoreTxtPlayer);
				else
					add(scoreTxtPlayer);

				scoreTxtPlayer.y = scoreTxtOriginY - (ox * 20) - scoreTxtPlayer.height;

				if (isRight)
					scoreTxtPlayer.offset.x += 30;
				else
					scoreTxtPlayer.offset.x -= 30;

				if (!isRight && scoreTxtP1 == null)
					scoreTxtP1 = scoreTxtPlayer;

				if (isRight && scoreTxtP2 == null)
					scoreTxtP2 = scoreTxtPlayer;

				return scoreTxtPlayer;
			}

			if (online.GameClient.room.state.teamMode) {
				scoreTxtOthers.set('LEFTSIDE', createScoreText(false));
				scoreTxtOthers.set('RIGHTSIDE', createScoreText(true));

				var mySideText = scoreTxtOthers.get(getPlayerStats(online.GameClient.room.sessionId).player.bfSide ? 'RIGHTSIDE' : 'LEFTSIDE');
				if (mySideText != null) mySideText.color = FlxColor.YELLOW;
			}
			else {
				for (sid => player in online.GameClient.room.state.players) {
					// Fallback row from effectiveOx when the server provides no ox, to keep same-side texts apart.
					scoreTxtOthers.set(sid, createScoreText(player.bfSide, effectiveOx(sid), true));
				}

				var myText = scoreTxtOthers.get(online.GameClient.room.sessionId);
				if (myText != null) myText.color = FlxColor.YELLOW;
			}
		}
		#end

		botplayTxt = new FlxText(400, timeBarBG.y + 55, FlxG.width - 800, turboModeActive ? "TURBO BOTPLAY" : "BOTPLAY", 32);
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


		// Replay judging-feel hint (from LeatherEngine), shown only when it differs.
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

		// 诊断: 把模组/歌曲脚本的搜索路径与结果写进 logs/script_log.txt。
		backend.ScriptLog.write('scan', 'song=' + SONG.song + ' path=' + Paths.formatToSongPath(SONG.song)
			+ ' currentMod=' + Paths.currentModDirectory + ' globalMods=[' + Paths.getGlobalMods().join(",") + ']');

		for (folder in foldersToCheck)
		{
			var loadedHere:Int = 0;
			var folderExists:Bool = FileSystem.exists(folder);
			if(folderExists)
			{
				for (file in FileSystem.readDirectory(folder))
				{
					if(file.endsWith('.lua') && !filesPushed.contains(file))
					{
						luaArray.push(new FunkinLua(folder + file));
						filesPushed.push(file);
						loadedHere++;
					}
				}
			}
			backend.ScriptLog.write('folder', (folderExists ? 'ok      ' : 'MISSING ') + folder + '  lua=' + loadedHere);
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


			// fieldWidth <= 0 disables word-wrap and sizes the text to its content in FlxText
			// (set_fieldWidth: value <= 0 -> wordWrap = false, autoSize = true).
			// A fixed width makes longer values wrap and push the lines below it out of the HUD,
			// so every side-HUD entry has to stay on exactly one line.
			tnh = new FlxText(tnhx + 10, 259, 0, totalNotesText, 20);
			tnh.setFormat(20, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
			tnh.cameras = [camOther];
			tnh.font = Paths.languageFont();
			tnh.borderSize = 2;
			add(tnh);

			cm = new FlxText(-tnh.x + cmoffset, tnh.y + cmy, 0, combosText, 20);
			cm.setFormat(20, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
			cm.cameras = [camOther];
			cm.font = Paths.languageFont();
			cm.borderSize = 2;
			add(cm);

			if (ClientPrefs.data.marvelousRatings)
			{
				marv = new FlxText(cm.x, cm.y + 30, 0, marvelousesText, 20);
				marv.setFormat(20, FlxColor.fromRGB(255, 215, 0), LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
				marv.cameras = [camOther];
				marv.font = Paths.languageFont();
				marv.borderSize = 2;
				add(marv);
			}

			sick = new FlxText(cm.x, (marv != null ? marv.y : cm.y) + 30, 0, sicksText, 20);
			sick.setFormat(20, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
			sick.cameras = [camOther];
			sick.font = Paths.languageFont();
			sick.borderSize = 2;
			add(sick);

			good = new FlxText(cm.x, sick.y + 30, 0, goodsText, 20);
			good.setFormat(20, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
			good.cameras = [camOther];
			good.font = Paths.languageFont();
			good.borderSize = 2;
			add(good);

			bad = new FlxText(cm.x, good.y + 30, 0, badsText, 20);
			bad.setFormat(20, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
			bad.cameras = [camOther];
			bad.font = Paths.languageFont();
			bad.borderSize = 2;
			add(bad);

			shit = new FlxText(cm.x, bad.y + 30, 0, shitsText, 20);
			shit.setFormat(20, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
			shit.cameras = [camOther];
			shit.font = Paths.languageFont();
			shit.borderSize = 2;
			add(shit);

			miss = new FlxText(cm.x, shit.y + 30, 0, missesText, 20);
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
		// 0.7.3/1.0.4 compatibility: Lua's onCreatePost runs before super.create(),
		// while HScript's onCreatePost is called inside super.create(), so it is not duplicated here.
		backend.ScriptLog.write('state', 'before onCreatePost  luaArray=' + (luaArray == null ? 'null' : Std.string(luaArray.length)));
		callOnLuas('onCreatePost', []);
		backend.ScriptLog.write('state', 'after  onCreatePost');
		super.create();
		backend.ScriptLog.write('state', 'after  super.create()');
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

		// One-pass preload: large textures are committed to VRAM and their CPU copies released,
		// avoiding the occasional hitch from batched uploads in the first seconds of a song.
		GfxPolicy.preloadWarm();

		#if cpp
		// 强制 GC / compact 之前先把异步图形线程停在任务边界上: 收集期间不应该有
		// 第二个线程正在 new hxcpp 对象、或往共享表里写指针。超时也继续, 只记一条日志。
		var gfxQuiet:Bool = backend.AsyncGfxLoader.quiesce();
		try
		{
			if (ClientPrefs.data.disableGC)
			{
				_gcDisabledForSong = true;
				GcState.setDisabled(false);
				cpp.vm.Gc.run(true);
				cpp.vm.Gc.compact();
				GcState.setDisabled(true);
			}

			// Force a full GC after creation so the load-time collection does not
			// hit first gameplay. Disable with FNF_GC_FULL_ON_PLAY_CREATE=0.
			if (!ClientPrefs.data.disableGC && Sys.getEnv("FNF_GC_FULL_ON_PLAY_CREATE") != "0")
			{
				cpp.vm.Gc.run(true);
				// Compacts the heap after a major collection and returns free blocks to the OS (pure GC, no logic impact).
				cpp.vm.Gc.compact();
			}
		}
		catch (e:Dynamic)
		{
			// Haxe 没有 finally: 异常路径也要把 worker 放回去再往上抛。
			backend.AsyncGfxLoader.resume();
			throw e;
		}
		backend.AsyncGfxLoader.resume();
		if (!gfxQuiet)
			backend.ScriptLog.write('gc', 'async graphics worker still busy when the post-create forced GC ran (quiesce timed out)');
		#end

		CustomFadeTransition.nextCamera = camOther;
		} catch (e:Dynamic) {
			backend.ScriptLog.write('state', 'create() THREW: ' + Std.string(e));
			backend.ScriptLog.write('state', 'stack: ' + haxe.CallStack.toString(haxe.CallStack.exceptionStack()));
			throw e;
		}
	}

	/**
	 * Loads the global scripts/ and the current stage's scripts (Lua + HScript).
	 * 0.6.3/0.7.3 modes call it before the characters exist; 1.0.4 calls it after they and the chart are generated.
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
			if (!FileSystem.exists(folder))
			{
				backend.ScriptLog.write('folder', 'MISSING ' + folder + '  (global/stage scripts)');
				continue;
			}
			var dirContents:Array<String> = FileSystem.readDirectory(folder);
			backend.ScriptLog.write('folder', 'ok      ' + folder + '  (global/stage scripts, ' + dirContents.length + ' entries)');
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
			// Recompute sustain scale.y from the new songSpeed to avoid float drift from repeated multiplication and extreme render values.
			// Unmaterialised unspawnNotes are lightweight data; spawn rebuilds them with setupNoteData and the current songSpeed.
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
	/**
	 * 播放视频。
	 *
	 * 参数与 Psych Engine 1.0.4 的 `PlayState.startVideo` 对齐（全部可选，
	 * 旧调用点只传 name，行为完全不变）:
	 *   - forMidSong : true = 歌曲中途播放，不进入 cutscene、不触发 startAndEnd；
	 *   - canSkip    : 是否允许按键跳过；
	 *   - loop       : 是否循环播放；
	 *   - playOnLoad : 加载后是否立刻播放。
	 *
	 * English: Plays a video. Signature matches Psych Engine 1.0.4's
	 * `PlayState.startVideo`; every new parameter is optional, so existing
	 * one-argument call sites keep their exact previous behaviour.
	 */
	public function startVideo(name:String, forMidSong:Bool = false, canSkip:Bool = true, loop:Bool = false, playOnLoad:Bool = true)
	{
		#if VIDEOS_ALLOWED
		// 1.0.4: forMidSong 时不进入过场状态；其余情况保持旧行为。
		if (!forMidSong)
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
			if (!forMidSong)
				startAndEnd();
			else
				videoPlaying = false;
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
			video.canSkip = canSkip;
			video.autoPlay = playOnLoad;
			video.finishCallback = function()
			{
				videoPlaying = false;
				if (!forMidSong)
				{
					// 1.0.4 的 onVideoEnd 会清掉 inCutscene; 0.6.3/0.7.3 从不设置它
					// (正常路径下 startCountdown() 自己会清), 所以只在 1.0.4 下显式清, 保证旧模式零差异。
					if (CompatEngine.is104()) inCutscene = false;
					startAndEnd();
				}
				return;
			}
			video.playVideo(filepath, loop);
		});
		#else
		FlxG.log.warn('Platform not supported!');
		if (!forMidSong) startAndEnd();
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

		#if ONLINE_ALLOWED
		// The room status "In-Game" is sent once the preload finishes and the countdown is about to
		// start. This engine has no preloadTasks; the equivalent moment is the first countdown
		// request, and the ready gate below holds that request until the room broadcasts "startSong".
		if (online.GameClient.isConnected() && !isReady)
			online.GameClient.send("status", "In-Game");

		// Ready gating: while connected, the first countdown request only arms the
		// "press accept to start" overlay; the countdown itself runs when the room's "startSong"
		// message arrives. It follows startCountdown()'s wait-ready gate:
		// `if (!canStart) { canStart = true; add(waitReadySpr); return false; }` (source :2176-2180).
		if (!onlineCheckCanStart())
			return;
		#end

		if (Conductor.crochet <= 0 || !Math.isFinite(Conductor.crochet))
			Conductor.changeBPM((SONG != null && SONG.bpm > 0 && Math.isFinite(SONG.bpm)) ? SONG.bpm : 100);

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
                #if ONLINE_ALLOWED
                // Online keeps each player's screen as "self at the bottom, opponent on top" and skips the
                // single-player playOpponent arrow swap, otherwise a dad-side player would have to hit the
                // top arrows to line up.
                if (!online.GameClient.isConnected()) {
                #end
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
                #if ONLINE_ALLOWED
                }
                #end
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
			if(daNote != null && daNote.strumTime - 350 < time)
			{
				// The DTO above is a copy, so stored state has to go through the store.
				unspawnNotes.setWasHit(i, true);
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
		#if ONLINE_ALLOWED
		// updateScore() recomputes songPoints, reports it to the room when it changed, then hands the
		// whole HUD to updateScoreSID() and returns. Implemented as the leading guarded branch (this
		// engine builds its own score text through buildScoreText()/flushHitPresentation(), so the
		// online path bypasses that). With GameClient disconnected the original body below runs.
		if (online.GameClient.isConnected()) {
			var points:Float = FlxMath.roundDecimal(
				online.FunkinPoints.fcalcFP(ratingPercent, songMisses, songDensity, totalNotesHit, maxcombo), 2);
			if (points != songPoints) {
				songPoints = points;
				online.GameClient.send("updateSongFP", Math.ffloor(songPoints));
			}
			songPoints = points;

			updateScoreSID(online.GameClient.room.sessionId);
			return;
		}
		#end

		if (hasActiveScripts())
		{
			// With scripts: keep the per-hit callback semantics (preUpdateScore can intercept, onUpdateScore fires every time)
			var preResult:Dynamic = callOnScripts('preUpdateScore', [miss], true);
			if (preResult == LuaUtils.Function_Stop || preResult == FunkinLua.Function_Stop)
				return;

			applyScoreText();
			if(ClientPrefs.data.scoreZoom && !miss && !cpuControlled)
				bounceScoreTxt();
			callOnScripts('onUpdateScore', [miss]);
			return;
		}

		if (!ClientPrefs.data.perfMode)
		{
			applyScoreText();
			if(ClientPrefs.data.scoreZoom && !miss && !cpuControlled)
				bounceScoreTxt();
			return;
		}
		_scoreTextDirty = true;
		if (!miss && ClientPrefs.data.scoreZoom && !cpuControlled)
			_scoreZoomDirty = true;
	}

	/** Builds the score HUD text (the pure part of updateScore). */
	function buildScoreText():String
	{
		// Botplay (Turbo forces botplay): the H-Slice-style readout replaces the normal line. Manual
		// play returns the exact string below, so nothing mod-visible changes there.
		if (cpuControlled)
			return buildBotplayScoreText();

		#if ONLINE_ALLOWED
			/*
			 * The FP readout is folded into this one pure builder, because this engine does not
			 * mutate `scoreTxt` from updateScore(). Either form is produced:
			 *   ' | FP: ' + songPoints + ' (V5: ${...devFP(..., difficultyInfo)...})'  [newFPPreview]
			 *   ' | FP: ' + songPoints + ' (${...pointsPercent...}%)'
			 * `showFP`/`newFPPreview` are the ClientPrefs options (both default false), so with them off
			 * the returned string is exactly the one built without any FP suffix; disabling both
			 * options leaves the score text as before.
			 *
			 * The percentage branch uses this engine's `getPresencePoints()` (there is no
			 * `pointsPercent` field here), and the "V5" branch's percentage is rebuilt from the live
			 * numbers.
			 *
			 * The base string and the FP suffix share one branch per guard: the function used to be
			 * `inline`, which is why the two macro branches still carry their own `return` (the botplay
			 * early return above is the only other one). With the macro off, the original one-line body
			 * is what compiles.
			 */
		var txt:String = Language.get("scorelangtxt", "Score") + ': $songScore'
		+ " | " + Language.get("combobtxt", "Combo Breaks") + ': $songMisses'
		+  " | " + Language.get("acclangtxt", "Accuracy") + ':' + (ratingName != '?' ? ' ${Highscore.floorDecimal(ratingPercent * 100, 2)}% | $ratingFC ' : '') + '($ratingName)';

		var fpExtra:String = "";
		if (ClientPrefs.data.showFP)
		{
			if (ClientPrefs.data.newFPPreview)
			{
				var calcPoints:Float = FlxMath.roundDecimal(
					online.FunkinPoints.fcalcFP(ratingPercent, songMisses, songDensity, totalNotesHit, maxcombo), 2);
				var maxPoints:Float = online.FunkinPoints.calcFP(1, 0, songDensity, totalPlayed, totalPlayed);
				var pointsPercent:Float = maxPoints == 0 ? 0 : Math.min(1, Math.max(0, calcPoints / maxPoints));
				fpExtra += ' | FP: ' + songPoints
					+ ' (V5: ${FlxMath.roundDecimal(online.FunkinPoints.devFP(ratingPercent, songMisses, songDensity, totalNotesHit, maxcombo, difficultyInfo), 2)})'
					+ ' (${CoolUtil.floorDecimal(pointsPercent * 100, 1)}%)';
			}
			else
			{
				fpExtra += ' | FP: ' + songPoints + ' (' + getPresencePoints() + ')';
			}
		}
		return txt + fpExtra;
		#else
		return Language.get("scorelangtxt", "Score") + ': $songScore'
		+ " | " + Language.get("combobtxt", "Combo Breaks") + ': $songMisses'
		+  " | " + Language.get("acclangtxt", "Accuracy") + ':' + (ratingName != '?' ? ' ${Highscore.floorDecimal(ratingPercent * 100, 2)}% | $ratingFC ' : '') + '($ratingName)';
		#end
	}

	/**
	 * H-Slice-style botplay readout: both sides' hit notes, the live NPS of each side (current/max,
	 * the current value is the 1 s window with the attack/release filter of updateBotplayReadout)
	 * then the combined current/max, plus HP. Only the cpuControlled branch of
	 * buildScoreText() uses it, so manual play's line is untouched.
	 *
	 * Score is deliberately absent: botplay zeroes songScore/songHits every frame (see update()), so
	 * it would always read 0.
	 *
	 * @param compact keep only the combined NPS (used when the full line would not fit the HUD width).
	 */
	function buildBotplayScoreText(?compact:Bool = false):String
	{
		var op:Float = opCombo;
		var bf:Float = bfNotesHit();
		var line:String = Language.get("botscore_notes", "Notes") + ': '
			+ readoutNum(op) + ' + ' + readoutNum(bf) + ' = ' + readoutNum(op + bf)
			+ ' | ' + Language.get("botscore_nps", "NPS") + ': ';
		if (!compact)
			line += readoutNum(_npsOpShown) + '/' + readoutNum(_npsOpMax)
				+ ' + ' + readoutNum(_npsBfShown) + '/' + readoutNum(_npsBfMax) + ' = ';
		return line + readoutNum(_npsOpShown + _npsBfShown) + '/' + readoutNum(_npsSumMax)
			+ ' | ' + Language.get("botscore_hp", "HP") + ': ' + CoolUtil.floorDecimal(health * 50, 1) + '%';
	}

	/** Notes hit on the player's side: the engine's own judged-note accounting (totalPlayed) minus the misses. */
	inline function bfNotesHit():Float
		return (totalPlayed : Float) - songMisses;

	/** Readout number: whole notes / NPS (Turbo counts are far past display precision anyway). */
	inline function readoutNum(v:Float):String
		return Std.string(Math.ffloor(v + 0.5));

	/**
	 * Writes the score line into scoreTxt. In botplay the readout has to stay one centered line, so the
	 * full form is measured first and the compact form used when it would wrap (scoreTxt's fieldWidth
	 * is FlxG.width, which turns wordWrap on).
	 */
	function applyScoreText():Void
	{
		if (!cpuControlled)
		{
			scoreTxt.text = buildScoreText();
			return;
		}

		scoreTxt.wordWrap = false;
		scoreTxt.text = buildBotplayScoreText();
		if (scoreTxt.textField.textWidth > FlxG.width)
			scoreTxt.text = buildBotplayScoreText(true);
	}

	/**
	 * Botplay/Turbo readout: slides the 1 s NPS window to the current song time, adds the notes hit since
	 * the last frame on each side, then filters the displayed current values (fast attack, slow release)
	 * so a burst leaving the window fades the readout out instead of snapping it to 0. Allocation-free
	 * after the first call and only run while cpuControlled, so manual play pays nothing.
	 */
	function updateBotplayReadout(elapsed:Float):Void
	{
		var idx:Int = Std.int(Conductor.songPosition / NPS_BUCKET_MS);
		if (_npsOp == null)
		{
			_npsOp = [for (i in 0...NPS_BUCKETS) 0.0];
			_npsBf = [for (i in 0...NPS_BUCKETS) 0.0];
			_npsSlot = idx;
			_npsSeenOp = _opHitCount;
			_npsSeenBf = bfNotesHit();
			return;
		}

		if (idx != _npsSlot)
		{
			if (idx < _npsSlot)
			{
				// The song clock moved backwards. Only a real seek/restart (further back than the whole
				// window) makes the contents meaningless; a small step happens every time the engine
				// re-syncs the song position to the music (unpause, after a video), and blanking the
				// window there would snap the readout to 0 for no reason. Re-entered buckets are already
				// zero, so keeping them cannot double count.
				if (_npsSlot - idx > NPS_BUCKETS)
				{
					for (i in 0...NPS_BUCKETS)
					{
						_npsOp[i] = 0;
						_npsBf[i] = 0;
					}
					_npsOpVal = 0;
					_npsBfVal = 0;
				}
			}
			else
			{
				// Clear every bucket the window leaves behind; a jump longer than the window clears all of them.
				var steps:Int = Std.int(Math.min(idx - _npsSlot, NPS_BUCKETS));
				for (i in 0...steps)
				{
					var s:Int = ((_npsSlot + 1 + i) % NPS_BUCKETS + NPS_BUCKETS) % NPS_BUCKETS;
					_npsOpVal -= _npsOp[s];
					_npsBfVal -= _npsBf[s];
					_npsOp[s] = 0;
					_npsBf[s] = 0;
				}
			}
			if (_npsOpVal < 0) _npsOpVal = 0;
			if (_npsBfVal < 0) _npsBfVal = 0;
			_npsSlot = idx;
		}

		var slot:Int = ((idx % NPS_BUCKETS) + NPS_BUCKETS) % NPS_BUCKETS;
		// Hits since the last frame land in the current bucket. The opponent side reads the private
		// counter, so a script writing `opCombo` shows up in the total but never as a fake NPS burst;
		// the player side only accepts positive deltas for the same reason (a script writing
		// totalPlayed/songMisses must not look like hits).
		var dOp:Float = _opHitCount - _npsSeenOp;
		if (dOp > 0)
		{
			_npsOp[slot] += dOp;
			_npsOpVal += dOp;
		}
		_npsSeenOp = _opHitCount;

		var bf:Float = bfNotesHit();
		var dBf:Float = bf - _npsSeenBf;
		if (dBf > 0)
		{
			_npsBf[slot] += dBf;
			_npsBfVal += dBf;
		}
		_npsSeenBf = bf;

		// Maxima are recorded from the exact window values (true peaks), the displayed current values
		// get the ballistics filter.
		if (_npsOpVal > _npsOpMax) _npsOpMax = _npsOpVal;
		if (_npsBfVal > _npsBfMax) _npsBfMax = _npsBfVal;
		var sum:Float = _npsOpVal + _npsBfVal;
		if (sum > _npsSumMax) _npsSumMax = sum;

		var kUp:Float = elapsed * NPS_ATTACK_PER_SEC;
		var kDown:Float = elapsed * NPS_RELEASE_PER_SEC;
		if (kUp > 1) kUp = 1;
		if (kDown > 1) kDown = 1;
		_npsOpShown += (_npsOpVal - _npsOpShown) * (_npsOpVal >= _npsOpShown ? kUp : kDown);
		_npsBfShown += (_npsBfVal - _npsBfShown) * (_npsBfVal >= _npsBfShown ? kUp : kDown);
		if (_npsOpShown < 0.5) _npsOpShown = 0;
		if (_npsBfShown < 0.5) _npsBfShown = 0;
	}

	/** Score text bounce (the zoom tween block from updateScore). */
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


	/**
	 * Single entry point for every rating / combo popup (per-object, merged-per-frame, Turbo opponent and online).
	 * It also drops the per-call comboOffset copy and is the one place the F8 hit probe has to time.
	 */
	inline function showRatingPopup(target:RatingPopup, ratingKey:String, comboValue:Int, baseX:Float,
		showRatingSprite:Bool, showComboNumSprite:Bool):Void
	{
		var t0:Float = haxe.Timer.stamp();
		target.show(ratingKey, comboValue, playbackRate, baseX, ClientPrefs.data.hideHud,
			showRatingSprite, showCombo, showComboNumSprite, ClientPrefs.data.comboOffset,
			Conductor.crochet, ClientPrefs.data.comboStacking);
		_probePopupMs += haxe.Timer.stamp() - t0;
		_probeShows++;
	}

	/** Store this frame's slice in the F8 probe ring and clear the per-frame accumulators. */
	function commitHitProbeFrame():Void
	{
		if (_probeBuf == null)
			_probeBuf = [for (i in 0...(PROBE_FRAMES * PROBE_STRIDE)) 0.0];
		var base:Int = _probeIdx * PROBE_STRIDE;
		_probeBuf[base + PROBE_TOTAL] = _probeTotalMs;
		_probeBuf[base + PROBE_BULK] = _probeBulkMs;
		_probeBuf[base + PROBE_NOTES] = _probeNotesMs;
		_probeBuf[base + PROBE_SORT] = _probeSortMs;
		_probeBuf[base + PROBE_PRESENT] = _probePresentMs;
		_probeBuf[base + PROBE_POPUP] = _probePopupMs;
		_probeBuf[base + PROBE_SHOWS] = _probeShows;
		_probeBuf[base + PROBE_MEMBERS] = (ratingPopup != null && ratingPopup.container != null) ? ratingPopup.container.length : -1;
		_probeBuf[base + PROBE_COMBO] = combo;
		_probeBuf[base + PROBE_SCRIPT] = _probeScriptMs;
		_probeBuf[base + PROBE_SWEEPS] = _probeSweeps;
		_probeBuf[base + PROBE_SCOUNT] = probeScriptCount();
		var reqImp:Int = FunkinLua.probeRequireResolves + FunkinLua.probeImportResolves;
		_probeBuf[base + PROBE_REQIMP] = reqImp - _probeReqImpPrev;
		_probeReqImpPrev = reqImp;
		_probeIdx = (_probeIdx + 1) % PROBE_FRAMES;
		if (_probeFrames < PROBE_FRAMES) _probeFrames++;
		_probePopupMs = 0;
		_probeShows = 0;
		_probeScriptMs = 0;
		_probeSweeps = 0;
	}

	/**
	 * F8: write the last PROBE_FRAMES frames of hit-path timings to ./crash/hitprobe.txt.
	 * The per-frame table is oldest-first, so whether the frame cost keeps growing with the hit
	 * count is directly visible; the header carries the settings the run used.
	 */
	function dumpHitProbe():Void
	{
		#if sys
		try
		{
			if (_probeFrames <= 0)
			{
				TraceManager.info('trace.playState.hitProbeEmpty', 'Hit probe: no frames recorded yet');
				return;
			}
			var n:Int = (_probeFrames < PROBE_FRAMES) ? _probeFrames : PROBE_FRAMES;
			var start:Int = (_probeFrames < PROBE_FRAMES) ? 0 : _probeIdx;
			var fps:Int = 0;
			try { if (Main.fpsVar != null) fps = Main.fpsVar.currentFPS; } catch (e:Dynamic) {}

			var buf:StringBuf = new StringBuf();
			buf.add('# SeiunEngine hit probe\n');
			buf.add('# date=' + Date.now().toString() + '\n');
			buf.add('# song=' + ((SONG != null) ? SONG.song : '?') + ' fps=' + fps + '\n');
			buf.add('# perfMode=' + ClientPrefs.data.perfMode + ' turbo=' + turboModeActive
				+ ' limitNotes=' + ClientPrefs.data.limitNotes + ' fastSort=' + ClientPrefs.data.fastSort
				+ ' bulkSkip=' + ClientPrefs.data.bulkSkip + ' comboStacking=' + ClientPrefs.data.comboStacking + '\n');
			buf.add('# frames=' + n + ' combo=' + combo + ' luaScripts=' + probeLuaScriptCount()
				+ ' hscripts=' + probeHScriptCount() + '\n');
			buf.add('# columns: frame total bulk notes sort present popup shows members combo script sweeps scount reqimp\n');

			var names:Array<String> = ['total', 'bulk', 'notes', 'sort', 'present', 'popup', 'shows', 'members', 'combo', 'script', 'sweeps', 'scount', 'reqimp'];
			var sums:Array<Float> = [for (i in 0...PROBE_STRIDE) 0.0];
			var maxs:Array<Float> = [for (i in 0...PROBE_STRIDE) 0.0];
			for (f in 0...n)
			{
				var b:Int = ((start + f) % PROBE_FRAMES) * PROBE_STRIDE;
				for (c in 0...PROBE_STRIDE)
				{
					var v:Float = _probeBuf[b + c];
					sums[c] += v;
					if (v > maxs[c]) maxs[c] = v;
				}
			}
			for (c in 0...PROBE_STRIDE)
				buf.add('# ' + names[c] + ' avg=' + _probeFmt(sums[c] / n) + ' max=' + _probeFmt(maxs[c]) + '\n');

			buf.add('frame\ttotal\tbulk\tnotes\tsort\tpresent\tpopup\tshows\tmembers\tcombo\tscript\tsweeps\tscount\treqimp\n');
			for (f in 0...n)
			{
				var b:Int = ((start + f) % PROBE_FRAMES) * PROBE_STRIDE;
				buf.add(Std.string(f));
				for (c in 0...PROBE_STRIDE)
					buf.add('\t' + _probeFmt(_probeBuf[b + c]));
				buf.add('\n');
			}

			if (!FileSystem.exists('./crash/')) FileSystem.createDirectory('./crash/');
			File.saveContent('./crash/hitprobe.txt', buf.toString());
			TraceManager.info('trace.playState.hitProbe', 'Hit probe written to ./crash/hitprobe.txt (frames=' + n + ')');
		}
		catch (e:Dynamic) {}
		#end
	}

	/** Fixed 3-decimal ms text for the probe dump (Haxe 4.2 has no StringTools.format). */
	static inline function _probeFmt(v:Float):String
	{
		return Std.string(Math.round(v * 1000) / 1000);
	}

	/** Start/stop one fixed per-frame script dispatch slice (4 slices per frame; Timer.stamp is ~100ns). */
	inline function _probeScriptT0():Float {
		return haxe.Timer.stamp();
	}
	inline function _probeScriptT1(t0:Float):Void {
		_probeScriptMs += haxe.Timer.stamp() - t0;
	}

	/** Script counts for the probe header / scount column (0 when the runtime is compiled out). */
	function probeLuaScriptCount():Int {
		#if LUA_ALLOWED
		return luaArray != null ? luaArray.length : 0;
		#else
		return 0;
		#end
	}
	function probeHScriptCount():Int {
		#if HSCRIPT_ALLOWED
		return hscriptArray != null ? hscriptArray.length : 0;
		#else
		return 0;
		#end
	}
	inline function probeScriptCount():Int {
		return probeLuaScriptCount() + probeHScriptCount();
	}

	function flushHitPresentation():Void
	{
		if (_scoreTextDirty)
		{
			_scoreTextDirty = false;
			applyScoreText();
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
			showRatingPopup(ratingPopup, _pendingRatingImage, combo, FlxG.width * 0.35, showRating, showComboNum);
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
	 * Muted song pre-buffering (keep-playing):
 * playback starts at volume 0 during loading and the AudioSource stays alive.
 * PCM decoding (mp3 especially), OpenAL buffer upload and vorbis stream init all happen up front,
 * so at countdown end only the volume is restored instead of creating a new channel,
 * eliminating the first-play stall (very noticeable on long modded oggs).
	 */
	function prebufferSongAudio():Void
	{
		// Music track: reuse FlxG.sound.music and play it at volume 0
		try { FlxG.sound.playMusic(Paths.inst(PlayState.SONG.song), 0, false); } catch (e:Dynamic) {}

		var tracks:Array<FlxSound> = [vocals, vocalsPlayer, opponentVocals];
		for (snd in tracks)
		{
			if (snd == null || !snd.exists) continue;
			snd.volume = 0;
			try { snd.play(); } catch (e:Dynamic) {}
		}

		// Pause every source at the lime layer right after pre-buffering:
		// the AudioSource stays alive (no setup cost when the countdown restores it),
		// and a paused source outputs nothing, so no audio can leak during the countdown.
		pauseAudioSource(FlxG.sound.music);
		pauseAudioSource(vocals);
		pauseAudioSource(vocalsPlayer);
		pauseAudioSource(opponentVocals);
	}

	/** Pauses a source at the lime layer (channel and buffer kept; a paused source is silent). */
	function pauseAudioSource(snd:FlxSound):Void
	{
		if (snd == null || !snd.exists) return;

		@:privateAccess
		var source = FlxSound.getAudioSource(snd._channel);

		if (source != null)
		{
			try
			{
				source.pause();
			}
			catch (e:Dynamic) {}
		}
	}

	/**
	 * Seeks a track back to zero and resumes it (reusing the existing AudioSource, no new channel).
 * Falls back to stop+play when no live channel is found.
	 */
	function seekAudioToZero(snd:FlxSound):Void
	{
		if (snd == null || !snd.exists) return;

		@:privateAccess
		var source = FlxSound.getAudioSource(snd._channel);

		if (source != null)
		{
			try
			{
				source.currentTime = 0;
				source.play();
				return;
			}
			catch (e:Dynamic) {}
		}

		try { snd.stop(); } catch (e:Dynamic) {}
		try { snd.play(); } catch (e:Dynamic) {}
	}

	/** Countdown finished: restore the volume from zero and start playback for real. */
	function resumeSongAudio():Void
	{
		if (FlxG.sound.music != null && FlxG.sound.music.exists)
		{
			seekAudioToZero(FlxG.sound.music);
		}
		else
		{
			// Fallback: if pre-buffering failed, use the normal playback path
			try { FlxG.sound.playMusic(Paths.inst(PlayState.SONG.song), 1, false); } catch (e:Dynamic) {}
		}

		seekAudioToZero(vocals);
		seekAudioToZero(vocalsPlayer);
		seekAudioToZero(opponentVocals);

		// After everything is back at zero, restore the volume with an 80ms fade-in
		// that masks any leftover noise or leak from the seek/restart.
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

		// The channel already exists, so just re-apply the pitch
		vocals.pitch = playbackRate;
		vocalsPlayer.pitch = playbackRate;
		opponentVocals.pitch = playbackRate;
	}

	function startSong():Void
	{
		startingSong = false;
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
		// Remember which FlxSound owns this callback so destroy() can detach it.
		_songMusic = FlxG.sound.music;
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
	/**
	 * Everything except the chart bytes that decides what the note loop in generateSong() produces:
	 * the fold settings, the per-note interpretation switches and the tables the loop reads.
	 * ChartCache stores this string with the note list and compares it on the next load, so a changed
	 * setting is a cache miss rather than a wrong note list. Keep it in step with the loop.
	 */
	static function cacheConfig(mania:Int, songSpeed:Float, playOpponent:Bool, turboModeActive:Bool,
		streamRewrite:Bool, streamAmmo:Int):String
	{
		var ammo:Int = (mania >= 0 && mania < Note.ammo.length) ? Note.ammo[mania] : -1;
		return 'v1'
			+ '|speed=' + FlxMath.roundDecimal(songSpeed, 2)
			+ '|mania=' + mania
			+ '|ammo=' + ammo
			+ '|opp=' + playOpponent
			+ '|newver=' + Song.isNewVersion
			+ '|turbo=' + turboModeActive
			+ '|budget=' + MAX_CHART_NOTES
			+ '|gap=' + TurboDensity.DEFAULT_MIN_GAP_PX
			+ '|rep=' + TurboDensity.MAX_REPRESENTED
			+ '|rewrite=' + streamRewrite
			+ '|sAmmo=' + streamAmmo
			+ '|ntypes=' + Note.defaultNoteTypes.join(',');
	}

	private function generateSong(dataPath:String):Void
	{
		// Chart-load phase timers, reported by the 'Chart load phases' trace at the end of this
		// function: the only way to tell a slow parse from a slow note-list build without a profiler.
		var __t0:Float = haxe.Timer.stamp();
		var __tLoop:Float = __t0;
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

		// Pre-buffer the song audio: play it muted once during loading and stop it, forcing PCM decoding and
		// OpenAL buffer upload (very noticeable on mp3) so the first playback at countdown end does not stall.
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
		// Streaming turbo fold writes straight into packed columns (see the collapser branch).
		var packed:ChartNotes = null;
		var noteData:Array<SwagSection> = songData.notes;
		var songName:String = Paths.formatToSongPath(SONG.song);

		// Streamed chart: sectionNotes live on disk, never in memory. Each section is fetched
		// when needed and dropped right after, so the peak is a single section DOM.
		var chartStreamInfo:Dynamic = Reflect.field(songData, '__seiunStream');
		var chartStream:ChartStream.ChartSectionReader = null;
		// Part files of a segmented chart (see ChartParts); one entry for a one-file chart.
		var chartPaths:Array<String> = null;
		if (chartStreamInfo != null && noteData != null)
		{
			chartPaths = cast Reflect.field(chartStreamInfo, 'paths');
			if (chartPaths == null && chartStreamInfo.path != null) chartPaths = [chartStreamInfo.path];
			try
			{
				chartStream = (chartPaths != null)
					? new ChartStream.ChartSectionReader(chartPaths, chartStreamInfo.ranges) : null;
			}
			catch (e:Dynamic)
			{
				chartStream = null;
			}
		}
		var chartSectionIndex:Int = 0;
		// Streaming path only; hoisted out of the note loop (chartStreamInfo is Dynamic).
		var streamRewrite:Bool = (chartStream != null) && (chartStreamInfo.rewrite == true);
		var streamAmmo:Int = (chartStream != null && chartStreamInfo.ammo != null && Std.int(chartStreamInfo.ammo) > 0)
			? Std.int(chartStreamInfo.ammo) : 4;

		// Sidecar cache (ChartCache): the note list below is a pure function of the chart bytes and
		// the settings cacheConfig() collects, so a second load of the same chart replays it instead
		// of parsing, folding and sorting again. Streamed charts only, so ordinary charts are never
		// affected; ClientPrefs.data.chartCache turns it off completely.
		var notesCacheConfig:String = null;
		var cachedNotes:ChartCache.CachedNotes = null;
		if (chartStream != null && chartPaths != null && ClientPrefs.data.chartCache)
		{
			notesCacheConfig = cacheConfig(mania, songSpeed, playOpponent, turboModeActive, streamRewrite, streamAmmo);
			cachedNotes = ChartCache.loadNotes(chartPaths, notesCacheConfig);
		}
		var cacheHit:Bool = (cachedNotes != null);

		// Async section prefetch (ChartPrefetch): the per-section parse is pure data work, so it runs
		// on a worker while this thread builds the note list. Below PREFETCH_MIN_PAYLOAD_BYTES the
		// inline read is cheaper; a failure to start silently falls back to it.
		var chartPrefetch:ChartPrefetch = null;
		var streamPayloadBytes:Float = 0;
		if (!cacheHit && chartStream != null && chartStreamInfo.ranges != null)
		{
			var streamRanges:Array<ChartStream.ChartSectionRange> = cast chartStreamInfo.ranges;
			for (r in streamRanges) if (r != null) streamPayloadBytes += r.len;
			if (streamPayloadBytes >= PREFETCH_MIN_PAYLOAD_BYTES && chartPaths != null)
			{
				try chartPrefetch = new ChartPrefetch(chartPaths, streamRanges, PREFETCH_WORKERS)
				catch (e:Dynamic) chartPrefetch = null;
			}
		}

		// Fold incrementally while streaming: building every DTO first would peak at GBs of
		// intermediate array that Immix never returns to the OS.
		var collapser:TurboDensity.GhostCollapser = null;
		if (!cacheHit && turboModeActive && chartStream != null)
			collapser = new TurboDensity.GhostCollapser(Note.ammo[mania], 1.0, songSpeed, mania);
		else if (!cacheHit && chartStream != null && chartStreamInfo.noteCount != null
			&& chartStreamInfo.noteCount > MAX_CHART_NOTES)
		{
			// A note list this large cannot be materialised (358 bytes per note), so fold to the
			// representatives that are actually distinguishable on screen instead of attempting the
			// allocation. Same fold Turbo uses, so the path is already exercised.
			collapser = new TurboDensity.GhostCollapser(Note.ammo[mania], 1.0, songSpeed, mania);
			// chartStreamInfo.noteCount is a Float out of a Dynamic (exact up to 2^53). Std.int takes a
			// Float but truncates into Int32 above 2^31 (Std.int(3e9) == -1294967296), which would print
			// a negative count for exactly the chart sizes this budget exists for, so it is formatted
			// through Int64.fromFloat -> Int64.toStr. Cold path: only a chart past MAX_CHART_NOTES.
			trace('Chart has ' + haxe.Int64.toStr(haxe.Int64.fromFloat(chartStreamInfo.noteCount)) + ' notes (> ' + MAX_CHART_NOTES
				+ '); folding to screen-distinguishable representatives (chart-budget fallback, see PlayState.MAX_CHART_NOTES)');
		}

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
						// 0.7.3+/1.0.4: onEventPushed (fires when an event is queued)
						// 0.7.3+/1.0.4: onEventPushed (fires when an event is queued)
						callOnScripts('onEventPushed', [subEvent.event, subEvent.value1 != null ? subEvent.value1 : '', subEvent.value2 != null ? subEvent.value2 : '', subEvent.strumTime]);
					}
				}
			}
		}

		var stepCrochet:Float = Conductor.stepCrochet;
		var isNewVer:Bool = Song.isNewVersion;

		// Pre-build the Change Mania timeline: per-note key-count lookups fall from a full event scan O(E)
		// to a binary search O(log M), so loading no longer grows with the event count on dense charts.
		EKData.maniaTimelineBuild(songData.events, mania);

		// noteType string intern table (local to this function): JSON parsing creates a new String for every
		// note type, and duplicate strings on million-note charts hold hundreds of MB alive.
		var typeIntern:Map<String, String> = new Map<String, String>();

		// Multi-key: Change Mania events make the chart use a new key count from that point on; each note is
		// interpreted with the key count in effect at its own time, so notes before and after the event keep their own counts.
		// Prefetched chunks: section index -> parsed notes, refilled by ChartPrefetch when exhausted.
		var prefetched:Array<Array<ChartStream.ChartRawNote>> = null;
		var prefetchedPos:Int = 0;

		__tLoop = haxe.Timer.stamp();
		// Loop split: time blocked on the section parse vs time consuming that section's notes.
		var __tWait:Float = 0;
		var __tBody:Float = 0;
		if (cacheHit)
		{
			// Cache hit: the note list, the fold count and the note types come back exactly as the
			// loop below produced them. Nothing here reads a chart file, and the Conductor ends up
			// in the same state because the loop's per-section changeBPM() is overwritten by the
			// changeBPM(songData.bpm) after the loop regardless.
			packed = cachedNotes.notes;
			// 0 means "that load was not folded", in which case the phase trace below reports the
			// list length -- reproduce that here so a cached load logs the same number as a fresh one.
			_turboRawTapCount = (cachedNotes.fedNotes > 0) ? cachedNotes.fedNotes : packed.length;
			for (cachedType in cachedNotes.noteTypes) noteTypeMap.set(cachedType, true);
			chartSectionIndex = (noteData == null) ? 0 : noteData.length;
		}
		else for (section in noteData)
		{
			var __tw:Float = haxe.Timer.stamp();
			// Streaming: read this section's notes from disk. A failed read must not be skipped.
			if (chartStream != null)
			{
				// A range list shorter than the chart would silently drop every missing section's
				// notes (readNotes() returns [] for an out-of-range index), so it throws instead.
				if (chartSectionIndex >= chartStream.sectionCount())
					throw new haxe.Exception('chart stream: ' + chartStream.sectionCount() + ' section ranges for '
						+ noteData.length + ' sections (' + (chartPaths != null ? chartPaths.length : 0)
						+ ' part file(s), section ' + chartSectionIndex + ')');
				var rawNotes:Array<ChartStream.ChartRawNote> = null;
				if (chartPrefetch != null)
				{
					// ChartPrefetch hands over whole chunks in chart order and starts the next chunk
					// before returning, so the worker threads parse ahead of this loop.
					if (prefetched == null || prefetchedPos >= prefetched.length)
					{
						prefetched = chartPrefetch.nextChunk();
						prefetchedPos = 0;
					}
					if (prefetched != null && prefetchedPos < prefetched.length) rawNotes = prefetched[prefetchedPos++];
				}
				else
				{
					rawNotes = chartStream.readNotes(chartSectionIndex);
				}
				if (rawNotes == null)
					throw new haxe.Exception('chart stream: cannot read section ' + chartSectionIndex
						+ ' of ' + chartStream.pathOf(chartSectionIndex) + ' (' + chartStream.lastError + ')');
				section.sectionNotes = cast rawNotes;
			}
			__tWait += haxe.Timer.stamp() - __tw;
			var __tb:Float = haxe.Timer.stamp();
			chartSectionIndex++;

			if (section.changeBPM && section.bpm > 0 && Math.isFinite(section.bpm))
			{
				Conductor.changeBPM(section.bpm);
				stepCrochet = Conductor.stepCrochet;
			}

			var mustHit:Bool = section.mustHitSection;
			var gfSec:Bool = section.gfSection;

			for (songNotes in section.sectionNotes)
			{
				// Both paths meet here: songNotes is a JSON array after a full parse and a
				// ChartRawNote on the streaming path. Only these reads differ; the generation
				// below is shared, so a change cannot apply to just one of them.
				var rawStrum:Float;
				var rawData:Int;
				var susLen:Float;
				var noteTypeDyn:Dynamic;
				var noteCount:Int;
				if (chartStream != null)
				{
					var rn:ChartStream.ChartRawNote = cast songNotes;
					rawStrum = rn.strumTime;
					rawData = Std.int(rn.data);
					susLen = rn.sustain;
					noteTypeDyn = rn.type;
					noteCount = rn.count;
					// Per-note equivalent of ChartStream.rewriteSectionNotes(): negative data is
					// not remapped, but the note is still consumed.
					if (streamRewrite && rawData >= 0)
					{
						var rewriteHit:Bool = (rawData < streamAmmo) ? section.mustHitSection : !section.mustHitSection;
						rawData = (rawData % streamAmmo) + (rewriteHit ? 0 : streamAmmo);
						if (noteCount > 3 && !Std.isOfType(noteTypeDyn, String) && noteTypeDyn != null)
						{
							var typeIdx:Int = Std.int(noteTypeDyn);
							noteTypeDyn = (typeIdx >= 0 && typeIdx < Note.defaultNoteTypes.length)
								? Note.defaultNoteTypes[typeIdx] : '';
						}
						else if (noteCount <= 3) noteTypeDyn = '';
					}
				}
				else
				{
					rawStrum = songNotes[0];
					rawData = Std.int(songNotes[1]);
					susLen = songNotes[2];
					noteTypeDyn = songNotes[3];
					noteCount = songNotes.length;
				}
				var noteMania:Int = EKData.maniaAtTimeCached(rawStrum);
				var noteAmmo:Int = Note.ammo[noteMania];
				var noteDataIdx:Int = rawData % noteAmmo;

				var gottaHitNote:Bool = isNewVer ? (rawData < noteAmmo) : (rawData >= noteAmmo ? !mustHit : mustHit);
				var isGFSide:Bool = gfSec && (gottaHitNote == mustHit);
				if (playOpponent) gottaHitNote = !gottaHitNote;

				var noteType:String = noteTypeDyn;
				if (!Std.isOfType(noteTypeDyn, String))
					noteType = Note.defaultNoteTypes[Std.int(noteTypeDyn)];
				else
				{
					// Intern the string and write it back to the DOM: strings are immutable, so
					// this only removes duplicate objects. The streaming path has no DOM.
					var interned:String = typeIntern.get(noteType);
					if (interned == null)
						typeIntern.set(noteType, noteType);
					else
					{
						noteType = interned;
						if (chartStream == null) songNotes[3] = interned;
					}
				}

				if (!noteTypeMap.exists(noteType))
					noteTypeMap.set(noteType, true);

				var isAlt:Bool = (noteType == 'Alt Animation');
				var isHurt:Bool = (noteType == 'Hurt Note');
				var isGF:Bool = isGFSide || noteType == 'GF Sing';
				var isNoAnim:Bool = (noteType == 'No Animation');
				var isAltSuffix:String = isAlt ? '-alt' : '';

				// Fold/Turbo raw path (GhostCollapser.wantsRepresentative): decide from the note's own
				// fields whether this tap becomes a representative BEFORE building a PreloadedChartNote,
				// so the notes that merge are never allocated at all. The merge rules are
				// GhostCollapser.feed()'s. Holds (susLen > 0) never merge and go through pushHold()
				// once their DTO exists.
				var foldHold:Bool = (collapser != null) && susLen > 0;
				if (collapser != null && !foldHold
					&& !collapser.wantsRepresentative(rawStrum, noteDataIdx, gottaHitNote))
					continue;

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
					sustainLength: susLen,
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
				if (collapser != null)
				{
					if (foldHold) collapser.pushHold(swagNote) else collapser.commitRepresentative(swagNote);
				}
				else preloadedNotes.push(swagNote);

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
					if (collapser != null) collapser.pushHold(sustainNote) else preloadedNotes.push(sustainNote);
				}
			}

			if (chartStream != null) section.sectionNotes = [];

		__tBody += haxe.Timer.stamp() - __tb;
		}

		if (chartStream != null)
		{
			// One line that says whether every part really was read and turned into notes. A note
			// count of ~13M for a 29-part chart means only part 0 was generated.
			trace('Chart stream: ' + chartSectionIndex + ' sections from '
				+ (chartPaths != null ? chartPaths.length : 0) + ' part file(s), ranges='
				+ chartStream.sectionCount() + ', notes='
				+ (cacheHit ? cachedNotes.fedNotes
					: (collapser != null ? collapser.fedCount : preloadedNotes.length))
				+ ', turbo=' + turboModeActive + ', mania=' + mania);
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
					// 0.7.3+/1.0.4: onEventPushed (fires when an event is queued)
					// 0.7.3+/1.0.4: onEventPushed (fires when an event is queued)
					callOnScripts('onEventPushed', [subEvent.event, subEvent.value1 != null ? subEvent.value1 : '', subEvent.value2 != null ? subEvent.value2 : '', subEvent.strumTime]);
				}
			}
		}


		// Sort preloaded notes by time
		// Guard: if the array is corrupted with null slots during generation, the sort closure dereferences
		// them natively and crashes (hxcpp does not check for a null this; it triggered rarely on restarts).
		// The normal path is one O(n) pointer scan; when nulls are found the array is rebuilt without them.
		// hxcpp indeed never checks for null.
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
		if (cacheHit)
		{
			// A cached list is stored in its final order; sorting it again could permute notes that
			// share a strum time, so only a freshly generated list goes through the sort below.
		}
		else if (chartStream != null)
		{
			// Streaming path: bucket sort, since Array.sort needs ~2.8s for 11.8M notes.
			// See ChartSort and tools/online_probe/ChartSortProbe.
			ChartSort.sortPreloadedNotes(preloadedNotes);
		}
		else
		{
			preloadedNotes.sort(function(a, b) {
				if (a == null || b == null)
					return 0;
				return FlxSort.byValues(FlxSort.ASCENDING, a.strumTime, b.strumTime);
			});
		}
		lastChartNoteTime = 0;
		if (packed != null)
		{
			// A hit hands over packed columns; reading the end from the empty Array would leave
			// lastChartNoteTime at 0 and the "chart finished" check would fire on frame one.
			if (packed.length > 0) lastChartNoteTime = packed.strumTimeAt(packed.length - 1);
		}
		else if (preloadedNotes.length > 0 && preloadedNotes[preloadedNotes.length - 1] != null)
			lastChartNoteTime = preloadedNotes[preloadedNotes.length - 1].strumTime;

		// Turbo: fold taps by screen pixel gap -- at low scroll speed the visible band spans several seconds,
		// which can hold six figures of notes on very dense charts; most of them overlap completely on screen
		// (same lane and direction, only a few pixels apart), so materialising them all is pure waste.
		// After folding, the living sprite count depends only on speed x screen geometry x lane count.
		// This is a pure data transform: no caller objects are mutated, nothing is cached and repeated calls are identical.
		if (!cacheHit) _turboRawTapCount = 0;
		if (collapser != null)
		{
			// Streaming emits notes in file order, so re-sort by strum time for the consumers
			// (spawn / fastSkipPastNotes) that assume ascending order. The array is already
			// collapsed, so this sort is cheap.
			_turboRawTapCount = collapser.fedCount;
			// The fold appends into packed columns; sorting permutes them via the key column.
			packed = collapser.finish();
			packed.sortByStrumTime();
			lastChartNoteTime = 0;
			if (packed.length > 0)
				lastChartNoteTime = packed.strumTimeAt(packed.length - 1);
		}
		else if (turboModeActive && !cacheHit)
		{
			_turboRawTapCount = preloadedNotes.length;
			preloadedNotes = TurboDensity.collapseGhostNotes(preloadedNotes, Note.ammo[mania], 1.0, songSpeed, mania);
		}

		// Lightweight chart data: notes are no longer materialised up front.
		// Notes are built by the spawn loop only when they enter the generation window, so peak memory is the living notes, not the whole chart.
		// A fold already produced packed columns; every other path hands over an Array, which
		// ChartNotes converts once here.
		if (packed != null) unspawnNotes = packed;
		else unspawnNotes = preloadedNotes;

		lastSpawnedNote = new Map<Int, Note>();

		// Miss on a streamed chart: keep the finished list so the next load of this chart with these
		// settings does not parse, fold and sort it again. Written here, before any consumer can
		// touch the DTOs, so what lands on disk is exactly what the loop produced (see ChartCache).
		if (!cacheHit && notesCacheConfig != null)
		{
			var cachedTypes:Array<String> = [for (key in noteTypeMap.keys()) key];
			ChartCache.saveNotes(chartPaths, notesCacheConfig, unspawnNotes, _turboRawTapCount,
				collapser != null, cachedTypes, ClientPrefs.data.chartCacheCompress);
		}

		if (chartStream != null)
		{
			// Per-30s note counts over the materialised chart, so a load log alone shows where the
			// notes actually are (the split parts leave long empty stretches on purpose).
			var bucketMs:Float = 30000;
			var buckets:Array<Int> = [];
			for (i in 0...unspawnNotes.length)
			{
				var bucket:Int = Std.int(unspawnNotes.strumTimeAt(i) / bucketMs);
				if (bucket < 0) bucket = 0;
				while (buckets.length <= bucket) buckets.push(0);
				buckets[bucket]++;
			}
			var histogram:StringBuf = new StringBuf();
			for (i in 0...buckets.length)
			{
				if (histogram.length > 0) histogram.add(' ');
				histogram.add(Std.string(i * 30) + 's=' + buckets[i]);
			}
			trace('Chart notes per 30s: ' + histogram.toString());
		}
		_chartHasHolds = unspawnNotes.hasHolds();

		if (turboModeActive)
		{
			trace('Turbo: chart notes ' + _turboRawTapCount + ' -> ' + unspawnNotes.length
				+ ' representatives (represented=' + TurboDensity.representedTotal(unspawnNotes)
				+ ', speed=' + FlxMath.roundDecimal(songSpeed, 2) + ', mania=' + mania + ')');
		}

		#if ONLINE_ALLOWED
		/*
			 * The song-density score is computed right after the note-generation loop:
			 *
			 *     songDensity = playingNoteCount == 0 ? 0 : playingNoteCount / (inst.length / playbackRate / 1000) / 2;
			 *
			 * `playingNoteCount` counts the *tap* notes that belong to the player's side, only when
			 * more than 10 ms separate them from the previously counted one. This engine's note loader
			 * builds `PreloadedChartNote` DTOs instead of live `Note` objects, so the predicate is
			 * `pn.mustPress == playsAsBF()`, and sustain segments are skipped because the counter is
			 * incremented on the tap note only, before the sustain loop.
			 * The value is used by `online.FunkinPoints.(f)calcFP/devFP` only; nothing else reads it,
			 * so the exact insertion point inside generateSong() is immaterial.
			 * It reads the just-sorted `preloadedNotes` (before the Turbo collapse below), which is
			 * the full tap set.
			 * Only tap notes of the player's own side count; opponent notes and sustains do not
			 * inflate the density.
		 */
		var fpPlayerNoteCount:Float = 0;
		var fpPlayerLastStrumTime:Float = 0;
		for (pn in preloadedNotes)
		{
			if (pn == null || pn.isSustainNote) continue;
			if (pn.mustPress != playsAsBF()) continue;
			if (pn.strumTime - fpPlayerLastStrumTime > 10)
				fpPlayerNoteCount++;
			fpPlayerLastStrumTime = pn.strumTime;
		}
		songDensity = (fpPlayerNoteCount == 0 || inst == null || inst.length <= 0 || playbackRate <= 0)
			? 0 : fpPlayerNoteCount / (inst.length / playbackRate / 1000) / 2;
		#end

		if (eventNotes.length > 1)
			eventNotes.sort(sortByTime);

		checkEventNote();

		if (Math.isNaN(songData.bpm) || songData.bpm <= 0)
			Conductor.changeBPM(100);
		else
			Conductor.changeBPM(songData.bpm);

		#if ONLINE_ALLOWED
		/*
			 * The chart-difficulty info is computed here, at the end of the note-generation loop,
			 * and the V5 FP readout reads it back:
			 *   difficultyInfo = online.ChartAnalyzer.calc(songData, playsAsBF());
			 *   trace(difficultyInfo);
			 * `prepareNetSong()` is NOT called: it would submit the song to the account backend
			 * through `online.network.FunkinNetwork.hasAccess('/api/admin/song/submit')`.
			 * `playOpponent` is always false while the chart loads, so passing `playsAsBF()` here
			 * can only express "BF side" -- that is what the analyzer needs. On the streaming path
			 * it reads the generated PreloadedChartNote list.
		 */
		// On the streaming path songData.notes[].sectionNotes is empty (the DOM is not resident), so
		// the analysis reads the generated PreloadedChartNote list instead.
		difficultyInfo = (chartStream != null)
			? online.ChartAnalyzer.calcFromPreloaded(unspawnNotes, playsAsBF())
			: online.ChartAnalyzer.calc(songData, playsAsBF());
		#end

		// Captured before the close()/null below: the phase trace has to report whether the async
		// prefetch actually ran, and reading chartPrefetch after this point always said false.
		var __usedPrefetch:Bool = chartPrefetch != null;
		if (chartPrefetch != null)
		{
			chartPrefetch.close();
			chartPrefetch = null;
		}

		if (chartStream != null)
		{
			chartStream.close();
			chartStream = null;
		}

		// One line per chart load that says where the notes went (the phase timers at the top of
		// generateSong). parse+build is the section parse plus one PreloadedChartNote per surviving
		// note; when 'folded=true' the merged notes are decided from raw fields and never allocated.
		trace('Chart load phases: scan+setup=' + FlxMath.roundDecimal(__tLoop - __t0, 3) + 's'
			+ ' parse+build=' + FlxMath.roundDecimal(haxe.Timer.stamp() - __tLoop, 3) + 's'
			+ ' sectionWait=' + FlxMath.roundDecimal(__tWait, 3) + 's'
			+ ' perNoteBody=' + FlxMath.roundDecimal(__tBody, 3) + 's'
			+ ' total=' + FlxMath.roundDecimal(haxe.Timer.stamp() - __t0, 3) + 's'
			// Int64.toStr: this value has to print exactly, and Std.int would truncate above 2^31.
			+ ' notesFed=' + haxe.Int64.toStr(cacheHit ? _turboRawTapCount
				: (collapser != null ? collapser.fedCount : unspawnNotes.length))
			+ ' representatives=' + unspawnNotes.length
			+ ' folded=' + (cacheHit ? cachedNotes.folded : collapser != null)
			+ ' prefetch=' + __usedPrefetch
			+ ' cache=' + (cacheHit ? 'hit' : (notesCacheConfig != null ? 'miss' : 'off')));

		// Pack the chart into columns and drop the DTO array: this is the only place unspawnNotes
		// is filled, and everything afterwards reads it through ChartNotes.
		preloadedNotes = null;

		generatedMusic = true;
	}

	// ─────────────────────────────────────────────────────────────
	// Turbo chart pre-processing
	// ─────────────────────────────────────────────────────────────
	// All dense-section work happens at load time (TurboDensity.collapseGhostNotes):
	// taps that cannot be told apart on screen fold into representatives whose noteDensity is the merged count,
	// and the runtime settles them in clusters (see bulkSettleNote).
	//
	// There is deliberately no "dense cluster" side cache:
	//   - its content was index ranges into unspawnNotes, i.e. position-dependent state; any folding
	//     change shifted it and a bad index fails silently by computing the wrong range;
	//   - the old folding mutated shared objects (prev.noteDensity += 1), so repeating it over the same
	//     array gave different results and kept writing new cache files for one chart;
	//   - with pixel-level folding the materialised count is already bounded by speed and screen geometry,
	//     so the saved O(n) scan is worth far less than the invalidation risk.

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
		// 1.0.4: eventEarlyTrigger 回调带完整参数 (event, value1, value2, strumTime)。
		// 0.6.3/0.7.3 脚本只声明一个参数时，多出来的实参在 Lua/HScript 里都会被忽略。
		var returnedValue:Float = callOnScripts('eventEarlyTrigger', [event.event, event.value1, event.value2, event.strumTime]);
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
		// Multi-key: with middleScroll the opponent strums spread to both screen edges to avoid overlapping the player's
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
	 * Multi-key: switch the chart key count mid-song (Change Mania event / Lua / HScript call).
 * Old strums animate out, strums are rebuilt, the new key count takes effect. Notes already generated keep
 * their key-count snapshot until destroyed; later notes use the new count.
	 *
 * The transition can be customised from Lua/HScript:
 * - onChangeManiaStart fires first and may return true / Function_Stop to take over the animation completely
 *   (the engine skips its built-in transition and the script can use noteTweenX/doTweenX).
 * - Otherwise the built-in animation for animStyle plays; the built-ins are
 *   fade / slide / zoom / spin.
 * - The style can be passed to setMania(k, skip, "style") / changeMania(...) from Lua/HScript or via event Value 2,
 *   or preset with setVar('maniaChangeAnimStyle', 'style').
	 *
 * @param skipStrumFadeOut skips the transition animation when true
 * @param animStyle built-in style name (fade/slide/zoom/spin); empty uses the script variable, default fade
	 */
	public function changeMania(newValue:Int, skipStrumFadeOut:Bool = false, ?animStyle:String = null)
	{
		newValue = EKData.clampMania(newValue);
		if (newValue == mania && strumLineNotes != null && strumLineNotes.length == Note.ammo[mania] * 2)
			return;

		var daOldMania:Int = mania;

		// Animation style: argument > script variable > default fade
		if (animStyle == null || animStyle.length < 1)
			animStyle = Std.string(getScriptManiaAnimStyle());
		if (animStyle == null || animStyle.length < 1) animStyle = 'fade';

		// Lua/HScript may take over: returning true/Function_Stop from onChangeManiaStart skips the built-in transition
		var customAnim:Bool = false;
		var scriptResult:Dynamic = callOnScripts('onChangeManiaStart', [newValue, daOldMania, animStyle]);
		if (scriptResult == true || scriptResult == FunkinLua.Function_Stop)
			customAnim = true;

		mania = newValue;

		// Built-in transition: the old strums exit with the chosen style (skippable by skip / a script takeover)
		if (!skipStrumFadeOut && !customAnim && strumLineNotes != null)
			playManiaStrumOutAnim(animStyle);

		playerStrums.clear();
		opponentStrums.clear();
		strumLineNotes.clear();

		// Sync the key bindings of the new key count
		var allKeybinds:Array<Array<Dynamic>> = Keybinds.fill();
		keysArray = (mania >= 0 && mania < allKeybinds.length) ? allKeybinds[mania] : allKeybinds[3];
		setOnScripts('mania', mania);
		setOnScripts('keys', mania + 1);

		// Temporarily disable the entry tween inside generateStaticArrows so the built-in animation takes over (the script path keeps its behaviour)
		var prevSkipArrowTween:Bool = skipArrowStartTween;
		if (!skipStrumFadeOut && !customAnim) skipArrowStartTween = true;
		generateStaticArrows(0);
		generateStaticArrows(1);
		skipArrowStartTween = prevSkipArrowTween;

		// Built-in transition: the new strums enter
		if (!skipStrumFadeOut && !customAnim)
			playManiaStrumInAnim(animStyle);

		// Multi-key: rebuild the keyboard display after a key-count change (count/names/stats bar)
		if (keyboardDisplay != null)
			keyboardDisplay.rebuild();

		// Multi-key: reset the scale of already generated notes to match the new strum size
		// Only notes whose mania snapshot matches the current key count are reset, so other segments keep their scale
		// (above 9K the strums shrink a lot and stale note scales would no longer line up)
		// Unmaterialised unspawnNotes are lightweight data and spawn with their own mania snapshot, so they need no adjustment here.
		for (note in notes.members)
			if (note != null && note.exists && note.noteData > -1 && note.mania == mania) note.resetNoteScaleForMania(mania);

		callOnScripts('onChangeMania', [mania, daOldMania]);
	}

	/**
	 * Reads the key-count-change animation style preset by a script.
 * HScript: `maniaChangeAnimStyle = "slide";` (the engine reads the global variable).
 * Lua: preferably pass the style directly to `setMania(k, skip, "style")` / `changeMania(k, skip, "style")`.
	 */
	function getScriptManiaAnimStyle():String
	{
		var v:Dynamic = null;
		#if HSCRIPT_ALLOWED
		for (script in hscriptArray) { if (script != null && !script.closed) { v = script.get('maniaChangeAnimStyle'); if (v != null) break; } }
		#end
		return (v != null) ? Std.string(v) : '';
	}

	/** Old strum exit animation: fade / slide out / zoom out / spin out. */
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
					// Player side slides right, opponent side slides left
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

	/** New strum entry animation: fade / slide in from the sides / zoom in / spin in. */
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

	/** Multi-key HScript API: current key count (1-based). */
	public function getManiaK():Int
	{
		return mania + 1;
	}

	/** Multi-key HScript API: change the texture of a note. */
	public function setNoteTextureByIndex(noteIndex:Int, texture:String):Bool
	{
		if (texture == null || noteIndex < 0 || noteIndex >= notes.length) return false;
		var note:Note = notes.members[noteIndex];
		if (note == null || !note.exists || note.noteData < 0) return false;
		// Custom textures skip multi-key tinting (default/empty textures restore the lane colour)
		note.applyLaneColorShader = (texture.length < 1 || texture == 'NOTE_assets');
		note.texture = texture;
		note.reloadNote('', texture);
		if (note.applyLaneColorShader) note.applyLaneColor();
		return true;
	}

	/** Multi-key HScript API: change the character animation of a note's hit. */
	public function setNoteCharAnimByIndex(noteIndex:Int, anim:String):Bool
	{
		if (noteIndex < 0 || noteIndex >= notes.length) return false;
		var note:Note = notes.members[noteIndex];
		if (note == null || !note.exists) return false;
		note.customCharAnim = (anim == null || anim.length < 1) ? null : anim;
		return true;
	}

	/** Multi-key HScript API: set a note's colour directly (hue/sat/brt, 0~360/0~100/0~100). */
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
		// With perfMode off the budget is unlimited: popups/splashes go straight back to stock per-hit display with no living cap.
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
		_probeFrameStart = _phaseT;

		#if ONLINE_ALLOWED
		/*
			 * In-game FP-counter toggle on `FlxG.keys.justPressed.F7`, next to the other
			 * debug hotkeys handled by update().
			 * This is what makes the FP readout wired into `buildScoreText()`
			 * observable without editing the save file, and it is the F7 key the setting's own
			 * description advertises.
			 *
			 * It lives in the online guard on purpose: `showFP` / `newFPPreview` and the counter
			 * itself are online-only additions, so with `ONLINE_ALLOWED` off the key map stays
			 * untouched. Only the two values it assigns are new; the
			 * dirty-flag refreshes below are this engine's own score-text mechanism.
		 */
		if (FlxG.keys.justPressed.F7)
		{
			ClientPrefs.data.showFP = !ClientPrefs.data.showFP;
			ClientPrefs.saveSettings();
			_scoreTextDirty = true;
			_scoreZoomDirty = true;
		}

		// Ctrl+P lets a client take over the opponent side, which is also the escape hatch that
		// un-gates the local opponent auto-hit below.

		if (FlxG.keys.pressed.CONTROL && FlxG.keys.justPressed.P)
			playOtherSide = !playOtherSide;

		// Ready gating: the ACCEPT branch tells the room this client is ready. The overlay is a
		// plain Alphabet, so its text is swapped instead of flickering a dedicated ready sprite.

		if (online.GameClient.isConnected() && !isReady && controls.ACCEPT && canStart && !inCutscene)
		{
			isReady = true;
			FlxG.sound.play(Paths.sound('confirmMenu'), 0.5);
			if (waitReadySpr != null)
				waitReadySpr.text = "waiting for other player...";
			online.GameClient.send("playerReady");
		}

		// Report the local health delta to the room, which accumulates it into Room.health and broadcasts it.
		syncOnlineHealth();
		#end

		// F8: dump the last PROBE_FRAMES frames of hit-path timings to ./crash/hitprobe.txt.
		// Deliberately outside the online guard: the 100k-NPS repro is a single-player run.
		if (FlxG.keys.justPressed.F8)
			dumpHitProbe();

		/*if (FlxG.keys.justPressed.NINE)
		{
			iconP1.swapOldIcon();
		}*/
		var _probeScA:Float = _probeScriptT0();
		callOnScripts('onUpdate', [elapsed]);
		_probeScriptT1(_probeScA);

		// Lua wiggle effects (addWiggleEffect in FunkinLua) advance with the same clock the scripts
		// get: the shader is already on the sprite, this is only its uTime.
		for(wig in wiggleMap) wig.update(elapsed);

		// 模组把 scoreTxt 关掉（1.0.4 通用的"关掉 HUD"写法）时，引擎自带的 side HUD 与
		// 键盘-KPS 面板必须一起关，否则会盖在模组自制界面上面。见 syncHudExtras()。
		syncHudExtras();
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

		// F8 probe + one sweep for both globals (same instant, same per-script order).
		var _probeScB:Float = _probeScriptT0();
		setOnScripts2('curDecStep', curDecStep, 'curDecBeat', curDecBeat);
		_probeScriptT1(_probeScB);

		if(botplayTxt.visible) {
			botplaySine += 180 * elapsed;
			botplayTxt.alpha = 1 - Math.sin((Math.PI * botplaySine) / 180 * playbackRate);
		}
		if(botplayTxt != null && cpuControlled && !botplayUsed) botplayUsed = true;

		// Botplay/Turbo readout: keep the 1 s NPS window current and the score line live (outside
		// botplay scoreTxt is only rebuilt per hit). flushHitPresentation() runs later in this update.
		if (cpuControlled)
		{
			updateBotplayReadout(elapsed);
			_scoreTextDirty = true;
		}
		if(replayTxt.visible) {
			replaySine += 180 * elapsed;
			replayTxt.alpha = 1 - Math.sin((Math.PI * replaySine) / 180);
		}


		if ((controls.PAUSE	#if android || FlxG.android.justReleased.BACK #end) && startedCountdown && canPause)
		{
			var ret:Dynamic = callOnScripts('onPause', [], false);
			if(ret != FunkinLua.Function_Stop#if VIDEOS_ALLOWED && !videoPlaying #end)  {
				openPauseMenu();
			}
		}

		if (FlxG.keys.anyJustPressed(debugKeysChart) && !endingSong && !inCutscene)
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
			// Exact living count: with perfMode off it matches the pre-submit behaviour via FlxTypedGroup.countLiving(),
			// so notes added by scripts are still counted; with perfMode on it reads the compact list (O(1)).
			limitNC = ClientPrefs.data.perfMode ? activeNotes.length : notes.countLiving();

			// Adaptive materialisation budget: longer frames may spawn more (catch up after a drop and recover);
			// notes inside hardDeadline (at the strum line) ignore the budget and always spawn, prioritising playability over smoothing.
			var hardDeadline:Float = Conductor.songPosition + Conductor.safeZoneOffset;
			var spawnBudget:Int = Std.int(Math.max(2048, Math.min(20000, elapsed * 1000 * 30)));
			// Overload is judged from this frame's data-level drain: a clearly non-zero drain means arrivals outpace
			// materialisation, so due notes are settled by the data path, materialisation keeps only a small quota
			// near the line and the hard deadline no longer forces spawns (behind, forced spawns pay for notes the data layer will settle).
			// Hysteresis: a clearly non-zero drain fills 30 frames, otherwise the counter decays per frame.
			// When drain briefly returns to zero (e.g. the cursor pinned by a sustain head) the hysteresis avoids toggling the throttle.
			if (_bulkDrainedLast >= 128) _overloadFrames = 30;
			else if (_overloadFrames > 0) _overloadFrames--;
			var perfOn:Bool = ClientPrefs.data.perfMode;
			// Critical: materialisation throttling must only exist under botplay. Manual mode has no data-layer
			// absorption path (fastSkipPastNotes uses softCut = -inf), so the only effect of throttling is to let the
			// spawn cursor fall behind the visible horizon: the lag in ms x scroll speed is how deep notes pop in
			// from mid-screen, and a spawnable head with a missing tail looks like a swallowed sustain.
			// Manual mode restores unlimited stock throughput, keeping only the noteLimit cap and the visible horizon gate.
			var behind:Bool = perfOn && cpuControlled && _overloadFrames > 0;
			var manualUnthrottled:Bool = !cpuControlled;
			if (behind)
				spawnBudget = 1024;
			// Visible materialisation horizon: notes beyond the cull distance are only kept resident or settled in the data layer, so building them is waste.
			// (The old 2000ms spawnTime window is ~10x the visible range at speed=10.)
			// With perfMode off the full stock spawnTime window is used and no horizon shrink is applied.
			var effTime:Float = perfOn ? Math.min(time, _visHorizonMs) : time;
			var spawnedThisFrame:Int = 0;

			_phaseT = haxe.Timer.stamp();
			// Turbo: reset the runtime keep gate every frame (see turboKeepNote).
			if (turboModeActive)
				resetTurboKeepGate();
			// With perfMode off there is no budget throttle and no hard-deadline forcing, matching the stock per-note behaviour.
			// Manual mode (manualUnthrottled) is also unthrottled to keep off-screen slide-in correct.
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

				if (turboModeActive && !turboKeepNote(targetData) && bulkSettleNote(targetData, _bulkAcc, notesAddedCount))
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
				// Join the compact living list (what lets limitNC read the exact living count)
				newNote.activeIdx = activeNotes.length;
				activeNotes.push(newNote);

				// Rebuild the prevNote/nextNote chain (links only generated notes; ungenerated sustain tails are handled by the data scan).
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
			// Replay mode: keys are handled by replayExam.replayUpdate(); otherwise by keysCheck()
			if (replayMode) {
				if (replayExam != null) replayExam.replayUpdate(elapsed);
			} else if(!cpuControlled) {
				keysCheck();
			} else if(!boyfriend.isAnimationNull() && boyfriend.holdTimer > Conductor.stepCrochet * (0.0011 / FlxG.sound.music.pitch) * boyfriend.singDuration && boyfriend.getAnimationName().startsWith('sing') && !boyfriend.getAnimationName().endsWith('miss')) {
				boyfriend.dance();
			}

			if(startedCountdown)
			{
				// With perfMode off there is no off-screen culling and no per-frame trig cache;
				// both are optimizations that are skipped to keep the pre-optimization per-note real-time computation.
				if (ClientPrefs.data.perfMode)
				{
					refreshNoteCullRanges(elapsed);
					refreshLaneTrigCaches();
				}
				_frameAliveTally = 0;

				// Reuse the strumsHit array to avoid a per-frame allocation (a main source of frame garbage on dense charts)
				var laneCount:Int = Note.ammo[mania] * 2;
				if (strumsHit.length != laneCount)
					strumsHit = [for (i in 0...laneCount) false];
				else
					for (i in 0...laneCount)
						strumsHit[i] = false;
				// Reset the once-per-lane-per-frame gates for botplay/opponent side
				resetBotGateArrays();

				_phaseT = haxe.Timer.stamp();
				var _probeBulkT0:Float = _phaseT;
				bulkHitDueMaterialized(); // batch-hit botplay's due materialised notes (merged per-hit call chain)
				var _probeBulkEnd:Float = haxe.Timer.stamp();
				_probeBulkMs = _probeBulkEnd - _probeBulkT0;
				if (ClientPrefs.data.perfMode)
				{
					// Iterate the compact living list (O(living), no full member scan).
					// Forward iteration with swap-remove compensation: updateDaNote may recycle the current element
					// and the tail element moves into its slot, so i must not advance then.
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
					// With perfMode off keep the pre-optimization behaviour: iterate every alive member of notes,
					// including notes that scripts add or move.
					notes.forEachAlive(updateDaNote);
				}
				_lastAliveTally = _frameAliveTally;

				// Pooled notes are no longer removed/destroyed in bulk; dead notes stay in members for slot reuse.
				// Only shells destroyed directly by scripts/external code (scale == null) are cleaned up, avoiding growth on error paths.
				_noteCleanupFrameCounter++;
				if (_noteCleanupFrameCounter >= NOTE_CLEANUP_INTERVAL)
				{
					_noteCleanupFrameCounter = 0;
					// One-pass compaction removes shells destroyed by scripts (scale == null),
					// replacing the O(n) splice of removing them one by one.
					var m:Array<Note> = notes.members;
					var total:Int = m.length;
					var wI:Int = 0;
					for (rI in 0...total)
					{
						var cleanNote:Note = m[rI];
						if (cleanNote != null && cleanNote.scale == null)
							continue;
						m[wI] = cleanNote;
						if (cleanNote != null) cleanNote.memberIndex = wI; // keep the index cache in sync
						wI++;
					}
					@:privateAccess notes.length = wI;
					// Critical: the array must be truncated directly to keep the "members has no null slots" invariant
					// that notes.remove(splice) maintained. FlxTypedGroup.sort sorts members without filtering, so when
					// fastSort is off each frame's notes.sort(FlxSort.byY) feeds null slots to the comparator, which
					// dereferences Obj1.y and crashes a few frames after a sustain is held with a shell left behind.
					if (wI < total)
						m.resize(wI);
					if (_noteSlotCursor > wI) _noteSlotCursor = wI;

					// Compact the living list too (shells destroyed by scripts may remain in it)
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
				// fasterNoteSort is safe for sustains too: it reorders only living, visible notes and leaves dead slots in place,
				// so the draw order matches a full sort and dense sustain charts no longer fall back to an O(n log n) full sort.
				var sortOrder:Int = ClientPrefs.data.downScroll ? FlxSort.ASCENDING : FlxSort.DESCENDING;
				var _probeNotesT:Float = haxe.Timer.stamp();
				_probeNotesMs = _probeNotesT - _probeBulkEnd;
				_phaseT = _probeNotesT;
				if (ClientPrefs.data.fastSort)
					fasterNoteSort(sortOrder);
				else
				{
					notes.sort(noteDrawOrder, sortOrder);
					rebuildMemberIndexes(notes.members, notes.members.length); // rebuild the index cache in one pass after a full reorder
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
				// Before the countdown notes are also not removed/destroyed; dead notes stay in members for reuse.
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

		// Refresh the presentation once at frame end (score text / ms text / merged popup), then update the watch counters.
		// Before onUpdatePost, so scripts reading the score/text in this frame's callbacks see the final values.
		var _probePresentT:Float = haxe.Timer.stamp();
		_probeSortMs = _probePresentT - _phaseT;
		_phaseT = _probePresentT;
		flushHitPresentation();
		_probePresentMs = haxe.Timer.stamp() - _probePresentT;

		// F8 probe + one sweep for the three globals (same instant, same per-script order).
		var _probeScC:Float = _probeScriptT0();
		setOnScripts3('cameraX', camFollowPos.x, 'cameraY', camFollowPos.y, 'botPlay', cpuControlled);
		_probeScriptT1(_probeScC);

		var _probeScD:Float = _probeScriptT0();
		callOnScripts('onUpdatePost', [elapsed]);
		_probeScriptT1(_probeScD);

		// Commit after the script tail so this frame's total and script slices include it.
		_probeTotalMs = haxe.Timer.stamp() - _probeFrameStart;
		commitHitProbeFrame();
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
		var usePause:Bool = ((Main.useOldPause != null) ? Main.useOldPause : ClientPrefs.data.oldPauseMenu);
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
		// Online play disables the death check while connected (the check starts with
		// `!GameClient.isConnected()`). The online path never switches to GameOverSubstate, and
		// `boyfriend.stunned` is never reset, so zeroed health would permanently kill the four note
		// keys while the screen kept running; the server never broadcasts endSong after one side's
		// playerEnded while it still waits for the other, so that side would hang forever. Online
		// now skips the death check: the bar stays empty and play continues; `endSong()` alone ends it.
		if (online.GameClient.isConnected()) {
			return false;
		}
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
				// A failing event does not block the following ones (prevents stalls and swallowed errors)
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
				if (Math.isNaN(newMania)) newMania = Note.defaultMania + 1; // default 4K (1-based)
				// Event Value 2: 'true'/'skip' skips the transition; any other value is an animation style name
				// (built-ins: fade/slide/zoom/spin; scripts may define their own)
				var skipTween:Bool = (value2 != null && (value2 == 'true' || value2 == 'skip'));
				var animStyle:String = null;
				if (!skipTween && value2 != null && value2.length > 0)
					animStyle = value2;
				// Event Value 1 uses a 1-based key count (9 = 9K); the internal mania is 0-based
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
							// The 0.7.3/1.0.4 Bar is a FlxSpriteGroup and some custom icons end up covered by the
							// health bar background; re-adding the icon after the bar keeps it on top.
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

				#if ONLINE_ALLOWED
				// Change Character must sync the characters map per sid.
				// The canonical swap is done above; this fills in the per-sid loop. Without it
				// characters[sid] still points at the replaced-out instance, so the remote animations
				if (charType != 2)
					onlineRebindCharacters(charType, value2);
				#end

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
	/**
	 * The FlxSound that carries onMusicComplete. It outlives this state while the next one
	 * loads (the song keeps playing during the transition), so destroy() has to detach the
	 * callback -- otherwise a late completion runs finishSong() on a destroyed state and
	 * writes the volume of an already destroyed FlxG.sound.music (null write at +0x30,
	 * crash/native_crash_20260925_154824.txt).
	 */
	var _songMusic:FlxSound = null;

	function onMusicComplete():Void
	{
		// The song's FlxSound outlives this state while the next one loads, and its onComplete
		// still points here. A late completion must not run on a dead state: FlxG.sound.music can
		// already be destroyed (FlxSound.destroy nulls _transform), and finishSong() writes its
		// volume -- a null write at +0x30 (crash/native_crash_20260925_154824.txt).
		if (instance != this) return;
		if (notesAddedCount >= unspawnNotes.length)
			finishSong();
		else
			musicEnded = true;
	}

	public function finishSong(?ignoreNoteOffset:Bool = false):Void
	{
		var finishCallback:Void->Void = endSong; //In case you want to change it in a specific song.

		updateTime = false;
		if (FlxG.sound.music != null && FlxG.sound.music.exists) FlxG.sound.music.volume = 0;
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
		#if ONLINE_ALLOWED
		// endSong() first reports the final FP, max combo and "playerEnded" to the room and
		// bails out. The room then answers with the "endSong" message, whose listener
		// calls endSong() again; that listener is not wired here, so online songs currently stop
		// at this early return.
		if (!canEndSongOnline && online.GameClient.isConnected()) {
			online.GameClient.send("updateSongFP", Math.ffloor(songPoints));
			online.GameClient.send("updateMaxCombo", maxcombo);
			online.GameClient.send("playerEnded");
			return;
		}
		#end

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
				if (!replayMode && !practiceMode && !cpuControlled && !chartingMode)
				{
				// Prepare replay frame data (converted to Dynamic for Allscore)
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
					// osu! tail judgement + judgement feel (27-30, force-restored by replay/score details)
					null, // placeholder: tail judgement is disabled but details[27] is kept so later fields do not shift
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
				// The FP total for the finished run:
				//   songPoints = online.FunkinPoints.calcFP(ratingPercent, songMisses, songDensity, totalNotesHit, maxCombo);
				// This engine has no `finishingSong` member, so the equivalent "the run really ended"
				// condition is its `SONG.validScore` gate around the score-saving block below. Computed
				// here (not inside that block) because songDensity/totalNotesHit/maxcombo are all final
				// by this point. Read by buildScoreText()/getPresencePoints() and by the online results
			// dispatch -- both only under ONLINE_ALLOWED.
			if (SONG.validScore || SONG.validScore == null)
				songPoints = online.FunkinPoints.calcFP(ratingPercent, songMisses, songDensity, totalNotesHit, maxcombo);
			#end

			#if ONLINE_ALLOWED
			// Online results go to online.states.ResultsState (which reads the room state for the
			// ranking) instead of the single-player PlayStateResultsSubstate.
			if (online.GameClient.isConnected()) {
				online.states.ResultsState.gainedPoints = songPoints;
				transitioning = true;
				FlxG.switchState(new online.states.ResultsState());
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

			unspawnNotes = ChartNotes.empty();
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
	 * Rebuild the rating data from judgementTimings / marvelousRatings (from LeatherEngine).
	 * Called again after a replay load so the restored judging feel applies immediately.
	 */
	private function buildRatingsData():Void
	{
		ratingsData = [];

		// Judgement windows come from judgementTimings and are synced into the Psych window fields
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
		// set_volume triggers a native soundTransform write, which is waste at three paths per hit under load;
		// skip it when the value is already 1 (semantically identical).
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
		// 原始判定名(含 'marvelous'): 给需要超完美档的脚本读,
		// 见 ClientPrefs.judgementNameCompat 与 Note.ratingRaw。
		note.ratingRaw = daRating.name;
		score = daRating.score;
		if(daRating.noteSplash && !note.noteSplashDisabled)
		{
			spawnNoteSplashOnNote(note);
		}

		if(!practiceMode) {
		 // Scoring keeps the vanilla botplay semantics (botplay adds no score); hit counts are counted like the batch path
		 // so the HUD/results do not show only the few notes handled by the per-object path.
		 if(!cpuControlled) songScore += score;
		 if(!note.ratingDisabled)
		 {
			 songHits++;
		 }
		}
		#if ONLINE_ALLOWED
		// Every local judgement is forwarded to the room. This engine also stashes the rating image
		// so goodNoteHit() can forward it in "noteHit" (the image comes from popUpScore(), which is
		// Void here), and that image is what the remote side plays.
		onlineLastRatingImage = daRating.image;
		if (!practiceMode && !cpuControlled)
		{
			online.GameClient.send("addScore", score);
			online.GameClient.send("addHitJudge", note.rating);
		}
		#end
		if(!note.ratingDisabled) {
			totalPlayed++;
			RecalculateRating(false);
		}

		if (_popupImmediateBudget > 0)
		{
			_popupImmediateBudget--;
			showComboNum = (combo >= 10);
			showRatingPopup(ratingPopup, daRating.image, combo, FlxG.width * 0.35, showRating, showComboNum);
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

			// 0.7.3+/1.0.4: onKeyPressPre (returning Function_Stop cancels the press)
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

			// Replay mode: scripts and key handling both use the exact time of the recorded frame.
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
				// Reuse keyPressed' scratch arrays so the outermost call allocates nothing; script re-entry gets fresh arrays.
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
				// Without scripts, scan only the compact living list instead of dead members and a forEachAlive closure.
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


				//more accurate hit time for the ratings? part 2 (Now that the calculations are done, go back to the time it was before for not causing a note stutter)
			Conductor.songPosition = lastTime;
			}


			var spr:StrumNote = playerStrums.members[key];
			if(strumsBlocked[key] != true && spr != null && spr.animation.curAnim.name != 'confirm')
			{
				#if ONLINE_ALLOWED
				// keyPressed() mirrors the press to the room.
				online.GameClient.send("strumPlay", ["pressed", key, 0]);
				#end
				spr.playAnim('pressed');
				spr.resetAnim = 0;
			}
			callOnScripts('onKeyPress', [key]);
			_pressScratchDepth--;
			}

		/**
		 * Multi-key: batch judgement for several simultaneous presses (one pass over the notes instead of one per key).
 * Same logic as keyPressed: jack detection, ghost keys and strum animations per lane, with script callbacks per key.
		 */
		public function keyPressBatch(keys:Array<Int>, time:Float, ?suppressAllButLast:Int = -1, ?pressTimes:Array<Float> = null):Void
		{
			if (cpuControlled || paused || keys == null || keys.length < 2) return;
			if (!generatedMusic || endingSong || boyfriend.stunned) return;

			// Pre-build the pressed-lane bitmap so every living note avoids keys.indexOf (O(N*K) -> O(N))
			// Reuse keyPressBatch' scratch arrays so the outermost call allocates nothing; script re-entry gets fresh arrays.
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

			// Group by lane (same-lane jack detection is independent); preallocated buckets avoid new Maps/arrays per batch.
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
					#if ONLINE_ALLOWED
					// The batch path is this engine's multi-key merge of the per-key keyPressed();
					// mirror each merged lane of the batch.
					online.GameClient.send("strumPlay", ["pressed", key, 0]);
					#end
					spr.playAnim('pressed');
					spr.resetAnim = 0;
				}

				var list:Array<Note> = (key >= 0 && key < laneNotes.length) ? laneNotes[key] : null;
				if (list == null || list.length < 1)
				{
					callOnScripts('onGhostTap', [key]);
					if (canMiss) noteMissPress(key);
					keysPressed[key] = true;

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

				callOnScripts('onKeyPress', [key]);
			}
			_pressScratchDepth--;
		}

		/** Multi-key: lets the Android hitbox trigger extended lanes directly (above 4K). */
		public function mobileKeyPressed(key:Int):Void
		{
			if (key < 0 || key >= Note.ammo[mania] || key >= mobileHeld.length)
				return;
			// Touch hold state: recorded even while paused or replaying so keysCheck can keep hitting sustain bodies
			mobileHeld[key] = true;
			if (replayMode || cpuControlled || paused)
				return;
			// Same-frame multi-touch presses are queued and merged into one keyPressBatch by keysCheck, avoiding a full note scan per finger.
			if (_mobilePressQueue.indexOf(key) == -1)
			{
				_mobilePressQueue.push(key);
				_mobilePressTimes.push(Conductor.songPosition);
			}
		}

		/** Multi-key: lets the Android hitbox release extended lanes directly (above 4K). */
		public function mobileKeyReleased(key:Int):Void
		{
			if (key < 0 || key >= Note.ammo[mania] || key >= mobileHeld.length)
				return;
			mobileHeld[key] = false;
			// If same-frame presses are still pending, queue the release first so keysCheck processes press then release,
			// otherwise a fast same-frame down+up would release before pressing and leave the key stuck.
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
			// Replay mode must handle press and release symmetrically: keyPressed does not require startedCountdown,
			// and requiring it here would swallow releases during the countdown/intro, leaving keys held.
			if (cpuControlled || paused || (!replayMode && !startedCountdown))
				return;
			keyboardDisplay.released(key);

			// 0.7.3+/1.0.4: onKeyReleasePre (returning Function_Stop cancels the release)
			// 0.7.3+/1.0.4: onKeyReleasePre (return Function_Stop to block the release)
			var preResult:Dynamic = callOnScripts('onKeyReleasePre', [key]);
			if (preResult == LuaUtils.Function_Stop || preResult == FunkinLua.Function_Stop)
				return;

			/** osu! tail judgement: a release is judged against the sustain tail time
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
				#if ONLINE_ALLOWED
				// keyReleased() mirrors the release.
				online.GameClient.send("strumPlay", ["static", key, 0]);
				#end
				spr.playAnim('static');
				spr.resetAnim = 0;
			}
			callOnScripts('onKeyRelease', [key]);

		}

		// ======================== osu! tail judgement ========================

		/** osu! tail judgement: initialises the per-lane arrays (mania may change).
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

		/** osu! tail judgement: clears the active sustain on a lane.
		private function clearActiveHold(lane:Int):Void
		{
			if (lane >= 0 && lane < activeTailEnd.length)
			{
				activeTailEnd[lane] = 0;
				activeHoldNote[lane] = null;
			}
		}
			*/

		/** osu! tail judgement: registers the active sustain when a head is hit (tail time and head note).
		private function registerActiveHold(note:Note):Void
		{
			if (note == null || cpuControlled || playOpponent || note.isSustainNote || note.sustainLength < 1) return;
			if (!note.mustPress) return;
			ensureTailArrays();
			var lane:Int = Std.int(Math.abs(note.noteData));
			if (lane < 0 || lane >= activeTailEnd.length) return;

			// Sustain chain: pressing a new head while the previous sustain is still active completes the previous one and settles its score
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
		 * osu! tail judgement: visual tail time of a sustain.
 * It cannot be strumTime + sustainLength: chart generation offsets the tail segment
 * (stepCrochet / songSpeed) and the player releases against the segment on screen.
 * Walk the nextNote chain to the last sustain segment (isSustainEnd) and use its strumTime;
 * if the sustain is too short to generate a tail segment, fall back to the chart length.

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
				// Scan only sustain segments belonging to this one sustain; stop at any other note.
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
		 * osu! tail judgement: release judgement (called from keyReleased).
 * - release error = release time - tail time, judged with the same windows on |error| as normal notes
 * - error outside the safe zone -> miss (early and late both count)
 * - still held past tail + safe zone -> the per-frame timeout marks a miss (osu: holding past the late miss window = miss)

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
		 * osu! tail judgement: release rating (fully osu!mania-like: early and late use the same windows).
 * - |error| <= marvelous/sick/good/bad window -> that rating
 * - bad window < |error| <= safe zone -> shit
 * - |error| > safe zone -> miss

		private function tailRatingFor(diff:Float):String
		{
			var absDiff:Float = Math.abs(diff);
			var mult:Float = tailWindowMult();
			if (absDiff > Conductor.safeZoneOffset * mult) return 'miss';
			// The tail window is widened by the multiplier (default 2x)
			return backend.Ratings.getRating(absDiff / mult);
		}
			*/

		/** osu! tail judgement: a successful release settles the sustain and rating scores, showing the delay and rating icon.
		private function tailHit(lane:Int, tailEnd:Float, diff:Float, rating:String):Void
		{
			var head:Note = (lane < activeHoldNote.length) ? activeHoldNote[lane] : null;

			// During replay the recorded high-precision tail judgement is preferred, reproducing the score and ms exactly
			var recordedJ = null;
			if (replayMode && replayExam != null && replayExam.hasJudgments)
				recordedJ = replayExam.getRecordedJudgment(tailEnd, lane);

			if (recordedJ != null) rating = recordedJ.rating;

			if (!replayMode && replayExam != null)
				replayExam.recordJudgment(tailEnd, lane, diff, rating, true);

			// Successful tail hit: the remaining sustain segments are voided instead of judged one by one
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
				// Only a successful tail hit settles the score accumulated while holding the sustain (osu: a broken sustain does not settle)
				songScore += sustainNotescore;
				songScore += score;
				songHits++;
				// A successful tail hit is counted in the rating counters (marvelouses/sicks/goods/bads/shits), matching accuracy
				var counterName:String = (rating == 'marvelous') ? 'marvelouses' : rating + 's';
				Reflect.setField(this, counterName, Reflect.field(this, counterName) + 1);
			}
			sustainNotescore = 0;
			updateScore();
			totalPlayed++;
			// A successful tail hit counts toward accuracy by rating like normal notes, otherwise an all-perfect run would drop accuracy on sustains
			var tailMod:Float = 1;
			if (rating == 'good') tailMod = 0.7;
			else if (rating == 'bad') tailMod = 0.4;
			else if (rating == 'shit') tailMod = 0;
			totalNotesHit += tailMod;
			RecalculateRating(false);
			*/

			// Rating popup (the rating image only, no combo number: the combo is handled by the head note)
			/**if (ratingPopup != null)
				ratingPopup.show(rating, combo, playbackRate, FlxG.width * 0.35,
					ClientPrefs.data.hideHud, showRating, false, false,*/
					//[for (v in ClientPrefs.data.comboOffset) Std.int(v)], Conductor.crochet,
					//ClientPrefs.data.comboStacking);
		//}

		/** osu! tail judgement: releasing far too early is a tail miss (breaks combo, drains health, counts a miss).
		private function tailMiss(lane:Int, tailEnd:Float, releaseTime:Float):Void
		{
			var head:Note = (lane < activeHoldNote.length) ? activeHoldNote[lane] : null;
			var diff:Float = releaseTime - tailEnd;

			if (!replayMode && replayExam != null)
				replayExam.recordJudgment(tailEnd, lane, diff, 'miss', true);

			// miss: the sustain segments return to the un-held state so they pass the receptor like normal misses (only one miss is counted)
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
			// Mimic a normal miss: character miss animation / gf cries
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

		/** osu! tail judgement: on a hit the remaining un-hit sustain segments are discarded so a release is not judged segment by segment.
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



		/** osu! tail judgement: on a miss the remaining sustain segments return to the un-held state so they pass the receptor like normal misses.
		private function markRemainingSustainMissed(lane:Int, head:Note):Void
		{
			if (head == null) return;
			var headParentST:Float = head.strumTime - ClientPrefs.data.noteOffset;
			notes.forEachAlive(function(n:Note)
			{
				if (n != null && n.isSustainNote && n.mustPress && n.noteData == lane
					&& n.parentST == headParentST && !n.missed)
				{
					n.wasGoodHit = false; // back to the un-held state
					n.missed = true;
					n.ignoreNote = true;
					n.tooLate = true;
					n.multAlpha = 0.3;
					n.alpha = 0.3;
				}
			});
		}*/

	/**
	 * @param frameTime  song time of this frame
 * @param pressLanes lanes pressed this frame
 * @param releaseLanes lanes released this frame
 * @param heldLanes  lanes currently held
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

		// Handle presses
		if (_press.contains(true))
		{
			for (i in 0..._press.length)
			{
				if (_press[i] && strumsBlocked[i] != true)
					keyPressed(i, frameTime);
			}
		}

		// Handle sustains (hold)
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

		// Character idle animation
		if (!_hold.contains(true) && !endingSong && generatedMusic)
		{
			var danceChar:Character = playOpponent ? dad : boyfriend;
			if (!danceChar.isAnimationNull()
				&& danceChar.holdTimer > Conductor.stepCrochet * (0.0011 / FlxG.sound.music.pitch) * danceChar.singDuration
				&& danceChar.getAnimationName().startsWith('sing')
				&& !danceChar.getAnimationName().endsWith('miss'))
				danceChar.dance();
		}

		// Handle releases
		if (_release.contains(true))
		{
			for (i in 0..._release.length)
			{
				if (_release[i] || strumsBlocked[i] == true)
					keyReleased(i, frameTime);
			}
		}

			// osu! tail judgement: during replay, holding past tail + safe zone still counts as a miss (same as live)
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

			// Reuse the preallocated arrays instead of allocating three new ones per frame (Android GC).
			if (holdArray.length < laneCount) holdArray.resize(laneCount);
			if (pressArray.length < laneCount) pressArray.resize(laneCount);
			if (releaseArray.length < laneCount) releaseArray.resize(laneCount);

			for (i in 0...laneCount)
			{
				holdArray[i] = false;
				pressArray[i] = false;
				releaseArray[i] = false;
			}

			// Non-replay input: read the key state from the controls object.
			for (i in 0...laneCount)
			{
				// 4K uses the stock control actions (keyboard / gamepad / Android buttons);
				// every lane of a multi-key layout reads its own extended key binding directly.
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
							// Extended lane names still go through dynamic lookup (Reflect).
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
					// Direct lookup of this lane's key binding (all lanes for multi-key, fallback for 4K).
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
					// FlxHitbox-driven holds must mark the lane here, otherwise held sustains never
					// reach goodNoteHit (4K goes through the controls path, so it is unaffected).
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
					// lastNoteAnimation keeps the per-key multi-key touch semantics: clear the same-frame
					// touch queue and then run the normal keyboard path, so the last-key animation wins.
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

					// Multiple keys take the same batch scan, preserving that same visual behavior.
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
					// Single scan for all lanes pressed this frame instead of a full note-table scan per key;
					// same-frame touches are merged in and their raw press times go through pressTimes.
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

				// With nothing held a sustain cannot be hit, so skip the whole table scan.
				// Without scripts the compact living list (activeNotes) is used, avoiding dead member slots;
				// with scripts the notes.forEachAlive semantics are kept (notes added by scripts participate too).
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
				// Non-gameplay input frames (pause/end/replay/lock) must not keep the same-frame touch queue.
				_mobilePressQueue.resize(0);
				_mobilePressTimes.resize(0);
				_mobileReleaseQueue.resize(0);
			}

			#if ONLINE_ALLOWED
			// keysCheck() writes the local player's hold state back onto its own character; this is
			// what makes the guarded Character.noteHold setter emit the room's "noteHold" callback.

			if (online.GameClient.isConnected())
				(playsAsBF() ? boyfriend : dad).noteHold = anyHeld;
			#end

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
				// Anti-stuck key (multi-bind or lost touch release leaves a phantom press): the lane is not
				// actually held but the strum is still 'pressed', so the release was swallowed; force 'static'. Only checked when the lane is truly not held.
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
			// osu! tail judgement: holding past tail + safe zone -> too-long miss (osu: holding past the late miss window = miss)
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

		vocals.volume = 0;
		vocalsPlayer.volume = 0;
		if(!practiceMode) songScore -= 0;
		#if ONLINE_ALLOWED
		// noteMissCommon() forwards the miss to the room. This engine's local score deliberately
		// does not subtract 10, but the room's score is what the online scoreboard shows, so -10
		// is what gets reported.
		if (!practiceMode)
			online.GameClient.send("addScore", -10);
		if (!endingSong)
			online.GameClient.send("addMiss");
		online.GameClient.send("noteMiss", [daNote.strumTime, daNote.noteData, daNote.isSustainNote]);
		#end

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
			#if ONLINE_ALLOWED
			// noteMissCommon() echoes the miss animation.
			online.GameClient.send("charPlay", [animToPlay, char == gf]);
			#end
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
			#if ONLINE_ALLOWED
			// noteMissPress() goes through noteMissCommon(), so an empty-lane tap forwards the
			// same score/miss pair.
			if (!practiceMode)
				online.GameClient.send("addScore", -10);
			if (!endingSong)
				online.GameClient.send("addMiss");
			#end
			totalPlayed++;
			wrongLaneTimes.push(Conductor.songPosition);
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
                     #if ONLINE_ALLOWED
                     // noteMissCommon() echoes the miss animation.
                     online.GameClient.send("charPlay", [getSingAnimDir(direction) + 'miss', false]);
                     #end
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

		// Opponent-side downgrade: sing animations and strum confirms are also once per lane per frame (opponent
		// lanes fire thousands of hits per frame on dense charts, so per-hit playAnim is pure waste).
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
			// 0.7.3+/1.0.4: opponentNoteHitPre / goodNoteHitPre callbacks
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
				// 0.7.3 format: uses Math.abs like opponentNoteHit
				result = callOnLuas(scriptName, [noteIndexFast(note), Math.abs(note.noteData), note.noteType, note.isSustainNote]);
			} else if (reverseNoteHit) {
				// 0.6.3 format, but reverseNoteHit actually calls goodNoteHit so the raw noteData is passed
				result = callOnLuas(scriptName, [noteIndexFast(note), note.noteData, note.noteType, note.isSustainNote]);
			} else {
				// 0.6.3 opponentNoteHit itself uses Math.abs
				result = callOnLuas(scriptName, [noteIndexFast(note), Math.abs(note.noteData), note.noteType, note.isSustainNote]);
			}
			if(result != FunkinLua.Function_Stop && result != FunkinLua.Function_StopHScript && result != FunkinLua.Function_StopAll) callOnHScript(scriptName, [note]);
		}
		// Turbo: opponent hits feed the player's own combo counter and popup. Most local notes are
		// settled in the data layer, so without this the combo never moves on dense charts. Only
		// taps count (no sustain tails) and none of the score / hit stats / judgement / rating are
		// touched; the popup draws the combo only, never the judgement icon.
		// opponent paths, with the popup still bounded by the per-frame POPUP_IMMEDIATE_HITS budget.
		// Both the counter and the popup live in addOpponentHit, the shared entry for all three.
		// Called for every tap, not only under Turbo: the same entry feeds the score text's
		// opponent-side note count; the combo/popup part inside stays Turbo-only.
		if (!note.isSustainNote)
			addOpponentHit(1);
		if (!note.isSustainNote)
			recycleNote(note);
		if (!ClientPrefs.data.opponentfe) {
			// Opponent-side downgrade: the original reset every lane to static on each hit (hits x lanes
			// playAnim calls on dense charts); once per frame is invisible because same-frame repeats are not seen.
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



	/** Kills a note and returns it to this state's notePool; no remove/destroy, so members stays bounded. */
	private function recycleNote(daNote:Note):Void
	{
		if (daNote == null || daNote.pooled) return;
		if (daNote.scale == null) return; // discard shells that were already destroyed
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
			// A plain tap returned to the pool must not stay as another note's prevNote, or reuse would link to the wrong object.
			if (lastSpawnedNote.get(linkKey) == daNote)
				lastSpawnedNote.remove(linkKey);
			daNote.pooled = true;
			notePool.push(daNote);
		}
	}

	/**
	 * Recomputes the off-screen cull distance every frame (world pixels):
 * - derived from the real geometry of the receptor group and the HUD camera: the room from the farthest
 *   receptor to the screen edges (plus 140px for sustain trimming/offset jitter). Culled notes are always invisible.
 * - accounts for the HUD camera zoom (zoom < 1 shows a larger world range)
 * - divided by |sin| of the lane scroll direction, so it stays correct with rotated receptors; purely horizontal scrolling disables culling.
	 *
 * It also derives the visible materialisation horizon: how many ms a note can still stay before crossing the cull edge.
 * That is the only gate on the materialised count:
 *   visible span (ms) = screen pixel band / (0.45 * songSpeed * maniaScale)
 * roughly 3s at speed=1 and 6s at speed=0.5, which is where dense charts fit six figures of notes.
 * Pinning the window to the real pixel band makes the materialised count depend on screen geometry,
 * not chart density (with Turbo's pixel folding covering the other side independently).
	 */
	function refreshNoteCullRanges(elapsed:Float):Void
	{
		var zoom:Float = (camHUD != null && camHUD.zoom > 0 && camHUD.zoom < 32) ? camHUD.zoom : 1;
		var viewTop:Float = (camHUD != null) ? camHUD.scroll.y : 0;
		var viewBottom:Float = viewTop + FlxG.height / zoom;
		// Critical: the margin must cover frame quantisation overshoot. Residency is decided once per frame, so at low
		// frame rates a note travels frame time x speed pixels in one step and a fixed 140px margin is overrun,
		// flashing notes/sustain tails on screen. The margin grows with frame time and speed.
		var quantizeMs:Float = Math.max(120.0, elapsed * 1000 * 1.5);
		var cullMargin:Float = 140 + 0.45 * songSpeed * quantizeMs;
		_cullDistPlayer = noteCullDistFor(playerStrums, viewTop, viewBottom, cullMargin);
		_cullDistOpponent = noteCullDistFor(opponentStrums, viewTop, viewBottom, cullMargin);

		// Visible materialisation horizon (ms): distance conversion px/ms = 0.45 * songSpeed * maniaScale
		// (the same formula as updateDaNote). Using the real pixel band plus the cull margin, which already
		// covers frame quantisation overshoot, means notes materialised in this window are guaranteed to appear
		// on screen and to get another update before leaving it.
		// The cap is still spawnTime (the stock spawn window); the floor guards against extreme values collapsing the window.
		var cullMin:Float = Math.min(_cullDistPlayer, _cullDistOpponent);
		var speedFactor:Float = 0.45 * songSpeed * Note.getManiaScale(mania);
		if (speedFactor <= 0.0001) speedFactor = 0.45;
		_visHorizonMs = Math.min(spawnTime, Math.max(120.0, (cullMin + cullMargin) / speedFactor));
	}

	/**
	 * Per-lane cos/sin cache: note position = strum + (cos,sin)(direction) * distance.
 * direction belongs to the strum (a per-lane constant), and the original computed two trig calls per note per
 * frame (~6400/frame with ~3200 notes on screen); the cache computes it once per lane per frame.
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

	/** O(1) removal from the living list (swap-remove; the tail element fills the slot and its index is fixed up). */
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

	/** Resets the botplay/opponent once-per-lane-per-frame gate arrays (synced with strumsHit, sized to the key count). */
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
	 * O(1) note index lookup in notes.members (for script callback arguments), replacing the per-hit
 * notes.members.indexOf O(n) scan, which costs seconds with tens of thousands of members and hits per frame.
 * The index is maintained by appendNoteFast/fasterNoteSort/compaction; when validation fails (scripts or
 * external code changed members) it falls back to one indexOf and self-heals the cache.
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

	/** Rebuilds the whole memberIndex cache (after a full reorder such as notes.sort; one O(n) pass). */
	static function rebuildMemberIndexes(m:Array<Note>, len:Int):Void
	{
		for (i in 0...len)
		{
			var n:Note = m[i];
			if (n != null) n.memberIndex = i;
		}
	}

	/**
	 * Amortised O(1) append of a note to the notes group, with the same slot choice as FlxTypedGroup.add
 * (first free slot, otherwise append). add()'s members.indexOf duplicate check and getFirstNull are both
 * O(n), which wastes tens of ms per frame with tens of thousands of members during dense spawning.
 * Only used by this state's deferred materialisation path (a note is never added twice).
	 */
	@:privateAccess
	function appendNoteFast(note:Note):Void
	{
		var m:Array<Note> = notes.members;
		var len:Int = m.length;

		// Find the first free slot from the cursor onwards
		var idx:Int = _noteSlotCursor;
		while (idx < len && m[idx] != null) idx++;

		if (idx >= len)
		{
			// There may be holes left by cleanup before the cursor; rescan the earlier part
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
			return; // group is full: drop it, matching add()

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
		if (minY > maxY) return 2200; // receptors not ready: conservative default

		var below:Float = viewBottom - maxY + margin; // how far it can still scroll below the screen
		var above:Float = minY - viewTop + margin;    // how far it can still scroll above the screen
		var dist:Float = (below > above) ? below : above;

		// Rotated / irregular lanes: tighten the threshold by |sin(scroll angle)| so "beyond distance => definitely off screen" holds
		var s0:StrumNote = members[0];
		var sinY:Float = (s0 == null) ? 1 : Math.abs(Math.sin(s0.direction * Math.PI / 180));
		return (sinY < 0.35) ? 1e12 : dist / sinY;
	}

	/** H-Slice style fasterSort: only alive+visible notes participate in the Y sort; dead slots keep their positions. */
	/**
	 * Note draw-order comparator (signature matches FlxTypedGroup.sort's Function.bind(Order) convention).
 * Layering: sustain segments always draw first (below), taps after (above), then by y within a layer
 * (closest to the strum line on top).
 * Background: the downscroll y order (ASCENDING, larger y drawn later) lets sustain segments (larger y
 * than taps) cover their own taps. This engine's segments are dense (2px overlap, 1.43x the stock
 * segment height), so tap rectangles overlap many segments and 0.6-alpha segments sitting on the arrows
 * look like "the tap is stuck inside the sustain" or "pressed to the back". The stock engine never
 * exposed this because stock segments are short. Segments must overlap taps to connect, so only the
 * draw order can keep the tap visible.
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
			// The comparator closure is created once (the original allocated two lambdas per frame, a steady GC source);
			// the sort direction is read live inside the comparator and stays consistent with the order argument.
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
				// Keep the memberIndex cache in sync (reordering is the main source of cache invalidation)
				_noteSortArr[k].memberIndex = _noteSortIdx[k];
			}
		}
	}

	/** Per-alive-note update hook (method reference, avoids allocating a closure every frame). */
	private function updateDaNote(daNote:Note):Void
	{
		if (daNote == null || !daNote.exists) return;

		_frameAliveTally++;

		// Off-screen culling: a note's y is derived linearly from strumTime, so notes far off screen need no
		// per-frame trig/clip/draw (visible=false lets group.draw skip them).
		// Only applies to notes whose position is fully engine-derived (copyX && copyY); notes past the kill
		// window are never kept resident -- they must run the normal miss/kill path.
		// With perfMode off there is no culling at all, keeping the pre-optimization behaviour where every alive note updates/draws.
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
		// Restore residency here when perfMode is switched back off or an existing culled flag must be cleared.
		if (daNote.culled)
		{
			daNote.culled = false;
			daNote.visible = true;
			daNote.active = true;
			_culledCount--;
		}

		#if ONLINE_ALLOWED
		// Connected players must set `camZooming = true` when a note is due (source
		// PlayState.hx:3560-3562). This engine only sets it in `opponentNoteHit()` / auto-hit opponent
		// notes, but online opponent notes are driven by the remote's "noteHit" message, so neither a
		// locally hit note nor an "unplayed yet" stretch sets it, and the
		// `if (camZooming) FlxG.camera.zoom = lerp(defaultCamZoom, ...)` in `update()` never runs:
		//   * a script or event changing `defaultCamZoom` has no effect (camera does not zoom);
		//   * zoom added by `Add Camera Zoom` never decays back to defaultCamZoom (bad zoom).
		// Set here only while connected; the single-player path is unchanged.
		if (online.GameClient.isConnected() && daNote.strumTime <= Conductor.songPosition)
			camZooming = true;
		#end

		// Auto-hit opponent notes
		#if ONLINE_ALLOWED
		// While connected, whoever does NOT own the opponent side must let the remote
		// player's "noteHit" messages drive those notes (the same rule as
		// `(!GameClient.isConnected() || playOtherSide || royalMode)`). The guarded `if` wraps the
		// untouched engine statement below, so the single-player path is unaffected.
		if (opponentAutoHitAllowed())
		#end
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

		// Per-lane cos/sin cache (refreshed by refreshLaneTrigCaches every frame); falls back to live computation when not covered.
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
					// Pixel stage: keeps the 0.6.3 fix, untouched here to avoid a pixel regression.
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
					// hxcpp, again.
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
			#if ONLINE_ALLOWED
			// Online: opponent sustains that nobody pressed vanish at the judgement line.
			// Online opponent notes are driven by remote messages and are no longer auto-hit locally, so
			// the old !mustPress branch matched every opponent sustain and clipped it to zero height as
			// soon as it crossed the line. Only sustains actually hit by the remote should clip at the
			// line; unplayed ones keep travelling past it.
			&& (daNote.wasGoodHit || (!daNote.mustPress && (!online.GameClient.isConnected() || daNote.hitByOpponent)))
			#else
			&& (!daNote.mustPress || daNote.wasGoodHit)
			#end
		)
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
		#if ONLINE_ALLOWED
		// Online: opponent sustains that nobody pressed vanish at the judgement line.
		// Online opponent notes are driven by remote messages and are not auto-hit locally, so an
		// unplayed note gets no message and fell into the "late recycle" below, dying noteKillOffset
		// past the line. The earlier clipping change only touched the visual layer, so it could not
		// fix the symptom; the lifetime is decided here. Unplayed opponent notes now keep travelling
		// past the line and are recycled only once fully off screen (both scroll directions).
		if (online.GameClient.isConnected() && !daNote.mustPress && !daNote.wasGoodHit && !daNote.hitByOpponent
			&& !daNote.ignoreNote && !endingSong)
		{
			if (Conductor.songPosition > noteKillOffset + daNote.strumTime
				&& (daNote.y > FlxG.height || daNote.y + daNote.height < 0))
				invalidateNote(daNote);
		}
		else
		#end
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
	 * Data-level batch advance: the structural downgrade for extreme note densities.
	 *
 * Core idea: when note density exceeds what per-object processing can handle, due/expired unmaterialised notes
 * are settled in the data layer (PreloadedChartNote.wasHit = true) instead of building sprites for them.
 * The settlement matches the per-hit path (combo/maxcombo/totalPlayed/totalNotesHit/judgement counts/health);
 * presentation is merged at frame end or de-duplicated per lane.
	 *
 * Two cutoffs:
 * - softCut (= songPosition, botplay only): due unmaterialised taps settle as auto-hits in the
 *   data layer. With a healthy frame rate the cursor runs ~2s ahead, so this layer does nothing;
 *   when it falls behind, the overflow is absorbed here, breaking the "lag -> backlog -> more lag"
 *   death spiral.
 * - hardCut (= songPosition - noteKillOffset): drains expired notes (the original behaviour).
	 *
 * Charts with sustains are no longer disabled as a whole: the scan stops at the first unsettled sustain
 * (sustains keep the per-object path and tail/trim semantics); taps after it keep draining once it is resolved.
	 *
 * Gated off with Lua/HScript, replay mode or an online session (script semantics stay byte-identical).
	 */
	function fastSkipPastNotes(elapsed:Float):Void
	{
		if (!ClientPrefs.data.perfMode || !ClientPrefs.data.bulkSkip) { _bulkDrainedLast = 0; return; }
		if ((hasActiveScripts() && !turboModeActive) || replayMode || endingSong) { _bulkDrainedLast = 0; return; }
		if (notesAddedCount >= unspawnNotes.length) { _bulkDrainedLast = 0; return; }

		var pos:Float = Conductor.songPosition;
		var hardCut:Float = pos - noteKillOffset;
		// Critical: the original "-Math.NEGATIVE_INFINITY" is positive infinity, so in manual mode softCut
		// became +inf, the scan never stopped, "strumTime <= softCut" held for every ungenerated note and
		// all of them were auto-hit early in the data layer (combo/health/strum confirms all fired).
		// Disabling softCut therefore has to use -inf.
		var softCut:Float = cpuControlled ? pos : Math.NEGATIVE_INFINITY;
		// Under overload (previous frame's drain clearly non-zero) the data settlement line moves to the inner visible edge:
		// with an insufficient materialisation budget, notes in the near half only flash for one frame at the strum
		// line before being recycled, so settling them directly beats paying for their construction; materialisation
		// then concentrates in the outer half, where each sprite lives through the whole fall (visible for many frames).
		// (The settlement itself is unchanged: notes that were due still count toward combo/judgements/health,
		//  just a few ms early. Turbo's pixel folding already bounds the materialised count by screen geometry,
		//  so special-casing a "dense cluster" is no longer needed.)
		if (cpuControlled && _overloadFrames > 0)
			softCut = pos + _visHorizonMs * 0.5;
		var drainTotal:Int = 0;

		// The accumulator is zeroed at the frame-end consumption point (finishBulkFrame -> resetBulkAccumulator):
		// the materialisation path settles folded groups into the same accumulator before fastSkipPastNotes,
		// so its contents must be reused or same-frame hits are lost before presentation.
		var acc:BulkAccumulator = _bulkAcc;

		// Turbo-only adaptive per-frame budget: about 100 notes per ms of frame time, capped at 65536.
		// 70k NPS is ~1167 notes/frame at 60fps; the budget keeps up with the densest endings while avoiding
		// a one-frame spike of tens of thousands of drains, and it grows automatically on slower frame rates.
		// Outside Turbo the stock one-shot drain behaviour is kept (off means unchanged).
		// A folded group counts as one budget unit: its members are overlapping notes in the same pixel band,
		// matching how the old implementation consumed folded groups.
		var drainBudget:Int = turboModeActive ? Std.int(Math.max(4096, Math.min(65536, elapsed * 1000 * 100))) : 0x7FFFFFFF;
		var processed:Int = 0;

		while (notesAddedCount < unspawnNotes.length)
		{
			if (processed >= drainBudget)
				break;
			processed++;

			var d:PreloadedChartNote = unspawnNotes[notesAddedCount];
			if (d.strumTime > hardCut && d.strumTime > softCut) break;
			// Sustains and sustain heads (isSustainNote=false but sustainLength>0) keep the per-object path:
			// consuming a head in the data layer would break the tail's prevNote/parent chain and its rendering.
			if (d.isSustainNote || d.sustainLength > 0) break;

			if (d.wasHit)
			{
				notesAddedCount++;
				continue;
			}

			// Data-level settlement (including expanding a Turbo fold group). Not-yet-due / non-player / sustain notes
			// return false with the cursor untouched -- this is also the only path that may advance the settlement cursor,
			// so any early-consume path that forgets to advance it would block every following note forever.
			if (!bulkSettleNote(d, acc, notesAddedCount))
				break;
			drainTotal++;
			notesAddedCount++;
		}

		_bulkDrainedLast = drainTotal;
		if (acc.drainedHit > 0 || acc.skippedHit > 0 || acc.skippedMiss > 0 || bulkHurtCount > 0 || acc.oppDrained > 0)
			finishBulkFrame(acc.drainedHit, acc.skippedHit, acc.skippedHitHealth, acc.skippedMiss, acc.skippedMissHealth, acc.oppDrained);
	}

	/** Resets the Turbo runtime keep gate every frame (one "last materialised" record per lane+side). */
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
	 * Turbo runtime keep gate: decides whether a tap is worth building a sprite for.
	 *
 * The test matches load-time folding (same lane + same side + same multSpeed, screen pixel gap below the threshold)
 * but uses the *current* songSpeed: load-time folding used the speed on entering the song, so if songSpeed is
 * rewritten by an event or tween mid-song the folded result no longer matches; this gate keeps the count bounded.
	 *
 * Returning false means "on screen this fully overlaps the previous materialised note", so the caller settles it in the data layer.
 * Sustains and sustain heads always pass (their tail chain and trimming must not be skipped).
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
			// The slower note decides (lastSlow), so the conclusion "the two can never separate enough to be told apart"
			// also holds for notes with different multSpeed.
			if (dt >= 0 && dt * _laneLastKeptSlow[idx] < TURBO_KEEP_GAP_PX)
				keep = false;
		}

		if (keep)
		{
			// Keep the smaller value while the rate is unchanged; re-anchor on the current rate when it changes.
			var prevRate:Float = _laneLastKeptRate[idx];
			var slow:Float = (prevRate == rate && _laneLastKeptSlow[idx] < rate) ? _laneLastKeptSlow[idx] : rate;
			_laneLastKeptTime[idx] = pn.strumTime;
			_laneLastKeptRate[idx] = rate;
			_laneLastKeptSlow[idx] = slow;
		}
		return keep;
	}

	/**
	 * Settle one unmaterialised note in the data layer without constructing a sprite.
	 *
	 * After Turbo folding one representative note stands for noteDensity original taps (pixel
	 * spacing below the threshold, so they always overlap). They must settle together:
	 *   - settling too few desyncs hit counts from totalPlayed, breaking accuracy/rating;
	 *   - settling across frames splits the combo of one pixel band into several runs.
	 * The whole group is therefore expanded at once and counts as one per-frame budget unit.
	 *
	 * @return whether settlement succeeded (the caller may then advance the cursor).
	 */
	/**
	 * Turbo only: count one opponent hit towards the player's own combo.
	 *
	 * It must be a single entry point: an opponent note has three disjoint consumption paths:
	 *   1. the !mustPress branch of bulkSettleNote() (unmaterialised tap, data-layer settle);
	 *   2. the else branch of bulkHitDueMaterialized() (materialised tap, batch recycle, botplay only);
	 *   3. opponentNoteHit() (sustains / sustain heads and the per-object path).
	 * Patching only one always misses the other two; under Turbo the tap path is (2), so a fix
	 * that only covers path (1) still leaves the taps uncounted.
	 * It is a no-op outside Turbo, so existing behaviour is unchanged.
	 * The opCombo side counter is not Turbo-gated: it is display-only and feeds the botplay score text.
	 */
	inline function addOpponentHit(den:Int):Void
	{
		if (den <= 0) return;
		// Opponent-side readout (botplay/Turbo score text); display-only, no score/judgement/rating counter.
		opCombo += den;
		_opHitCount += den;
		if (!turboModeActive) return;
		combo += den;
		if (combo > maxcombo) maxcombo = combo;
		notehitlol += den;          // the side HUD's "Total Notes Hit" grows too
		popUpComboOnly();
	}

	/**
	 * Turbo only: draw the combo number / COMBO text, never a judgement icon (showRating = false).
	 *
	 * The popup hangs off addOpponentHit together with the count because the count has three
	 * paths; attaching the popup to only one (opponentNoteHit) leaves the other two (data-layer /
	 * materialised batch) raising the number with no popup.
	 * Per-frame POPUP_IMMEDIATE_HITS budget: with thousands of opponent hits per Turbo frame,
	 * over-budget hits are neither drawn nor queued (the _popupPending queue adds icons).
	 */
	function popUpComboOnly():Void
	{
		if (_popupImmediateBudget <= 0) return;
		_popupImmediateBudget--;
		showComboNum = (combo >= 10);
		showRatingPopup(ratingPopup, '', combo, FlxG.width * 0.35, false, showComboNum);
	}

	function bulkSettleNote(d:PreloadedChartNote, acc:BulkAccumulator, srcIndex:Int):Bool
	{
		if (d == null || d.wasHit)
			return false;
		// Sustains / sustain heads: per-object path only (tail chain and trimming semantics).
		if (d.isSustainNote || d.sustainLength > 0)
			return false;

		var pos:Float = Conductor.songPosition;
		var onTime:Bool = d.strumTime <= pos;

		var den:Int = Std.int(Math.max(1, Math.round(d.noteDensity)));

		if (!d.mustPress)
		{
			unspawnNotes.setWasHit(srcIndex, true);
			acc.oppDrained += den;
			// Turbo: opponent-side unmaterialised taps are consumed here (folded groups by noteDensity).
			addOpponentHit(den);
			// Due opponent note: apply the presentation gate, matching the per-object path.
			if (onTime) gateOppLaneAnim(laneOf(d.noteData));
			return true;
		}

		if (onTime)
		{
			unspawnNotes.setWasHit(srcIndex, true);
			if (d.blockHit)
			{
				// Stuck-key notes never judge: consume silently (final effect matches the original path)
			}
			else if (d.ignoreNote)
			{
				// Under botplay the original path only fires scripts (none here): consume silently
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
				notehitlol += den; // HUD total hit count shares the totalPlayed source
				totalNotesHit += den; // botplay judgement is always ratingsData[0] with ratingMod=1
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

		// Not due yet: only botplay player taps may auto-hit early in the data layer
		// (equivalent to the old cpuControlled skippedHit branch). Manual mode returns false,
		// keeping the "off-lane notes are not settled early" semantics.
		if (!cpuControlled)
			return false;

		unspawnNotes.setWasHit(srcIndex, true);
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

	/** Presentation gate for due botplay opponent notes (sing/confirm animations, once per lane per frame). */
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
	 * Lane presentation gate for due botplay hits: character sing animation plus player-side strum confirm,
 * both once per lane per frame -- identical to the per-hit path's presentation.
	 */
	function gateBotLaneAnim(lane:Int):Void
	{
		// strum confirm (same strumsHit gate as the per-hit path, so hit effects are not lost)
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
	 * Batch hit of due materialised notes (botplay only): folds the per-hit goodNoteHit call chain
 * (judgeNote/popUpScore/RecalculateRating/recycle) into one aggregation plus a single O(living) scan.
 * Settlement matches the per-hit path; sustains/heads still use the original path (trim/tail semantics).
 * Visually equivalent: notes still disappear at the strum line and lane animations stay once per lane per frame.
	 */
	function bulkHitDueMaterialized():Void
	{
		if (!ClientPrefs.data.perfMode || !cpuControlled || replayMode || (hasActiveScripts() && !turboModeActive)) return;

		var pos:Float = Conductor.songPosition;
		var hitCount:Int = 0;
		var hurtCount:Int = 0;
		var oppCount:Int = 0;

		// Iterate the compact living list; recycleNote swap-removes the current element and moves the tail
		// element into its slot, so re-check the same index for unprocessed elements (only advance when the length is unchanged).
		var i:Int = 0;
		while (i < activeNotes.length)
		{
			var n:Note = activeNotes[i];
			var lenBefore:Int = activeNotes.length;
			var removed:Bool = false;

			{
				if (n == null || n.pooled || !n.exists)
				{
					// Ghost slot: cannot exist in the living list; skipped defensively
				}
				else if (n.isSustainNote || n.sustainLength > 0)
				{
					// Sustains and sustain heads use the per-object path (trim/tail chain semantics)
					removed = false;
				}
				else if (n.strumTime <= pos && !n.wasGoodHit && !n.hitByOpponent)
				{
					if (n.mustPress)
					{
						var den:Int = Std.int(Math.max(1, Math.round(n.noteDensity)));
						if (n.blockHit || n.ignoreNote)
						{
							recycleNote(n); // note that never judges: recycle it directly
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
							notehitlol += den; // HUD total hit count shares the same source
							totalNotesHit += den; // botplay judgement is always ratingsData[0] with ratingMod=1
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
						// Due opponent note: opponentNoteHit presentation gate plus recycle
						// Main opponent-tap path under Turbo: it bypasses opponentNoteHit, so the combo
						// counter is added explicitly here; addOpponentHit is a no-op outside Turbo.
						addOpponentHit(Std.int(Math.max(1, Math.round(n.noteDensity))));
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
			// removed or the length changed: the tail element filled the current slot, so re-check the same index
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
	 * End of this frame's data-level batch settlement: one RecalculateRating / popup merge flag / volume update.
 * The shared accumulator is cleared afterwards (the materialisation path and fastSkipPastNotes share it within the frame).
	 */
	function finishBulkFrame(drainedHit:Int, skippedHit:Int, skippedHitHealth:Float,
		skippedMiss:Int, skippedMissHealth:Float, oppDrained:Int):Void
	{
		if (skippedHit > 0)
		{
			combo += skippedHit;
			if (combo > maxcombo) maxcombo = combo;
			totalPlayed += skippedHit;
			songHits += skippedHit; // count fix: aggregated hits were previously missing from the settlement
			notehitlol += skippedHit; // count fix: the HUD total only counted the per-object path
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

	/** Clears the per-frame data-level settlement accumulator (zeroed once finishBulkFrame consumes it). */
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

/** Current hit sound (preloaded so the path is not parsed every frame; from LeatherEngine). */
var hitsoundSnd:FlxSound = null;

/**
 * Preload the currently selected hit sound (from LeatherEngine).
 * Files live under sounds/hitsounds/ (mods may override); missing files fall back to the default.
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

/** Play the hit sound (supports 'none' to mute and custom sounds; from LeatherEngine). */
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
// goodNoteHit() starts with `camZooming = true`.
// See the note on the same fix in `updateDaNote()`.
if (online.GameClient.isConnected())
	camZooming = true;
#end
// osu! tail judgement: sustain head hit -> register the active sustain; tail segment hit -> sustain complete
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
	// During replay the recorded high-precision judgement is preferred, reproducing the original score/ms (older replays without judgement data fall back to live judging)
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
	    // Judgement windows come from judgementTimings (marvelous/sick/good/bad/shit; from LeatherEngine).
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

	// ms text merged per frame: only the last hit difference of the frame is kept,
	// and flushHitPresentation() rebuilds the text and its tween pair once at frame end.
	// The original set the text (rebuilding the whole glyph mesh) and allocated two tweens per hit.
	// With perfMode off the stock per-hit direct text write and tween are kept, without merging.
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
			// 0.7.3+/1.0.4: goodNoteHitPre / opponentNoteHitPre callbacks
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
				// Play the currently selected hit sound (from LeatherEngine).
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


			#if ONLINE_ALLOWED
			// The hit itself is forwarded here. The `rating?.image` equivalent comes from the image
			// popUpScore() stashed; it is null for sustain notes, just like the null `rating` local.

			if (online.GameClient.isConnected())
			{
				online.GameClient.send("noteHit", [note.strumTime, note.noteData, note.isSustainNote,
					(note.isSustainNote ? null : onlineLastRatingImage), note.noteType,
					notes.members.indexOf(note), note.mustPress]);
				online.GameClient.send("updateMaxCombo", maxcombo);
			}
			#end

			if(!note.noAnimation && !_suppressNoteAnim) {
				var animToPlay:String = getSingAnim(note);

				// Botplay downgrade: character animations become once per lane per frame. Thousands of hits per
				// frame would otherwise trigger thousands of playAnim calls (string building + anim lookup + restart),
				// while same-lane same-frame restarts are only visible once; manual mode keeps per-hit playback.
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
					#if ONLINE_ALLOWED
					// The local character animation is echoed to the room,
					// including the "Hey!" variant's special flag.
					if (online.GameClient.isConnected())
					{
						if (note.noteType == 'Hey!')
							online.GameClient.send("charPlay", [note.gfNote ? 'cheer' : 'hey', note.gfNote, true]);
						else
							online.GameClient.send("charPlay", [animToPlay + note.animSuffix, note.gfNote]);
					}
					#end
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
					#if ONLINE_ALLOWED
					// Manual-hit confirm.
					online.GameClient.send("strumPlay", ["confirm", note.noteData, 0]);
					#end
					spr.playAnim('confirm', true);
				}
			}
						note.wasGoodHit = true;
			if (vocals.volume != 1) vocals.volume = 1;
			if (vocalsPlayer.volume != 1) vocalsPlayer.volume = 1;
			if (opponentVocals.volume != 1) opponentVocals.volume = 1;

			if (hasActiveScripts())
			{
				var scriptName:String = reverseNoteHit ? 'opponentNoteHit' : 'goodNoteHit';
				var result:Dynamic = FunkinLua.Function_Continue;
				if (!cpuControlled) {
					if (CompatEngine.isModern()) {
						// 0.7.3 format: passes Math.round(Math.abs(noteData))
						var isSus:Bool = note.isSustainNote;
						var leData:Int = Math.round(Math.abs(note.noteData));
						var leType:String = note.noteType;
						result = callOnLuas(scriptName, [noteIndexFast(note), leData, leType, isSus]);
					} else {
						// 0.6.3 format: passes the raw noteData (may be negative)
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
			// Botplay downgrade: static resets are also once per lane per frame (was one playAnim per hit)
			var stIdx:Int = Std.int(Math.abs(note.noteData));
			var laneTotal:Int = Note.ammo[mania];
			if (laneTotal <= 0) laneTotal = 1; // guard against % 0
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
			// The stock 0.6.3 path indexes playerStrums.members[note.noteData] directly;
			// laneData()'s % ammo would fold a noteData=4 written by a Lua mod (e.g. Holofunk's fifth key)
			// back to 0 and put the splash on lane 0, so the same strategy as the update() strum
			// index fix is used here.
			var strumIdx:Int = Std.int(Math.abs(note.noteData));
			var strumCount:Int = playerStrums.members.length;
			if (strumCount <= 0) return; // no lanes available while the strum group is rebuilt/cleared
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
			// A user-chosen splash skin applies in every mode; the default skin follows the compatibility path
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
				// 不要用 null 覆盖谱面的 splashSkin: NoteSplash.setupNoteSplash 只在 texture == null
				// 时挑默认图集, 所以一个没带材质的 Note 会把整首歌的自定义溅射(如
				// noteSplashes-sonic)顶掉, 表现为"贴图识别不到"。材质为空时保留谱面的 splashSkin。
				if (note.noteSplashTexture != null && note.noteSplashTexture.length > 0)
					skin = note.noteSplashTexture;
				hue = note.noteSplashHue;
				sat = note.noteSplashSat;
				brt = note.noteSplashBrt;
			}
			else
			{
				// Multi-key: use the current key count's lane colour when there is no note
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
		// Back to the menus: the watermark is visible again (ClientPrefs.data.showWatermark wins).
		backend.Watermark.setVisible(true);

		// Detach the song's completion callback before the state goes away (see _songMusic).
		if (_songMusic != null) {
			_songMusic.onComplete = null;
			_songMusic = null;
		}

		#if ONLINE_ALLOWED
		// Unregister this state's onMessage handlers and schema callbacks.
		// These closures reaching a destroyed PlayState through a Waiter is what crashed before.
		// Only this state's batch is removed: clearOnMessage() would wipe the whole room's handlers.
		// The new lines stay inside the guard, so the single-player path is unaffected.
		online.GameClient.disposeStateHandlers(this);
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
		#if ONLINE_ALLOWED
		// Each remote player gets its own rating popup.
		if (onlineRatingPopups != null) {
			for (sid => popup in onlineRatingPopups)
				if (popup != null) popup.destroyAll();
			onlineRatingPopups.clear();
		}
		#end

		// Clear NoteMs/NoteTime arrays to free memory
		if (NoteMs != null) NoteMs = [];
		if (NoteTime != null) NoteTime = [];

		// unspawnNotes now holds lightweight PreloadedChartNote data, not Note objects.
		// ChartNotes is a value wrapper: replacing it drops every column in one go.
		unspawnNotes = ChartNotes.empty();
		lastSpawnedNote = new Map<Int, Note>();

		// Destroy notes that are still alive; shells already destroyed are removed directly.
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

		// Clear the cross-song static note pool, releasing the animations/ColorSwaps of pooled notes.
		if (Note.pool != null)
			Note.pool.clear(function(note) { if (note != null && note.scale != null) note.destroy(); });

		// 1.0.4: clear the splash config cache to avoid config bleed across charts/mods
		NoteSplash.configs.clear();
		if (eventNotes != null) eventNotes = [];

		// Destroy stage backdrop
		if (stageBackdrop != null)
		{
			stageBackdrop.destroy();
			stageBackdrop = null;
		}


		// Restore the perfMode/bulkSkip overrides Turbo forced.
		if (turboModeActive)
		{
			ClientPrefs.data.perfMode = _turboPrevPerf;
			ClientPrefs.data.bulkSkip = _turboPrevBulk;
			ClientPrefs.data.fastSort = _turboPrevFastSort;
		}
		#if ONLINE_ALLOWED
		// Restore the runtime Note optimisations silenced while online.
		if (_onlineNoteOptsOff)
		{
			ClientPrefs.data.perfMode = _onlinePrevPerf;
			ClientPrefs.data.bulkSkip = _onlinePrevBulk;
			ClientPrefs.data.fastSort = _onlinePrevFastSort;
		}
		#end

		instance = null;

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


	/**
	 * Shared read-only argument arrays for the dispatch path. Nothing here is ever mutated: the
	 * previous code allocated a fresh [] / [Function_Continue] on every callOnScripts and every
	 * callOnHScript, which is pure frame garbage on dense charts.
	 */
	static final EMPTY_ARGS:Array<Dynamic> = [];
	static final EMPTY_STRINGS:Array<String> = [];
	static final CONTINUE_ONLY:Array<Dynamic> = [FunkinLua.Function_Continue];

	public function callOnScripts(funcToCall:String, args:Array<Dynamic> = null, ignoreStops = false, exclusions:Array<String> = null, excludeValues:Array<Dynamic> = null):Dynamic {
		var returnVal:Dynamic = FunkinLua.Function_Continue;
		if(args == null) args = EMPTY_ARGS;
		if(exclusions == null) exclusions = EMPTY_STRINGS;
		if(excludeValues == null) excludeValues = CONTINUE_ONLY;

		var result:Dynamic = callOnLuas(funcToCall, args, ignoreStops, exclusions, excludeValues);
		if(result == null || excludeValues.contains(result)) result = callOnHScript(funcToCall, args, ignoreStops, exclusions, excludeValues);
		return result;
	}

	#if HSCRIPT_ALLOWED
	/**
	 * MusicBeatState.initHScripts() now appends with concat instead of resetting the array,
 * so the scripts/ scripts loaded manually in PlayState.create() survive.
 * The scripts under data/states/PlayState/ and hscripts/PlayState/ are added by the parent.
	 */
	override function initHScripts():Void {
		super.initHScripts();
	}
	#end

	#if HSCRIPT_ALLOWED
	/**
	 * 0.7.3+/1.0.4 addHScript: loads one hscript file by full path.
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
		_probeSweeps++;
		// `exclusions` is dead here: the old code allocated it but never read it. Script-level
		// exclusions are applied by callers that pass an already-filtered list.
		// The old code also pushed Function_Continue into the caller's excludeValues array on every
		// call (mutating an array it does not own); Continue is now tested explicitly, which gives
		// the same result because a Continue return never overrides returnVal.
		var len:Int = hscriptArray.length;
		if (len < 1)
			return returnVal;
		for(i in 0...len) {
			var script:HScript = hscriptArray[i];
			// No script.exists() probe: HScript.call() resolves the name once and returns
			// Function_Continue for an absent / not-a-function value - exactly what the old
			// `!exists() -> continue` did. interpGet() cannot throw (null-guarded map lookups),
			// so the exists()+call() pair only ever bought a second lookup.
			if(script == null || script.closed)
				continue;

			var myValue:Dynamic = null;
			try {
				myValue = script.call(funcToCall, args);
				if(myValue == FunkinLua.Function_StopHScript || myValue == FunkinLua.Function_StopAll)
				{
					if(!_excludedBy(excludeValues, myValue) && !ignoreStops)
					{
						returnVal = myValue;
						break;
					}
				}
				else if(myValue != null && myValue != FunkinLua.Function_Continue && !_excludedBy(excludeValues, myValue))
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
		if(exclusions == null) exclusions = EMPTY_STRINGS;
		setOnLuas(variable, arg, exclusions);
		setOnHScript(variable, arg, exclusions);
	}

	/** Null-safe membership test for the dispatch exclusion lists (callers may omit them). */
	static inline function _excludedBy(list:Array<Dynamic>, value:Dynamic):Bool
		return list != null && list.contains(value);

	/**
	 * Push two engine globals per script in one sweep of each script list.
	 * Only the interleaving between scripts changes: every script still receives the same
	 * variables in the same order as two back-to-back setOnScripts() calls, and no script code
	 * runs while the values are written (Lua setglobal / interp.variables.set only), so no
	 * script can observe the difference. Use ONLY for variables that used to be pushed at the
	 * same point of the frame - delaying a set past a callback would change what scripts read.
	 */
	function setOnScripts2(n1:String, v1:Dynamic, n2:String, v2:Dynamic):Void {
		#if LUA_ALLOWED
		_probeSweeps++;
		if (luaArray != null)
			for (script in luaArray)
			{
				script.set(n1, v1);
				script.set(n2, v2);
			}
		#end
		#if HSCRIPT_ALLOWED
		_probeSweeps++;
		HScript.setOnGlobalScript(n1, v1);
		HScript.setOnGlobalScript(n2, v2);
		if (hscriptArray != null)
			for (script in hscriptArray)
				if (!script.closed)
				{
					script.set(n1, v1);
					script.set(n2, v2);
				}
		#end
	}

	/** Three-variable variant of setOnScripts2 (same reasoning). */
	function setOnScripts3(n1:String, v1:Dynamic, n2:String, v2:Dynamic, n3:String, v3:Dynamic):Void {
		#if LUA_ALLOWED
		_probeSweeps++;
		if (luaArray != null)
			for (script in luaArray)
			{
				script.set(n1, v1);
				script.set(n2, v2);
				script.set(n3, v3);
			}
		#end
		#if HSCRIPT_ALLOWED
		_probeSweeps++;
		HScript.setOnGlobalScript(n1, v1);
		HScript.setOnGlobalScript(n2, v2);
		HScript.setOnGlobalScript(n3, v3);
		if (hscriptArray != null)
			for (script in hscriptArray)
				if (!script.closed)
				{
					script.set(n1, v1);
					script.set(n2, v2);
					script.set(n3, v3);
				}
		#end
	}

	override public function setOnLuas(variable:String, arg:Dynamic, exclusions:Array<String> = null) {
		#if LUA_ALLOWED
		_probeSweeps++;
		if(exclusions == null) exclusions = EMPTY_STRINGS;
		for (script in luaArray) {
			if(exclusions.contains(script.scriptName))
				continue;

			script.set(variable, arg);
		}
		#end
	}

	public function setOnHScript(variable:String, arg:Dynamic, exclusions:Array<String> = null) {
		#if HSCRIPT_ALLOWED
		_probeSweeps++;
		if(exclusions == null) exclusions = EMPTY_STRINGS;
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
		_probeSweeps++;
		if (luaArray == null || luaArray.length == 0) return returnVal;
		if(args == null) args = EMPTY_ARGS;
		if(exclusions == null) exclusions = EMPTY_STRINGS;
		if(excludeValues == null) excludeValues = CONTINUE_ONLY;

		// Lazy: allocated only when a script closed itself while we were iterating (rare).
		var arr:Array<FunkinLua> = null;
		for (script in luaArray)
		{
			if(script.closed)
			{
				if (arr == null) arr = [];
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

			if(script.closed)
			{
				if (arr == null) arr = [];
				arr.push(script);
			}
		}

		if(arr != null)
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
			#if ONLINE_ALLOWED
			// StrumPlayAnim() echoes player confirmations.
			online.GameClient.send("strumPlay", ["confirm", id, time]);
			#end
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
		// Dense-chart downgrade: setOnScripts/callOnScripts are no-ops without scripts, but the per-hit
		// chain of seven sets plus one callback is still measurable at peak, so it is gated by
		// hasActiveScripts() -- with scripts the semantics are byte-identical (including Stop skipping
		// the calculation while set variables are still synced).
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
			// Marvelous hits count towards the FC badge (MFC > SFC > GFC > FC; from LeatherEngine).
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

	#if ONLINE_ALLOWED
	/**
		 * Two static members the online code needs; both are read by the online states.
		 * They are only meaningful while a room is connected.
	 *
	 *   * RAW_SONG -- the raw chart text loadSong() read, kept for the online chart
	 *     identity/hash work.
		 *   * redditMod -- set in the "enables" easter-egg branch so that the following
	 *     mod install/uninstall steps skip the normal alerts and skip canPause/chart-editor
	 *     checks. Consumers here: online/states/OnlineState.hx:623 (setter) and
	 *     online/mods/OnlineMods.hx:498 (reader).
	 *
	 * Deliberately placed at the END of the class: every addition above an existing method shifts
	 * the source line numbers that Haxe embeds in HXDLIN() and HX_LOCAL_STACK_FRAME(), so adding
	 * lines earlier in the file changes the generated C++ even when the macro is off. Appending
	 * here keeps every existing line number, and therefore the whole macro-off translation unit,
	 * identical to the previous output.
	 */
	/** Raw text of the chart last read by loadSong(). */
	public static var RAW_SONG:String = '';
	/** Set by the "enables" easter egg; read by the online mod installer. */
	@:unreflective
	public static var redditMod:Bool = false;

	/**
		 * Loads a chart for the online flow and keeps its raw text in RAW_SONG.
		 * online/GameClient.hx calls it when the host starts a song and online/states/RoomState.hx
		 * calls it for the "host this song" flow.
		 *
		 * The raw-text reader is Song.loadRawSong() (added here, source/Song.hx) and the parser
		 * entry point is Song.parseJSON() -- parseJSON is what Song.loadFromJson() itself calls,
		 * so the chart is normalised exactly the same way a normal load would normalise it, which
		 * is what the online flow needs: the host and the client must end up with the same
		 * in-memory chart. RAW_SONG is only empty for charts that go through the byte-stream path
		 * (see below).
	 */
	public static function loadSong(jsonInput:String, ?folder:String):SwagSong {
		// Large charts go through Song.loadFromJson's byte-stream path (same route as FreeplayState).
		// RAW_SONG stays empty for them: this is the only writer in the tree and nothing reads it
		// for streamed charts.
		var loaded:SwagSong = Song.loadFromJson(jsonInput, folder);
		RAW_SONG = (loaded != null && Reflect.field(loaded, '__seiunStream') != null)
			? '' : Song.loadRawSong(jsonInput, folder);
		return SONG = loaded;
	}

	/**
		 * Tells whether the chart's player side is BF. Who needs it:
		 * online.ChartAnalyzer.calc(songData, mustPress) is always called with
		 * playsAsBF() as the second argument, so the analyzer can tell "this chart's player side is
		 * the dad side" (online room / opponent mode) from "player side is BF".
		 *
		 * This engine has no `opponentMode` member; its equivalent switch is `playOpponent` (this
		 * file, instance field, filled from the 'playOpponent' gameplay setting) -- it drives the
		 * very same note-side flip in its own note loader. `instance` is null outside a song
		 * (main menu, chart editor, results), where "the player is BF" is the correct answer anyway.
		 *
		 * GameClient.room.state.{royalMode,royalModeDadSide} and GameClient.getPlayerSelf().bfSide are
		 * the online schema fields (online/backend/schema/{Room,Player}.hx), so the online
		 * branch keeps the online behavior.
	 *
	 * `GameClient.room.state.{royalMode,royalModeDadSide}` and `GameClient.getPlayerSelf().bfSide` are
	 * the online schema fields (online/backend/schema/{Room,Player}.hx), so the online
	 * branch keeps the online behavior.
	 */
	public static function playsAsBF():Bool {
		if (online.GameClient.isConnected()) {
			if (online.GameClient.room.state.royalMode) {
				return !online.GameClient.room.state.royalModeDadSide;
			}

			var playerSelf = online.GameClient.getPlayerSelf();
			if (playerSelf != null) {
				return playerSelf.bfSide;
			}
		}
		if (instance != null) return !instance.playOpponent;
		return true;
	}

	/**
		 * Resolves whether a raw note belongs to the player side, using the chart convention
		 * described below.
	 *
	 * The chart convention is chosen from `PlayState.SONG.format`
	 * (`rawNote[1] < Note.maniaKeys`) and the legacy convention
	 * (`rawNote[1] > Note.maniaKeys - 1` -> flip against `section.mustHitSection`).
	 *
	 * Decisive difference in THIS engine: `Song.loadFromJson()` normalises every chart through
	 * `Song.convert()`, which already rewrites every raw note index into the psych_v1 convention --
	 * for ALL formats, unconditionally:
	 *     var gottaHitNote:Bool = (rawData < ammo) ? section.mustHitSection : !section.mustHitSection;
	 *     note[1] = (rawData % ammo) + (gottaHitNote ? 0 : ammo);
	 * (source/Song.hx, `convert()`, lines ~444-465). The engine's own note loader then decides sides
	 * two-branch `isPsychRelease` test here is just the psych_v1 branch -- keeping the `format`
	 * branch would make the analyzer disagree with the engine's own loader for the legacy charts
	 * that convert() has already re-encoded.
	 *
	 * It is also per-note mania aware (`EKData.maniaAtTimeCached`), mirroring generateSong, so a
	 * "Change Mania" event mid-chart is interpreted with the same key count in both places.
	 * This per-mania model difference also applies to the analyzer.
	 */
	public static function getMustPressFromRaw(section:SwagSection, rawNote:Array<Dynamic>):Bool {
		var rawData:Int = Std.int(rawNote[1]);
		var noteMania:Int = EKData.maniaAtTimeCached(rawNote[0]);
		var noteAmmo:Int = Note.ammo[noteMania];
		return rawData < noteAmmo;
	}

	#if ONLINE_ALLOWED
	/**
		 * Chart-difficulty info, filled right after the notes are generated:
		 *   difficultyInfo = online.ChartAnalyzer.calc(songData, playsAsBF());
		 * It is read by `online.FunkinPoints.devFP(...)`, which feeds the "V5 FP" readout in the score
		 * text.
		 *
		 * Appended here (not next to the other vars) to respect the line-number constraint: adding
		 * lines above existing members shifts the line numbers Haxe embeds in HXDLIN().
	 */
	public var difficultyInfo:online.ChartAnalyzer.FunkinDiffInfo;

	/**
		 * Formats the FP readout from `songPoints`; called from `buildScoreText()`'s FP
		 * readout. Lives in the same ONLINE_ALLOWED class-level block as `difficultyInfo`.
	 * readout. Lives in the same ONLINE_ALLOWED class-level block as `difficultyInfo`.
	 */
	function getPresencePoints():String {
		if (songPoints == 0)
			return "";

		if (songPoints < 0) {
			var aasss = '${songPoints}'.split('');
			aasss.insert(1, ' ');
			return ' - ${aasss.join('')}FP';
		}

		return ' - ${songPoints}FP';
	}

	/**
		 * The FP fields.
		 *
		 *   * songPoints  -- `public var songPoints(default, null):Float = 0;`
		 *   * songDensity -- `public var songDensity:Float = 0;`
		 *   * netSong     -- `public var netSong:online.network.Leaderboard.NetSong = null;`
		 *
		 * `songPoints`/`songDensity` are what feeds `online.FunkinPoints.(f)calcFP/devFP` from
		 * `buildScoreText()` / `generateSong()` / `endSong()`; `netSong` is only ever filled by
		 * `prepareNetSong()`, which is not wired here (see the generateSong() note -- that is the
		 * leaderboard-submission wiring, not the FP readout), so the field is deliberately present but
		 * always null. Kept at the END of the class with `difficultyInfo` for the line-number reason
		 * documented above. `songPoints` is a plain `var` rather than a read-only property:
		 * nothing outside this class writes it either way.
	 */
	public var songPoints:Float = 0;
	public var songDensity:Float = 0;
	public var netSong:online.network.Leaderboard.NetSong = null;

	
	/*
	 * ============================================================================================
	 * Online per-player score HUD ("scoreboard").
	 * ============================================================================================
		 * Per-player score HUD renderer for the online room.
		 *
		 * Entry points: updateScoreSelf(), updateTeamSide(), averageOf(), updateScoreSID(),
		 * doTweenScore(), getPlayerStats() and the @:publicFields class PlayStatePlayer.
		 *
	 * This is a *pure render* of the online schema
	 * (online.GameClient.room.state.players, source/online/backend/schema/Player.hx). It touches
	 * nothing on the single-player HUD: every entry point is behind GameClient.isConnected() and
	 * the whole block lives inside the class-level #if ONLINE_ALLOWED region at the END of the
	 * class (zero line-number offset for everything that came before it).
	 *
		 * Implementation notes (library / engine differences, all mechanical):
	 *   * FlxText.camera = camOther (flixel 5) -> cameras = [camOther] (flixel 4.11).
	 *   * The updateScore() FP block is folded into the guarded branch added in
	 *     updateScore() itself (this engine builds its score text through
	 *     buildScoreText()/flushHitPresentation(), not by assigning scoreTxt.text inline).
	 *   * resetRPC(true) (Discord RPC) is not called here: this engine has no equivalent.
	 *   * PlayStatePlayer is declared after PlayState rather than inline.
	 *
	 * Not covered here (the remaining online work):
	 * registerMessages() and the outgoing note/strum/score messages. They need the per-sid
	 * characters map, popUpScoreOP, getRatingOffset, getStrumsFromSID and the online character
	 * spawn, none of which exist in this engine yet.
	 */

	/** Per-player score texts; keyed by session id, or by 'LEFTSIDE'/'RIGHTSIDE' in team mode. */
	public var scoreTxtOthers:Map<String, FlxText> = new Map();
	public var scoreTxtOthersTween:Map<String, FlxTween> = new Map();
	public var scoreTxtP1:FlxText;
	public var scoreTxtP2:FlxText;
	/** Score HUD baseline Y. */
	var scoreTxtOriginY:Float = 700;
	/** Per-player rating/counter wrapper. */
	var playersStats:Map<String, PlayStatePlayer> = new Map();
	/** Set by the room's "endSong" message listener; read by endSong(). */
	var canEndSongOnline:Bool = false;

	/** Per-player score text update. */
	public function updateScoreSelf(?miss:Bool = false):Void {
		RecalculateRating(miss);
		if (online.GameClient.isConnected()) {
			updateScoreSID(online.GameClient.room.sessionId);
		}
	}

	/** Team-wide score text update (isRight, miss). */
	public function updateTeamSide(isRight:Bool, miss:Bool):Void {
		var sideNames:Array<String> = [];
		var sideScores:Array<Float> = [];
		var sideMisses:Array<Float> = [];
		var sideAccuracy:Array<Float> = [];
		var sidePing:Array<Float> = [];
		var sideFP:Array<Float> = [];

		for (sid => player in online.GameClient.room.state.players) {
			if (player.bfSide == isRight) {
				var stats = getPlayerStats(sid);

				var ret:Dynamic = callOnScripts('onRecalculateRatingPlayer', [sid], true);
				if (ret != FunkinLua.Function_Stop) {
					stats.recalculateRating();
				}

				sideNames.push(player.name);
				sideScores.push(player.score);
				sideMisses.push(player.misses);
				sideAccuracy.push(stats.ratingPercent * 100);
				sidePing.push(player.ping);
				if (ClientPrefs.data.showFP) {
					sideFP.push(player.songPoints);
				}
			}
		}

		if (sideNames.length == 0)
			return;

		var daText = scoreTxtOthers.get(isRight ? 'RIGHTSIDE' : 'LEFTSIDE');

		var pingText = onlinePingList(sidePing);

		if (ClientPrefs.data.onlineScoreDetails) {
			daText.text = onlineDetailScore(sideNames.join(' & '), [
				['scorelangtxt', 'Score', FlxStringUtil.formatMoney(averageOf(sideScores), false)],
				['missesText', 'Misses', Std.string(averageOf(sideMisses))],
				['acclangtxt', 'Accuracy', CoolUtil.floorDecimal(averageOf(sideAccuracy), 2) + '%']
			], ClientPrefs.data.showFP ? averageOf(sideFP) : null, pingText);
		}
		else {
			daText.text = onlineCompactScore(sideNames.join(' & '), averageOf(sideScores), averageOf(sideMisses),
				Std.string(CoolUtil.floorDecimal(averageOf(sideAccuracy), 2)), null,
				ClientPrefs.data.showFP ? averageOf(sideFP) : null, pingText);
		}

		daText.y = scoreTxtOriginY - daText.height;

		if (!miss) {
			doTweenScore(isRight ? 'RIGHTSIDE' : 'LEFTSIDE', isRight);
		}

		callOnScripts('onUpdateScoreTeam', [isRight, miss]);
	}

	function averageOf(arr:Array<Float>):Float {
		if (arr.length == 0)
			return 0;
		var sum = 0.0;
		for (item in arr)
			sum += item;
		if (sum == 0)
			return 0;
		return sum / arr.length;
	}

	/*
	 * The online score HUD is localised and Ping is rounded. Labels reuse the engine's
	 * own keys where they exist (scorelangtxt / missesText / acclangtxt); only Rating
	 * (ScoreHistorySubstate.rating) and Ping (Online.room.ping) come from shared keys.
	 * The compact one-liner is the default form; ClientPrefs.onlineScoreDetails restores the
	 * multi-line block. Text only -- no layout math changes.
	 */
	function onlineScoreLabel(key:String, fallback:String):String {
		var s = StringTools.trim(Language.get(key, fallback));
		if (StringTools.endsWith(s, ':') || StringTools.endsWith(s, '：'))
			s = StringTools.trim(s.substr(0, s.length - 1));
		return s;
	}

	function onlinePingMs(ping:Null<Float>):String {
		if (ping == null || ping != ping)
			return '?ms';
		return Math.round(ping) + 'ms';
	}

	function onlinePingList(pings:Array<Float>):String {
		var out:Array<String> = [];
		for (p in pings)
			out.push(onlinePingMs(p));
		return out.join(' & ');
	}

	function onlineCompactScore(name:String, score:Float, misses:Float, percent:String, ratingFC:String, fp:Null<Float>, pingText:String):String {
		var out = name + ': ' + FlxStringUtil.formatMoney(score, false)
			+ ' | ' + onlineScoreLabel('missesText', 'Misses') + ': ' + misses
			+ ' | ' + percent + '%';
		if (ratingFC != null && ratingFC != '')
			out += ' - ' + ratingFC;
		if (ClientPrefs.data.showFP && fp != null)
			out += ' | ' + Math.round(fp) + 'FP';
		return out + ' | ' + onlineScoreLabel('Online.room.ping', 'Ping') + ': ' + pingText;
	}

	function onlineDetailScore(name:String, lines:Array<Array<String>>, fp:Null<Float>, pingText:String):String {
		var out = name;
		for (line in lines)
			out += '\n' + onlineScoreLabel(line[0], line[1]) + ': ' + line[2];
		if (ClientPrefs.data.showFP && fp != null)
			out += '\nFP: ' + Math.round(fp);
		return out + '\n' + onlineScoreLabel('Online.room.ping', 'Ping') + ': ' + pingText;
	}

	/** Per-sid score text update. */
	public function updateScoreSID(sid:String, ?miss:Bool = false):Void {
		var op = getPlayerStats(sid);

		if (online.GameClient.room.state.teamMode) {
			updateTeamSide(op.player.bfSide, miss);
			return;
		}

		setOnScripts('scoreOP', op.player.score);
		setOnScripts('missesOP', op.player.misses);
		setOnScripts('hitsOP', op.calcHits()); // may be inaccurate to hits
		setOnScripts('comboOP', op.combo);

		var ret:Dynamic = callOnScripts('onRecalculateRatingPlayer', [sid], true);
		if (ret != FunkinLua.Function_Stop) {
			op.recalculateRating();
		}

		var str:String = op.ratingName != null ? op.ratingName : '?';
		var percent:Float = 0;
		if (op.calcTotalPlayed() != 0) {
			percent = CoolUtil.floorDecimal(op.ratingPercent * 100, 2);
			str += ' ($percent%) - ${op.ratingFC}';
		}

		var countSide = 0;
		for (otherSid => otherPlayer in online.GameClient.room.state.players) {
			if (otherPlayer.bfSide == op.player.bfSide) {
				countSide++;
			}
		}

		var daText = scoreTxtOthers.get(sid);

		var pingText = onlinePingMs(op.player.ping);

		if (ClientPrefs.data.onlineScoreDetails && countSide <= 1) {
			daText.text = onlineDetailScore(op.player.name, [
				['scorelangtxt', 'Score', FlxStringUtil.formatMoney(op.player.score, false)],
				['missesText', 'Misses', Std.string(op.player.misses)],
				['ScoreHistorySubstate.rating', 'Rating', str]
			], ClientPrefs.data.showFP ? op.player.songPoints : null, pingText);
		}
		else {
			daText.text = onlineCompactScore(op.player.name, op.player.score, op.player.misses, Std.string(percent), op.ratingFC,
				ClientPrefs.data.showFP ? op.player.songPoints : null, pingText);
		}

		daText.y = scoreTxtOriginY - (effectiveOx(sid) * 20) - daText.height;

		if (!miss) {
			doTweenScore(sid);
		}

		setOnScripts('ratingOP', op.ratingPercent);
		setOnScripts('ratingNameOP', op.ratingName);
		setOnScripts('ratingFCOP', op.ratingFC);

		callOnScripts('onUpdateScorePlayer', [sid, miss]);
	}

	function doTweenScore(sid:String, ?isRight:Null<Bool> = null):Void {
		if (isRight != null) {
			sid = isRight ? 'RIGHTSIDE' : 'LEFTSIDE';
		}

		if (ClientPrefs.data.scoreZoom) {
			if (scoreTxtOthersTween.exists(sid)) {
				scoreTxtOthersTween.get(sid).cancel();
			}

			var text = scoreTxtOthers.get(sid);
			text.scale.x = 1.025;
			text.scale.y = 1.025;
			
			scoreTxtOthersTween.set(sid, FlxTween.tween(text.scale, {x: 1, y: 1}, 0.2, {
				onComplete: function(twn:FlxTween) {
					scoreTxtOthersTween.remove(sid);
				}
			}));
		}
	}

	/**
	 * Vertical row number for per-sid texts (two clients' F7 FP texts overlapped).
	 *
	 * The position should come from the server's `Player.ox`, but the server does not always
	 * provide a usable ox, and then the two same-side rows both landed on the same y. This adds
	 * a client-side fallback: use the server value when ox > 0, otherwise give a stable row
	 * number from the player's insertion order on that side (MapSchema preserves it).
	 */
	function effectiveOx(sid:String):Int {
		if (!online.GameClient.isConnected() || online.GameClient.room == null)
			return 0;

		var player = online.GameClient.room.state.players.get(sid);
		if (player == null)
			return 0;
		if (player.ox > 0)
			return Std.int(player.ox);

		var index:Int = 0;
		for (otherSid => other in online.GameClient.room.state.players) {
			if (other == null)
				continue;
			if (other.bfSide == player.bfSide) {
				if (otherSid == sid)
					return index;
				index++;
			}
		}
		return 0;
	}

	function getPlayerStats(sid:String):PlayStatePlayer {
		if (!playersStats.exists(sid))
			playersStats.set(sid, new PlayStatePlayer(online.GameClient.room.state.players.get(sid)));

		return playersStats.get(sid);
	}

	/*
	 * ============================================================================================
	 * Per-session characters map + strums/vocals accessors.
	 * ============================================================================================
		 * Per-session characters map plus the strums/vocals accessors.
		 *
		 * Entry points: getStrumsFromSID(), getPlayerStrums(), getOpponentStrums(),
		 * getVocalsFromSID(), getVocalsFromSIDVolume() and the per-sid spawn in create().
	 *
		 * Implementation notes (all mechanical, no single-player behaviour change):
	 *   * The engine builds exactly one dad + one boyfriend in create(); the room-player
	 *     preload path pushes one character per room player. `spawnOnlineCharacters()` keeps
	 *     the engine's two canonical characters and maps the LOCAL session id onto whichever
	 *     of them matches player.bfSide; only REMOTE sessions get an extra Character.
	 *   * The skin branch in initPlayCharacter is not implemented: this engine has no
	 *     ClientPrefs.data.currentSkin / player.skin handling. A remote player is therefore
	 *     rendered with the song's own player1/player2 character -- the same final fallback.
	 *   * Health icons / nameplates are not spawned per player. This engine has a single
	 *     iconP1/iconP2 and no nameplate group, so they are absent; cosmetics only, not on
	 *     the critical path.
	 *   * `characters.get(sid)` is null-checked in getStrumsFromSID/getVocalsFromSID.
	 */

	/** Per-sid characters, keyed by session id. */
	public var characters:Map<String, Character> = new Map<String, Character>();

	/** Player strum group. */
	public function getPlayerStrums():FlxTypedGroup<StrumNote> {
		// Online returns this engine's own mustPress meaning: the note update uses
		// strumGroup = daNote.mustPress ? playerStrums : opponentStrums, so mustPress notes always
		// live in playerStrums. The playsAsBF() meaning matches only while mustPress is
		// BF-relative; online, a dad-side player (bfSide=false) is misread as opponentStrums, so its strumPlay animation plays on the wrong side.
		if (online.GameClient.isConnected())
			return playerStrums;

		if (playsAsBF())
			return playerStrums;
		return opponentStrums;
	}

	/** Opponent strum group. */
	public function getOpponentStrums():FlxTypedGroup<StrumNote> {
		if (online.GameClient.isConnected())
			return opponentStrums;

		if (playsAsBF())
			return opponentStrums;
		return playerStrums;
	}

	/** Strum group of the given sid, or null when the sid has no character. */
	public function getStrumsFromSID(sid:String):FlxTypedGroup<StrumNote> {
		if (online.GameClient.isConnected() && online.GameClient.room.state.royalMode) {
			return online.GameClient.room.state.royalModeDadSide ? opponentStrums : playerStrums;
		}

		var char = characters.get(sid);
		if (char != null && char.isPlayer == playsAsBF())
			return playerStrums;

		return opponentStrums;
	}

	/** Vocals of the given sid. */
	public function getVocalsFromSID(sid:String):FlxSound {
		if (online.GameClient.isConnected() && online.GameClient.room.state.royalMode) {
			return null;
		}

		var char = characters.get(sid);
		if (char == null || opponentVocals == null || opponentVocals.length <= 0 || char.isPlayer == playsAsBF()) {
			return vocals;
		}
		return opponentVocals;
	}

	/** Sets the vocals volume of the given sid. */
	public function getVocalsFromSIDVolume(sid:String, v:Float):Void {
		var sidVocals = getVocalsFromSID(sid);
		if (sidVocals != null)
			sidVocals.volume = v;
	}

	/** Per-sid character spawn, minus skins / icons / nameplates. */
	/** A character this state created itself (not the dad/boyfriend canonical). */
	var onlineIndepChars:Map<String, Character> = new Map<String, Character>();

	/** SIDs that already have their ping/botplay/noteHold listeners (reconnect must not stack them). */
	var onlineListenedSIDs:Map<String, Bool> = new Map<String, Bool>();

	/**
	 * Online health is *room-shared* (Room.health).
	 * onlineSyncedHealth = the last synced health; syncOnlineHealth() uses it to compute the delta.
	 */
	var onlineSyncedHealth:Float = 1;
	var onlineHealthReady:Bool = false;

	/**
	 * Keep characters consistent with room.state.players, with exactly one Character per player.
	 * Every player must have exactly one Character.
	 *
	 * Rules (idempotent; safe to repeat from create(), onAdd/onRemove("players") and bfSide changes):
	 *   1. the first sid on the BF side (bfSide=true) takes the existing boyfriend, and the first sid on the dad side takes the existing dad;
	 *   2. the second and later players on a side each get a new Character (using the song's player1/player2);
	 *   3. a sid that leaves the room returns its canonical (not destroyed); an independently created one is destroyed and removed from the group;
	 *   4. hide an unoccupied side's canonical -- this is the fix for the "two opponent sprites" bug: while both clients defaulted to
	 *      bfSide=false, the local dad canonical and the remote shadow character showed at once.
	 *      The server now assigns sides in onPlayerJoined (one left, one right) and the client falls back to the character table.
	 */
	function syncOnlineCharacters():Void {
		var room = online.GameClient.room;
		if (room == null || room.state == null || room.state.players == null)
			return;

		// 1) Which side's canonical slot each sid occupies
		var bfOwner:String = null;
		var dadOwner:String = null;
		for (sid => player in room.state.players) {
			if (player == null)
				continue;
			if (player.bfSide) {
				if (bfOwner == null)
					bfOwner = sid;
			}
			else if (dadOwner == null)
				dadOwner = sid;
		}

		// 2) Drop the sids that have left the room
		var gone:Array<String> = [];
		for (sid in characters.keys()) {
			if (room.state.players.get(sid) == null)
				gone.push(sid);
		}
		for (sid in gone) {
			var indep = onlineIndepChars.get(sid);
			onlineIndepChars.remove(sid);
			characters.remove(sid);
			if (indep != null) {
				(indep.isPlayer ? boyfriendGroup : dadGroup).remove(indep, true);
				indep.destroy();
			}
		}

		// 3) Assign / reuse per room member
		for (sid => player in room.state.players) {
			if (player == null)
				continue;

			var isBF:Bool = player.bfSide;
			var canonical:Character = isBF ? boyfriend : dad;
			var ownsCanonical:Bool = (isBF ? bfOwner : dadOwner) == sid;
			var indep = onlineIndepChars.get(sid);
			var current = characters.get(sid);

			if (ownsCanonical) {
				if (indep != null) {
					// This player went from an independent character to the canonical owner (e.g. the other side freed it)
					onlineIndepChars.remove(sid);
					(indep.isPlayer ? boyfriendGroup : dadGroup).remove(indep, true);
					indep.destroy();
					if (current == indep)
						current = null;
				}
				canonical.ox = Std.int(player.ox);
				characters.set(sid, canonical);
			}
			else {
				if (current == null || indep == null) {
					// Needs a (new) independent character: either none yet, or it currently owns the canonical slot
					var charName:String = isBF ? SONG.player1 : SONG.player2;
					var nc:Character = new Character(0, 0, charName, isBF);
					startCharacterPos(nc, !isBF);
					(isBF ? boyfriendGroup : dadGroup).add(nc);
					onlineIndepChars.set(sid, nc);
					characters.set(sid, nc);
					current = nc;
				}
				if (current != null)
					current.ox = Std.int(player.ox);
			}
		}

		// 4) Hide the canonical character of an unclaimed side (avoids ghost characters)
		if (boyfriend != null)
			boyfriend.visible = bfOwner != null;
		if (dad != null)
			dad.visible = dadOwner != null;
	}

	/**
	 * Per-sid sync for the Change Character event.
	 *
	 * This engine drives remote-player animations (charPlay, opponentNoteHitSID,
	 * noteMiss / noteHold) through characters:Map<sid, Character>. The event
	 * walks [canonical].concat([for (v in characters) v]) in the event and builds one
	 * `<value2>__<sid>` instance per same-side sid, then characters.set(daSID, char). This engine's
	 * onEvent used to swap only the canonical, so after a character change characters[sid] still
	 * pointed at the old, replaced-out instance (alpha 0.00001): to the other player the new character just stands still.
	 *
	 * This function follows the same rules as syncOnlineCharacters():
	 *   * the first sid on a side owns the canonical -> characters[sid] is re-pointed to the swapped canonical;
	 *   * the other same-side sids are independent instances -> build one `<value2>__<sid>` (the
	 *     resource name stays value2 without the suffix; only the Map key carries it) and replace onlineIndepChars[sid],
	 *     otherwise the next onAdd/onRemove triggers syncOnlineCharacters() and rebuilds the song default character.
	 * Old instances are only hidden, not destroyed, which keeps them in their groups.
	 *
	 * Online only; charType == 2 (gf) never enters the characters map, so callers skip it.
	 */
	function onlineRebindCharacters(charType:Int, newChar:String):Void {
		if (!online.GameClient.isConnected()) return;

		var room = online.GameClient.room;
		if (room == null || room.state == null || room.state.players == null) return;

		var isBF:Bool = (charType == 0);

		// Canonical owner = the first sid on that side (same rule as syncOnlineCharacters)
		var owner:String = null;
		for (sid => player in room.state.players) {
			if (player != null && player.bfSide == isBF) {
				owner = sid;
				break;
			}
		}

		var holder:Character = isBF ? boyfriend : dad;

		for (sid in characters.keys()) {
			var old:Character = characters.get(sid);
			if (old == null || old.isPlayer != isBF) continue;   // the other side, or already gone
			if (old.curCharacter == newChar) continue;           // already the new character

			if (sid == owner) {
				if (holder != null) characters.set(sid, holder);
				continue;
			}

			var target:Character = null;
			var indepID:String = newChar + '__' + sid;
			if (isBF) {
				if (!boyfriendMap.exists(indepID)) {
					var nb:Boyfriend = new Boyfriend(0, 0, newChar);
					boyfriendMap.set(indepID, nb);
					boyfriendGroup.add(nb);
					startCharacterPos(nb);
					nb.alpha = 0.00001;
					startCharacterLua(nb.curCharacter);
				}
				target = boyfriendMap.get(indepID);
			} else {
				if (!dadMap.exists(indepID)) {
					var nd:Character = new Character(0, 0, newChar);
					dadMap.set(indepID, nd);
					dadGroup.add(nd);
					startCharacterPos(nd, true);
					nd.alpha = 0.00001;
					startCharacterLua(nd.curCharacter);
				}
				target = dadMap.get(indepID);
			}
			if (target == null) continue;

			var keepAlpha:Float = old.alpha;
			old.alpha = 0.00001;
			target.alpha = keepAlpha;
			characters.set(sid, target);
			onlineIndepChars.set(sid, target);
		}
	}
	/*
		 * The remaining host methods the online noteHit / registerMessages path calls; none of
		 * them existed here before.
	 *
		 * Implementation notes:
	 *   * getRatingOffset(): this engine does not have `ClientPrefs.data.verticalRatingPos`,
	 *     so placementY is always 0 (horizontal placement).
	 *   * popUpScoreOP(): this engine has a
	 *     pooled RatingPopup (source/popup/RatingPopup.hx) whose show(ratingKey, combo, rate, baseX,
	 *     ...) already applies RATING_X_OFFSET == -40 -- the same as
	 *     `rating.x = placement[0] - 40` -- so getRatingOffset()[0] is passed as `baseX`. The combo
	 *     count comes from the per-sid stats the score HUD already keeps.
	 *   * showBotplay(): the body is just
	 *     the botplay label visibility.

	 * NOTE: these are staged host methods. They are only *called* by the noteHit listener, which
	 * needs the online opponent-note loop to be wired first (see the deferred registerMessages()
	 * note).
	 */

	/**
	 * Online rating popups must be one per sid.
	 *
	 * comboGroup is a shared container, but each popup takes an *independent*
	 * sprite from the pool (`comboGroup.recycle(new FlxTweenedSprite(...))`),
	 * positioned by getRatingOffset(forSID) (:4769-4785) per sid. This engine replaced that with a
	 * pooled RatingPopup (source/popup/RatingPopup.hx), and popUpScore() and popUpScoreOP()
	 * **share the same instance**, so:
	 *   * both players' rating icons stack on the same baseX (always FlxG.width*0.35 locally);
	 *   * RatingPopup.show() calls clearAll() when !comboStacking, which clears its own container's
	 *     members and wipes the other player's floating icons too.
	 * Here each remote sid lazily gets its own RatingPopup (its own container / pool) while the
	 * local player keeps the main ratingPopup. Created only online; the single-player path is unchanged.
	 */
	var onlineRatingPopups:Map<String, RatingPopup> = new Map<String, RatingPopup>();

	/** Get (or lazily create) the rating popup owned by a remote sid. */
	function getOnlineRatingPopup(sid:String):RatingPopup {
		var popup = onlineRatingPopups.get(sid);
		if (popup != null) return popup;

		popup = new RatingPopup();
		popup.targetCameras = [camHUD];
		popup.antialiasing = isPixelStage ? false : ClientPrefs.data.globalAntialiasing;
		popup.isPixel = isPixelStage;
		popup.daPixelZoom = daPixelZoom;

		// Every popup needs its own FlxSpriteGroup: RatingPopup.clearAll() clears `container.members`,
		// so sharing comboGroup across sids would share one pool. Cameras must be assigned
		// explicitly or the children fall back to the default game camera (see create()).
		var grp:FlxSpriteGroup = new FlxSpriteGroup();
		grp.cameras = [camHUD];
		if (CompatEngine.isModern() && comboGroup != null)
			comboGroup.add(grp);
		else
			insert(members.indexOf(strumLineNotes), grp);
		popup.container = grp;

		onlineRatingPopups.set(sid, popup);
		return popup;
	}

	/** Whether the BOTPLAY label is visible. */
	@:unreflective public var botplayVisibility:Bool = false;

	/** Rating placement offset (horizontal / vertical) for the given sid. */
	function getRatingOffset(?forSID:String):Array<Float> {
		var placementX:Float = FlxG.width * 0.35;
		var placementY:Float = 0;
		if (online.GameClient.isConnected() && forSID != null) {
			var char = characters.get(forSID);
			if (char != null) {
				placementX = FlxG.width * (0.4 + (char.isPlayer == playsAsBF() ? 0.15 : -0.1));
				placementX += char.ox * (char.isPlayer == playsAsBF() ? 250 : -250);
			}
		}
		return [placementX, placementY];
	}

	/** Rating popup for the given sid, drawn through this engine's RatingPopup. */
	function popUpScoreOP(ratingImage:String, ?forSID:String):Void {
		// A remote player uses its own popup; the local player still goes through ratingPopup / popUpScore()
		// (the server broadcasts noteHit with `except: client`, so the local client never receives its own hits).
		var popup:RatingPopup = ratingPopup;
		if (forSID != null)
			popup = getOnlineRatingPopup(forSID);

		if (popup == null)
			return;

		var stats:PlayStatePlayer = (forSID != null) ? getPlayerStats(forSID) : null;
		var comboValue:Int = (stats != null) ? stats.combo : 0;
		var placement = getRatingOffset(forSID);

		showRatingPopup(popup, ratingImage, comboValue, placement[0], showRating, comboValue >= 10);
	}

	/** Character animation tag for the given side / sid. */
	function getCharPlayTag(isBF:Null<Bool>, ?sid:String):String {
		if (sid != null)
			return 'characters[${sid}]';

		if (isBF == null)
			return 'gf';

		return isBF ? 'boyfriend' : 'dad';
	}

	/**
	 * 引擎自带的 side HUD（总命中数 / 连击 / 判定统计）与键盘-KPS 面板挂在 `camOther` 上，
	 * 而 1.0.4 模组关闭 HUD 的写法是把标准 HUD 元素逐个设成不可见（`scoreTxt` / `healthBar` /
	 * `iconP1` …）。1.0.4 里根本不存在这两个东西，所以那套写法覆盖不到它们 —— 结果是它们直接
	 * 盖在模组自制界面上（SonicTheFunkChinese 用假歌曲当菜单/设置界面，画面上就多出这两块）。
	 *
	 * 这里让它们跟随标准 HUD：脚本把 `scoreTxt` 关掉就等于把整块 HUD 关掉。用户自己的
	 * `ClientPrefs.data.hideHud`（含在线模式自己关掉 scoreTxt 的情况）不算 —— 那是引擎/用户
	 * 的选择，两个开关保持互不影响。
	 */
	private var _hudExtrasSuppressed:Bool = false;
	private var _hudExtrasKeyboardForced:Bool = false;
	private var _hudExtraTexts:Array<FlxText> = null;
	function syncHudExtras():Void
	{
		if (_hudExtrasSuppressed || scoreTxt == null) return;

		var engineHidesHud:Bool = ClientPrefs.data.hideHud;
		#if ONLINE_ALLOWED
		if (online.GameClient.isConnected()) engineHidesHud = true;
		#end
		var scriptHidHud:Bool = !scoreTxt.visible && !engineHidesHud;

		if (_hudExtraTexts == null) _hudExtraTexts = [tnh, cm, marv, sick, good, bad, shit, miss];
		for (t in _hudExtraTexts)
			if (t != null) t.visible = !scriptHidHud;

		if (keyboardDisplay != null)
		{
			if (scriptHidHud)
			{
				keyboardDisplay.visible = false;
				_hudExtrasKeyboardForced = true;
			}
			else if (_hudExtrasKeyboardForced)
			{
				keyboardDisplay.visible = ClientPrefs.data.keyboardDisplay;
				_hudExtrasKeyboardForced = false;
			}
		}
	}

	/**
	 * Hides the play-HUD pieces that PlayStateResultsSubstate does not cover with its own panels.
	 *
	 * The results screen hides healthBar/scoreTxt/icons/timeBar/keyboardDisplay/strumLineNotes, but the
	 * side HUD and the BOTPLAY/REPLAY/ms/judge labels live on camOther, which it keeps visible, so they
	 * were drawn straight over the results panels (the side HUD's 20px text with a 2px black outline
	 * reads as a black box behind its numbers, and the raw counts collided with the results values).
	 * Nothing restores them: at that point the song is over and the PlayState is discarded, exactly like
	 * the other hides the results screen already performs.
	 */
	public function hideTransientHud():Void
	{
		// 结算界面把这批 HUD 一次性关掉且不再恢复，所以跟随逻辑必须让位，否则会把它们又点亮。
		_hudExtrasSuppressed = true;
		for (t in [tnh, cm, marv, sick, good, bad, shit, miss])
			if (t != null) t.visible = false;
		if (msTxtKade != null) msTxtKade.visible = false;
		if (atkText != null) atkText.visible = false;
		if (botplayTxt != null) botplayTxt.visible = false;
		if (replayTxt != null) replayTxt.visible = false;
		if (judgeRestoreTxt != null) judgeRestoreTxt.visible = false;
	}

	/** Shows the BOTPLAY label. */
	function showBotplay():Void {
		if (botplayTxt == null)
			return;

		// There is an online branch that shows the BOTPLAY label when any player in the room
		// has botplay on, but it reads the long-gone `state.player1/player2` fields, so the whole
		// block is commented out there. This engine's schema is a `players` map, so the same intent is
		// restored: show the label when the local or any room player has botplay on (still centred).
		// showBotplay is only called from the online listener, so the single-player path is unaffected.
		botplayVisibility = cpuControlled;
		if (online.GameClient.isConnected() && online.GameClient.room != null) {
			for (sid => player in online.GameClient.room.state.players) {
				if (player != null && player.botplay) {
					botplayVisibility = true;
					break;
				}
			}
		}

		botplayTxt.x = FlxG.width / 2 - botplayTxt.width / 2;
		botplayTxt.visible = botplayVisibility;
	}

	
	/*
	 * ============================================================================================
	 * Online note-loop gating + ready gating + registerMessages().
	 * ============================================================================================
		 * Online note-loop and ready gating plus registerMessages().
		 *
		 * Entry points: playOtherSide(), countOpponents(), isPlayerNote(), the per-sid
		 * opponentNoteHit(note, ?sid), the canStart/waitReady/isReady gates and registerMessages().
	 *
	 * This closes the two holes in the online note loop:
	 *   1. this engine's update() auto-hit opponent notes unconditionally, so the "noteHit"
	 *      listener would double-drive them -> `opponentAutoHitAllowed()` gates the local path;
	 *   2. this engine's create() starts the countdown unconditionally, so the "startSong"
	 *      listener would start it twice -> `onlineCheckCanStart()` holds the first request.
	 *
		 * Implementation notes (all mechanical):
	 *   * `isPlayerNote`: the check is `note.mustPress == playsAsBF()` because mustPress is
	 *     BF-relative. This engine's generateSong() already flips mustPress for the local player
	 *     (`if (playOpponent) gottaHitNote = !gottaHitNote`), so the predicate is just
	 *     `note.mustPress`.
	 *   * per-sid opponentNoteHit: this
	 *     engine's method is performance-gated and cannot be edited outside a guard, so
	 *     `opponentNoteHitSID` reuses it with `note.noAnimation` raised and animates the remote
	 *     player's own character afterwards.
	 *   * `Alphabet` stands in for the overlay (same constructor signature).
	 *   * the "noteMiss" listener's `unspawnNotes.remove(note)` is NOT portable (this engine's
	 *     unspawnNotes holds PreloadedChartNote, not Note); the note goes back to the engine's note
	 *     pool through recycleNote() instead.
	 *   * `replayPlayer`/`replayRecorder`/`nameplates`/s3d are absent here.
	 */

	/** This client drives the opponent side itself. */
	public var playOtherSide:Bool = false;

	/** Ready-gating fields. */
	var isReady:Bool = false;
	var waitReady(default, set):Bool = false;
	var canStart:Bool = true;
	var waitReadySpr:Alphabet;
	var readyTween:FlxTween;

	function set_waitReady(v:Bool):Bool {
		if (readyTween != null)
			readyTween.cancel();

		if (waitReadySpr != null)
			readyTween = FlxTween.tween(waitReadySpr, {alpha: v ? 1 : 0}, 0.5, {ease: FlxEase.quadIn});

		return waitReady = v;
	}

	/** Creates the wait-ready overlay. */
	function spawnWaitReadyOverlay():Void {
		if (waitReadySpr != null)
			return;

		waitReadySpr = new Alphabet(0, 0, "PRESS ACCEPT TO START", true);
		waitReadySpr.cameras = [camOther];
		waitReadySpr.setAlignmentFromString('center');
		waitReadySpr.x = FlxG.width / 2;
		waitReadySpr.y = (FlxG.height - waitReadySpr.height) / 2;
		waitReadySpr.alpha = 0;
		add(waitReadySpr);
		waitReady = true;
	}

	/** startCountdown()'s `canStart` check. */
	function onlineCheckCanStart():Bool {
		if (!online.GameClient.isConnected())
			return true;

		if (!canStart)
		{
			canStart = true;
			if (waitReadySpr != null)
				waitReadySpr.alpha = 1;
			return false;
		}
		return true;
	}

	/** May this client auto-hit opponent notes locally? */
	function opponentAutoHitAllowed():Bool {
		if (!online.GameClient.isConnected())
			return true;

		return playOtherSide || online.GameClient.room.state.royalMode;
	}

	/** Number of opponents in the room. */
	function countOpponents():Int {
		if (!online.GameClient.isConnected() || playOtherSide || online.GameClient.room.state.royalMode)
			return 1;

		var count:Int = 0;
		for (sid => character in characters)
		{
			if (character != null && !character.isPlayer)
				count++;
		}
		return count;
	}

	/**
		 * The isPlayerNote() predicate, using this engine's mustPress convention (see the
	 * block header). Used by the "noteHit"/"noteMiss" listeners to find the note a remote player
	 * just drove.
	 */
	public static function isPlayerNote(note:Note):Bool {
		return note.mustPress;
	}

	/**
	 * Per-sid opponent note hit for a remote player. See the block header for
	 * why this wraps the engine's 1-parameter opponentNoteHit instead of extending it.
	 */
	function opponentNoteHitSID(note:Note, sid:String):Void {
		note.hits++;
		if (note.hits - countOpponents() > 0)
			return;

		var opChar:Character = characters.get(sid);

		var altAnim:String = note.animSuffix;
		var useGF:Bool = note.gfNote;
		var isHey:Bool = (note.noteType == 'Hey!');
		var doSing:Bool = !note.noAnimation && !isHey && opChar != null;
		var animToPlay:String = null;

		if (doSing)
		{
			if (playsAsBF() && SONG.notes[curSection] != null && SONG.notes[curSection].altAnim && !SONG.notes[curSection].gfSection)
				altAnim = '-alt';
			animToPlay = getSingAnim(note) + altAnim;
		}

		// The engine's opponent path also animates dad/boyfriend and switches the opponent vocals;
		// suppress only the animation so the remote character is the one that sings (the split happens
		// exactly at the opChar selection).
		var wasNoAnim:Bool = note.noAnimation;
		note.noAnimation = true;
		opponentNoteHit(note);
		note.noAnimation = wasNoAnim;

		if (isHey && opChar != null && opChar.animOffsets.exists('hey'))
		{
			opChar.playAnim('hey', true);
			opChar.specialAnim = true;
			opChar.heyTimer = 0.6;
		}
		else if (doSing)
		{
			var target:Character = (useGF && gf != null) ? gf : opChar;
			if (target != null)
			{
				target.playAnim(animToPlay, true);
				target.holdTimer = 0;
			}
		}

		if (SONG.needsVoices)
			getVocalsFromSIDVolume(sid, 1);
	}

	/**
		 * Room message registration, as described in the block header.
		 * Called once from create() while connected, and re-invoked
		 * through `GameClient.initStateListeners` after a reconnect.
	 */
	function registerMessages():Void {
		online.GameClient.initStateListeners(this, this.registerMessages);

		if (!online.GameClient.isConnected())
			return;

		// Players can join or leave mid-song, so listeners and characters must hang off the state-level
		// onAdd/onRemove rather than being installed once for the players present when the room was
		// created. onAdd's immediate flag defaults to true, so registration already fires once for
		// every player in the room; a for loop here would double the listeners.
		online.GameClient.registerStateDisposer(this, online.GameClient.callbacks.onAdd("players", (player, sid) -> {
			online.backend.Waiter.put(() -> {
				if (destroyed)
					return;
				listenPlayerSID(sid, player);
				syncOnlineCharacters();
			});
		}));

		online.GameClient.registerStateDisposer(this, online.GameClient.callbacks.onRemove("players", (player, sid) -> {
			online.backend.Waiter.put(() -> {
				if (destroyed)
					return;
				onlineListenedSIDs.remove(sid);
				syncOnlineCharacters();
				showBotplay();
			});
		}));

		syncOnlineCharacters();
		initOnlineHealthSync();

		online.GameClient.registerStateMessage(this, "custom", function(message:Array<Dynamic>) {
			if (message.length != 2)
				return;

			online.backend.Waiter.put(() -> {
				callOnScripts('onCustomMessage', message);
			});
		});

		online.GameClient.registerStateMessage(this, "log", function(message) {
			online.backend.Waiter.putPersist(() -> {
				online.gui.Alert.alert("New message", online.util.ShitUtil.parseLog(message).content);
			});
		});

		online.GameClient.registerStateMessage(this, "strumPlay", function(_message:Array<Dynamic>) {
			var sid:String = _message[0];
			var message:Array<Dynamic> = _message[1];

			online.backend.Waiter.put(() -> {
				if (message == null || message[0] == null || message[1] == null || message[2] == null)
					return;

				if (callOnScripts('onMessageStrumPlay', [sid, message], true) == FunkinLua.Function_Stop)
					return;

				var strums = getStrumsFromSID(sid);
				if (strums == getPlayerStrums())
					return;

				var spr:StrumNote = strums.members[Std.int(message[1])];
				if (spr != null)
				{
					spr.playAnim(message[0] + "", true);
					spr.resetAnim = message[2];
				}
			});
		});

		online.GameClient.registerStateMessage(this, "charPlay", function(_message:Array<Dynamic>) {
			var sid:String = _message[0];
			var message:Array<Dynamic> = _message[1];

			online.backend.Waiter.put(() -> {
				if (message == null || message[0] == null)
					return;

				if (callOnScripts('onMessageCharPlay', [sid, message], true) == FunkinLua.Function_Stop)
					return;

				var isGF:Bool = (message[1] == true);
				var special:Bool = (message[2] == true);
				if (isGF && gf != null)
				{
					gf.playAnim(message[0], true);
					if (special)
						gf.specialAnim = true;
				}
				else if (!isGF)
				{
					var char = characters.get(sid);
					if (char == null)
						return;

					char.playAnim(message[0], true);
					if (special)
						char.specialAnim = true;
				}
			});
		});

		online.GameClient.registerStateMessage(this, "noteHit", function(_message:Array<Dynamic>) {
			var sid:String = _message[0];
			var message:Array<Dynamic> = _message[1];

			online.backend.Waiter.put(() -> {
				if (message == null || message[0] == null || message[1] == null || message[2] == null)
					return;

				if (callOnScripts('onMessageNoteHit', [sid, message], true) == FunkinLua.Function_Stop)
					return;

				notes.forEachAlive(function(note:Note) {
					if (!isPlayerNote(note)
						&& note.noteData == message[1]
						&& note.isSustainNote == message[2]
						&& Math.abs(note.strumTime - (message[0] : Float)) < 1)
					{
						opponentNoteHitSID(note, sid);
					}
				});

				if (!(message[2] == true) && message[3] != null)
				{
					getPlayerStats(sid).combo++;
					popUpScoreOP(message[3], sid);
				}

				var isSelf:Bool = (message[6] == true);
				callOnLuas(isSelf ? 'goodNoteHit' : 'opponentNoteHit', [message[5], message[1], message[4], message[2], getCharPlayTag(isSelf, sid)]);
				callOnHScript(isSelf ? 'goodNoteHit' : 'opponentNoteHit', [notes.members[Std.int(message[5])], getCharPlayTag(isSelf, sid)]);

				updateScoreSID(sid, false);
				getVocalsFromSIDVolume(sid, 1);
			});
		});

		online.GameClient.registerStateMessage(this, "noteMiss", function(_message:Array<Dynamic>) {
			var sid:String = _message[0];
			var message:Array<Dynamic> = _message[1];

			online.backend.Waiter.put(() -> {
				if (message == null || message[0] == null || message[1] == null || message[2] == null)
					return;

				if (callOnScripts('onMessageNoteMiss', [sid, message], true) == FunkinLua.Function_Stop)
					return;

				// The remote sends a noteMiss for *every* sustain segment, and this used to recycle the local
				// counterpart, so an unplayed opponent sustain disappeared segment by segment. Unplayed opponent
				// notes must keep travelling past the judgement line, so the local visual note is no longer
				// destroyed here -- updateNote's "recycle only once off screen" branch handles it. Score / combo / vocals still settle normally.

				updateScoreSID(sid, true);
				getVocalsFromSIDVolume(sid, 0);
				getPlayerStats(sid).combo = 0;
			});
		});

		online.GameClient.registerStateMessage(this, "startSong", function(_) {
			online.backend.Waiter.put(() -> {
				if (callOnScripts('onMessageStartSong', null, true) == FunkinLua.Function_Stop)
					return;

				isReady = true;
				waitReady = false;
				startCountdown();
			});
		});

		online.GameClient.registerStateMessage(this, "endSong", function(_) {
			online.backend.Waiter.put(() -> {
				if (callOnScripts('onMessageEndSong', null, true) == FunkinLua.Function_Stop)
					return;

				canEndSongOnline = true;
				endSong();
			});
		});

		online.objects.ChatBox.tryRegisterLogs();
	}

	/** Installs the state-level schema listeners (ping / botplay / noteHold) for one sid. Idempotent. */
	function listenPlayerSID(sid:String, player:online.backend.schema.Player):Void {
		if (player == null || sid == null)
			return;
		if (onlineListenedSIDs.exists(sid))
			return;
		onlineListenedSIDs.set(sid, true);

		online.GameClient.registerStateDisposer(this, online.GameClient.callbacks.listen(player, "ping", (value, prev) -> {
			online.backend.Waiter.put(() -> {
				if (destroyed)
					return;
				if (callOnScripts('onPlayerPing', [sid, player.ping], true) == FunkinLua.Function_Stop)
					return;

				updateScoreSID(sid, true);
			});
		}));

		online.GameClient.registerStateDisposer(this, online.GameClient.callbacks.listen(player, "botplay", (value, prev) -> {
			online.backend.Waiter.put(() -> {
				if (destroyed)
					return;
				if (callOnScripts('onPlayerBotplay', [sid, value], true) == FunkinLua.Function_Stop)
					return;

				showBotplay();
			});
		}));

		online.GameClient.registerStateDisposer(this, online.GameClient.callbacks.listen(player, "noteHold", (value, prev) -> {
			online.backend.Waiter.put(() -> {
				if (destroyed)
					return;
				if (callOnScripts('onPlayerNoteHold', [sid, value], true) == FunkinLua.Function_Stop)
					return;

				if (characters.exists(sid))
					characters.get(sid).noteHold = value;
			});
		}));
	}

	/**
	 * Online never declares death -- the old `onlineDeathCheck()` is gone.
	 *
	 * It used to zero health into `isDead` + `boyfriend.stunned` + a `playerEnded` broadcast,
	 * but the online path never switches to GameOverSubstate, and `boyfriend.stunned` is the
	 * first gate on note input with no reset point, so one side failing would leave that side
	 * permanently unable to press keys while the screen kept running and no failure was shown.
	 * "Ending" is now driven only by the normal `endSong()` path (which still sends `playerEnded`).
	 */

	/*
	 * The two host members the outbound message send sites need.
	 */
	/**
	 * popUpScore() returns the judgement Rating so its caller can forward `rating.image` in
	 * "noteHit"; this engine's popUpScore() is a Void method whose signature cannot change outside a
	 * guard, so it stashes the image here and goodNoteHit() reads it back.
	 */
	public var onlineLastRatingImage:String = null;

	/** Is `character` this client's own player character? */
	public static function isCharacterPlayer(character:Character):Bool {
		if (instance == null)
			return character != null && character.isPlayer;

		return character == (playsAsBF() ? instance.boyfriend : instance.dad);
	}

	/**
	 * Online health is *room-shared* (the schema's Room.health; PlayState.get_health/set_health
	 * PlayState.get_health/set_health also proxy room.state.health while connected). This engine's
	 * health is a plain field (no get/set proxy), so it uses an equivalent report + adopt scheme:
	 *   1. on song start, initialise onlineSyncedHealth to the current local health;
	 *   2. listen to room.state.health -- the server value is authoritative and is adopted directly
	 *      (also updating onlineSyncedHealth so the next update() does not re-send it as a local change);
	 *   3. update() calls syncOnlineHealth() every frame, reporting the local health delta for the server to accumulate.
	 * Result: both clients see the same health value/progress instead of each its own.
	 *
	 * Deliberate difference: set_health is a no-op online (only the
	 * server-simulated value counts); with no server-side simulation here the delta comes from the real client's local judging -- equivalent in effect.
	 */
	function initOnlineHealthSync():Void {
		var room = online.GameClient.room;
		if (room == null || room.state == null)
			return;

		onlineSyncedHealth = health;
		onlineHealthReady = true;

		online.GameClient.registerStateDisposer(this, online.GameClient.callbacks.listen(room.state, "health", (value, prev) -> {
			online.backend.Waiter.put(() -> {
				if (destroyed || !onlineHealthReady)
					return;
				var v:Float = (value == null) ? 1 : (cast value);
				health = v;
				onlineSyncedHealth = v;
			});
		}));
	}

	function syncOnlineHealth():Void {
		if (!onlineHealthReady || !online.GameClient.isConnected())
			return;

		var delta:Float = health - onlineSyncedHealth;
		if (delta == 0)
			return;

		onlineSyncedHealth = health;
		online.GameClient.send("updateHealth", delta);
	}

	#end
	#end
}

#if ONLINE_ALLOWED
/**
 * Row model for the online score HUD. It wraps one online.backend.schema.Player (the
 * Colyseus room state object) and recomputes that player's rating from the *same*
 * PlayState.ratingStuff / ratingsData tables the local player uses, so a remote player's row
 * is scored exactly like the local one. Only the rating tier is recomputed here; nothing is
 * sent back to the server.
 *
 * Declared after PlayState and guarded, so the class disappears with the macro.
 */
@:publicFields
class PlayStatePlayer {
	public var player:online.backend.schema.Player;
	public var ratingPercent:Float = 0.;
	public var ratingName:String = '?';
	public var ratingFC:String = null;
	public var combo:Int = 0;

	function calcHits():Int {
		return player.sicks + player.goods + player.bads + player.shits;
	}

	// all the encountered notes
	function calcTotalPlayed():Int {
		return player.sicks + player.goods + player.bads + player.shits + player.misses;
	}

	function calcTotalNotesHit():Float {
		return 
			(player.sicks * PlayState.instance.ratingsData[0].ratingMod) + 
			(player.goods * PlayState.instance.ratingsData[1].ratingMod) + 
			(player.bads * PlayState.instance.ratingsData[2].ratingMod) +
			(player.shits * PlayState.instance.ratingsData[3].ratingMod)
		;
	}

	function recalculateRating():Void {
		var totalPlayed = calcTotalPlayed();
		var totalNotesHit = calcTotalNotesHit();
		var ratingStuff = PlayState.ratingStuff;

		if (totalPlayed != 0) // Prevent divide by 0
		{
			// Rating Percent
			ratingPercent = Math.min(1, Math.max(0, totalNotesHit / totalPlayed));

			// Rating Name
			ratingName = ratingStuff[ratingStuff.length - 1][0]; // Uses last string
			if (ratingPercent < 1)
				for (i in 0...ratingStuff.length - 1)
					if (ratingPercent < ratingStuff[i][1]) {
						ratingName = ratingStuff[i][0];
						break;
					}
		}

		ratingFC = 'Clear';
		if (player.misses < 1) {
			if (player.shits > 0) ratingFC = 'NM';
			if (player.bads > 0) ratingFC = 'FC';
			else if (player.goods > 0) ratingFC = 'GFC';
			else if (player.sicks > 0) ratingFC = 'SFC';
		}
		else if (player.misses < 10)
			ratingFC = 'SDCB';
	}

	function new(player:online.backend.schema.Player) {
		this.player = player;
	}
}
#end
