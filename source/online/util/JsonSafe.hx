package online.util;

#if ONLINE_ALLOWED
import haxe.io.Bytes;

/**
 * JSON serializer that keeps astral (non-BMP) characters intact on the cpp target.
 *
 * Why this exists: haxe.Json.stringify delegates to haxe.format.JsonPrinter, whose quote() feeds
 * every code unit of a string through StringBuf.addChar(). On hxcpp that encodes each UTF-16
 * surrogate of a non-BMP codepoint on its own, so the printer emits two U+FFFD replacement
 * characters instead of the original character. Reproduced by the Lead (temp/lead/AstralProbe.hx):
 * input bytes f09f9880 (U+1F600) -> output efbfbdefbfbd on cpp, while neko and haxe.Json.parse
 * (raw UTF-8) are correct. A player posting an emoji message, bio or comment sent mangled text.
 *
 * This is a small printer instead of a std patch. It mirrors haxe.format.JsonPrinter exactly
 * (same Type.typeof dispatch, same Reflect.fields / Type.getInstanceFields order, same
 * Std.string number formatting, same escapes), but strings are handled as UTF-8 BYTES on a
 * haxe.io.Bytes buffer: a UTF-8 lead/continuation byte is never one of the ASCII characters that
 * need escaping, so a multi-byte character (including a 4-byte astral one) is copied verbatim.
 *
 * One extra repair, because the probe measured it: on neko/cpp, haxe.format.JsonParser takes the
 * !target.unicode branch for uXXXX escapes (JsonParser.hx:193-208), so an escaped surrogate pair
 * arrives as two CESU-8 encoded lone surrogates instead of one astral codepoint. quote() therefore
 * normalizes surrogate bytes: a high+low pair becomes the single 4-byte astral sequence, a lone
 * surrogate or any structurally invalid byte becomes U+FFFD. Nothing invalid can reach the wire.
 *
 * Scope: the online OUTGOING request bodies (FunkinNetwork, Leaderboard, the vendored colyseus
 * HTTP funnel). Local save/editor/hscript call sites are a separate audit (task-13 report).
 */
class JsonSafe {
	/** JSON text for the given value; haxe.Json.stringify output except that astral characters survive. */
	public static function stringify(value:Dynamic):String {
		var buf = new StringBuf();
		write(buf, value);
		return buf.toString();
	}

	/** Dispatch copied from haxe.format.JsonPrinter.write(). */
	static function write(buf:StringBuf, v:Dynamic):Void {
		switch (Type.typeof(v)) {
			case TUnknown:
				buf.add('"???"');
			case TObject:
				writeFields(buf, v, Reflect.fields(v));
			case TInt:
				buf.add(Std.string(v));
			case TFloat:
				buf.add(Math.isFinite(v) ? Std.string(v) : 'null');
			case TFunction:
				buf.add('"<fun>"');
			case TClass(c):
				if (c == String) {
					quote(buf, cast v);
				}
				else if (c == Array) {
					var arr:Array<Dynamic> = cast v;
					buf.add('[');
					var len = arr.length;
					for (i in 0...len) {
						if (i > 0)
							buf.add(',');
						write(buf, arr[i]);
					}
					buf.add(']');
				}
				else if (c == haxe.ds.StringMap) {
					// Map<String, T> is what the matchmaking options use; JsonPrinter prints it as
					// an object built from its keys, and so does this.
					var map:haxe.ds.StringMap<Dynamic> = cast v;
					buf.add('{');
					var empty = true;
					for (k in map.keys()) {
						if (empty)
							empty = false;
						else
							buf.add(',');
						quote(buf, k);
						buf.add(':');
						write(buf, map.get(k));
					}
					buf.add('}');
				}
				else if (c == Date) {
					quote(buf, (cast v:Date).toString());
				}
				else {
					writeFields(buf, v, Type.getInstanceFields(c));
				}
			case TEnum(_):
				buf.add(Std.string(Type.enumIndex(v)));
			case TBool:
				buf.add(v ? 'true' : 'false');
			case TNull:
				buf.add('null');
		}
	}

	/** Object/class body; function-valued fields are skipped exactly like JsonPrinter does. */
	static function writeFields(buf:StringBuf, v:Dynamic, fields:Array<String>):Void {
		buf.add('{');
		var empty = true;
		for (f in fields) {
			var value = Reflect.field(v, f);
			if (Reflect.isFunction(value))
				continue;

			if (empty)
				empty = false;
			else
				buf.add(',');

			quote(buf, f);
			buf.add(':');
			write(buf, value);
		}
		buf.add('}');
	}

	/**
	 * Quote a JSON string as UTF-8 bytes.
	 *
	 * Escape set copied from JsonPrinter: quote, backslash, newline, carriage return, tab, backspace
	 * and form feed. Everything else - including every byte >= 0x80 - is copied unchanged, which is
	 * what keeps astral characters valid on hxcpp.
	 */
	static function quote(buf:StringBuf, s:String):Void {
		if (s == null) {
			buf.add('null');
			return;
		}

		var bytes = normalizeSurrogates(Bytes.ofString(s));
		// An escaped byte emits two bytes, so twice the input plus the quotes always fits.
		var out = Bytes.alloc(bytes.length * 2 + 2);
		var n = 0;
		for (i in 0...bytes.length) {
			var b = bytes.get(i);
			switch (b) {
				case 0x22: { out.set(n++, 0x5C); out.set(n++, 0x22); }
				case 0x5C: { out.set(n++, 0x5C); out.set(n++, 0x5C); }
				case 0x0A: { out.set(n++, 0x5C); out.set(n++, 0x6E); }
				case 0x0D: { out.set(n++, 0x5C); out.set(n++, 0x72); }
				case 0x09: { out.set(n++, 0x5C); out.set(n++, 0x74); }
				case 0x08: { out.set(n++, 0x5C); out.set(n++, 0x62); }
				case 0x0C: { out.set(n++, 0x5C); out.set(n++, 0x66); }
				default: out.set(n++, b);
			}
		}

		buf.add('"');
		buf.add(out.sub(0, n).toString());
		buf.add('"');
	}

	/**
	 * Return UTF-8 bytes with every surrogate repaired: high+low CESU-8 pair -> one 4-byte astral
	 * sequence (a lone surrogate, an overlong sequence or a bad continuation byte -> U+FFFD).
	 * Returns the input untouched when no 0xED byte is present, so ASCII/CJK output cannot change.
	 */
	static function normalizeSurrogates(bytes:Bytes):Bytes {
		var mayHoldSurrogate = false;
		for (i in 0...bytes.length) {
			if (bytes.get(i) == 0xED) {
				mayHoldSurrogate = true;
				break;
			}
		}
		if (!mayHoldSurrogate)
			return bytes;

		// A pair is 6 bytes in and 4 out, a lone surrogate 3 in and 3 out, so this never overflows.
		var out = Bytes.alloc(bytes.length + 4);
		var n = 0;
		var i = 0;
		while (i < bytes.length) {
			var size = sequenceSize(bytes, i);
			if (size == 0) {
				n = appendReplacement(out, n);
				i++;
				continue;
			}

			var cp = decode(bytes, i, size);
			if (size == 3 && cp >= 0xD800 && cp <= 0xDBFF) {
				// A high surrogate; try to consume the low half that follows.
				if (i + 6 <= bytes.length && sequenceSize(bytes, i + 3) == 3) {
					var low = decode(bytes, i + 3, 3);
					if (low >= 0xDC00 && low <= 0xDFFF) {
						var astral = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
						out.set(n++, 0xF0 | (astral >> 18));
						out.set(n++, 0x80 | ((astral >> 12) & 0x3F));
						out.set(n++, 0x80 | ((astral >> 6) & 0x3F));
						out.set(n++, 0x80 | (astral & 0x3F));
						i += 6;
						continue;
					}
				}
				n = appendReplacement(out, n);
				i += 3;
				continue;
			}
			if (size == 3 && cp >= 0xDC00 && cp <= 0xDFFF) {
				n = appendReplacement(out, n);
				i += 3;
				continue;
			}

			for (k in 0...size)
				out.set(n++, bytes.get(i + k));
			i += size;
		}

		return out.sub(0, n);
	}

	/** Writes U+FFFD (efbfbd) at n and returns the new length. */
	static inline function appendReplacement(out:Bytes, n:Int):Int {
		out.set(n, 0xEF);
		out.set(n + 1, 0xBF);
		out.set(n + 2, 0xBD);
		return n + 3;
	}

	/** Byte length of the valid UTF-8 sequence at i (overlong and out-of-range forms rejected), or 0. */
	static function sequenceSize(bytes:Bytes, i:Int):Int {
		var b = bytes.get(i);
		if (b < 0x80)
			return 1;

		if ((b & 0xE0) == 0xC0) {
			if (i + 1 >= bytes.length || (bytes.get(i + 1) & 0xC0) != 0x80 || b < 0xC2)
				return 0;
			return 2;
		}
		if ((b & 0xF0) == 0xE0) {
			if (i + 2 >= bytes.length)
				return 0;
			if ((bytes.get(i + 1) & 0xC0) != 0x80 || (bytes.get(i + 2) & 0xC0) != 0x80)
				return 0;
			if (b == 0xE0 && bytes.get(i + 1) < 0xA0)
				return 0;
			return 3;
		}
		if ((b & 0xF8) == 0xF0) {
			if (i + 3 >= bytes.length)
				return 0;
			if ((bytes.get(i + 1) & 0xC0) != 0x80 || (bytes.get(i + 2) & 0xC0) != 0x80 || (bytes.get(i + 3) & 0xC0) != 0x80)
				return 0;
			if (b == 0xF0 && bytes.get(i + 1) < 0x90)
				return 0;
			if (b > 0xF4 || (b == 0xF4 && bytes.get(i + 1) > 0x8F))
				return 0;
			return 4;
		}
		return 0;
	}

	/** Codepoint of a sequence whose size sequenceSize() already validated. */
	static function decode(bytes:Bytes, i:Int, size:Int):Int {
		var first = bytes.get(i);
		if (size == 1)
			return first;
		var cp = first & (size == 2 ? 0x1F : (size == 3 ? 0x0F : 0x07));
		for (k in 1...size)
			cp = (cp << 6) | (bytes.get(i + k) & 0x3F);
		return cp;
	}
}
#end
