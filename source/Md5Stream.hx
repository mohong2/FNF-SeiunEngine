package;

import haxe.io.Bytes;
import sys.io.File;
import sys.io.FileInput;
import sys.io.FileSeek;

/**
 * Streaming MD5 (RFC 1321).
 *
 * haxe.crypto.Md5 only offers one-shot encode/make, which has to hold the whole input in
 * memory. This is the incremental version of the same algorithm: chunked update, producing
 * exactly the same digest as Md5.encode() over the same bytes.
 *
 * hashChartFile() reproduces Song.loadRawSong()'s byte handling: trim both ends (same
 * whitespace test as StringTools.trim), then cut everything after the last '}'.
 */
class Md5Stream
{
	static inline final BLOCK_BYTES:Int = 64;
	static inline final CHUNK:Int = 1 << 20;

	static var POW256:Array<Float> = [1.0, 256.0, 65536.0, 16777216.0];

	// 64 constants from RFC 1321
	static var K:Array<Int> = [
		0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
		0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
		0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
		0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
		0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
		0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
		0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
		0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
		0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
		0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
		0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
		0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
		0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
		0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
		0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
		0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391
	];

	// Per-round left shift amounts
	static var S:Array<Int> = [
		7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
		5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
		4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
		6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21
	];

	var a:Int = 0x67452301;
	var b:Int = 0xefcdab89;
	var c:Int = 0x98badcfe;
	var d:Int = 0x10325476;

	var block:Bytes;
	var blockLen:Int = 0;
	var total:Float = 0;

	public function new()
	{
		block = Bytes.alloc(BLOCK_BYTES);
	}

	public function update(bytes:Bytes, pos:Int, len:Int):Void
	{
		var i:Int = pos;
		var end:Int = pos + len;
		while (i < end)
		{
			if (blockLen == BLOCK_BYTES)
			{
				processBlock();
				blockLen = 0;
			}
			var take:Int = end - i;
			var room:Int = BLOCK_BYTES - blockLen;
			if (take > room) take = room;
			var k:Int = 0;
			while (k < take)
			{
				block.set(blockLen + k, bytes.get(i + k));
				k++;
			}
			blockLen += take;
			i += take;
		}
		total += len;
	}

	public function digest():String
	{
		var bitLen:Float = total * 8;

		block.set(blockLen++, 0x80);
		if (blockLen > 56)
		{
			while (blockLen < BLOCK_BYTES) block.set(blockLen++, 0);
			processBlock();
			blockLen = 0;
		}
		while (blockLen < 56) block.set(blockLen++, 0);

		// 64-bit little-endian length. Do not use Std.int(lo / 256^k): once the bit length
		// exceeds 2^31 that division saturates instead of truncating on neko/cpp and the low
		// words come out wrong. Splitting into two parts below 65536 keeps every Std.int safe.
		var lo:Float = bitLen % 4294967296.0;
		var hi:Float = Math.floor(bitLen / 4294967296.0);
		var loLow:Float = lo % 65536.0;
		var loHigh:Float = Math.floor(lo / 65536.0);
		var hiLow:Float = hi % 65536.0;
		var hiHigh:Float = Math.floor(hi / 65536.0);
		block.set(56, Std.int(loLow % 256.0) & 0xFF);
		block.set(57, Std.int(Math.floor(loLow / 256.0)) & 0xFF);
		block.set(58, Std.int(loHigh % 256.0) & 0xFF);
		block.set(59, Std.int(Math.floor(loHigh / 256.0)) & 0xFF);
		block.set(60, Std.int(hiLow % 256.0) & 0xFF);
		block.set(61, Std.int(Math.floor(hiLow / 256.0)) & 0xFF);
		block.set(62, Std.int(hiHigh % 256.0) & 0xFF);
		block.set(63, Std.int(Math.floor(hiHigh / 256.0)) & 0xFF);
		processBlock();

		var out:Bytes = Bytes.alloc(16);
		putLE(out, 0, a);
		putLE(out, 4, b);
		putLE(out, 8, c);
		putLE(out, 12, d);
		return out.toHex();
	}

	function processBlock():Void
	{
		var m:Array<Int> = [];
		var i:Int = 0;
		while (i < 16)
		{
			m[i] = block.get(i * 4) | (block.get(i * 4 + 1) << 8) | (block.get(i * 4 + 2) << 16) | (block.get(i * 4 + 3) << 24);
			i++;
		}

		var aa:Int = a;
		var bb:Int = b;
		var cc:Int = c;
		var dd:Int = d;

		var j:Int = 0;
		while (j < 64)
		{
			var f:Int;
			var g:Int;
			if (j < 16)
			{
				f = (bb & cc) | (~bb & dd);
				g = j;
			}
			else if (j < 32)
			{
				f = (dd & bb) | (~dd & cc);
				g = (5 * j + 1) % 16;
			}
			else if (j < 48)
			{
				f = bb ^ cc ^ dd;
				g = (3 * j + 5) % 16;
			}
			else
			{
				f = cc ^ (bb | ~dd);
				g = (7 * j) % 16;
			}
			f = f + aa + K[j] + m[g];
			aa = dd;
			dd = cc;
			cc = bb;
			bb = bb + rotl(f, S[j]);
			j++;
		}

		a += aa;
		b += bb;
		c += cc;
		d += dd;
	}

	static inline function rotl(x:Int, n:Int):Int
	{
		return (x << n) | (x >>> (32 - n));
	}

	static function putLE(out:Bytes, pos:Int, v:Int):Void
	{
		out.set(pos, v & 0xFF);
		out.set(pos + 1, (v >>> 8) & 0xFF);
		out.set(pos + 2, (v >>> 16) & 0xFF);
		out.set(pos + 3, (v >>> 24) & 0xFF);
	}

	// ── chart file hashing with loadRawSong's byte handling ────────────────

	public static inline function isJsonSpace(c:Int):Bool
	{
		return (c > 8 && c < 14) || c == 32;
	}

	/** MD5 of the file after the same trim + tail cut (== Md5.encode(Song.loadRawSong(...))). */
	public static function hashChartFile(path:String):String
	{
		var start:Int = findJsonStart(path);
		var end:Int = findJsonEnd(path, start);
		var md5:Md5Stream = new Md5Stream();
		if (end > start)
		{
			var input:FileInput = File.read(path, true);
			try
			{
				input.seek(start, FileSeek.SeekBegin);
				var remaining:Int = end - start;
				var buf:Bytes = Bytes.alloc(CHUNK);
				while (remaining > 0)
				{
					var want:Int = (remaining < buf.length) ? remaining : buf.length;
					var got:Int = input.readBytes(buf, 0, want);
					if (got <= 0) break;
					md5.update(buf, 0, got);
					remaining -= got;
				}
			}
			catch (e:haxe.io.Eof) {}
			input.close();
		}
		return md5.digest();
	}

	/** Offset of the first non-whitespace byte (the trim). */
	static function findJsonStart(path:String):Int
	{
		var input:FileInput = File.read(path, true);
		var buf:Bytes = Bytes.alloc(1 << 16);
		var base:Int = 0;
		var res:Int = 0;
		var found:Bool = false;
		while (!found)
		{
			var got:Int = 0;
			try got = input.readBytes(buf, 0, buf.length) catch (e:haxe.io.Eof) got = 0;
			if (got <= 0) break;
			var i:Int = 0;
			while (i < got)
			{
				if (!isJsonSpace(buf.get(i)))
				{
					res = base + i;
					found = true;
					break;
				}
				i++;
			}
			base += got;
		}
		input.close();
		return res;
	}

	/** Position after the last '}' (the tail cut). */
	static function findJsonEnd(path:String, start:Int):Int
	{
		var size:Int = Std.int(sys.FileSystem.stat(path).size);
		var input:FileInput = File.read(path, true);
		var win:Int = 1 << 20;
		var lastBrace:Int = -1;
		while (true)
		{
			var from:Int = size - win;
			if (from < 0) from = 0;
			var len:Int = size - from;
			if (len > 0)
			{
				input.seek(from, FileSeek.SeekBegin);
				var b:Bytes = Bytes.alloc(len);
				try input.readFullBytes(b, 0, len) catch (e:Dynamic) {};
				var i:Int = len - 1;
				while (i >= 0)
				{
					if (b.get(i) == 125) // '}'
					{
						lastBrace = from + i;
						break;
					}
					i--;
				}
			}
			if (lastBrace >= 0 || from == 0) break;
			win = win * 4;
		}
		input.close();
		if (lastBrace < 0 || lastBrace < start) return start;
		return lastBrace + 1;
	}
}
