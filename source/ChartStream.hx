package;

import haxe.Json;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import sys.io.File;
import sys.io.FileInput;

/**
 * Byte-streaming parser for very large charts.
 *
 * Parsing the whole file reads the entire JSON text and builds a full DOM, which costs
 *
 *   1. scan() -- materialises everything except sectionNotes (section scalars / events /
 *      top-level fields) and records the byte range of every sectionNotes value.
 *   2. ChartSectionReader -- seeks to a section on demand, parses just those bytes and
 *      lets the caller drop the result immediately; the peak is a single section DOM.
 *
 * No chart semantics (format normalisation / note re-encoding) happen here; see
 * Song.tryLoadStreaming() and rewriteSectionNotes().
 *
 * Standard JSON only. Parse errors are caught by the caller, which falls back to a full parse.
 */

typedef ChartSectionRange = {
	/** Byte offset of the sectionNotes value (brackets included) in the file. */
	var start:Float;
	/** Byte length of that value. */
	var len:Int;
	/** Index into the chart's part list; 0 for an ordinary one-file chart. */
	var part:Int;
}

typedef ChartScanResult = {
	/** Top-level JSON object matching a full parse, except notes[].sectionNotes are empty. */
	var chart:Dynamic;
	/** One range per chart.notes (or chart.song.notes) entry. */
	var ranges:Array<ChartSectionRange>;
	/** Note entries counted while scanning; see Cursor.noteCount. Feeds PlayState's load budget. */
	var noteCount:Float;
	/**
	 * Whether any note entry contained a negative number. Only a legacy chart (<= 0.3.2) writes
	 * those: it stores events as negative-data notes, which Song.convert() / onLoadJson() turn back
	 * into events -- and that needs a materialised sectionNotes array, which a scan never builds.
	 * See Cursor.sawNegativeNote and maySynthesizeEvents().
	 */
	var sawNegativeNote:Bool;
}

/** One raw entry of a sectionNotes array, produced by ChartSectionReader.readNotes(). */
class ChartRawNote
{
	/** note[0] */
	public var strumTime:Float = 0;
	/** note[1], before Song.convert() remaps it */
	public var data:Float = 0;
	/** note[2], 0 when the entry has fewer than 3 elements */
	public var sustain:Float = 0;
	/** note[3]: String, numeric index, or null when the entry has fewer than 4 elements */
	public var type:Dynamic = null;
	/** Element count of the entry; Song.convert() uses length <= 3 to add a noteType. */
	public var count:Int = 0;

	public function new() {}
}

class ChartStream
{
	/** Charts below this size still take the whole-file path; streaming is only worth it on huge charts. */
	public static inline final MIN_STREAM_BYTES:Float = 64 * 1024 * 1024;

	/** Whether the chart file is large enough to be worth streaming. */
	public static function isLargeChart(path:String):Bool
	{
		#if sys
		try
		{
			var st = sys.FileSystem.stat(path);
			return st != null && st.size >= MIN_STREAM_BYTES;
		}
		catch (e:Dynamic)
		{
			return false;
		}
		#else
		return false;
		#end
	}

	/** Scans the skeleton of a one-file chart and records each section's sectionNotes byte range. */
	public static function scan(path:String):ChartScanResult
	{
		return scanPart(path, 0);
	}

	/** scan() for part `part` of a segmented chart: every recorded range carries that index. */
	static function scanPart(path:String, part:Int):ChartScanResult
	{
		var cur = new Cursor(path);
		var ranges:Array<ChartSectionRange> = [];
		try
		{
			cur.skipWs();
			var root:Dynamic = scanObject(cur, ranges, true, part);
			cur.skipWs();
			var counted:Float = cur.noteCount;
			cur.close();
			return { chart: root, ranges: ranges, noteCount: counted, sawNegativeNote: cur.sawNegativeNote };
		}
		catch (e:Dynamic)
		{
			cur.close();
			throw e;
		}
	}

	/**
	 * Scans several part files and merges them into ONE logical chart skeleton:
	 *
	 *   - notes[] is the concatenation of every part's notes[] in the given order;
	 *   - every range keeps the index of the file it came from (range.part), so
	 *     ChartSectionReader can seek in the right file;
	 *   - top-level metadata comes from the first part, because it describes the whole song;
	 *   - chart-level events from all parts are merged with exact duplicates dropped, so a real
	 *     time-split keeps its later events while a chart that was copied verbatim into every
	 *     part does not fire each event once per part.
	 *
	 * The caller unwraps the merged chart exactly once (see Song.tryLoadStreamingInner), so all
	 * parts have to use the same JSON shape -- psych 1.0 `{"song":{...}}` or flat.
	 */
	public static function scanParts(paths:Array<String>):ChartScanResult
	{
		if (paths == null || paths.length == 0)
			throw new haxe.Exception('ChartStream: no chart part to scan');
		var base:ChartScanResult = scanPart(paths[0], 0);
		if (paths.length < 2) return base;

		var sections:Array<Dynamic> = sectionArray(base.chart);
		if (sections == null)
			throw new haxe.Exception('ChartStream: chart part 0 has no notes[]');
		var ranges:Array<ChartSectionRange> = base.ranges;

		var eventsOwner:Dynamic = eventsSubObject(base.chart);
		var events:Array<Dynamic> = (eventsOwner != null) ? fieldArray(eventsOwner, 'events') : null;
		// The field is written back only when some part actually had one. Inventing an empty array
		// would make Song.convert() see a non-null events field and skip its extraction of events
		// that a legacy chart encodes as negative-data notes.
		var hadEvents:Bool = (events != null);
		if (events == null) events = [];
		var seen:Map<String, Bool> = new Map<String, Bool>();
		for (event in events) seen.set(Json.stringify(event), true);

		for (i in 1...paths.length)
		{
			var part:ChartScanResult = scanPart(paths[i], i);
			base.noteCount += part.noteCount;
			if (part.sawNegativeNote) base.sawNegativeNote = true;
			var partSections:Array<Dynamic> = sectionArray(part.chart);
			if (partSections == null)
				throw new haxe.Exception('ChartStream: chart part ' + i + ' has no notes[]');
			for (section in partSections) sections.push(section);
			for (range in part.ranges) ranges.push(range);

			var partEvents:Array<Dynamic> = (eventsOwner != null) ? fieldArray(eventsSubObject(part.chart), 'events') : null;
			if (partEvents != null)
			{
				hadEvents = true;
				for (event in partEvents)
				{
					var key:String = Json.stringify(event);
					if (seen.exists(key)) continue;
					seen.set(key, true);
					events.push(event);
				}
			}
			// The part's own skeleton is dropped from here on: only its section objects and byte
			// ranges survive, which is what keeps a 29-part chart's skeleton at tens of MB.
		}

		if (eventsOwner != null && hadEvents) Reflect.setField(eventsOwner, 'events', events);
		return base;
	}

	/**
	 * Whether a missing (or non-array) `events` field may be replaced with an empty array, i.e.
	 * whether the chart can still be streamed.
	 *
	 * `events` is optional in every Psych format and Song.onLoadJson() fills it in, so its absence is
	 * ordinary -- but it used to be the reason the streaming route was refused for a one-file chart,
	 * and a refused route means a full Json.parse of the file (for a 2 GB chart that is minutes and
	 * tens of GB: it is what froze song select on a chart without an events field).
	 *
	 * The one thing a skeleton cannot rebuild is a legacy chart (<= 0.3.2) that hides its events
	 * inside sectionNotes as negative-data notes: convert() / onLoadJson() move those into `events`,
	 * and sectionNotes are never materialised at scan time. The scan does see every byte of them, so
	 * it reports whether a note element was ever negative (sawNegativeNote) and only then is a full
	 * parse still required.
	 *
	 * `scanningParts`: a segmented chart has no one-file fallback at all, so refusing to stream it
	 * would not load it any other way either -- parts are scanned together and synthesising events
	 * has always been the accepted behaviour there, so the negative-note rule does not apply.
	 */
	public static function maySynthesizeEvents(scan:ChartScanResult, scanningParts:Bool):Bool
	{
		if (scan == null) return false;
		return scanningParts || !scan.sawNegativeNote;
	}

	/**
	 * The section array of a scanned chart: `song.notes` for psych 1.0 charts, `notes` otherwise.
	 * Mirrors the unwrap Song.tryLoadStreamingInner() performs on the very same object.
	 */
	static function sectionArray(chart:Dynamic):Array<Dynamic>
	{
		if (chart == null) return null;
		var sub:Dynamic = Reflect.field(chart, 'song');
		if (sub != null && Type.typeof(sub) == TObject)
		{
			var subNotes:Array<Dynamic> = fieldArray(sub, 'notes');
			if (subNotes != null) return subNotes;
		}
		return fieldArray(chart, 'notes');
	}

	/** The object that owns `events` in a scanned chart (the `song` sub-object when present). */
	static function eventsSubObject(chart:Dynamic):Dynamic
	{
		if (chart == null) return null;
		var sub:Dynamic = Reflect.field(chart, 'song');
		if (sub != null && Type.typeof(sub) == TObject) return sub;
		return chart;
	}

	static function fieldArray(obj:Dynamic, name:String):Array<Dynamic>
	{
		if (obj == null) return null;
		var value:Dynamic = Reflect.field(obj, name);
		return Std.isOfType(value, Array) ? cast value : null;
	}

	// ── byte-level note parsing ─────────────────────────────────────────────

	/**
	 * Parses the raw bytes of a sectionNotes value (a JSON array) into notes without
	 * building a DOM. Handles numbers, strings and null/true/false; anything else
	 * throws so the caller can fall back instead of silently dropping notes.
	 */
	public static function parseSectionNotes(b:Bytes, off:Int, len:Int):Array<ChartRawNote>
	{
		var out:Array<ChartRawNote> = [];
		var p:Int = off;
		var end:Int = off + len;
		p = noteWs(b, p, end);
		if (p >= end || b.get(p) != 91)
			throw new haxe.Exception('ChartStream: sectionNotes is not an array at byte ' + p);
		p++;
		while (true)
		{
			p = noteWs(b, p, end);
			if (p >= end) throw new haxe.Exception('ChartStream: unterminated sectionNotes at byte ' + p);
			var c:Int = b.get(p);
			if (c == 93) { p++; break; }
			if (c != 91) throw new haxe.Exception('ChartStream: expected note array at byte ' + p);
			p++;
			var n:ChartRawNote = new ChartRawNote();
			while (true)
			{
				p = noteWs(b, p, end);
				if (p >= end) throw new haxe.Exception('ChartStream: unterminated note at byte ' + p);
				var cc:Int = b.get(p);
				if (cc == 93) { p++; break; }
				var isStr:Bool = false;
				var isNull:Bool = false;
				var sval:String = null;
				var nval:Float = 0;
				if (cc == 34)
				{
					var rs = noteString(b, p, end);
					sval = rs.s;
					p = rs.p;
					isStr = true;
				}
				else if (cc == 110) { p += 4; isNull = true; }   // null
				else if (cc == 116) { p += 4; nval = 1; }        // true
				else if (cc == 102) { p += 5; }                  // false
				else
				{
					var rn = noteNumber(b, p, end);
					if (rn.p <= p) throw new haxe.Exception('ChartStream: bad number at byte ' + p);
					nval = rn.v;
					p = rn.p;
				}
				// Mirror Json.parse for index 3: keep the raw value. The consumer relies on
				// Std.isOfType(type, String) to tell an escaped name from a numeric index.
				if (isStr) n.type = sval;
				else if (!isNull)
					switch (n.count)
					{
						case 0: n.strumTime = nval;
						case 1: n.data = nval;
						case 2: n.sustain = nval;
						// Keep a numeric noteType as a number: the consumer uses
						// Std.isOfType(type, String) to tell an escaped name from an index.
						default: n.type = nval;
					}
				n.count++;
				p = noteWs(b, p, end);
				if (p < end && b.get(p) == 44) p++;
			}
			out.push(n);
			p = noteWs(b, p, end);
			if (p < end && b.get(p) == 44) p++;
		}
		return out;
	}

	static function noteWs(b:Bytes, p:Int, end:Int):Int
	{
		while (p < end)
		{
			var c:Int = b.get(p);
			if (c == 32 || c == 9 || c == 10 || c == 13) p++;
			else break;
		}
		return p;
	}

	/**
	 * Byte-level JSON number parser for note fields.
	 *
	 * Sign, integer digits and fraction digits are collected into one integer mantissa plus a
	 * fraction-digit count, then divided by an exact power of ten: for <= 15 significant digits
	 * (what chart numbers are) the mantissa and 10^frac are both exactly representable, so the
	 * single IEEE division is correctly rounded and matches Std.parseFloat() bit for bit -- without
	 * the per-number substring String that Std.parseFloat() would allocate for every note field.
	 *
	 * Exponents and > 15-digit mantissas are rare in charts and fall back to Std.parseFloat().
	 */
	static inline function noteNumber(b:Bytes, p:Int, end:Int):{v:Float, p:Int}
	{
		var s:Int = p;
		var neg:Bool = false;
		if (p < end && b.get(p) == 45)
		{
			neg = true;
			p++;
		}
		else if (p < end && b.get(p) == 43) p++;

		var mant:Float = 0;
		var digits:Int = 0;
		while (p < end)
		{
			var c:Int = b.get(p);
			if (c >= 48 && c <= 57)
			{
				mant = mant * 10 + (c - 48);
				digits++;
				p++;
			}
			else break;
		}

		var frac:Int = 0;
		if (p < end && b.get(p) == 46)
		{
			p++;
			while (p < end)
			{
				var c:Int = b.get(p);
				if (c >= 48 && c <= 57)
				{
					mant = mant * 10 + (c - 48);
					frac++;
					digits++;
					p++;
				}
				else break;
			}
		}

		if (digits == 0 || digits > 15 || (p < end && (b.get(p) == 101 || b.get(p) == 69)))
		{
			var stop:Int = p;
			while (stop < end)
			{
				var c:Int = b.get(stop);
				if ((c >= 48 && c <= 57) || c == 45 || c == 43 || c == 46 || c == 101 || c == 69) stop++;
				else break;
			}
			return { v: Std.parseFloat(b.getString(s, stop - s)), p: stop };
		}

		var v:Float = (frac > 0) ? mant / pow10(frac) : mant;
		return { v: neg ? -v : v, p: p };
	}

	/** 10^n, exact as a double for n <= 22; anything else falls back to Math.pow. */
	static inline function pow10(n:Int):Float
	{
		return switch (n)
		{
			case 0: 1.0;
			case 1: 10.0;
			case 2: 100.0;
			case 3: 1000.0;
			case 4: 10000.0;
			case 5: 100000.0;
			case 6: 1000000.0;
			case 7: 10000000.0;
			case 8: 100000000.0;
			case 9: 1000000000.0;
			case 10: 10000000000.0;
			case 11: 100000000000.0;
			case 12: 1000000000000.0;
			case 13: 10000000000000.0;
			case 14: 100000000000000.0;
			case 15: 1000000000000000.0;
			default: Math.pow(10, n);
		}
	}

	static function noteString(b:Bytes, p:Int, end:Int):{s:String, p:Int}
	{
		p++;
		var start:Int = p;
		var sb:StringBuf = null;
		while (true)
		{
			if (p >= end) throw new haxe.Exception('ChartStream: unterminated string in note');
			var c:Int = b.get(p);
			if (c == 92)
			{
				if (sb == null) sb = new StringBuf();
				sb.add(b.getString(start, p - start));
				p++;
				if (p >= end) throw new haxe.Exception('ChartStream: unterminated escape in note');
				var e:Int = b.get(p);
				switch (e)
				{
					case 110: sb.addChar(10);
					case 116: sb.addChar(9);
					case 114: sb.addChar(13);
					case 98: sb.addChar(8);
					case 102: sb.addChar(12);
					case 117:
						if (p + 4 >= end) throw new haxe.Exception('ChartStream: bad \\u escape in note');
						sb.addChar(Std.parseInt('0x' + b.getString(p + 1, 4)));
						p += 4;
					default: sb.addChar(e);
				}
				p++;
				start = p;
			}
			else if (c == 34)
			{
				if (sb == null) return { s: b.getString(start, p - start), p: p + 1 };
				sb.add(b.getString(start, p - start));
				return { s: sb.toString(), p: p + 1 };
			}
			else p++;
		}
		return null;
	}

	/**
	 * Re-encodes one note exactly like Song.convert() (old format -> psych_v1 convention).
	 * Streamed sectionNotes are not in memory, so the reader has to run this when it loads them.
	 * ammo follows convert()'s rule: chart-level mania, not the per-note Change Mania.
	 */
	public static function rewriteSectionNotes(notes:Array<Dynamic>, mustHitSection:Bool, ammo:Int,
		noteTypes:Array<String>):Void
	{
		if (notes == null) return;
		if (ammo <= 0) ammo = 4;
		var typeCount:Int = (noteTypes != null) ? noteTypes.length : 0;
		for (note in notes)
		{
			if (note == null) continue;
			var rawData:Int = Std.int(note[1]);
			if (rawData < 0) continue;
			var gottaHitNote:Bool = (rawData < ammo) ? mustHitSection : !mustHitSection;
			note[1] = (rawData % ammo) + (gottaHitNote ? 0 : ammo);

			if (note.length > 3 && !Std.isOfType(note[3], String) && note[3] != null)
			{
				var typeIdx:Int = Std.int(note[3]);
				if (typeIdx >= 0 && typeIdx < typeCount)
					note[3] = noteTypes[typeIdx];
				else
					note[3] = '';
			}
			else if (note.length <= 3)
			{
				note.push('');
			}
		}
	}

	// ── skeleton scan ───────────────────────────────────────────────────────

	static function scanObject(cur:Cursor, ranges:Array<ChartSectionRange>, allowNotes:Bool, part:Int):Dynamic
	{
		cur.expect(123); // {
		var obj:Dynamic = {};
		cur.skipWs();
		if (cur.peek() == 125)
		{
			cur.next();
			return obj;
		}
		while (true)
		{
			cur.skipWs();
			var key:String = Std.string(cur.captureValue());
			cur.skipWs();
			cur.expect(58); // :
			cur.skipWs();
			if (allowNotes && key == 'notes' && cur.peek() == 91)
				Reflect.setField(obj, key, scanNotes(cur, ranges, part));
			else if (cur.peek() == 123)
				Reflect.setField(obj, key, scanObject(cur, ranges, key == 'song', part));
			else
				Reflect.setField(obj, key, cur.captureValue());

			cur.skipWs();
			var c:Int = cur.next();
			if (c == 125) break;
			if (c != 44) throw new haxe.Exception('ChartStream: expected "," or "}" at byte ' + cur.pos);
		}
		return obj;
	}

	static function scanNotes(cur:Cursor, ranges:Array<ChartSectionRange>, part:Int):Array<Dynamic>
	{
		cur.expect(91); // [
		var arr:Array<Dynamic> = [];
		cur.skipWs();
		if (cur.peek() == 93)
		{
			cur.next();
			return arr;
		}
		while (true)
		{
			cur.skipWs();
			if (cur.peek() == 123)
			{
				var sec:Dynamic = {};
				ranges.push(scanSection(cur, sec, ranges, part));
				arr.push(sec);
			}
			else
			{
				ranges.push({ start: 0, len: 0, part: part });
				arr.push(cur.captureValue());
			}
			cur.skipWs();
			var c:Int = cur.next();
			if (c == 93) break;
			if (c != 44) throw new haxe.Exception('ChartStream: expected "," or "]" at byte ' + cur.pos);
		}
		return arr;
	}

	static function scanSection(cur:Cursor, sec:Dynamic, ranges:Array<ChartSectionRange>, part:Int):ChartSectionRange
	{
		cur.expect(123); // {
		var range:ChartSectionRange = { start: 0, len: 0, part: part };
		cur.skipWs();
		if (cur.peek() == 125)
		{
			cur.next();
			return range;
		}
		while (true)
		{
			cur.skipWs();
			var key:String = Std.string(cur.captureValue());
			cur.skipWs();
			cur.expect(58);
			cur.skipWs();
			if (key == 'sectionNotes')
			{
				// Record the range only; collecting the bytes would make the scan as slow as a
				// full read for GB-sized sectionNotes.
				var startPos:Float = cur.pos;
				cur.skipValueFast();
				range = { start: startPos, len: Std.int(cur.pos - startPos), part: part };
				// The field must be an empty array, not missing: tryLoadStreaming() runs
				// Song.convert() on this skeleton and convert() iterates sectionNotes, so a null
				// field crashes hxcpp with an ACCESS_VIOLATION that Haxe cannot catch.
				Reflect.setField(sec, 'sectionNotes', []);
			}
			else if (cur.peek() == 123)
				Reflect.setField(sec, key, scanObject(cur, ranges, false, part));
			else
				Reflect.setField(sec, key, cur.captureValue());

			cur.skipWs();
			var c:Int = cur.next();
			if (c == 125) break;
			if (c != 44) throw new haxe.Exception('ChartStream: expected "," or "}" at byte ' + cur.pos);
		}
		// A chart without sectionNotes still needs the empty array: the downstream convert /
		// generateSong paths iterate it directly.
		if (Reflect.field(sec, 'sectionNotes') == null) Reflect.setField(sec, 'sectionNotes', []);
		return range;
	}
}

/**
 * Per-section reader: keeps one chart file open and seeks + parses on demand.
 *
 * A chart may be split across several files (see ChartParts): `paths` lists them in the order
 * the ranges were recorded and every range names the part it lives in. Only one file is open at
 * a time -- sections are read in order, so the file changes at most once per part -- and the
 * seek state is shared, so it is only safe to use sequentially on one thread.
 */
class ChartSectionReader
{
	static inline final MAX_RANGE_BYTES:Int = 64 * 1024 * 1024;

	/** One file per chart part, indexed by ChartSectionRange.part. */
	var paths:Array<String>;
	var ranges:Array<ChartSectionRange>;
	var input:FileInput;
	/** Part whose file `input` holds; -1 while closed. */
	var openPart:Int = -1;
	/** Last failure reason (for the caller to trace); null on success. */
	public var lastError:String = null;

	/**
	 * `paths` describes the whole chart: a one-file chart just passes a single-element array.
	 * Nothing is opened here, so a part that cannot be read is reported by the first read that
	 * needs it rather than by the constructor.
	 */
	public function new(paths:Array<String>, ranges:Array<ChartSectionRange>)
	{
		this.paths = paths;
		this.ranges = ranges;
	}

	/** How many sections this reader can serve (one range per section). */
	public function sectionCount():Int
		return (ranges == null) ? 0 : ranges.length;

	/** File that holds section `index`, or null when the index is out of range. */
	public function pathOf(index:Int):String
	{
		if (ranges == null || index < 0 || index >= ranges.length) return null;
		var r:ChartSectionRange = ranges[index];
		if (r == null || paths == null || r.part < 0 || r.part >= paths.length) return null;
		return paths[r.part];
	}

	/** Opens the part file `part` belongs to, closing whatever was open before. */
	function handle(part:Int):FileInput
	{
		if (input != null && part == openPart) return input;
		closeInput();
		if (paths == null || part < 0 || part >= paths.length)
			throw new haxe.Exception('ChartStream: no file for chart part ' + part);
		input = File.read(paths[part], true);
		openPart = part;
		return input;
	}

	function closeInput():Void
	{
		if (input != null)
		{
			input.close();
			input = null;
		}
		openPart = -1;
	}

	/** Raw note array of section `index`; empty array when the range is missing or empty, null on read failure. */
	public function read(index:Int):Array<Dynamic>
	{
		if (ranges == null || index < 0 || index >= ranges.length) return [];
		var r:ChartSectionRange = ranges[index];
		if (r == null || r.len <= 0) return [];
		if (r.len > MAX_RANGE_BYTES) return null;
		try
		{
			var source:FileInput = handle(r.part);
			source.seek(Std.int(r.start), sys.io.FileSeek.SeekBegin);
			var b:Bytes = Bytes.alloc(r.len);
			source.readFullBytes(b, 0, r.len);
			lastError = null;
			return cast Json.parse(b.toString());
		}
		catch (e:Dynamic)
		{
			lastError = Std.string(e);
			return null;
		}
	}

	/**
	 * Same bytes as read(), parsed straight into notes instead of a JSON DOM.
	 * Equivalent per entry (see tools/online_probe/ChartStreamProbe). Returns null on
	 * failure so the caller can decide.
	 */
	public function readNotes(index:Int):Array<ChartRawNote>
	{
		if (ranges == null || index < 0 || index >= ranges.length) return [];
		var r:ChartSectionRange = ranges[index];
		if (r == null || r.len <= 0) return [];
		if (r.len > MAX_RANGE_BYTES) return null;
		try
		{
			var source:FileInput = handle(r.part);
			source.seek(Std.int(r.start), sys.io.FileSeek.SeekBegin);
			var b:Bytes = Bytes.alloc(r.len);
			source.readFullBytes(b, 0, r.len);
			lastError = null;
			return ChartStream.parseSectionNotes(b, 0, r.len);
		}
		catch (e:Dynamic)
		{
			lastError = Std.string(e);
			return null;
		}
	}

	public function close():Void
	{
		closeInput();
	}
}

/** Chunked byte cursor that understands JSON structure without building objects. */
private class Cursor
{
	static inline final BUFSIZE:Int = 1 << 20;
	static inline final MAX_DEPTH:Int = 64;

	var input:FileInput;
	var buf:Bytes;
	var bufPos:Int = 0;
	var bufLen:Int = 0;
	var atEof:Bool = false;
	var collect:BytesBuffer = null;
	/** Note entries seen by skipValueFast(); see ChartScanResult.noteCount. */
	public var noteCount:Float = 0;
	/** Negative note elements seen by skipValueFast(); see ChartScanResult.sawNegativeNote. */
	public var sawNegativeNote:Bool = false;
	/** Bytes consumed == absolute offset of the next byte to read. */
	public var pos:Float = 0;

	public function new(path:String)
	{
		input = File.read(path, true);
		buf = Bytes.alloc(BUFSIZE);
		fill();
	}

	public function close():Void
	{
		if (input != null)
		{
			input.close();
			input = null;
		}
	}

	function fill():Void
	{
		bufPos = 0;
		bufLen = 0;
		// FileInput.readBytes raises Eof at exactly 0 bytes read rather than returning 0, so
		// the end of file has to be caught; a short final read still returns real bytes to keep.
		try
		{
			bufLen = input.readBytes(buf, 0, buf.length);
		}
		catch (e:haxe.io.Eof)
		{
			bufLen = 0;
		}
		if (bufLen < 0) bufLen = 0;
		atEof = (bufLen == 0);
	}

	public function peek():Int
	{
		if (bufPos >= bufLen)
		{
			if (atEof) return -1;
			fill();
			if (bufLen == 0) return -1;
		}
		return buf.get(bufPos);
	}

	public function next():Int
	{
		var c:Int = peek();
		if (c < 0) return -1;
		bufPos++;
		pos += 1;
		if (collect != null) collect.addByte(c);
		return c;
	}

	public function expect(ch:Int):Void
	{
		var c:Int = next();
		if (c != ch) throw new haxe.Exception('ChartStream: expected byte ' + ch + ' at ' + pos + ', got ' + c);
	}

	public function skipWs():Void
	{
		while (true)
		{
			var c:Int = peek();
			if (c == 32 || c == 9 || c == 10 || c == 13) next();
			else break;
		}
	}

	/** Consumes one complete JSON value and collects its raw bytes. */
	public function captureRaw():Bytes
	{
		collect = new BytesBuffer();
		skipValue(0);
		var b:Bytes = collect.getBytes();
		collect = null;
		return b;
	}

	public function captureValue():Dynamic
	{
		var b:Bytes = captureRaw();
		if (b.length == 0) return null;
		return Json.parse(b.toString());
	}

	public function skipValue(depth:Int):Void
	{
		if (depth > MAX_DEPTH) throw new haxe.Exception('ChartStream: nesting deeper than ' + MAX_DEPTH + ' at byte ' + pos);
		skipWs();
		var c:Int = peek();
		if (c < 0) throw new haxe.Exception('ChartStream: unexpected end of file at byte ' + pos);
		switch (c)
		{
			case 123: skipObject(depth);   // {
			case 91: skipArray(depth);     // [
			case 34: skipString();         // "
			case 116: skipLiteral('true');
			case 102: skipLiteral('false');
			case 110: skipLiteral('null');
			default: skipNumber();
		}
	}

	/**
	 * Like skipValue(0), but the hot path is a flat byte state machine over the buffer
	 * instead of per-byte peek()/next() calls. sectionNotes accounts for ~95% of a large
	 * chart file, so this is where scan() spends nearly all of its time.
	 * Only valid while collect == null.
	 */
	public function skipValueFast():Void
	{
		skipWs();
		var c0:Int = peek();
		if (c0 < 0) throw new haxe.Exception('ChartStream: unexpected end of file at byte ' + pos);
		if (c0 == 34) { skipString(); return; }
		if (c0 == 116) { skipLiteral('true'); return; }
		if (c0 == 102) { skipLiteral('false'); return; }
		if (c0 == 110) { skipLiteral('null'); return; }
		if (c0 != 123 && c0 != 91) { skipNumber(); return; }

		var depth:Int = 0;
		var inStr:Bool = false;
		var esc:Bool = false;
		var chunkStart:Int = bufPos;
		while (true)
		{
			var b:Bytes = buf;
			var end:Int = bufLen;
			var p:Int = bufPos;
			while (p < end)
			{
				var c:Int = b.get(p++);
				if (inStr)
				{
					if (esc) esc = false;
					else if (c == 92) esc = true;
					else if (c == 34) inStr = false;
				}
				else if (c == 34) inStr = true;
				// '-' at note-element depth. A note element is never negative in a current chart, so
				// this is the legacy "event stored as a note" marker; only a leading sign counts, so an
				// exponent (1e-5) is not mistaken for one.
				else if (c == 45 && depth == 2 && numberSign(b, p - 2, chunkStart)) sawNegativeNote = true;
				else if (c == 123 || c == 91)
				{
					// A '[' at depth 1 is one note entry of the sectionNotes array being skipped.
					if (c == 91 && depth == 1) noteCount++;
					depth++;
				}
				else if (c == 125 || c == 93)
				{
					depth--;
					if (depth <= 0)
					{
						bufPos = p;
						pos += (p - chunkStart);
						return;
					}
				}
			}
			// Chunk consumed: account for it, then refill (fill() resets bufPos/bufLen).
			bufPos = p;
			pos += (p - chunkStart);
			fill();
			if (bufLen == 0) throw new haxe.Exception('ChartStream: unexpected end of file at byte ' + pos);
			chunkStart = 0;
		}
	}

	function skipObject(depth:Int):Void
	{
		next(); // {
		skipWs();
		if (peek() == 125)
		{
			next();
			return;
		}
		while (true)
		{
			skipWs();
			skipString();
			skipWs();
			expect(58); // :
			skipValue(depth + 1);
			skipWs();
			var c:Int = next();
			if (c == 125) return;
			if (c != 44) throw new haxe.Exception('ChartStream: expected "," or "}" at byte ' + pos);
		}
	}

	function skipArray(depth:Int):Void
	{
		next(); // [
		skipWs();
		if (peek() == 93)
		{
			next();
			return;
		}
		while (true)
		{
			skipValue(depth + 1);
			skipWs();
			var c:Int = next();
			if (c == 93) return;
			if (c != 44) throw new haxe.Exception('ChartStream: expected "," or "]" at byte ' + pos);
		}
	}

	function skipString():Void
	{
		next(); // opening quote
		while (true)
		{
			var c:Int = next();
			if (c < 0) throw new haxe.Exception('ChartStream: unterminated string at byte ' + pos);
			if (c == 92)
			{
				next(); // escaped char
				continue;
			}
			if (c == 34) return;
		}
	}

	function skipLiteral(word:String):Void
	{
		for (i in 0...word.length)
		{
			var c:Int = next();
			if (c != StringTools.fastCodeAt(word, i))
				throw new haxe.Exception('ChartStream: bad literal at byte ' + pos);
		}
	}

	/**
	 * Whether the byte at `idx` ends a value boundary, i.e. a '-' after it starts a new number
	 * rather than continuing one ("1e-5"). `chunkStart` is the first index of the current buffer
	 * chunk: a sign there has no readable byte before it, and counting it as a sign errs towards the
	 * safe answer (a fallback to the full parse).
	 */
	static function numberSign(b:Bytes, idx:Int, chunkStart:Int):Bool
	{
		if (idx < chunkStart) return true;
		var c:Int = b.get(idx);
		return c == 91 || c == 44 || c == 32 || c == 9 || c == 10 || c == 13; // '[' ',' or whitespace
	}

	function skipNumber():Void
	{
		while (true)
		{
			var c:Int = peek();
			if (c < 0) return;
			var isNum:Bool = (c >= 48 && c <= 57) || c == 45 || c == 43 || c == 46 || c == 101 || c == 69;
			if (!isNum) return;
			next();
		}
	}
}
