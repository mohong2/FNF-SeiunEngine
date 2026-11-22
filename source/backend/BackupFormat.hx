package backend;

import haxe.io.Bytes;
import haxe.io.Eof;
import haxe.io.Input;

/**
 * A problem with a backup file that the player can act on.
 *
 * Deliberately not a haxe.Exception: hxcpp prints the stack for real exceptions when the
 * message is rendered, and this message ends up in a FlxText or a native dialog. A plain
 * class keeps toString() to exactly the sentence that should be shown.
 */
class BackupError
{
	public var message:String;

	public function new(message:String)
	{
		this.message = message;
	}

	public function toString():String
	{
		return message;
	}
}

/** One unpacked container: version from the header plus the plain-text JSON payload. */
typedef BackupContainer =
{
	var version:Int;
	var json:String;
	var legacy:Bool;
}

// ---------------------------------------------------------------------- text sinks

/** Where the text body of a .SEB file goes while it is being produced. */
interface TextSink
{
	public function write(text:String):Void;
}

/**
 * A text sink that can reserve the header text up front and fill it in at the end.
 *
 * The v2 header holds the payload length and the payload checksum, but the header is the
 * first text in the file: while the payload is being produced those two values are not
 * known yet. The encoder therefore reserves HEADER_CHARS characters at the current
 * position (beginHeader), streams the payload after them, and finally overwrites the
 * reserved characters with the real header (patchHeader). A file sink seeks back to the
 * start; a string sink keeps the header as a separate prefix.
 */
interface HeaderSink extends TextSink
{
	public function beginHeader(length:Int):Void;
	public function patchHeader(text:String):Void;
}

/** In-memory text sink, used by the fallback (whole-text) path and by the tests. */
class StringSink implements TextSink
{
	var buf:StringBuf = new StringBuf();

	public function new() {}

	public function write(text:String):Void
	{
		buf.add(text);
	}

	public function toString():String
	{
		return buf.toString();
	}
}

/** Text sink that forwards to a function, for callers that just want the pieces. */
class FunctionSink implements TextSink
{
	var fn:String->Void;

	public function new(fn:String->Void)
	{
		this.fn = fn;
	}

	public function write(text:String):Void
	{
		fn(text);
	}
}

/** In-memory container sink: the header lives in `head`, the payload text in `body`. */
class StringHeaderSink implements HeaderSink
{
	var head:String = '';
	var body:StringBuf = new StringBuf();

	public function new() {}

	public function beginHeader(length:Int):Void
	{
		head = '';
	}

	public function write(text:String):Void
	{
		body.add(text);
	}

	public function patchHeader(text:String):Void
	{
		head = text;
	}

	public function toString():String
	{
		return head + body.toString();
	}
}

// ---------------------------------------------------------------------- base64 out

/**
 * Wrapped base64 encoder: bytes in, text out.
 *
 * Used for three different texts: a whole container (starting at column 20, where the
 * header placeholder sits), a score blob inside the JSON payload (unwrapped) and the
 * legacy score encoding. The line break is emitted lazily in front of the next character,
 * so a text that ends exactly on a line boundary does not get a trailing newline.
 */
class Base64Writer
{
	inline static var FLUSH_AT:Int = 8192;

	var sink:TextSink;
	var buf:StringBuf = new StringBuf();
	var width:Int;
	var column:Int;
	var pending:Int = 0;
	var first:Int = 0;
	var second:Int = 0;

	public function new(sink:TextSink, startColumn:Int = 0, lineWidth:Int = -1)
	{
		this.sink = sink;
		this.column = startColumn;
		this.width = (lineWidth < 0) ? BackupFormat.LINE_WIDTH : lineWidth;
	}

	public function write(bytes:Bytes, offset:Int, length:Int):Void
	{
		var i:Int = offset;
		var end:Int = offset + length;
		while (i < end)
		{
			var value:Int = bytes.get(i++);
			if (pending == 0)
			{
				first = value;
				pending = 1;
			}
			else if (pending == 1)
			{
				second = value;
				pending = 2;
			}
			else
			{
				emit(first, second, value);
				pending = 0;
			}
		}
	}

	/** Writes the final (padded) group and hands everything left to the sink. */
	public function finish():Void
	{
		if (pending == 1)
		{
			put(table((first >> 2) & 0x3F));
			put(table((first << 4) & 0x3F));
			put(0x3D);
			put(0x3D);
		}
		else if (pending == 2)
		{
			put(table((first >> 2) & 0x3F));
			put(table(((first << 4) & 0x30) | ((second >> 4) & 0x0F)));
			put(table((second << 2) & 0x3C));
			put(0x3D);
		}
		pending = 0;
		flush();
	}

	inline function table(index:Int):Int
	{
		return BackupFormat.BASE64.charCodeAt(index);
	}

	function emit(a:Int, b:Int, c:Int):Void
	{
		put(table((a >> 2) & 0x3F));
		put(table(((a << 4) & 0x30) | ((b >> 4) & 0x0F)));
		put(table(((b << 2) & 0x3C) | ((c >> 6) & 0x03)));
		put(table(c & 0x3F));
	}

	inline function put(code:Int):Void
	{
		if (width > 0 && column >= width)
		{
			buf.addChar(0x0A);
			column = 0;
		}
		buf.addChar(code);
		column++;
		if (buf.length >= FLUSH_AT) flush();
	}

	function flush():Void
	{
		if (buf.length == 0) return;
		sink.write(buf.toString());
		buf = new StringBuf();
	}
}

// ---------------------------------------------------------------------- byte sources

/**
 * Where the text bytes of a .SEB file come from while it is being read.
 *
 * Implementations exist for a file (streams, so a 40 MB backup never becomes a 40 MB
 * string), a string (Android SAF already hands the game a string) and an in-memory
 * buffer (tests).
 */
interface ByteSource
{
	/** Reads up to `len` bytes into `buf` at `pos`; returns how many, 0 at the end. */
	public function read(buf:Bytes, pos:Int, len:Int):Int;

	/**
	 * How many bytes are still available, or -1 when that is not known up front.
	 * Used to reject a header that claims more data than the file can possibly hold
	 * before anything is allocated for it.
	 */
	public function size():Int;
}

class BytesSource implements ByteSource
{
	var bytes:Bytes;
	var pos:Int;
	var end:Int;

	public function new(bytes:Bytes, ?offset:Int = 0, ?length:Int = -1)
	{
		this.bytes = bytes;
		this.pos = offset;
		this.end = (length < 0) ? bytes.length : offset + length;
	}

	public function read(buf:Bytes, pos:Int, len:Int):Int
	{
		var available:Int = end - this.pos;
		if (available <= 0) return 0;
		var count:Int = (len < available) ? len : available;
		buf.blit(pos, bytes, this.pos, count);
		this.pos += count;
		return count;
	}

	public function size():Int
	{
		return end - pos;
	}
}

class InputSource implements ByteSource
{
	var input:Input;
	var length:Int;

	public function new(input:Input, ?length:Int = -1)
	{
		this.input = input;
		this.length = length;
	}

	public function size():Int
	{
		return length;
	}

	public function read(buf:Bytes, pos:Int, len:Int):Int
	{
		var total:Int = 0;
		while (total < len)
		{
			var got:Int = 0;
			try
			{
				got = input.readBytes(buf, pos + total, len - total);
			}
			catch (e:Eof)
			{
				got = 0;
			}
			if (got <= 0) break;
			total += got;
		}
		return total;
	}
}

class StringSource implements ByteSource
{
	var text:String;
	var pos:Int;

	public function new(text:String)
	{
		this.text = text;
		// a UTF-16 BOM in front of a text file is transport noise, not data
		this.pos = (text.length > 0 && text.charCodeAt(0) == 0xFEFF) ? 1 : 0;
	}

	public function read(buf:Bytes, pos:Int, len:Int):Int
	{
		var count:Int = 0;
		while (count < len && this.pos < text.length)
		{
			var code:Int = text.charCodeAt(this.pos++);
			// base64 text is ASCII; anything wider is kept as an invalid byte so the
			// reader reports it instead of silently truncating it into a valid char
			buf.set(pos + count, (code > 0xFF) ? 0xFF : code);
			count++;
		}
		return count;
	}

	public function size():Int
	{
		return text.length - pos;
	}
}

// ---------------------------------------------------------------------- base64 in

/**
 * Streaming base64 text reader: text bytes in, decoded bytes out, one at a time.
 *
 * Whitespace is ignored, a leading UTF-8 BOM is skipped, and anything outside the base64
 * alphabet is reported as damage instead of being skipped, because a silently shifted
 * byte would ruin the restored save.
 */
class TextByteReader
{
	inline static var CHUNK:Int = 16384;

	var source:ByteSource;
	var chunk:Bytes = Bytes.alloc(CHUNK);
	var chunkLength:Int = 0;
	var chunkPos:Int = 0;
	var buffer:Int = 0;
	var bits:Int = 0;
	var padding:Int = 0;
	var offset:Int = 0;
	var raw:Bool;

	public function new(source:ByteSource, ?raw:Bool = false)
	{
		this.source = source;
		this.raw = raw;

		// raw mode reads container bytes, which are not base64 and have no BOM
		if (raw) return;

		chunkLength = source.read(chunk, 0, 3);
		chunkPos = (chunkLength >= 3 && chunk.get(0) == 0xEF && chunk.get(1) == 0xBB && chunk.get(2) == 0xBF) ? 3 : 0;
	}

	/** Number of decoded bytes handed out so far. */
	public var decoded:Int = 0;

	/** Next byte, or -1 once the source ended. */
	public function next():Int
	{
		if (raw)
		{
			if (chunkPos >= chunkLength)
			{
				chunkLength = source.read(chunk, 0, CHUNK);
				chunkPos = 0;
				if (chunkLength <= 0) return -1;
			}
			decoded++;
			return chunk.get(chunkPos++);
		}

		while (true)
		{
			if (chunkPos >= chunkLength)
			{
				chunkLength = source.read(chunk, 0, CHUNK);
				chunkPos = 0;
				if (chunkLength <= 0) return -1;
			}

			var code:Int = chunk.get(chunkPos++);
			offset++;

			// space, tab, CR, LF, VT, FF
			if (code == 0x20 || code == 0x09 || code == 0x0A || code == 0x0D || code == 0x0B || code == 0x0C) continue;

			if (code == 0x3D) // '='
			{
				padding++;
				if (padding > 2) throw new BackupError('the backup file has invalid base64 padding');
				continue;
			}

			if (padding > 0)
				throw new BackupError('the backup file contains an invalid character after the padding (position ' + offset + ')');

			if (code >= 128 || BackupFormat.BASE64_LOOKUP[code] < 0)
				throw new BackupError('the backup file contains an invalid character at position ' + offset);

			buffer = ((buffer << 6) | BackupFormat.BASE64_LOOKUP[code]) & 0xFFFFFF;
			bits += 6;
			if (bits >= 8)
			{
				bits -= 8;
				decoded++;
				return (buffer >> bits) & 0xFF;
			}
		}
		return -1;
	}
}

// ---------------------------------------------------------------------- container out

/** Result of writing a payload: its length and checksum, i.e. what the header says. */
typedef BackupStreamResult =
{
	var length:Int;
	var hash:Int;
}

/**
 * Streams the plain payload of a container into a sink as wrapped base64 text.
 *
 * Every chunk is hashed (FNV-1a, the container checksum) and XOR-obfuscated before it is
 * base64-encoded, so the whole payload never has to exist in memory: only the chunk being
 * written does. finish() patches the header that was reserved at the start.
 */
class BackupStream
{
	var sink:HeaderSink;
	var writer:Base64Writer;
	var keyIndex:Int;
	var keyStart:Int;
	var checksum:Int = 0x811C9DC5;
	var length:Int = 0;
	var finished:Bool = false;

	/** Reused XOR buffer: one allocation for the whole stream instead of one per chunk. */
	var scratch:Bytes = Bytes.alloc(0);

	public function new(sink:HeaderSink, keyIndex:Int = 0)
	{
		this.sink = sink;
		this.keyIndex = keyIndex & 0xFF;
		this.keyStart = this.keyIndex % BackupFormat.XOR_KEY.length;
		sink.beginHeader(BackupFormat.HEADER_CHARS);
		writer = new Base64Writer(sink, BackupFormat.HEADER_CHARS);
	}

	/** Appends a chunk of plain payload text (the JSON payload). */
	public function write(text:String):Void
	{
		if (text == null || text.length == 0) return;
		if (finished) throw new BackupError('the backup stream is already closed');

		var plain:Bytes = Bytes.ofString(text, UTF8);
		var count:Int = plain.length;
		if (count == 0) return;

		var key:Array<Int> = BackupFormat.XOR_KEY;
		var keyLength:Int = key.length;
		var base:Int = length + keyStart;
		var hash:Int = checksum;

		if (scratch.length < count) scratch = Bytes.alloc(count);

		for (i in 0...count)
		{
			var value:Int = plain.get(i);
			hash = (hash ^ value) * 16777619;
			scratch.set(i, value ^ key[(base + i) % keyLength]);
		}

		checksum = hash;
		length += count;
		writer.write(scratch, 0, count);
	}

	/** Flushes the last group, writes the real header over the reserved one. */
	public function finish():BackupStreamResult
	{
		if (finished) throw new BackupError('the backup stream is already closed');
		finished = true;

		writer.finish();
		var header:Bytes = BackupFormat.headerV2(keyIndex, length, checksum);
		sink.patchHeader(BackupFormat.headerText(header));
		return {length: length, hash: checksum};
	}
}

// ---------------------------------------------------------------------- container

/**
 * The .SEB container: header, integrity check and obfuscation for a JSON payload.
 *
 * This class has no engine dependencies at all. Everything a backup does to its bytes
 * lives here so it can be tested with plain `haxe --interp` (see tools/backup_tests).
 *
 * ## v2 layout (the only format this build writes)
 *
 * ```
 * offset  size  content
 * 0       4     magic "SEB2"
 * 4       1     format version (2)
 * 5       1     XOR key index (key rotation slot)
 * 6       1     flags (reserved, must be 0)
 * 7       4     plain-text length, big endian
 * 11      4     FNV-1a checksum of the plain text, big endian
 * 15      n     payload, XOR-obfuscated
 * ```
 *
 * The file the player actually gets is that byte stream base64-encoded as text. That is
 * not an aesthetic choice: OpenFL's FileReference.save() writes text reliably on every
 * target this engine ships (desktop writes UTF-8, Android writes through SAF's text API,
 * iOS writes a text file), and the read side goes through the same text-only path.
 * Base64 costs 33% size and keeps one code path.
 *
 * The XOR is obfuscation, not encryption: it stops a casual editor from changing scores
 * and it is trivially reversible by anyone who looks. What actually protects the player
 * is the checksum plus the length field, which turn a truncated or edited file into a
 * clean "this backup is damaged" message instead of a half-applied restore.
 *
 * ## Streaming
 *
 * A score history can be tens of megabytes, and the old code built it in memory several
 * times over (base64 per file, one JSON string, a packed copy, an encoded copy). The
 * writer and reader here move one chunk at a time, so peak memory is a couple of chunks
 * instead of a multiple of the backup size. pack()/unpack()/encodeText()/decodeText()
 * are the same format in one-shot form, kept for tests and for the in-memory fallback.
 *
 * ## v1 / legacy
 *
 * Older builds wrote "SEB1" + version 1 + key byte + length + XORed JSON with no checksum.
 * Those files are still readable (BackupData.upgradeLegacy converts their payload), so a
 * backup made before this rewrite can still be restored.
 */
class BackupFormat
{
	public static inline var MAGIC_V1 = 'SEB1';
	public static inline var MAGIC_V2 = 'SEB2';
	public static inline var VERSION_V2 = 2;

	public static inline var HEADER_V2 = 4 + 1 + 1 + 1 + 4 + 4;
	public static inline var HEADER_V1 = 4 + 1 + 1 + 4;

	/** Characters the base64 header of a v2 file occupies (15 bytes, no padding). */
	public static inline var HEADER_CHARS = 20;

	/** Refuse absurd files before allocating anything for them (1 GiB of JSON is not a save). */
	public static inline var MAX_PAYLOAD = 1024 * 1024 * 1024;

	/** Exported text is wrapped so the file stays readable; the decoder ignores all whitespace. */
	public static inline var LINE_WIDTH = 76;

	/**
	 * XOR key. `keyIndex` in the header selects a rotation offset so the key can be
	 * changed for files written in the future without breaking files already on disk.
	 */
	public static var XOR_KEY:Array<Int> = [
		0x9A, 0x3C, 0xF7, 0x2B, 0x6D, 0xE4, 0x15, 0x88,
		0x4E, 0x71, 0xB2, 0x0F, 0xC9, 0x56, 0xAD, 0x38,
		0x6F, 0xD2, 0x1B, 0xE7, 0x84, 0x39, 0xCA, 0x5F,
		0x20, 0x94, 0x6B, 0xD7, 0x41, 0xFE, 0x03, 0xBC
	];

	public static var BASE64:String = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

	/** char code -> 6-bit value, -1 for "not a base64 character". Built once. */
	public static var BASE64_LOOKUP:Array<Int> = buildLookup();

	static function buildLookup():Array<Int>
	{
		var lookup:Array<Int> = [];
		for (i in 0...128) lookup.push(-1);
		for (i in 0...BASE64.length) lookup[BASE64.charCodeAt(i)] = i;
		return lookup;
	}

	// ------------------------------------------------------------------ container

	/** Builds the 15 byte v2 header. */
	public static function headerV2(keyIndex:Int, plainLength:Int, checksum:Int):Bytes
	{
		var out:Bytes = Bytes.alloc(HEADER_V2);
		for (i in 0...4) out.set(i, MAGIC_V2.charCodeAt(i));
		out.set(4, VERSION_V2);
		out.set(5, keyIndex & 0xFF);
		out.set(6, 0); // flags, reserved
		out.set(7, (plainLength >>> 24) & 0xFF);
		out.set(8, (plainLength >>> 16) & 0xFF);
		out.set(9, (plainLength >>> 8) & 0xFF);
		out.set(10, plainLength & 0xFF);
		out.set(11, (checksum >>> 24) & 0xFF);
		out.set(12, (checksum >>> 16) & 0xFF);
		out.set(13, (checksum >>> 8) & 0xFF);
		out.set(14, checksum & 0xFF);
		return out;
	}

	/** Base64 text of a container header (exactly HEADER_CHARS characters, no wrapping). */
	public static function headerText(header:Bytes):String
	{
		var sink = new StringSink();
		var writer = new Base64Writer(sink, 0, 0);
		writer.write(header, 0, header.length);
		writer.finish();
		return sink.toString();
	}

	/** Packs a JSON string into the binary v2 container (one-shot form). */
	public static function pack(json:String, keyIndex:Int = 0):Bytes
	{
		if (json == null) throw new BackupError('the backup payload is empty');

		var plain:Bytes = Bytes.ofString(json, UTF8);
		if (plain.length > MAX_PAYLOAD) throw new BackupError('the backup is too large (' + plain.length + ' bytes)');

		var header:Bytes = headerV2(keyIndex, plain.length, hash(plain));
		var out:Bytes = Bytes.alloc(HEADER_V2 + plain.length);
		out.blit(0, header, 0, HEADER_V2);
		xorInto(plain, 0, plain.length, keyIndex, out, HEADER_V2);
		return out;
	}

	/** Reads a container from base64 text; the payload is decoded while it is read. */
	public static function readContainer(source:ByteSource):BackupContainer
	{
		return parse(new TextByteReader(source), false, source.size());
	}

	/** Shared parser for both entry points: `raw` means "already container bytes". */
	static function parse(reader:TextByteReader, raw:Bool, available:Int):BackupContainer
	{
		var head:Bytes = Bytes.alloc(HEADER_V2);
		var got:Int = 0;
		while (got < 4)
		{
			var value:Int = reader.next();
			if (value < 0) throw new BackupError('the backup file is truncated (no header)');
			head.set(got++, value);
		}

		var legacy:Bool;
		var headerSize:Int;
		var magic:String = head.getString(0, 4);
		if (magic == MAGIC_V2)
		{
			legacy = false;
			headerSize = HEADER_V2;
		}
		else if (magic == MAGIC_V1)
		{
			legacy = true;
			headerSize = HEADER_V1;
		}
		else
		{
			throw new BackupError('this is not a SeiunEngine backup file');
		}

		while (got < headerSize)
		{
			var value:Int = reader.next();
			if (value < 0) throw new BackupError('the backup file is truncated (no header)');
			head.set(got++, value);
		}

		var version:Int = head.get(4);
		if (legacy)
		{
			if (version != 1) throw new BackupError('unsupported legacy backup version ' + version);
		}
		else if (version != VERSION_V2)
		{
			throw new BackupError('unsupported backup format version ' + version + ' (this build reads version ' + VERSION_V2 + ')');
		}

		var keyIndex:Int = head.get(5);
		var flags:Int = legacy ? 0 : head.get(6);
		var checksum:Int = legacy ? 0 : int32At(head, 11);
		var payloadLength:Int = int32At(head, legacy ? 6 : 7);

		if (payloadLength < 0 || payloadLength > MAX_PAYLOAD)
			throw new BackupError((legacy ? 'the legacy backup header' : 'the backup header') + ' is damaged (bad length)');

		// Four text characters carry at most three bytes, so a file whose text cannot
		// possibly hold the claimed payload is rejected before anything is allocated for
		// it. Without this a 20 byte file with a damaged length field could ask for a
		// gigabyte of memory. Container bytes are one to one, so the check is exact there.
		if (available >= 0)
		{
			var possible:Int = (raw ? available : Std.int(available / 4) * 3 + 3) - headerSize;
			if (payloadLength > possible)
				throw new BackupError('the backup file is truncated: it cannot hold the ' + payloadLength + ' bytes of data it announces');
		}

		var total:Int = headerSize + payloadLength;
		var data:Bytes = Bytes.alloc(total);
		data.blit(0, head, 0, headerSize);

		var pos:Int = headerSize;
		while (pos < total)
		{
			var value:Int = reader.next();
			if (value < 0)
				throw new BackupError('the backup file is truncated (' + (pos - headerSize) + ' of ' + payloadLength + ' bytes)');
			data.set(pos++, value);
		}

		if (reader.next() >= 0)
			throw new BackupError('the backup file has extra data after the end of the payload');

		// the payload is stored obfuscated, so undo that before checking it
		xorInto(data, headerSize, payloadLength, keyIndex, data, headerSize);

		if (!legacy)
		{
			if (hash(data, headerSize, payloadLength) != checksum)
				throw new BackupError('the backup checksum does not match: the file was modified or damaged');

			// Flags are reserved. A file that uses one was written by a newer build whose
			// payload this build cannot interpret; saying so beats restoring half of it.
			if (flags != 0)
				throw new BackupError('this backup uses a newer container feature this build does not understand');
		}

		return {
			version: version,
			json: (payloadLength == 0) ? '' : data.getString(headerSize, payloadLength, UTF8),
			legacy: legacy
		};
	}

	/** Reads a container from already-decoded container bytes. */
	public static function unpack(bytes:Bytes):BackupContainer
	{
		if (bytes == null) throw new BackupError('the backup file is empty');
		if (bytes.length < HEADER_V1) throw new BackupError('the backup file is truncated (no header)');
		return parse(new TextByteReader(new BytesSource(bytes), true), true, bytes.length);
	}

	// ------------------------------------------------------------------ text form

	/** Base64-encodes bytes into the text body of a .SEB file (wrapped at LINE_WIDTH). */
	public static function encodeText(bytes:Bytes):String
	{
		if (bytes == null || bytes.length == 0) return '';
		var sink = new StringSink();
		var writer = new Base64Writer(sink);
		writer.write(bytes, 0, bytes.length);
		writer.finish();
		return sink.toString();
	}

	/** Base64 of a byte range without any line wrapping (a blob inside the JSON payload). */
	public static function encodeRaw(bytes:Bytes):String
	{
		if (bytes == null || bytes.length == 0) return '';
		var sink = new StringSink();
		var writer = new Base64Writer(sink, 0, 0);
		writer.write(bytes, 0, bytes.length);
		writer.finish();
		return sink.toString();
	}

	/**
	 * Streams the base64 of a byte range into `sink` in pieces (no line wrapping).
	 * The writer hands over a piece every few kilobytes, so the encoded text never
	 * exists as one string; the pieces can simply be concatenated.
	 */
	public static function streamBase64(bytes:Bytes, offset:Int, length:Int, sink:String->Void):Void
	{
		if (bytes == null || length <= 0) return;
		var writer = new Base64Writer(new FunctionSink(sink), 0, 0);
		writer.write(bytes, offset, length);
		writer.finish();
	}

	/**
	 * Decodes the text body of a .SEB file (one-shot form).
	 * Whitespace, a BOM and any line wrapping are ignored.
	 */
	public static function decodeText(text:String):Bytes
	{
		if (text == null) throw new BackupError('the backup file is empty');

		var length:Int = text.length;
		var chars:Int = 0;
		var pad:Int = 0;

		for (i in 0...length)
		{
			var code:Int = text.charCodeAt(i);
			if (code == 0x20 || code == 0x09 || code == 0x0D || code == 0x0A || code == 0x0B || code == 0x0C || code == 0xFEFF) continue;

			if (code == 0x3D)
			{
				pad++;
				if (pad > 2) throw new BackupError('the backup file has invalid base64 padding');
				continue;
			}

			if (pad > 0) throw new BackupError('the backup file contains an invalid character at position ' + (i + 1));
			if (code >= 128 || BASE64_LOOKUP[code] < 0)
				throw new BackupError('the backup file contains an invalid character at position ' + (i + 1));
			chars++;
		}

		if (chars == 0) throw new BackupError('the backup file contains no data');
		if (chars % 4 == 1) throw new BackupError('the backup file has an invalid base64 length');

		var outLength:Int = Std.int(chars * 6 / 8);
		var out:Bytes = Bytes.alloc(outLength);

		var buffer:Int = 0;
		var bits:Int = 0;
		var written:Int = 0;

		for (i in 0...length)
		{
			var code:Int = text.charCodeAt(i);
			if (code == 0x20 || code == 0x09 || code == 0x0D || code == 0x0A || code == 0x0B || code == 0x0C || code == 0xFEFF) continue;
			if (code == 0x3D) continue;

			buffer = ((buffer << 6) | BASE64_LOOKUP[code]) & 0xFFFFFF;
			bits += 6;
			if (bits >= 8)
			{
				bits -= 8;
				if (written < outLength) out.set(written++, (buffer >> bits) & 0xFF);
			}
		}

		if (written == outLength) return out;
		if (written == 0) throw new BackupError('the backup file contains no usable data');
		return out.sub(0, written);
	}

	// ------------------------------------------------------------------ helpers

	/** FNV-1a (32 bit) over the whole buffer; used for the payload and for score blobs. */
	public static function hash(bytes:Bytes, offset:Int = 0, length:Int = -1):Int
	{
		if (bytes == null) return 0;
		if (length < 0) length = bytes.length - offset;

		var h:Int = 0x811C9DC5;
		var end:Int = offset + length;
		var i:Int = offset;
		while (i < end)
		{
			h = (h ^ bytes.get(i)) * 16777619;
			i++;
		}
		return h;
	}

	/** Big-endian int32 at `offset`. */
	public static function int32At(bytes:Bytes, offset:Int):Int
	{
		return (bytes.get(offset) << 24) | (bytes.get(offset + 1) << 16) | (bytes.get(offset + 2) << 8) | bytes.get(offset + 3);
	}

	/**
	 * XORs `length` bytes of `src` into `dest`. Both may be the same buffer and the
	 * same offset, which is how the reader decodes in place without a second copy.
	 */
	public static function xorInto(src:Bytes, srcOffset:Int, length:Int, keyIndex:Int, dest:Bytes, destOffset:Int):Void
	{
		var key:Array<Int> = XOR_KEY;
		var keyLength:Int = key.length;
		var start:Int = keyIndex % keyLength;
		if (start < 0) start += keyLength;

		for (i in 0...length)
			dest.set(destOffset + i, src.get(srcOffset + i) ^ key[(i + start) % keyLength]);
	}
}
