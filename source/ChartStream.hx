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
}

typedef ChartScanResult = {
	/** Top-level JSON object matching a full parse, except notes[].sectionNotes are empty. */
	var chart:Dynamic;
	/** One range per chart.notes (or chart.song.notes) entry. */
	var ranges:Array<ChartSectionRange>;
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

	/** Scans the skeleton and records each section's sectionNotes byte range. */
	public static function scan(path:String):ChartScanResult
	{
		var cur = new Cursor(path);
		var ranges:Array<ChartSectionRange> = [];
		try
		{
			cur.skipWs();
			var root:Dynamic = scanObject(cur, ranges, true);
			cur.skipWs();
			cur.close();
			return { chart: root, ranges: ranges };
		}
		catch (e:Dynamic)
		{
			cur.close();
			throw e;
		}
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

	static inline function noteNumber(b:Bytes, p:Int, end:Int):{v:Float, p:Int}
	{
		var s:Int = p;
		while (p < end)
		{
			var c:Int = b.get(p);
			if ((c >= 48 && c <= 57) || c == 45 || c == 43 || c == 46 || c == 101 || c == 69) p++;
			else break;
		}
		return { v: Std.parseFloat(b.getString(s, p - s)), p: p };
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

	static function scanObject(cur:Cursor, ranges:Array<ChartSectionRange>, allowNotes:Bool):Dynamic
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
				Reflect.setField(obj, key, scanNotes(cur, ranges));
			else if (cur.peek() == 123)
				Reflect.setField(obj, key, scanObject(cur, ranges, key == 'song'));
			else
				Reflect.setField(obj, key, cur.captureValue());

			cur.skipWs();
			var c:Int = cur.next();
			if (c == 125) break;
			if (c != 44) throw new haxe.Exception('ChartStream: expected "," or "}" at byte ' + cur.pos);
		}
		return obj;
	}

	static function scanNotes(cur:Cursor, ranges:Array<ChartSectionRange>):Array<Dynamic>
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
				ranges.push(scanSection(cur, sec, ranges));
				arr.push(sec);
			}
			else
			{
				ranges.push({ start: 0, len: 0 });
				arr.push(cur.captureValue());
			}
			cur.skipWs();
			var c:Int = cur.next();
			if (c == 93) break;
			if (c != 44) throw new haxe.Exception('ChartStream: expected "," or "]" at byte ' + cur.pos);
		}
		return arr;
	}

	static function scanSection(cur:Cursor, sec:Dynamic, ranges:Array<ChartSectionRange>):ChartSectionRange
	{
		cur.expect(123); // {
		var range:ChartSectionRange = { start: 0, len: 0 };
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
				range = { start: startPos, len: Std.int(cur.pos - startPos) };
				// The field must be an empty array, not missing: tryLoadStreaming() runs
				// Song.convert() on this skeleton and convert() iterates sectionNotes, so a null
				// field crashes hxcpp with an ACCESS_VIOLATION that Haxe cannot catch.
				Reflect.setField(sec, 'sectionNotes', []);
			}
			else if (cur.peek() == 123)
				Reflect.setField(sec, key, scanObject(cur, ranges, false));
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
 * Per-section reader: opens the file once and seeks + parses on demand.
 * The seek state is shared, so it is only safe to use sequentially on one thread.
 */
class ChartSectionReader
{
	static inline final MAX_RANGE_BYTES:Int = 64 * 1024 * 1024;

	var input:FileInput;
	var ranges:Array<ChartSectionRange>;
	/** Last failure reason (for the caller to trace); null on success. */
	public var lastError:String = null;

	public function new(path:String, ranges:Array<ChartSectionRange>)
	{
		input = File.read(path, true);
		this.ranges = ranges;
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
			input.seek(Std.int(r.start), sys.io.FileSeek.SeekBegin);
			var b:Bytes = Bytes.alloc(r.len);
			input.readFullBytes(b, 0, r.len);
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
			input.seek(Std.int(r.start), sys.io.FileSeek.SeekBegin);
			var b:Bytes = Bytes.alloc(r.len);
			input.readFullBytes(b, 0, r.len);
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
		if (input != null)
		{
			input.close();
			input = null;
		}
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
				else if (c == 123 || c == 91) depth++;
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
