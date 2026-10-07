package online.util;

/**
 * Pure UTF-8 aware text helpers for the online UI (no engine imports, so a standalone probe can
 * compile this module alone with -D server_build).
 *
 * Why it exists: on neko and hxcpp (the targets this engine ships) `String.length`,
 * `String.charAt` and `String.substr` work on BYTES, not characters. ServerConfig says the same
 * thing for the server side ("String.length is a byte count on neko/hxcpp", ServerConfig.hx:584).
 * Any width/wrap/truncate decision taken with String.length therefore counts a 3-byte CJK
 * character as three and an emoji as four.
 *
 * Everything here operates on lead bytes: a UTF-8 continuation byte (0b10xxxxxx) never starts a
 * codepoint. ASCII is unaffected, so callers that used to be ASCII-correct stay identical.
 */
class TextWrap {
	/**
	 * Wrap so every line holds at most `lineLength` CODEPOINTS.
	 * ASCII output is byte-for-byte identical to the previous byte-counting implementation.
	 */
	public static function wrap(string:String, lineLength:Int):String {
		var lines:Array<String> = [];
		var sentence = '';
		var sentenceChars = 0;
		var word = '';
		var wordChars = 0;

		for (i in 0...string.length) {
			var char = string.charAt(i);

			if (char == ' ' || char == '\n' || i == string.length - 1) {
				if (char == '\n' || sentenceChars + wordChars > lineLength) {
					lines.push(sentence);
					sentence = '';
					sentenceChars = 0;
				}
				if (i == string.length - 1) {
					word += char;
					wordChars += startsCodepoint(char);
				}
				// Keep the ORIGINAL join test (byte length) so ASCII output cannot drift.
				var joined = sentence.length > 0;
				sentence += (joined ? ' ' : '') + word;
				sentenceChars += (joined ? 1 : 0) + wordChars;
				word = '';
				wordChars = 0;
				continue;
			}

			word += char;
			wordChars += startsCodepoint(char);
		}

		if (sentence.length > 0)
			lines.push(sentence);
		return lines.join('\n');
	}

	/** Number of UTF-8 codepoints (null and invalid bytes count as nothing). */
	public static function length(string:String):Int {
		if (string == null)
			return 0;

		var count = 0;
		for (i in 0...string.length)
			count += startsCodepoint(string.charAt(i));
		return count;
	}

	/**
	 * Keep at most `maxCodepoints` characters, never splitting a multi-byte one, and drop bytes
	 * that cannot be valid UTF-8 (a truncated tail, a lone continuation byte). A byte-counting
	 * substr can end inside a CJK character, which puts an invalid sequence into FlxText - the same
	 * failure class task-1 fixed on the server (ServerConfig.truncateUtf8).
	 */
	public static function truncate(string:String, maxCodepoints:Int):String {
		if (string == null || maxCodepoints <= 0)
			return '';

		var out = new StringBuf();
		var kept = 0;
		var i = 0;

		while (i < string.length && kept < maxCodepoints) {
			var size = sequenceSize(string.charCodeAt(i));
			if (size <= 0) {
				i++;
				continue;
			}

			var valid = i + size <= string.length;
			if (valid) {
				for (k in 1...size) {
					if ((string.charCodeAt(i + k) & 0xC0) != 0x80) {
						valid = false;
						break;
					}
				}
			}
			if (!valid) {
				i++;
				continue;
			}

			out.add(string.substr(i, size));
			i += size;
			kept++;
		}

		return out.toString();
	}

	/** 1 when this byte can start a codepoint (ASCII or a lead byte), 0 for a continuation byte. */
	public static function startsCodepoint(char:String):Int {
		if (char == null || char.length == 0)
			return 0;
		return (char.charCodeAt(0) & 0xC0) == 0x80 ? 0 : 1;
	}

	/** Byte length of the UTF-8 sequence a lead byte starts, or 0 when the byte cannot start one. */
	public static function sequenceSize(code:Int):Int {
		if (code < 0x80) return 1;
		if ((code & 0xE0) == 0xC0) return 2;
		if ((code & 0xF0) == 0xE0) return 3;
		if ((code & 0xF8) == 0xF0) return 4;
		return 0;
	}
}
