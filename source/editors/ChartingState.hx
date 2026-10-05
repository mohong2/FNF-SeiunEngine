package editors;

import editors.content.Prompt;
import editors.content.Prompt.BasePrompt;

#if cpp
import Discord.DiscordClient;
#end
import flash.geom.Rectangle;
import haxe.Json;
import haxe.format.JsonParser;
import haxe.io.Bytes;
import Conductor.BPMChangeEvent;
import Section.SwagSection;
import Song.SwagSong;
import Note.NoteTypeRegistry;
import flixel.FlxObject;
import backend.ui.*;
import flixel.addons.display.FlxGridOverlay;
import flixel.addons.transition.FlxTransitionableState;
import flixel.group.FlxGroup;
import flixel.input.keyboard.FlxKey;
import flixel.system.FlxSound;
import flixel.ui.FlxSpriteButton;
import flixel.math.FlxRandom;

import flixel.text.FlxText.FlxTextAlign;
import flixel.util.FlxSort;
import lime.media.AudioBuffer;
import lime.utils.Assets;
import openfl.media.Sound;
import openfl.utils.Assets as OpenFlAssets;
import editors.content.FileDialogHandler;
import mohong.TraceManager;
import openfl.utils.ByteArray;
using StringTools;
#if sys
import flash.media.Sound;
import sys.FileSystem;
import sys.io.File;
#end


@:access(flixel.system.FlxSound._sound)
@:access(openfl.media.Sound.__buffer)

class ChartingState extends MusicBeatState implements PsychUIEventHandler.PsychUIEvent
{
	public static var noteTypeList:Array<String> = //Used for backwards compatibility with 0.1 - 0.3.2 charts, though, you should add your hardcoded custom note types here too.
	[
		'',
		'Alt Animation',
		'Hey!',
		'Hurt Note',
		'GF Sing',
		'No Animation'
	];
	private var noteTypeIntMap:Map<Int, String> = new Map<Int, String>();
	private var noteTypeMap:Map<String, Null<Int>> = new Map<String, Null<Int>>();
	public var ignoreWarnings = false;
	var undos = [];
	var redos = [];
	var eventStuff:Array<Dynamic> =
	[
		['', "Nothing. Yep, that's right."],
		['Dadbattle Spotlight', "Used in Dad Battle,\nValue 1: 0/1 = ON/OFF,\n2 = Target Dad\n3 = Target BF"],
		['Hey!', "Plays the \"Hey!\" animation from Bopeebo,\nValue 1: BF = Only Boyfriend, GF = Only Girlfriend,\nSomething else = Both.\nValue 2: Custom animation duration,\nleave it blank for 0.6s"],
		['Set GF Speed', "Sets GF head bopping speed,\nValue 1: 1 = Normal speed,\n2 = 1/2 speed, 4 = 1/4 speed etc.\nUsed on Fresh during the beatbox parts.\n\nWarning: Value must be integer!"],
		['Philly Glow', "Exclusive to Week 3\nValue 1: 0/1/2 = OFF/ON/Reset Gradient\n \nNo, i won't add it to other weeks."],
		['Kill Henchmen', "For Mom's songs, don't use this please, i love them :("],
		['Add Camera Zoom', "Used on MILF on that one \"hard\" part\nValue 1: Camera zoom add (Default: 0.015)\nValue 2: UI zoom add (Default: 0.03)\nLeave the values blank if you want to use Default."],
		['BG Freaks Expression', "Should be used only in \"school\" Stage!"],
		['Trigger BG Ghouls', "Should be used only in \"schoolEvil\" Stage!"],
		['Play Animation', "Plays an animation on a Character,\nonce the animation is completed,\nthe animation changes to Idle\n\nValue 1: Animation to play.\nValue 2: Character (Dad, BF, GF)"],
		['Camera Follow Pos', "Value 1: X\nValue 2: Y\n\nThe camera won't change the follow point\nafter using this, for getting it back\nto normal, leave both values blank."],
		['Alt Idle Animation', "Sets a specified suffix after the idle animation name.\nYou can use this to trigger 'idle-alt' if you set\nValue 2 to -alt\n\nValue 1: Character to set (Dad, BF or GF)\nValue 2: New suffix (Leave it blank to disable)"],
		['Screen Shake', "Value 1: Camera shake\nValue 2: HUD shake\n\nEvery value works as the following example: \"1, 0.05\".\nThe first number (1) is the duration.\nThe second number (0.05) is the intensity."],
		['Change Character', "Value 1: Character to change (Dad, BF, GF)\nValue 2: New character's name"],
		['Change Scroll Speed', "Value 1: Scroll Speed Multiplier (1 is default)\nValue 2: Time it takes to change fully in seconds."],
		['Set Property', "Value 1: Variable name\nValue 2: New value"],
		['Play Sound', "Value 1: Sound file name\nValue 2: Volume (Default: 1), ranges from 0 to 1"]
	];

	var _file:FileDialogHandler;

	var UI_box:PsychUIBox;

	public static var goToPlayState:Bool = false;

	/** Unsaved changes flag — prompts confirm dialog on exit / playtest. */
	public static var staticUnsavedChanges:Bool = false;
	public var unsavedChanges(get, set):Bool;
	function get_unsavedChanges():Bool return staticUnsavedChanges;
	function set_unsavedChanges(v:Bool):Bool
	{
		staticUnsavedChanges = v;
		backend.UnsavedChangesTracker.hasUnsavedChanges = v;
		if(v) backend.UnsavedChangesTracker.currentEditorState = this;
		return staticUnsavedChanges;
	}

	/**
	 * Array of notes showing when each section STARTS in STEPS
	 * Usually rounded up??
	 */
	public static var curSec:Int = 0;
	public static var lastSection:Int = 0;
	private static var lastSong:String = '';

	var bpmTxt:EditorsText;

	var camPos:FlxObject;
	var strumLine:FlxSprite;
	var quant:AttachedSprite;
	var strumLineNotes:FlxTypedGroup<StrumNote>;
	var curSong:String = 'Test';
	var amountSteps:Int = 0;

	var highlight:FlxSprite;

	public static var GRID_SIZE = 40;
	/** 多k: 当前网格总宽度 (格数 = 轨道数*2 + 事件列)。 */
	inline function curGridCols():Int
	{
		return Note.ammo[getMania()] * 2 + 1;
	}

	/** 多k: 预览模式下的网格键数 (-1 = 未预览, 使用谱面基准 _song.mania)。 */
	var previewMania:Int = -1;

	/** 多k: 事件输入 (键数/时间) 编辑会话, 焦点释放后统一重编码, 避免逐字符中间态。 */
	var _pendingManiaReencode:Bool = false;
	var _pendingManiaOldEvents:Array<Dynamic> = null;
	var _eventInputFocused:Bool = false;

	/** 多k: 当前网格显示键数 (0 基)。预览模式下跟随 Change Mania 事件, 不写回 _song.mania。 */
	inline function getMania():Int
	{
		if (previewMania >= 0) return EKData.clampMania(previewMania);
		var m:Int = (_song != null && _song.mania != null) ? _song.mania : Note.defaultMania;
		m = EKData.clampMania(m);
		if (_song != null) _song.mania = m;
		return m;
	}

	/** 多k: 某小节的 Step 总数 (4 * 拍数)。 */
	function chartSectionSteps(sec:Int):Int
	{
		if (_song == null || _song.notes == null || sec < 0 || sec >= _song.notes.length) return 16;
		var secs:Null<Float> = cast _song.notes[sec].sectionBeats;
		var beats:Float = (secs != null && secs > 0) ? secs : 4;
		return Std.int(Math.max(1, Math.round(4 * beats)));
	}

	/** 多k: 某小节每 Step 的毫秒数 (按该小节生效的 BPM)。 */
	function chartSectionStepMs(sec:Int):Float
	{
		if (_song == null || _song.notes == null) return Conductor.stepCrochet;
		var bpm:Float = (_song.bpm > 0) ? _song.bpm : 100;
		var end:Int = Std.int(Math.min(sec + 1, _song.notes.length));
		for (i in 0...end)
		{
			var section = _song.notes[i];
			if (section == null) continue;
			if (section.changeBPM && section.bpm > 0) bpm = section.bpm;
		}
		return Conductor.calculateCrochet(bpm) / 4;
	}

	/**
	 * 多k: 某小节按 Change Mania 事件切分出的网格段 (Step 级)。
	 * 事件所在 Step 之后换新键数网格列数, 事件之前的行保持旧键数。
	 */
	function chartSectionSegments(sec:Int):Array<{startStep:Int, k:Int}>
	{
		var segs:Array<{startStep:Int, k:Int}> = [];
		if (_song == null || _song.notes == null || sec < 0 || sec >= _song.notes.length)
		{
			segs.push({startStep: 0, k: getMania()});
			return segs;
		}
		var base:Int = (_song.mania != null) ? EKData.clampMania(_song.mania) : Note.defaultMania;
		var secStart:Float = sectionStartTime(sec - curSec);
		var secEnd:Float = sectionStartTime(sec - curSec + 1);
		var steps:Int = chartSectionSteps(sec);
		var stepMs:Float = chartSectionStepMs(sec);
		segs.push({startStep: 0, k: EKData.effectiveManiaAtTime(_song.events, base, secStart)});

		var bounds:Map<Int, Float> = [];
		if (_song.events != null)
		{
			for (event in _song.events)
			{
				if (event == null || event[0] == null || event[1] == null) continue;
				var evTime:Float = Std.parseFloat(Std.string(event[0]));
				if (Math.isNaN(evTime) || evTime <= secStart || evTime >= secEnd) continue;
				var subs:Array<Dynamic> = cast event[1];
				if (subs == null) continue;
				for (sub in subs)
				{
					if (sub == null || sub.length < 2) continue;
					if (Std.string(sub[0]) != 'Change Mania') continue;
					var s:Int = Std.int(Math.floor((evTime - secStart) / stepMs));
					if (s < 1) s = 1;
					if (s >= steps) s = steps - 1;
					// 同一步多个事件时取最晚事件时刻: 该步结束时真正生效的 k
					var prevT:Float = bounds.exists(s) ? bounds.get(s) : Math.NEGATIVE_INFINITY;
					if (evTime > prevT) bounds.set(s, evTime);
				}
			}
		}
		var boundSteps:Array<Int> = [for (s in bounds.keys()) s];
		boundSteps.sort((a, b) -> a - b);
		for (s in boundSteps)
			segs.push({startStep: s, k: EKData.effectiveManiaAtTime(_song.events, base, bounds.get(s))});
		return segs;
	}

	/** 多k: 某小节总像素高度 (Step 数 * 格高 * zoom)。 */
	function chartSectionHeight(sec:Int):Int
	{
		return Std.int(chartSectionSteps(sec) * GRID_SIZE * zoomList[curZoom]);
	}

	/** 多k: 某小节网格最大宽度 (取段内最大键数, 供鼠标点击边界使用)。 */
	function chartSectionWidth(sec:Int):Int
	{
		var maxK:Int = getMania();
		for (seg in chartSectionSegments(sec))
			if (seg.k > maxK) maxK = seg.k;
		return GRID_SIZE * (Note.ammo[maxK] * 2 + 1);
	}

	/**
	 * 多k: 某小节网格应使用的键数 (0 基, 按 Change Mania 事件分段)。
	 * 取小节起始与结束时刻中较大的生效键数: 事件位于小节边界时就是该小节自己的 k;
	 * 事件位于小节中间时, 后段 Note 按新键数编码, 网格需按新键数扩列避免溢出。
	 */
	function sectionMania(sec:Int):Int
	{
		if (_song == null) return Note.defaultMania;
		var base:Int = (_song.mania != null) ? EKData.clampMania(_song.mania) : Note.defaultMania;
		var startK:Int = EKData.effectiveManiaAtTime(_song.events, base, sectionStartTime(sec - curSec));
		var endK:Int = EKData.effectiveManiaAtTime(_song.events, base, sectionStartTime(sec - curSec + 1));
		return (endK > startK) ? endK : startK;
	}

	/** 多k: 当前 k 值轨道数。 */
	inline function maniaAmmo():Int
	{
		return Note.ammo[getMania()];
	}

	/** 多k: 键数 stepper UI (类字段, 供 Change Mania 事件播放时同步显示)。 */
	var uiManiaStepper:PsychUINumericStepper;
	/** Key conversion mode. */
	var convertModeDropDown:PsychUIDropDownMenu;

	/**
	 * 多k: 切 K 时转换谱面 Note 数据。
	 * - side (玩家/对手) 始终保持;
	 * - mode=1/3: 组内轨道随机重排 (数量超轨道数时保持映射, 避免冲突丢 Note);
	 * - mode=2/3: 单押自动复制到同侧空轨道组成双押。
	 */
	function convertChartNoteData(oldMania:Int, newMania:Int, mode:Int = 0):Void
	{
		if (oldMania == newMania || _song == null) return;
		var oldAmmo:Int = Note.ammo[EKData.clampMania(oldMania)];
		var newAmmo:Int = Note.ammo[EKData.clampMania(newMania)];
		if (oldAmmo < 1 || newAmmo < 1) return;

		var noteSection:Map<Array<Dynamic>, SwagSection> = [];
		var all:Array<Array<Dynamic>> = [];
		for (section in _song.notes)
		{
			if (section == null || section.sectionNotes == null) continue;
			for (note in section.sectionNotes)
			{
				if (note == null || note.length < 2) continue;
				var raw:Int = Std.int(note[1]);
				if (raw < 0) continue; // 事件 Note (data = -1)
				noteSection.set(note, section);
				all.push(note);
			}
		}

		for (note in all)
		{
			var raw:Int = Std.int(note[1]);
			var side:Int = Std.int(raw / oldAmmo);
			if (side > 1) side = 1;
			var lane:Int = raw % oldAmmo;
			note[1] = side * newAmmo + (lane % newAmmo);
		}

		var doShuffle:Bool = (mode == 1 || mode == 3);
		var doFill:Bool = (mode == 2 || mode == 3);
		if (doShuffle && newAmmo > oldAmmo)
		{
			var groups:Map<String, Array<{note:Array<Dynamic>, side:Int}>> = [];
			for (note in all)
			{
				var raw:Int = Std.int(note[1]);
				var side:Int = Std.int(raw / newAmmo);
				var key:String = side + ':' + note[0];
				if (!groups.exists(key)) groups.set(key, []);
				groups.get(key).push({note: note, side: side});
			}
			for (key => grp in groups)
			{
				if (grp.length < 2 || grp.length > newAmmo) continue;
				var targets:Array<Int> = [for (i in 0...newAmmo) i];
				// xorshift 确定性随机 (FlxRandom 的 LCG 在 32 位 Int 下溢出, 分布偏斜)
				var rstate:Int = hashStr(key);
				if (rstate == 0) rstate = 0x9E3779B9;
				var i:Int = targets.length - 1;
				while (i >= 1)
				{
					rstate ^= (rstate << 13);
					rstate ^= (rstate >>> 17);
					rstate ^= (rstate << 5);
					var j:Int = (rstate & 0x7FFFFFFF) % (i + 1);
					var tmp:Int = targets[i];
					targets[i] = targets[j];
					targets[j] = tmp;
					i--;
				}
				for (i in 0...grp.length)
					grp[i].note[1] = grp[0].side * newAmmo + targets[i];
			}
		}

		if (doFill && newAmmo > oldAmmo)
		{
			var groups2:Map<String, Array<Array<Dynamic>>> = [];
			for (note in all)
			{
				var raw:Int = Std.int(note[1]);
				var side:Int = Std.int(raw / newAmmo);
				var key:String = side + ':' + note[0];
				if (!groups2.exists(key)) groups2.set(key, []);
				groups2.get(key).push(note);
			}
			for (key => grp in groups2)
			{
				if (grp.length != 1) continue;
				var raw:Int = Std.int(grp[0][1]);
				var side:Int = Std.int(raw / newAmmo);
				var used:Array<Bool> = [for (i in 0...newAmmo) false];
				for (n in grp) used[Std.int(n[1]) % newAmmo] = true;
				var free:Array<Int> = [for (i in 0...newAmmo) if (!used[i]) i];
				if (free.length < 1) continue;
				var seed:Int = hashStr(key);
				var newLane:Int = free[Std.int(Math.abs(seed)) % free.length];
				var copyNote:Array<Dynamic> = grp[0].copy();
				copyNote[1] = side * newAmmo + newLane;
				var sec:SwagSection = noteSection.get(grp[0]);
				if (sec != null && sec.sectionNotes != null) sec.sectionNotes.push(copyNote);
			}
		}
	}

	/** 字符串哈希, 用作确定性随机种子。 */
	static function hashStr(s:String):Int
	{
		var h:Int = 0;
		for (i in 0...s.length)
			h = ((h << 5) - h) + s.charCodeAt(i);
		return h;
	}

	/**
	 * 多k: 事件列表变化 (增删改 Change Mania) 后, 把受影响 Note 从旧生效键数
	 * 重编码到新生效键数, 遵循"多k工具"里的转换模式。
	 * - 顺序映射 (mode=0): side 保持, lane 按新 k 取模;
	 * - mode=1/3: 每个 (side, 旧k, 时间) 组内确定性重排;
	 * - mode=2/3: 单押自动复制到同侧空轨道组成双押。
	 */
	function reencodeNotesForEventChange(oldEvents:Array<Dynamic>, newEvents:Array<Dynamic>, mode:Int):Void
	{
		if (_song == null || _song.notes == null) return;
		var baseMania:Int = (_song.mania != null) ? EKData.clampMania(_song.mania) : Note.defaultMania;
		var noteSection:Map<Array<Dynamic>, SwagSection> = [];
		var all:Array<Array<Dynamic>> = [];
		for (section in _song.notes)
		{
			if (section == null || section.sectionNotes == null) continue;
			for (note in section.sectionNotes)
			{
				if (note == null || note.length < 2) continue;
				var raw:Int = Std.int(note[1]);
				if (raw < 0) continue; // 事件 Note
				noteSection.set(note, section);
				all.push(note);
			}
		}
		if (all.length < 1) return;

		// 筛选受影响 Note (新旧事件列表下生效键数不同的), 并记录旧键数
		var changed:Array<Array<Dynamic>> = [];
		var oldKOf:Map<Array<Dynamic>, Int> = [];
		for (note in all)
		{
			var t:Float = Std.parseFloat(Std.string(note[0]));
			var oldK:Int = EKData.effectiveManiaAtTime(oldEvents, baseMania, t);
			var newK:Int = EKData.effectiveManiaAtTime(newEvents, baseMania, t);
			if (oldK == newK) continue;
			oldKOf.set(note, oldK);
			changed.push(note);
		}
		if (changed.length < 1) return;

		// 1. 顺序映射基础: side 保持, lane 按新 k 取模
		for (note in changed)
		{
			var t:Float = Std.parseFloat(Std.string(note[0]));
			var newK:Int = EKData.effectiveManiaAtTime(newEvents, baseMania, t);
			note[1] = EKData.convertRawData(Std.int(note[1]), oldKOf.get(note), newK);
		}

		var doShuffle:Bool = (mode == 1 || mode == 3);
		var doFill:Bool = (mode == 2 || mode == 3);
		if (!doShuffle && !doFill) return;

		// 2. 按 (side, 旧k, 新k, 时间) 分组
		var groups:Map<String, Array<{note:Array<Dynamic>, side:Int, newK:Int, newAmmo:Int}>> = [];
		for (note in changed)
		{
			var t:Float = Std.parseFloat(Std.string(note[0]));
			var newK:Int = EKData.effectiveManiaAtTime(newEvents, baseMania, t);
			var raw:Int = Std.int(note[1]);
			var newAmmo:Int = Note.ammo[newK];
			var side:Int = Std.int(raw / newAmmo);
			if (side > 1) side = 1;
			var key:String = side + ':' + oldKOf.get(note) + ':' + newK + ':' + note[0];
			if (!groups.exists(key)) groups.set(key, []);
			groups.get(key).push({note: note, side: side, newK: newK, newAmmo: newAmmo});
		}

		for (key => grp in groups)
		{
			var oldK:Int = oldKOf.get(grp[0].note);
			if (grp[0].newAmmo <= Note.ammo[oldK]) continue; // 只在扩容时重排/补双押

			if (doShuffle && grp.length >= 2 && grp.length <= grp[0].newAmmo)
			{
				var targets:Array<Int> = [for (i in 0...grp[0].newAmmo) i];
				var rstate:Int = hashStr(key);
				if (rstate == 0) rstate = 0x9E3779B9;
				var i:Int = targets.length - 1;
				while (i >= 1)
				{
					rstate ^= (rstate << 13);
					rstate ^= (rstate >>> 17);
					rstate ^= (rstate << 5);
					var j:Int = (rstate & 0x7FFFFFFF) % (i + 1);
					var tmp:Int = targets[i];
					targets[i] = targets[j];
					targets[j] = tmp;
					i--;
				}
				for (i in 0...grp.length)
					grp[i].note[1] = grp[0].side * grp[0].newAmmo + targets[i];
			}
			else if (doFill && grp.length == 1)
			{
				var used:Array<Bool> = [for (i in 0...grp[0].newAmmo) false];
				used[Std.int(grp[0].note[1]) % grp[0].newAmmo] = true;
				var free:Array<Int> = [for (i in 0...grp[0].newAmmo) if (!used[i]) i];
				if (free.length < 1) continue;
				var seed:Int = hashStr(key);
				var newLane:Int = free[Std.int(Math.abs(seed)) % free.length];
				var copyNote:Array<Dynamic> = grp[0].note.copy();
				copyNote[1] = grp[0].side * grp[0].newAmmo + newLane;
				var sec:SwagSection = noteSection.get(grp[0].note);
				if (sec != null && sec.sectionNotes != null) sec.sectionNotes.push(copyNote);
			}
		}
	}

	/**
	 * 多k: 一键写大粪 (旧版编辑器简化版)。
	 * 先切到目标 K (例如 4K -> 9K), 再点此按钮:
	 * - 分析人声能量, 人声密集处生成更多 Note;
	 * - 现有 Note 按人声能量附加 1~3 个随机轨道副本;
	 * - 人声强且无 Note 的 16 分位置补随机轨道 Note。
	 */
	function writeDumbChart():Void
	{
		if (_song == null) return;
		var ammo:Int = maniaAmmo();
		if (ammo < 5)
		{
			TraceManager.warn('trace.editor.dumbChart', '请先切换到 5K 以上再一键写大粪');
			return;
		}
		var energy:Array<Float> = analyzeVocalEnergy();
		var avg:Float = 0;
		for (e in energy) avg += e;
		if (energy.length > 0) avg /= energy.length;
		var rnd:FlxRandom = new FlxRandom();
		var totalAdd:Int = 0;
		var maxTime:Float = (FlxG.sound.music != null) ? FlxG.sound.music.length : Math.POSITIVE_INFINITY;

		for (secNum => section in _song.notes)
		{
			if (section == null || section.sectionNotes == null) continue;
			var secStart:Float = sectionStartTime(secNum);
			var stepMs:Float = Conductor.stepCrochet;
			var sb:Null<Float> = section.sectionBeats;
			var beats:Float = (sb != null && sb > 0) ? sb : 4;
			var steps:Int = Std.int(Math.max(4, beats * 4));
			var used:Map<String, Bool> = [];
			var addList:Array<Array<Dynamic>> = [];

			var groups:Map<String, Array<Array<Dynamic>>> = [];
			for (n in section.sectionNotes)
			{
				if (n == null || n.length < 2) continue;
				var raw:Int = Std.int(n[1]);
				if (raw < 0) continue;
				var side:Int = Std.int(raw / ammo);
				var lane:Int = raw % ammo;
				used.set(Std.string(n[0]) + ':' + side + ':' + lane, true);
				var key:String = side + ':' + n[0];
				if (!groups.exists(key)) groups.set(key, []);
				groups.get(key).push(n);
			}

			for (key => grp in groups)
			{
				var raw:Int = Std.int(grp[0][1]);
				var side:Int = Std.int(raw / ammo);
				var t:Float = Std.parseFloat(Std.string(grp[0][0]));
				var e:Float = energyAt(energy, t);
				var extra:Int = 0;
				if (e > avg * 1.3) extra = rnd.int(2, 3);
				else if (e > avg * 0.7) extra = 1;
				else if (rnd.float() < 0.25) extra = 1;
				for (k in 0...extra)
				{
					var freeLanes:Array<Int> = [];
					for (lane in 0...ammo)
						if (!used.exists(Std.string(t) + ':' + side + ':' + lane)) freeLanes.push(lane);
					if (freeLanes.length < 1) break;
					var newLane:Int = freeLanes[rnd.int(0, freeLanes.length - 1)];
					var copyNote:Array<Dynamic> = grp[0].copy();
					copyNote[1] = side * ammo + newLane;
					addList.push(copyNote);
					used.set(Std.string(t) + ':' + side + ':' + newLane, true);
				}
			}

			for (i in 0...steps)
			{
				var st:Float = secStart + i * stepMs;
				if (st >= maxTime - 1) break; // 不生成超出歌曲长度的 Note
				var e:Float = energyAt(energy, st);
				if (e <= avg * 1.2) continue;
				var side:Int = rnd.int(0, 1);
				var has:Bool = false;
				for (lane in 0...ammo)
					if (used.exists(Std.string(st) + ':' + side + ':' + lane)) { has = true; break; }
				if (has) continue;
				var lane:Int = rnd.int(0, ammo - 1);
				var key:String = Std.string(st) + ':' + side + ':' + lane;
				if (used.exists(key)) continue;
				addList.push([st, side * ammo + lane, 0]);
				used.set(key, true);
			}

			for (n in addList) section.sectionNotes.push(n);
			totalAdd += addList.length;
		}

		markUnsaved();
		updateGrid();
		TraceManager.info('trace.editor.dumbChartDone', '一键写大粪完成(匹配人声), 新增 {} 个 Note', [totalAdd]);
	}

	/** 多k: 分析人声轨能量, 每 25ms 一个能量桶。 */
	function analyzeVocalEnergy():Array<Float>
	{
		var result:Array<Float> = [];
		#if (lime_cffi && !macro)
		@:privateAccess
		if (vocals != null && vocals._sound != null && vocals._sound.__buffer != null)
		{
			var buffer:AudioBuffer = vocals._sound.__buffer;
			if (buffer != null && buffer.data != null)
			{
				var bytes:Bytes = buffer.data.toBytes();
				var channels:Int = buffer.channels;
				if (channels >= 1 && bytes != null && bytes.length >= 2)
				{
					var samplesPerBucket:Int = Math.round(buffer.sampleRate * 0.025);
					if (samplesPerBucket < 1) samplesPerBucket = 1;
					var totalFrames:Int = Math.floor(bytes.length / (2 * channels));
					var bucketCount:Int = Math.floor(totalFrames / samplesPerBucket) + 1;
					var sums:Array<Float> = [for (i in 0...bucketCount) 0.0];
					var counts:Array<Int> = [for (i in 0...bucketCount) 0];
					var i:Int = 0;
					while (i < totalFrames)
					{
						var byte:Int = bytes.getUInt16(i * channels * 2);
						if (byte > 65535 / 2) byte -= 65535;
						var sample:Float = byte / 65535;
						if (channels >= 2)
						{
							byte = bytes.getUInt16(i * channels * 2 + 2);
							if (byte > 65535 / 2) byte -= 65535;
							var s2:Float = byte / 65535;
							if (Math.abs(s2) > Math.abs(sample)) sample = s2;
						}
						var bucket:Int = Math.floor(i / samplesPerBucket);
						if (bucket < bucketCount)
						{
							sums[bucket] += Math.abs(sample);
							counts[bucket]++;
						}
						i++;
					}
					result = [for (b in 0...bucketCount) (counts[b] > 0) ? sums[b] / counts[b] : 0];
				}
			}
		}
		#end
		return result;
	}

	/** 查询某时刻的人声能量 (25ms 桶)。 */
	inline function energyAt(energy:Array<Float>, t:Float):Float
	{
		if (energy == null || energy.length < 1 || t < 0) return 0;
		var idx:Int = Std.int(t / 25);
		if (idx >= energy.length) return 0;
		return energy[idx];
	}

	/**
	 * 多k: 密度增强 (旧版简化版)。
	 * 1 拍窗口内 Note 数 >= 阈值时补充 1~2 个随机轨道 Note。
	 */
	function boostDensity(threshold:Int):Void
	{
		if (_song == null) return;
		if (threshold < 1) threshold = 1;
		var ammo:Int = maniaAmmo();
		var rnd:FlxRandom = new FlxRandom();
		var totalAdd:Int = 0;
		var maxTime:Float = (FlxG.sound.music != null) ? FlxG.sound.music.length : Math.POSITIVE_INFINITY;

		for (secNum => section in _song.notes)
		{
			if (section == null || section.sectionNotes == null) continue;
			var stepMs:Float = Conductor.stepCrochet;
			var beatMs:Float = stepMs * 4;
			var secStart:Float = sectionStartTime(secNum);
			var sb:Null<Float> = section.sectionBeats;
			var beats:Float = (sb != null && sb > 0) ? sb : 4;
			var steps:Int = Std.int(Math.max(4, beats * 4));
			var used:Map<String, Bool> = [];
			var addList:Array<Array<Dynamic>> = [];

			for (n in section.sectionNotes)
			{
				if (n == null || n.length < 2) continue;
				var raw:Int = Std.int(n[1]);
				if (raw < 0) continue;
				var side:Int = Std.int(raw / ammo);
				var lane:Int = raw % ammo;
				used.set(Std.string(n[0]) + ':' + side + ':' + lane, true);
			}

			// 按拍遍历 (每拍一个密度窗口)
			var beatCount:Int = Std.int(Math.max(1, beats));
			for (b in 0...beatCount)
			{
				var beatStart:Float = secStart + b * beatMs;
				if (beatStart >= maxTime - 1) break;
				var count:Int = 0;
				for (n in section.sectionNotes)
				{
					if (n == null || n.length < 2) continue;
					var t:Float = Std.parseFloat(Std.string(n[0]));
					if (t >= beatStart && t < beatStart + beatMs) count++;
				}
				if (count < threshold) continue;
				var toAdd:Int = rnd.int(1, 2);
				for (k in 0...toAdd)
				{
					var st:Float = beatStart + rnd.int(0, 3) * stepMs;
					if (st >= maxTime - 1) continue;
					var side:Int = rnd.int(0, 1);
					var lane:Int = rnd.int(0, ammo - 1);
					var key:String = Std.string(st) + ':' + side + ':' + lane;
					if (used.exists(key)) continue;
					addList.push([st, side * ammo + lane, 0]);
					used.set(key, true);
				}
			}

			for (n in addList) section.sectionNotes.push(n);
			totalAdd += addList.length;
		}

		markUnsaved();
		updateGrid();
		TraceManager.info('trace.editor.dumbChartDensity', '密度增强完成(阈值 {}), 新增 {} 个 Note', [threshold, totalAdd]);
	}
	var CAM_OFFSET:Int = 360;

	var dummyArrow:FlxSprite;

	var curRenderedSustains:FlxTypedGroup<FlxSprite>;
	var curRenderedNotes:FlxTypedGroup<Note>;
	var curRenderedNoteType:FlxTypedGroup<EditorsText>;

	var nextRenderedSustains:FlxTypedGroup<FlxSprite>;
	var nextRenderedNotes:FlxTypedGroup<Note>;

	var gridBG:FlxSprite;
	var nextGridBG:FlxSprite;

	var daquantspot = 0;
	var curEventSelected:Int = 0;
	var curUndoIndex = 0;
	var curRedoIndex = 0;
	var _song:SwagSong;
	/*
	 * WILL BE THE CURRENT / LAST PLACED NOTE
	**/
	var curSelectedNote:Array<Dynamic> = null;

	#if android
	var _longPressNote:Note = null;
	var _longPressTimer:Float = 0;
	var _longPressThreshold:Float = 0.4;
	#end

	var tempBpm:Float = 0;
	var playbackSpeed:Float = 1;

	var vocals:FlxSound = null;
	var opponentVocals:FlxSound = null;

	var leftIcon:HealthIcon;
	var rightIcon:HealthIcon;

	var value1InputText:PsychUIInputText;
	var value2InputText:PsychUIInputText;
	var currentSongName:String;

	var zoomTxt:EditorsText;

	var zoomList:Array<Float> = [
		0.25,
		0.5,
		1,
		2,
		3,
		4,
		6,
		8,
		12,
		16,
		24
	];
	var curZoom:Int = 2;

	private var blockPressWhileTypingOn:Array<PsychUIInputText> = [];
	private var blockPressWhileTypingOnStepper:Array<PsychUINumericStepper> = [];
	private var blockPressWhileScrolling:Array<PsychUIDropDownMenu> = [];

	var waveformSprite:FlxSprite;
	var gridLayer:FlxTypedGroup<FlxSprite>;

	public static var quantization:Int = 16;
	public static var curQuant = 3;

	public var quantizations:Array<Int> = [
		4,
		8,
		12,
		16,
		20,
		24,
		32,
		48,
		64,
		96,
		192
	];



	var text:String = "";
	public static var vortex:Bool = false;
	public var mouseQuant:Bool = false;
	override function create()
	{
		clearUnsaved();
		_file = new FileDialogHandler();

		if (PlayState.SONG != null)
			_song = PlayState.SONG;
		else
		{
			CoolUtil.difficulties = CoolUtil.defaultDifficulties.copy();

			_song = {
				song: 'Test',
				notes: [],
				events: [],
				bpm: 150.0,
				needsVoices: true,
				offset: 0,
				mania: Note.defaultMania,

				arrowSkin: '',
				splashSkin: 'noteSplashes',//idk it would crash if i didn't
				player1: 'bf',
				player2: 'dad',
				gfVersion: 'gf',
				speed: 1,
				stage: 'stage',
				format: 'na',
				validScore: false
			};
			addSection();
			PlayState.SONG = _song;
		}
		if (_song.mania == null) _song.mania = Note.defaultMania;
		PlayState.mania = EKData.clampMania(_song.mania);
		TraceManager.info('trace.editor.create', 'ChartingState create() #{} mania={} notes={}', [Math.floor(FlxG.random.float(0, 100000)), getMania(), _song.notes.length]);

		// Paths.clearMemory();

		#if cpp
		// Updating Discord Rich Presence
		DiscordClient.changePresence("Chart Editor", StringTools.replace(_song.song, '-', ' '));
		#end

		vortex = FlxG.save.data.chart_vortex;
		ignoreWarnings = FlxG.save.data.ignoreWarnings;
		var bg:FlxSprite = new FlxSprite().loadGraphic(Paths.image('menuDesat'));
		bg.scrollFactor.set();
		bg.color = 0xFF222222;
		add(bg);

		gridLayer = new FlxTypedGroup<FlxSprite>();
		add(gridLayer);

		waveformSprite = new FlxSprite(GRID_SIZE, 0).makeGraphic(FlxG.width, FlxG.height, 0x00FFFFFF);
		add(waveformSprite);

		var eventIcon:FlxSprite = new FlxSprite(-GRID_SIZE - 5, -90).loadGraphic(Paths.image('eventArrow'));
		leftIcon = new HealthIcon('bf');
		rightIcon = new HealthIcon('dad');
		eventIcon.scrollFactor.set(1, 1);
		leftIcon.scrollFactor.set(1, 1);
		rightIcon.scrollFactor.set(1, 1);

		eventIcon.setGraphicSize(30, 30);
		leftIcon.setGraphicSize(0, 45);
		rightIcon.setGraphicSize(0, 45);

		add(eventIcon);
		add(leftIcon);
		add(rightIcon);

		leftIcon.setPosition(GRID_SIZE * (maniaAmmo() / 2), -100);
		rightIcon.setPosition(GRID_SIZE * (maniaAmmo() + maniaAmmo() / 2), -100);

		curRenderedSustains = new FlxTypedGroup<FlxSprite>();
		curRenderedNotes = new FlxTypedGroup<Note>();
		curRenderedNoteType = new FlxTypedGroup<EditorsText>();

		nextRenderedSustains = new FlxTypedGroup<FlxSprite>();
		nextRenderedNotes = new FlxTypedGroup<Note>();

		if(curSec >= _song.notes.length) curSec = _song.notes.length - 1;

		FlxG.mouse.visible = true;
		//FlxG.save.bind('funkin', 'ninjamuffin99');

		tempBpm = _song.bpm;

		addSection();

		// sections = _song.notes;

		currentSongName = Paths.formatToSongPath(_song.song);
		loadSong();
		reloadGridLayer();
		Conductor.changeBPM(_song.bpm);
		Conductor.mapBPMChanges(_song);

		bpmTxt = new EditorsText(1000, 50, 0, "", 16);
		bpmTxt.scrollFactor.set();
		add(bpmTxt);

		strumLine = new FlxSprite(0, 50).makeGraphic(Std.int(GRID_SIZE * curGridCols()), 4);
		add(strumLine);

		quant = new AttachedSprite('chart_quant','chart_quant');
		quant.animation.addByPrefix('q','chart_quant',0,false);
		quant.animation.play('q', true, false, 0);
		quant.sprTracker = strumLine;
		quant.xAdd = -32;
		quant.yAdd = 8;
		add(quant);

		strumLineNotes = new FlxTypedGroup<StrumNote>();
		add(strumLineNotes);
		rebuildStrumNotes();

		camPos = new FlxObject(0, 0, 1, 1);
		camPos.setPosition(strumLine.x + CAM_OFFSET, strumLine.y);

		dummyArrow = new FlxSprite().makeGraphic(GRID_SIZE, GRID_SIZE);
		add(dummyArrow);

		var tabs = ['newchartEditor_charting', 'newchartEditor_section', 'newchartEditor_note', 'newchartEditor_events', 'newchartEditor_song'];

		UI_box = new PsychUIBox(640 + GRID_SIZE / 2, 25, 300, 400, tabs);
		UI_box.scrollFactor.set();

		text = Language.get("ChartingState.text", "W/S or Mouse Wheel - Adjust Conductor's strum time\nA/D - Jump to Previous/Next Section\nLeft Arrow/Right Arrow - Change Snap\nUp Arrow/Down Arrow - Adjust Conductor's Strum Time with Snap\n[ / ] - Change Playback Rate (Hold Shift for faster adjustment)\nALT + [ / ] - Reset Playback Rate\nHold Shift for 4x Speed Movement\nHold Control and click a note arrow to select it\nZ/X - Zoom In/Out\n\nEsc - Test Chart in Editor\nEnter - Play Chart\nQ/E - Decrease/Increase Note Sustain Length\nSpacebar - Stop/Resume Song");
		var tipTextArray:Array<String> = text.split('\n');
		for (i in 0...tipTextArray.length) {
			var tipText:EditorsText = new EditorsText(UI_box.x, UI_box.y + UI_box.height + 8, 0, tipTextArray[i], 16);
			tipText.y += i * 12;
			tipText.setFormat(Paths.font("editors.ttf"), 14, FlxColor.WHITE, LEFT/*, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK*/);
			//tipText.borderSize = 2;
			tipText.scrollFactor.set();
			add(tipText);
		}
		add(UI_box);
			for (tab in UI_box.tabs) tab.text.font = 'assets/fonts/editors.ttf';

		addSongUI();
		addSectionUI();
		addNoteUI();
		addEventsUI();
		addChartingUI();
		updateHeads();
		updateWaveform();
		//UI_box.selectedIndex = 4;

		add(curRenderedSustains);
		add(curRenderedNotes);
		add(curRenderedNoteType);
		add(nextRenderedSustains);
		add(nextRenderedNotes);

		if(lastSong != currentSongName) {
			changeSection();
		}
		lastSong = currentSongName;

		zoomTxt = new EditorsText(10, 40, 0, "Zoom: 1 / 1", 16);
		zoomTxt.scrollFactor.set();
		add(zoomTxt);
		updateGrid();
		#if (android || desktop)
		addVirtualPad(LEFT_FULL, CHART_EDITOR);
		#end
		super.create();
	}

	var check_mute_inst:PsychUICheckBox = null;
	var check_vortex:PsychUICheckBox = null;
	var check_warnings:PsychUICheckBox = null;
	var playSoundBf:PsychUICheckBox = null;
	var playSoundDad:PsychUICheckBox = null;
	var UI_songTitle:PsychUIInputText;
	var noteSkinInputText:PsychUIInputText;
	var noteSplashesInputText:PsychUIInputText;
	var stageDropDown:PsychUIDropDownMenu;
	var sliderRate:PsychUISlider;
	function addSongUI():Void
	{
		UI_songTitle = new PsychUIInputText(10, 10, 70, _song.song, 8);
		blockPressWhileTypingOn.push(UI_songTitle);

		var check_voices = new PsychUICheckBox(10, 25, Language.get("newchartEditor_allow_vocals", "Has voice track"), 100, null);
		check_voices.checked = _song.needsVoices;
		// _song.needsVoices = check_voices.checked;
		check_voices.onClick = function()
		{
			_song.needsVoices = check_voices.checked;
			//trace('CHECKED!');
		};

		var saveButton:PsychUIButton = new PsychUIButton(110, 8, Language.get("newchartEditor_save_btn", "Save"), function()
		{
			saveLevel();
		});

		saveButton.text.font = 'assets/fonts/editors.ttf';

		var reloadSong:PsychUIButton = new PsychUIButton(saveButton.x + 90, saveButton.y, Language.get("newchartEditor_reload_audio", "Reload Audio"), function()
		{
			currentSongName = Paths.formatToSongPath(UI_songTitle.text);
			loadSong();
			updateWaveform();
		});

		reloadSong.text.font = 'assets/fonts/editors.ttf';

		var reloadSongJson:PsychUIButton = new PsychUIButton(reloadSong.x, saveButton.y + 30, Language.get("newchartEditor_reload_json", "Reload JSON"), function()
		{
			var songLower:String = _song.song.toLowerCase();
			openSubState(new Prompt('This action will clear current progress.\n\nProceed?', function() {
				// Delay to ensure the Prompt fully closes before opening any new substate
				haxe.Timer.delay(function() {
					getAvailableDifficultiesForSong(songLower);
				}, 200);
			}));
		});

		reloadSongJson.text.font = 'assets/fonts/editors.ttf';

		var loadAutosaveBtn:PsychUIButton = new PsychUIButton(reloadSongJson.x, reloadSongJson.y + 30, Language.get("newchartEditor_load_autosave_btn", "Load Autosave"), function()
		{
			PlayState.SONG = Song.parseJSON(FlxG.save.data.autosave);
			MusicBeatState.resetState();
		});

		loadAutosaveBtn.text.font = 'assets/fonts/editors.ttf';

		var loadEventJson:PsychUIButton = new PsychUIButton(loadAutosaveBtn.x, loadAutosaveBtn.y + 30, Language.get("newchartEditor_load_events_btn", "Load Events"), function()
		{

			var songName:String = Paths.formatToSongPath(_song.song);
			var file:String = Paths.json(songName + '/events');
			#if sys
			if (#if MODS_ALLOWED FileSystem.exists(Paths.modsJson(songName + '/events')) || #end FileSystem.exists(file))
			#else
			if (OpenFlAssets.exists(file))
			#end
			{
				clearEvents();
				var events:SwagSong = Song.loadFromJson('events', songName);
				_song.events = events.events;
				changeSection(curSec);
			}
		});

		loadEventJson.text.font = 'assets/fonts/editors.ttf';

		var saveEvents:PsychUIButton = new PsychUIButton(110, reloadSongJson.y, Language.get("newchartEditor_save_events_btn", "Save Events"), function ()
		{
			saveEvents();
		});

		saveEvents.text.font = 'assets/fonts/editors.ttf';

		var clear_events:PsychUIButton = new PsychUIButton(180, 310, Language.get("newchartEditor_clear_events_btn", "Clear events"), function()
			{
				openSubState(new Prompt('This action will clear current progress.\n\nProceed?', clearEvents));
			});
		clear_events.text.font = 'assets/fonts/editors.ttf';
		clear_events.bg.color = FlxColor.RED;
		clear_events.text.color = FlxColor.WHITE;

		var clear_notes:PsychUIButton = new PsychUIButton(180, clear_events.y + 30, Language.get("newchartEditor_clear_notes_btn", "Clear notes"), function()
			{
openSubState(new Prompt('This action will clear current progress.\n\nProceed?', function(){pushUndo(); for (sec in 0..._song.notes.length) {
				_song.notes[sec].sectionNotes = [];
			}
			updateGrid();
		}));

			});
		clear_notes.text.font = 'assets/fonts/editors.ttf';
		clear_notes.bg.color = FlxColor.RED;
		clear_notes.text.color = FlxColor.WHITE;

		var stepperBPM:PsychUINumericStepper = new PsychUINumericStepper(10, 70, 1, 1, 1, 400, 3);
		stepperBPM.textObj.font = 'assets/fonts/editors.ttf';
			stepperBPM.value = Conductor.bpm;
		stepperBPM.name = 'song_bpm';
		blockPressWhileTypingOnStepper.push(stepperBPM);

		var stepperSpeed:PsychUINumericStepper = new PsychUINumericStepper(10, stepperBPM.y + 35, 0.1, 1, 0.1, 10, 1);
		stepperSpeed.textObj.font = 'assets/fonts/editors.ttf';
			stepperSpeed.value = _song.speed;
		stepperSpeed.name = 'song_speed';
		blockPressWhileTypingOnStepper.push(stepperSpeed);

		// 多k: 键数 (显示 1-18, 内部 mania = 值-1)
		uiManiaStepper = new PsychUINumericStepper(200, 128, 1, getMania() + 1, 1, Note.maxMania + 1, 0, 45);
		uiManiaStepper.textObj.font = 'assets/fonts/editors.ttf';
		uiManiaStepper.name = 'mania';
		blockPressWhileTypingOnStepper.push(uiManiaStepper);
		// Key conversion mode: sequential / shuffle / auto-double / shuffle+double.
		convertModeDropDown = new PsychUIDropDownMenu(150, 180, [
			Language.get('newchartEditor_convert_sequential', '顺序映射'),
			Language.get('newchartEditor_convert_shuffle', '自动打乱'),
			Language.get('newchartEditor_convert_double', '自动补双押'),
			Language.get('newchartEditor_convert_shuffle_double', '打乱+双押')
		], function(id:Int, label:String) {}, 110);
		convertModeDropDown.selectedIndex = 0;
		#if MODS_ALLOWED
		var directories:Array<String> = [Paths.mods('characters/'), Paths.mods(Paths.currentModDirectory + '/characters/'), Paths.getPreloadPath('characters/')];
		for(mod in Paths.getGlobalMods())
			directories.push(Paths.mods(mod + '/characters/'));
		#else
		var directories:Array<String> = [Paths.getPreloadPath('characters/')];
		#end

		var tempMap:Map<String, Bool> = new Map<String, Bool>();
		var characters:Array<String> = CoolUtil.coolTextFile(Paths.txt('characterList'));
		for (i in 0...characters.length) {
			tempMap.set(characters[i], true);
		}

		#if MODS_ALLOWED
		for (i in 0...directories.length) {
			var directory:String = directories[i];
			if(FileSystem.exists(directory)) {
				for (file in FileSystem.readDirectory(directory)) {
					var path = haxe.io.Path.join([directory, file]);
					if (!FileSystem.isDirectory(path) && file.endsWith('.json')) {
						var charToCheck:String = file.substr(0, file.length - 5);
						if(!charToCheck.endsWith('-dead') && !tempMap.exists(charToCheck)) {
							tempMap.set(charToCheck, true);
							characters.push(charToCheck);
						}
					}
				}
			}
		}
		#end

		var player1DropDown = new PsychUIDropDownMenu(10, stepperSpeed.y + 45, characters, function(index:Int, label:String)
		{
			_song.player1 = characters[index];
			markUnsaved();
			updateHeads();
		});
		player1DropDown.textObj.font = 'assets/fonts/editors.ttf';
			player1DropDown.selectedLabel = _song.player1;
		player1DropDown.maxItems = 12; // 角色列表可能很长, 窗口化展开避免面板超出屏幕
		blockPressWhileScrolling.push(player1DropDown);

		var gfVersionDropDown = new PsychUIDropDownMenu(player1DropDown.x, player1DropDown.y + 40, characters, function(index:Int, label:String)
		{
			_song.gfVersion = characters[index];
			markUnsaved();
			updateHeads();
		});
		gfVersionDropDown.textObj.font = 'assets/fonts/editors.ttf';
			gfVersionDropDown.selectedLabel = _song.gfVersion;
		gfVersionDropDown.maxItems = 12;
		blockPressWhileScrolling.push(gfVersionDropDown);

		var player2DropDown = new PsychUIDropDownMenu(player1DropDown.x, gfVersionDropDown.y + 40, characters, function(index:Int, label:String)
		{
			_song.player2 = characters[index];
			markUnsaved();
			updateHeads();
		});
		player2DropDown.textObj.font = 'assets/fonts/editors.ttf';
			player2DropDown.selectedLabel = _song.player2;
		player2DropDown.maxItems = 12;
		blockPressWhileScrolling.push(player2DropDown);

		#if MODS_ALLOWED
		var directories:Array<String> = [Paths.mods('stages/'), Paths.mods(Paths.currentModDirectory + '/stages/'), Paths.getPreloadPath('stages/')];
		for(mod in Paths.getGlobalMods())
			directories.push(Paths.mods(mod + '/stages/'));
		#else
		var directories:Array<String> = [Paths.getPreloadPath('stages/')];
		#end

		tempMap.clear();
		var stageFile:Array<String> = CoolUtil.coolTextFile(Paths.txt('stageList'));
		var stages:Array<String> = [];
		for (i in 0...stageFile.length) { //Prevent duplicates
			var stageToCheck:String = stageFile[i];
			if(!tempMap.exists(stageToCheck)) {
				stages.push(stageToCheck);
			}
			tempMap.set(stageToCheck, true);
		}
		#if MODS_ALLOWED
		for (i in 0...directories.length) {
			var directory:String = directories[i];
			if(FileSystem.exists(directory)) {
				for (file in FileSystem.readDirectory(directory)) {
					var path = haxe.io.Path.join([directory, file]);
					if (!FileSystem.isDirectory(path) && file.endsWith('.json')) {
						var stageToCheck:String = file.substr(0, file.length - 5);
						if(!tempMap.exists(stageToCheck)) {
							tempMap.set(stageToCheck, true);
							stages.push(stageToCheck);
						}
					}
				}
			}
		}
		#end

		if(stages.length < 1) stages.push('stage');

		stageDropDown = new PsychUIDropDownMenu(player1DropDown.x + 140, player1DropDown.y, stages, function(index:Int, label:String)
		{
			_song.stage = stages[index];
			markUnsaved();
			StageData.loadDirectory(_song);
			var sf = StageData.getStageFile(stages[index]);
			if(sf != null) PlayState.isPixelStage = sf.isPixelStage;
			updateGrid();
		});
		stageDropDown.textObj.font = 'assets/fonts/editors.ttf';
			stageDropDown.selectedLabel = _song.stage;
		stageDropDown.maxItems = 12;
		blockPressWhileScrolling.push(stageDropDown);

		var skin = PlayState.SONG.arrowSkin;
		if(skin == null) skin = '';
		noteSkinInputText = new PsychUIInputText(player2DropDown.x, player2DropDown.y + 50, 150, skin, 8);
		blockPressWhileTypingOn.push(noteSkinInputText);

		noteSplashesInputText = new PsychUIInputText(noteSkinInputText.x, noteSkinInputText.y + 35, 150, _song.splashSkin, 8);
		blockPressWhileTypingOn.push(noteSplashesInputText);

		var reloadNotesButton:PsychUIButton = new PsychUIButton(noteSplashesInputText.x + 5, noteSplashesInputText.y + 20, Language.get("newchartEditor_change_notes_btn", "Change Notes"), function() {
			_song.arrowSkin = noteSkinInputText.text;
				updateGrid();
		});

		reloadNotesButton.text.font = 'assets/fonts/editors.ttf';

		var tab_group_song = UI_box.getTab("newchartEditor_song").menu;
		tab_group_song.add(UI_songTitle);

		tab_group_song.add(check_voices);
		tab_group_song.add(clear_events);
		tab_group_song.add(clear_notes);
		tab_group_song.add(saveButton);
		tab_group_song.add(saveEvents);
		tab_group_song.add(reloadSong);
		tab_group_song.add(reloadSongJson);
		tab_group_song.add(loadAutosaveBtn);
		tab_group_song.add(loadEventJson);
		tab_group_song.add(stepperBPM);
		tab_group_song.add(stepperSpeed);
		tab_group_song.add(uiManiaStepper);
		tab_group_song.add(convertModeDropDown);
		tab_group_song.add(reloadNotesButton);
		tab_group_song.add(noteSkinInputText);
		tab_group_song.add(noteSplashesInputText);
		tab_group_song.add(new EditorsText(stepperBPM.x, stepperBPM.y - 15, 0, Language.get("newchartEditor_song_bpm_label", "Song BPM:")));
		tab_group_song.add(new EditorsText(stepperSpeed.x, stepperSpeed.y - 15, 0, Language.get("newchartEditor_song_speed_label", "Song Speed:")));
		tab_group_song.add(new EditorsText(uiManiaStepper.x, uiManiaStepper.y - 15, 0, Language.get("newchartEditor_song_keys_label", "Keys (1-18):")));
		tab_group_song.add(new EditorsText(player2DropDown.x, player2DropDown.y - 15, 0, Language.get("newchartEditor_opponent", "Opponent:")));
		tab_group_song.add(new EditorsText(gfVersionDropDown.x, gfVersionDropDown.y - 15, 0, Language.get("newchartEditor_girlfriend", "Girlfriend:")));
		tab_group_song.add(new EditorsText(player1DropDown.x, player1DropDown.y - 15, 0, Language.get("newchartEditor_boyfriend_label", "Boyfriend:")));
		tab_group_song.add(new EditorsText(stageDropDown.x, stageDropDown.y - 15, 0, Language.get("newchartEditor_stage", "Stage:")));
		tab_group_song.add(new EditorsText(noteSkinInputText.x, noteSkinInputText.y - 15, 0, Language.get("newchartEditor_note_texture", "Note Texture:")));
		tab_group_song.add(new EditorsText(noteSplashesInputText.x, noteSplashesInputText.y - 15, 0, Language.get("newchartEditor_note_splashes_texture", "Note Splashes Texture:")));
		tab_group_song.add(player2DropDown);
		tab_group_song.add(gfVersionDropDown);
		tab_group_song.add(player1DropDown);
		tab_group_song.add(stageDropDown);


		FlxG.camera.follow(camPos);
	}

	/** 多k: 按当前键数重建 strum 列 (mania 变化时调用)。 */
	function rebuildStrumNotes():Void
	{
		if (strumLineNotes == null) return;
		strumLineNotes.clear();
		strumLine.makeGraphic(Std.int(GRID_SIZE * curGridCols()), 4);
		for (i in 0...(Note.ammo[getMania()] * 2)){
			var note:StrumNote = new StrumNote(GRID_SIZE * (i+1), strumLine.y, i % Note.ammo[getMania()], 0);
			note.setGraphicSize(GRID_SIZE, GRID_SIZE);
			note.updateHitbox();
			note.playAnim('static', true);
			strumLineNotes.add(note);
			note.scrollFactor.set(1, 1);
		}
	}

	var stepperBeats:PsychUINumericStepper;
	var check_mustHitSection:PsychUICheckBox;
	var check_gfSection:PsychUICheckBox;
	var check_changeBPM:PsychUICheckBox;
	var stepperSectionBPM:PsychUINumericStepper;
	var check_altAnim:PsychUICheckBox;

	var sectionToCopy:Int = 0;
	var notesCopied:Array<Dynamic>;

	function addSectionUI():Void
	{
		var tab_group_section = UI_box.getTab("newchartEditor_section").menu;

		check_mustHitSection = new PsychUICheckBox(10, 15, Language.get("newchartEditor_must_hit_sec", "Must hit section"), 100, null);
		check_mustHitSection.name = 'check_mustHit';
		check_mustHitSection.checked = _song.notes[curSec].mustHitSection;

		check_gfSection = new PsychUICheckBox(10, check_mustHitSection.y + 22, Language.get("newchartEditor_gf_section", "GF section"), 100, null);
		check_gfSection.name = 'check_gf';
		check_gfSection.checked = _song.notes[curSec].gfSection;
		// _song.needsVoices = check_mustHit.checked;

		check_altAnim = new PsychUICheckBox(check_gfSection.x + 120, check_gfSection.y, Language.get("newchartEditor_alt_anim", "Alt Animation"), 100, null);
		check_altAnim.checked = _song.notes[curSec].altAnim;

		stepperBeats = new PsychUINumericStepper(10, 100, 1, 4, 1, 6, 2);
			stepperBeats.textObj.font = 'assets/fonts/editors.ttf';
		stepperBeats.value = getSectionBeats();
		stepperBeats.name = 'section_beats';
		blockPressWhileTypingOnStepper.push(stepperBeats);
		check_altAnim.name = 'check_altAnim';

		check_changeBPM = new PsychUICheckBox(10, stepperBeats.y + 30, Language.get("newchartEditor_change_bpm", "Change BPM"), 100, null);
		check_changeBPM.checked = _song.notes[curSec].changeBPM;
		check_changeBPM.name = 'check_changeBPM';

		stepperSectionBPM = new PsychUINumericStepper(10, check_changeBPM.y + 20, 1, Conductor.bpm, 0, 999, 1);
			stepperSectionBPM.textObj.font = 'assets/fonts/editors.ttf';
		if(check_changeBPM.checked) {
			stepperSectionBPM.value = _song.notes[curSec].bpm;
		} else {
			stepperSectionBPM.value = Conductor.bpm;
		}
		stepperSectionBPM.name = 'section_bpm';
		blockPressWhileTypingOnStepper.push(stepperSectionBPM);

		var check_eventsSec:PsychUICheckBox = null;
		var check_notesSec:PsychUICheckBox = null;
		var copyButton:PsychUIButton = new PsychUIButton(10, 190, Language.get("newchartEditor_copy_section", "Copy Section"), function()
		{
			notesCopied = [];
			sectionToCopy = curSec;
			for (i in 0..._song.notes[curSec].sectionNotes.length)
			{
				var note:Array<Dynamic> = _song.notes[curSec].sectionNotes[i];
				notesCopied.push(note);
			}

			var startThing:Float = sectionStartTime();
			var endThing:Float = sectionStartTime(1);
			for (event in _song.events)
			{
				var strumTime:Float = event[0];
				if(endThing > event[0] && event[0] >= startThing)
				{
					var copiedEventArray:Array<Dynamic> = [];
					for (i in 0...event[1].length)
					{
						var eventToPush:Array<Dynamic> = event[1][i];
						copiedEventArray.push([eventToPush[0], eventToPush[1], eventToPush[2]]);
					}
					notesCopied.push([strumTime, -1, copiedEventArray]);
				}
			}
		});

		copyButton.text.font = 'assets/fonts/editors.ttf';

		var pasteButton:PsychUIButton = new PsychUIButton(copyButton.x + 100, copyButton.y, Language.get("newchartEditor_paste_section", "Paste Section"), function()
		{
			if(notesCopied == null || notesCopied.length < 1)
			{
				return;
			}

			var addToTime:Float = Conductor.stepCrochet * (getSectionBeats() * 4 * (curSec - sectionToCopy));
			//trace('Time to add: ' + addToTime);

			for (note in notesCopied)
			{
				var copiedNote:Array<Dynamic> = [];
				var newStrumTime:Float = note[0] + addToTime;
				if(note[1] < 0)
				{
					if(check_eventsSec.checked)
					{
						var copiedEventArray:Array<Dynamic> = [];
						for (i in 0...note[2].length)
						{
							var eventToPush:Array<Dynamic> = note[2][i];
							copiedEventArray.push([eventToPush[0], eventToPush[1], eventToPush[2]]);
						}
						_song.events.push([newStrumTime, copiedEventArray]);
					}
				}
				else
				{
					if(check_notesSec.checked)
					{
						if(note[4] != null) {
							copiedNote = [newStrumTime, note[1], note[2], note[3], note[4]];
						} else {
							copiedNote = [newStrumTime, note[1], note[2], note[3]];
						}
						_song.notes[curSec].sectionNotes.push(copiedNote);
					}
				}
			}
			updateGrid();
		});

		pasteButton.text.font = 'assets/fonts/editors.ttf';

		var clearSectionButton:PsychUIButton = new PsychUIButton(pasteButton.x + 100, pasteButton.y, Language.get("newchartEditor_clear", "Clear"), function()
		{
			if(check_notesSec.checked)
			{
				_song.notes[curSec].sectionNotes = [];
			}

			if(check_eventsSec.checked)
			{
				var i:Int = _song.events.length - 1;
				var startThing:Float = sectionStartTime();
				var endThing:Float = sectionStartTime(1);
				while(i > -1) {
					var event:Array<Dynamic> = _song.events[i];
					if(event != null && endThing > event[0] && event[0] >= startThing)
					{
						_song.events.remove(event);
					}
					--i;
				}
			}
			updateGrid();
			updateNoteUI();
		});
		clearSectionButton.text.font = 'assets/fonts/editors.ttf';
		clearSectionButton.bg.color = FlxColor.RED;
		clearSectionButton.text.color = FlxColor.WHITE;

		check_notesSec = new PsychUICheckBox(10, clearSectionButton.y + 25, Language.get("newchartEditor_notes", "Notes"), 100, null);
		check_notesSec.checked = true;
		check_eventsSec = new PsychUICheckBox(check_notesSec.x + 100, check_notesSec.y, Language.get("newchartEditor_events_tab", "Events"), 100, null);
		check_eventsSec.checked = true;

		var swapSection:PsychUIButton = new PsychUIButton(10, check_notesSec.y + 40, Language.get("newchartEditor_swap_section", "Swap section"), function()
		{
			for (i in 0..._song.notes[curSec].sectionNotes.length)
			{
				var note:Array<Dynamic> = _song.notes[curSec].sectionNotes[i];
				note[1] = (note[1] + maniaAmmo()) % (maniaAmmo() * 2);
				_song.notes[curSec].sectionNotes[i] = note;
			}
			updateGrid();
		});

		swapSection.text.font = 'assets/fonts/editors.ttf';

		var stepperCopy:PsychUINumericStepper = null;
		var copyLastButton:PsychUIButton = new PsychUIButton(10, swapSection.y + 30, Language.get("newchartEditor_copy_last_section", "Copy last section"), function()
		{
			var value:Int = Std.int(stepperCopy.value);
			if(value == 0) return;

			var daSec = FlxMath.maxInt(curSec, value);

			for (note in _song.notes[daSec - value].sectionNotes)
			{
				var strum = note[0] + Conductor.stepCrochet * (getSectionBeats(daSec) * 4 * value);


				var copiedNote:Array<Dynamic> = [strum, note[1], note[2], note[3]];
				_song.notes[daSec].sectionNotes.push(copiedNote);
			}

			var startThing:Float = sectionStartTime(-value);
			var endThing:Float = sectionStartTime(-value + 1);
			for (event in _song.events)
			{
				var strumTime:Float = event[0];
				if(endThing > event[0] && event[0] >= startThing)
				{
					strumTime += Conductor.stepCrochet * (getSectionBeats(daSec) * 4 * value);
					var copiedEventArray:Array<Dynamic> = [];
					for (i in 0...event[1].length)
					{
						var eventToPush:Array<Dynamic> = event[1][i];
						copiedEventArray.push([eventToPush[0], eventToPush[1], eventToPush[2]]);
					}
					_song.events.push([strumTime, copiedEventArray]);
				}
			}
			updateGrid();
		});
		copyLastButton.text.font = 'assets/fonts/editors.ttf';
		copyLastButton.setGraphicSize(80, 30);
		copyLastButton.updateHitbox();

		stepperCopy = new PsychUINumericStepper(copyLastButton.x + 100, copyLastButton.y, 1, 1, -999, 999, 0);
			stepperCopy.textObj.font = 'assets/fonts/editors.ttf';
		blockPressWhileTypingOnStepper.push(stepperCopy);

		var duetButton:PsychUIButton = new PsychUIButton(10, copyLastButton.y + 45, Language.get("newchartEditor_duet_section", "Duet Notes"), function()
		{
			var duetNotes:Array<Array<Dynamic>> = [];
			for (note in _song.notes[curSec].sectionNotes)
			{
				var boob = note[1];
				if (boob >= maniaAmmo()){
					boob -= maniaAmmo();
				}else{
					boob += maniaAmmo();
				}

				var copiedNote:Array<Dynamic> = [note[0], boob, note[2], note[3]];
				duetNotes.push(copiedNote);
			}

			for (i in duetNotes){
			_song.notes[curSec].sectionNotes.push(i);

			}

			updateGrid();
		});
		duetButton.text.font = 'assets/fonts/editors.ttf';

		var mirrorButton:PsychUIButton = new PsychUIButton(duetButton.x + 100, duetButton.y, Language.get("newchartEditor_mirror_notes", "Mirror Notes"), function()
		{
			var duetNotes:Array<Array<Dynamic>> = [];
			for (note in _song.notes[curSec].sectionNotes)
			{
				var boob = note[1] % maniaAmmo();
				boob = (maniaAmmo() - 1) - boob;
				if (note[1] >= maniaAmmo()) boob += maniaAmmo();

				note[1] = boob;
				var copiedNote:Array<Dynamic> = [note[0], boob, note[2], note[3]];
				//duetNotes.push(copiedNote);
			}

			for (i in duetNotes){
			//_song.notes[curSec].sectionNotes.push(i);

			}

			updateGrid();
		});

		mirrorButton.text.font = 'assets/fonts/editors.ttf';

		tab_group_section.add(new EditorsText(stepperBeats.x, stepperBeats.y - 15, 0, Language.get("newchartEditor_beats_per_section", "Beats per Section:")));
		tab_group_section.add(stepperBeats);
		tab_group_section.add(stepperSectionBPM);
		tab_group_section.add(check_mustHitSection);
		tab_group_section.add(check_gfSection);
		tab_group_section.add(check_altAnim);
		tab_group_section.add(check_changeBPM);
		tab_group_section.add(copyButton);
		tab_group_section.add(pasteButton);
		tab_group_section.add(clearSectionButton);
		tab_group_section.add(check_notesSec);
		tab_group_section.add(check_eventsSec);
		tab_group_section.add(swapSection);
		tab_group_section.add(stepperCopy);
		tab_group_section.add(copyLastButton);
		tab_group_section.add(duetButton);
		tab_group_section.add(mirrorButton);

			}

	var stepperSusLength:PsychUINumericStepper;
	var strumTimeInputText:PsychUIInputText; //I wanted to use a stepper but we can't scale these as far as i know :(
	var noteTypeDropDown:PsychUIDropDownMenu;
	var currentType:Int = 0;

	function addNoteUI():Void
	{
		var tab_group_note = UI_box.getTab("newchartEditor_note").menu;

		stepperSusLength = new PsychUINumericStepper(10, 25, Conductor.stepCrochet / 2, 0, 0, Conductor.stepCrochet * 64);
			stepperSusLength.textObj.font = 'assets/fonts/editors.ttf';
		stepperSusLength.value = 0;
		stepperSusLength.name = 'note_susLength';
		blockPressWhileTypingOnStepper.push(stepperSusLength);

		strumTimeInputText = new PsychUIInputText(10, 65, 180, "0", 8);
		tab_group_note.add(strumTimeInputText);
		blockPressWhileTypingOn.push(strumTimeInputText);

		var key:Int = 0;
		var displayNameList:Array<String> = [];
		while (key < noteTypeList.length) {
			displayNameList.push(noteTypeList[key]);
			noteTypeMap.set(noteTypeList[key], key);
			noteTypeIntMap.set(key, noteTypeList[key]);
			key++;
		}

		#if LUA_ALLOWED
		var directories:Array<String> = [];

		#if MODS_ALLOWED
		directories.push(Paths.mods('custom_notetypes/'));
		directories.push(Paths.mods(Paths.currentModDirectory + '/custom_notetypes/'));
		for(mod in Paths.getGlobalMods())
			directories.push(Paths.mods(mod + '/custom_notetypes/'));
		#end

		for (i in 0...directories.length) {
			var directory:String =  directories[i];
			if(FileSystem.exists(directory)) {
				for (file in FileSystem.readDirectory(directory)) {
					var path = haxe.io.Path.join([directory, file]);
					if (!FileSystem.isDirectory(path) && file.endsWith('.lua')) {
						var fileToCheck:String = file.substr(0, file.length - 4);
						if(!noteTypeMap.exists(fileToCheck)) {
							displayNameList.push(fileToCheck);
							noteTypeMap.set(fileToCheck, key);
							noteTypeIntMap.set(key, fileToCheck);
							key++;
						}
					}
				}
			}
		}
		#end

		for (i in 1...displayNameList.length) {
			displayNameList[i] = i + '. ' + displayNameList[i];
		}

		noteTypeDropDown = new PsychUIDropDownMenu(10, 105, displayNameList, function(index:Int, label:String)
		{
			pushUndo();
			currentType = index;
			markUnsaved();
			if(curSelectedNote != null && curSelectedNote[1] > -1) {
				curSelectedNote[3] = noteTypeIntMap.get(currentType);
				updateGrid();
			}
		});
		noteTypeDropDown.textObj.font = 'assets/fonts/editors.ttf';
			noteTypeDropDown.maxItems = 12;
		blockPressWhileScrolling.push(noteTypeDropDown);

		tab_group_note.add(new EditorsText(10, 10, 0, Language.get("newchartEditor_sustain_length", "Sustain length:")));
		tab_group_note.add(new EditorsText(10, 50, 0, Language.get("newchartEditor_note_hit_time", "Strum time (in miliseconds):")));
		tab_group_note.add(new EditorsText(10, 90, 0, Language.get("newchartEditor_note_type", "Note type:")));
		tab_group_note.add(stepperSusLength);
		tab_group_note.add(strumTimeInputText);
		tab_group_note.add(noteTypeDropDown);

			}

	var eventDropDown:PsychUIDropDownMenu;
	var descText:EditorsText;
	var selectedEventText:FlxText;
	function addEventsUI():Void
	{
		var tab_group_event = UI_box.getTab("newchartEditor_events").menu;

		#if LUA_ALLOWED
		var eventPushedMap:Map<String, Bool> = new Map<String, Bool>();
		var directories:Array<String> = [];

		#if MODS_ALLOWED
		directories.push(Paths.mods('custom_events/'));
		directories.push(Paths.mods(Paths.currentModDirectory + '/custom_events/'));
		for(mod in Paths.getGlobalMods())
			directories.push(Paths.mods(mod + '/custom_events/'));
		#end

		for (i in 0...directories.length) {
			var directory:String =  directories[i];
			if(FileSystem.exists(directory)) {
				for (file in FileSystem.readDirectory(directory)) {
					var path = haxe.io.Path.join([directory, file]);
					if (!FileSystem.isDirectory(path) && file != 'readme.txt' && file.endsWith('.txt')) {
						var fileToCheck:String = file.substr(0, file.length - 4);
						if(!eventPushedMap.exists(fileToCheck)) {
							eventPushedMap.set(fileToCheck, true);
							eventStuff.push([fileToCheck, File.getContent(path)]);
						}
					}
				}
			}
		}
		eventPushedMap.clear();
		eventPushedMap = null;
		#end

		descText = new EditorsText(20, 200, 0, eventStuff[0][0]);

		var leEvents:Array<String> = [];
		for (i in 0...eventStuff.length) {
			leEvents.push(eventStuff[i][0]);
		}

		var text:EditorsText = new EditorsText(20, 30, 0, Language.get("newchartEditor_event", "Event:"));
		tab_group_event.add(text);
		eventDropDown = new PsychUIDropDownMenu(20, 50, leEvents, function(index:Int, label:String) {
			var selectedEvent:Int = index;
			pushUndo();
			markUnsaved();
			descText.text = eventStuff[selectedEvent][1];
				if (curSelectedNote != null &&  eventStuff != null) {
				// 多k: 事件改名 (含改为/改掉 Change Mania) 后按工具箱模式重编码受影响 Note
				var oldEvents:Array<Dynamic> = EKData.deepCopyEvents(_song.events);
				if (curSelectedNote[2] == null){
				curSelectedNote[1][curEventSelected][0] = eventStuff[selectedEvent][0];
				}
				reencodeNotesForEventChange(oldEvents, _song.events, (convertModeDropDown != null) ? convertModeDropDown.selectedIndex : 0);
				reloadGridLayer();
			}
		});
		eventDropDown.maxItems = 12;
		blockPressWhileScrolling.push(eventDropDown);

		var text:EditorsText = new EditorsText(20, 90, 0, Language.get("newchartEditor_value_1", "Value 1:"));
		tab_group_event.add(text);
		value1InputText = new PsychUIInputText(20, 110, 100, "", 8);
		blockPressWhileTypingOn.push(value1InputText);

		var text:EditorsText = new EditorsText(20, 130, 0, Language.get("newchartEditor_value_2", "Value 2:"));
		tab_group_event.add(text);
		value2InputText = new PsychUIInputText(20, 150, 100, "", 8);
		blockPressWhileTypingOn.push(value2InputText);

		// New event buttons (use proper PsychUIButton API and styles)
		var btnSizeX:Int = 20;
		var btnSizeY:Int = 20;
		var removeButton:PsychUIButton = new PsychUIButton(eventDropDown.x + eventDropDown.width + 10, eventDropDown.y, '-', function()
		{
			if(curSelectedNote != null && curSelectedNote[2] == null) //Is event note
			{
				// 多k: 删除子事件前记录事件快照, 删除后按工具箱模式重编码
				var oldEvents:Array<Dynamic> = EKData.deepCopyEvents(_song.events);
				if(curSelectedNote[1].length < 2)
				{
					_song.events.remove(curSelectedNote);
					curSelectedNote = null;
				}
				else
				{
					curSelectedNote[1].remove(curSelectedNote[1][curEventSelected]);
				}

				var eventsGroup:Array<Dynamic>;
				--curEventSelected;
				if(curEventSelected < 0) curEventSelected = 0;
				else if(curSelectedNote != null && curEventSelected >= (eventsGroup = curSelectedNote[1]).length) curEventSelected = eventsGroup.length - 1;

				changeEventSelected();
				reencodeNotesForEventChange(oldEvents, _song.events, (convertModeDropDown != null) ? convertModeDropDown.selectedIndex : 0);
				reloadGridLayer();
			}
		}, btnSizeX, btnSizeY, "editors.ttf", 12);
		removeButton.normalStyle.bgColor = FlxColor.RED;
		removeButton.normalStyle.textColor = FlxColor.WHITE;
		removeButton.resize(btnSizeX, btnSizeY);
				tab_group_event.add(removeButton);

		var addButton:PsychUIButton = new PsychUIButton(removeButton.x + removeButton.width + 10, removeButton.y, '+', function()
		{
			if(curSelectedNote != null && curSelectedNote[2] == null) //Is event note
			{
				var eventsGroup:Array<Dynamic> = curSelectedNote[1];
				eventsGroup.push(['', '', '']);

				changeEventSelected(1);
				updateGrid();
			}
		}, btnSizeX, btnSizeY, "editors.ttf", 12);
		addButton.normalStyle.bgColor = FlxColor.GREEN;
		addButton.normalStyle.textColor = FlxColor.WHITE;
		addButton.resize(btnSizeX, btnSizeY);
				tab_group_event.add(addButton);

		var moveLeftButton:PsychUIButton = new PsychUIButton(addButton.x + addButton.width + 20, addButton.y, '<', function()
		{
			changeEventSelected(-1);
		}, btnSizeX, btnSizeY, "editors.ttf", 12);
		moveLeftButton.resize(btnSizeX, btnSizeY);
				tab_group_event.add(moveLeftButton);

		var moveRightButton:PsychUIButton = new PsychUIButton(moveLeftButton.x + moveLeftButton.width + 10, moveLeftButton.y, '>', function()
		{
			changeEventSelected(1);
		}, btnSizeX, btnSizeY, "editors.ttf", 12);
		moveRightButton.resize(btnSizeX, btnSizeY);
				tab_group_event.add(moveRightButton);

		selectedEventText = new FlxText(addButton.x - 250, addButton.y + addButton.height + 6, (moveRightButton.x - addButton.x) + 186, Language.get("newchartEditor_selected_event_none", "Selected Event: None"));
		selectedEventText.font = 'assets/fonts/editors.ttf';
		selectedEventText.alignment = CENTER;
		tab_group_event.add(selectedEventText);

		tab_group_event.add(descText);
		tab_group_event.add(value1InputText);
		tab_group_event.add(value2InputText);
		tab_group_event.add(eventDropDown);

			}

	function changeEventSelected(change:Int = 0)
	{
		if(curSelectedNote != null && curSelectedNote[2] == null) //Is event note
		{
			curEventSelected += change;
			if(curEventSelected < 0) curEventSelected = Std.int(curSelectedNote[1].length) - 1;
			else if(curEventSelected >= curSelectedNote[1].length) curEventSelected = 0;
			selectedEventText.text = Language.get("newchartEditor_selected_event_format", "Selected Event: ") + (curEventSelected + 1) + ' / ' + curSelectedNote[1].length;
		}
		else
		{
			curEventSelected = 0;
			selectedEventText.text = Language.get("newchartEditor_selected_event_none", "Selected Event: None");
		}
		updateNoteUI();
	}

	var metronome:PsychUICheckBox;
	var mouseScrollingQuant:PsychUICheckBox;
	var metronomeStepper:PsychUINumericStepper;
	var metronomeOffsetStepper:PsychUINumericStepper;
	var disableAutoScrolling:PsychUICheckBox;
	var waveformUseInstrumental:PsychUICheckBox;
	var waveformUseVoices:PsychUICheckBox;
	var instVolume:PsychUINumericStepper;
	var voicesVolume:PsychUINumericStepper;
	var playerVolume:PsychUINumericStepper;
	var opponentVolume:PsychUINumericStepper;
	function addChartingUI() {
		var tab_group_chart = UI_box.getTab("newchartEditor_charting").menu;

		if (FlxG.save.data.chart_waveformInst == null) FlxG.save.data.chart_waveformInst = false;
		if (FlxG.save.data.chart_waveformVoices == null) FlxG.save.data.chart_waveformVoices = false;

		waveformUseInstrumental = new PsychUICheckBox(10, 90, Language.get("newchartEditor_waveform_inst", "Waveform for Instrumental"), 100, null);
		waveformUseInstrumental.checked = FlxG.save.data.chart_waveformInst;
		waveformUseInstrumental.onClick = function()
		{
			waveformUseVoices.checked = false;
			FlxG.save.data.chart_waveformVoices = false;
			FlxG.save.data.chart_waveformInst = waveformUseInstrumental.checked;
			updateWaveform();
		};

		waveformUseVoices = new PsychUICheckBox(waveformUseInstrumental.x + 120, waveformUseInstrumental.y, Language.get("newchartEditor_waveform_voices", "Waveform for Voices"), 100, null);
		waveformUseVoices.checked = FlxG.save.data.chart_waveformVoices;
		waveformUseVoices.onClick = function()
		{
			waveformUseInstrumental.checked = false;
			FlxG.save.data.chart_waveformInst = false;
			FlxG.save.data.chart_waveformVoices = waveformUseVoices.checked;
			updateWaveform();
		};

		check_mute_inst = new PsychUICheckBox(10, 310, Language.get("newchartEditor_mute_inst", "Mute Instrumental (in editor)"), 100, null);
		check_mute_inst.checked = false;
		check_mute_inst.onClick = function()
		{
			var vol:Float = 1;

			if (check_mute_inst.checked)
				vol = 0;

			FlxG.sound.music.volume = vol;
		};
		mouseScrollingQuant = new PsychUICheckBox(10, 200, Language.get("newchartEditor_mouse_scroll_quant", "Mouse Scrolling Quantization"), 100, null);
		if (FlxG.save.data.mouseScrollingQuant == null) FlxG.save.data.mouseScrollingQuant = false;
		mouseScrollingQuant.checked = FlxG.save.data.mouseScrollingQuant;

		mouseScrollingQuant.onClick = function()
		{
			FlxG.save.data.mouseScrollingQuant = mouseScrollingQuant.checked;
			mouseQuant = FlxG.save.data.mouseScrollingQuant;
		};

		check_vortex = new PsychUICheckBox(10, 160, Language.get("newchartEditor_vortex_editor", "Vortex Editor (BETA)"), 100, null);
		if (FlxG.save.data.chart_vortex == null) FlxG.save.data.chart_vortex = false;
		check_vortex.checked = FlxG.save.data.chart_vortex;

		check_vortex.onClick = function()
		{
			FlxG.save.data.chart_vortex = check_vortex.checked;
			vortex = FlxG.save.data.chart_vortex;
			reloadGridLayer();
		};

		check_warnings = new PsychUICheckBox(10, 120, Language.get("newchartEditor_ignore_progress_warnings", "Ignore Progress Warnings"), 100, null);
		if (FlxG.save.data.ignoreWarnings == null) FlxG.save.data.ignoreWarnings = false;
		check_warnings.checked = FlxG.save.data.ignoreWarnings;

		check_warnings.onClick = function()
		{
			FlxG.save.data.ignoreWarnings = check_warnings.checked;
			ignoreWarnings = FlxG.save.data.ignoreWarnings;
		};

		var check_mute_vocals = new PsychUICheckBox(check_mute_inst.x + 120, check_mute_inst.y, Language.get("newchartEditor_mute_vocals", "Mute Vocals (in editor)"), 100, null);
		check_mute_vocals.checked = false;
		check_mute_vocals.onClick = function()
		{
			if(vocals != null) {
				var vol:Float = 1;

				if (check_mute_vocals.checked)
					vol = 0;

				vocals.volume = vol;
			}
		};

		playSoundBf = new PsychUICheckBox(check_mute_inst.x, check_mute_vocals.y + 30, Language.get("newchartEditor_play_sound_bf", "Play Sound (Boyfriend notes)"), 100,
			function() {
				FlxG.save.data.chart_playSoundBf = playSoundBf.checked;
			}
		);
		playSoundBf.text.font = 'assets/fonts/editors.ttf';
		if (FlxG.save.data.chart_playSoundBf == null) FlxG.save.data.chart_playSoundBf = false;
		playSoundBf.checked = FlxG.save.data.chart_playSoundBf;

		playSoundDad = new PsychUICheckBox(check_mute_inst.x + 120, playSoundBf.y, Language.get("newchartEditor_play_sound_dad", "Play Sound (Opponent notes)"), 100,
			function() {
				FlxG.save.data.chart_playSoundDad = playSoundDad.checked;
			}
		);
		playSoundDad.text.font = 'assets/fonts/editors.ttf';
		if (FlxG.save.data.chart_playSoundDad == null) FlxG.save.data.chart_playSoundDad = false;
		playSoundDad.checked = FlxG.save.data.chart_playSoundDad;

		metronome = new PsychUICheckBox(10, 15, Language.get("newchartEditor_metronome_enabled", "Metronome Enabled"), 100,
			function() {
				FlxG.save.data.chart_metronome = metronome.checked;
			}
		);
		metronome.text.font = 'assets/fonts/editors.ttf';
		if (FlxG.save.data.chart_metronome == null) FlxG.save.data.chart_metronome = false;
		metronome.checked = FlxG.save.data.chart_metronome;

		metronomeStepper = new PsychUINumericStepper(15, 55, 5, _song.bpm, 1, 1500, 1);
			metronomeStepper.textObj.font = 'assets/fonts/editors.ttf';
		metronomeOffsetStepper = new PsychUINumericStepper(metronomeStepper.x + 100, metronomeStepper.y, 25, 0, 0, 1000, 1);
			metronomeOffsetStepper.textObj.font = 'assets/fonts/editors.ttf';
		blockPressWhileTypingOnStepper.push(metronomeStepper);
		blockPressWhileTypingOnStepper.push(metronomeOffsetStepper);

		disableAutoScrolling = new PsychUICheckBox(metronome.x + 120, metronome.y, Language.get("newchartEditor_disable_autoscroll", "Disable Autoscroll (Not Recommended)"), 120,
			function() {
				FlxG.save.data.chart_noAutoScroll = disableAutoScrolling.checked;
			}
		);
		disableAutoScrolling.text.font = 'assets/fonts/editors.ttf';
		if (FlxG.save.data.chart_noAutoScroll == null) FlxG.save.data.chart_noAutoScroll = false;
		disableAutoScrolling.checked = FlxG.save.data.chart_noAutoScroll;

		instVolume = new PsychUINumericStepper(metronomeStepper.x, 270, 0.1, 1, 0, 1, 1);
			instVolume.textObj.font = 'assets/fonts/editors.ttf';
		instVolume.value = FlxG.sound.music.volume;
		instVolume.name = 'inst_volume';
		blockPressWhileTypingOnStepper.push(instVolume);

		voicesVolume = new PsychUINumericStepper(instVolume.x + 100, instVolume.y, 0.1, 1, 0, 1, 1);
			voicesVolume.textObj.font = 'assets/fonts/editors.ttf';
		voicesVolume.value = vocals.volume;
		voicesVolume.name = 'voices_volume';
		blockPressWhileTypingOnStepper.push(voicesVolume);

		opponentVolume = new PsychUINumericStepper(voicesVolume.x + 100, instVolume.y, 0.1, 1, 0, 1, 1);
			opponentVolume.textObj.font = 'assets/fonts/editors.ttf';
		opponentVolume.value = opponentVocals.volume;
		opponentVolume.name = 'voices_opponent';
		blockPressWhileTypingOnStepper.push(opponentVolume);
		/*
		playerVolume = new PsychUINumericStepper(opponentVolume.x + 150, opponentVolume.y, 0.1, 1, 0, 1, 1);
		playerVolume.value = vocalsPlayer.volume;
		playerVolume.name = 'voices_player';
		blockPressWhileTypingOnStepper.push(playerVolume);*/

		#if !html5
		sliderRate = new PsychUISlider(120, 120, function(v:Float) { playbackSpeed = v; }, 1, 0.5, 3, 150);
		sliderRate.label = Language.get("newchartEditor_playback_rate", "Playback Rate");
		tab_group_chart.add(sliderRate);
		#end

		tab_group_chart.add(new EditorsText(metronomeStepper.x, metronomeStepper.y - 15, 0, Language.get("newchartEditor_bpm", "BPM:")));
		tab_group_chart.add(new EditorsText(metronomeOffsetStepper.x, metronomeOffsetStepper.y - 15, 0, Language.get("newchartEditor_offset_ms_label", "Offset (ms):")));
		tab_group_chart.add(new EditorsText(instVolume.x, instVolume.y - 15, 0, Language.get("newchartEditor_inst_volume_label", "Inst Volume")));
		tab_group_chart.add(new EditorsText(voicesVolume.x, voicesVolume.y - 15, 0, Language.get("newchartEditor_voices_volume_label", "Voices Volume")));

		tab_group_chart.add(new EditorsText(opponentVolume.x, opponentVolume.y - 15, 0, Language.get("newchartEditor_opponent_voices_volume_label", "Opponent Voices Volume")));
		/*tab_group_chart.add(new EditorsText(playerVolume.x, playerVolume.y - 15, 0, 'Player Voices Volume'));*/
		tab_group_chart.add(metronome);
		tab_group_chart.add(disableAutoScrolling);
		tab_group_chart.add(metronomeStepper);
		tab_group_chart.add(metronomeOffsetStepper);
		tab_group_chart.add(waveformUseInstrumental);
		tab_group_chart.add(waveformUseVoices);
		tab_group_chart.add(instVolume);
		tab_group_chart.add(voicesVolume);


		tab_group_chart.add(opponentVolume);
		/*tab_group_chart.add(playerVolume);*/
		tab_group_chart.add(check_mute_inst);
		tab_group_chart.add(check_mute_vocals);
		tab_group_chart.add(check_vortex);
		tab_group_chart.add(mouseScrollingQuant);
		tab_group_chart.add(check_warnings);
		tab_group_chart.add(playSoundBf);
		tab_group_chart.add(playSoundDad);
			}

	function loadSong():Void
	{
		if (FlxG.sound.music != null)
		{
			FlxG.sound.music.stop();
			// vocals.stop();
		}

		var file:Dynamic = Paths.voices(Paths.formatToSongPath(PlayState.SONG.song));
		vocals = new FlxSound();
		opponentVocals = new FlxSound();
		if (Std.isOfType(file, Sound) || OpenFlAssets.exists(file)) {
			vocals.loadEmbedded(file);
			FlxG.sound.list.add(vocals);
		}
			var bfVocalPath = 'songs/' + Paths.formatToSongPath(PlayState.SONG.song) + '/Voices-Player.ogg';
			var dadVocalPath = 'songs/' + Paths.formatToSongPath(PlayState.SONG.song) + '/Voices-Opponent.ogg';

			#if MODS_ALLOWED
			if (sys.FileSystem.exists(Paths.modFolders(bfVocalPath))) {
				vocals.loadEmbedded(Paths.modFolders(bfVocalPath));
			}
			#end
			if (OpenFlAssets.exists(bfVocalPath)) {
				vocals.loadEmbedded(bfVocalPath);
			}
			#if MODS_ALLOWED
			if (sys.FileSystem.exists(Paths.modFolders(dadVocalPath))) {
				opponentVocals.loadEmbedded(Paths.modFolders(dadVocalPath));
			}
			#end
			if (OpenFlAssets.exists(dadVocalPath)) {
					opponentVocals.loadEmbedded(dadVocalPath);
			}
		FlxG.sound.list.add(opponentVocals);
		generateSong();
		FlxG.sound.music.pause();
		Conductor.songPosition = sectionStartTime();
		FlxG.sound.music.time = Conductor.songPosition;
	}

function generateSong() {
    FlxG.sound.playMusic(Paths.inst(currentSongName), 0.6/*, false*/);
    if (instVolume != null) FlxG.sound.music.volume = instVolume.value;
    if (check_mute_inst != null && check_mute_inst.checked) FlxG.sound.music.volume = 0;
    if (opponentVolume != null) opponentVocals.volume = opponentVolume.value;

    FlxG.sound.music.onComplete = function()
    {
        FlxG.sound.music.pause();
        Conductor.songPosition = 0;
        if(vocals != null) {
            vocals.pause();
            opponentVocals.pause();
            vocals.time = 0;
            opponentVocals.time = 0;
        }
        changeSection();
        curSec = 0;
        updateGrid();
        updateSectionUI();
        vocals.play();
        opponentVocals.play();
    };
}

	public function UIEvent(id:String, sender:Dynamic)
	{
		if (id == PsychUICheckBox.CLICK_EVENT)
		{
			var check:PsychUICheckBox = cast sender;
			switch (check.name)
			{
				case 'check_mustHit':
					pushUndo();
					_song.notes[curSec].mustHitSection = check.checked;
					markUnsaved();

					updateGrid();
					updateHeads();

				case 'check_gf':
					pushUndo();
					_song.notes[curSec].gfSection = check.checked;
					markUnsaved();

					updateGrid();
					updateHeads();

				case 'check_changeBPM':
					pushUndo();
					_song.notes[curSec].changeBPM = check.checked;
					markUnsaved();
				case 'check_altAnim':
					pushUndo();
					_song.notes[curSec].altAnim = check.checked;
					markUnsaved();
			}
		}
		else if (id == PsychUINumericStepper.CHANGE_EVENT && (sender is PsychUINumericStepper))
		{
			var nums:PsychUINumericStepper = cast sender;
			var wname = nums.name;
			FlxG.log.add(wname);
			if (wname == 'section_beats')
			{
				_song.notes[curSec].sectionBeats = nums.value;
				markUnsaved();
				reloadGridLayer();
			}
			else if (wname == 'song_speed')
			{
				_song.speed = nums.value;
				markUnsaved();
			}
			else if (wname == 'mania')
			{
				var newMania:Int = EKData.clampMania(Std.int(nums.value) - 1);
				if (previewMania >= 0) previewMania = -1; // 手动切 K: 退出事件预览模式
				if (newMania == _song.mania) return; // 防抖: 值未变化时不再整表重载
				var oldMania:Int = (_song.mania != null) ? EKData.clampMania(_song.mania) : Note.defaultMania;
				convertChartNoteData(oldMania, newMania, (convertModeDropDown != null) ? convertModeDropDown.selectedIndex : 0);
				_song.mania = newMania;
				markUnsaved();
				TraceManager.info('trace.editor.mania', 'Change mania -> {} (stepper={}) membersBefore={}', [newMania, nums.value, members.length]);
				try
				{
					reloadGridLayer(); // 与 EK 源码一致: 内部同步 PlayState.mania + 重建 strums + updateGrid
				}
				catch (e:Dynamic)
				{
					TraceManager.error('trace.editor.maniaError', '切换键数时出错: {}', [Std.string(e)]);
					rebuildStrumNotes(); // 兜底: 至少保证 strum 数量与键数一致
				}
				TraceManager.info('trace.editor.maniaAfter', 'membersAfter={}', [members.length]);
			}
			else if (wname == 'song_bpm')
			{
				tempBpm = nums.value;
				Conductor.mapBPMChanges(_song);
				Conductor.changeBPM(nums.value);
				markUnsaved();
			}
			else if (wname == 'note_susLength')
			{
				if(curSelectedNote != null && curSelectedNote[2] != null) {
					curSelectedNote[2] = nums.value;
					markUnsaved();
					updateGrid();
				}
			}
			else if (wname == 'section_bpm')
			{
				_song.notes[curSec].bpm = nums.value;
				markUnsaved();
				updateGrid();
			}
			else if (wname == 'inst_volume')
			{
				FlxG.sound.music.volume = nums.value;
			}
			else if (wname == 'voices_volume')
			{
				vocals.volume = nums.value;
			}
			else if (wname == 'voices_opponent')
			{
    		opponentVocals.volume = nums.value;
			}
		}
		else if(id == PsychUIInputText.CHANGE_EVENT && (sender is PsychUIInputText)) {
			if(sender == noteSplashesInputText) {
				_song.splashSkin = noteSplashesInputText.text;
				markUnsaved();
			}
			else if(sender == noteSkinInputText) {
				_song.arrowSkin = noteSkinInputText.text;
				markUnsaved();
			}
			else if(curSelectedNote != null)
			{
				if(sender == value1InputText) {
					if(curSelectedNote[1][curEventSelected] != null)
					{
						curSelectedNote[1][curEventSelected][1] = value1InputText.text;
						// 多k: Change Mania 事件改键数 -> 延迟到输入结束再重编码, 避免逐字符中间态
						if(Std.string(curSelectedNote[1][curEventSelected][0]) == 'Change Mania')
						{
							if(!_pendingManiaReencode) _pendingManiaOldEvents = EKData.deepCopyEvents(_song.events);
							_pendingManiaReencode = true;
						}
						updateGrid();
					}
				}
				else if(sender == value2InputText) {
					if(curSelectedNote[1][curEventSelected] != null)
					{
						curSelectedNote[1][curEventSelected][2] = value2InputText.text;
						updateGrid();
					}
				}
				else if(sender == strumTimeInputText) {
					var value:Float = Std.parseFloat(strumTimeInputText.text);
					if(Math.isNaN(value)) value = 0;
					curSelectedNote[0] = value;
					// 多k: 移动 Change Mania 事件位置 -> 延迟重编码
					if(curSelectedNote[1] != null && curSelectedNote[1].length > 0)
					{
						var subEvents:Array<Dynamic> = cast curSelectedNote[1];
						for (sub in subEvents)
						{
							if(sub != null && Std.string(sub[0]) == 'Change Mania')
							{
								if(!_pendingManiaReencode) _pendingManiaOldEvents = EKData.deepCopyEvents(_song.events);
								_pendingManiaReencode = true;
								break;
							}
						}
					}
					updateGrid();
				}
			}
		}

		// FlxG.log.add(id + " WEED " + sender + " WEED " + data + " WEED " + params);
	}

	var updatedSection:Bool = false;

	function sectionStartTime(add:Int = 0):Float
	{
		var daBPM:Float = _song.bpm;
		var daPos:Float = 0;
		for (i in 0...curSec + add)
		{
			if(_song.notes[i] != null)
			{
				if (_song.notes[i].changeBPM)
				{
					daBPM = _song.notes[i].bpm;
				}
				daPos += getSectionBeats(i) * (1000 * 60 / daBPM);
			}
		}
		return daPos;
	}

	var lastConductorPos:Float;
	var colorSine:Float = 0;

	/** 多k: 计算某时间点应生效的键数 (0 基): 取该时间前最近一次 Change Mania 事件的 k 值。 */
	function computeManiaAtTime(time:Float):Int
	{
		if (_song == null) return Note.defaultMania;
		var base:Int = (_song.mania != null) ? EKData.clampMania(_song.mania) : Note.defaultMania;
		return EKData.effectiveManiaAtTime(_song.events, base, time);
	}

	/**
	 * 多k: 编辑器网格按播放位置动态预览 Change Mania 事件 (预览模式)。
	 * - 事件之前显示谱面基准 k, 经过事件后显示新 k, 回退到事件前自动恢复;
	 * - 只改 previewMania / PlayState.mania 显示, 不修改 _song.mania 谱面数据。
	 */
	function checkManiaEvents():Void
	{
		if (_song == null || FlxG.sound.music == null) return;
		var target:Int = computeManiaAtTime(Conductor.songPosition);
		if (target == getMania()) return; // 显示键数未变化
		previewMania = target;
		PlayState.mania = target;
		var newGridSize:Int = Note.gridSizes[getMania()];
		if (newGridSize != GRID_SIZE)
		{
			// 跨 k 格宽变化时才重建网格 (10K+ 会缩格); 4K<->9K 格宽同为 40, 只重建 strum
			try { reloadGridLayer(); }
			catch (e:Dynamic) { rebuildStrumNotes(); }
		}
		else
		{
			try
			{
				rebuildStrumNotes();
				updateGrid();
			}
			catch (e:Dynamic) {}
		}
		if (uiManiaStepper != null) uiManiaStepper.value = target + 1;
	}

	override function update(elapsed:Float)
	{
		curStep = recalculateSteps();

		// 多k: Change Mania 事件值/时间输入结束后执行一次重编码 + 网格重建
		var focusOnEventInput:Bool = (PsychUIInputText.focusOn == value1InputText
			|| PsychUIInputText.focusOn == value2InputText
			|| PsychUIInputText.focusOn == strumTimeInputText);
		if(focusOnEventInput) _eventInputFocused = true;
		else if(_eventInputFocused)
		{
			_eventInputFocused = false;
			if(_pendingManiaReencode)
			{
				_pendingManiaReencode = false;
				reencodeNotesForEventChange(_pendingManiaOldEvents, _song.events, (convertModeDropDown != null) ? convertModeDropDown.selectedIndex : 0);
				reloadGridLayer();
			}
		}

		if(FlxG.sound.music.time < 0) {
			FlxG.sound.music.pause();
			FlxG.sound.music.time = 0;
		}
		else if(FlxG.sound.music.time > FlxG.sound.music.length) {
			FlxG.sound.music.pause();
			FlxG.sound.music.time = 0;
			changeSection();
		}
		Conductor.songPosition = FlxG.sound.music.time;
		_song.song = UI_songTitle.text;

		// 多k: 播放经过 Change Mania 事件时实时更新网格列数
		checkManiaEvents();

		strumLineUpdateY();
		for (i in 0...(maniaAmmo() * 2)){
			strumLineNotes.members[i].y = strumLine.y;
		}

		FlxG.mouse.visible = true;//cause reasons. trust me
		camPos.y = strumLine.y;
		if(!disableAutoScrolling.checked) {
			// 多k: 滚动到底的判断用当前小节总高度 (含事件切分段)
			if (Math.ceil(strumLine.y) >= chartSectionHeight(curSec))
			{
				if (_song.notes[curSec + 1] == null)
				{
					addSection();
				}

				changeSection(curSec + 1, false);
			} else if(strumLine.y < -10) {
				changeSection(curSec - 1, false);
			}
		}
		FlxG.watch.addQuick('daBeat', curBeat);
		FlxG.watch.addQuick('daStep', curStep);



		if (FlxG.mouse.x > gridBG.x
			// 多k: 点击范围按当前小节最大宽度 (事件后 9K 段比 4K 段宽)
			&& FlxG.mouse.x < gridBG.x + chartSectionWidth(curSec)
			&& FlxG.mouse.y > gridBG.y
			&& FlxG.mouse.y < gridBG.y + (GRID_SIZE * getSectionBeats() * 4) * zoomList[curZoom])
		{
			dummyArrow.visible = true;
			dummyArrow.x = Math.floor(FlxG.mouse.x / GRID_SIZE) * GRID_SIZE;
			if (#if (android || desktop) (virtualPad != null && virtualPad.buttonY.pressed) || #end FlxG.keys.pressed.SHIFT)
				dummyArrow.y = FlxG.mouse.y;
			else
			{
				var gridmult = GRID_SIZE / (quantization / 16);
				dummyArrow.y = Math.floor(FlxG.mouse.y / gridmult) * gridmult;
			}
		} else {
			dummyArrow.visible = false;
		}

		if (FlxG.mouse.justPressed
			#if (android || desktop)
			&& !(virtualPad != null && virtualPad.isMouseOverAnyButton())
			#end
		)
		{
			if (FlxG.mouse.overlaps(curRenderedNotes))
			{
				curRenderedNotes.forEachAlive(function(note:Note)
				{
					if (FlxG.mouse.overlaps(note))
					{
						if (#if (android || desktop) (virtualPad != null && virtualPad.buttonF.pressed) || #end FlxG.keys.pressed.CONTROL)
						{
							selectNote(note);
						}
						else if (FlxG.keys.pressed.ALT)
						{
							selectNote(note);
							curSelectedNote[3] = noteTypeIntMap.get(currentType);
							updateGrid();
						}
						else
						{
							#if android
							// Android long-press: start timer instead of immediate delete
							_longPressNote = note;
							_longPressTimer = 0;
							#else
							deleteNote(note);
							#end
						}
					}
				});
			}
			else #if (android || desktop) if(virtualPad == null || !virtualPad.buttonF.pressed) #end
			{
				if (FlxG.mouse.x > gridBG.x
					// 多k: 点击范围按当前小节最大宽度
					&& FlxG.mouse.x < gridBG.x + chartSectionWidth(curSec)
					&& FlxG.mouse.y > gridBG.y
					&& FlxG.mouse.y < gridBG.y + (GRID_SIZE * getSectionBeats() * 4) * zoomList[curZoom])
				{
					FlxG.log.add('added note');
					addNote();
				}
			}
		}

		var blockInput:Bool = false;
		for (inputText in blockPressWhileTypingOn) {
			if(PsychUIInputText.focusOn == inputText) {
				FlxG.sound.muteKeys = [];
				FlxG.sound.volumeDownKeys = [];
				FlxG.sound.volumeUpKeys = [];
				blockInput = true;
				break;
			}
		}

		if(!blockInput) {
			for (stepper in blockPressWhileTypingOnStepper) {
				// removed: text_field access
				if(PsychUIInputText.focusOn == stepper) {
					FlxG.sound.muteKeys = [];
					FlxG.sound.volumeDownKeys = [];
					FlxG.sound.volumeUpKeys = [];
					blockInput = true;
					break;
				}
			}
		}

		if(!blockInput) {
			FlxG.sound.muteKeys = TitleState.muteKeys;
			FlxG.sound.volumeDownKeys = TitleState.volumeDownKeys;
			FlxG.sound.volumeUpKeys = TitleState.volumeUpKeys;
			if(PsychUIDropDownMenu.anyDropdownOpen) {
				blockInput = true;
			}
		}

		if (!blockInput)
		{
			if (#if (android || desktop) (virtualPad != null && virtualPad.buttonC.justPressed) || #end FlxG.keys.justPressed.ESCAPE)
			{
				confirmPreview();
			}
			if (#if (android || desktop) (virtualPad != null && virtualPad.buttonA.justPressed) || #end FlxG.keys.justPressed.ENTER)
			{
				confirmPlaytest();
			}

			if(curSelectedNote != null && curSelectedNote[1] > -1) {
				if (#if (android || desktop) (virtualPad != null && virtualPad.buttonDown2.justPressed) || #end FlxG.keys.justPressed.E)
				{
					changeNoteSustain(Conductor.stepCrochet);
				}
				if (#if (android || desktop) (virtualPad != null && virtualPad.buttonUp2.justPressed) || #end FlxG.keys.justPressed.Q)
				{
					changeNoteSustain(-Conductor.stepCrochet);
				}
			}


			if (#if (android || desktop) (virtualPad != null && virtualPad.buttonB.justPressed) ||#end FlxG.keys.justPressed.BACKSPACE) {
				confirmExit();
				return;
			}

			if(#if (android || desktop) (virtualPad != null && virtualPad.buttonZ.justPressed) ||#end (FlxG.keys.justPressed.Z && FlxG.keys.pressed.CONTROL)) {
				undo();
			}
			if (FlxG.keys.justPressed.Y && FlxG.keys.pressed.CONTROL) {
				redo();
			}

			if (FlxG.keys.justPressed.Z && curZoom > 0 && !FlxG.keys.pressed.CONTROL) {
				--curZoom;
				updateZoom();
			}
			if ((#if (android || desktop) (virtualPad != null && virtualPad.buttonD.justPressed) || #end FlxG.keys.justPressed.X) && curZoom < zoomList.length-1) {
				curZoom++;
				updateZoom();
			}

			if (FlxG.keys.justPressed.TAB)
			{
				if (FlxG.keys.pressed.SHIFT)
				{
					UI_box.selectedIndex -= 1;
					if (UI_box.selectedIndex < 0)
						UI_box.selectedIndex = UI_box.tabs.length - 1;
				}
				else
				{
					UI_box.selectedIndex += 1;
					if (UI_box.selectedIndex >= UI_box.tabs.length)
						UI_box.selectedIndex = 0;
				}
			}

			if (#if (android || desktop) (virtualPad != null && virtualPad.buttonX.justPressed) || #end FlxG.keys.justPressed.SPACE)
			{
				if (FlxG.sound.music.playing)
				{
					FlxG.sound.music.pause();
					if(vocals != null) vocals.pause();
					if(opponentVocals != null) opponentVocals.pause();
				}
				else
				{
					if(vocals != null) {
						vocals.play();
						vocals.pause();
						vocals.time = FlxG.sound.music.time;
						vocals.play();
					}
					if(opponentVocals != null) {
						opponentVocals.play();
						opponentVocals.pause();
						opponentVocals.time = FlxG.sound.music.time;
						opponentVocals.play();
					}
					FlxG.sound.music.play();
				}
			}

			if (!FlxG.keys.pressed.ALT && (#if (android || desktop) (virtualPad != null && virtualPad.buttonV.justPressed) || #end FlxG.keys.justPressed.R))
			{
				if (FlxG.keys.pressed.SHIFT)
					resetSection(true);
				else
					resetSection();
			}

			if (FlxG.mouse.wheel != 0)
			{
				FlxG.sound.music.pause();
				if (!mouseQuant)
					FlxG.sound.music.time -= (FlxG.mouse.wheel * Conductor.stepCrochet*0.8);
				else
					{
						var time:Float = FlxG.sound.music.time;
						var beat:Float = curDecBeat;
						var snap:Float = quantization / 4;
						var increase:Float = 1 / snap;
						if (FlxG.mouse.wheel > 0)
						{
							var fuck:Float = CoolUtil.quantize(beat, snap) - increase;
							FlxG.sound.music.time = Conductor.beatToSeconds(fuck);
						}else{
							var fuck:Float = CoolUtil.quantize(beat, snap) + increase;
							FlxG.sound.music.time = Conductor.beatToSeconds(fuck);
						}
					}
				if(vocals != null) {
					vocals.pause();
					vocals.time = FlxG.sound.music.time;
				}
				if(opponentVocals != null){
					opponentVocals.pause();
					opponentVocals.time = FlxG.sound.music.time;
				}
			}

			//ARROW VORTEX SHIT NO DEADASS



			if ((FlxG.keys.pressed.W || FlxG.keys.pressed.S) #if (android || desktop) || (virtualPad != null && (virtualPad.buttonUp.pressed || virtualPad.buttonDown.pressed)) #end)
			{
				FlxG.sound.music.pause();

				var holdingShift:Float = 1;
				if (FlxG.keys.pressed.CONTROL) holdingShift = 0.25;
				else if (#if (android || desktop) (virtualPad != null && virtualPad.buttonY.pressed) || #end FlxG.keys.pressed.SHIFT) holdingShift = 4;

				var daTime:Float = 700 * FlxG.elapsed * holdingShift;

				if (#if (android || desktop) (virtualPad != null && virtualPad.buttonUp.pressed) ||#end FlxG.keys.pressed.W)
				{
					FlxG.sound.music.time -= daTime;
				}
				else
					FlxG.sound.music.time += daTime;

				if(vocals != null) {
					vocals.pause();
					vocals.time = FlxG.sound.music.time;
				}
				if(opponentVocals != null) {
					opponentVocals.pause();
					opponentVocals.time = FlxG.sound.music.time;
				}
			}

			if(!vortex){
				if (FlxG.keys.justPressed.UP || FlxG.keys.justPressed.DOWN  )
				{
					FlxG.sound.music.pause();
					updateCurStep();
					var time:Float = FlxG.sound.music.time;
					var beat:Float = curDecBeat;
					var snap:Float = quantization / 4;
					var increase:Float = 1 / snap;
					if (FlxG.keys.pressed.UP)
					{
						var fuck:Float = CoolUtil.quantize(beat, snap) - increase; //(Math.floor((beat+snap) / snap) * snap);
						FlxG.sound.music.time = Conductor.beatToSeconds(fuck);
					}else{
						var fuck:Float = CoolUtil.quantize(beat, snap) + increase; //(Math.floor((beat+snap) / snap) * snap);
						FlxG.sound.music.time = Conductor.beatToSeconds(fuck);
					}
				}
			}

			var style = currentType;

			if (#if (android || desktop) (virtualPad != null && virtualPad.buttonY.pressed) || #end FlxG.keys.pressed.SHIFT){
				style = 3;
			}

			var conductorTime = Conductor.songPosition; //+ sectionStartTime();Conductor.songPosition / Conductor.stepCrochet;

			//AWW YOU MADE IT SEXY <3333 THX SHADMAR

			if(!blockInput){
				if(FlxG.keys.justPressed.RIGHT #if (android || desktop) || (virtualPad != null && virtualPad.buttonG.pressed && virtualPad.buttonRight.justPressed) #end){
					curQuant++;
					if(curQuant>quantizations.length-1)
						curQuant = 0;

					quantization = quantizations[curQuant];
				}

				if(FlxG.keys.justPressed.LEFT #if (android || desktop) || (virtualPad != null && virtualPad.buttonG.pressed && virtualPad.buttonLeft.justPressed) #end){
					curQuant--;
					if(curQuant<0)
						curQuant = quantizations.length-1;

					quantization = quantizations[curQuant];
				}
				quant.animation.play('q', true, false, curQuant);
			}
			if(vortex && !blockInput){
				var controlArray:Array<Bool> = [FlxG.keys.justPressed.ONE, FlxG.keys.justPressed.TWO, FlxG.keys.justPressed.THREE, FlxG.keys.justPressed.FOUR,
											   FlxG.keys.justPressed.FIVE, FlxG.keys.justPressed.SIX, FlxG.keys.justPressed.SEVEN, FlxG.keys.justPressed.EIGHT];

				if(controlArray.contains(true))
				{
					for (i in 0...controlArray.length)
					{
						if(controlArray[i])
							doANoteThing(conductorTime, i, style);
					}
				}

				var feces:Float;
				if (FlxG.keys.justPressed.UP || FlxG.keys.justPressed.DOWN  )
				{
					FlxG.sound.music.pause();


					updateCurStep();
					//FlxG.sound.music.time = (Math.round(curStep/quants[curQuant])*quants[curQuant]) * Conductor.stepCrochet;

						//(Math.floor((curStep+quants[curQuant]*1.5/(quants[curQuant]/2))/quants[curQuant])*quants[curQuant]) * Conductor.stepCrochet;//snap into quantization
					var time:Float = FlxG.sound.music.time;
					var beat:Float = curDecBeat;
					var snap:Float = quantization / 4;
					var increase:Float = 1 / snap;
					if (FlxG.keys.pressed.UP)
					{
						var fuck:Float = CoolUtil.quantize(beat, snap) - increase;
						feces = Conductor.beatToSeconds(fuck);
					}else{
						var fuck:Float = CoolUtil.quantize(beat, snap) + increase; //(Math.floor((beat+snap) / snap) * snap);
						feces = Conductor.beatToSeconds(fuck);
					}
					FlxTween.tween(FlxG.sound.music, {time:feces}, 0.1, {ease:FlxEase.circOut});
					if(vocals != null) {
						vocals.pause();
						vocals.time = FlxG.sound.music.time;
					}
					if(opponentVocals != null) {
						opponentVocals.pause();
						opponentVocals.time = FlxG.sound.music.time;
					}

					var dastrum = 0;

					if (curSelectedNote != null){
						dastrum = curSelectedNote[0];
					}

					var secStart:Float = sectionStartTime();
					var datime = (feces - secStart) - (dastrum - secStart); //idk math find out why it doesn't work on any other section other than 0
					if (curSelectedNote != null)
					{
						var controlArray:Array<Bool> = [FlxG.keys.pressed.ONE, FlxG.keys.pressed.TWO, FlxG.keys.pressed.THREE, FlxG.keys.pressed.FOUR,
													   FlxG.keys.pressed.FIVE, FlxG.keys.pressed.SIX, FlxG.keys.pressed.SEVEN, FlxG.keys.pressed.EIGHT];

						if(controlArray.contains(true))
						{

							for (i in 0...controlArray.length)
							{
								if(controlArray[i])
									if(curSelectedNote[1] == i) curSelectedNote[2] += datime - curSelectedNote[2] - Conductor.stepCrochet;
							}
							updateGrid();
							updateNoteUI();
						}
					}
				}
			}
			var shiftThing:Int = 1;
			if (#if (android || desktop) (virtualPad != null && virtualPad.buttonY.pressed) || #end FlxG.keys.pressed.SHIFT)
				shiftThing = 4;

			if ((#if (android || desktop) (virtualPad != null && virtualPad.buttonRight.justPressed && !virtualPad.buttonG.pressed) || #end FlxG.keys.justPressed.D))
				changeSection(curSec + shiftThing);
			if ((#if (android || desktop) (virtualPad != null && virtualPad.buttonLeft.justPressed && !virtualPad.buttonG.pressed) ||#end FlxG.keys.justPressed.A)) {
				if(curSec <= 0) {
					changeSection(_song.notes.length-1);
				} else {
					changeSection(curSec - shiftThing);
				}
			}
		} else if (FlxG.keys.justPressed.ENTER) {
			for (i in 0...blockPressWhileTypingOn.length) {
				if(PsychUIInputText.focusOn == blockPressWhileTypingOn[i]) {
					PsychUIInputText.focusOn = null;
				}
			}
		}

		_song.bpm = tempBpm;

		strumLineNotes.visible = quant.visible = vortex;

		if(FlxG.sound.music.time < 0) {
			FlxG.sound.music.pause();
			FlxG.sound.music.time = 0;
		}
		else if(FlxG.sound.music.time > FlxG.sound.music.length) {
			FlxG.sound.music.pause();
			FlxG.sound.music.time = 0;
			changeSection();
		}
		Conductor.songPosition = FlxG.sound.music.time;
		strumLineUpdateY();
		camPos.y = strumLine.y;
		for (i in 0...(maniaAmmo() * 2)){
			strumLineNotes.members[i].y = strumLine.y;
			strumLineNotes.members[i].alpha = FlxG.sound.music.playing ? 1 : 0.35;
		}

		// PLAYBACK SPEED CONTROLS //
		var holdingShift = FlxG.keys.pressed.SHIFT;
		var holdingLB = FlxG.keys.pressed.LBRACKET;
		var holdingRB = FlxG.keys.pressed.RBRACKET;
		var pressedLB = FlxG.keys.justPressed.LBRACKET;
		var pressedRB = FlxG.keys.justPressed.RBRACKET;

		if (!holdingShift && pressedLB || holdingShift && holdingLB)
			playbackSpeed -= 0.01;
		if (!holdingShift && pressedRB || holdingShift && holdingRB)
			playbackSpeed += 0.01;
		if (#if (android || desktop) (virtualPad != null && virtualPad.buttonG.justPressed) || #end (FlxG.keys.pressed.ALT && (pressedLB || pressedRB || holdingLB || holdingRB)))
			playbackSpeed = 1;
		//

		if (playbackSpeed <= 0.5)
			playbackSpeed = 0.5;
		if (playbackSpeed >= 3)
			playbackSpeed = 3;

		FlxG.sound.music.pitch = playbackSpeed;
		vocals.pitch = playbackSpeed;
		opponentVocals.pitch = playbackSpeed;

		bpmTxt.text =
		Std.string(FlxMath.roundDecimal(Conductor.songPosition / 1000, 2)) + " / " + Std.string(FlxMath.roundDecimal(FlxG.sound.music.length / 1000, 2)) +
		"\nSection: " + curSec +
		"\n\nBeat: " + Std.string(curDecBeat).substring(0,4) +
		"\n\nStep: " + curStep +
		"\n\nBeat Snap: " + quantization + "th";

		var playedSound:Array<Bool> = [false, false, false, false]; //Prevents ouchy GF sex sounds
		curRenderedNotes.forEachAlive(function(note:Note) {
			note.alpha = 1;
			if(curSelectedNote != null) {
			var noteDataToCheck:Int = note.noteData;
			if(noteDataToCheck > -1 && note.mustPress != _song.notes[curSec].mustHitSection) noteDataToCheck += maniaAmmo();

				if (curSelectedNote[0] == note.strumTime && ((curSelectedNote[2] == null && noteDataToCheck < 0) || (curSelectedNote[2] != null && curSelectedNote[1] == noteDataToCheck)))
				{
					colorSine += elapsed;
					var colorVal:Float = 0.7 + Math.sin(Math.PI * colorSine) * 0.3;
					note.color = FlxColor.fromRGBFloat(colorVal, colorVal, colorVal, 0.999); //Alpha can't be 100% or the color won't be updated for some reason, guess i will die
				}
			}

			if(note.strumTime <= Conductor.songPosition) {
				note.alpha = 0.4;
				if(note.strumTime > lastConductorPos && FlxG.sound.music.playing && note.noteData > -1) {
					var data:Int = note.noteData % maniaAmmo();
					var noteDataToCheck:Int = note.noteData;
					if(noteDataToCheck > -1 && note.mustPress != _song.notes[curSec].mustHitSection) noteDataToCheck += maniaAmmo();
						strumLineNotes.members[noteDataToCheck].playAnim('confirm', true);
						strumLineNotes.members[noteDataToCheck].resetAnim = (note.sustainLength / 1000) + 0.15;
					if(!playedSound[data]) {
						if((playSoundBf.checked && note.mustPress) || (playSoundDad.checked && !note.mustPress)){
							var soundToPlay = 'hitsound';
							if(_song.player1 == 'gf') { //Easter egg
								soundToPlay = 'GF_' + Std.string(data + 1);
							}

							FlxG.sound.play(Paths.sound(soundToPlay)).pan = note.noteData < 4? -0.3 : 0.3; //would be coolio
							playedSound[data] = true;
						}

						data = note.noteData;
						if(note.mustPress != _song.notes[curSec].mustHitSection)
						{
							data += 4;
						}
					}
				}
			}
		});

		if(metronome.checked && lastConductorPos != Conductor.songPosition) {
			var metroInterval:Float = 60 / metronomeStepper.value;
			var metroStep:Int = Math.floor(((Conductor.songPosition + metronomeOffsetStepper.value) / metroInterval) / 1000);
			var lastMetroStep:Int = Math.floor(((lastConductorPos + metronomeOffsetStepper.value) / metroInterval) / 1000);
			if(metroStep != lastMetroStep) {
				FlxG.sound.play(Paths.sound('Metronome_Tick'));
				//trace('Ticked');
			}
		}
		lastConductorPos = Conductor.songPosition;

		#if android
		// Android long-press: hold finger on a note > 0.4s → select it (like Ctrl+Click)
		if (_longPressNote != null)
		{
			if (FlxG.mouse.justReleased)
			{
				if (curRenderedNotes.members.contains(_longPressNote))
					deleteNote(_longPressNote);
				_longPressNote = null;
			}
			else if (FlxG.mouse.pressed && FlxG.mouse.overlaps(_longPressNote))
			{
				_longPressTimer += elapsed;
				if (_longPressTimer >= _longPressThreshold)
				{
					if (curRenderedNotes.members.contains(_longPressNote))
						selectNote(_longPressNote);
					_longPressNote = null;
				}
			}
			else
			{
				_longPressNote = null;
			}
		}
		#end

		super.update(elapsed);
	}

	function updateZoom() {
		if (curZoom < 0) curZoom = 0;
		if (curZoom >= zoomList.length) curZoom = zoomList.length - 1;
		
		var daZoom:Float = zoomList[curZoom];
		var zoomThing:String = '1 / ' + daZoom;
		if(daZoom < 1) zoomThing = Math.round(1 / daZoom) + ' / 1';
		zoomTxt.text = 'Zoom: ' + zoomThing;
		reloadGridLayer();
	}

	/*
	function loadAudioBuffer() {
		if(audioBuffers[0] != null) {
			audioBuffers[0].dispose();
		}
		audioBuffers[0] = null;
		#if MODS_ALLOWED
		if(FileSystem.exists(Paths.modFolders('songs/' + currentSongName + '/Inst.ogg'))) {
			audioBuffers[0] = AudioBuffer.fromFile(Paths.modFolders('songs/' + currentSongName + '/Inst.ogg'));
			//trace('Custom vocals found');
		}
		else { #end
			var leVocals:String = Paths.getPath(currentSongName + '/Inst.' + Paths.SOUND_EXT, SOUND, 'songs');
			if (OpenFlAssets.exists(leVocals)) { //Vanilla inst
				audioBuffers[0] = AudioBuffer.fromFile('./' + leVocals.substr(6));
				//trace('Inst found');
			}
		#if MODS_ALLOWED
		}
		#end

		if(audioBuffers[1] != null) {
			audioBuffers[1].dispose();
		}
		audioBuffers[1] = null;
		#if MODS_ALLOWED
		if(FileSystem.exists(Paths.modFolders('songs/' + currentSongName + '/Voices.ogg'))) {
			audioBuffers[1] = AudioBuffer.fromFile(Paths.modFolders('songs/' + currentSongName + '/Voices.ogg'));
			//trace('Custom vocals found');
		} else { #end
			var leVocals:String = Paths.getPath(currentSongName + '/Voices.' + Paths.SOUND_EXT, SOUND, 'songs');
			if (OpenFlAssets.exists(leVocals)) { //Vanilla voices
				audioBuffers[1] = AudioBuffer.fromFile('./' + leVocals.substr(6));
				//trace('Voices found, LETS FUCKING GOOOO');
			}
		#if MODS_ALLOWED
		}
		#end
	}
	*/

	var lastSecBeats:Float = 0;
	var lastSecBeatsNext:Float = 0;

	// Reusable pool of grid decoration sprites to avoid new Sprite in reloadGridLayer
	var _gridDecor:Array<FlxSprite> = [];
	var _gridDecorUsed:Int = 0;
	/** 多k: 小节内 Change Mania 事件切分出的额外网格段 (每次 reloadGridLayer 重建时销毁)。 */
	var _gridSegSprites:Array<FlxSprite> = [];
	/** 多k: 网格视觉是为哪个 curSec 构建的 (切节后重建分段/列数)。 */
	var _lastGridSec:Int = -999;

	function allocGridDecor():FlxSprite
	{
		if(_gridDecorUsed < _gridDecor.length)
		{
			var s = _gridDecor[_gridDecorUsed++];
			s.visible = true;
			return s;
		}
		var s = new FlxSprite();
		_gridDecor.push(s);
		_gridDecorUsed++;
		return s;
	}

	/** 多k: 为某小节的额外事件分段创建网格精灵 (段 0 已由 gridBG/nextGridBG 承担)。 */
	function buildChartSegments(segs:Array<{startStep:Int, k:Int}>, steps:Int, baseY:Int):Void
	{
		for (i in 1...segs.length)
		{
			var segEnd:Int = (i + 1 < segs.length) ? segs[i + 1].startStep : steps;
			var h:Int = Std.int((segEnd - segs[i].startStep) * GRID_SIZE * zoomList[curZoom]);
			var sp:FlxSprite = FlxGridOverlay.create(GRID_SIZE, GRID_SIZE, GRID_SIZE * (Note.ammo[segs[i].k] * 2 + 1), h);
			sp.y = baseY + segs[i].startStep * GRID_SIZE * zoomList[curZoom];
			_gridSegSprites.push(sp);
			gridLayer.add(sp);
		}
	}

	function reloadGridLayer() {
		// 多k: 网格格宽随 k 值缩小 (1K~18K 都塞得下)
		GRID_SIZE = Note.gridSizes[getMania()];
		PlayState.mania = getMania(); // 与 EK 源码一致: reloadGridLayer 内同步 mania

		rebuildStrumNotes();
		rebuildGridVisuals();

		updateGrid();

		lastSecBeats = getSectionBeats();
		lastSecBeatsNext = (sectionStartTime(1) > FlxG.sound.music.length) ? 0 : getSectionBeats(curSec + 1);
		_lastGridSec = curSec;
	}

	/** 多k: 重建网格本体 (当前/下一小节主网格 + 事件 Step 分段 + 分隔线), 不碰 strum/音符。 */
	function rebuildGridVisuals():Void
	{
		gridLayer.clear();
		for (sp in _gridSegSprites)
			if (sp != null) sp.destroy();
		_gridSegSprites = [];

		// 主网格
		// 多k: 网格列数按 Change Mania 事件逐 Step 切分: 事件前 4K 网格, 事件后 9K 网格
		var curSegs:Array<{startStep:Int, k:Int}> = chartSectionSegments(curSec);
		var nextSegs:Array<{startStep:Int, k:Int}> = chartSectionSegments(curSec + 1);
		var curSteps:Int = chartSectionSteps(curSec);
		var nextSteps:Int = chartSectionSteps(curSec + 1);
		var curMainRows:Int = (curSegs.length > 1) ? curSegs[1].startStep : curSteps;
		gridBG = FlxGridOverlay.create(GRID_SIZE, GRID_SIZE, GRID_SIZE * (Note.ammo[curSegs[0].k] * 2 + 1), Std.int(curMainRows * GRID_SIZE * zoomList[curZoom]));

		if(FlxG.save.data.chart_waveformInst || FlxG.save.data.chart_waveformVoices)
			updateWaveform();

		var leHeight:Int = chartSectionHeight(curSec);
		var foundNextSec:Bool = false;
		if(sectionStartTime(1) <= FlxG.sound.music.length)
		{
			var nextMainRows:Int = (nextSegs.length > 1) ? nextSegs[1].startStep : nextSteps;
			nextGridBG = FlxGridOverlay.create(GRID_SIZE, GRID_SIZE, GRID_SIZE * (Note.ammo[nextSegs[0].k] * 2 + 1), Std.int(nextMainRows * GRID_SIZE * zoomList[curZoom]));
			leHeight += chartSectionHeight(curSec + 1);
			foundNextSec = true;
		}
		else {
			nextGridBG = new FlxSprite().makeGraphic(1, 1, FlxColor.TRANSPARENT);
		}
		nextGridBG.y = chartSectionHeight(curSec);

		gridLayer.add(nextGridBG);
		gridLayer.add(gridBG);

		// Reuse decoration sprites from pool
		_gridDecorUsed = 0;

		// 多k: 当前小节内事件之后的 Step 段, 用新键数网格列数单独绘制
		buildChartSegments(curSegs, curSteps, 0);

		// 多k: 下一小节的事件分段 + 淡色遮罩
		if(foundNextSec)
		{
			buildChartSegments(nextSegs, nextSteps, Std.int(nextGridBG.y));
			for (i => seg in nextSegs)
			{
				var segEnd:Int = (i + 1 < nextSegs.length) ? nextSegs[i + 1].startStep : nextSteps;
				var s = allocGridDecor();
				s.makeGraphic(GRID_SIZE * (Note.ammo[seg.k] * 2 + 1), Std.int((segEnd - seg.startStep) * GRID_SIZE * zoomList[curZoom]), FlxColor.BLACK);
				s.alpha = 0.4;
				s.setPosition(0, Std.int(nextGridBG.y) + seg.startStep * GRID_SIZE * zoomList[curZoom]);
				gridLayer.add(s);
			}
		}

		// 多k: 玩家-对手分隔线: 每段一条, 按各段键数 (事件前 4K 段与事件后 9K 段位置不同)
		for (i => seg in curSegs)
		{
			var segEnd:Int = (i + 1 < curSegs.length) ? curSegs[i + 1].startStep : curSteps;
			var s = allocGridDecor();
			s.makeGraphic(2, Std.int((segEnd - seg.startStep) * GRID_SIZE * zoomList[curZoom]), FlxColor.BLACK);
			s.setPosition(gridBG.x + GRID_SIZE * (Note.ammo[seg.k] + 1), seg.startStep * GRID_SIZE * zoomList[curZoom]);
			gridLayer.add(s);
		}
		for (i => seg in nextSegs)
		{
			var segEnd:Int = (i + 1 < nextSegs.length) ? nextSegs[i + 1].startStep : nextSteps;
			var s = allocGridDecor();
			s.makeGraphic(2, Std.int((segEnd - seg.startStep) * GRID_SIZE * zoomList[curZoom]), FlxColor.BLACK);
			s.setPosition(gridBG.x + GRID_SIZE * (Note.ammo[seg.k] + 1), Std.int(nextGridBG.y) + seg.startStep * GRID_SIZE * zoomList[curZoom]);
			gridLayer.add(s);
		}

		if(vortex) for (i in 1...maniaAmmo()) {
			var s = allocGridDecor();
			s.makeGraphic(chartSectionWidth(curSec), 1, 0x44FF0000);
			s.setPosition(gridBG.x, (GRID_SIZE * (4 * curZoom)) * i);
			gridLayer.add(s);
		}

		var s = allocGridDecor();
		s.makeGraphic(2, leHeight, FlxColor.BLACK);
		s.setPosition(gridBG.x + GRID_SIZE, 0);
		gridLayer.add(s);

		// Hide unused decoration sprites
		for (i in _gridDecorUsed..._gridDecor.length)
			_gridDecor[i].visible = false;
	}

	function strumLineUpdateY()
	{
		strumLine.y = getYfromStrum((Conductor.songPosition - sectionStartTime()) / zoomList[curZoom] % (Conductor.stepCrochet * 16)) / (getSectionBeats() / 4);
	}

	var waveformPrinted:Bool = true;
	var wavData:Array<Array<Array<Float>>> = [[[0], [0]], [[0], [0]]];
	function updateWaveform() {
		if(waveformPrinted) {
			// 多k: 波形按当前小节总高度/最大宽度
			waveformSprite.makeGraphic(Std.int(GRID_SIZE * maniaAmmo() * 2), chartSectionHeight(curSec), 0x00FFFFFF);
			waveformSprite.pixels.fillRect(new Rectangle(0, 0, chartSectionWidth(curSec), chartSectionHeight(curSec)), 0x00FFFFFF);
		}
		waveformPrinted = false;

		if(!FlxG.save.data.chart_waveformInst && !FlxG.save.data.chart_waveformVoices) {
			//trace('Epic fail on the waveform lol');
			return;
		}

		wavData[0][0] = [];
		wavData[0][1] = [];
		wavData[1][0] = [];
		wavData[1][1] = [];

		var steps:Int = Math.round(getSectionBeats() * 4);
		var st:Float = sectionStartTime();
		var et:Float = st + (Conductor.stepCrochet * steps);

		if (FlxG.save.data.chart_waveformInst) {
			var sound:FlxSound = FlxG.sound.music;
			if (sound._sound != null && sound._sound.__buffer != null) {
				var bytes:Bytes = sound._sound.__buffer.data.toBytes();

				wavData = waveformData(
					sound._sound.__buffer,
					bytes,
					st,
					et,
					1,
					wavData,
					chartSectionHeight(curSec)
				);
			}
		}

		if (FlxG.save.data.chart_waveformVoices) {
			var sound:FlxSound = vocals;
			var soundOpponent:FlxSound = opponentVocals;
			if (sound._sound != null && sound._sound.__buffer != null) {
				var bytes:Bytes = sound._sound.__buffer.data.toBytes();

				wavData = waveformData(
					sound._sound.__buffer,
					bytes,
					st,
					et,
					1,
					wavData,
					chartSectionHeight(curSec)
				);
			}
			if (soundOpponent._sound != null && soundOpponent._sound.__buffer != null) {
				var bytes:Bytes = soundOpponent._sound.__buffer.data.toBytes();
				wavData = waveformData(
					soundOpponent._sound.__buffer,
					bytes,
					st,
					et,
					1,
					wavData,
					chartSectionHeight(curSec)
				);
		}


		}
		// Draws
		var gSize:Int = Std.int(GRID_SIZE * maniaAmmo() * 2);
		var hSize:Int = Std.int(gSize / 2);

		var lmin:Float = 0;
		var lmax:Float = 0;

		var rmin:Float = 0;
		var rmax:Float = 0;

		var size:Float = 1;

		var leftLength:Int = (
			wavData[0][0].length > wavData[0][1].length ? wavData[0][0].length : wavData[0][1].length
		);

		var rightLength:Int = (
			wavData[1][0].length > wavData[1][1].length ? wavData[1][0].length : wavData[1][1].length
		);

		var length:Int = leftLength > rightLength ? leftLength : rightLength;

		var index:Int;
		for (i in 0...length) {
			index = i;

			lmin = FlxMath.bound(((index < wavData[0][0].length && index >= 0) ? wavData[0][0][index] : 0) * (gSize / 1.12), -hSize, hSize) / 2;
			lmax = FlxMath.bound(((index < wavData[0][1].length && index >= 0) ? wavData[0][1][index] : 0) * (gSize / 1.12), -hSize, hSize) / 2;

			rmin = FlxMath.bound(((index < wavData[1][0].length && index >= 0) ? wavData[1][0][index] : 0) * (gSize / 1.12), -hSize, hSize) / 2;
			rmax = FlxMath.bound(((index < wavData[1][1].length && index >= 0) ? wavData[1][1][index] : 0) * (gSize / 1.12), -hSize, hSize) / 2;

			waveformSprite.pixels.fillRect(new Rectangle(hSize - (lmin + rmin), i * size, (lmin + rmin) + (lmax + rmax), size), FlxColor.BLUE);
		}

		waveformPrinted = true;
	}

	function waveformData(buffer:AudioBuffer, bytes:Bytes, time:Float, endTime:Float, multiply:Float = 1, ?array:Array<Array<Array<Float>>>, ?steps:Float):Array<Array<Array<Float>>>
	{
		#if (lime_cffi && !macro)
		if (buffer == null || buffer.data == null) return [[[0], [0]], [[0], [0]]];

		var khz:Float = (buffer.sampleRate / 1000);
		var channels:Int = buffer.channels;

		var index:Int = Std.int(time * khz);

		var samples:Float = ((endTime - time) * khz);

		if (steps == null) steps = 1280;

		var samplesPerRow:Float = samples / steps;
		var samplesPerRowI:Int = Std.int(samplesPerRow);

		var gotIndex:Int = 0;

		var lmin:Float = 0;
		var lmax:Float = 0;

		var rmin:Float = 0;
		var rmax:Float = 0;

		var rows:Float = 0;

		var simpleSample:Bool = true;//samples > 17200;
		var v1:Bool = false;

		if (array == null) array = [[[0], [0]], [[0], [0]]];

		while (index < (bytes.length - 1)) {
			if (index >= 0) {
				var byte:Int = bytes.getUInt16(index * channels * 2);

				if (byte > 65535 / 2) byte -= 65535;

				var sample:Float = (byte / 65535);

				if (sample > 0) {
					if (sample > lmax) lmax = sample;
				} else if (sample < 0) {
					if (sample < lmin) lmin = sample;
				}

				if (channels >= 2) {
					byte = bytes.getUInt16((index * channels * 2) + 2);

					if (byte > 65535 / 2) byte -= 65535;

					sample = (byte / 65535);

					if (sample > 0) {
						if (sample > rmax) rmax = sample;
					} else if (sample < 0) {
						if (sample < rmin) rmin = sample;
					}
				}
			}

			v1 = samplesPerRowI > 0 ? (index % samplesPerRowI == 0) : false;
			while (simpleSample ? v1 : rows >= samplesPerRow) {
				v1 = false;
				rows -= samplesPerRow;

				gotIndex++;

				var lRMin:Float = Math.abs(lmin) * multiply;
				var lRMax:Float = lmax * multiply;

				var rRMin:Float = Math.abs(rmin) * multiply;
				var rRMax:Float = rmax * multiply;

				if (gotIndex > array[0][0].length) array[0][0].push(lRMin);
					else array[0][0][gotIndex - 1] = array[0][0][gotIndex - 1] + lRMin;

				if (gotIndex > array[0][1].length) array[0][1].push(lRMax);
					else array[0][1][gotIndex - 1] = array[0][1][gotIndex - 1] + lRMax;

				if (channels >= 2) {
					if (gotIndex > array[1][0].length) array[1][0].push(rRMin);
						else array[1][0][gotIndex - 1] = array[1][0][gotIndex - 1] + rRMin;

					if (gotIndex > array[1][1].length) array[1][1].push(rRMax);
						else array[1][1][gotIndex - 1] = array[1][1][gotIndex - 1] + rRMax;
				}
				else {
					if (gotIndex > array[1][0].length) array[1][0].push(lRMin);
						else array[1][0][gotIndex - 1] = array[1][0][gotIndex - 1] + lRMin;

					if (gotIndex > array[1][1].length) array[1][1].push(lRMax);
						else array[1][1][gotIndex - 1] = array[1][1][gotIndex - 1] + lRMax;
				}

				lmin = 0;
				lmax = 0;

				rmin = 0;
				rmax = 0;
			}

			index++;
			rows++;
			if(gotIndex > steps) break;
		}

		return array;
		#else
		return [[[0], [0]], [[0], [0]]];
		#end
	}

	function changeNoteSustain(value:Float):Void
	{
		if (curSelectedNote != null)
		{
			if (curSelectedNote[2] != null)
			{
				curSelectedNote[2] += value;
				curSelectedNote[2] = Math.max(curSelectedNote[2], 0);
			}
		}
		markUnsaved();
		updateNoteUI();
		updateGrid();
	}

	function recalculateSteps(add:Float = 0):Int
	{
		var lastChange:BPMChangeEvent = {
			stepTime: 0,
			songTime: 0,
			bpm: 0
		}
		for (i in 0...Conductor.bpmChangeMap.length)
		{
			if (FlxG.sound.music.time > Conductor.bpmChangeMap[i].songTime)
				lastChange = Conductor.bpmChangeMap[i];
		}

		curStep = lastChange.stepTime + Math.floor((FlxG.sound.music.time - lastChange.songTime + add) / Conductor.stepCrochet);
		updateBeat();

		return curStep;
	}

	function resetSection(songBeginning:Bool = false):Void
	{
		updateGrid();

		FlxG.sound.music.pause();
		// Basically old shit from changeSection???
		FlxG.sound.music.time = sectionStartTime();

		if (songBeginning)
		{
			FlxG.sound.music.time = 0;
			curSec = 0;
		}

		if(vocals != null) {
			vocals.pause();
			opponentVocals.pause();
			vocals.time = FlxG.sound.music.time;
			opponentVocals.time = FlxG.sound.music.time;
		}
		updateCurStep();

		updateGrid();
		updateSectionUI();
		updateWaveform();
	}

	function changeSection(sec:Int = 0, ?updateMusic:Bool = true):Void
	{
		if (_song.notes[sec] != null)
		{
			curSec = sec;
			if (updateMusic)
			{
			FlxG.sound.music.pause();
				FlxG.sound.music.time = sectionStartTime();
				if(vocals != null) {
				vocals.pause();
				opponentVocals.pause();
				vocals.time = FlxG.sound.music.time;
				opponentVocals.time = FlxG.sound.music.time;
				}
				updateCurStep();
			}

			var blah1:Float = getSectionBeats();
			var blah2:Float = getSectionBeats(curSec + 1);
			if(sectionStartTime(1) > FlxG.sound.music.length) blah2 = 0;

			if(blah1 != lastSecBeats || blah2 != lastSecBeatsNext)
			{
				reloadGridLayer();
			}
			else
			{
				// 多k: 拍数相同但切了节时, 只重建网格本体 (主网格列数/事件分段/分隔线), 不重建 strum/音符
				if(_lastGridSec != curSec)
				{
					rebuildGridVisuals();
					_lastGridSec = curSec;
				}
				updateGrid();
			}
			updateSectionUI();
		}
		else
		{
			changeSection();
		}
		Conductor.songPosition = FlxG.sound.music.time;
		updateWaveform();
	}

	function updateSectionUI():Void
	{
		var sec = _song.notes[curSec];

		stepperBeats.value = getSectionBeats();
		check_mustHitSection.checked = sec.mustHitSection;
		check_gfSection.checked = sec.gfSection;
		check_altAnim.checked = sec.altAnim;
		check_changeBPM.checked = sec.changeBPM;
		stepperSectionBPM.value = sec.bpm;

		updateHeads();
	}

	function updateHeads():Void
	{
		var healthIconP1:String = loadHealthIconFromCharacter(_song.player1);
		var healthIconP2:String = loadHealthIconFromCharacter(_song.player2);

		if (_song.notes[curSec].mustHitSection)
		{
			leftIcon.changeIcon(healthIconP1);
			rightIcon.changeIcon(healthIconP2);
			if (_song.notes[curSec].gfSection) leftIcon.changeIcon('gf');
		}
		else
		{
			leftIcon.changeIcon(healthIconP2);
			rightIcon.changeIcon(healthIconP1);
			if (_song.notes[curSec].gfSection) leftIcon.changeIcon('gf');
		}
	}

	function loadHealthIconFromCharacter(char:String) {
		var characterPath:String = 'characters/' + char + '.json';
		#if MODS_ALLOWED
		var path:String = Paths.modFolders(characterPath);
		if (!FileSystem.exists(path)) {
			path = Paths.getPreloadPath(characterPath);
		}

		if (!FileSystem.exists(path))
		#else
		var path:String = Paths.getPreloadPath(characterPath);
		if (!OpenFlAssets.exists(path))
		#end
		{
			path = Paths.getPreloadPath('characters/' + Character.DEFAULT_CHARACTER + '.json'); //If a character couldn't be found, change him to BF just to prevent a crash
		}

		#if MODS_ALLOWED
		var rawJson = File.getContent(path);
		#else
		var rawJson = OpenFlAssets.getText(path);
		#end

		var json:Character.CharacterFile = cast Json.parse(rawJson);
		return json.healthicon;
	}

	function updateNoteUI():Void
	{
		if (curSelectedNote != null) {
			if(curSelectedNote[2] != null) {
				stepperSusLength.value = curSelectedNote[2];
				if(curSelectedNote[3] != null) {
					var typeIndex:Null<Int> = noteTypeMap.get(curSelectedNote[3]);
					currentType = (typeIndex != null) ? typeIndex : 0;
					if(currentType <= 0) {
						noteTypeDropDown.selectedLabel = '';
					} else {
						noteTypeDropDown.selectedLabel = currentType + '. ' + curSelectedNote[3];
					}
				}
			} else {
				eventDropDown.selectedLabel = curSelectedNote[1][curEventSelected][0];
				var selected:Int = eventDropDown.selectedIndex;
				if(selected > 0 && selected < eventStuff.length) {
					descText.text = eventStuff[selected][1];
				}
				value1InputText.text = curSelectedNote[1][curEventSelected][1];
				value2InputText.text = curSelectedNote[1][curEventSelected][2];
			}
			strumTimeInputText.text = '' + curSelectedNote[0];
		}
	}

	// ---- Object pools: reuse FlxSprite / AttachedFlxText ----
	var _poolSustains:Array<FlxSprite> = [];
	var _poolTexts:Array<AttachedFlxText> = [];

	inline function allocSustain():FlxSprite
	{
		if(_poolSustains.length > 0) { var s = _poolSustains.pop(); s.visible = true; return s; }
		return new FlxSprite().makeGraphic(8, 1);
	}

	inline function allocText(width:Float, text:String, fontSize:Int, alignment:FlxTextAlign):AttachedFlxText
	{
		var t:AttachedFlxText = _poolTexts.length > 0 ? _poolTexts.pop() : new AttachedFlxText(0, 0, 400, '', 12);
		t.text = text;
		t.setFormat(Paths.font("editors.ttf"), fontSize, FlxColor.WHITE, alignment, FlxTextBorderStyle.OUTLINE_FAST, FlxColor.BLACK);
		t.borderSize = 1;
		t.visible = true;
		t.alpha = 1;
		t.xAdd = 0;
		t.yAdd = 0;
		return t;
	}

	function recycleGroups():Void
	{
		_poolSustains.resize(0);
		curRenderedSustains.forEachAlive(function(s:FlxSprite) { s.visible = false; _poolSustains.push(s); });
		curRenderedSustains.clear();
		nextRenderedSustains.forEachAlive(function(s:FlxSprite) { s.visible = false; _poolSustains.push(s); });
		nextRenderedSustains.clear();

		_poolTexts.resize(0);
		curRenderedNoteType.forEachAlive(function(t:FlxText) { t.visible = false; _poolTexts.push(cast t); });
		curRenderedNoteType.clear();

		curRenderedNotes.clear();
		nextRenderedNotes.clear();
	}

	function updateGrid():Void
	{
		recycleGroups();

		if (_song.notes[curSec].changeBPM && _song.notes[curSec].bpm > 0)
		{
			Conductor.changeBPM(_song.notes[curSec].bpm);
		}
		else
		{
			var daBPM:Float = _song.bpm;
			for (i in 0...curSec)
				if (_song.notes[i].changeBPM)
					daBPM = _song.notes[i].bpm;
			Conductor.changeBPM(daBPM);
		}

		// CURRENT SECTION
		var beats:Float = getSectionBeats();
		for (i in _song.notes[curSec].sectionNotes)
		{
			var note:Note = setupNoteData(i, false);
			curRenderedNotes.add(note);
			if (note.sustainLength > 0)
				curRenderedSustains.add(setupSusNote(note, beats));

			if(i[3] != null && note.noteType != null && note.noteType.length > 0) {
				var typeInt:Null<Int> = noteTypeMap.get(i[3]);
				var theType:String = (typeInt != null) ? Std.string(typeInt) : '?';
				var daText:AttachedFlxText = allocText(100, theType, 24, CENTER);
				daText.xAdd = -32;
				daText.yAdd = 6;
				curRenderedNoteType.add(daText);
				daText.sprTracker = note;
			}
			note.mustPress = _song.notes[curSec].mustHitSection;
			// 多k: 玩家/对手侧按该 Note 自身 k 判断
			if(i[1] >= Note.ammo[note.mania]) note.mustPress = !note.mustPress;
		}

		// CURRENT EVENTS
		var startThing:Float = sectionStartTime();
		var endThing:Float = sectionStartTime(1);
		for (i in _song.events)
		{
			if(endThing > i[0] && i[0] >= startThing)
			{
				var note:Note = setupNoteData(i, false);
				curRenderedNotes.add(note);

				var text:String = 'Event: ' + note.eventName + ' (' + Math.floor(note.strumTime) + ' ms)' + '\nValue 1: ' + note.eventVal1 + '\nValue 2: ' + note.eventVal2;
				if(note.eventLength > 1) text = note.eventLength + ' Events:\n' + note.eventName;

				var daText:AttachedFlxText = allocText(400, text, 12, RIGHT);
				daText.xAdd = -410;
				if(note.eventLength > 1) daText.yAdd += 8;
				curRenderedNoteType.add(daText);
				daText.sprTracker = note;
			}
		}

		// NEXT SECTION
		beats = getSectionBeats(1);
		if(curSec < _song.notes.length-1) {
			for (i in _song.notes[curSec+1].sectionNotes)
			{
				var note:Note = setupNoteData(i, true);
				note.alpha = 0.6;
				nextRenderedNotes.add(note);
				if (note.sustainLength > 0)
					nextRenderedSustains.add(setupSusNote(note, beats));
			}
		}

		// NEXT EVENTS
		startThing = sectionStartTime(1);
		endThing = sectionStartTime(2);
		for (i in _song.events)
		{
			if(endThing > i[0] && i[0] >= startThing)
			{
				var note:Note = setupNoteData(i, true);
				note.alpha = 0.6;
				nextRenderedNotes.add(note);
			}
		}
	}

function setupNoteData(i:Array<Dynamic>, isNextSection:Bool):Note
	{
		// 显式解析为基本类型, 避免 Dynamic 隐式转 Float 导致 null 检查编译错误
		var daStrumTime:Float = 0;
		if (i[0] != null) {
			var t:Float = Std.parseFloat(Std.string(i[0]));
			if (!Math.isNaN(t)) daStrumTime = t;
		}
		var daNoteInfo:Int = -1;
		if (i[1] != null) {
			var d:Null<Int> = Std.parseInt(Std.string(i[1]));
			if (d != null) daNoteInfo = d;
		}
		var daSus:Dynamic = i[2];

		// 多k: 按该 Note 自身时间点的生效键数解释 (Change Mania 事件分段, 各段各自解释)
		var baseMania:Int = (_song != null && _song.mania != null) ? EKData.clampMania(_song.mania) : Note.defaultMania;
		var noteMania:Int = EKData.effectiveManiaAtTime((_song != null) ? _song.events : null, baseMania, daStrumTime);
		var noteAmmo:Int = Note.ammo[EKData.clampMania(noteMania)];

		var note:Note = new Note(daStrumTime, daNoteInfo % noteAmmo, null, false, true);
		note.mania = noteMania; // 记录该 Note 所属 k, 使后续渲染/颜色按正确 k
		if(daSus != null) { //Common note
			if(!Std.isOfType(i[3], String)) //Convert old note type to new note type format
			{
				var resolvedType:Dynamic = noteTypeIntMap.get(i[3]);
				i[3] = (resolvedType != null) ? resolvedType : NoteTypeRegistry.fromIndex(Std.int(i[3]));
			}
			if(i.length > 3 && (i[3] == null || i[3].length < 1))
			{
				i.remove(i[3]);
			}
			note.sustainLength = daSus;
			note.noteType = i[3];
		} else { //Event note
			note.loadGraphic(Paths.image('eventArrow'));
			note.eventName = getEventName(i[1]);
			note.eventLength = i[1].length;
			if(i[1].length < 2)
			{
				note.eventVal1 = i[1][0][1];
				note.eventVal2 = i[1][0][2];
			}
			note.noteData = -1;
			daNoteInfo = -1;
		}

		note.setGraphicSize(GRID_SIZE, GRID_SIZE);
		note.updateHitbox();
		// 多k: 按 Note 所属 k 应用轨道色 (基底纹理 + 色差 + 用户偏移)
		if (note.colorSwap != null && note.noteData > -1) note.applyLaneColor();
		note.x = Math.floor(daNoteInfo * GRID_SIZE) + GRID_SIZE;
		if(isNextSection && _song.notes[curSec].mustHitSection != _song.notes[curSec+1].mustHitSection) {
			if(daNoteInfo >= noteAmmo) {
				note.x -= GRID_SIZE * noteAmmo;
			} else if(daSus != null) {
				note.x += GRID_SIZE * noteAmmo;
			}
		}

		var beats:Float = getSectionBeats(isNextSection ? 1 : 0);
		note.y = getYfromStrumNotes(daStrumTime - sectionStartTime(), beats);
		//if(isNextSection) note.y += gridBG.height;
		if(note.y < -150) note.y = -150;
		return note;
	}

	function getEventName(names:Array<Dynamic>):String
	{
		var retStr:String = '';
		var addedOne:Bool = false;
		for (i in 0...names.length)
		{
			if(addedOne) retStr += ', ';
			retStr += names[i][0];
			addedOne = true;
		}
		return retStr;
	}

	function setupSusNote(note:Note, beats:Float):FlxSprite {
		var height:Int = Math.floor(FlxMath.remapToRange(note.sustainLength, 0, Conductor.stepCrochet * 16, 0, GRID_SIZE * 16 * zoomList[curZoom]) + (GRID_SIZE * zoomList[curZoom]) - GRID_SIZE / 2);
		var minHeight:Int = Std.int((GRID_SIZE * zoomList[curZoom] / 2) + GRID_SIZE / 2);
		if(height < minHeight) height = minHeight;
		if(height < 1) height = 1;

		var spr:FlxSprite = allocSustain();
		spr.setPosition(note.x + (GRID_SIZE * 0.5) - 4, note.y + GRID_SIZE / 2);
		spr.makeGraphic(8, height);
		return spr;
	}

	private function addSection(sectionBeats:Float = 4):Void
	{
		var sec:SwagSection = {
			sectionBeats: sectionBeats,
			bpm: _song.bpm,
			changeBPM: false,
			mustHitSection: true,
			gfSection: false,
			sectionNotes: [],
			typeOfSection: 0,
			altAnim: false
		};

		_song.notes.push(sec);
	}

	function selectNote(note:Note):Void
	{
		var noteDataToCheck:Int = note.noteData;

		if(noteDataToCheck > -1)
		{
			if(note.mustPress != _song.notes[curSec].mustHitSection) noteDataToCheck += maniaAmmo();
			for (i in _song.notes[curSec].sectionNotes)
			{
				if (i != curSelectedNote && i.length > 2 && i[0] == note.strumTime && i[1] == noteDataToCheck)
				{
					curSelectedNote = i;
					break;
				}
			}
		}
		else
		{
			for (i in _song.events)
			{
				if(i != curSelectedNote && i[0] == note.strumTime)
				{
					curSelectedNote = i;
					curEventSelected = Std.int(curSelectedNote[1].length) - 1;
					break;
				}
			}
		}
		changeEventSelected();

		updateGrid();
		updateNoteUI();
	}

	function deleteNote(note:Note):Void
	{
		pushUndo();
		var noteDataToCheck:Int = note.noteData;
		if(noteDataToCheck > -1 && note.mustPress != _song.notes[curSec].mustHitSection) noteDataToCheck += maniaAmmo();

		if(note.noteData > -1) //Normal Notes
		{
			for (i in _song.notes[curSec].sectionNotes)
			{
				if (i[0] == note.strumTime && i[1] == noteDataToCheck)
				{
					if(i == curSelectedNote) curSelectedNote = null;
					//FlxG.log.add('FOUND EVIL NOTE');
					_song.notes[curSec].sectionNotes.remove(i);
					break;
				}
			}
		}
		else //Events
		{
			// 多k: 删除 Change Mania 事件 -> 记录快照, 删除后按工具箱模式重编码
			var oldEvents:Array<Dynamic> = EKData.deepCopyEvents(_song.events);
			for (i in _song.events)
			{
				if(i[0] == note.strumTime)
				{
					if(i == curSelectedNote)
					{
						curSelectedNote = null;
						changeEventSelected();
					}
					//FlxG.log.add('FOUND EVIL EVENT');
					_song.events.remove(i);
					break;
				}
			}
			reencodeNotesForEventChange(oldEvents, _song.events, (convertModeDropDown != null) ? convertModeDropDown.selectedIndex : 0);
			reloadGridLayer();
		}
		markUnsaved();

		updateGrid();
	}

	public function doANoteThing(cs, d, style){
		var delnote = false;
		if(strumLineNotes.members[d].overlaps(curRenderedNotes))
		{
			curRenderedNotes.forEachAlive(function(note:Note)
			{
				if (note.overlapsPoint(new FlxPoint(strumLineNotes.members[d].x + 1,strumLine.y+1)) && note.noteData == d % maniaAmmo())
				{
						//trace('tryin to delete note...');
						if(!delnote) deleteNote(note);
						delnote = true;
				}
			});
		}

		if (!delnote){
			addNote(cs, d, style);
		}
	}
	private function addNote(strum:Null<Float> = null, data:Null<Int> = null, type:Null<Int> = null):Void
	{
		pushUndo();
		var noteStrum = getStrumTime(dummyArrow.y * (getSectionBeats() / 4), false) + sectionStartTime();
		var noteData = Math.floor((FlxG.mouse.x - GRID_SIZE) / GRID_SIZE);
		// 多k: 鼠标放置时按点击时间所属 k 段限制列范围 (4K 段不能点到 9K 列)
		if (data == null)
		{
			var partMania:Int = EKData.effectiveManiaAtTime(_song.events, (_song.mania != null) ? EKData.clampMania(_song.mania) : Note.defaultMania, noteStrum);
			var partAmmo:Int = Note.ammo[partMania];
			if (noteData >= partAmmo * 2) noteData = partAmmo * 2 - 1;
			// 事件列在最左 (x < GRID_SIZE → noteData = -1)：不能钳成 0，否则事件永远放不下
		}
		var noteSus = 0;
		var daAlt = false;
		var daType = currentType;

		if (strum != null) noteStrum = strum;
		if (data != null) noteData = data;
		if (type != null) daType = type;

		if(noteData > -1)
		{
			_song.notes[curSec].sectionNotes.push([noteStrum, noteData, noteSus, noteTypeIntMap.get(daType)]);
			curSelectedNote = _song.notes[curSec].sectionNotes[_song.notes[curSec].sectionNotes.length - 1];
		}
		else
		{
			// 多k: 新增事件 (可能是 Change Mania) -> 记录快照, 插入后按工具箱模式重编码
			var oldEvents:Array<Dynamic> = EKData.deepCopyEvents(_song.events);
			var event = eventStuff[eventDropDown.selectedIndex][0];
			var text1 = value1InputText.text;
			var text2 = value2InputText.text;
			_song.events.push([noteStrum, [[event, text1, text2]]]);
			curSelectedNote = _song.events[_song.events.length - 1];
			curEventSelected = 0;
			reencodeNotesForEventChange(oldEvents, _song.events, (convertModeDropDown != null) ? convertModeDropDown.selectedIndex : 0);
			reloadGridLayer();
		}
		changeEventSelected();

		if (FlxG.keys.pressed.CONTROL && noteData > -1)
		{
			_song.notes[curSec].sectionNotes.push([noteStrum, (noteData + maniaAmmo()) % (maniaAmmo() * 2), noteSus, noteTypeIntMap.get(daType)]);
		}

		//trace(noteData + ', ' + noteStrum + ', ' + curSec);
		strumTimeInputText.text = '' + curSelectedNote[0];
		markUnsaved();
		updateGrid();
		updateNoteUI();
	}

	// Snapshot-based undo/redo (same serialization as autosave).
	function pushUndo():Void
	{
		undos.push(Json.stringify({"song": _song}));
		redos = [];
		while (undos.length > 50) undos.shift();
	}

	function restoreChart(json:String):Void
	{
		var parsed:SwagSong = Song.parseJSON(json);
		if (parsed == null) return;
		PlayState.SONG = parsed;
		_song = parsed;
		Conductor.mapBPMChanges(_song);
		reloadGridLayer();
		updateGrid();
		updateNoteUI();
		updateSectionUI();
		updateWaveform();
	}

	function redo()
	{
		if (redos.length < 1) return;
		undos.push(Json.stringify({"song": _song}));
		restoreChart(redos.pop());
	}

	function undo()
	{
		if (undos.length < 1) return;
		redos.push(Json.stringify({"song": _song}));
		restoreChart(undos.pop());
	}

	function getStrumTime(yPos:Float, doZoomCalc:Bool = true):Float
	{
		var leZoom:Float = zoomList[curZoom];
		if(!doZoomCalc) leZoom = 1;
		// 多k: 时间<->Y 换算用当前小节总高度 (含事件切分段)
		return FlxMath.remapToRange(yPos, gridBG.y, gridBG.y + chartSectionHeight(curSec) * leZoom, 0, 16 * Conductor.stepCrochet);
	}

	function getYfromStrum(strumTime:Float, doZoomCalc:Bool = true):Float
	{
		var leZoom:Float = zoomList[curZoom];
		if(!doZoomCalc) leZoom = 1;
		return FlxMath.remapToRange(strumTime, 0, 16 * Conductor.stepCrochet, gridBG.y, gridBG.y + chartSectionHeight(curSec) * leZoom);
	}

	function getYfromStrumNotes(strumTime:Float, beats:Float):Float
	{
		var value:Float = strumTime / (beats * 4 * Conductor.stepCrochet);
		return GRID_SIZE * beats * 4 * zoomList[curZoom] * value + gridBG.y;
	}

	function getNotes():Array<Dynamic>
	{
		var noteData:Array<Dynamic> = [];

		for (i in _song.notes)
		{
			noteData.push(i.sectionNotes);
		}

		return noteData;
	}

	function loadJson(song:String, diffIndex:Int = -1, ?chartName:String = null):Void
	{
		var songLower:String = song.toLowerCase();
		var loadedChart:SwagSong = null;

		if(chartName != null && chartName.length > 0)
		{
			// Custom difficulty chart (e.g. song-remix.json) or explicit name
			loadedChart = Song.getChart(chartName, songLower);
			if(loadedChart != null && Reflect.hasField(loadedChart, 'song') && diffIndex >= 0)
			{
				PlayState.storyDifficulty = diffIndex;
			}
		}
		else if(diffIndex >= 0)
		{
			var chartName:String = Highscore.formatSong(songLower, diffIndex);
			loadedChart = Song.getChart(chartName, songLower);
			if(loadedChart != null && Reflect.hasField(loadedChart, 'song'))
			{
				PlayState.storyDifficulty = diffIndex;
			}
		}
		else
		{
			// Try loading without any difficulty suffix
			loadedChart = Song.getChart(songLower, songLower);
		}

		if(loadedChart == null || !Reflect.hasField(loadedChart, 'song'))
		{
			openSubState(new BasePrompt(400, 160, 'Error: Could not find chart for "' + songLower + '"!'));
			return;
		}

		PlayState.SONG = loadedChart;

		// Smart defaults matching PlayState.create() logic
		if(PlayState.SONG.stage == null || PlayState.SONG.stage.length < 1)
		{
			var songName:String = Paths.formatToSongPath(PlayState.SONG.song);
			switch(songName)
			{
				case 'spookeez' | 'south' | 'monster': PlayState.SONG.stage = 'spooky';
				case 'pico' | 'blammed' | 'philly' | 'philly-nice': PlayState.SONG.stage = 'philly';
				case 'milf' | 'satin-panties' | 'high': PlayState.SONG.stage = 'limo';
				case 'cocoa' | 'eggnog': PlayState.SONG.stage = 'mall';
				case 'winter-horrorland': PlayState.SONG.stage = 'mallEvil';
				case 'senpai' | 'roses': PlayState.SONG.stage = 'school';
				case 'thorns': PlayState.SONG.stage = 'schoolEvil';
				case 'ugh' | 'guns' | 'stress': PlayState.SONG.stage = 'tank';
				default: PlayState.SONG.stage = 'stage';
			}
		}
		if(PlayState.SONG.gfVersion == null || PlayState.SONG.gfVersion.length < 1)
		{
			switch(PlayState.SONG.stage)
			{
				case 'limo': PlayState.SONG.gfVersion = 'gf-car';
				case 'mall' | 'mallEvil': PlayState.SONG.gfVersion = 'gf-christmas';
				case 'school' | 'schoolEvil': PlayState.SONG.gfVersion = 'gf-pixel';
				case 'tank': PlayState.SONG.gfVersion = 'gf-tankmen';
				default: PlayState.SONG.gfVersion = 'gf';
			}
			var songName:String = Paths.formatToSongPath(PlayState.SONG.song);
			switch(songName)
			{
				case 'stress': PlayState.SONG.gfVersion = 'pico-speaker';
			}
		}
		if(PlayState.SONG.arrowSkin == null) PlayState.SONG.arrowSkin = '';
		if(PlayState.SONG.splashSkin == null) PlayState.SONG.splashSkin = 'noteSplashes';

		MusicBeatState.resetState();
	}

	function getAvailableDifficultiesForSong(song:String):Void
	{
		var songLower:String = song.toLowerCase();
		var foundDifficulties:Array<{name:String, chartName:String, index:Int}> = [];
		var defaultIndex:Int = 0;

		// 1) Standard difficulties from the difficulty list (Easy/Normal/Hard...)
		for(i in 0...CoolUtil.difficulties.length)
		{
			var diff:String = CoolUtil.difficulties[i];
			var chartName:String = Highscore.formatSong(songLower, i);

			if(chartExists(songLower, chartName))
			{
				foundDifficulties.push({name: diff, chartName: chartName, index: i});
				if(diff == CoolUtil.defaultDifficulty) defaultIndex = foundDifficulties.length - 1;
			}
		}

		// 2) Extra difficulties found on disk: any <song>-<something>.json file
		// that is not one of the standard difficulties (e.g. song-remix.json)
		var extraNames:Array<String> = [];
		for(dir in getChartFolders(songLower))
		{
			#if sys
			if(!FileSystem.exists(dir)) continue;
			for(file in FileSystem.readDirectory(dir))
			{
				var lower:String = file.toLowerCase();
				if(!lower.startsWith(songLower + '-') || !lower.endsWith('.json')) continue;
				var name:String = lower.substr(songLower.length + 1, lower.length - songLower.length - 6);
				if(name.length < 1 || name == 'events') continue;
				if(!extraNames.contains(name)) extraNames.push(name);
			}
			#else
			var prefix:String = dir + '/';
			for(asset in lime.utils.Assets.list())
			{
				if(!asset.startsWith(prefix)) continue;
				var file:String = asset.substr(prefix.length);
				var lower:String = file.toLowerCase();
				if(!lower.startsWith(songLower + '-') || !lower.endsWith('.json')) continue;
				var name:String = lower.substr(songLower.length + 1, lower.length - songLower.length - 6);
				if(name.length < 1 || name == 'events') continue;
				if(!extraNames.contains(name)) extraNames.push(name);
			}
			#end
		}
		for(name in extraNames)
		{
			var already:Bool = false;
			for(d in foundDifficulties)
			{
				if(d.chartName == '$songLower-$name' || d.name.toLowerCase() == name)
				{
					already = true;
					break;
				}
			}
			if(already) continue;
			foundDifficulties.push({name: name.charAt(0).toUpperCase() + name.substr(1), chartName: '$songLower-$name', index: -1});
		}

		if(foundDifficulties.length < 1)
		{
			//Try loading the base song name directly (no difficulty suffix)
			if(chartExists(songLower, songLower))
			{
				loadJson(songLower, -1);
			}
			else
			{
				openSubState(new BasePrompt(400, 160, 'Error: No chart files found for "' + songLower + '"!'));
			}
			return;
		}

		if(foundDifficulties.length == 1)
		{
			loadJson(songLower, foundDifficulties[0].index, foundDifficulties[0].chartName);
			return;
		}

		//Multiple difficulties found - show a selection prompt
		var diffLabels:Array<String> = [];
		for(d in foundDifficulties)
			diffLabels.push(d.name);

		var radioGrp:PsychUIRadioGroup = new PsychUIRadioGroup(0, 0, diffLabels, 35, 6, false, 200);
		radioGrp.checked = defaultIndex;

		var itemCount:Int = Std.int(Math.min(diffLabels.length, 6));
		var promptHeight:Float = 100 + itemCount * 35 + 70; // title area + radio items + buttons area
		openSubState(new BasePrompt(420, promptHeight,
			'newchartEditor_select_difficulty',
			function(state:BasePrompt)
			{
				// Radio group below title
				radioGrp.x = state.bg.x + 20;
				radioGrp.y = state.bg.y + 60;
				radioGrp.cameras = state.cameras;
				state.add(radioGrp);

				// Buttons near the bottom of the panel
				var btnY:Float = state.bg.y + state.bg.height - 45;
				var confirmBtn:PsychUIButton = new PsychUIButton(0, btnY, Language.get('newchartEditor_load_btn', 'Load'), function()
				{
					state.close();
					loadJson(songLower, foundDifficulties[radioGrp.checked].index, foundDifficulties[radioGrp.checked].chartName);
				});
				confirmBtn.screenCenter(X);
				confirmBtn.x -= 100;
				confirmBtn.cameras = state.cameras;
				confirmBtn.normalStyle.bgColor = FlxColor.GREEN;
				confirmBtn.normalStyle.textColor = FlxColor.WHITE;
				state.add(confirmBtn);

				var cancelBtn:PsychUIButton = new PsychUIButton(0, btnY, Language.get('newchartEditor_cancel_btn', 'Cancel'), function()
				{
					state.close();
				});
				cancelBtn.screenCenter(X);
				cancelBtn.x += 100;
				cancelBtn.cameras = state.cameras;
				state.add(cancelBtn);
			}
		));
	}

	/** True when a chart file exists for the given song folder + chart name. */
	function chartExists(songLower:String, chartName:String):Bool
	{
		#if MODS_ALLOWED
		if(FileSystem.exists(Paths.modsJson('$songLower/$chartName'))) return true;
		if(FileSystem.exists(Paths.json('$songLower/$chartName'))) return true;
		#else
		try { if(Assets.exists(Paths.json('$songLower/$chartName'))) return true; } catch(e:Dynamic) {}
		#end
		return false;
	}

	/** Data folders that may contain chart files for this song. */
	function getChartFolders(songLower:String):Array<String>
	{
		var dirs:Array<String> = [];
		#if MODS_ALLOWED
		if(Paths.currentModDirectory != null && Paths.currentModDirectory.length > 0)
			dirs.push(Paths.mods(Paths.currentModDirectory + '/data/' + songLower));
		for(mod in Paths.getGlobalMods())
			dirs.push(Paths.mods(mod + '/data/' + songLower));
		dirs.push(Paths.mods('data/' + songLower));
		#end
		dirs.push(Paths.getPreloadPath('data/' + songLower));
		return dirs;
	}

	/** Mark the chart as having unsaved changes. */
	function markUnsaved():Void
	{
		unsavedChanges = true;
	}
	/** Clear the unsaved changes flag (called after save / load / discard). */
	function clearUnsaved():Void
	{
		unsavedChanges = false;
	}

	/** Show an exit-confirmation prompt if there are unsaved changes. */
	function confirmExit():Void
	{
		if(unsavedChanges)
		{
			openSubState(new editors.content.Prompt(
				Language.get('newchartEditor_unsaved_exit', 'There\'s unsaved progress,\nare you sure you want to exit?'),
				function()
				{
					clearUnsaved();
					PlayState.chartingMode = false;
					MusicBeatState.switchState(new editors.MasterEditorMenu());
					FlxG.sound.playMusic(Paths.music('freakyMenu'));
					FlxG.mouse.visible = false;
				}
			));
		}
		else
		{
			PlayState.chartingMode = false;
			MusicBeatState.switchState(new editors.MasterEditorMenu());
			FlxG.sound.playMusic(Paths.music('freakyMenu'));
			FlxG.mouse.visible = false;
		}
	}

	/** Show a confirmation prompt before playtesting if there are unsaved changes. */
	function confirmPlaytest():Void
	{
		if(unsavedChanges)
		{
			openSubState(new editors.content.Prompt(
				Language.get('newchartEditor_unsaved_playtest', 'You have unsaved changes.\nPlaytest anyway? (Changes won\'t be lost)'),
				function()
				{
					doPlaytest();
				},
				Language.get('newchartEditor_play', 'Play'),
				Language.get('newchartEditor_cancel', 'Cancel')
			));
		}
		else
		{
			doPlaytest();
		}
	}

	/** Actually run the playtest. */
	function doPlaytest():Void
	{
		autosaveSong();
		FlxG.mouse.visible = false;
		PlayState.SONG = _song;
		FlxG.sound.music.stop();
		if(vocals != null) vocals.stop();
		if(opponentVocals != null) opponentVocals.stop();
		StageData.loadDirectory(_song);
		LoadingState.loadAndSwitchState(new PlayState());
		PlayState.replayMode = false;
	}

	/** Confirm before preview (EditorPlayState). */
	function confirmPreview():Void
	{
		if(unsavedChanges)
		{
			openSubState(new editors.content.Prompt(
				Language.get('newchartEditor_unsaved_preview', 'You have unsaved changes.\nPreview anyway? (Changes won\'t be lost)'),
				function()
				{
					doPreview();
				},
				Language.get('newchartEditor_preview', 'Preview'),
				Language.get('newchartEditor_cancel', 'Cancel')
			));
		}
		else
		{
			doPreview();
		}
	}

	/** Actually run the preview. */
	function doPreview():Void
	{
		autosaveSong();
		LoadingState.loadAndSwitchState(new editors.EditorPlayState(sectionStartTime(), _song.mania));
	}

	function autosaveSong():Void
	{
		// Autosave is opt-in via the Chart Auto-save setting.
		// When disabled, we never touch the player's chart / autosave data.
		if(!ClientPrefs.data.chartAutosave) return;
		FlxG.save.data.autosave = Json.stringify({
			"song": _song
		});
		FlxG.save.flush();
	}

	function clearEvents() {
		pushUndo();
		_song.events = [];
		updateGrid();
		markUnsaved();
	}

	public function saveLevel(?onComplete:Void->Void)
	{
		// 多k: 4K 谱面可选择是否导出 mania 字段; 非 4K 必须导出 (锁死)
		if (getMania() == Note.defaultMania)
		{
			openSubState(new BasePrompt(420, 180, Language.get("newchartEditor_export_mania_title", "Export Multi-K Field?"),
				function(state:BasePrompt)
				{
					var check:PsychUICheckBox = new PsychUICheckBox(state.bg.x + 60, state.bg.y + 80,
						Language.get("newchartEditor_export_mania_label", "Include mania field (4K)"), 500);
					check.checked = false; // 默认不导出, 最大化兼容
					check.cameras = state.cameras;
					state.add(check);

					var saveBtn:PsychUIButton = new PsychUIButton(0, state.bg.y + state.bg.height - 45,
						Language.get("newchartEditor_save_btn", "Save"), function()
						{
							state.close();
							doSaveLevel(check.checked, onComplete);
						});
					saveBtn.screenCenter(X);
					saveBtn.x -= 80;
					saveBtn.cameras = state.cameras;
					saveBtn.normalStyle.bgColor = FlxColor.GREEN;
					saveBtn.normalStyle.textColor = FlxColor.WHITE;
					state.add(saveBtn);

					var cancelBtn:PsychUIButton = new PsychUIButton(0, state.bg.y + state.bg.height - 45,
						Language.get("newchartEditor_cancel_btn", "Cancel"), function() { state.close(); });
					cancelBtn.screenCenter(X);
					cancelBtn.x += 80;
					cancelBtn.cameras = state.cameras;
					state.add(cancelBtn);
				}));
			return;
		}
		doSaveLevel(true, onComplete);
	}

	function doSaveLevel(includeManiaField:Bool, ?onComplete:Void->Void)
	{
		if(_song.events != null && _song.events.length > 1) _song.events.sort(sortByTime);
		var songCopy:Dynamic = {};
		for (f in Reflect.fields(_song))
			Reflect.setField(songCopy, f, Reflect.field(_song, f));
		// 引擎内部字段不入谱面文件
		Song.stripRuntimeFields(songCopy);
		if (!includeManiaField) Reflect.deleteField(songCopy, 'mania');

		// 深拷贝，避免 castVersion（旧格式转换）原地修改编辑器 _song 数据。
		if (songCopy.notes != null)
		{
			var notesArr:Array<Dynamic> = cast songCopy.notes;
			var newNotes:Array<Dynamic> = [];
			for (sec in notesArr)
			{
				var newSec:Dynamic = Reflect.copy(sec);
				var secNotes:Array<Dynamic> = sec.sectionNotes != null ? cast sec.sectionNotes : [];
				var newSectionNotes:Array<Dynamic> = [];
				for (note in secNotes)
					newSectionNotes.push((note != null && Std.isOfType(note, Array)) ? note.copy() : note);
				newSec.sectionNotes = newSectionNotes;
				newNotes.push(newSec);
			}
			songCopy.notes = newNotes;
		}

		// 保存为 0.6.3/EK 可读的旧格式：去掉 psych_v1 format，
		// 并把全局玩家/对手半区转换为按 mustHitSection 区分的左右半区。
		if (Reflect.hasField(songCopy, 'format')) Reflect.deleteField(songCopy, 'format');
		Song.castVersion((cast songCopy : SwagSong));

		var json = { "song": songCopy };

		var data:String = Json.stringify(json, "\t");

		if ((data != null) && (data.length > 0))
		{
			_file.save(Paths.formatToSongPath(_song.song) + ".json", data.trim(), function()
			{
				clearUnsaved();
				if(onComplete != null) onComplete();
			});
		}
	}

	function sortByTime(Obj1:Array<Dynamic>, Obj2:Array<Dynamic>):Int
	{
		return FlxSort.byValues(FlxSort.ASCENDING, Obj1[0], Obj2[0]);
	}
	private function saveEvents()
	{
		if(_song.events != null && _song.events.length > 1) _song.events.sort(sortByTime);
		var eventsSong:Dynamic = {
			events: _song.events
		};
		var json = {
			"song": eventsSong
		}

		var data:String = Json.stringify(json, "\t");

		if ((data != null) && (data.length > 0))
		{
			_file.save("events.json", data.trim());
		}
	}
	function getSectionBeats(?section:Null<Int> = null)
	{
		if (section == null) section = curSec;
		var val:Null<Float> = null;

		if(_song.notes[section] != null) val = _song.notes[section].sectionBeats;
		return val != null ? val : 4;
	}
}

class AttachedFlxText extends EditorsText
{
	public var sprTracker:FlxSprite;
	public var xAdd:Float = 0;
	public var yAdd:Float = 0;

	public function new(X:Float = 0, Y:Float = 0, FieldWidth:Float = 0, ?Text:String, Size:Int = 8, EmbeddedFont:Bool = true) {
		super(X, Y, FieldWidth, Text, Size, EmbeddedFont);
	}

	override function update(elapsed:Float)
	{
		super.update(elapsed);

		if (sprTracker != null) {
			setPosition(sprTracker.x + xAdd, sprTracker.y + yAdd);
			angle = sprTracker.angle;
			alpha = sprTracker.alpha;
		}
	}
}
