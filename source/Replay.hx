package;

import openfl.events.KeyboardEvent;
import flixel.input.keyboard.FlxKey;
import flixel.input.FlxInput;
import flixel.FlxBasic;
import flixel.FlxG;
import haxe.Json;
import StringTools;
import states.PlayState;
import Conductor;
import CoolUtil;
import ClientPrefs;
import Paths;
#if sys
import sys.io.File;
import sys.FileSystem;
#end

typedef NoteJudgment = {
	var strumTime:Float;
	var noteData:Int;
	var hitDiff:Float;
	var rating:String;
	var isSustain:Bool;
}

typedef FrameSave = {
	var time:Float;
	var songSpeed:Float;
	var playbackRate:Float;
	var pressKey:Array<String>;
	var releaseKey:Array<String>;
	@:optional var noteJudgments:Array<NoteJudgment>;
}

typedef StateRecord = {
	var songName:String;
	var difficulty:Int;
	var playDate:String;
	var songLength:Float;
	var songSpeed:Float;
	var playbackRate:Float;
	var healthGain:Float;
	var healthLoss:Float;
	var cpuControlled:Bool;
	var practiceMode:Bool;
	var instakillOnMiss:Bool;
	var songScore:Int;
	var ratingPercent:Float;
	var ratingFC:String;
	var songHits:Int;
	var highestCombo:Int;
	var songMisses:Int;
	var sicks:Int;
	var goods:Int;
	var bads:Int;
	var shits:Int;
	var noteTime:Array<Float>;
	var noteMs:Array<Float>;
	var songSpeedType:String;
	var sickWindow:Int;
	var goodWindow:Int;
	var badWindow:Int;
	var safeFrames:Float;
	/** Judgement windows recorded with the replay (marvelous/sick/good/bad ms). */
	@:optional var judgementTimings:Array<Int>;
	/** Judgement preset name recorded with the replay (preset name or "Custom"). */
	@:optional var judgementPreset:String;
	@:optional var marvelousRatings:Bool;
	@:optional var marvelousWindow:Int;
	/** osu! tail judgement: whether it was enabled while recording, plus the tail window (ms). */
	//@:optional var osuTailJudgement:Bool;
	/** osu! tail window multiplier relative to a normal judgement window (default 2.0). */
	//@:optional var tailWindowMult:Float;
	/** Online replay marker: this replay was recorded in an online match. */
	@:optional var isOnline:Bool;
	/** Online replay: room code / room name / mode (realtime/async). */
	@:optional var roomCode:String;
	@:optional var roomName:String;
	@:optional var onlineMode:String;
	/** Judgement feel recorded with the replay: rating offset / whether sustains are judged as single notes. */
	@:optional var ratingOffset:Int;
	@:optional var guitarHeroSustains:Bool;
	var replayVersion:Int;
	/** Multi-key: key count while recording (mania+1, used to validate the replay). */
	@:optional var mania:Int;
}

class Replay extends FlxBasic
{
	/** Temporary debug log (for replay load/playback issues; can be removed once diagnosed). */
	public static function dbgLog(msg:String):Void
	{
		#if sys
		try
		{
			var path:String = 'replay_debug.log';
			var old:String = sys.FileSystem.exists(path) ? sys.io.File.getContent(path) : '';
			sys.io.File.saveContent(path, old + msg + '\n');
		}
		catch (e:Dynamic) {}
		#end
	}

	/**
	 * Monotonic input-event counter.
	 *
	 * Why: Replay.update() used to ask FlxG.keys.justPressed.ANY / justReleased.ANY every frame.
	 * FlxKey.fromStringMap holds 95 keys, so each ANY getter walks the 93 entries of
	 * FlxKeyManager._keyListArray and probes every one of them (see FlxBaseKeyList.get_ANY).
	 * Two getters per frame = 186 probes to learn "nothing happened" (measured 1547 ns/frame on a
	 * desktop hxcpp build, see _seiun-perf-work/callback-perf/inputtick). This counter is bumped by
	 * the keyboard listeners attached while recording (below) and by the Android controls / focus
	 * changes, so the same question is answered in O(1) (measured 0.9 ns/frame).
	 *
	 * Semantics: the keyboard listeners observe exactly the same events that move FlxG.keys, and the
	 * focus hooks cover FlxKeyManager.reset() (which releases every key without a KEY_UP event), so
	 * "tick changed" is equivalent to "some key state may have changed" for the recording pipeline.
	 */
	public static var inputTick:Int = 0;

	/** Bumps inputTick. Cheap enough to call from every key event; see inputTick. */
	public static inline function notifyInput():Void
	{
		inputTick++;
	}

	/** Frame data (written while recording, read during playback). */
	private var frameData:Array<FrameSave> = [];

	/** Whether recording is in progress. */
	public var isRecording:Bool = true;

	/** inputTick seen by the previous update() (see Replay.inputTick). */
	private var _lastInputTick:Int = 0;

	/** True while this instance owns the two stage keyboard listeners. */
	private var _listening:Bool = false;

	/** Path of the replay file currently loaded. */
	public static var preparedPath:String;

	/** Keys currently held (maintained during playback). */
	private var keysHeld:Map<FlxKey, Bool> = new Map<FlxKey, Bool>();

	/** FlxKey -> lane index map. */
	private var keyToLane:Map<FlxKey, Int> = null;

	/** All FlxKey values (iterated directly while recording; key names are resolved only on press/release). */
	private static var cachedKeyList:Array<FlxKey> = null;

	// ---- simulated key state during playback (backs the script keyJustPressed/keyPressed/keyJustReleased queries) ----
	private var simPressed:Map<String, Bool> = new Map<String, Bool>();
	private var simJustPressed:Map<String, Bool> = new Map<String, Bool>();
	private var simJustReleased:Map<String, Bool> = new Map<String, Bool>();
	private var simKnownKeys:Map<String, Bool> = new Map<String, Bool>();

	/** Lane count (4K = 4). */
	private var laneCount:Int = 0;

	/** Scratch arrays (avoid GC). */
	private var tmpPressLanes:Array<Int> = [];
	private var tmpReleaseLanes:Array<Int> = [];
	private var tmpHeldLanes:Array<Bool> = [];

	/** Empty event array used to pump sustain/idle logic every frame (avoid per-frame GC). */
	private var tmpEmptyPress:Array<Int> = [];
	private var tmpEmptyRelease:Array<Int> = [];

	// ---- high-precision judgement replay ----
	public var hasJudgments(default, null):Bool = false;
	private var judgmentMap:Map<String, NoteJudgment> = new Map<String, NoteJudgment>();
	public var replayVersion(default, null):Int = 1;

	// ---- judgement feel restored during replay ----
	/** True when the windows restored by the replay differ from the player's current settings. */
	public var judgementRestoredDifferent:Bool = false;
	/** Description of the judgement windows the replay actually used, e.g. "25/50/70/100 (Marvelous)". */
	public var judgementRestoreInfo:String = '';

	// ---- replay state ----
	private var globalTick:Int = 0;
	private var lastFrameCount:Int = 0;
	/** Current replay frame time (used for note-hit checks). */
	public var replayTime:Float = 0;
	private var lastReplayTimeForResync:Float = Math.NaN;

	private var lastSongSpeed:Float = 1;
	private var lastPlaybackRate:Float = 1;

	// ---- pending judgements (accumulated across frames while recording) ----
	private var pendingJudgments:Array<NoteJudgment> = [];

	// songSpeed / playbackRate of the last written frame -- sample an extra frame only on speed changes
	private var lastRecordedSongSpeed:Float = 1;
	private var lastRecordedPlaybackRate:Float = 1;

	public function new()
	{
		super();
	}

	/** Starts recording (clears previous data). */
	public function startRecording():Void
	{
		isRecording = true;
		frameData = [];
		keysHeld = new Map<FlxKey, Bool>();
		pendingJudgments = [];
		resetSimState();
		lastRecordedSongSpeed = PlayState.instance != null ? PlayState.instance.songSpeed : 1;
		lastRecordedPlaybackRate = PlayState.instance != null ? PlayState.instance.playbackRate : 1;
		lastFrameCount = 0;
		replayVersion = 1;
		replayTime = 0;
		lastReplayTimeForResync = Math.NaN;
		// Start from the current tick: the first update() must not see a stale value and scan.
		_lastInputTick = Replay.inputTick;
		ensureInputListener();
	}

	/** Stops recording. */
	public function stopRecording():Void
	{
		isRecording = false;
		removeInputListener();
	}

	// ---- keyboard change detection (see Replay.inputTick) ----
	// Attached only while recording, so playback and the menus never add a stage listener. The
	// handler does nothing but bump a counter: the actual key names are still resolved by
	// captureFrame()'s scan, so the recorded frames stay byte-identical to the old implementation.

	private function ensureInputListener():Void
	{
		if (_listening || FlxG.stage == null) return;
		try
		{
			FlxG.stage.addEventListener(KeyboardEvent.KEY_DOWN, onAnyKeyEvent);
			FlxG.stage.addEventListener(KeyboardEvent.KEY_UP, onAnyKeyEvent);
			_listening = true;
		}
		catch (e:Dynamic) { _listening = false; }
	}

	private function removeInputListener():Void
	{
		if (!_listening) return;
		_listening = false;
		try
		{
			if (FlxG.stage != null)
			{
				FlxG.stage.removeEventListener(KeyboardEvent.KEY_DOWN, onAnyKeyEvent);
				FlxG.stage.removeEventListener(KeyboardEvent.KEY_UP, onAnyKeyEvent);
			}
		}
		catch (e:Dynamic) {}
	}

	private function onAnyKeyEvent(event:KeyboardEvent):Void
	{
		Replay.inputTick++;
	}

	/** Loads a replay from an external frame array plus a state record. */
	public function loadFromData(frames:Array<FrameSave>, ?stateRecord:StateRecord):Void
	{
		isRecording = false;
		frameData = normalizeFrames(frames);
		resetSimState();
		buildJudgmentMap();
		if (stateRecord != null) restoreState(stateRecord);
		ensureLaneMap();
	}

	/** Loads a replay from a file (lenient: BOM, stray bytes, alternate frame field names, incomplete frames). */
	public function loadFromFile(path:String):Void
	{
		#if sys
		Replay.dbgLog('[DEBUG-rpl] loadFromFile path=$path');
		isRecording = false;
		resetSimState();
		if (path == null || !FileSystem.exists(path))
		{
			Replay.dbgLog('[DEBUG-rpl] loadFromFile: file missing');
			CoolUtil.traceMsg('trace.errReplayLoad', 'Replay file not found: {}', [path]);
			frameData = [];
			return;
		}
		try
		{
			var json:Dynamic = parseReplayJson(File.getContent(path));
			if (json == null)
			{
				Replay.dbgLog('[DEBUG-rpl] loadFromFile: JSON unparseable');
				CoolUtil.traceMsg('trace.errReplayLoad', 'Failed to load replay: {}', ['invalid JSON']);
				frameData = [];
				return;
			}
			frameData = extractFrames(json);
			Replay.dbgLog('[DEBUG-rpl] loadFromFile parsed, frameData=' + frameData.length);
			if (json.stateRecord != null) restoreState(json.stateRecord);
			buildJudgmentMap();
			ensureLaneMap();
			lastFrameCount = 0;
			globalTick = 0;
			lastReplayTimeForResync = Math.NaN;
			Replay.dbgLog('[DEBUG-rpl] loadFromFile OK');
		}
		catch (e:Dynamic)
		{
			Replay.dbgLog('[DEBUG-rpl] loadFromFile EXCEPTION: ' + Std.string(e));
			CoolUtil.traceMsg('trace.errReplayLoad', 'Failed to load replay: {}', [e]);
			frameData = [];
		}
		#end
	}

	/** Clears the simulated key state (on replay load / recording start). */
	private function resetSimState():Void
	{
		simPressed.clear();
		simJustPressed.clear();
		simJustReleased.clear();
		simKnownKeys.clear();
	}

	// ======================== replay key simulation (script API) ========================

	/** Replay: whether the key appears in the recording (decides if script queries use the simulated state). */
	public function keyExists(keyName:String):Bool
	{
		return simKnownKeys.exists(normalizeKeyName(keyName));
	}

	/** Replay: whether the key went down this frame (matches Script keyJustPressed('space') etc.). */
	public function keyJustPressed(keyName:String):Bool
	{
		return simJustPressed.get(normalizeKeyName(keyName)) == true;
	}

	/** Replay: whether the key is currently held. */
	public function keyPressed(keyName:String):Bool
	{
		return simPressed.get(normalizeKeyName(keyName)) == true;
	}

	/** Replay: whether the key was released this frame. */
	public function keyJustReleased(keyName:String):Bool
	{
		return simJustReleased.get(normalizeKeyName(keyName)) == true;
	}

	static inline function normalizeKeyName(keyName:String):String
	{
		if (keyName == null) return '';
		return keyName.toUpperCase();
	}

	/** Builds the judgement map (for exact replay). */
	private function buildJudgmentMap():Void
	{
		judgmentMap.clear();
		hasJudgments = false;
		for (frame in frameData)
		{
			if (frame == null || frame.noteJudgments == null) continue;
			for (j in frame.noteJudgments)
			{
				var key:String = '${j.strumTime}_${j.noteData}';
				if (!judgmentMap.exists(key)) judgmentMap.set(key, j);
			}
			hasJudgments = true;
		}
	}

	/** Recorded judgement of the given note, when present. */
	public function getRecordedJudgment(strumTime:Float, noteData:Int):NoteJudgment
	{
		return judgmentMap.get('${strumTime}_${noteData}');
	}

	/** Restores game settings from a StateRecord. */
	private function restoreState(stateRecord:Dynamic):Void
	{
		var ps = PlayState.instance;
		if (ps == null) return;

		// Remember the judgement feel before restoring, so a mismatch can be reported
		var prevSick:Int = ClientPrefs.data.sickWindow;
		var prevGood:Int = ClientPrefs.data.goodWindow;
		var prevBad:Int = ClientPrefs.data.badWindow;
		var prevMarv:Int = ClientPrefs.data.marvelousWindow;
		var prevMarvOn:Bool = ClientPrefs.data.marvelousRatings;
		//var prevTailOn:Bool = ClientPrefs.data.osuTailJudgement;
		//var prevTailMult:Float = ClientPrefs.data.tailWindowMult;
		var prevRatingOffset:Int = ClientPrefs.data.ratingOffset;
		var prevGuitarHero:Bool = ClientPrefs.data.guitarHeroSustains;

		// Numeric/boolean fields go through lenient conversion (strings/missing/wrong types; replays from any version load)
		if (stateRecord.songSpeed != null) ps.songSpeed = toFloat(stateRecord.songSpeed, ps.songSpeed);
		if (stateRecord.playbackRate != null) ps.playbackRate = toFloat(stateRecord.playbackRate, ps.playbackRate);
		if (stateRecord.healthGain != null) ps.healthGain = toFloat(stateRecord.healthGain, ps.healthGain);
		if (stateRecord.healthLoss != null) ps.healthLoss = toFloat(stateRecord.healthLoss, ps.healthLoss);
		if (stateRecord.instakillOnMiss != null) ps.instakillOnMiss = toBool(stateRecord.instakillOnMiss);
		if (stateRecord.cpuControlled != null) ps.cpuControlled = toBool(stateRecord.cpuControlled);
		if (stateRecord.practiceMode != null) ps.practiceMode = toBool(stateRecord.practiceMode);
		if (stateRecord.songSpeedType != null) ps.songSpeedType = Std.string(stateRecord.songSpeedType);
		if (stateRecord.sickWindow != null) ClientPrefs.data.sickWindow = Std.int(toFloat(stateRecord.sickWindow, ClientPrefs.data.sickWindow));
		if (stateRecord.goodWindow != null) ClientPrefs.data.goodWindow = Std.int(toFloat(stateRecord.goodWindow, ClientPrefs.data.goodWindow));
		if (stateRecord.badWindow != null) ClientPrefs.data.badWindow = Std.int(toFloat(stateRecord.badWindow, ClientPrefs.data.badWindow));
		if (stateRecord.safeFrames != null) ClientPrefs.data.safeFrames = toFloat(stateRecord.safeFrames, ClientPrefs.data.safeFrames);
		// Restore the recorded judgement windows so the replay scores exactly as it did live.
		// Only a well-formed numeric array is accepted; anything else leaves the player's settings alone.
		if (stateRecord.judgementTimings != null && Std.isOfType(stateRecord.judgementTimings, Array))
		{
			var rawTimings:Array<Dynamic> = cast stateRecord.judgementTimings;
			var timings:Array<Int> = [];
			for (v in rawTimings)
			{
				var t:Float = toFloat(v, -1);
				if (t >= 0) timings.push(Std.int(t));
			}
			if (timings.length >= 4)
			{
				ClientPrefs.data.judgementTimings = timings;
				backend.Ratings.syncWindows();
			}
		}
		if (stateRecord.judgementPreset != null && Std.string(stateRecord.judgementPreset).length > 0)
			ClientPrefs.data.judgementPreset = Std.string(stateRecord.judgementPreset);
		else if (stateRecord.judgementTimings != null && Std.isOfType(stateRecord.judgementTimings, Array))
			ClientPrefs.data.judgementPreset = backend.Ratings.presetNameForTimings(ClientPrefs.data.judgementTimings);
		if (stateRecord.marvelousRatings != null) ClientPrefs.data.marvelousRatings = toBool(stateRecord.marvelousRatings);
		if (stateRecord.marvelousWindow != null) ClientPrefs.data.marvelousWindow = Std.int(toFloat(stateRecord.marvelousWindow, ClientPrefs.data.marvelousWindow));
		// osu! tail judgement: force-restored from the recording so tail scores are reproducible
		//if (stateRecord.osuTailJudgement != null)
		//	ClientPrefs.data.osuTailJudgement = toBool(stateRecord.osuTailJudgement);
		//else
			// Older replays have no tail field: treat it as off, matching how it was recorded
		//	ClientPrefs.data.osuTailJudgement = false;
		// Tail window multiplier: restore the recorded value (invalid values fall back to 2.0)
		//if (stateRecord.tailWindowMult != null)
		//{
		//	var mult:Float = toFloat(stateRecord.tailWindowMult, 2.0);
		//	if (!Math.isNaN(mult) && mult > 0 && mult <= 8)
		//		ClientPrefs.data.tailWindowMult = mult;
		//	else
		//		ClientPrefs.data.tailWindowMult = 2.0;
		//}
		//else
		//	ClientPrefs.data.tailWindowMult = 2.0;
		// Remaining judgement feel: rating offset / sustain-as-single-note (not force-restored before)
		if (stateRecord.ratingOffset != null) ClientPrefs.data.ratingOffset = Std.int(toFloat(stateRecord.ratingOffset, ClientPrefs.data.ratingOffset));
		if (stateRecord.guitarHeroSustains != null)
		{
			ClientPrefs.data.guitarHeroSustains = toBool(stateRecord.guitarHeroSustains);
			if (ps != null) ps.guitarHeroSustains = ClientPrefs.data.guitarHeroSustains;
		}
		if (stateRecord.replayVersion != null) replayVersion = Std.int(toFloat(stateRecord.replayVersion, 1));

		// Judgement-feel change detection: only report when the replay windows differ from the current settings
		judgementRestoredDifferent =
			(prevSick != ClientPrefs.data.sickWindow
			|| prevGood != ClientPrefs.data.goodWindow
			|| prevBad != ClientPrefs.data.badWindow
			|| prevMarv != ClientPrefs.data.marvelousWindow
			|| prevMarvOn != ClientPrefs.data.marvelousRatings
			//|| prevTailOn != ClientPrefs.data.osuTailJudgement
			//|| prevTailMult != ClientPrefs.data.tailWindowMult
			|| prevRatingOffset != ClientPrefs.data.ratingOffset
			|| prevGuitarHero != ClientPrefs.data.guitarHeroSustains);

		if (judgementRestoredDifferent)
		{
			var t:Array<Int> = ClientPrefs.data.judgementTimings;
			if (t != null && t.length >= 4)
				judgementRestoreInfo =
					ClientPrefs.data.judgementPreset + " (" + Std.string(t[0]) + "/" + Std.string(t[1]) + "/" + Std.string(t[2]) + "/" + Std.string(t[3]) + ")"
					+ (ClientPrefs.data.marvelousRatings ? " (Marvelous)" : "");
			else
				// Missing / invalid window data: report only the preset name to avoid an out-of-bounds read
				judgementRestoreInfo = ClientPrefs.data.judgementPreset + " (unknown windows)"
					+ (ClientPrefs.data.marvelousRatings ? " (Marvelous)" : "");
			// Restore info for tail judgement / rating offset / sustain-as-single-note (list only the ones set)
			var extra:Array<String> = [];
			//if (prevTailOn != ClientPrefs.data.osuTailJudgement)
			//	extra.push("osu! Tail: " + (ClientPrefs.data.osuTailJudgement ? "ON" : "OFF"));
			//if (prevTailMult != ClientPrefs.data.tailWindowMult)
			//	extra.push("Tail Window: " + Std.string(ClientPrefs.data.tailWindowMult) + "x");
			if (prevRatingOffset != ClientPrefs.data.ratingOffset)
				extra.push("Rating Offset: " + Std.string(ClientPrefs.data.ratingOffset) + "ms");
			if (prevGuitarHero != ClientPrefs.data.guitarHeroSustains)
				extra.push("Sustains as One Note: " + (ClientPrefs.data.guitarHeroSustains ? "ON" : "OFF"));
			if (extra.length > 0)
				judgementRestoreInfo += "\n" + extra.join("\n");
			// Replay windows differ from the player's settings -> mark the judgement type custom
			ClientPrefs.data.judgementPreset = backend.Ratings.presetNameForTimings(ClientPrefs.data.judgementTimings);
		}
		else
			judgementRestoreInfo = '';
		// Multi-key: warn when the replay key count does not match the chart (lane mapping would shift)
		if (stateRecord.mania != null)
		{
			var replayMania:Int = Std.int(toFloat(stateRecord.mania, -1));
			if (replayMania >= 0 && replayMania != PlayState.mania)
				FlxG.log.warn('Replay was recorded on ${replayMania + 1}K but current chart is ${PlayState.mania + 1}K');
		}

		lastSongSpeed = ps.songSpeed;
		lastPlaybackRate = ps.playbackRate;
	}

	/** Current StateRecord. */
	public function getStateRecord():StateRecord
	{
		var ps = PlayState.instance;
		if (ps == null) return null;

		return {
			songName: Paths.formatToSongPath(PlayState.SONG != null ? PlayState.SONG.song : ''),
			difficulty: PlayState.storyDifficulty,
			playDate: Date.now().toString(),
			songLength: ps.songLength,
			songSpeed: ps.songSpeed,
			playbackRate: ps.playbackRate,
			healthGain: ps.healthGain,
			healthLoss: ps.healthLoss,
			cpuControlled: ps.cpuControlled,
			practiceMode: ps.practiceMode,
			instakillOnMiss: ps.instakillOnMiss,
			songScore: ps.songScore,
			ratingPercent: ps.ratingPercent,
			ratingFC: ps.ratingFC,
			songHits: ps.songHits,
			highestCombo: ps.maxcombo,
			songMisses: ps.songMisses,
			sicks: ps.sicks,
			goods: ps.goods,
			bads: ps.bads,
			shits: ps.shits,
			noteTime: ps.NoteTime,
			noteMs: ps.NoteMs,
			songSpeedType: ps.songSpeedType,
			sickWindow: ClientPrefs.data.sickWindow,
			goodWindow: ClientPrefs.data.goodWindow,
			badWindow: ClientPrefs.data.badWindow,
			safeFrames: ClientPrefs.data.safeFrames,
			judgementTimings: ClientPrefs.data.judgementTimings != null ? ClientPrefs.data.judgementTimings.copy() : null,
			judgementPreset: ClientPrefs.data.judgementPreset,
			marvelousRatings: ClientPrefs.data.marvelousRatings,
			marvelousWindow: ClientPrefs.data.marvelousWindow,
			//osuTailJudgement: ClientPrefs.data.osuTailJudgement,
			//tailWindowMult: ClientPrefs.data.tailWindowMult,
			ratingOffset: ClientPrefs.data.ratingOffset,
			guitarHeroSustains: ClientPrefs.data.guitarHeroSustains,
			replayVersion: ClientPrefs.data.saveReplayData ? 2 : 1,
			mania: PlayState.mania
		};
	}

	override public function destroy():Void
	{
		removeInputListener();
		super.destroy();
	}

	// ======================== recording ========================

	/** Per-frame update: detects key changes and records frames. */
	override public function update(elapsed:Float):Void
	{
		super.update(elapsed);
		if (!isRecording || PlayState.instance == null) return;

		// With replay saving off the recording is never consumed (Allscore only reads frames when saveReplayData is set),
		// so skip the whole pipeline and avoid a full keyboard scan every frame while keys are hammered.
		if (!ClientPrefs.data.saveReplayData)
		{
			_pendingPressKeys.resize(0);
			_pendingReleaseKeys.resize(0);
			return;
		}

		var ps = PlayState.instance;
		// Frames are recorded only on key events / judgements / speed changes;
		// the old forced 60fps sampling is gone, so silent frames are not written and the replay file
		// and its memory footprint shrink a lot (playback keeps key state from press/release events).
		var hasChanges:Bool = false;
		// O(1) change detection (see Replay.inputTick). The two FlxG.keys.*.ANY getters this replaces
		// scanned the whole key table twice on every frame, including the thousands of frames where
		// no key is touched.
		if (_lastInputTick != Replay.inputTick)
		{
			_lastInputTick = Replay.inputTick;
			hasChanges = true;
		}
		if (_pendingPressKeys.length > 0 || _pendingReleaseKeys.length > 0)
			hasChanges = true;
		if (pendingJudgments.length > 0)
			hasChanges = true;
		if (lastRecordedSongSpeed != ps.songSpeed || lastRecordedPlaybackRate != ps.playbackRate)
			hasChanges = true;

		if (hasChanges)
		{
			var frame:FrameSave = captureFrame();
			if (ClientPrefs.data.saveReplayData && pendingJudgments.length > 0)
			{
				frame.noteJudgments = pendingJudgments.copy();
				pendingJudgments = [];
			}
			frameData.push(frame);
			lastRecordedSongSpeed = ps.songSpeed;
			lastRecordedPlaybackRate = ps.playbackRate;
		}
	}

	/** Records a note judgement (for high-precision replay). */
	public function recordJudgment(strumTime:Float, noteData:Int, hitDiff:Float, rating:String, isSustain:Bool):Void
	{
		if (!isRecording || !ClientPrefs.data.saveReplayData) return;
		pendingJudgments.push({
			strumTime: strumTime,
			noteData: noteData,
			hitDiff: hitDiff,
			rating: rating,
			isSustain: isSustain
		});
	}

	/** Captures the key state of the current frame. */
	private function captureFrame():FrameSave
	{
		ensureLaneMap();
		var pressKey:Array<String> = [];
		var releaseKey:Array<String> = [];

		// Iterate every key so any mod-defined binding is recorded:
		// only checkStatus lookups run per frame; key names are resolved on press/release,
		// avoiding the old 200+ keys x (toUpperCase + map lookups) string allocation cost.
		if (cachedKeyList == null)
			cachedKeyList = [for (k in FlxKey.toStringMap.keys()) k];
		for (flxKey in cachedKeyList)
		{
			if (flxKey == FlxKey.ANY || flxKey == FlxKey.NONE) continue;
			if (FlxG.keys.checkStatus(flxKey, JUST_PRESSED))
				pressKey.push(FlxKey.toStringMap.get(flxKey));
			if (FlxG.keys.checkStatus(flxKey, JUST_RELEASED))
				releaseKey.push(FlxKey.toStringMap.get(flxKey));
		}

		// Merge keys reported directly by the Android controls (without touching FlxG.keys, so Controls does not double-judge)
		for (keyName in _pendingPressKeys)
		{
			if (pressKey.indexOf(keyName) < 0)
				pressKey.push(keyName);
		}
		_pendingPressKeys.resize(0);
		for (keyName in _pendingReleaseKeys)
		{
			if (releaseKey.indexOf(keyName) < 0)
				releaseKey.push(keyName);
		}
		_pendingReleaseKeys.resize(0);

		var ps = PlayState.instance;
		return {
			time: Conductor.songPosition,
			songSpeed: ps != null ? ps.songSpeed : 1,
			playbackRate: ps != null ? ps.playbackRate : 1,
			pressKey: pressKey,
			releaseKey: releaseKey
		};
	}

	// ---- recording entry points used by the Android controls (no keyboard simulation, so Controls does not double-judge) ----
	private var _pendingPressKeys:Array<String> = [];
	private var _pendingReleaseKeys:Array<String> = [];

	/** Called by the Android controls (hitbox / virtual pad) to record a key press. */
	public function recordPress(keyName:String):Void
	{
		if (!isRecording) return;
		Replay.inputTick++;
		if (_pendingPressKeys.indexOf(keyName) < 0)
			_pendingPressKeys.push(keyName);
	}

	/** Called by the Android controls (hitbox / virtual pad) to record a key release. */
	public function recordRelease(keyName:String):Void
	{
		if (!isRecording) return;
		Replay.inputTick++;
		if (_pendingReleaseKeys.indexOf(keyName) < 0)
			_pendingReleaseKeys.push(keyName);
	}

	/**
	 * Static notification used by FlxHitbox / FlxVirtualPad directly.
	 * Resolves the bind value and forwards the key name to the current Replay instance.
	 */
	public static function notifyPress(keyName:String):Void
	{
		var ps = PlayState.instance;
		if (ps != null && ps.replayExam != null && ps.replayExam.isRecording)
			ps.replayExam.recordPress(keyName);
	}

	public static function notifyRelease(keyName:String):Void
	{
		var ps = PlayState.instance;
		if (ps != null && ps.replayExam != null && ps.replayExam.isRecording)
			ps.replayExam.recordRelease(keyName);
	}

	// ======================== playback ========================

	/** Main replay logic: called every frame by PlayState.update(). */
	public function replayUpdate(elapsed:Float):Void
	{
		if (isRecording || PlayState.instance == null) return;
		if (frameData.length == 0)
		{
			Replay.dbgLog('[DEBUG-rpl] replayUpdate: frameData empty, cannot play');
			return;
		}

		var ps = PlayState.instance;
		var targetSongPos:Float = Conductor.songPosition;
		ensureLaneMap();

		if (globalTick == 0)
			Replay.dbgLog('[DEBUG-rpl] replayUpdate start, frames=' + frameData.length + ' songPos=' + targetSongPos);

		// Clear the just-pressed / just-released edge flags at the start of each frame (held state persists until release)
		simJustPressed.clear();
		simJustReleased.clear();

		while (lastFrameCount < frameData.length && frameData[lastFrameCount].time <= targetSongPos)
		{
			var frame = frameData[lastFrameCount];
			this.replayTime = frame.time;

			// Rate resync
			if (!Math.isNaN(lastReplayTimeForResync))
			{
				if (Math.abs(frame.songSpeed - lastSongSpeed) > 0.1)
				{
					ps.songSpeed = frame.songSpeed;
					lastSongSpeed = frame.songSpeed;
				}
				if (Math.abs(frame.playbackRate - lastPlaybackRate) > 0.1)
				{
					ps.playbackRate = frame.playbackRate;
					lastPlaybackRate = frame.playbackRate;
				}
			}
			lastReplayTimeForResync = frame.time;

			// Resolve keys -> lanes
			tmpPressLanes.resize(0);
			tmpReleaseLanes.resize(0);

			for (keyName in frame.pressKey)
			{
				var flxKey:FlxKey = FlxKey.fromString(keyName);
				var lane:Null<Int> = keyToLane.get(flxKey);
				if (lane != null) tmpPressLanes.push(lane);
				keysHeld.set(flxKey, true);
				// Record the simulated key state (for script keyJustPressed/keyPressed queries)
				var simName:String = normalizeKeyName(keyName);
				simPressed.set(simName, true);
				simJustPressed.set(simName, true);
				simKnownKeys.set(simName, true);
			}

			for (keyName in frame.releaseKey)
			{
				var flxKey:FlxKey = FlxKey.fromString(keyName);
				var lane:Null<Int> = keyToLane.get(flxKey);
				if (lane != null) tmpReleaseLanes.push(lane);
				keysHeld.remove(flxKey);
				// Record the simulated key state (for script keyJustReleased queries)
				var simName:String = normalizeKeyName(keyName);
				simPressed.remove(simName);
				simJustReleased.set(simName, true);
				simKnownKeys.set(simName, true);
			}

			// Apply this frame's press/release before building the held lanes, so a release frame is not still held
			buildHeldLanes();

			// Hand the keys to PlayState
			ps.replayApplyInput(frame.time, tmpPressLanes, tmpReleaseLanes, tmpHeldLanes);

			lastFrameCount++;
			globalTick++;
			if (globalTick % 120 == 0)
				Replay.dbgLog('[DEBUG-rpl] replayUpdate progress lastFrameCount=' + lastFrameCount + '/' + frameData.length + ' songPos=' + targetSongPos);
		}

		// Pump sustain hits / idle animations once per frame from the current key state.
		// Recording is trimmed, so there are no empty frames between key events; if replayApplyInput only ran
		// inside the while loop, a sustain body with no new events would never be judged and the character
		// would not return to idle. The idempotent empty press/release pump below covers that case.
		buildHeldLanes();
		ps.replayApplyInput(Conductor.songPosition, tmpEmptyPress, tmpEmptyRelease, tmpHeldLanes);
	}

	/** Builds the held-lane array from keysHeld (written into tmpHeldLanes). */
	private inline function buildHeldLanes():Void
	{
		tmpHeldLanes.resize(laneCount);
		for (i in 0...laneCount) tmpHeldLanes[i] = false;
		for (flxKey in keysHeld.keys())
		{
			var lane:Null<Int> = keyToLane.get(flxKey);
			if (lane != null && lane >= 0 && lane < laneCount)
				tmpHeldLanes[lane] = true;
		}
	}

	/** Builds the FlxKey -> lane map. */
	private function ensureLaneMap():Void
	{
		var ps = PlayState.instance;
		if (ps == null) return;
		if (keyToLane != null && laneCount > 0) return;
		if (keyToLane == null) keyToLane = new Map<FlxKey, Int>();
		laneCount = 0;

		var keysList:Array<Dynamic> = ps.keysArray;
		if (keysList == null || keysList.length <= 0) return;

		laneCount = keysList.length;
		for (lane in 0...keysList.length)
		{
			var keys:Array<FlxKey> = keysList[lane];
			if (keys != null)
			{
				for (key in keys)
				{
					if (key != FlxKey.NONE && !keyToLane.exists(key))
						keyToLane.set(key, lane);
				}
			}
		}
	}

	// ======================== I/O ========================

	/** Frame data for saving to Allscore. */
	public function getFrameData():Array<FrameSave>
	{
		return frameData;
	}

	/** Saves a replay to a file. */
	public static function saveToFile(frames:Array<FrameSave>, stateRecord:StateRecord, path:String):Void
	{
		#if sys
		var data:Dynamic = {
			stateRecord: stateRecord,
			frameRecord: frames
		};
		var json:String = Json.stringify(data, "\t");
		File.saveContent(path, json);
		#end
	}

	/** Loads a replay from a file (same lenient parsing as loadFromFile). */
	public static function loadFromFileStatic(path:String):{frames:Array<FrameSave>, state:StateRecord}
	{
		#if sys
		try
		{
			var json:Dynamic = parseReplayJson(File.getContent(path));
			if (json == null) return {frames: [], state: null};
			return {
				frames: extractFrames(json),
				state: json.stateRecord
			};
		}
		catch (e:Dynamic)
		{
			return {frames: [], state: null};
		}
		#else
		return {frames: [], state: null};
		#end
	}

	// ======================== lenient parsing / normalisation ========================

	/** Lenient replay JSON parsing: strips BOM, tolerates stray bytes/comments; null means unparseable. */
	private static function parseReplayJson(content:String):Dynamic
	{
		if (content == null) return null;
		if (content.length > 0 && content.charCodeAt(0) == 0xFEFF) content = content.substr(1);
		content = StringTools.trim(content);
		if (content.length == 0) return null;

		var json:Dynamic = null;
		try { json = Json.parse(content); } catch (e:Dynamic) { json = null; }
		if (json == null)
		{
			// Retry from the first { to the last } (tolerates surrounding garbage)
			var start:Int = content.indexOf('{');
			var end:Int = content.lastIndexOf('}');
			if (start >= 0 && end > start)
			{
				try { json = Json.parse(content.substring(start, end + 1)); } catch (e:Dynamic) { json = null; }
			}
		}
		return json;
	}

	/** Extracts the frame array (frameRecord / frames / frameData / a top-level array). */
	private static function extractFrames(json:Dynamic):Array<FrameSave>
	{
		var raw:Dynamic = null;
		if (json != null)
		{
			if (Reflect.hasField(json, 'frameRecord')) raw = json.frameRecord;
			else if (Reflect.hasField(json, 'frames')) raw = json.frames;
			else if (Reflect.hasField(json, 'frameData')) raw = json.frameData;
			else if (Std.isOfType(json, Array)) raw = json;
		}
		return normalizeFrames(raw);
	}

	/**
	 * Normalises frames from any source into a complete FrameSave array.
	 * Frames with missing or wrong-typed fields are patched with defaults rather than dropped, so more replays load and play.
	 */
	private static function normalizeFrames(raw:Dynamic):Array<FrameSave>
	{
		var out:Array<FrameSave> = [];
		if (raw == null) return out;
		if (Std.isOfType(raw, Array))
		{
			var arr:Array<Dynamic> = cast raw;
			for (d in arr) normalizeFrame(d, out);
		}
		else if (Type.typeof(raw) == TObject)
		{
			// The whole value may be a {frames:[...]} / {frameRecord:[...]} wrapper
			var inner:Dynamic = null;
			if (Reflect.hasField(raw, 'frames')) inner = raw.frames;
			else if (Reflect.hasField(raw, 'frameRecord')) inner = raw.frameRecord;
			else if (Reflect.hasField(raw, 'frameData')) inner = raw.frameData;
			if (Std.isOfType(inner, Array))
			{
				var innerArr:Array<Dynamic> = cast inner;
				for (d in innerArr) normalizeFrame(d, out);
			}
			else
				normalizeFrame(inner, out);
		}
		return out;
	}

	/** Normalises one frame (non-object / corrupt frames are skipped). */
	private static function normalizeFrame(d:Dynamic, out:Array<FrameSave>):Void
	{
		if (d == null || Type.typeof(d) != TObject) return;

		var rawTime:Dynamic = d.time;
		var time:Float = toFloat(rawTime, 0);
		// Frames without a numeric timestamp continue after the previous frame so event order never collapses to 0ms.
		// A legitimate countdown time (negative or 0) must not be treated as missing: presses during the
		// countdown would move to the first frames while releases stayed put, leaving keys stuck held.
		if ((rawTime == null || Math.isNaN(Std.parseFloat(Std.string(rawTime)))) && out.length > 0)
			time = out[out.length - 1].time + 1;
		var songSpeed:Float = toFloat(d.songSpeed, 1); if (songSpeed <= 0) songSpeed = 1;
		var playbackRate:Float = toFloat(d.playbackRate, 1); if (playbackRate <= 0) playbackRate = 1;

		out.push({
			time: time,
			songSpeed: songSpeed,
			playbackRate: playbackRate,
			pressKey: toKeyArray(d.pressKey),
			releaseKey: toKeyArray(d.releaseKey),
			noteJudgments: toJudgments(d.noteJudgments)
		});
	}

	/** Numeric coercion: numbers, numeric strings and booleans; parse failures return the default. */
	private static function toFloat(v:Dynamic, def:Float):Float
	{
		if (v == null) return def;
		var f:Float = Std.parseFloat(Std.string(v));
		return Math.isNaN(f) ? def : f;
	}

	/** Boolean coercion: true/1/"true"/"1" all count as true. */
	private static function toBool(v:Dynamic):Bool
	{
		if (v == null) return false;
		if (v == true) return true;
		if (Std.isOfType(v, Int) || Std.isOfType(v, Float)) return (v != 0);
		return (Std.string(v).toLowerCase() == 'true' || Std.string(v).toLowerCase() == '1');
	}

	/** Key-array coercion: arrays pass through; a single key name or keycode is accepted too. */
	private static function toKeyArray(v:Dynamic):Array<String>
	{
		if (v == null) return [];
		if (Std.isOfType(v, Array))
		{
			var out:Array<String> = [];
			var arr:Array<Dynamic> = cast v;
			for (k in arr) if (k != null) out.push(Std.string(k));
			return out;
		}
		return [Std.string(v)];
	}

	/** Judgement coercion: only structurally complete judgements are kept. */
	private static function toJudgments(v:Dynamic):Array<NoteJudgment>
	{
		if (v == null || !Std.isOfType(v, Array)) return null;
		var out:Array<NoteJudgment> = [];
		var arr:Array<Dynamic> = cast v;
		for (j in arr)
		{
			if (j == null || Type.typeof(j) != TObject) continue;
			out.push({
				strumTime: toFloat(j.strumTime, 0),
				noteData: Std.int(toFloat(j.noteData, 0)),
				hitDiff: toFloat(j.hitDiff, 0),
				rating: j.rating != null ? Std.string(j.rating) : 'sick',
				isSustain: toBool(j.isSustain)
			});
		}
		return out.length > 0 ? out : null;
	}

	/** Builds a replay file name. */
	public static function generateFileName(songName:String, difficulty:Int):String
	{
		var safeName:String = Paths.formatToSongPath(songName);
		var timestamp:Float = Date.now().getTime();
		var random:Int = Std.random(10000);
		return '${safeName}_${difficulty}_${timestamp}_${random}.rsd';
	}

	/** Converts a FrameSave array to Dynamic (for Allscore serialisation). */
	public static function framesToDynamic(frames:Array<FrameSave>):Array<Dynamic>
	{
		var result:Array<Dynamic> = [];
		for (f in frames)
		{
			result.push({
				time: f.time,
				songSpeed: f.songSpeed,
				playbackRate: f.playbackRate,
				pressKey: f.pressKey,
				releaseKey: f.releaseKey,
				noteJudgments: f.noteJudgments
			});
		}
		return result;
	}

	/** Converts a Dynamic array back to FrameSave (Allscore deserialisation, lenient normalisation). */
	public static function dynamicToFrames(data:Array<Dynamic>):Array<FrameSave>
	{
		return normalizeFrames(data);
	}
}
