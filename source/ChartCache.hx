package;

import haxe.Int64;
import haxe.crypto.Md5;
import haxe.io.Bytes;
import mohong.TraceManager;
import sys.FileSystem;
import sys.io.File;
import sys.io.FileInput;
import sys.io.FileOutput;

import Note.PreloadedChartNote;

/** Note object the cache stores and restores. */
typedef CachedNote = PreloadedChartNote;

/** A note list read back from the cache, with the loop state that belongs to it. */
typedef CachedNotes = {
	/** Packed columns: a cache hit must not materialise the multi-million-element DTO array. */
	var notes:ChartNotes;
	/**
	 * Raw tap count the fold consumed (PlayState._turboRawTapCount); 0 when the load did not fold.
	 *
	 * Int64, like ChartStream.ChartScanResult.noteCount and for the same reason: it totals a whole
	 * (possibly segmented) chart rather than indexing anything, so an Int would wrap silently at 2^31
	 * while still looking correct. Stored in the header's second 8 byte slot, SECOND_OFFSET.
	 */
	var fedNotes:Int64;
	/** Whether the list was folded, i.e. one DTO may stand for several chart notes. */
	var folded:Bool;
	/** Note types the chart used, for the custom_notetypes script lookup. */
	var noteTypes:Array<String>;
}

/** How each column of the note record is stored in one cache file. */
private class NotePlan
{
	/** Bit c: column c has the same value in every record, so it is stored once. */
	public var constDoubles:Int = 0;
	public var constDoubleValue:Array<Float> = [];
	/** Bit c: column c is 0 in at least one record, so records carry a bit for it. */
	public var zeroDoubles:Int = 0;
	/** Columns not covered by constDoubles, ascending. */
	public var varDoubles:Array<Int> = [];
	/** Whether records carry the per-record zero mask at all. */
	public var zeroable:Bool = false;
	public var constStrings:Int = 0;
	public var constStringValue:Array<Int> = [];
	public var varStrings:Array<Int> = [];
	public function new() {}
}

/** Sequential reader over one decompressed record block. */
private class BlockCursor
{
	public var bytes:Bytes;
	public var pos:Int = 0;
	public function new() {}
	public inline function f64():Float { var v:Float = bytes.getDouble(pos); pos += 8; return v; }
	public inline function u16():Int { var v:Int = bytes.getUInt16(pos); pos += 2; return v; }
	public inline function u8():Int { var v:Int = bytes.get(pos); pos += 1; return v; }
	public inline function i8():Int { var v:Int = bytes.get(pos); pos += 1; return (v & 0x80) != 0 ? v - 256 : v; }
}

/**
 * On-disk cache of the note list a streamed chart produces.
 *
 * Loading a huge chart is dominated by work that depends only on the chart bytes and a handful of
 * settings: the skeleton scan (ChartStream), the per-section parse (ChartSectionReader /
 * ChartPrefetch), the fold (TurboDensity) and the sort (ChartSort). A second load of the same chart
 * with the same settings therefore produces the same PreloadedChartNote list, so that list is kept
 * next to the executable and replayed instead of recomputed.
 *
 * What is cached is the output of PlayState.generateSong's note loop -- the full DTO per record,
 * never an index into a mutable array -- so a cache hit cannot silently address the wrong note. A
 * file is used only while every chart part keeps its size and modification time and the caller's
 * configuration string is unchanged; anything else is a miss and the file is rewritten.
 *
 * The record is column-compressed, because in a real note list most columns do not vary at all:
 * measured on a 12.6M-note list, 7 of the 12 Float columns, all 5 String columns and the whole
 * splash block held one value. Columns that never vary are stored once in the file header, columns
 * that are usually zero cost one bit each, and the remaining bytes are deflated in 1 MB blocks.
 * That took the same list from 1.78 GB to a few MB without giving up load speed: only one block
 * (at most 1 MB) is ever held in memory while reading or writing.
 *
 * The module holds no gameplay policy (it never reads ClientPrefs): the caller decides whether the
 * cache may be used, what belongs in the configuration string, and whether to compress.
 */
class ChartCache
{
	/**
	 * Layout revision. Bump when a record field, its meaning or the fold rules change.
	 *
	 * 3: the header's two counters are 8 byte haxe.Int64 (they were 4 byte Int32, which capped a note
	 * total at 2^31-1) and the fields around them moved 16/20 -> 16/24, so a file written by revision
	 * 2 must never be read. fileFor() mixes this revision into the name hash, so such a file is never
	 * opened; the FORMAT check in loadNotes()/loadSkeleton() also deletes one that is reached anyway,
	 * and prune() reclaims whatever is left on disk under MAX_TOTAL_BYTES.
	 */
	public static inline final FORMAT:Int = 3;

	static inline final MAGIC:Int = 0x53454E43; // "SENC"
	static inline final KIND_NOTES:Int = 1;
	static inline final KIND_SKELETON:Int = 2;

	/*
	 * Header layout, byte for byte. Every integer goes through haxe.io.Bytes, whose 64 bit helpers
	 * are implemented in Haxe (getInt64 = make(getInt32(pos+4), getInt32(pos)), setInt64 =
	 * setInt32(pos, low) then setInt32(pos+4, high)) on top of little-endian 32 bit helpers, so
	 * these offsets do not depend on the host's byte order:
	 *
	 *   offset  size   type    .notes                .skel
	 *   0       4      Int32   MAGIC                 MAGIC
	 *   4       4      Int32   FORMAT                FORMAT
	 *   8       4      Int32   KIND_NOTES            KIND_SKELETON
	 *   12      4      Int32   header text length    header text length
	 *   16      8      Int64   record count          serialized payload length
	 *   24      8      Int64   fed note count        scan note count
	 *   32      len    text    buildHeader() text    buildHeader() text
	 *   ...     rest   bytes   record blocks         haxe.Serializer payload
	 *
	 * A revision 2 file was 24 bytes: magic, format, kind, header length, count (Int32) and fed count
	 * (Int32). Read with the offsets above it would be misread -- bytes 20..27 would be taken as one
	 * Int64, splicing the old fed count with the first four header bytes -- which is why the revision
	 * is part of the name hash and is checked again in loadNotes()/loadSkeleton().
	 */

	/** magic, format, kind, header text length, then the two counters below. */
	static inline final PREFIX_BYTES:Int = 32;

	/**
	 * First counter. .notes: records in the body. .skel: bytes of serialized payload after the
	 * header. Both are Int64 in the file, but a record loop bound and a Bytes length are Int by
	 * construction (haxe.io.Bytes/Array lengths are Int32), so the reader validates the value and
	 * then narrows it explicitly instead of truncating it.
	 */
	static inline final COUNT_OFFSET:Int = 16;

	/**
	 * Second counter. .notes: raw note count the fold consumed (CachedNotes.fedNotes). .skel: the
	 * ChartScanResult note count, which cannot ride inside the serialized payload: haxe.Serializer
	 * has no Int64 representation (on cpp it returns one as a plain Int when the value fits 32 bits
	 * and as a cpp::Int64 object otherwise), and its Float path is only good to 15 significant
	 * digits. A raw 8 byte field is exact across the whole range.
	 */
	static inline final SECOND_OFFSET:Int = 24;

	/** 2^31 - 1: the largest count or byte length that can be addressed with a row Int index. */
	static inline final INT32_LIMIT:Int = 0x7FFFFFFF;

	/** Float columns of a PreloadedChartNote, in the order the record stores them. */
	static inline final DOUBLE_COLUMNS:Int = 12;
	/** String columns, after the Float ones. */
	static inline final STRING_COLUMNS:Int = 5;

	/** A record block is written at record boundaries and never exceeds this many raw bytes. */
	static inline final BLOCK_BYTES:Int = 1 << 20;
	/** Longest record the layout can produce; keeps a record inside a single block. */
	static inline final MAX_RECORD_BYTES:Int = 2 + DOUBLE_COLUMNS * 8 + 1 + 24 + STRING_COLUMNS * 2 + 1 + 1 + 2;
	/** deflate level for the record blocks (the payload is highly repetitive, so this is cheap). */
	static inline final COMPRESS_LEVEL:Int = 6;

	/**
	 * String index meaning "no string" (noteSplashTexture is nullable).
	 *
	 * Nothing here may be named after a common SDK macro: these constants become declarations in the
	 * generated C++ header, which compiles next to the Windows SDK, and winspool.h already defines
	 * `STRING_NONE` as 0x00000001 -- that turned its declaration into `static int 0x00000001;`.
	 */
	static inline final NO_STRING_INDEX:Int = 0xFFFF;

	static inline final CACHE_DIR:String = 'chart_cache/';
	static inline final NOTES_EXT:String = '.notes';
	static inline final SKELETON_EXT:String = '.skel';

	/**
	 * Cache files are pruned down to this much after every write. The literal is written as a Float
	 * on purpose: Int arithmetic would wrap this past 2^31 and the budget would end up 0, which
	 * makes prune() delete the file that was just written.
	 */
	static inline final MAX_TOTAL_BYTES:Float = 8.0 * 1024 * 1024 * 1024;

	static var _dirReady:Bool = false;

	// ── location ────────────────────────────────────────────────────────────

	/** Directory the cache lives in, created on first use. */
	public static function cacheDir():String
	{
		if (!_dirReady)
		{
			_dirReady = true;
			try FileSystem.createDirectory(CACHE_DIR) catch (e:Dynamic) {}
		}
		return CACHE_DIR;
	}

	/** Identity of the chart bytes: every part's size and modification time, in order. */
	public static function sourceSignature(paths:Array<String>):String
	{
		if (paths == null) return '';
		var b:StringBuf = new StringBuf();
		for (path in paths)
		{
			b.add(normalizePath(path));
			b.add(':');
			var st:sys.FileStat = null;
			try st = FileSystem.stat(path) catch (e:Dynamic) {}
			if (st == null)
				b.add('missing');
			else
			{
				b.add(st.size);
				b.add('@');
				b.add(Std.int(st.mtime.getTime()));
			}
			b.add(';');
		}
		return b.toString();
	}

	/** Deletes every cache file and returns how many bytes were freed (the "clear chart cache" option). */
	public static function clear():Float
	{
		var freed:Float = 0;
		for (name in listFiles())
		{
			var path:String = CACHE_DIR + name;
			try
			{
				if (FileSystem.isDirectory(path)) continue;
				var st:sys.FileStat = FileSystem.stat(path);
				if (st != null) freed += st.size;
				FileSystem.deleteFile(path);
			}
			catch (e:Dynamic) {}
		}
		return freed;
	}

	// ── notes ───────────────────────────────────────────────────────────────

	/**
	 * Note list of \`paths\` as produced by an earlier load, or null when there is no usable cache:
	 * no file, another format revision, different chart bytes, a different configuration string, or
	 * a damaged file. A damaged file is deleted so it can never be read again; a stale one is simply
	 * overwritten by the next save.
	 */
	public static function loadNotes(paths:Array<String>, config:String):CachedNotes
	{
		#if sys
		if (paths == null || paths.length == 0 || config == null) return null;
		var path:String = fileFor(paths, NOTES_EXT);
		var input:FileInput = null;
		try
		{
			if (!FileSystem.exists(path)) return null;
			var stat:sys.FileStat = FileSystem.stat(path);
			input = File.read(path, true);

			var prefix:Bytes = Bytes.alloc(PREFIX_BYTES);
			readFull(input, prefix, 0, PREFIX_BYTES);
			if (prefix.getInt32(0) != MAGIC || prefix.getInt32(4) != FORMAT || prefix.getInt32(8) != KIND_NOTES)
			{
				input.close();
				deleteFile(path);
				return null;
			}

			var headerLen:Int = prefix.getInt32(12);
			// Both counters are 8 byte Int64 fields. A count that does not fit an Int32 cannot describe
			// a file this class wrote: rejecting it takes the same damaged-file path as a bad magic
			// instead of narrowing the value silently.
			var count:Int = countToInt(prefix.getInt64(COUNT_OFFSET));
			var fed:Int64 = prefix.getInt64(SECOND_OFFSET);
			if (headerLen <= 0 || count < 0 || stat.size < PREFIX_BYTES + headerLen)
			{
				input.close();
				deleteFile(path);
				return null;
			}

			var headerBytes:Bytes = Bytes.alloc(headerLen);
			readFull(input, headerBytes, 0, headerLen);
			var header = parseHeader(headerBytes.getString(0, headerLen));
			if (header == null || header.src != sourceSignature(paths) || header.cfg != config)
			{
				input.close();
				return null;
			}

			var table:Array<String> = readStringTable(input);
			var plan:NotePlan = readPlan(input);
			// The header is intact and describes this chart, so the counter is real: trace it if it is
			// past the largest value an Int32 could hold. Diagnostics only.
			reportCountPastLimit('cached note list fed count', fed);

			// Built as packed columns, one record at a time. The estimate only seeds the column
			// capacity; hoisted (constant) columns never allocate at all, so it must stay small.
			var notes:ChartNotes = ChartNotes.builder(4096);
			if (count > 0)
			{
				var cursor:BlockCursor = new BlockCursor();
				// One reusable DTO for the whole decode; append() copies it into the columns.
				var scratch:CachedNote = blankNote();
				var block:Bytes = null;
				var rawLen:Int = 0;
				var decoded:Int = 0;
				while (decoded < count)
				{
					if (block == null)
					{
						var head:Bytes = Bytes.alloc(8);
						readFull(input, head, 0, 8);
						rawLen = head.getInt32(0);
						var stored:Int = head.getInt32(4);
						if (rawLen <= 0 || rawLen > BLOCK_BYTES || stored <= 0 || stored > BLOCK_BYTES * 2)
							throw new haxe.Exception('ChartCache: bad record block ' + rawLen + '/' + stored);
						var payload:Bytes = Bytes.alloc(stored);
						readFull(input, payload, 0, stored);
						block = header.compressed ? haxe.zip.Uncompress.run(payload) : payload;
						if (block.length != rawLen)
							throw new haxe.Exception('ChartCache: block decoded to ' + block.length + ', expected ' + rawLen);
						cursor.bytes = block;
						cursor.pos = 0;
					}
					while (cursor.pos < rawLen && decoded < count)
					{
						decodeInto(cursor, plan, table, scratch);
						notes.append(scratch);
						decoded++;
					}
					block = null;
				}
			}
			input.close();
			return { notes: notes, fedNotes: fed, folded: header.folded, noteTypes: header.types };
		}
		catch (e:Dynamic)
		{
			if (input != null) try input.close() catch (e2:Dynamic) {}
			// A truncated or corrupt file must never be read again.
			deleteFile(path);
			return null;
		}
		#else
		return null;
		#end
	}

	/**
	 * Writes the note list of \`paths\` for \`config\`. Failures are silent: a cache that cannot be
	 * written only means the next load parses the chart again.
	 */
	public static function saveNotes(paths:Array<String>, config:String, notes:ChartNotes,
		fedNotes:Int64, folded:Bool, noteTypes:Array<String>, compress:Bool = true):Void
	{
		#if sys
		if (paths == null || paths.length == 0 || notes == null || notes.length == 0) return;
		var dest:String = fileFor(paths, NOTES_EXT);
		var tmp:String = dest + '.tmp';
		var out:FileOutput = null;
		try
		{
			if (FileSystem.exists(tmp)) FileSystem.deleteFile(tmp);

			// First pass: the string table, the live count and every column that never varies. A
			// column that is constant across the whole list costs nothing per record.
			var table:Array<String> = [''];
			var index:Map<String, Int> = new Map<String, Int>();
			index.set('', 0);
			var plan:NotePlan = new NotePlan();
			plan.constDoubleValue = [];
			for (col in 0...DOUBLE_COLUMNS) plan.constDoubleValue[col] = 0;
			plan.constDoubles = (1 << DOUBLE_COLUMNS) - 1;
			plan.constStringValue = [];
			for (col in 0...STRING_COLUMNS) plan.constStringValue[col] = 0;
			plan.constStrings = (1 << STRING_COLUMNS) - 1;
			var count:Int = 0;
			var zeroDoubles:Int = 0;
			for (note in notes)
			{
				if (note == null) continue;
				for (col in 0...DOUBLE_COLUMNS)
				{
					var value:Float = doubleAt(note, col);
					if (count == 0)
						plan.constDoubleValue[col] = value;
					else if ((plan.constDoubles & (1 << col)) != 0 && value != plan.constDoubleValue[col])
						plan.constDoubles &= ~(1 << col);
					if (value == 0) zeroDoubles |= (1 << col);
				}
				for (col in 0...STRING_COLUMNS)
				{
					var strIndex:Int = addString(table, index, stringAt2(note, col));
					if (count == 0)
						plan.constStringValue[col] = strIndex;
					else if ((plan.constStrings & (1 << col)) != 0 && strIndex != plan.constStringValue[col])
						plan.constStrings &= ~(1 << col);
				}
				count++;
			}
			if (count == 0) return;
			plan.zeroDoubles = zeroDoubles & ~plan.constDoubles;
			plan.zeroable = plan.zeroDoubles != 0;
			buildPlan(plan);

			out = File.write(tmp, true);
			var prefix:Bytes = Bytes.alloc(PREFIX_BYTES);
			prefix.setInt32(0, MAGIC);
			prefix.setInt32(4, FORMAT);
			prefix.setInt32(8, KIND_NOTES);
			var headerBytes:Bytes = Bytes.ofString(buildHeader(sourceSignature(paths), config, folded, compress, noteTypes));
			prefix.setInt32(12, headerBytes.length);
			// The header's counters are 8 byte Int64, so the record count is not capped at 2^31. `count`
			// is an Int here only because a row index is one.
			prefix.setInt64(COUNT_OFFSET, Int64.ofInt(count));
			prefix.setInt64(SECOND_OFFSET, fedNotes);
			reportCountPastLimit('chart cache fed count', fedNotes);
			out.writeBytes(prefix, 0, PREFIX_BYTES);
			out.writeBytes(headerBytes, 0, headerBytes.length);
			writeStringTable(out, table);
			writePlan(out, plan);

			var block:Bytes = Bytes.alloc(BLOCK_BYTES);
			var filled:Int = 0;
			for (note in notes)
			{
				if (note == null) continue;
				// Only whole records go into a block, so the reader never has to carry a partial one.
				if (filled + MAX_RECORD_BYTES > BLOCK_BYTES)
				{
					flushBlock(out, block, filled, compress);
					filled = 0;
				}
				filled = encodeRecord(block, filled, note, plan, index);
			}
			if (filled > 0) flushBlock(out, block, filled, compress);
			out.close();
			out = null;

			if (FileSystem.exists(dest)) FileSystem.deleteFile(dest);
			FileSystem.rename(tmp, dest);
			prune();
		}
		catch (e:Dynamic)
		{
			if (out != null) try out.close() catch (e2:Dynamic) {}
			deleteFile(tmp);
		}
		#end
	}

	// ── record blocks ───────────────────────────────────────────────────────

	/** Appends one block: raw length, stored length, then the (optionally deflated) bytes. */
	static function flushBlock(out:FileOutput, block:Bytes, filled:Int, compress:Bool):Void
	{
		var stored:Int = filled;
		var payload:Bytes = block;
		if (compress)
		{
			payload = haxe.zip.Compress.run(block.sub(0, filled), COMPRESS_LEVEL);
			stored = payload.length;
		}
		var head:Bytes = Bytes.alloc(8);
		head.setInt32(0, filled);
		head.setInt32(4, stored);
		out.writeBytes(head, 0, 8);
		out.writeBytes(payload, 0, stored);
	}

	// ── record layout ───────────────────────────────────────────────────────
	// Field order is shared by encodeRecord() and decodeRecord(); buildPlan() derives the column
	// lists both sides walk. Bump FORMAT when any of it changes.

	static function encodeRecord(b:Bytes, o:Int, n:CachedNote, plan:NotePlan, index:Map<String, Int>):Int
	{
		if (plan.zeroable)
		{
			var mask:Int = 0;
			for (k in 0...plan.varDoubles.length)
			{
				var col:Int = plan.varDoubles[k];
				if ((plan.zeroDoubles & (1 << col)) != 0 && doubleAt(n, col) == 0) mask |= (1 << k);
			}
			b.setUInt16(o, mask);
			o += 2;
			for (k in 0...plan.varDoubles.length)
			{
				if ((mask & (1 << k)) != 0) continue;
				b.setDouble(o, doubleAt(n, plan.varDoubles[k]));
				o += 8;
			}
		}
		else
		{
			for (col in plan.varDoubles)
			{
				b.setDouble(o, doubleAt(n, col));
				o += 8;
			}
		}

		var splash:Int = 0;
		if (n.noteSplashHue != null) splash |= 1;
		if (n.noteSplashSat != null) splash |= 2;
		if (n.noteSplashBrt != null) splash |= 4;
		b.set(o++, splash);
		if ((splash & 1) != 0) { b.setDouble(o, n.noteSplashHue); o += 8; }
		if ((splash & 2) != 0) { b.setDouble(o, n.noteSplashSat); o += 8; }
		if ((splash & 4) != 0) { b.setDouble(o, n.noteSplashBrt); o += 8; }

		for (col in plan.varStrings)
		{
			b.setUInt16(o, stringIndex(index, stringAt2(n, col)));
			o += 2;
		}

		b.set(o++, n.noteData & 0xFF);
		b.set(o++, n.mania & 0xFF);
		b.setUInt16(o, boolFlags(n));
		o += 2;
		return o;
	}

	/** Blank DTO shape. The decoder overwrites every field, so one instance can be reused. */
	static function blankNote():CachedNote
	{
		return {
			strumTime: 0,
			sustainLength: 0,
			parentST: 0,
			parentSL: 0,
			stepCrochet: 0,
			hitHealth: 0.023,
			missHealth: 0.0475,
			multSpeed: 1,
			multAlpha: 1,
			noteDensity: 1,
			offsetX: 0,
			offsetY: 0,
			noteSplashHue: null,
			noteSplashSat: null,
			noteSplashBrt: null,
			noteType: '',
			animSuffix: '',
			noteskin: '',
			texture: '',
			noteSplashTexture: null,
			noteData: 0,
			mania: -1,
			mustPress: false,
			oppNote: false,
			gfNote: false,
			noAnimation: false,
			noMissAnimation: false,
			isSustainNote: false,
			isSustainEnd: false,
			hitCausesMiss: false,
			ignoreNote: false,
			blockHit: false,
			lowPriority: false,
			wasHit: false,
			noteSplashDisabled: false,
			hitsoundDisabled: false
		};
	}

	/**
	 * Decodes one record into `note`. The caller passes a reusable instance: decoding into a
	 * scratch instead of returning a fresh DTO removes one allocation per record, i.e. 12.6M
	 * garbage objects on a dense chart, which is what kept the cache-hit path's block-pool
	 * high-water mark several hundred MB above the cold path's.
	 */
	static function decodeInto(cur:BlockCursor, plan:NotePlan, table:Array<String>, note:CachedNote):Void
	{
		// The plan writes the splash fields only when their bit is set, so a reused instance would
		// otherwise keep the previous record's values.
		note.noteSplashHue = null;
		note.noteSplashSat = null;
		note.noteSplashBrt = null;

		for (col in 0...DOUBLE_COLUMNS)
			if ((plan.constDoubles & (1 << col)) != 0) setDoubleAt(note, col, plan.constDoubleValue[col]);
		for (col in 0...STRING_COLUMNS)
			if ((plan.constStrings & (1 << col)) != 0) setStringAt(note, col, stringAt(table, plan.constStringValue[col]));

		if (plan.zeroable)
		{
			var mask:Int = cur.u16();
			for (k in 0...plan.varDoubles.length)
				setDoubleAt(note, plan.varDoubles[k], ((mask & (1 << k)) != 0) ? 0 : cur.f64());
		}
		else
		{
			for (col in plan.varDoubles) setDoubleAt(note, col, cur.f64());
		}

		var splash:Int = cur.u8();
		if ((splash & 1) != 0) note.noteSplashHue = cur.f64();
		if ((splash & 2) != 0) note.noteSplashSat = cur.f64();
		if ((splash & 4) != 0) note.noteSplashBrt = cur.f64();

		for (col in plan.varStrings)
			setStringAt(note, col, stringAt(table, cur.u16()));

		note.noteData = cur.i8();
		note.mania = cur.i8();
		var flags:Int = cur.u16();
		note.mustPress = (flags & 1) != 0;
		note.oppNote = (flags & 2) != 0;
		note.gfNote = (flags & 4) != 0;
		note.noAnimation = (flags & 8) != 0;
		note.noMissAnimation = (flags & 16) != 0;
		note.isSustainNote = (flags & 32) != 0;
		note.isSustainEnd = (flags & 64) != 0;
		note.hitCausesMiss = (flags & 128) != 0;
		note.ignoreNote = (flags & 256) != 0;
		note.blockHit = (flags & 512) != 0;
		note.lowPriority = (flags & 1024) != 0;
		note.wasHit = (flags & 2048) != 0;
		note.noteSplashDisabled = (flags & 4096) != 0;
		note.hitsoundDisabled = (flags & 8192) != 0;
	}

	/** Single-shot decode for callers that want their own instance. */
	static function decodeRecord(cur:BlockCursor, plan:NotePlan, table:Array<String>):CachedNote
	{
		var note:CachedNote = blankNote();
		decodeInto(cur, plan, table, note);
		return note;
	}

	static function boolFlags(n:CachedNote):Int
	{
		var flags:Int = 0;
		if (n.mustPress) flags |= 1;
		if (n.oppNote) flags |= 2;
		if (n.gfNote) flags |= 4;
		if (n.noAnimation) flags |= 8;
		if (n.noMissAnimation) flags |= 16;
		if (n.isSustainNote) flags |= 32;
		if (n.isSustainEnd) flags |= 64;
		if (n.hitCausesMiss) flags |= 128;
		if (n.ignoreNote) flags |= 256;
		if (n.blockHit) flags |= 512;
		if (n.lowPriority) flags |= 1024;
		if (n.wasHit) flags |= 2048;
		if (n.noteSplashDisabled) flags |= 4096;
		if (n.hitsoundDisabled) flags |= 8192;
		return flags;
	}

	static inline function doubleAt(n:CachedNote, col:Int):Float
	{
		return switch (col)
		{
			case 0: n.strumTime;
			case 1: n.sustainLength;
			case 2: n.parentST;
			case 3: n.parentSL;
			case 4: n.stepCrochet;
			case 5: n.hitHealth;
			case 6: n.missHealth;
			case 7: n.multSpeed;
			case 8: n.multAlpha;
			case 9: n.noteDensity;
			case 10: n.offsetX;
			default: n.offsetY;
		}
	}

	static inline function setDoubleAt(n:CachedNote, col:Int, v:Float):Void
	{
		switch (col)
		{
			case 0: n.strumTime = v;
			case 1: n.sustainLength = v;
			case 2: n.parentST = v;
			case 3: n.parentSL = v;
			case 4: n.stepCrochet = v;
			case 5: n.hitHealth = v;
			case 6: n.missHealth = v;
			case 7: n.multSpeed = v;
			case 8: n.multAlpha = v;
			case 9: n.noteDensity = v;
			case 10: n.offsetX = v;
			default: n.offsetY = v;
		}
	}

	static inline function stringAt2(n:CachedNote, col:Int):String
	{
		return switch (col)
		{
			case 0: n.noteType;
			case 1: n.animSuffix;
			case 2: n.noteskin;
			case 3: n.texture;
			default: n.noteSplashTexture;
		}
	}

	static inline function setStringAt(n:CachedNote, col:Int, v:String):Void
	{
		switch (col)
		{
			case 0: n.noteType = v;
			case 1: n.animSuffix = v;
			case 2: n.noteskin = v;
			case 3: n.texture = v;
			default: n.noteSplashTexture = v;
		}
	}

	/** Fills the column lists both encodeRecord() and decodeRecord() walk. */
	static function buildPlan(plan:NotePlan):Void
	{
		plan.varDoubles = [];
		for (col in 0...DOUBLE_COLUMNS)
			if ((plan.constDoubles & (1 << col)) == 0) plan.varDoubles.push(col);
		plan.varStrings = [];
		for (col in 0...STRING_COLUMNS)
			if ((plan.constStrings & (1 << col)) == 0) plan.varStrings.push(col);
	}

	static function writePlan(out:FileOutput, plan:NotePlan):Void
	{
		var head:Bytes = Bytes.alloc(2);
		head.setUInt16(0, plan.constDoubles);
		out.writeBytes(head, 0, 2);
		for (col in 0...DOUBLE_COLUMNS)
		{
			if ((plan.constDoubles & (1 << col)) == 0) continue;
			var v:Bytes = Bytes.alloc(8);
			v.setDouble(0, plan.constDoubleValue[col]);
			out.writeBytes(v, 0, 8);
		}
		var sHead:Bytes = Bytes.alloc(1);
		sHead.set(0, plan.constStrings);
		out.writeBytes(sHead, 0, 1);
		for (col in 0...STRING_COLUMNS)
		{
			if ((plan.constStrings & (1 << col)) == 0) continue;
			var v:Bytes = Bytes.alloc(2);
			v.setUInt16(0, plan.constStringValue[col]);
			out.writeBytes(v, 0, 2);
		}
		var flags:Bytes = Bytes.alloc(1);
		flags.set(0, plan.zeroable ? 1 : 0);
		out.writeBytes(flags, 0, 1);
	}

	static function readPlan(input:FileInput):NotePlan
	{
		var plan:NotePlan = new NotePlan();
		plan.constDoubleValue = [];
		for (col in 0...DOUBLE_COLUMNS) plan.constDoubleValue[col] = 0;
		plan.constStringValue = [];
		for (col in 0...STRING_COLUMNS) plan.constStringValue[col] = 0;

		var head:Bytes = Bytes.alloc(2);
		readFull(input, head, 0, 2);
		plan.constDoubles = head.getUInt16(0);
		for (col in 0...DOUBLE_COLUMNS)
		{
			if ((plan.constDoubles & (1 << col)) == 0) continue;
			var v:Bytes = Bytes.alloc(8);
			readFull(input, v, 0, 8);
			plan.constDoubleValue[col] = v.getDouble(0);
		}
		var sHead:Bytes = Bytes.alloc(1);
		readFull(input, sHead, 0, 1);
		plan.constStrings = sHead.get(0);
		for (col in 0...STRING_COLUMNS)
		{
			if ((plan.constStrings & (1 << col)) == 0) continue;
			var v:Bytes = Bytes.alloc(2);
			readFull(input, v, 0, 2);
			plan.constStringValue[col] = v.getUInt16(0);
		}
		var flags:Bytes = Bytes.alloc(1);
		readFull(input, flags, 0, 1);
		plan.zeroable = flags.get(0) != 0;
		buildPlan(plan);
		return plan;
	}

	// ── chart skeleton ──────────────────────────────────────────────────────

	/**
	 * Cached ChartStream scan of \`paths\` (skeleton + section ranges + note count), or null. The
	 * value is stored with haxe.Serializer, which keeps the Int/Float distinction the scan produced
	 * from the file bytes; the caller must treat a miss as "scan it again".
	 */
	public static function loadSkeleton(paths:Array<String>, config:String):Dynamic
	{
		#if sys
		if (paths == null || paths.length == 0 || config == null) return null;
		var path:String = fileFor(paths, SKELETON_EXT);
		var input:FileInput = null;
		try
		{
			if (!FileSystem.exists(path)) return null;
			var stat:sys.FileStat = FileSystem.stat(path);
			input = File.read(path, true);

			var prefix:Bytes = Bytes.alloc(PREFIX_BYTES);
			readFull(input, prefix, 0, PREFIX_BYTES);
			if (prefix.getInt32(0) != MAGIC || prefix.getInt32(4) != FORMAT || prefix.getInt32(8) != KIND_SKELETON)
			{
				input.close();
				deleteFile(path);
				return null;
			}

			var headerLen:Int = prefix.getInt32(12);
			// Same first slot as .notes' record count, holding the serialized payload length here.
			var count:Int = countToInt(prefix.getInt64(COUNT_OFFSET));
			var noteCount:Int64 = prefix.getInt64(SECOND_OFFSET);
			if (headerLen <= 0 || count < 0 || stat.size < PREFIX_BYTES + headerLen + count)
			{
				input.close();
				deleteFile(path);
				return null;
			}

			var headerBytes:Bytes = Bytes.alloc(headerLen);
			readFull(input, headerBytes, 0, headerLen);
			var header = parseHeader(headerBytes.getString(0, headerLen));
			if (header == null || header.src != sourceSignature(paths) || header.cfg != config)
			{
				input.close();
				return null;
			}

			var payload:Bytes = Bytes.alloc(count);
			readFull(input, payload, 0, count);
			input.close();
			var scan:Dynamic = haxe.Unserializer.run(payload.getString(0, count));
			// The payload's noteCount is the constant placeholder saveSkeleton() wrote; the real value
			// is the raw Int64 in the header. Restoring it as an Int64 keeps the field's declared type
			// true after a cache load, so a caller that converts it to Float (ChartStream.i64ToFloat)
			// reads the same type whether or not the cache was hit.
			if (scan != null) Reflect.setField(scan, 'noteCount', noteCount);
			reportCountPastLimit('cached chart scan note count', noteCount);
			return scan;
		}
		catch (e:Dynamic)
		{
			if (input != null) try input.close() catch (e2:Dynamic) {}
			deleteFile(path);
			return null;
		}
		#else
		return null;
		#end
	}

	/** Stores a ChartStream scan; see loadSkeleton(). */
	public static function saveSkeleton(paths:Array<String>, config:String, scan:Dynamic):Void
	{
		#if sys
		if (paths == null || paths.length == 0 || scan == null) return;
		var dest:String = fileFor(paths, SKELETON_EXT);
		var tmp:String = dest + '.tmp';
		var out:FileOutput = null;
		try
		{
			if (FileSystem.exists(tmp)) FileSystem.deleteFile(tmp);
			var noteCount:Int64 = 0;
			if (Reflect.hasField(scan, 'noteCount')) noteCount = (cast scan : ChartStream.ChartScanResult).noteCount;
			// An Int64 must not be handed to haxe.Serializer: on cpp it comes back as a plain Int when
			// the value fits 32 bits and as a cpp::Int64 object otherwise, and its Float path only
			// survives 15 significant digits. The count therefore goes into the header as raw bytes,
			// and the payload carries a constant placeholder that loadSkeleton() overwrites. The
			// Reflect.copy below keeps the caller's scan object untouched.
			var cached:Dynamic = Reflect.copy(scan);
			Reflect.setField(cached, 'noteCount', 0.0);
			var payload:Bytes = Bytes.ofString(haxe.Serializer.run(cached));

			out = File.write(tmp, true);
			var prefix:Bytes = Bytes.alloc(PREFIX_BYTES);
			prefix.setInt32(0, MAGIC);
			prefix.setInt32(4, FORMAT);
			prefix.setInt32(8, KIND_SKELETON);
			var headerBytes:Bytes = Bytes.ofString(buildHeader(sourceSignature(paths), config, false, false, null));
			prefix.setInt32(12, headerBytes.length);
			prefix.setInt64(COUNT_OFFSET, Int64.ofInt(payload.length));
			prefix.setInt64(SECOND_OFFSET, noteCount);
			reportCountPastLimit('chart cache scan note count', noteCount);
			out.writeBytes(prefix, 0, PREFIX_BYTES);
			out.writeBytes(headerBytes, 0, headerBytes.length);
			out.writeBytes(payload, 0, payload.length);
			out.close();
			out = null;

			if (FileSystem.exists(dest)) FileSystem.deleteFile(dest);
			FileSystem.rename(tmp, dest);
			prune();
		}
		catch (e:Dynamic)
		{
			if (out != null) try out.close() catch (e2:Dynamic) {}
			deleteFile(tmp);
		}
		#end
	}

	// ── helpers ─────────────────────────────────────────────────────────────

	/**
	 * Names in the cache directory, never null. hxcpp's FileSystem.readDirectory answers a missing
	 * directory with null instead of throwing, and iterating that null faults natively, so the
	 * directory is created first and a null answer is turned into an empty list.
	 */
	static function listFiles():Array<String>
	{
		cacheDir();
		var names:Array<String> = null;
		try names = FileSystem.readDirectory(CACHE_DIR) catch (e:Dynamic) {}
		return (names == null) ? [] : names;
	}

	static function normalizePath(path:String):String
	{
		if (path == null) return '';
		return path.split('\\').join('/').toLowerCase();
	}

	/** One file per chart path list; the chart's identity is inside the header, not the name. */
	static function fileFor(paths:Array<String>, ext:String):String
	{
		var key:StringBuf = new StringBuf();
		key.add(FORMAT);
		for (path in paths)
		{
			key.add('|');
			key.add(normalizePath(path));
		}
		return cacheDir() + Md5.encode(key.toString()) + ext;
	}

	static function buildHeader(src:String, config:String, folded:Bool, compressed:Bool, noteTypes:Array<String>):String
	{
		var types:Array<String> = (noteTypes == null) ? [] : noteTypes;
		var b:StringBuf = new StringBuf();
		b.add('src=');
		b.add(src);
		b.add('\ncfg=');
		b.add(config);
		b.add('\nfolded=');
		b.add(folded ? '1' : '0');
		b.add('\ncompressed=');
		b.add(compressed ? '1' : '0');
		b.add('\ntypes=');
		b.add(types.length);
		for (t in types)
		{
			b.add('\n');
			b.add(t == null ? '' : t);
		}
		return b.toString();
	}

	static function parseHeader(text:String):{src:String, cfg:String, folded:Bool, compressed:Bool, types:Array<String>}
	{
		var lines:Array<String> = text.split('\n');
		if (lines.length < 5) return null;
		if (!lines[0].startsWith('src=') || !lines[1].startsWith('cfg=') || !lines[2].startsWith('folded=')
			|| !lines[3].startsWith('compressed=') || !lines[4].startsWith('types=')) return null;
		var count:Null<Int> = Std.parseInt(lines[4].substr(6));
		if (count == null || count < 0 || lines.length < 5 + count) return null;
		var types:Array<String> = [];
		for (i in 0...count) types.push(lines[5 + i]);
		return {
			src: lines[0].substr(4),
			cfg: lines[1].substr(4),
			folded: lines[2].substr(7) == '1',
			compressed: lines[3].substr(11) == '1',
			types: types
		};
	}

	/** Adds \`value\` to the intern table when it is new and returns its index. */
	static function addString(table:Array<String>, index:Map<String, Int>, value:String):Int
	{
		if (value == null) return NO_STRING_INDEX;
		var found:Null<Int> = index.get(value);
		if (found != null) return found;
		index.set(value, table.length);
		table.push(value);
		return table.length - 1;
	}

	static function stringIndex(index:Map<String, Int>, value:String):Int
	{
		if (value == null) return NO_STRING_INDEX;
		var i:Null<Int> = index.get(value);
		return (i == null) ? 0 : i;
	}

	/** Table entry 0 is the empty string, so an unknown index degrades to "" instead of null. */
	static function stringAt(table:Array<String>, index:Int):String
	{
		if (index == NO_STRING_INDEX) return null;
		if (index < 0 || index >= table.length) return '';
		return table[index];
	}

	static function writeStringTable(out:FileOutput, table:Array<String>):Void
	{
		var head:Bytes = Bytes.alloc(4);
		head.setInt32(0, table.length);
		out.writeBytes(head, 0, 4);
		for (entry in table)
		{
			var bytes:Bytes = Bytes.ofString(entry);
			var len:Bytes = Bytes.alloc(2);
			len.setUInt16(0, bytes.length);
			out.writeBytes(len, 0, 2);
			out.writeBytes(bytes, 0, bytes.length);
		}
	}

	static function readStringTable(input:FileInput):Array<String>
	{
		var head:Bytes = Bytes.alloc(4);
		readFull(input, head, 0, 4);
		var count:Int = head.getInt32(0);
		if (count <= 0 || count > 0x10000) throw new haxe.Exception('ChartCache: string table of ' + count + ' entries');
		var table:Array<String> = [];
		var lenBytes:Bytes = Bytes.alloc(2);
		for (i in 0...count)
		{
			readFull(input, lenBytes, 0, 2);
			var len:Int = lenBytes.getUInt16(0);
			var bytes:Bytes = Bytes.alloc(len);
			readFull(input, bytes, 0, len);
			table.push(bytes.getString(0, len));
		}
		return table;
	}

	static function readFull(input:FileInput, b:Bytes, pos:Int, len:Int):Void
	{
		var done:Int = 0;
		while (done < len)
		{
			var got:Int = input.readBytes(b, pos + done, len - done);
			if (got <= 0) throw new haxe.Exception('ChartCache: unexpected end of file');
			done += got;
		}
	}

	/**
	 * Narrows a counter read from a file to an Int, or -1 when it cannot be one.
	 *
	 * Only this class writes these files, so a negative count or one past 2^31-1 is damage, not a
	 * chart with billions of records: a record loop bound and a Bytes length are Int by
	 * construction. Returning a sentinel feeds the existing "count < 0 -> delete the file" check
	 * instead of truncating the value and handing a bogus length to Bytes.alloc.
	 */
	static inline function countToInt(v:Int64):Int
	{
		if (v < 0 || v > INT32_LIMIT) return -1;
		return v.low;
	}

	/**
	 * Overflow guard for the counters: traces when a cumulative note count is past 2^31-1, the largest
	 * value an Int can hold, so the trace shows a counter carrying a value an Int32 could not. Changes
	 * no behaviour.
	 */
	static function reportCountPastLimit(label:String, value:Int64):Void
	{
		if (value <= INT32_LIMIT) return;
		TraceManager.debug('trace.chart.countOverflow', '{} is past the 32-bit counter limit ({})',
			[label, Int64.toStr(value)]);
	}

	static function deleteFile(path:String):Void
	{
		try
		{
			if (FileSystem.exists(path)) FileSystem.deleteFile(path);
		}
		catch (e:Dynamic) {}
	}

	/** Keeps the cache directory under MAX_TOTAL_BYTES by dropping the least recently used files. */
	static function prune():Void
	{
		try
		{
			var entries:Array<{path:String, size:Float, time:Float}> = [];
			var total:Float = 0;
			for (name in listFiles())
			{
				var path:String = CACHE_DIR + name;
				try
				{
					if (FileSystem.isDirectory(path)) continue;
					var st:sys.FileStat = FileSystem.stat(path);
					if (st == null) continue;
					entries.push({ path: path, size: st.size, time: st.mtime.getTime() });
					total += st.size;
				}
				catch (e:Dynamic) {}
			}
			if (total <= MAX_TOTAL_BYTES) return;
			entries.sort(function(a, b) return a.time < b.time ? -1 : (a.time > b.time ? 1 : 0));
			for (entry in entries)
			{
				if (total <= MAX_TOTAL_BYTES) break;
				deleteFile(entry.path);
				total -= entry.size;
			}
		}
		catch (e:Dynamic) {}
	}
}
