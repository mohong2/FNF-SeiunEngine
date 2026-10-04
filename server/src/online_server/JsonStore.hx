package online_server;

import haxe.Json;
import sys.FileSystem;
import sys.io.File;
import sys.thread.Mutex;

/**
 * Legacy JSON utilities.
 *
 * Persistence no longer goes through this class: accounts / leaderboard / clubs / mods / admin /
 * public data live in SQLite (see online_server.db.Db and the repositories). What remains here is
 *  - mutex/lock(), still used for purely in-memory structures (the online-player list, the image
 *    index) that never touch the database,
 *  - read(), used exactly once by db.LegacyImport to ingest an old JSON file,
 *  - randomHex / isoNow / isoOf, the small helpers that predate Crypto and are still referenced
 *    by existing call sites.
 *
 * There is deliberately no write() anymore: nothing in this server rewrites a whole JSON file.
 * randomHex now delegates to Crypto, which draws from the OS entropy device or the HMAC-SHA256
 * DRBG instead of a time+Math.random seed.
 */
class JsonStore {
	public static var mutex(default, null):Mutex = new Mutex();

	/** Serialises an in-memory read-modify-write; never hold it while taking the DB lock (or the reverse). */
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
			Log.warn("legacy", "JSON parse failed", { path: path, error: Std.string(e) });
			return fallback;
		}
	}

	/** Random hex string with `hexChars` characters, from the Crypto CSPRNG/DRBG. */
	public static function randomHex(hexChars:Int = 64):String {
		return Crypto.randomHexChars(hexChars);
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
