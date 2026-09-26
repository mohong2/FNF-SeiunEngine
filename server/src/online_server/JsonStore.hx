package online_server;

import haxe.Json;
import haxe.crypto.Sha256;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import sys.thread.Mutex;

/**
 * Local JSON storage primitives.
 *
 * Accounts / scores / comments all use local JSON files (sys.io.File + haxe.Json); no
 * external storage or auth dependency is used.
 *
 * Threading: HTTP handles one thread per connection, so the storage layer serializes
 * read-modify-write with one static Mutex. Callers use lock() and must not call a locking public
 * method from inside the callback (self-deadlock). Every successful write flushes immediately,
 * which is enough at LAN transaction rates.
 */
class JsonStore {
	public static var mutex(default, null):Mutex = new Mutex();

	public static inline function lock<T>(cb:Void->T):T {
		mutex.acquire();
		var result = cb();
		mutex.release();
		return result;
	}

	/** Reads JSON; returns fallback (and logs the reason) when the file is missing or malformed. */
	public static function read(path:String, fallback:Dynamic):Dynamic {
		if (path == null || !FileSystem.exists(path))
			return fallback;
		try {
			var text = File.getContent(path);
			if (text == null || StringTools.trim(text) == "")
				return fallback;
			return Json.parse(text);
		} catch (e:Dynamic) {
			trace('[store] parse failed: ' + path + ' -> ' + Std.string(e));
			return fallback;
		}
	}

	public static function write(path:String, data:Dynamic):Void {
		if (path == null) return;
		try {
			var dir = Path.directory(path);
			if (dir != "" && !FileSystem.exists(dir)) FileSystem.createDirectory(dir);
			File.saveContent(path, Json.stringify(data));
		} catch (e:Dynamic) {
			trace('[store] write failed: ' + path + ' -> ' + Std.string(e));
		}
	}

	/**
	 * Random hex string (account token). No JWT dependency: a time / Math.random / Std.random
	 * seed goes through the built-in SHA256.
	 */
	static var tokenSeq:Int = 0;

	public static function randomHex(hexChars:Int = 64):String {
		tokenSeq++;
		var seed = Std.string(Date.now().getTime()) + ':' + Std.string(tokenSeq) + ':' + Std.string(haxe.Timer.stamp());
		try {
			// Std.random throws on neko (missing std@random_int), so only Math.random is used;
			// if even that throws, the time + counter seed is still sufficient.
			seed += ':' + Std.string(Math.random()) + ':' + Std.string(Math.random());
		} catch (e:Dynamic) {}
		var digest = Sha256.encode(seed);
		return digest.substr(0, hexChars > digest.length ? digest.length : hexChars);
	}

	/** ISO-8601 UTC with a fixed format, independent of locale. */
	public static function isoNow():String {
		return isoOf(Date.now().getTime());
	}

	/**
	 * Converts a millisecond timestamp to the same ISO format as isoNow() (null passes through);
	 * used for /api/user/info's joined / lastActive fields.
	 */
	public static function isoOf(ms:Null<Float>):String {
		if (ms == null) return null;
		var d = Date.fromTime(ms);
		return d.getUTCFullYear() + '-' + pad2(d.getUTCMonth() + 1) + '-' + pad2(d.getUTCDate())
			+ 'T' + pad2(d.getUTCHours()) + ':' + pad2(d.getUTCMinutes()) + ':' + pad2(d.getUTCSeconds()) + 'Z';
	}

	static function pad2(n:Int):String return (n < 10 ? '0' : '') + n;
}
