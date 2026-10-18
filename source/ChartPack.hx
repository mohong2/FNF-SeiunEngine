package;

import haxe.Int64;
import haxe.Json;
import haxe.io.Bytes;
import sys.FileSystem;
import sys.io.File;

/**
 * Packed chart container ("SEIUNPK1").
 *
 * A chart JSON is stored as:
 *   - a skeleton: every byte except the contents of each sectionNotes array, with a NUL byte
 *     where the array belongs (deflated).  Section objects, unknown fields, events and all
 *     formatting survive byte for byte;
 *   - a group stream: one record per distinct (time, lane, sustain, type) inside a section,
 *     plus a repeat count.  A 1.4 GB spam chart collapses from 64 M note entries to ~200 k
 *     groups.
 *
 * readNotes() expands a section's groups into ChartRawNote values carrying repeat, so the
 * existing generateSong loop can feed the same notes to the GhostCollapser without allocating
 * a DTO per duplicate.
 *
 * The file format is produced by tools/chartpack/chartpack.mjs.  All integers are little
 * endian; compressed streams use the zlib wrapper (haxe.zip.Uncompress).
 */
class ChartPack
{
	public static inline final EXT:String = '.chartpack';
	public static inline final MAGIC:String = 'SEIUNPK1';

	static var cache:Map<String, ChartPackData> = new Map();

	public static function isPack(path:String):Bool
	{
		return path != null && path.toLowerCase().endsWith(EXT);
	}

	/** Loaded pack for `path`, or null when it is not a pack. Cached per path for the session. */
	public static function load(path:String):ChartPackData
	{
		if (!isPack(path)) return null;
		var data:ChartPackData = cache.get(path);
		if (data == null)
		{
			data = new ChartPackData(path);
			cache.set(path, data);
		}
		return data;
	}

	public static function clearCache():Void
	{
		cache = new Map();
	}

	/**
	 * Scan result for a pack part: the skeleton chart and one range per section.  `range.start`
	 * is the section index (not a byte offset); ChartSectionReader passes it to Data.readNotes().
	 */
	public static function scan(path:String, part:Int):ChartStream.ChartScanResult
	{
		var data:ChartPackData = load(path);
		if (data == null) throw 'ChartPack: not a pack: ' + path;
		var chart:Dynamic = Json.parse(data.skeletonJson);
		var ranges:Array<ChartStream.ChartSectionRange> = [];
		var count:Int = data.sectionGroups.length;
		for (i in 0...count)
			ranges.push({start: i * 1.0, len: 0, part: part});
		return {
			chart: chart,
			ranges: ranges,
			noteCount: data.noteCount,
			sawNegativeNote: false
		};
	}

	/** Whether any path in the list is a pack (used to skip native JSON scanning). */
	public static function anyPack(paths:Array<String>):Bool
	{
		if (paths == null) return false;
		for (path in paths)
			if (isPack(path)) return true;
		return false;
	}
}

/** One decoded pack file. */
class ChartPackData
{
	public var path:String;
	public var header:Dynamic;
	public var skeletonJson:String;
	public var groupRaw:Bytes;
	public var sectionOffsets:Array<Int> = [];
	public var sectionGroups:Array<Int> = [];
	public var noteCount:Int64 = Int64.ofInt(0);
	public var base:Float = 0;
	public var timeMode:String = 'tick';
	public var sustains:Array<String> = [];
	public var types:Array<Dynamic> = [];

	public function new(path:String)
	{
		this.path = path;
		var b:Bytes = File.getBytes(path);
		if (b.length < 12 || b.getString(0, 8) != ChartPack.MAGIC)
			throw 'ChartPack: bad magic in ' + path;
		var p:Int = 8;
		var headerLen:Int = b.getInt32(p); p += 4;
		if (headerLen <= 0 || p + headerLen > b.length)
			throw 'ChartPack: bad header length in ' + path;
		header = Json.parse(b.getString(p, headerLen)); p += headerLen;
		base = header.base;
		timeMode = (header.timeMode == 'float') ? 'float' : 'tick';
		sustains = cast header.sustains;
		types = cast header.types;
		var groups:Array<Dynamic> = cast header.sectionGroups;
		for (g in groups) sectionGroups.push(Std.int(g));

		var skelCompLen:Int = b.getInt32(p); p += 4;
		var skelRawLen:Int = b.getInt32(p); p += 4;
		var skelComp:Bytes = b.sub(p, skelCompLen); p += skelCompLen;
		var groupCompLen:Int = b.getInt32(p); p += 4;
		var groupRawLen:Int = b.getInt32(p); p += 4;
		var groupComp:Bytes = b.sub(p, groupCompLen); p += groupCompLen;

		var skelBytes:Bytes = haxe.zip.Uncompress.run(skelComp);
		if (skelBytes.length != skelRawLen)
			throw 'ChartPack: skeleton length mismatch in ' + path;
		// NUL marks where a sectionNotes array used to be.
		skeletonJson = skelBytes.toString().split(String.fromCharCode(0)).join('[]');

		groupRaw = haxe.zip.Uncompress.run(groupComp);
		if (groupRaw.length != groupRawLen)
			throw 'ChartPack: group stream length mismatch in ' + path;

		// Index every section and total the expanded note count.  Group ticks are relative to the
		// previous group *inside the section*, so a section can be decoded on its own.
		var cursor:PackCursor = new PackCursor(groupRaw, 0);
		var total:Int64 = Int64.ofInt(0);
		for (i in 0...sectionGroups.length)
		{
			sectionOffsets.push(cursor.pos);
			var n:Int = sectionGroups[i];
			for (j in 0...n)
			{
				if (timeMode == 'float') cursor.skip(8); // double time
				else cursor.varint(); // tick delta
				cursor.varint(); // lane
				cursor.varint(); // sustain index
				cursor.varint(); // type index
				var repeat:Int = cursor.varint();
				total = total + repeat;
			}
		}
		noteCount = total;
	}

	/** Groups of section `section`, expanded to one ChartRawNote per distinct key with repeat set. */
	public function readNotes(section:Int):Array<ChartStream.ChartRawNote>
	{
		var out:Array<ChartStream.ChartRawNote> = [];
		if (section < 0 || section >= sectionGroups.length) return out;
		var cursor:PackCursor = new PackCursor(groupRaw, sectionOffsets[section]);
		var n:Int = sectionGroups[section];
		var prevTick:Int = 0;
		for (i in 0...n)
		{
			var time:Float;
			if (timeMode == 'float')
				time = cursor.double();
			else
			{
				var tick:Int = prevTick + zigzag(cursor.varint());
				prevTick = tick;
				// Do NOT scale by 1e6 before Math.round: Haxe's Math.round returns a 32-bit Int, and
				// tick * base * 1e6 is ~3.5e11 for a 6-minute chart, so it wraps and every note lands
				// near the start.  tick * base is already in milliseconds (Float).
				time = tick * base;
			}
			var lane:Int = zigzag(cursor.varint());
			var si:Int = cursor.varint();
			var ti:Int = cursor.varint();
			var repeat:Int = cursor.varint();
			var note:ChartStream.ChartRawNote = new ChartStream.ChartRawNote();
			note.strumTime = time;
			note.data = lane;
			note.sustain = (si >= 0 && si < sustains.length) ? Std.parseFloat(sustains[si]) : 0;
			var ty:Dynamic = (ti >= 0 && ti < types.length) ? types[ti] : null;
			if (ty == null || ty.kind == 0)
			{
				note.type = null;
				note.count = 3;
			}
			else
			{
				note.type = ty.value;
				note.count = 4;
			}
			note.repeat = repeat;
			out.push(note);
		}
		return out;
	}

	static inline function zigzag(n:Int):Int
	{
		return (n >>> 1) ^ -(n & 1);
	}
}

/** Little cursor over the inflated group stream. */
private class PackCursor
{
	public var b:Bytes;
	public var pos:Int;

	public function new(b:Bytes, pos:Int)
	{
		this.b = b;
		this.pos = pos;
	}

	public function skip(n:Int):Void
	{
		pos += n;
	}

	public function double():Float
	{
		var v:Float = b.getDouble(pos);
		pos += 8;
		return v;
	}

	public function varint():Int
	{
		var result:Int = 0;
		var shift:Int = 0;
		var c:Int;
		do
		{
			c = b.get(pos++);
			result |= (c & 0x7F) << shift;
			shift += 7;
		}
		while ((c & 0x80) != 0);
		return result;
	}
}
