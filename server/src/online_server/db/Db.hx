package online_server.db;

import online_server.Crypto;
import online_server.Log;
import sys.db.Connection;
import sys.thread.Mutex;

/**
 * Process-wide SQLite handle. One connection, one Mutex -- the direct semantic replacement for
 * JsonStore.mutex, including the rule that a callback must never call another Db.lock() (a
 * non-reentrant Mutex would self-deadlock).
 *
 * Every repository goes through this class, so there is exactly one writer, one transaction
 * scope and one place that knows the file name.
 */
class Db {
	public static var mutex(default, null):Mutex = new Mutex();

	static var conn:Connection = null;
	static var dbFile:String = null;
	static var schema:Int = 0;
	static var journal:String = null;
	static var openedAt:Float = 0;

	/** Opens the database, runs the migrations and installs the credential HMAC key. Idempotent. */
	public static function open(path:String):Void {
		mutex.acquire();
		try {
			if (conn != null) {
				mutex.release();
				Log.warn("db", "open() called twice, keeping the existing connection", { path: dbFile });
				return;
			}
			var t0 = haxe.Timer.stamp();
			conn = Sqlite.open(path);
			dbFile = path;
			schema = Migrations.migrate(conn);
			journal = Sqlite.scalarString(conn, "PRAGMA journal_mode", "unknown");
			Crypto.probeEntropy();
			var secret = metaGetLocked("auth.secret");
			var created = false;
			if (secret == null || secret == "") {
				secret = Crypto.newSecretHex();
				metaSetLocked("auth.secret", secret);
				created = true;
			}
			Crypto.initSecret(secret);
			// One-shot migration from the legacy JSON documents. Runs before any Store reads a
			// table; a failure here propagates and aborts startup rather than losing data.
			LegacyImport.bootstrap(haxe.io.Path.directory(path), LegacyImport.force);
			openedAt = haxe.Timer.stamp();
			mutex.release();
			Log.info("db", "sqlite ready", {
				path: path,
				schemaVersion: schema,
				journalMode: journal,
				secretCreated: created,
				osEntropy: Crypto.osEntropyAvailable,
				ms: Std.int((haxe.Timer.stamp() - t0) * 1000)
			});
		} catch (e:Dynamic) {
			mutex.release();
			conn = null;
			Log.error("db", "open failed", { path: path, error: Std.string(e) });
			throw e;
		}
	}

	/**
	 * Canonical database file for the directory that holds a legacy data file. Every Store.init
	 * receives the old "<data-dir>/<name>.json" path, so deriving the database from it keeps all
	 * of them pointing at exactly one file without changing any Store signature.
	 */
	public static function defaultFileFor(legacyFile:String):String {
		var dir = haxe.io.Path.directory(legacyFile);
		if (dir == null || dir == "") dir = ".";
		return dir + "/seiun.sqlite3";
	}

	/** Opens the canonical database for the directory holding legacyFile (idempotent). */
	public static function openFor(legacyFile:String):Void {
		open(defaultFileFor(legacyFile));
	}

	public static function close():Void {
		mutex.acquire();
		try {
			if (conn != null) conn.close();
		} catch (e:Dynamic) {
			Log.warn("db", "close failed", { error: Std.string(e) });
		}
		conn = null;
		mutex.release();
	}

	public static function isOpen():Bool return conn != null;
	public static function filePath():String return dbFile;
	public static function schemaVersion():Int return schema;
	public static function journalMode():String return journal;
	public static function connection():Connection return conn;

	/**
	 * Serialises one repository operation against every other repository operation. Callbacks must
	 * not call Db.lock() again (non-reentrant) and must not leak a row object or a live record out
	 * of the callback: repository methods project rows into freshly built structs first.
	 */
	public static function lock<T>(cb:Void->T):T {
		mutex.acquire();
		// A repository exception must not leave the mutex locked forever (every later DB call,
		// including auth, would block and the whole server would hang). Haxe has no finally, so the
		// release happens on both paths explicitly.
		var result:T;
		try {
			result = cb();
		} catch (e:Dynamic) {
			mutex.release();
			throw e;
		}
		mutex.release();
		return result;
	}

	/**
	 * Runs cb inside BEGIN IMMEDIATE / COMMIT, rolling back on any exception. Must be called while
	 * holding the lock (use lockTx for the common case).
	 */
	public static function tx<T>(cb:Void->T):T {
		Sqlite.exec(conn, "BEGIN IMMEDIATE");
		var result:T;
		try {
			result = cb();
		} catch (e:Dynamic) {
			try Sqlite.exec(conn, "ROLLBACK") catch (e2:Dynamic) {}
			throw e;
		}
		Sqlite.exec(conn, "COMMIT");
		return result;
	}

	public static function lockTx<T>(cb:Void->T):T {
		return lock(function() return tx(cb));
	}

	// ------------------------------------------------------------------
	// Statement helpers (callers already hold the lock)
	// ------------------------------------------------------------------

	public static function exec(sql:String):Void {
		Sqlite.exec(conn, sql);
	}

	public static function query(sql:String):Array<Dynamic> {
		return Sqlite.rows(conn, sql);
	}

	public static function queryOne(sql:String):Dynamic {
		return Sqlite.row(conn, sql);
	}

	public static function scalar(sql:String, fallback:Int = 0):Int {
		return Sqlite.scalarInt(conn, sql, fallback);
	}

	public static function quote(s:String):String {
		return Sqlite.text(conn, s);
	}

	public static function lastInsertId():Int {
		return conn.lastInsertId();
	}

	// ------------------------------------------------------------------
	// meta key/value
	// ------------------------------------------------------------------

	public static function metaGet(key:String):Null<String> {
		return lock(function() return metaGetLocked(key));
	}

	public static function metaSet(key:String, value:String):Void {
		lock(function() {
			metaSetLocked(key, value);
			return true;
		});
	}

	/** Variant for callers that already hold the lock (never acquire it again). */
	public static function metaGetLocked(key:String):Null<String> {
		return Sqlite.scalarString(conn, "SELECT value FROM meta WHERE key = " + Sqlite.text(conn, key), null);
	}

	public static function metaSetLocked(key:String, value:String):Void {
		Sqlite.exec(conn, "INSERT OR REPLACE INTO meta (key, value) VALUES (" + Sqlite.text(conn, key) + ", " + Sqlite.text(conn, value) + ")");
	}

	/** Monotonic per-entity sequence counters (ids such as u12 / s4 / c1 / w2 / r3). */
	public static function nextSeq(counterKey:String):Int {
		return lock(function() return nextSeqLocked(counterKey));
	}

	/** Counter read-and-increment for callers that already hold the lock. */
	public static function nextSeqLocked(counterKey:String):Int {
		var next = seqOfLocked(counterKey) + 1;
		metaSetLocked(counterKey, Std.string(next));
		return next;
	}

	/** Reads a counter without consuming it (import needs to adopt the legacy value). */
	public static function seqOf(counterKey:String):Int {
		return lock(function() return seqOfLocked(counterKey));
	}

	public static function seqOfLocked(counterKey:String):Int {
		var current = Std.parseInt(metaGetLocked(counterKey));
		return current == null ? 0 : current;
	}

	public static function setSeq(counterKey:String, value:Int):Void {
		lock(function() {
			metaSetLocked(counterKey, Std.string(value));
			return true;
		});
	}

	/** Row counts for /api/health and the startup log line. */
	public static function tableCounts():Dynamic {
		return lock(function() {
			var out:Dynamic = {};
			for (name in ["accounts", "sessions", "scores", "comments", "reports", "clubs", "mods", "warns", "admin_logs", "front_messages", "day_players"]) {
				Reflect.setField(out, name, Sqlite.scalarInt(conn, "SELECT COUNT(*) FROM " + name, 0));
			}
			return out;
		});
	}

	public static function uptimeSeconds():Float {
		return openedAt <= 0 ? 0 : haxe.Timer.stamp() - openedAt;
	}
}