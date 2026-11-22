package backend;

import backend.BackupFormat.BackupContainer;
import backend.BackupFormat.BackupError;
import haxe.Json;
import haxe.Serializer;
import haxe.Unserializer;
import haxe.io.Bytes;

/** One score-history file carried by a backup. `data` is base64 of the raw file bytes. */
typedef BackupScoreFile =
{
	var path:String;
	var size:Int;
	var hash:Int;
	var data:String;
}

/** A decoded score blob, ready to be written. */
typedef BackupScoreBlob =
{
	var path:String;
	var bytes:Bytes;
}

/** What a payload write actually put into the file, for the status line and the logs. */
typedef BackupJsonStats =
{
	var scores:Int;
	var scoreBytes:Int;
}

/**
 * The JSON payload of a backup, in memory.
 *
 * Everything here is engine-independent on purpose (the test suite compiles this file
 * with plain haxe --interp). The engine side — reading FlxG.save, writing files — lives in
 * BackupUtil.
 *
 * ## Save data is stored as Serializer strings
 *
 * A save payload contains real Haxe values: `Map<String, Int64>`, `Map<String, Dynamic>`,
 * nested arrays, boxed Int64 and so on. Converting that to JSON field by field is exactly
 * how the old backup lost data: maps turned into empty objects, Int64 turned into
 * objects with no fields, and the restore silently skipped whatever it could not convert.
 *
 * Instead every field of the save is stored as the output of `haxe.Serializer.run(value)`
 * — the same serializer FlxSave itself uses for the save file. Round-tripping is exact by
 * construction, and a value that cannot be serialized is skipped at export time (and
 * logged) instead of corrupting the whole backup.
 */
class BackupData
{
	public static inline var FORMAT = 2;
	public static inline var ENGINE = 'FNF-SeiunEngine';

	/** Metadata shown before restoring. */
	public var engine:String = ENGINE;
	public var engineVersion:String = '';
	public var buildVersion:String = '';
	public var platform:String = '';
	public var createdAt:String = '';
	public var createdAtUnix:Float = 0;

	/** Save field name -> Serializer string of its value. */
	public var saveFields:Map<String, String> = new Map();

	/** Control name -> key codes. */
	public var keyboard:Map<String, Array<Int>> = new Map();
	/** Control name -> gamepad button ids. */
	public var gamepad:Map<String, Array<Int>> = new Map();

	public var scores:Array<BackupScoreFile> = [];

	/** True when this was converted from a v1 file written by an older build. */
	public var legacy:Bool = false;

	/**
	 * Decoding is done once and kept: a restore validates first (parse) and applies
	 * later, and decoding the same 20 MB of score files twice doubled both the work and
	 * the memory. Kept in memory once decoded, with the base64 text released.
	 */
	var decodedValues:Map<String, Dynamic> = null;
	var decodedBlobs:Array<BackupScoreBlob> = null;

	public function new() {}

	// ------------------------------------------------------------------ build

	/**
	 * Serializes a live value map into the string map a payload stores.
	 * With `onSkip` a value that cannot be serialized is dropped instead of failing the
	 * export (the caller logs it); without it the problem is reported, which is what tests
	 * and any future strict caller want.
	 */
	public static function encodeSaveFields(values:Map<String, Dynamic>,
			?onSkip:String->String->Void):Map<String, String>
	{
		var out:Map<String, String> = new Map();
		for (field => value in values)
		{
			if (field == null || field.length == 0) continue;
			try
			{
				out.set(field, Serializer.run(value));
			}
			catch (e:Dynamic)
			{
				if (onSkip == null)
					throw new BackupError('save field "' + field + '" cannot be serialized');
				onSkip(field, Std.string(e));
			}
		}
		return out;
	}

	// ------------------------------------------------------------------ parse

	/** Turns an unpacked container into a payload, upgrading v1 files on the way. */
	public static function fromContainer(container:BackupContainer):BackupData
	{
		if (container == null || container.json == null)
			throw new BackupError('the backup payload is empty');

		var parsed:Dynamic = null;
		try
		{
			parsed = Json.parse(container.json);
		}
		catch (e:Dynamic)
		{
			throw new BackupError('the backup payload is not valid JSON');
		}

		if (parsed == null || Type.typeof(parsed) != TObject)
			throw new BackupError('the backup payload has no data');

		return container.legacy ? upgradeLegacy(parsed) : fromJson(parsed);
	}

	public static function fromJson(obj:Dynamic):BackupData
	{
		var data = new BackupData();

		var format:Int = intOf(obj.format, -1);
		if (format >= 0 && format != FORMAT)
			throw new BackupError('unsupported backup payload version ' + format);

		data.engine = strOf(obj.engine, ENGINE);
		data.engineVersion = strOf(obj.engineVersion, '');
		data.buildVersion = strOf(obj.buildVersion, strOf(obj.build, ''));
		data.platform = strOf(obj.platform, '');
		data.createdAt = strOf(obj.createdAt, '');
		data.createdAtUnix = floatOf(obj.createdAtUnix, 0);

		if (obj.saveFields != null)
			data.saveFields = stringMapOf(obj.saveFields, 'saveFields');

		if (obj.keyboard != null)
			data.keyboard = codeMapOf(obj.keyboard, 'keyboard');

		if (obj.gamepad != null)
			data.gamepad = codeMapOf(obj.gamepad, 'gamepad');

		if (obj.scores != null)
		{
			if (!Std.isOfType(obj.scores, Array))
				throw new BackupError('the backup score list is damaged');

			var list:Array<Dynamic> = cast obj.scores;
			for (item in list)
			{
				if (item == null) continue;
				var path:String = strOf(item.path, '');
				var payload:String = strOf(item.data, '');
				if (path.length == 0 || payload.length == 0)
					throw new BackupError('the backup contains an empty score entry');

				data.scores.push({
					path: path,
					size: intOf(item.size, -1),
					hash: intOf(item.hash, 0),
					data: payload
				});
			}
		}

		return data;
	}

	/**
	 * Converts the payload of a file written by the old backup code.
	 *
	 * The old shape was:
	 * ```
	 * { version:1, timestamp, engine, highscoreData:{songScores:{...}, songRating:{...}},
	 *   allscoreData:[{type:"score", fileName:"song/diff/x.json", data:"<base64>"}],
	 *   clientPrefs:{...}, weekCompleted:{week:true} }
	 * ```
	 * Highscore maps have to be rebuilt as real Maps (the save reads them with
	 * `for (k => v in map)`), everything under clientPrefs maps 1:1 onto save fields.
	 * Fields the old exporter never captured (note colours, combo offsets, mod settings)
	 * simply stay absent; BackupUtil merges legacy restores instead of replacing the save
	 * so those keep their current values.
	 */
	public static function upgradeLegacy(obj:Dynamic):BackupData
	{
		var data = new BackupData();
		data.legacy = true;
		data.engine = strOf(obj.engine, ENGINE + ' (legacy)');
		data.createdAt = strOf(obj.timestamp, '');
		data.createdAtUnix = 0;

		// ---- high scores
		var hs:Dynamic = obj.highscoreData;
		if (hs != null && Type.typeof(hs) == TObject)
		{
			addIntStringMap(data, hs, 'songScores');
			addFloatMap(data, hs, 'songRating');
			addIntStringMap(data, hs, 'weekScores');
			addIntStringMap(data, hs, 'songSicks');
			addIntStringMap(data, hs, 'songGoods');
			addIntStringMap(data, hs, 'songBads');
			addIntStringMap(data, hs, 'songShits');
			addIntStringMap(data, hs, 'songMisses');
			addIntStringMap(data, hs, 'songMaxCombo');
		}

		// ---- client preferences
		var prefs:Dynamic = obj.clientPrefs;
		if (prefs != null && Type.typeof(prefs) == TObject)
		{
			for (field in Reflect.fields(prefs))
			{
				if (field == 'keyBinds' || field == 'gameplaySettings') continue;
				var value:Dynamic = Reflect.field(prefs, field);
				if (value == null) continue;
				try
				{
					data.saveFields.set(field, Serializer.run(value));
				}
				catch (e:Dynamic)
				{
					// one unserializable field must not lose the rest of the backup
				}
			}

			// game settings are a Map in the live save, not an anonymous object
			if (prefs.gameplaySettings != null && Type.typeof(prefs.gameplaySettings) == TObject)
				data.saveFields.set('gameplaySettings', Serializer.run(objectToMap(prefs.gameplaySettings)));

			if (prefs.keyBinds != null && Type.typeof(prefs.keyBinds) == TObject)
				data.keyboard = codeMapOf(prefs.keyBinds, 'keyBinds');
		}

		// ---- week completion
		if (obj.weekCompleted != null && Type.typeof(obj.weekCompleted) == TObject)
			data.saveFields.set('weekCompleted', Serializer.run(objectToBoolMap(obj.weekCompleted)));

		// ---- score history + replays
		if (obj.allscoreData != null && Std.isOfType(obj.allscoreData, Array))
		{
			var list:Array<Dynamic> = cast obj.allscoreData;
			for (entry in list)
			{
				if (entry == null) continue;
				var path:String = strOf(entry.fileName, '');
				var payload:String = strOf(entry.data, '');
				if (path.length == 0 || payload.length == 0) continue;

				var bytes:Bytes = null;
				try
				{
					bytes = BackupFormat.decodeText(payload);
				}
				catch (e:Dynamic)
				{
					continue; // a broken legacy entry is dropped, the rest still restores
				}

				data.scores.push({
					path: path,
					size: bytes.length,
					hash: BackupFormat.hash(bytes),
					data: BackupFormat.encodeRaw(bytes)
				});
			}
		}

		return data;
	}

	// ------------------------------------------------------------------ write

	/**
	 * Writes the payload as JSON text, one small piece at a time.
	 *
	 * The old code built the whole payload as a Dynamic tree and ran Json.stringify on
	 * it: the score base64 existed once per entry and once more in the joined string, and
	 * a 23 MB score history needed well over 100 MB before anything was written to disk.
	 * Here the score bytes are streamed straight from disk into the payload through
	 * `openScore`, so the only score data in memory is the file currently being written.
	 *
	 * `sink` receives chunks of the plain JSON text and must not hold on to them: the
	 * caller hashes and encodes them right away.
	 */
	public function writeJson(sink:String->Void, ?openScore:BackupScoreFile->Bytes):BackupJsonStats
	{
		var stats:BackupJsonStats = {scores: 0, scoreBytes: 0};
		var buf:StringBuf = new StringBuf();

		function flush():Void
		{
			if (buf.length == 0) return;
			sink(buf.toString());
			buf = new StringBuf();
		}

		buf.add('{"format":');
		buf.add(Std.string(FORMAT));
		buf.add(',"engine":');
		quote(buf, engine);
		buf.add(',"engineVersion":');
		quote(buf, engineVersion);
		buf.add(',"buildVersion":');
		quote(buf, buildVersion);
		buf.add(',"platform":');
		quote(buf, platform);
		buf.add(',"createdAt":');
		quote(buf, createdAt);
		buf.add(',"createdAtUnix":');
		buf.add(numberText(createdAtUnix));

		buf.add(',"saveFields":{');
		var first:Bool = true;
		for (field in sortedKeys(saveFields))
		{
			if (!first) buf.add(',');
			first = false;
			quote(buf, field);
			buf.add(':');
			quote(buf, saveFields.get(field));
			if (buf.length >= 16384) flush();
		}
		buf.add('}');

		buf.add(',"keyboard":');
		writeCodeMap(buf, keyboard);
		buf.add(',"gamepad":');
		writeCodeMap(buf, gamepad);
		flush();

		buf.add(',"scores":[');
		flush();

		var wroteScore:Bool = false;
		for (i in 0...scores.length)
		{
			var score:BackupScoreFile = scores[i];
			var stored:String = score.data;
			var size:Int = score.size;
			var checksum:Int = score.hash;
			var bytes:Bytes = null;

			if (stored == null)
			{
				if (openScore == null)
					throw new BackupError('score file "' + score.path + '" has no data');

				// null means "this file could not be read": the opener has already logged
				// why, and one unreadable history entry must not lose the whole backup.
				bytes = openScore(score);
				if (bytes == null) continue;
				if (bytes.length == 0) continue;

				size = bytes.length;
				checksum = BackupFormat.hash(bytes);
			}

			if (wroteScore) buf.add(',');
			wroteScore = true;
			buf.add('{"path":');
			quote(buf, score.path);
			buf.add(',"size":');
			buf.add(Std.string(size));
			buf.add(',"hash":');
			buf.add(Std.string(checksum));
			buf.add(',"data":');
			flush();

			if (stored != null)
			{
				quote(buf, stored);
				flush();
			}
			else
			{
				sink('"');
				BackupFormat.streamBase64(bytes, 0, bytes.length, sink);
				sink('"');
			}

			buf.add('}');
			flush();

			stats.scores++;
			stats.scoreBytes += size;
			bytes = null; // let this file go before the next one is read
		}

		buf.add(']}');
		flush();

		return stats;
	}

	// ------------------------------------------------------------------ writing helpers

	/** JSON string literal, escaped exactly like JsonPrinter does. */
	static function quote(buf:StringBuf, value:String):Void
	{
		buf.add('"');
		if (value != null)
		{
			var length:Int = value.length;
			var start:Int = 0;

			for (i in 0...length)
			{
				var code:Int = value.charCodeAt(i);
				if (code >= 0x20 && code != 0x22 && code != 0x5C) continue;

				if (i > start) buf.add(value.substr(start, i - start));

				switch (code)
				{
					case 0x22:
						buf.add('\\"');
					case 0x5C:
						buf.add('\\\\');
					case 0x08:
						buf.add('\\b');
					case 0x0C:
						buf.add('\\f');
					case 0x0A:
						buf.add('\\n');
					case 0x0D:
						buf.add('\\r');
					case 0x09:
						buf.add('\\t');
					default:
						buf.add('\\u00' + StringTools.hex(code, 2));
				}
				start = i + 1;
			}

			if (start < length) buf.add(value.substr(start, length - start));
		}
		buf.add('"');
	}

	static function numberText(value:Float):String
	{
		if (Math.isNaN(value) || !Math.isFinite(value)) return '0';
		return Std.string(value);
	}

	static function writeCodeMap(buf:StringBuf, map:Map<String, Array<Int>>):Void
	{
		buf.add('{');
		var first:Bool = true;
		for (name in sortedKeys(map))
		{
			if (!first) buf.add(',');
			first = false;

			quote(buf, name);
			buf.add(':[');
			var codes:Array<Int> = map.get(name);
			if (codes != null)
			{
				for (i in 0...codes.length)
				{
					if (i > 0) buf.add(',');
					buf.add(Std.string(codes[i]));
				}
			}
			buf.add(']');
		}
		buf.add('}');
	}

	static function sortedKeys<V>(map:Map<String, V>):Array<String>
	{
		var out:Array<String> = [];
		if (map != null)
			for (key in map.keys()) out.push(key);
		out.sort(function(a, b) return a < b ? -1 : (a > b ? 1 : 0));
		return out;
	}

	// ------------------------------------------------------------------ validate

	/**
	 * Rebuilds every live save value. Throws when one of them cannot be read, so the
	 * caller can abort before touching the current save.
	 */
	public function decodeSaveFields():Map<String, Dynamic>
	{
		if (decodedValues != null) return decodedValues;

		var out:Map<String, Dynamic> = new Map();
		for (field => encoded in saveFields)
		{
			if (field == null || field.length == 0)
				throw new BackupError('the backup contains an unnamed save field');
			if (encoded == null || encoded.length == 0)
				throw new BackupError('the backup field "' + field + '" is empty');

			var value:Dynamic = null;
			var consumed:Int = 0;
			try
			{
				var reader:Unserializer = new Unserializer(encoded);
				value = reader.unserialize();
				consumed = @:privateAccess reader.pos;
			}
			catch (e:Dynamic)
			{
				throw new BackupError('the backup field "' + field + '" cannot be read');
			}

			// Unserializer stops at the first complete value, so a truncated tail after a
			// valid prefix would "decode" (e.g. "t..." becomes true). One field has to be
			// exactly one value, otherwise the payload is not what it claims to be.
			if (consumed != encoded.length)
				throw new BackupError('the backup field "' + field + '" is truncated');

			out.set(field, value);
		}

		decodedValues = out;
		return out;
	}

	/**
	 * Decodes every score file and verifies its size and hash. Throws on any damage.
	 * The base64 copy of each file is released as soon as it has been decoded, and the
	 * result is kept so a later call does not decode the same data again.
	 */
	public function decodeScores():Array<BackupScoreBlob>
	{
		if (decodedBlobs != null) return decodedBlobs;

		var out:Array<BackupScoreBlob> = [];
		var seen:Map<String, Bool> = new Map();

		for (score in scores)
		{
			var path:String = sanitizeScorePath(score.path);
			if (path == null)
				throw new BackupError('the backup contains an unsafe score path: ' + score.path);

			if (seen.exists(path))
				throw new BackupError('the backup contains the same score file twice: ' + path);
			seen.set(path, true);

			var bytes:Bytes = null;
			try
			{
				bytes = BackupFormat.decodeText(score.data);
			}
			catch (e:Dynamic)
			{
				throw new BackupError('score file "' + path + '" is damaged (bad encoding)');
			}

			if (score.size >= 0 && bytes.length != score.size)
				throw new BackupError('score file "' + path + '" is truncated');
			if (BackupFormat.hash(bytes) != score.hash)
				throw new BackupError('score file "' + path + '" is damaged (checksum mismatch)');

			score.data = null; // released: the decoded bytes are what the restore writes
			out.push({path: path, bytes: bytes});
		}

		decodedBlobs = out;
		return out;
	}

	public function saveFieldCount():Int return mapSize(saveFields);
	public function scoreCount():Int return scores.length;

	public function scoreBytes():Int
	{
		var total:Int = 0;
		for (score in scores)
			if (score.size > 0) total += score.size;
		return total;
	}

	// ------------------------------------------------------------------ helpers

	/**
	 * Normalizes and validates a path inside the score directory.
	 * Returns null for anything that could escape .scores or cannot be written portably.
	 */
	public static function sanitizeScorePath(path:String):String
	{
		if (path == null) return null;

		var p:String = StringTools.replace(path, '\\', '/');
		while (p.indexOf('./') == 0) p = p.substr(2);

		if (p.length == 0 || p.length > 200) return null;
		if (p.charAt(0) == '/' || p.indexOf(':') >= 0) return null;
		if (!p.endsWith('.json')) return null;

		var parts:Array<String> = p.split('/');
		var clean:Array<String> = [];
		var forbidden:String = '\\:*?"<>|';

		for (part in parts)
		{
			if (part.length == 0 || part == '.') continue;
			if (part == '..') return null;
			if (part.length > 120) return null;
			if (part.charAt(part.length - 1) == '.' || part.charAt(part.length - 1) == ' ') return null;

			for (i in 0...part.length)
			{
				var code:Int = part.charCodeAt(i);
				if (code < 32) return null;
				if (forbidden.indexOf(part.charAt(i)) >= 0) return null;
			}
			clean.push(part);
		}

		if (clean.length == 0) return null;
		return clean.join('/');
	}

	static function objectToMap(obj:Dynamic):Map<String, Dynamic>
	{
		var out:Map<String, Dynamic> = new Map();
		for (field in Reflect.fields(obj))
			out.set(field, Reflect.field(obj, field));
		return out;
	}

	static function objectToBoolMap(obj:Dynamic):Map<String, Bool>
	{
		var out:Map<String, Bool> = new Map();
		for (field in Reflect.fields(obj))
			out.set(field, Reflect.field(obj, field) == true);
		return out;
	}

	static function stringMapOf(value:Dynamic, what:String):Map<String, String>
	{
		if (Type.typeof(value) != TObject)
			throw new BackupError('the backup ' + what + ' section is damaged');

		var out:Map<String, String> = new Map();
		for (field in Reflect.fields(value))
		{
			var entry:Dynamic = Reflect.field(value, field);
			if (entry == null)
				throw new BackupError('the backup ' + what + ' section is damaged (empty "' + field + '")');
			if (!Std.isOfType(entry, String))
				throw new BackupError('the backup ' + what + ' section is damaged (bad "' + field + '")');
			out.set(field, entry);
		}
		return out;
	}

	static function codeMapOf(value:Dynamic, what:String):Map<String, Array<Int>>
	{
		if (Type.typeof(value) != TObject)
			throw new BackupError('the backup ' + what + ' section is damaged');

		var out:Map<String, Array<Int>> = new Map();
		for (field in Reflect.fields(value))
		{
			var entry:Dynamic = Reflect.field(value, field);
			if (entry == null || !Std.isOfType(entry, Array)) continue;

			var list:Array<Dynamic> = cast entry;
			var codes:Array<Int> = [];
			for (item in list)
			{
				if (item == null) continue;
				// -1 is a real code (FlxKey.NONE / FlxGamepadInputID.NONE), not a missing
				// one: dropping it rewrote every bind that has a "no second key" slot.
				codes.push(intOf(item, -1));
			}
			out.set(field, codes);
		}
		return out;
	}

	static function addIntStringMap(data:BackupData, source:Dynamic, field:String):Void
	{
		var raw:Dynamic = Reflect.field(source, field);
		if (raw == null) return;

		var map:Map<String, String> = new Map();
		if (Type.typeof(raw) == TObject)
		{
			for (key in Reflect.fields(raw))
			{
				var value:Dynamic = Reflect.field(raw, key);
				if (value == null) continue;
				map.set(key, Std.string(value));
			}
		}

		if (mapSize(map) == 0) return;
		data.saveFields.set(field, Serializer.run(map));
	}

	static function addFloatMap(data:BackupData, source:Dynamic, field:String):Void
	{
		var raw:Dynamic = Reflect.field(source, field);
		if (raw == null || Type.typeof(raw) != TObject) return;

		var map:Map<String, Float> = new Map();
		for (key in Reflect.fields(raw))
		{
			var value:Dynamic = Reflect.field(raw, key);
			if (value == null) continue;
			var parsed:Float = Std.parseFloat(Std.string(value));
			if (Math.isNaN(parsed)) parsed = 0;
			map.set(key, parsed);
		}

		if (mapSize(map) == 0) return;
		data.saveFields.set(field, Serializer.run(map));
	}

	/** Map has no count() on this Haxe version; every caller only needs "is it empty?". */
	static function mapSize<K, V>(map:Map<K, V>):Int
	{
		if (map == null) return 0;
		var n:Int = 0;
		for (_ in map.keys()) n++;
		return n;
	}

	static function strOf(value:Dynamic, fallback:String):String
	{
		if (value == null) return fallback;
		var text:String = Std.string(value);
		return text.length == 0 ? fallback : text;
	}

	static function intOf(value:Dynamic, fallback:Int):Int
	{
		if (value == null) return fallback;
		if (Std.isOfType(value, Int)) return value;
		var parsed:Float = Std.parseFloat(Std.string(value));
		return Math.isNaN(parsed) ? fallback : Std.int(parsed);
	}

	static function floatOf(value:Dynamic, fallback:Float):Float
	{
		if (value == null) return fallback;
		var parsed:Float = Std.parseFloat(Std.string(value));
		return Math.isNaN(parsed) ? fallback : parsed;
	}
}
