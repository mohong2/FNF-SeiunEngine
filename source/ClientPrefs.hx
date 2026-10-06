package;


import flixel.util.FlxSave;
import flixel.input.keyboard.FlxKey;
import flixel.graphics.FlxGraphic;
import Controls;
import flixel.input.gamepad.FlxGamepadInputID;
import mohong.TraceManager;
#if sys
import sys.io.Process;
#end

@:structInit class SaveVariables{
	public var arrowRGB:Array<Array<FlxColor>> = [
		[0xFFC24B99, 0xFFFFFFFF, 0xFF3C1F56],
		[0xFF00FFFF, 0xFFFFFFFF, 0xFF1542B7],
		[0xFF12FA05, 0xFFFFFFFF, 0xFF0A4447],
		[0xFFF9393F, 0xFFFFFFFF, 0xFF651038],
		// Multi-key: the last five entries are space/leftex1/downex1/upex1/rightex1,
		// one independent colour per lane rather than a mirror of the base colours
		[0xFFCCCCCC, 0xFFFFFFFF, 0xFF4C4C4C],
		[0xFFFFFF00, 0xFFFFFFFF, 0xFF4C4C00],
		[0xFF8B4AFF, 0xFFFFFFFF, 0xFF2B0066],
		[0xFFFF0000, 0xFFFFFFFF, 0xFF4C0000],
		[0xFF0033FF, 0xFFFFFFFF, 0xFF00004C]];
	public var arrowRGBPixel:Array<Array<FlxColor>> = [
		[0xFFE276FF, 0xFFFFF9FF, 0xFF60008D],
		[0xFF3DCAFF, 0xFFF4FFFF, 0xFF003060],
		[0xFF71E300, 0xFFF6FFE6, 0xFF003100],
		[0xFFFF884E, 0xFFFFFAF5, 0xFF6C0000],
		// Multi-key: one independent colour per lane
		[0xFFCCCCCC, 0xFFFFFFFF, 0xFF4C4C4C],
		[0xFFFFFF00, 0xFFFFFFFF, 0xFF4C4C00],
		[0xFF8B4AFF, 0xFFFFFFFF, 0xFF2B0066],
		[0xFFFF0000, 0xFFFFFFFF, 0xFF4C0000],
		[0xFF0033FF, 0xFFFFFFFF, 0xFF00004C]];
	public var noteSkin:String = 'Default';
	public var splashSkin:String = 'Psych';
	/** Note style: Old = 0.6.3 flat NOTE_assets, New = 0.7.3 noteSkins/NOTE_assets. Independent of the compatibility mode. */
	public var noteStyle:String = 'Old';
	/** Note RGB tint shader: Chart = follow the chart's disableNoteRGB (default), On = force on, Off = force off. */
	public var noteRGBMode:String = 'Chart';

	public var modSettings:Map<String, Map<String, Dynamic>> = new Map();

	public var keyboardAlpha:Float = 0.8;
	public var keyboardTimeDisplay:Bool = true;
	public var keyboardTime:Float = 500;
	public var keyboardBGColor:String = 'WHITE';
	public var keyboardTextColor:String = 'BLACK';
	public var keyboardDisplay:Bool = false;
	public var hitboxPos:Bool = true;
	public var hitboxType:String = "No Gradient";
	public var mobileCAlpha:Float = 0.6;
	public var mobileCEx:Bool = false;
	public var hitboxExtraToggle:Bool = true;
	public var hitboxExtraPos:String = "Bottom";
	/** Alpha of a pressed hitbox square (fully transparent while released). */
	public var hitboxPressAlpha:Float = 0.6;
	/** Draws borders between the hitbox squares to help locate the touch areas. */
	public var hitboxBorder:Bool = true;
	/** Desktop touch support: brings the Android controls (virtual pad / hitbox) to desktop, usable with mouse or touch. */
	public var touchControls:Bool = false;
	public var downScroll:Bool = false;
	public var middleScroll:Bool = false;
	public var opponentStrums:Bool = true;
	public var showFPS:Bool = true;
	public var flashing:Bool = true;
	public var globalAntialiasing:Bool = true;
	public var noteSplashes:Bool = true;
	public var lowQuality:Bool = false;
	public var shaders:Bool = true;
	public var framerate:Int = 60;
	public var drawFramerate:Int = 144;
	public var cursing:Bool = true;
	public var violence:Bool = true;
	public var camZooms:Bool = true;
	public var hideHud:Bool = false;
	public var noteOffset:Int = 0;
	// Multi-key: the first four entries are the 4K colour offsets; the last five are space/leftex1/downex1/upex1/rightex1
	public var arrowHSV:Array<Array<Int>> = [
		[0, 0, 0], [0, 0, 0], [0, 0, 0], [0, 0, 0],
		[0, 0, 0], [0, 0, 0], [0, 0, 0], [0, 0, 0], [0, 0, 0]
	];
	public var ghostTapping:Bool = true;
	public var timeBarType:String = 'Time Left';
	public var scoreZoom:Bool = true;
	public var noReset:Bool = false;
	public var healthBarAlpha:Float = 1;
	public var controllerMode:Bool = #if !android false #else true #end;
	public var hitsoundVolume:Float = 0;
	// Hit sound selection (list from data/hitsoundList.txt, extensible by mods)
	public var hitsound:String = "osu!mania";
	public var trackAlpha:Float = 0;
	public var pauseMusic:String = 'Tea Time';
	public var checkForUpdates:Bool = true;
	public var checkForPrereleases:Bool = false;
	public var comboStacking = false;
	public var language:String = "English";
	public var oldmodsmenu:Bool = false;
	public var sidehud:Bool = true;
	public var luattf:String = "Default TTF";
	public var doublebetbf:Bool = true;
	public var doublebetdad:Bool = true;
	public var opponentfe:Bool = true;
	public var currentFont:String = "vcr.ttf"; 
	public var windowedmode:String = "windowed";
	// Close animation: style (off/squeeze/zoom/drop/slide) plus speed multiplier
	public var closeAnimStyle:String = 'squeeze';
	public var closeAnimSpeed:Float = 1.0;
	/** Three-engine compatibility mode: Auto / 0.6.3 / 0.7.3 / 1.0.4 (see backend.CompatEngine). */
	public var compatEngine:String = 'Auto';
	/** Legacy 0.7.3 compatibility flag kept for save migration; new logic should use CompatEngine. */
	public var compatibility_mode:Bool = false; 
	public var guitarHeroSustains:Bool = false; 
	public var smoothhpbar:Bool = false; 
	public var unnotec:Bool = false;
	public var cacheOnGPU:Bool = true;
	public var preloadAssets:Bool = false;
	/** Performance master switch: when off, batch advancing / merged rebuilds / budget throttling fall back to the stock per-hit behaviour. */
	public var perfMode:Bool = false;
	/** Turbo master switch: forces botplay and enables dense merging plus data-level batch settlement. */
	public var turboMode:Bool = false;
	/** Performance option: batch skip chart notes that are already past. */
	public var bulkSkip:Bool = false;
	/** Performance option: sort only the visible living notes. */
	public var fastSort:Bool = false;
	//不不不，我个老牧师的怎么给他删了
	public var stockNoteSort:Bool = false;

	public var stockEventDrain:Bool = false;

	public var stockBpmStruct:Bool = false;

	public var stockHudTextRewrite:Bool = false;
	/** Performance option: maximum simultaneously materialised notes, 0 = unlimited (use with care). */
	public var limitNotes:Int = 0;
	/** Performance option: keep the note list of streamed (64 MB+) charts on disk and replay it on the next load. */
	public var chartCache:Bool = true;
	/** Performance option: deflate the cached note list (much smaller files, ~1s more on load). */
	public var chartCacheCompress:Bool = true;
	/** Placeholder state for the "clear chart cache" action button: the action never reads it. */
	public var clearChartCache:Bool = false;
	/** Performance option: disables the hxcpp GC during a song, trading memory for frame time (off by default, prevents leaks). */
	public var disableGC:Bool = false;
	/** Release CPU-side copies of large textures (>=2048px) only after confirming no live sprite/atlas/script references. */
	public var gfxCpuRelease:Bool = true;
	/** Store uploaded graphics in LRU cache upon song exit, with strict cache/atlas synchronization and reference-safe eviction. */
	public var gfxLruCache:Bool = true;
	/** Placeholder state for the "clear image cache" action button: a button option must bind a field, but the action never reads it. */
	public var clearImageCache:Bool = false;
	/** Bottom-right version/build watermark. Hidden automatically while a song is playing; it never takes input. */
	public var showWatermark:Bool = true;
	/** Placeholder state for the "show the note-optimisation notice again" action row: a button option must bind a field, but the action never reads it. */
	public var showNoteOptimizationNotice:Bool = false;
	public var scriptArgReuse:Bool = true;
	/** Trim transparent borders and repack large sheets at runtime on the main thread, with XML/dimension validation. */
	public var gfxRuntimeRepack:Bool = true;
	public var splashAlpha:Float = 0.6;
	public var autoPause:Bool = true;
	public var gameplaySettings:Map<String, Dynamic> = [
		'scrollspeed' => 1.0,
		'scrolltype' => 'multiplicative', 
		'songspeed' => 1.0,
		'healthgain' => 1.0,
		'healthloss' => 1.0,
		'instakill' => false,
		'practice' => false,
		'botplay' => false,
		'opponentplay' => false
	];
	public var comboOffset:Array<Int> = [0, 0, 0, 0, 530, 470, 520, 350];
	public var ratingOffset:Int = 0;
	public var sickWindow:Int = 45;
	public var goodWindow:Int = 90;
	public var badWindow:Int = 130;
	public var safeFrames:Float = 10;
	// Judgement windows (marvelous/sick/good/bad ms windows)
	public var judgementTimings:Array<Int> = [25, 50, 70, 100];
	public var judgementPreset:String = 'Leather Engine';
	public var marvelousRatings:Bool = true;
	public var marvelousWindow:Int = 25;
	/**
	 * Psych 的 0.6.3 / 0.7.3 / 1.0.4 都**没有** 'marvelous' 这一档判定, 模组按名字映射判定时
	 * 超完美命中不落任何一档(准确率被拉低、连击计数不涨)。开启后模组脚本读到的判定名按 1.0.4
	 * 的口径给出(≤25ms → 'sick'); 关闭后脚本读到原始判定名。
	 * 引擎自身的 HUD / 结算 / 计分 / hitsound / 在线始终使用真实判定, 不受此开关影响;
	 * 想拿原始判定名的脚本还可以读 `Note.ratingRaw` 或 PlayState 的 `marvelouses` 计数。
	 */
	public var judgementNameCompat:Bool = true;
	/** osu! tail judgement: judge sustain tails on release instead of on hold (affects scores and replays). */
	//public var osuTailJudgement:Bool = false;
	/** osu! tail window multiplier relative to a normal judgement window (1.0 = same, default 2.0). */
	//public var tailWindowMult:Float = 2.0;

	public var saveReplayData:Bool = true;
	public var lastNoteAnimation:Bool = false;

	//not 063 compatible
	public var debugEnabled:Bool = false;
	public var hscriptErrorHandling:Bool = true;
	public var newchartingstate:Bool = false;
	public var runInBackground:Bool = false;
	public var backgroundDim:Bool = false;
	public var autoExtractAssets:Bool = true;
	// Chart editor auto-save (off by default — player opts in)
	public var chartAutosave:Bool = false;
	/**
	 * How charts split across several files are loaded; the player picks this in Options > Advanced.
	 * Auto   -- the engine finds <song>-0.json, -1, ... and plays them as one song;
	 * Manifest -- only the parts listed in <song>.parts.json are merged;
	 * Off    -- every chart file is its own chart, the stock behavior.
	 * Kept as a String (not an enum) so an unknown value from an old/newer save degrades to Auto.
	 */
	public var segmentedCharts:String = 'Auto';

	// Trace Console debug settings
	public var traceConsoleEnabled:Bool = false;
	public var traceConsoleLevel:String = 'DEBUG';

	// Touch/Swipe gestures
	public var touchSwipeEnabled:Bool = true;

	// Separate Update/Draw mode
	public var separateUpdateDraw:Bool = false;

	// ─── Video rendering (FFmpeg pipe) ────────────────────────────────────
	// Preview mode: everything runs exactly as during a real render (fixed
	// timestep, per-frame capture) but no ffmpeg process is spawned and no
	// file is written. Used to rehearse a render and by the codec test.
	public var previewRender:Bool = false;
	// Encoder id; must be a key of backend.FFMpeg.CODECS.
	public var renderCodec:String = 'H.264 (x264)';
	// Rate control: CRF/CQP | VBR | CBR
	public var renderMode:String = 'CRF/CQP';
	// Quality for CRF/CQP (lower = better).
	public var renderQuality:Int = 18;
	// Target bitrate in Mbit/s for VBR/CBR.
	public var renderBitrate:Int = 12;
	// How many captured frames may be in flight before frames are dropped.
	// This is what bounds the recorder's memory:
	//   renderBufferFrames * width * height * 4 bytes.
	public var renderBufferFrames:Int = 60;
	// Framerate the render is captured and encoded at. The loop is pinned to it
	// while rendering and one captured frame is exactly 1/renderFps of song time,
	// so the video always lasts as long as the song no matter how fast the PC is.
	// Free choice: any rate from 15 to 480.
	public var renderFps:Int = 60;
	// Mix the song's Inst/Voices tracks into the rendered video.
	public var renderAudio:Bool = true;
	// Start recording automatically the moment a song starts, with no hotkey.
	public var renderOnSongStart:Bool = false;

	// Old pause menu style
	public var oldPauseMenu:Bool = false;

	// Seiun Engine menu effects (aurora glows, particles, beat-synced pulses)
	public var seiuMenuFx:Bool = true;

	// Freeplay: automatically play the selected song's music
	public var freeplayAutoPreview:Bool = false;

	// Android storage type (empty = auto-detect)
	public var storageType:String = "";

	// Warn once per cold start when the game's data is not on the public root directory
	// (/storage/emulated/0/.<game>). Turned off by the dialog's "Don't show again" action and
	// turned back on from Android Settings.
	public var showStorageRootWarning:Bool = true;

	// Lua / HScript error loop protection: ignore a script file after too many consecutive errors.
	public var ignoreErrorLoopScripts:Bool = true;
	public var scriptErrorLimit:Int = 50;
	#if ONLINE_ALLOWED
	// ─── Online support: save fields the online code needs ──────────────────
	// Field names, types and defaults required by the online code. Single-player code never reads these fields,
	// and the whole block is skipped when ONLINE_ALLOWED is undefined.
	/** Local nickname cache, read and written only through getNickname()/setNickname(). */
	private var nickname:String = "Boyfriend";
	/** Player-entered online server address (null = use GameClient.serverAddresses[0]). */
	public var serverAddress:String = null;
	/** Online skin as [character name, ?, ?, mod directory]; null = not chosen. */
	public var currentSkin:Array<String> = null;
	/** Whitelist of URLs this client may request. */
	public var trustedSources:Array<String> = ["https://gamebanana.com/"];
	/** Disables automatic mod downloads. */
	public var disableAutoDownloads:Bool = false;
	/** Hides Freeplay icons. */
	public var disableFreeplayIcons:Bool = false;
	/** Hides the Freeplay alphabet animation (faster rendering). */
	public var disableFreeplayAlphabet:Bool = false;
	/** Notify when a chat message arrives. */
	public var notifyOnChatMsg:Bool = false;
	/** Disables private message notifications. */
	public var disablePMs:Bool = false;
	/** Disables room invite notifications. */
	public var disableRoomInvites:Bool = false;
	/** Persisted user choice for HTTPS certificate verification. NOT applied at startup
		(see loadPrefs); the online options screen reads/writes sys.ssl.Socket.DEFAULT_VERIFY_CERT directly. */
	public var verifySSL:Bool = false;
	/** Player-entered network server address. */
	public var networkServerAddress:String = null;
	/** Notify when a friend comes online. */
	public var friendOnlineNotification:Bool = false;
	/** Show FP (Funkin Points) on the score HUD. Default false leaves the engine display unchanged. */
	public var showFP:Bool = false;
	/** Preview FP with the V5 (devFP) formula instead of a percentage. */
	public var newFPPreview:Bool = false;
	/** Online score HUD form: false = compact one-liner (default), true = multi-line. */
	public var onlineScoreDetails:Bool = false;
	/** Favourite skins, formatted 'charactername-originfolder'. */
	public var favSkins:Array<String> = []; //format: 'charactername-originfolder'
	/**
	 * In-client LAN hosting (OnlineState -> LanHostState). The first HTTP port the host tries;
	 * a busy port walks upward and the panel shows the ports really in use.
	 */
	public var lanHostPort:Int = 2567;
	/** Max players of the hosted room (1..64, the same clamp ServerConfig applies). */
	public var lanHostMaxClients:Int = 6;
	/** True = the hosted room is listed in FIND on the host's own server. Default off = code only. */
	public var lanHostPublic:Bool = false;
	/** True = several sessions from one IP may join (local testing on one PC). */
	public var lanHostAllowSamePc:Bool = false;
	/** Empty = <applicationStorageDirectory>/lanhost (a writable local volume). */
	public var lanHostDataDir:String = "";
	#end
}

class ClientPrefs {
	public static var data:SaveVariables = {};
	public static var defaultData:SaveVariables = {};
	public static var arrowRGB(get, never):Array<Array<FlxColor>>;
	public static var arrowRGBPixel(get, never):Array<Array<FlxColor>>;
	public static var noteSkin(get, never):String;
	public static var splashSkin(get, never):String;
	public static var noteStyle(get, never):String;
	public static var noteRGBMode(get, never):String;
	public static var modSettings(get, never):Map<String, Map<String, Dynamic>>;
	public static var keyboardAlpha(get, never):Float;
	public static var keyboardTimeDisplay(get, never):Bool;
	public static var keyboardTime(get, never):Float;
	public static var keyboardBGColor(get, never):String;
	public static var keyboardTextColor(get, never):String;
	public static var keyboardDisplay(get, never):Bool;
	public static var hitboxPos(get, never):Bool;
	public static var hitboxType(get, never):String;
	public static var mobileCAlpha(get, never):Float;
	public static var mobileCEx(get, never):Bool;
	public static var hitboxExtraToggle(get, never):Bool;
	public static var hitboxExtraPos(get, never):String;
	public static var hitboxPressAlpha(get, never):Float;
	public static var hitboxBorder(get, never):Bool;
	public static var touchControls(get, never):Bool;
	public static var downScroll(get, never):Bool;
	public static var middleScroll(get, never):Bool;
	public static var opponentStrums(get, never):Bool;
	public static var showFPS(get, never):Bool;
	public static var flashing(get, never):Bool;
	public static var globalAntialiasing(get, never):Bool;
	public static var noteSplashes(get, never):Bool;
	public static var lowQuality(get, never):Bool;
	public static var shaders(get, never):Bool;
	public static var framerate(get, never):Int;
	public static var drawFramerate(get, never):Int;
	public static var cursing(get, never):Bool;
	public static var violence(get, never):Bool;
	public static var camZooms(get, never):Bool;
	public static var hideHud(get, never):Bool;
	public static var noteOffset(get, never):Int;
	public static var arrowHSV(get, never):Array<Array<Int>>;
	public static var ghostTapping(get, never):Bool;
	public static var timeBarType(get, never):String;
	public static var scoreZoom(get, never):Bool;
	public static var noReset(get, never):Bool;
	public static var healthBarAlpha(get, never):Float;
	public static var controllerMode(get, never):Bool;
	public static var hitsoundVolume(get, never):Float;
	public static var hitsound(get, never):String;
	public static var trackAlpha(get, never):Float;
	public static var pauseMusic(get, never):String;
	public static var checkForUpdates(get, never):Bool;
	public static var checkForPrereleases(get, never):Bool;
	public static var comboStacking(get, never):Bool;
	public static var language(get, never):String;
	public static var oldmodsmenu(get, never):Bool;
	public static var sidehud(get, never):Bool;
	public static var luattf(get, never):String;
	public static var doublebetbf(get, never):Bool;
	public static var doublebetdad(get, never):Bool;
	public static var opponentfe(get, never):Bool;
	public static var currentFont(get, never):String;
	public static var windowedmode(get, never):String;
	public static var closeAnimStyle(get, never):String;
	public static var closeAnimSpeed(get, never):Float;
	public static var compatEngine(get, never):String;
	public static var compatibility_mode(get, never):Bool;
	public static var guitarHeroSustains(get, never):Bool;
	public static var smoothhpbar(get, never):Bool;
	public static var unnotec(get, never):Bool;
	public static var cacheOnGPU(get, never):Bool;
	public static var preloadAssets(get, never):Bool;
	public static var splashAlpha(get, never):Float;
	public static var autoPause(get, never):Bool;
	public static var runInBackground(get, never):Bool;
	public static var backgroundDim(get, never):Bool;
	public static var autoExtractAssets(get, never):Bool;
	public static var traceConsoleEnabled(get, never):Bool;
	public static var traceConsoleLevel(get, never):String;
	public static var gameplaySettings(get, never):Map<String, Dynamic>;
	public static var comboOffset(get, never):Array<Int>;
	public static var ratingOffset(get, never):Int;
	public static var sickWindow(get, never):Int;
	public static var goodWindow(get, never):Int;
	public static var badWindow(get, never):Int;
	public static var safeFrames(get, never):Float;
	public static var judgementTimings(get, never):Array<Int>;
	public static var judgementPreset(get, never):String;
	public static var marvelousRatings(get, never):Bool;
	public static var marvelousWindow(get, never):Int;
	public static var judgementNameCompat(get, never):Bool;
	//public static var osuTailJudgement(get, never):Bool;
	//public static var tailWindowMult(get, never):Float;
	public static var touchSwipeEnabled(get, never):Bool;
	public static var separateUpdateDraw(get, never):Bool;

	public static var ignoreErrorLoopScripts(get, never):Bool;
	public static var scriptErrorLimit(get, never):Int;

	/**
	 * The player's multi-file chart choice, read at chart-load time.
	 * Returns one of "Auto" / "Manifest" / "Off" and never dereferences null: a few load paths
	 * (and any tool that builds a Song outside the game) run before loadPrefs().
	 * The strings are spelled out instead of referencing ChartParts.MODE_* on purpose -- ChartParts
	 * is a sys-only module and ClientPrefs compiles for every target.
	 */
	public static function segmentedChartMode():String
	{
		if (data == null || data.segmentedCharts == null) return 'Auto';
		return data.segmentedCharts;
	}

	static inline function get_arrowRGB() return data.arrowRGB;
	static inline function get_arrowRGBPixel() return data.arrowRGBPixel;
	static inline function get_noteSkin() return data.noteSkin;
	static inline function get_splashSkin() return data.splashSkin;
	static inline function get_noteStyle() return data.noteStyle;
	static inline function get_noteRGBMode() return data.noteRGBMode;
	static inline function get_modSettings() return data.modSettings;
	static inline function get_keyboardAlpha() return data.keyboardAlpha;
	static inline function get_keyboardTimeDisplay() return data.keyboardTimeDisplay;
	static inline function get_keyboardTime() return data.keyboardTime;
	static inline function get_keyboardBGColor() return data.keyboardBGColor;
	static inline function get_keyboardTextColor() return data.keyboardTextColor;
	static inline function get_keyboardDisplay() return data.keyboardDisplay;
	static inline function get_hitboxPos() return data.hitboxPos;
	static inline function get_hitboxType() return data.hitboxType;
	static inline function get_mobileCAlpha() return data.mobileCAlpha;
	static inline function get_mobileCEx() return data.mobileCEx;
	static inline function get_hitboxExtraToggle() return data.hitboxExtraToggle;
	static inline function get_hitboxExtraPos() return data.hitboxExtraPos;
	static inline function get_hitboxPressAlpha() return data.hitboxPressAlpha;
	static inline function get_hitboxBorder() return data.hitboxBorder;
	static inline function get_touchControls() return data.touchControls;

	/** Whether the touch UI is used (always true on Android/iOS; on desktop it follows the touch support toggle). */
	public static function touchUIEnabled():Bool
	{
		#if TOUCH_CONTROLS
		return true;
		#else
		return data.touchControls;
		#end
	}

	static inline function get_downScroll() return data.downScroll;
	static inline function get_middleScroll() return data.middleScroll;
	static inline function get_opponentStrums() return data.opponentStrums;
	static inline function get_showFPS() return data.showFPS;
	static inline function get_flashing() return data.flashing;
	static inline function get_globalAntialiasing() return data.globalAntialiasing;
	static inline function get_noteSplashes() return data.noteSplashes;
	static inline function get_lowQuality() return data.lowQuality;
	static inline function get_shaders() return data.shaders;
	static inline function get_framerate() return data.framerate;
	static inline function get_drawFramerate() return data.drawFramerate;
	static inline function get_cursing() return data.cursing;
	static inline function get_violence() return data.violence;
	static inline function get_camZooms() return data.camZooms;
	static inline function get_hideHud() return data.hideHud;
	static inline function get_noteOffset() return data.noteOffset;
	static inline function get_arrowHSV() return data.arrowHSV;
	static inline function get_ghostTapping() return data.ghostTapping;
	static inline function get_timeBarType() return data.timeBarType;
	static inline function get_scoreZoom() return data.scoreZoom;
	static inline function get_noReset() return data.noReset;
	static inline function get_healthBarAlpha() return data.healthBarAlpha;
	static inline function get_controllerMode() return data.controllerMode;
	static inline function get_hitsoundVolume() return data.hitsoundVolume;
	static inline function get_hitsound() return data.hitsound;
	static inline function get_trackAlpha() return data.trackAlpha;
	static inline function get_pauseMusic() return data.pauseMusic;
	static inline function get_checkForUpdates() return data.checkForUpdates;
	static inline function get_checkForPrereleases() return data.checkForPrereleases;
	static inline function get_comboStacking() return data.comboStacking;
	static inline function get_language() return data.language;
	static inline function get_oldmodsmenu() return data.oldmodsmenu;
	static inline function get_sidehud() return data.sidehud;
	static inline function get_luattf() return data.luattf;
	static inline function get_doublebetbf() return data.doublebetbf;
	static inline function get_doublebetdad() return data.doublebetdad;
	static inline function get_opponentfe() return data.opponentfe;
	static inline function get_currentFont() return data.currentFont;
	static inline function get_windowedmode() return data.windowedmode;
	static inline function get_closeAnimStyle() return data.closeAnimStyle;
	static inline function get_closeAnimSpeed() return data.closeAnimSpeed;
	static inline function get_compatEngine() return data.compatEngine;
	static inline function get_compatibility_mode() return data.compatibility_mode;
	static inline function get_guitarHeroSustains() return data.guitarHeroSustains;
	static inline function get_smoothhpbar() return data.smoothhpbar;
	static inline function get_unnotec() return data.unnotec;
		static inline function get_cacheOnGPU() return data.cacheOnGPU;
	static inline function get_preloadAssets() return data.preloadAssets;
	static inline function get_splashAlpha() return data.splashAlpha;
	static inline function get_autoPause() return data.autoPause;
	static inline function get_runInBackground() return data.runInBackground;
	static inline function get_backgroundDim() return data.backgroundDim;
	static inline function get_autoExtractAssets() return data.autoExtractAssets;
	static inline function get_traceConsoleEnabled() return data.traceConsoleEnabled;
	static inline function get_traceConsoleLevel() return data.traceConsoleLevel;
	static inline function get_gameplaySettings() return data.gameplaySettings;
	static inline function get_comboOffset() return data.comboOffset;
	static inline function get_ratingOffset() return data.ratingOffset;
	static inline function get_sickWindow() return data.sickWindow;
	static inline function get_goodWindow() return data.goodWindow;
	static inline function get_badWindow() return data.badWindow;
	static inline function get_safeFrames() return data.safeFrames;
	static inline function get_judgementTimings() return data.judgementTimings;
	static inline function get_judgementPreset() return data.judgementPreset;
	static inline function get_marvelousRatings() return data.marvelousRatings;
	static inline function get_judgementNameCompat() return data.judgementNameCompat;
	static inline function get_marvelousWindow() return data.marvelousWindow;
	//static inline function get_osuTailJudgement() return data.osuTailJudgement;
	//static inline function get_tailWindowMult() return data.tailWindowMult;
	static inline function get_touchSwipeEnabled() return data.touchSwipeEnabled;
	static inline function get_separateUpdateDraw() return data.separateUpdateDraw;

	static inline function get_ignoreErrorLoopScripts() return data.ignoreErrorLoopScripts;
	static inline function get_scriptErrorLimit() return data.scriptErrorLimit;

	/**
	 * Whether the save file has been loaded from disk (set once loadPrefs finishes).
 * Until then data/keyBinds are still factory defaults and saveSettings() refuses to write,
 * so an early save (e.g. Android SUtil.getStorageDirectory) cannot overwrite the player's
 * saved controls_v3 with defaults -- the cause of keys resetting on every Android cold start.
	 */
	public static var prefsLoaded:Bool = false;

	public static var keyBinds:Map<String, Array<FlxKey>> = [
		//Key Bind, Name for ControlsSubState
		'note_left'		=> [A, LEFT],
		'note_down'		=> [S, DOWN],
		'note_up'		=> [W, UP],
		'note_right'	=> [D, RIGHT],

		// Extra-key bindings
		'note_one1'		=> [SPACE, NONE],

		'note_two1'		=> [D, NONE],
		'note_two2'		=> [K, NONE],

		'note_three1'	=> [D, NONE],
		'note_three2'	=> [SPACE, NONE],
		'note_three3'	=> [K, NONE],

		'note_five1'	=> [D, NONE],
		'note_five2'	=> [F, NONE],
		'note_five3'	=> [SPACE, NONE],
		'note_five4'	=> [J, NONE],
		'note_five5'	=> [K, NONE],

		'note_six1'		=> [S, NONE],
		'note_six2'		=> [D, NONE],
		'note_six3'		=> [F, NONE],
		'note_six4'		=> [J, NONE],
		'note_six5'		=> [K, NONE],
		'note_six6'		=> [L, NONE],

		'note_seven1'	=> [S, NONE],
		'note_seven2'	=> [D, NONE],
		'note_seven3'	=> [F, NONE],
		'note_seven4'	=> [SPACE, NONE],
		'note_seven5'	=> [J, NONE],
		'note_seven6'	=> [K, NONE],
		'note_seven7'	=> [L, NONE],

		'note_eight1'	=> [A, NONE],
		'note_eight2'	=> [S, NONE],
		'note_eight3'	=> [D, NONE],
		'note_eight4'	=> [F, NONE],
		'note_eight5'	=> [H, NONE],
		'note_eight6'	=> [J, NONE],
		'note_eight7'	=> [K, NONE],
		'note_eight8'	=> [L, NONE],

		'note_nine1'	=> [A, NONE],
		'note_nine2'	=> [S, NONE],
		'note_nine3'	=> [D, NONE],
		'note_nine4'	=> [F, NONE],
		'note_nine5'	=> [SPACE, NONE],
		'note_nine6'	=> [H, NONE],
		'note_nine7'	=> [J, NONE],
		'note_nine8'	=> [K, NONE],
		'note_nine9'	=> [L, NONE],

		'note_ten1'		=> [A, NONE],
		'note_ten2'		=> [S, NONE],
		'note_ten3'		=> [D, NONE],
		'note_ten4'		=> [F, NONE],
		'note_ten5'		=> [G, NONE],
		'note_ten6'		=> [SPACE, NONE],
		'note_ten7'		=> [H, NONE],
		'note_ten8'		=> [J, NONE],
		'note_ten9'		=> [K, NONE],
		'note_ten10'	=> [L, NONE],

		'note_elev1'	=> [A, NONE],
		'note_elev2'	=> [S, NONE],
		'note_elev3'	=> [D, NONE],
		'note_elev4'	=> [F, NONE],
		'note_elev5'	=> [G, NONE],
		'note_elev6'	=> [SPACE, NONE],
		'note_elev7'	=> [H, NONE],
		'note_elev8'	=> [J, NONE],
		'note_elev9'	=> [K, NONE],
		'note_elev10'	=> [L, NONE],
		'note_elev11'	=> [PERIOD, NONE],

		'note_twel1'	=> [A, NONE],
		'note_twel2'	=> [S, NONE],
		'note_twel3'	=> [D, NONE],
		'note_twel4'	=> [F, NONE],
		'note_twel5'	=> [C, NONE],
		'note_twel6'	=> [V, NONE],
		'note_twel7'	=> [N, NONE],
		'note_twel8'	=> [M, NONE],
		'note_twel9'	=> [H, NONE],
		'note_twel10'	=> [J, NONE],
		'note_twel11'	=> [K, NONE],
		'note_twel12'	=> [L, NONE],

		'note_thir1'	=> [A, NONE],
		'note_thir2'	=> [S, NONE],
		'note_thir3'	=> [D, NONE],
		'note_thir4'	=> [F, NONE],
		'note_thir5'	=> [C, NONE],
		'note_thir6'	=> [V, NONE],
		'note_thir7'	=> [SPACE, NONE],
		'note_thir8'	=> [N, NONE],
		'note_thir9'	=> [M, NONE],
		'note_thir10'	=> [H, NONE],
		'note_thir11'	=> [J, NONE],
		'note_thir12'	=> [K, NONE],
		'note_thir13'	=> [L, NONE],

		'note_fourt1'	=> [A, NONE],
		'note_fourt2'	=> [S, NONE],
		'note_fourt3'	=> [D, NONE],
		'note_fourt4'	=> [F, NONE],
		'note_fourt5'	=> [C, NONE],
		'note_fourt6'	=> [V, NONE],
		'note_fourt7'	=> [G, NONE],
		'note_fourt8'	=> [Y, NONE],
		'note_fourt9'	=> [N, NONE],
		'note_fourt10'	=> [M, NONE],
		'note_fourt11'	=> [H, NONE],
		'note_fourt12'	=> [J, NONE],
		'note_fourt13'	=> [K, NONE],
		'note_fourt14'	=> [L, NONE],

		'note_151'	=> [A, NONE],
		'note_152'	=> [S, NONE],
		'note_153'	=> [D, NONE],
		'note_154'	=> [F, NONE],
		'note_155'	=> [C, NONE],
		'note_156'	=> [V, NONE],
		'note_157'	=> [T, NONE],
		'note_158'	=> [Y, NONE],
		'note_159'	=> [U, NONE],
		'note_1510'	=> [N, NONE],
		'note_1511'	=> [M, NONE],
		'note_1512'	=> [H, NONE],
		'note_1513'	=> [J, NONE],
		'note_1514'	=> [K, NONE],
		'note_1515'	=> [L, NONE],

		'note_161'	=> [A, NONE],
		'note_162'	=> [S, NONE],
		'note_163'	=> [D, NONE],
		'note_164'	=> [F, NONE],
		'note_165'	=> [Q, NONE],
		'note_166'	=> [W, NONE],
		'note_167'	=> [E, NONE],
		'note_168'	=> [R, NONE],
		'note_169'	=> [Y, NONE],
		'note_1610'	=> [U, NONE],
		'note_1611'	=> [I, NONE],
		'note_1612'	=> [O, NONE],
		'note_1613'	=> [H, NONE],
		'note_1614'	=> [J, NONE],
		'note_1615'	=> [K, NONE],
		'note_1616'	=> [L, NONE],

		'note_171'	=> [A, NONE],
		'note_172'	=> [S, NONE],
		'note_173'	=> [D, NONE],
		'note_174'	=> [F, NONE],
		'note_175'	=> [Q, NONE],
		'note_176'	=> [W, NONE],
		'note_177'	=> [E, NONE],
		'note_178'	=> [R, NONE],
		'note_179'	=> [SPACE, NONE],
		'note_1710'	=> [Y, NONE],
		'note_1711'	=> [U, NONE],
		'note_1712'	=> [I, NONE],
		'note_1713'	=> [O, NONE],
		'note_1714'	=> [H, NONE],
		'note_1715'	=> [J, NONE],
		'note_1716'	=> [K, NONE],
		'note_1717'	=> [L, NONE],

		'note_181'	=> [A, NONE],
		'note_182'	=> [S, NONE],
		'note_183'	=> [D, NONE],
		'note_184'	=> [F, NONE],
		'note_185'	=> [SPACE, NONE],
		'note_186'	=> [H, NONE],
		'note_187'	=> [J, NONE],
		'note_188'	=> [K, NONE],
		'note_189'	=> [L, NONE],
		'note_1810'	=> [Q, NONE],
		'note_1811'	=> [W, NONE],
		'note_1812'	=> [E, NONE],
		'note_1813'	=> [R, NONE],
		'note_1814'	=> [T, NONE],
		'note_1815'	=> [Y, NONE],
		'note_1816'	=> [U, NONE],
		'note_1817'	=> [I, NONE],
		'note_1818'	=> [O, NONE],
		
		'ui_left'		=> [A, LEFT],
		'ui_down'		=> [S, DOWN],
		'ui_up'			=> [W, UP],
		'ui_right'		=> [D, RIGHT],
		
		'accept'		=> [SPACE, ENTER],
		'back'			=> [BACKSPACE, ESCAPE],
		'pause'			=> [ENTER, ESCAPE],
		'reset'			=> [R, NONE],
		#if ONLINE_ALLOWED
		// Sidebar toggle, default ` (GRAVEACCENT).
		// A single key only: copyKey()/checkKey() iterate the array and do not require two entries.
		'sidebar'		=> [GRAVEACCENT],
		// taunt / fav (used by the online lobby and skin selection).
		'taunt'			=> [SPACE, T],
		'fav'			=> [Q],
		#end
		
		'volume_mute'	=> [ZERO, NONE],
		'volume_up'		=> [NUMPADPLUS, PLUS],
		'volume_down'	=> [NUMPADMINUS, MINUS],
		
		'debug_1'		=> [SEVEN, NONE],
		'debug_2'		=> [EIGHT, NONE]
	];
	public static var defaultKeys:Map<String, Array<FlxKey>> = null;

	public static var gamepadBinds:Map<String, Array<FlxGamepadInputID>> = [
		'note_up'		=> [DPAD_UP, Y],
		'note_left'		=> [DPAD_LEFT, X],
		'note_down'		=> [DPAD_DOWN, A],
		'note_right'	=> [DPAD_RIGHT, B],
		
		'ui_up'			=> [DPAD_UP, LEFT_STICK_DIGITAL_UP],
		'ui_left'		=> [DPAD_LEFT, LEFT_STICK_DIGITAL_LEFT],
		'ui_down'		=> [DPAD_DOWN, LEFT_STICK_DIGITAL_DOWN],
		'ui_right'		=> [DPAD_RIGHT, LEFT_STICK_DIGITAL_RIGHT],
		
		'accept'		=> [A, START],
		'back'			=> [B],
		'pause'			=> [START],
		#if ONLINE_ALLOWED
		'reset'			=> [BACK],
		// Online action gamepad defaults (same guard as the keyboard branch).
		'taunt'			=> [RIGHT_STICK_CLICK],
		'sidebar'		=> [],
		'fav'			=> [Y]
		#end
	];
	public static var defaultButtons:Map<String, Array<FlxGamepadInputID>> = null;

	public static function resetKeys(controller:Null<Bool> = null) //Null = both, False = Keyboard, True = Controller
	{
		if(controller != true)
			for (key in keyBinds.keys())
				if(defaultKeys.exists(key))
					keyBinds.set(key, defaultKeys.get(key).copy());

		#if !android // gamepad bindings cannot be reset on Android
		if(controller != false)
			for (button in gamepadBinds.keys())
				if(defaultButtons.exists(button))
					gamepadBinds.set(button, defaultButtons.get(button).copy());
		#end
	}

	public static function clearInvalidKeys(key:String)
	{
		var keyBind:Array<FlxKey> = keyBinds.get(key);
		#if !android
		var gamepadBind:Array<FlxGamepadInputID> = gamepadBinds.get(key);
		while(gamepadBind != null && gamepadBind.contains(NONE)) gamepadBind.remove(NONE);
		#end
		while(keyBind != null && keyBind.contains(NONE)) keyBind.remove(NONE);
	}

	public static function loadDefaultKeys()
	{
		defaultKeys = keyBinds.copy();
		#if !android
		defaultButtons = gamepadBinds.copy();
		#end
	}

	// Snapshot of the data last written to disk. Every return from the settings menu or popup
	// calls saveSettings(), and a sync flush is a visible frame drop on mobile; if nothing
	// changed the disk writes are skipped entirely.
	static var _lastDataSnapshot:String = null;
	static var _lastKeyBindsSnapshot:String = null;

	public static function saveSettings()
	{
		// Early-startup guard: writing before loadPrefs would store default data/keyBinds and
		// overwrite the player's settings (typically controls_v3, on every Android boot).
		if (!prefsLoaded)
		{
			FlxG.log.warn("ClientPrefs.saveSettings() called before loadPrefs() - ignored to protect saved data");
			return;
		}

		for (key in Reflect.fields(data))
			Reflect.setField(FlxG.save.data, key, Reflect.field(data, key));

		// MusicBeatState writes fullscreen into FlxG.save.data every frame, so the snapshot must include it
		var dataSnapshot:String = Std.string(FlxG.save.data) + '|' + (FlxG.fullscreen ? '1' : '0');
		if (dataSnapshot != _lastDataSnapshot)
		{
			FlxG.save.flush();
			_lastDataSnapshot = dataSnapshot;
		}

		// Placing this in a separate save so that it can be manually deleted without removing your Score and stuff
		// Key binds only change on rebind/reset; when unchanged the whole serialise + write is skipped.
		var bindsSnapshot:String = keyBinds.toString()
			+ (#if !android gamepadBinds.toString() #else '' #end);
		if (bindsSnapshot != _lastKeyBindsSnapshot)
		{
			var save:FlxSave = new FlxSave();
			save.bind('controls_v3', 'ninjamuffin99');
			save.data.keyboard = keyBinds;
			#if !android
			save.data.gamepad = gamepadBinds;
			#end
			save.flush();
			_lastKeyBindsSnapshot = bindsSnapshot;
		}
		FlxG.log.add("Settings saved!");
	}


	/**
	 * Bind the save file and load preferences exactly once per process.
	 *
	 * Every boot state (CopyState then TitleState) needs ClientPrefs, and the storage root
	 * must be resolved *after* prefs are in memory: resolving it before loadPrefs() uses the
	 * version-aware default, and a later re-resolve left Sys.getCwd() pointing at a
	 * different directory than SUtil.getStorageDirectory().
	 */
	public static function ensureLoaded():Void
	{
		if (prefsLoaded) return;
		FlxG.save.bind('funkin', 'ninjamuffin99');
		loadPrefs();
	}

	public static function loadPrefs() {
		if (data == null) data = {};
		if (defaultData == null) defaultData = {};

		for (key in Reflect.fields(data))
			if (key != 'gameplaySettings' && Reflect.hasField(FlxG.save.data, key))
				Reflect.setField(data, key, Reflect.field(FlxG.save.data, key));

		// Corrupted/older saves can set collections to null. Never let those
		// propagate: every gameplay code path assumes these maps/arrays exist.
		if (data.gameplaySettings == null)
		{
			data.gameplaySettings = new Map<String, Dynamic>();
			if (defaultData != null && defaultData.gameplaySettings != null)
				for (k => v in defaultData.gameplaySettings)
					data.gameplaySettings.set(k, v);
		}
		if (data.modSettings == null)
			data.modSettings = new Map<String, Map<String, Dynamic>>();

		backend.Scripts.reuseEnabled = data.scriptArgReuse;//何意味
		// Multi-key: old saves only have four arrowHSV entries; pad to nine (one per A~I lane)
		// so the NotesSubState carousel and in-game colour lookups cannot go out of bounds.
		if (data.arrowHSV == null || data.arrowHSV.length < 9)
		{
			var padded:Array<Array<Int>> = [];
			if (data.arrowHSV != null) for (hsv in data.arrowHSV) padded.push(hsv != null ? hsv : [0, 0, 0]);
			while (padded.length < 9) padded.push([0, 0, 0]);
			data.arrowHSV = padded;
		}

		// Multi-key: old saves only have four arrowRGB entries; pad to nine (same layout as arrowHSV:
		// space mirrors up, leftex1=left, downex1=down, upex1=up, rightex1=right)
		if (data.arrowRGB == null || data.arrowRGB.length < 9)
		{
			var paddedRGB:Array<Array<FlxColor>> = [];
			if (data.arrowRGB != null) for (rgb in data.arrowRGB) paddedRGB.push(rgb != null ? rgb : [0, 0, 0]);
			while (paddedRGB.length < 4) paddedRGB.push(defaultData.arrowRGB[paddedRGB.length]);
			while (paddedRGB.length < 9) paddedRGB.push(defaultData.arrowRGB[paddedRGB.length]);
			data.arrowRGB = paddedRGB;
		}
		if (data.arrowRGBPixel == null || data.arrowRGBPixel.length < 9)
		{
			var paddedRGB:Array<Array<FlxColor>> = [];
			if (data.arrowRGBPixel != null) for (rgb in data.arrowRGBPixel) paddedRGB.push(rgb != null ? rgb : [0, 0, 0]);
			while (paddedRGB.length < 4) paddedRGB.push(defaultData.arrowRGBPixel[paddedRGB.length]);
			while (paddedRGB.length < 9) paddedRGB.push(defaultData.arrowRGBPixel[paddedRGB.length]);
			data.arrowRGBPixel = paddedRGB;
		}

		// Judgement-feel migration: old saves have no judgementTimings, so initialise from the
		// stock Psych windows (marvelous 25ms; sick/good/bad reuse the player's saved values -> custom preset)
		if (!Reflect.hasField(FlxG.save.data, 'judgementTimings'))
		{
			if (Reflect.hasField(FlxG.save.data, 'sickWindow') || Reflect.hasField(FlxG.save.data, 'goodWindow') || Reflect.hasField(FlxG.save.data, 'badWindow'))
			{
				// Existing player: keep the saved Psych windows and mark the judgement type custom
				data.judgementTimings = [25, data.sickWindow, data.goodWindow, data.badWindow];
				data.judgementPreset = 'Custom';
			}
			else
			{
				// New player: use the Leather Engine preset
				data.judgementTimings = [25, 50, 70, 100];
				data.judgementPreset = 'Leather Engine';
			}
			data.marvelousWindow = data.judgementTimings[0];
		}
		else if (data.judgementTimings == null || data.judgementTimings.length != 4)
		{
			data.judgementTimings = [25, data.sickWindow, data.goodWindow, data.badWindow];
			data.judgementPreset = 'Custom';
			data.marvelousWindow = data.judgementTimings[0];
		}
		else
		{
			data.marvelousWindow = data.judgementTimings[0];
			// Older versions have judgementTimings but no judgementPreset: match a preset by the window values
			if (!Reflect.hasField(FlxG.save.data, 'judgementPreset'))
			{
				var t:Array<Int> = data.judgementTimings;
				if (t[0] == 25 && t[1] == 50 && t[2] == 70 && t[3] == 100)
					data.judgementPreset = 'Leather Engine';
				else if (t[0] == 23 && t[1] == 45 && t[2] == 90 && t[3] == 135)
					data.judgementPreset = 'Psych Engine / Kade Engine';
				else if (t[0] == 16 && t[1] == 33 && t[2] == 124 && t[3] == 149)
					data.judgementPreset = 'Friday Night Funkin\'';
				else
					data.judgementPreset = 'Custom';
			}
		}

		// osu! tail window multiplier migration: missing/invalid old saves use the 2.0 default
		//if (Math.isNaN(data.tailWindowMult) || data.tailWindowMult <= 0 || data.tailWindowMult > 8)
		//	data.tailWindowMult = 2.0;

		if (Main.fpsVar != null) {
			Main.fpsVar.visible = data.showFPS && !Main.useOldFPS;
			Main.oldFpsVar.visible = data.showFPS && Main.useOldFPS;
		}

		#if (!html5 && !switch)
		FlxG.autoPause = ClientPrefs.data.runInBackground ? false : ClientPrefs.data.autoPause;

		if (FlxG.save.data.framerate == null) {
			#if mobile
			data.framerate = 60;
			data.drawFramerate = 60;
			#else
			final refreshRate:Int = FlxG.stage.application.window.displayMode.refreshRate;
			data.framerate = Std.int(FlxMath.bound(refreshRate, 60, 240));
			data.drawFramerate = data.framerate;
			#end
		}
		#end

		if (data.separateUpdateDraw) {
			FlxG.updateFramerate = data.framerate;
			FlxG.drawFramerate = data.drawFramerate;
		} else {
			if (data.framerate > FlxG.drawFramerate) {
				FlxG.updateFramerate = data.framerate;
				FlxG.drawFramerate = data.framerate;
			} else {
				FlxG.drawFramerate = data.framerate;
				FlxG.updateFramerate = data.framerate;
			}
		}

		// Apply separate update/draw mode (the property setter keeps FlxGame in sync).
		// Idle render ticks in that mode reuse the recorded draw commands; mirror the mode that
		// is actually in effect rather than the preference, so a direct change of
		// FlxGame.separateUpdateDraw cannot leave the flag behind.
		if (FlxG.game != null)
		{
			FlxG.game.separateUpdateDraw = data.separateUpdateDraw;
			FlxG.separateDrawSkipIdleFrames = FlxG.game.separateUpdateDraw;
		}

		// Ensure draw wrapper is null (threaded rendering removed)
		if (FlxG.game != null)
			FlxG.game.drawWrapper = null;
		#if ONLINE_ALLOWED
		// The vanilla assignment
		//   `sys.ssl.Socket.DEFAULT_VERIFY_CERT = data.verifySSL;`
		// is deliberately NOT done here. `data.verifySSL` defaults to **false** (and every existing
		// save file already stores false), while `sys.ssl.Socket.DEFAULT_VERIFY_CERT` defaults to
		// true and is a process-wide switch. Applying the saved pref at startup would therefore
		// silently disable TLS certificate verification for *every* HTTPS connection this engine
		// makes (update checks, GitHub / GameBanana / Drive downloads, ...) on the next launch, and
		// would turn the currently-safe default into an insecure one. That is an engine-wide
		// security decision, so it stays off until it is explicitly made.
		// Contract this file guarantees and OnlineOptionsState relies on: `data.verifySSL` only
		// records the user's explicit choice; the live switch is read/written directly by the online
		// options screen and is never restored from the save file.
		// Re-adding the restore is these 3 lines.
		#end

		// only tunes observation intensity; visuals stay with lowQuality.

		if (FlxG.save.data.gameplaySettings != null) {
			var savedMap:Map<String, Dynamic> = FlxG.save.data.gameplaySettings;
			for (name => value in savedMap)
				data.gameplaySettings.set(name, value);
		}

		// flixel automatically saves your volume!
		if (FlxG.save.data.volume != null)
			FlxG.sound.volume = FlxG.save.data.volume;
		if (FlxG.save.data.mute != null)
			FlxG.sound.muted = FlxG.save.data.mute;

		#if DISCORD_ALLOWED
		DiscordClient.check();
		#end
		var save:FlxSave = new FlxSave();
		save.bind('controls_v3', 'ninjamuffin99');
		if(save != null)
		{
			if(save.data.keyboard != null)
			{
				var loadedControls:Map<String, Array<FlxKey>> = save.data.keyboard;
				for (control => keys in loadedControls)
					if(keyBinds.exists(control)) keyBinds.set(control, keys);
			}
			#if !android
			if(save.data.gamepad != null)
			{
				var loadedControls:Map<String, Array<FlxGamepadInputID>> = save.data.gamepad;
				for (control => keys in loadedControls)
					if(gamepadBinds.exists(control)) gamepadBinds.set(control, keys);
			}
			#end
		}
		else
		{
			// Migrate from old controls_v2 save format
			var oldSave:FlxSave = new FlxSave();
			oldSave.bind('controls_v2', 'ninjamuffin99');
			if(oldSave != null && oldSave.data.customControls != null)
			{
				var loadedControls:Map<String, Array<FlxKey>> = oldSave.data.customControls;
				for (control => keys in loadedControls)
					if(keyBinds.exists(control)) keyBinds.set(control, keys);
			}
			oldSave = null;
		}

		// Ensure volume keys are properly initialised
		if(keyBinds.get('volume_mute') == null) keyBinds.set('volume_mute', [ZERO, NONE]);
		if(keyBinds.get('volume_up') == null) keyBinds.set('volume_up', [NUMPADPLUS, PLUS]);
		if(keyBinds.get('volume_down') == null) keyBinds.set('volume_down', [NUMPADMINUS, MINUS]);
		#if !android
		if(gamepadBinds.get('volume_mute') == null) gamepadBinds.set('volume_mute', [NONE]);
		if(gamepadBinds.get('volume_up') == null) gamepadBinds.set('volume_up', [NONE]);
		if(gamepadBinds.get('volume_down') == null) gamepadBinds.set('volume_down', [NONE]);
		#end

		// Sync the loaded key binds into the controls system; otherwise PlayerSettings keeps using the defaults
		reloadControls();
		reloadVolumeKeys();

		// Save file loaded; saveSettings() may write from here on
		prefsLoaded = true;
	}

	/**
	 * Whether the note RGB tint shader ends up disabled: combines the player's noteRGBMode with the chart's disableNoteRGB.
 * Chart (default) = follow the chart; On = force on (ignoring the chart); Off = force off (white textures keep their colour).
	 */
	public static function noteRGBDisabled(chartDisabled:Bool):Bool
	{
		return switch (data.noteRGBMode)
		{
			case 'On': false;
			case 'Off': true;
			default: chartDisabled;
		}
	}

	inline public static function getGameplaySetting(name:String, defaultValue:Dynamic = null, ?customDefaultValue:Bool = false):Dynamic {
		if (!customDefaultValue)
		{
			if (defaultData != null && defaultData.gameplaySettings != null)
				defaultValue = defaultData.gameplaySettings.get(name);
		}
		if (data == null || data.gameplaySettings == null)
			return defaultValue;
		return (data.gameplaySettings.exists(name) ? data.gameplaySettings.get(name) : defaultValue);
	}


	public static function reloadControls() {
		// player1 is null until PlayerSettings.init() runs. loadPrefs() (which ends here) can be
		// reached from the boot state before any state has created the players, so establish
		// them rather than dereferencing null.
		if (PlayerSettings.player1 == null)
			PlayerSettings.init();

		PlayerSettings.player1.controls.setKeyboardScheme(KeyboardScheme.Solo);

		TitleState.muteKeys = copyKey(keyBinds.get('volume_mute'));
		TitleState.volumeDownKeys = copyKey(keyBinds.get('volume_down'));
		TitleState.volumeUpKeys = copyKey(keyBinds.get('volume_up'));
		FlxG.sound.muteKeys = TitleState.muteKeys;
		FlxG.sound.volumeDownKeys = TitleState.volumeDownKeys;
		FlxG.sound.volumeUpKeys = TitleState.volumeUpKeys;
	}
	public static function reloadVolumeKeys()
	{
		TitleState.muteKeys = copyKey(keyBinds.get('volume_mute'));
		TitleState.volumeDownKeys = copyKey(keyBinds.get('volume_down'));
		TitleState.volumeUpKeys = copyKey(keyBinds.get('volume_up'));
		toggleVolumeKeys(true);
	}
	public static function toggleVolumeKeys(?turnOn:Bool = true)
	{
		final emptyArray = [];
		FlxG.sound.muteKeys = turnOn ? TitleState.muteKeys : emptyArray;
		FlxG.sound.volumeDownKeys = turnOn ? TitleState.volumeDownKeys : emptyArray;
		FlxG.sound.volumeUpKeys = turnOn ? TitleState.volumeUpKeys : emptyArray;
	}

	
	public static function copyKey(arrayToCopy:Array<FlxKey>):Array<FlxKey> {

		if (arrayToCopy == null) {
			TraceManager.warn('trace.clientPrefs.copyKeyNull', 'copyKey called with null array (missing keybind?)');
			return [];
		}
		var copiedArray:Array<FlxKey> = arrayToCopy.copy();
		var i:Int = 0;
		var len:Int = copiedArray.length;

		while (i < len) {
			if(copiedArray[i] == NONE) {
				copiedArray.remove(NONE);
				--i;
			}
			i++;
			len = copiedArray.length;
		}
		return copiedArray;
	}
	#if ONLINE_ALLOWED
	// ─── Online support: static members the online code needs ───────────────
	// Methods required by the online code. Where an implementation needs an API this engine
	// does not have, a minimal equivalent is used (see the method comments).
	public static function isDebug():Bool
	{
		#if debug
		return true;
		#end

		if (PlayState.chartingMode)
			return true;

		// The equivalent field here is
		// `data.debugEnabled` (same type and default, this file L176).
		// Haxe 4.2.5 has no null-coalescing operator, so `data?.debugMode ?? false` is expanded.
		return data != null ? data.debugEnabled : false;
	}

	/**
	 * Current nickname.
	 */
	public static function getNickname():String
	{
		if (online.network.FunkinNetwork.loggedIn)
			return online.network.FunkinNetwork.nickname;

		@:privateAccess
		return data.nickname;
	}

	/**
	 * Writes the nickname; an empty string falls back to "Boyfriend".
	 */
	public static function setNickname(name:String):String
	{
		if (online.network.FunkinNetwork.loggedIn)
			return online.network.FunkinNetwork.updateName(name);

		if (name == "")
			return @:privateAccess data.nickname = "Boyfriend";

		return @:privateAccess data.nickname = name;
	}

	/**
	 * Note skin of the given player (online.backend.NoteSkinData and GameClient.getOptions()
	 * both read it). Only the single-player semantics exist here: it returns the local note skin.
	 * The `player` parameter is kept for signature compatibility (-1 = force the local setting).
	 */
	#if ONLINE_ALLOWED
	public static function getNoteSkin(?player:Int = 0):String
	{
		return data != null ? data.noteSkin : 'Default';
	}
	#end

	/**
	 * Packs the player palette into a "full" map covering every key count.
	 *
	 * The engine has no per-mania `arrowRGBMap` / `arrowRGBPixelMap`, only the 9-slot palettes
	 * `data.arrowRGB` / `data.arrowRGBPixel` indexed by lane letter; multi-key colours are
	 * derived at render/tint time by `Note.initializeGlobalRGBShader()` / `StrumNote.hx`
	 * through `EKData.letterColorIndex.get(EKData.getLetter(mania, lane))`. The same rule
	 * generates the map for 1k..18k (`EKData.ammo`), matching the lane colours the engine
	 * actually displays without hard-coding any colour.
	 * The '4k' entry is therefore derived too (the 4 entries engine 4K really uses,
	 * `arrowRGB[0..3]`) instead of the whole `data.arrowRGB`, to match the engine's
	 * palette semantics.
	 */
	public static function getArrowRGBCompleteMaps():Array<Map<String, Array<Array<FlxColor>>>>
	{
		function buildPalette(palette:Array<Array<FlxColor>>, mania:Int):Array<Array<FlxColor>>
		{
			var arr:Array<Array<FlxColor>> = [];
			if (palette == null || palette.length == 0)
				return arr;

			var arrLen:Int = palette.length;
			for (lane in 0...EKData.ammo[mania])
			{
				var colorIdx:Int = lane % arrLen;
				var mapped:Null<Int> = EKData.letterColorIndex.get(EKData.getLetter(mania, lane));
				if (mapped != null && mapped >= 0 && mapped < arrLen)
					colorIdx = mapped;
				arr.push(palette[colorIdx]);
			}
			return arr;
		}

		var rgbMap:Map<String, Array<Array<FlxColor>>> = new Map();
		var rgbPixelMap:Map<String, Array<Array<FlxColor>>> = new Map();
		for (mania in 0...EKData.ammo.length)
		{
			var key:String = EKData.ammo[mania] + 'k';
			rgbMap.set(key, buildPalette(data.arrowRGB, mania));
			rgbPixelMap.set(key, buildPalette(data.arrowRGBPixel, mania));
		}
		return [rgbMap, rgbPixelMap];
	}
	#end
}
