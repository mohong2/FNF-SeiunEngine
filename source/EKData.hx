package;

import flixel.input.keyboard.FlxKey;

#if sys
import sys.io.File;
import sys.FileSystem;
#end

using StringTools;

/**
 * Extra-keys data layer.
 * Extra-keys data layer.
 * Note textures reuse the four stock notes (left/down/up/right); lane colours are derived from
 * the base colours through the ColorSwap shader (hue shift + saturation + brightness).
 *
 * mania is a zero-based index (0 = 1K, 3 = 4K, 8 = 9K, 17 = 18K).
 *
 * Soft-coded: assets/data/extraKeys/extraKeys.json (or mods/<mod>/data/extraKeys/extraKeys.json)
 * can override scales/gridSizes/splashScales/pixelScales/lessX/separator/offsetX/restPosition/noteColors.
 */
class EKData
{
	/** Per key count: key letters / character animations / strum animations / pixel frame indices. */
	public static var keysShit:Map<Int, Map<String, Dynamic>> = buildKeysShit();

	/** Lane count per key count (mania + 1). */
	public static var ammo:Array<Int> = [for (i in 0...18) i + 1];

	public static var minMania:Int = 0;
	public static var maxMania:Int = 17; // key count = this + 1
	public static var defaultMania:Int = 3; // 4K

	/** Most lanes the editor renders directly; above 9K it shrinks the cells and paginates. */
	public static var editorMaxMania:Int = 17;

	// ---- layout data ----
	public static var scales:Array<Float> = [
		0.9, // 1k
		0.85, // 2k
		0.8, // 3k
		0.7, // 4k
		0.66, // 5k
		0.6, // 6k
		0.55, // 7k
		0.5, // 8k
		0.46, // 9k
		0.39, // 10k
		0.36, // 11k
		0.32, // 12k
		0.31, // 13k
		0.31, // 14k
		0.3, // 15k
		0.26, // 16k
		0.26, // 17k
		0.22 // 18k
	];

	public static var lessX:Array<Int> = [
		0, // 1k
		0, // 2k
		0, // 3k
		0, // 4k
		0, // 5k
		8, // 6k
		7, // 7k
		8, // 8k
		8, // 9k
		7, // 10k
		6, // 11k
		6, // 12k
		8, // 13k
		7, // 14k
		6, // 15k
		7, // 16k
		6, // 17k
		6 // 18k
	];

	public static var noteSep:Array<Int> = [
		0, // 1k
		0, // 2k
		1, // 3k
		1, // 4k
		2, // 5k
		2, // 6k
		2, // 7k
		3, // 8k
		3, // 9k
		4, // 10k
		4, // 11k
		5, // 12k
		6, // 13k
		6, // 14k
		7, // 15k
		6, // 16k
		5, // 17k
		5 // 18k
	];

	public static var offsetX:Array<Float> = [
		150, // 1k
		89, // 2k
		0, // 3k
		0, // 4k
		0, // 5k
		0, // 6k
		0, // 7k
		0, // 8k
		0, // 9k
		0, // 10k
		0, // 11k
		0, // 12k
		0, // 13k
		0, // 14k
		0, // 15k
		0, // 16k
		0, // 17k
		0 // 18k
	];

	public static var restPosition:Array<Float> = [
		0, // 1k
		0, // 2k
		0, // 3k
		0, // 4k
		25, // 5k
		32, // 6k
		46, // 7k
		52, // 8k
		60, // 9k
		40, // 10k
		45, // 11k
		30, // 12k
		30, // 13k
		29, // 14k
		72, // 15k
		37, // 16k
		61, // 17k
		16 // 18k
	];

	public static var gridSizes:Array<Int> = [
		40, // 1k
		40, // 2k
		40, // 3k
		40, // 4k
		40, // 5k
		40, // 6k
		40, // 7k
		40, // 8k
		40, // 9k
		35, // 10k
		30, // 11k
		25, // 12k
		25, // 13k
		20, // 14k
		20, // 15k
		20, // 16k
		20, // 17k
		15 // 18k
	];

	public static var splashScales:Array<Float> = [
		1.3, // 1k
		1.2, // 2k
		1.1, // 3k
		1.0, // 4k
		1.0, // 5k
		0.9, // 6k
		0.8, // 7k
		0.7, // 8k
		0.6, // 9k
		0.5, // 10k
		0.4, // 11k
		0.3, // 12k
		0.3, // 13k
		0.3, // 14k
		0.2, // 15k
		0.18, // 16k
		0.18, // 17k
		0.15 // 18k
	];

	public static var pixelScales:Array<Float> = [
		1.2, // 1k
		1.15, // 2k
		1.1, // 3k
		1.0, // 4k
		0.9, // 5k
		0.83, // 6k
		0.8, // 7k
		0.74, // 8k
		0.7, // 9k
		0.6, // 10k
		0.55, // 11k
		0.5, // 12k
		0.48, // 13k
		0.48, // 14k
		0.42, // 15k
		0.38, // 16k
		0.38, // 17k
		0.32 // 18k
	];

	// ---- note colours ----
	/** Base colours of the four stock notes. */
	public static var baseNoteColors:Array<Array<Int>> = [
		[194, 75, 153], // left
		[0, 255, 255], // down
		[18, 250, 5], // up
		[246, 56, 62] // right
	];

	/**
	 * Multi-key colour table (each extended lane gets its own colour, not a mirror of the base):
	 * 0 left / 1 down / 2 up / 3 right / 4 space / 5 leftex1 / 6 downex1 / 7 upex1 / 8 rightex1
	 */
	public static var noteColors:Array<Array<Int>> = [
		[194, 75, 153], // left       purple
		[0, 255, 255], // down        cyan
		[18, 250, 5], // up          green
		[246, 56, 62], // right      red
		[204, 204, 204], // space    gray
		[255, 255, 0], // leftex1    yellow
		[139, 74, 255], // downex1   purple
		[255, 0, 0], // upex1        red
		[0, 51, 255] // rightex1     blue
	];

	/** Letter -> colour index (0-8). J~R map back onto A~I cyclically. */
	public static var letterColorIndex:Map<String, Int> = [
		'A' => 0,
		'B' => 1,
		'C' => 2,
		'D' => 3,
		'E' => 4,
		'F' => 5,
		'G' => 6,
		'H' => 7,
		'I' => 8,
		'J' => 0,
		'K' => 1,
		'L' => 2,
		'M' => 3,
		'N' => 4,
		'O' => 5,
		'P' => 6,
		'Q' => 7,
		'R' => 8
	];

	/** Letter -> reused base note texture index (0=left, 1=down, 2=up, 3=right). */
	public static var letterBaseTexture:Map<String, Int> = [
		'A' => 0,
		'B' => 1,
		'C' => 2,
		'D' => 3,
		'E' => 2, // space -> up
		'F' => 0,
		'G' => 1,
		'H' => 2,
		'I' => 3,
		'J' => 0,
		'K' => 1,
		'L' => 2,
		'M' => 3,
		'N' => 2,
		'O' => 0,
		'P' => 1,
		'Q' => 2,
		'R' => 3
	];

	static function buildKeysShit():Map<Int, Map<String, Dynamic>>
	{
		var base:Array<Map<String, Dynamic>> = [
			[
				'letters' => ['E'],
				'anims' => ['UP'],
				'strumAnims' => ['SPACE'],
				'pixelAnimIndex' => [4]
			],
			[
				'letters' => ['A', 'D'],
				'anims' => ['LEFT', 'RIGHT'],
				'strumAnims' => ['LEFT', 'RIGHT'],
				'pixelAnimIndex' => [0, 3]
			],
			[
				'letters' => ['A', 'E', 'D'],
				'anims' => ['LEFT', 'UP', 'RIGHT'],
				'strumAnims' => ['LEFT', 'SPACE', 'RIGHT'],
				'pixelAnimIndex' => [0, 4, 3]
			],
			[
				'letters' => ['A', 'B', 'C', 'D'],
				'anims' => ['LEFT', 'DOWN', 'UP', 'RIGHT'],
				'strumAnims' => ['LEFT', 'DOWN', 'UP', 'RIGHT'],
				'pixelAnimIndex' => [0, 1, 2, 3]
			],
			[
				'letters' => ['A', 'B', 'E', 'C', 'D'],
				'anims' => ['LEFT', 'DOWN', 'UP', 'UP', 'RIGHT'],
				'strumAnims' => ['LEFT', 'DOWN', 'SPACE', 'UP', 'RIGHT'],
				'pixelAnimIndex' => [0, 1, 4, 2, 3]
			],
			[
				'letters' => ['A', 'C', 'D', 'F', 'B', 'I'],
				'anims' => ['LEFT', 'UP', 'RIGHT', 'LEFT', 'DOWN', 'RIGHT'],
				'strumAnims' => ['LEFT', 'UP', 'RIGHT', 'LEFT', 'DOWN', 'RIGHT'],
				'pixelAnimIndex' => [0, 2, 3, 5, 1, 8]
			],
			[
				'letters' => ['A', 'C', 'D', 'E', 'F', 'B', 'I'],
				'anims' => ['LEFT', 'UP', 'RIGHT', 'UP', 'LEFT', 'DOWN', 'RIGHT'],
				'strumAnims' => ['LEFT', 'UP', 'RIGHT', 'SPACE', 'LEFT', 'DOWN', 'RIGHT'],
				'pixelAnimIndex' => [0, 2, 3, 4, 5, 1, 8]
			],
			[
				'letters' => ['A', 'B', 'C', 'D', 'F', 'G', 'H', 'I'],
				'anims' => ['LEFT', 'UP', 'DOWN', 'RIGHT', 'LEFT', 'DOWN', 'UP', 'RIGHT'],
				'strumAnims' => ['LEFT', 'DOWN', 'UP', 'RIGHT', 'LEFT', 'DOWN', 'UP', 'RIGHT'],
				'pixelAnimIndex' => [0, 1, 2, 3, 5, 6, 7, 8]
			],
			[
				'letters' => ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I'],
				'anims' => ['LEFT', 'DOWN', 'UP', 'RIGHT', 'UP', 'LEFT', 'DOWN', 'UP', 'RIGHT'],
				'strumAnims' => ['LEFT', 'DOWN', 'UP', 'RIGHT', 'SPACE', 'LEFT', 'DOWN', 'UP', 'RIGHT'],
				'pixelAnimIndex' => [0, 1, 2, 3, 4, 5, 6, 7, 8]
			]
		];

		var ret:Map<Int, Map<String, Dynamic>> = [];
		var nine:Map<String, Dynamic> = base[8];
		for (i in 0...18)
		{
			if (i < base.length)
			{
				ret.set(i, base[i]);
			}
			else
			{
				var letters:Array<String> = [];
				var anims:Array<String> = [];
				var strums:Array<String> = [];
				var pix:Array<Int> = [];
				var n:Int = i + 1;
				for (j in 0...n)
				{
					var k:Int = j % 9;
					letters.push((cast nine.get('letters'):Array<String>)[k]);
					anims.push((cast nine.get('anims'):Array<String>)[k]);
					strums.push((cast nine.get('strumAnims'):Array<String>)[k]);
					pix.push((cast nine.get('pixelAnimIndex'):Array<Int>)[k]);
				}
				ret.set(i, [
					'letters' => letters,
					'anims' => anims,
					'strumAnims' => strums,
					'pixelAnimIndex' => pix
				]);
			}
		}
		return ret;
	}

	public static function clampMania(mania:Int):Int
	{
		if (mania < minMania) return minMania;
		if (mania > maxMania) return maxMania;
		return mania;
	}

	/** Letter of a lane for a given key count. */
	public static function getLetter(mania:Int, lane:Int):String
	{
		var m:Int = clampMania(mania);
		var letters:Array<String> = keysShit.get(m).get('letters');
		if (lane < 0) lane = 0;
		if (lane >= letters.length) lane %= letters.length;
		return letters[lane];
	}

	/**
	 * Multi-key: key count (zero based) in effect at a time, for a given event list.
	 * Uses the most recent Change Mania event at or before that time;
	 * event value1 is 1-based (9 = 9K) while the internal mania is 0-based.
	 * events shape: [[strumTime, [[name, value1, value2], ...]], ...]
	 */
	/** Change Mania timeline cache (bulk chart loading; see maniaTimelineBuild). */
	private static var _mtEvents:Array<Dynamic> = null;
	private static var _mtBase:Int = -1;
	private static var _mtTimes:Array<Float> = [];
	private static var _mtManias:Array<Int> = [];

	/**
	 * Pre-builds the Change Mania event timeline: call once before the chart load loop.
	 * Every note then does one binary search through maniaAtTimeCached,
	 * replacing the per-note event scan (O(notes x events), which froze for seconds on dense charts).
	 * The events reference is validated with the base to prevent a stale cross-chart cache.
	 */
	public static function maniaTimelineBuild(events:Array<Dynamic>, baseMania:Int):Void
	{
		_mtEvents = events;
		_mtBase = clampMania(baseMania);
		_mtTimes.resize(0);
		_mtManias.resize(0);

		if (events == null) return;

		var rawTimes:Array<Float> = [];
		var rawIdx:Array<Int> = [];
		var rawManias:Array<Int> = [];

		var evI:Int = 0;
		for (event in events)
		{
			if (event == null || event[0] == null || event[1] == null) continue;
			var evTime:Float = Std.parseFloat(Std.string(event[0]));
			if (Math.isNaN(evTime)) continue;
			var subEvents:Array<Dynamic> = cast event[1];
			if (subEvents == null) continue;
			for (subEvent in subEvents)
			{
				if (subEvent == null || subEvent.length < 2) continue;
				if (Std.string(subEvent[0]) != 'Change Mania') continue;
				var newMania:Null<Int> = Std.parseInt(Std.string(subEvent[1]));
				if (newMania == null || Math.isNaN(newMania)) continue;
				rawTimes.push(evTime);
				rawIdx.push(evI);
				rawManias.push(clampMania(newMania - 1));
			}
			evI++;
		}

		var total:Int = rawTimes.length;
		if (total == 0) return;

		// Sort by (time, array order); the later entry wins at equal times, matching the original semantics
		var order:Array<Int> = [for (i in 0...total) i];
		order.sort(function(a:Int, b:Int):Int {
			if (rawTimes[a] != rawTimes[b]) return rawTimes[a] < rawTimes[b] ? -1 : 1;
			return rawIdx[a] - rawIdx[b];
		});

		for (oi in order)
		{
			var n:Int = _mtTimes.length;
			if (n > 0 && _mtTimes[n - 1] == rawTimes[oi])
				_mtManias[n - 1] = rawManias[oi];
			else
			{
				_mtTimes.push(rawTimes[oi]);
				_mtManias.push(rawManias[oi]);
			}
		}
	}

	/**
	 * Chart-load loop only: maniaTimelineBuild must have run on the same events array.
	 * O(1) without Change Mania events; a binary search O(log M) otherwise.
	 */
	public static function maniaAtTimeCached(time:Float):Int
	{
		var n:Int = _mtTimes.length;
		if (n == 0) return _mtBase;

		var lo:Int = 0;
		var hi:Int = n - 1;
		var idx:Int = -1;
		while (lo <= hi)
		{
			var mid:Int = (lo + hi) >> 1;
			if (_mtTimes[mid] <= time)
			{
				idx = mid;
				lo = mid + 1;
			}
			else hi = mid - 1;
		}
		return (idx < 0) ? _mtBase : _mtManias[idx];
	}

	/** Whether the cache points at the given events array (caller self-check / debugging). */
	public static function maniaTimelineMatches(events:Array<Dynamic>):Bool
	{
		return _mtEvents == events;
	}

	public static function effectiveManiaAtTime(events:Array<Dynamic>, baseMania:Int, time:Float):Int
	{
		var result:Int = clampMania(baseMania);
		if (events == null) return result;
		var lastEvTime:Float = Math.NEGATIVE_INFINITY;
		for (event in events)
		{
			if (event == null || event[0] == null || event[1] == null) continue;
			var evTime:Float = Std.parseFloat(Std.string(event[0]));
			if (Math.isNaN(evTime) || evTime > time) continue; // only events before this time
			var subEvents:Array<Dynamic> = cast event[1];
			if (subEvents == null) continue;
			for (subEvent in subEvents)
			{
				if (subEvent == null || subEvent.length < 2) continue;
				if (Std.string(subEvent[0]) != 'Change Mania') continue;
				var newMania:Null<Int> = Std.parseInt(Std.string(subEvent[1]));
				if (newMania != null && !Math.isNaN(newMania) && evTime >= lastEvTime)
				{
					// Latest event wins (array order aside); at equal times the later entry wins
					result = clampMania(newMania - 1);
					lastEvTime = evTime;
				}
			}
		}
		return result;
	}

	/**
	 * Multi-key: re-encodes one raw note from oldMania to newMania (order mapping).
 * - side (player/opponent) is preserved;
 * - lane is taken modulo the new key count (4K->9K keeps lanes 0~3 and leaves new lanes empty).
 * Event notes (raw < 0) are returned unchanged.
	 */
	public static function convertRawData(raw:Int, oldMania:Int, newMania:Int):Int
	{
		if (raw < 0) return raw;
		var oldAmmo:Int = ammo[clampMania(oldMania)];
		var newAmmo:Int = ammo[clampMania(newMania)];
		if (oldAmmo < 1 || newAmmo < 1) return raw;
		var side:Int = Std.int(raw / oldAmmo);
		if (side > 1) side = 1;
		var lane:Int = raw % oldAmmo;
		return side * newAmmo + (lane % newAmmo);
	}

	/** Multi-key: deep-copies the event list (event-edit diffing; no shared inner arrays). */
	public static function deepCopyEvents(events:Array<Dynamic>):Array<Dynamic>
	{
		if (events == null) return null;
		var ret:Array<Dynamic> = [];
		for (event in events)
		{
			if (event == null) { ret.push(null); continue; }
			var sub:Array<Dynamic> = [];
			if (event[1] != null)
			{
				var oldSub:Array<Dynamic> = cast event[1];
				for (s in oldSub)
				{
					if (s == null) { sub.push(null); continue; }
					sub.push([s[0], s[1], s[2]]);
				}
			}
			ret.push([event[0], sub]);
		}
		return ret;
	}

	/** Character animation suffix for a lane (LEFT/DOWN/UP/RIGHT/SPACE...). */
	public static function getAnim(mania:Int, lane:Int):String
	{
		var m:Int = clampMania(mania);
		var anims:Array<String> = keysShit.get(m).get('anims');
		if (lane < 0) lane = 0;
		if (lane >= anims.length) lane %= anims.length;
		return anims[lane];
	}

	/** Strum animation for a lane (LEFT/DOWN/UP/RIGHT/SPACE...). */
	public static function getStrumAnim(mania:Int, lane:Int):String
	{
		var m:Int = clampMania(mania);
		var strums:Array<String> = keysShit.get(m).get('strumAnims');
		if (lane < 0) lane = 0;
		if (lane >= strums.length) lane %= strums.length;
		return strums[lane];
	}

	/** Reused base note texture index (0-3). */
	public static function getBaseTexture(mania:Int, lane:Int):Int
	{
		return letterBaseTexture.get(getLetter(mania, lane));
	}

	/** Target lane colour (RGB). */
	public static function getLaneColor(mania:Int, lane:Int):Array<Int>
	{
		var idx:Int = letterColorIndex.get(getLetter(mania, lane));
		if (idx < 0 || idx >= noteColors.length) idx = lane % noteColors.length;
		return noteColors[idx];
	}

	/**
	 * ColorSwap values for a lane relative to its base texture.
	 * @return [hue (0~1 shift), saturation (0~1 shift), brightness (multiplier shift, same /100 semantics as arrowHSV)]
	 */
	public static function getLaneColorSwap(mania:Int, lane:Int):Array<Float>
	{
		var base:Int = getBaseTexture(mania, lane);
		var baseRGB:Array<Int> = baseNoteColors[base];
		var targetRGB:Array<Int> = getLaneColor(mania, lane);

		var baseHSV:Array<Float> = rgb2hsv(baseRGB);
		var targetHSV:Array<Float> = rgb2hsv(targetRGB);

		var hue:Float = targetHSV[0] - baseHSV[0];
		while (hue < 0) hue += 1;
		while (hue >= 1) hue -= 1;
		var sat:Float = targetHSV[1] - baseHSV[1];
		var brt:Float = (baseHSV[2] > 0.0001) ? (targetHSV[2] / baseHSV[2]) - 1 : 0;
		return [hue, sat, brt];
	}

	/** RGB (0-255) -> HSV (h:0~1, s:0~1, v:0~1)。 */
	public static function rgb2hsv(rgb:Array<Int>):Array<Float>
	{
		var r:Float = rgb[0] / 255;
		var g:Float = rgb[1] / 255;
		var b:Float = rgb[2] / 255;
		var max:Float = Math.max(r, Math.max(g, b));
		var min:Float = Math.min(r, Math.min(g, b));
		var d:Float = max - min;
		var h:Float = 0;
		if (d != 0)
		{
			if (max == r) h = ((g - b) / d) % 6;
			else if (max == g) h = ((b - r) / d) + 2;
			else h = ((r - g) / d) + 4;
			h *= 60;
			if (h < 0) h += 360;
			h /= 360;
		}
		var s:Float = (max == 0) ? 0 : d / max;
		return [h, s, max];
	}

	static var _loaded:Bool = false;

	/**
	 * Soft-coded overrides read from data/extraKeys/extraKeys.json.
	 * Overridable: scales, gridSizes, splashScales, pixelScales, lessX, separator,
	 * offsetX, restPosition, noteColors, baseNoteColors。
	 */
	public static function loadConfig():Void
	{
		if (_loaded) return;
		_loaded = true;
		#if sys
		var path:String = Paths.json('extraKeys/extraKeys');
		#if MODS_ALLOWED
		var modPath:String = Paths.modsJson('extraKeys/extraKeys');
		if (modPath != null && FileSystem.exists(modPath)) path = modPath;
		#end
		if (path == null || !FileSystem.exists(path)) return;
		try
		{
			var json:Dynamic = haxe.Json.parse(File.getContent(path));
			if (json == null) return;
			overlayFloats(json.scales, scales);
			overlayInts(json.gridSizes, gridSizes);
			overlayFloats(json.splashScales, splashScales);
			overlayFloats(json.pixelScales, pixelScales);
			overlayInts(json.lessX, lessX);
			overlayInts(json.separator, noteSep);
			overlayFloats(json.offsetX, offsetX);
			overlayFloats(json.restPosition, restPosition);
			if (json.noteColors != null && Std.isOfType(json.noteColors, Array))
				noteColors = cast json.noteColors;
			if (json.baseNoteColors != null && Std.isOfType(json.baseNoteColors, Array))
				baseNoteColors = cast json.baseNoteColors;
		}
		catch (e:Dynamic)
		{
			// A bad config must not stop the game
		}
		#end
	}

	static function overlayFloats(arr:Dynamic, target:Array<Float>):Void
	{
		if (arr == null || !Std.isOfType(arr, Array)) return;
		var a:Array<Dynamic> = cast arr;
		for (i in 0...a.length)
			if (i < target.length && Std.isOfType(a[i], Float)) target[i] = a[i];
	}

	static function overlayInts(arr:Dynamic, target:Array<Int>):Void
	{
		if (arr == null || !Std.isOfType(arr, Array)) return;
		var a:Array<Dynamic> = cast arr;
		for (i in 0...a.length)
			if (i < target.length && Std.isOfType(a[i], Int)) target[i] = a[i];
	}
}

/**
 * Key binding table.
 * Rendered by ControlsSubState and read by PlayState for key bindings.
 */
class Keybinds
{
	public static function optionShit():Array<Dynamic>
	{
		return [
			['1 KEY'],
			['Center', 'note_one1'],
			[''],
			['2 KEYS'],
			['Left', 'note_two1'],
			['Right', 'note_two2'],
			[''],
			['3 KEYS'],
			['Left', 'note_three1'],
			['Center', 'note_three2'],
			['Right', 'note_three3'],
			[''],
			['4 KEYS'],
			['Left', 'note_left'],
			['Down', 'note_down'],
			['Up', 'note_up'],
			['Right', 'note_right'],
			[''],
			['5 KEYS'],
			['Left', 'note_five1'],
			['Down', 'note_five2'],
			['Center', 'note_five3'],
			['Up', 'note_five4'],
			['Right', 'note_five5'],
			[''],
			['6 KEYS'],
			['Left 1', 'note_six1'],
			['Up', 'note_six2'],
			['Right 1', 'note_six3'],
			['Left 2', 'note_six4'],
			['Down', 'note_six5'],
			['Right 2', 'note_six6'],
			[''],
			['7 KEYS'],
			['Left 1', 'note_seven1'],
			['Up', 'note_seven2'],
			['Right 1', 'note_seven3'],
			['Center', 'note_seven4'],
			['Left 2', 'note_seven5'],
			['Down', 'note_seven6'],
			['Right 2', 'note_seven7'],
			[''],
			['8 KEYS'],
			['Left 1', 'note_eight1'],
			['Down 1', 'note_eight2'],
			['Up 1', 'note_eight3'],
			['Right 1', 'note_eight4'],
			['Left 2', 'note_eight5'],
			['Down 2', 'note_eight6'],
			['Up 2', 'note_eight7'],
			['Right 2', 'note_eight8'],
			[''],
			['9 KEYS'],
			['Left 1', 'note_nine1'],
			['Down 1', 'note_nine2'],
			['Up 1', 'note_nine3'],
			['Right 1', 'note_nine4'],
			['Center', 'note_nine5'],
			['Left 2', 'note_nine6'],
			['Down 2', 'note_nine7'],
			['Up 2', 'note_nine8'],
			['Right 2', 'note_nine9'],
			[''],
			['10 KEYS'],
			['Left 1', 'note_ten1'],
			['Down 1', 'note_ten2'],
			['Up 1', 'note_ten3'],
			['Right 1', 'note_ten4'],
			['Center 1', 'note_ten5'],
			['Center 2', 'note_ten6'],
			['Left 2', 'note_ten7'],
			['Down 2', 'note_ten8'],
			['Up 2', 'note_ten9'],
			['Right 2', 'note_ten10'],
			[''],
			['11 KEYS'],
			['Left 1', 'note_elev1'],
			['Down 1', 'note_elev2'],
			['Up 1', 'note_elev3'],
			['Right 1', 'note_elev4'],
			['Left 2', 'note_elev5'],
			['Center 2', 'note_elev6'],
			['Right 2', 'note_elev7'],
			['Left 3', 'note_elev8'],
			['Down 2', 'note_elev9'],
			['Up 2', 'note_elev10'],
			['Right 3', 'note_elev11'],
			[''],
			['12 KEYS'],
			['Left 1', 'note_twel1'],
			['Down 1', 'note_twel2'],
			['Up 1', 'note_twel3'],
			['Right 1', 'note_twel4'],
			['Left 2', 'note_twel5'],
			['Down 2', 'note_twel6'],
			['Up 2', 'note_twel7'],
			['Right 2', 'note_twel8'],
			['Left 3', 'note_twel9'],
			['Down 3', 'note_twel10'],
			['Up 3', 'note_twel11'],
			['Right 3', 'note_twel12'],
			[''],
			['13 KEYS'],
			['Left 1', 'note_thir1'],
			['Down 1', 'note_thir2'],
			['Up 1', 'note_thir3'],
			['Right 1', 'note_thir4'],
			['Left 2', 'note_thir5'],
			['Down 2', 'note_thir6'],
			['Center', 'note_thir7'],
			['Up 2', 'note_thir8'],
			['Right 2', 'note_thir9'],
			['Left 3', 'note_thir10'],
			['Down 3', 'note_thir11'],
			['Up 3', 'note_thir12'],
			['Right 3', 'note_thir13'],
			[''],
			['14 KEYS'],
			['Left 1', 'note_fourt1'],
			['Down 1', 'note_fourt2'],
			['Up 1', 'note_fourt3'],
			['Right 1', 'note_fourt4'],
			['Left 2', 'note_fourt5'],
			['Down 2', 'note_fourt6'],
			['Center 1', 'note_fourt7'],
			['Center 2', 'note_fourt8'],
			['Up 2', 'note_fourt9'],
			['Right 2', 'note_fourt10'],
			['Left 3', 'note_fourt11'],
			['Down 3', 'note_fourt12'],
			['Up 3', 'note_fourt13'],
			['Right 3', 'note_fourt14'],
			[''],
			['15 KEYS'],
			['Left 1', 'note_151'],
			['Down 1', 'note_152'],
			['Up 1', 'note_153'],
			['Right 1', 'note_154'],
			['Left 2', 'note_155'],
			['Down 2', 'note_156'],
			['Center 1', 'note_157'],
			['Center 2', 'note_158'],
			['Center 3', 'note_159'],
			['Up 2', 'note_1510'],
			['Right 2', 'note_1511'],
			['Left 3', 'note_1512'],
			['Down 3', 'note_1513'],
			['Up 3', 'note_1514'],
			['Right 3', 'note_1515'],
			[''],
			['16 KEYS'],
			['Left 1', 'note_161'],
			['Down 1', 'note_162'],
			['Up 1', 'note_163'],
			['Right 1', 'note_164'],
			['Left 2', 'note_165'],
			['Down 2', 'note_166'],
			['Up 2', 'note_167'],
			['Right 2', 'note_168'],
			['Left 3', 'note_169'],
			['Down 3', 'note_1610'],
			['Up 3', 'note_1611'],
			['Right 3', 'note_1612'],
			['Left 4', 'note_1613'],
			['Down 4', 'note_1614'],
			['Up 4', 'note_1615'],
			['Right 4', 'note_1616'],
			[''],
			['17 KEYS'],
			['Left 1', 'note_171'],
			['Down 1', 'note_172'],
			['Up 1', 'note_173'],
			['Right 1', 'note_174'],
			['Left 2', 'note_175'],
			['Down 2', 'note_176'],
			['Up 2', 'note_177'],
			['Right 2', 'note_178'],
			['Center', 'note_179'],
			['Left 3', 'note_1710'],
			['Down 3', 'note_1711'],
			['Up 3', 'note_1712'],
			['Right 3', 'note_1713'],
			['Left 4', 'note_1714'],
			['Down 4', 'note_1715'],
			['Up 4', 'note_1716'],
			['Right 4', 'note_1717'],
			[''],
			['18 KEYS FINAL'],
			['Left 1', 'note_181'],
			['Down 1', 'note_182'],
			['Up 1', 'note_183'],
			['Right 1', 'note_184'],
			['Center 1', 'note_185'],
			['Left 2', 'note_186'],
			['Down 2', 'note_187'],
			['Up 2', 'note_188'],
			['Right 2', 'note_189'],
			['Left 3', 'note_1810'],
			['Down 3', 'note_1811'],
			['Up 3', 'note_1812'],
			['Right 3', 'note_1813'],
			['Center 2', 'note_1814'],
			['Left 4', 'note_1815'],
			['Down 4', 'note_1816'],
			['Up 4', 'note_1817'],
			['Right 4', 'note_1818'],
			[''],
			['UI'],
			['Left', 'ui_left'],
			['Down', 'ui_down'],
			['Up', 'ui_up'],
			['Right', 'ui_right'],
			[''],
			['Reset', 'reset'],
			['Accept', 'accept'],
			['Back', 'back'],
			['Pause', 'pause'],
			[''],
			['VOLUME'],
			['Mute', 'volume_mute'],
			['Up', 'volume_up'],
			['Down', 'volume_down'],
			[''],
			['DEBUG'],
			['Key 1', 'debug_1'],
			['Key 2', 'debug_2']
		];
	}

	public static function fill():Array<Array<Dynamic>>
	{
		return [
			[ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_one1'))],
			[
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_two1')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_two2'))
			],
			[
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_three1')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_three2')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_three3'))
			],
			[
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_left')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_down')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_up')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_right'))
			],
			[
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_five1')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_five2')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_five3')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_five4')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_five5'))
			],
			[
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_six1')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_six2')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_six3')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_six4')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_six5')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_six6'))
			],
			[
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_seven1')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_seven2')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_seven3')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_seven4')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_seven5')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_seven6')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_seven7'))
			],
			[
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_eight1')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_eight2')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_eight3')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_eight4')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_eight5')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_eight6')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_eight7')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_eight8'))
			],
			[
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_nine1')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_nine2')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_nine3')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_nine4')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_nine5')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_nine6')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_nine7')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_nine8')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_nine9'))
			],
			[
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_ten1')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_ten2')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_ten3')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_ten4')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_ten5')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_ten6')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_ten7')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_ten8')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_ten9')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_ten10'))
			],
			[
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_elev1')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_elev2')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_elev3')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_elev4')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_elev5')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_elev6')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_elev7')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_elev8')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_elev9')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_elev10')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_elev11'))
			],
			[
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_twel1')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_twel2')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_twel3')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_twel4')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_twel5')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_twel6')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_twel7')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_twel8')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_twel9')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_twel10')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_twel11')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_twel12'))
			],
			[
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_thir1')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_thir2')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_thir3')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_thir4')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_thir5')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_thir6')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_thir7')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_thir8')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_thir9')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_thir10')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_thir11')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_thir12')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_thir13'))
			],
			[
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_fourt1')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_fourt2')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_fourt3')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_fourt4')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_fourt5')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_fourt6')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_fourt7')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_fourt8')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_fourt9')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_fourt10')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_fourt11')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_fourt12')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_fourt13')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_fourt14'))
			],
			[
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_151')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_152')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_153')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_154')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_155')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_156')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_157')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_158')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_159')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1510')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1511')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1512')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1513')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1514')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1515'))
			],
			[
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_161')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_162')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_163')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_164')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_165')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_166')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_167')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_168')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_169')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1610')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1611')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1612')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1613')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1614')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1615')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1616'))
			],
			[
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_171')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_172')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_173')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_174')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_175')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_176')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_177')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_178')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_179')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1710')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1711')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1712')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1713')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1714')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1715')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1716')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1717'))
			],
			[
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_181')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_182')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_183')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_184')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_185')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_186')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_187')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_188')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_189')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1810')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1811')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1812')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1813')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1814')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1815')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1816')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1817')),
				ClientPrefs.copyKey(ClientPrefs.keyBinds.get('note_1818'))
			]
		];
	}
}
