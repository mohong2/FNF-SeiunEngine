package online_server.db;

import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.db.Connection;
import sys.db.ResultSet;
import sys.db.Sqlite as SqliteEngine;

/**
 * Thin typed wrapper over sys.db.Sqlite plus the value/row helpers the repositories use.
 *
 * Both supported targets (neko and hxcpp) expose only Connection.request(sql) and
 * Connection.quote(s) -- there are no prepared statements, so every value must be formatted
 * here and every table/column name must come from a code constant. Nothing a client sends may
 * ever be concatenated as an identifier.
 */
class Sqlite {
	/** Opens (creating if needed) the database file and applies the PRAGMAs. */
	public static function open(file:String):Connection {
		var dir = Path.directory(file);
		if (dir != "" && !FileSystem.exists(dir)) FileSystem.createDirectory(dir);
		var conn = SqliteEngine.open(file);
		// WAL: readers never block the writer and a crash cannot leave a half-written page in the
		// main file. busy_timeout: a second connection (the console, a migration run) waits
		// instead of failing immediately with SQLITE_BUSY.
		request(conn, "PRAGMA journal_mode=WAL");
		request(conn, "PRAGMA busy_timeout=5000");
		// NORMAL is the documented pairing for WAL: durable across application crashes, still
		// fsync-ing at every checkpoint. FULL was the JSON layer's weakness, not its goal.
		request(conn, "PRAGMA synchronous=NORMAL");
		request(conn, "PRAGMA foreign_keys=ON");
		return conn;
	}

	/** Runs a statement, wrapping the driver error with the offending SQL for the log. */
	public static function request(conn:Connection, sql:String):ResultSet {
		try {
			return conn.request(sql);
		} catch (e:Dynamic) {
			throw "sqlite: " + Std.string(e) + " [sql: " + sql + "]";
		}
	}

	/** Runs a statement that produces no rows (DDL/DML). */
	public static function exec(conn:Connection, sql:String):Void {
		request(conn, sql);
	}

	/** Runs a query and materialises every row. */
	public static function rows(conn:Connection, sql:String):Array<Dynamic> {
		var rs = request(conn, sql);
		var out:Array<Dynamic> = [];
		while (true) {
			var row = rs.next();
			if (row == null) break;
			out.push(row);
		}
		return out;
	}

	public static function row(conn:Connection, sql:String):Dynamic {
		var all = rows(conn, sql);
		return all.length == 0 ? null : all[0];
	}

	public static function scalarInt(conn:Connection, sql:String, fallback:Int = 0):Int {
		var r = row(conn, sql);
		if (r == null) return fallback;
		var fields = Reflect.fields(r);
		if (fields.length == 0) return fallback;
		return toInt(Reflect.field(r, fields[0]), fallback);
	}

	public static function scalarString(conn:Connection, sql:String, fallback:String = null):String {
		var r = row(conn, sql);
		if (r == null) return fallback;
		var fields = Reflect.fields(r);
		if (fields.length == 0) return fallback;
		var v = Reflect.field(r, fields[0]);
		return v == null ? fallback : Std.string(v);
	}

	public static function lastInsertId(conn:Connection):Int {
		return conn.lastInsertId();
	}

	// ------------------------------------------------------------------
	// Value formatting (the only place SQL literals are produced)
	// ------------------------------------------------------------------

	/** String literal or NULL. */
	public static function text(conn:Connection, s:String):String {
		// Store-layer guarantee: no TEXT column can receive invalid UTF-8, whatever the caller passed.
		return s == null ? "NULL" : conn.quote(online_server.ServerConfig.repairUtf8(s));
	}

	/** Integer literal. */
	public static function int(v:Null<Int>):String {
		return v == null ? "NULL" : Std.string(v);
	}

	/**
	 * REAL literal. Std.string is used directly: on neko Std.int truncates to 32 bits, which would
	 * corrupt every millisecond timestamp (all of them exceed 2^31) and any large score.
	 * Std.string already prints the integral range without an exponent, and a REAL-affinity column
	 * converts the numeric text whatever the notation, so no special case is needed.
	 */
	public static function real(v:Null<Float>):String {
		if (v == null) return "NULL";
		if (v != v) return "NULL";
		if (v == Math.POSITIVE_INFINITY || v == Math.NEGATIVE_INFINITY) return "NULL";
		return Std.string(v);
	}

	public static function bool(v:Null<Bool>):String {
		return v == null ? "NULL" : (v ? "1" : "0");
	}

	/** JSON-encodes a value for a TEXT column holding a list / embedded object; [] when null. */
	public static function json(v:Dynamic, empty:String = "[]"):String {
		if (v == null) return empty;
		// Embedded JSON (notifications, permissions, ...) must not mangle astral characters on cpp.
		return online_server.ServerConfig.jsonEncode(v);
	}

	public static function jsonText(conn:Connection, v:Dynamic, empty:String = "[]"):String {
		return text(conn, json(v, empty));
	}

	// ------------------------------------------------------------------
	// Row readers (SQLite is dynamically typed: coerce, never cast blindly)
	// ------------------------------------------------------------------

	public static function str(row:Dynamic, field:String, fallback:String = null):String {
		if (row == null) return fallback;
		var v:Dynamic = Reflect.field(row, field);
		if (v == null) return fallback;
		return Std.string(v);
	}

	public static function num(row:Dynamic, field:String, fallback:Float = 0.0):Float {
		if (row == null) return fallback;
		var v:Dynamic = Reflect.field(row, field);
		if (v == null) return fallback;
		if (Std.isOfType(v, Float)) return cast(v, Float);
		if (Std.isOfType(v, Int)) return cast(v, Int) * 1.0;
		var parsed = Std.parseFloat(Std.string(v));
		return (parsed != parsed) ? fallback : parsed;
	}

	/**
	 * Coerces a Dynamic (a SQLite column, or a value decoded from a JSON column) to Float.
	 * Used where a typed Float field can still hold null at runtime, which is also the only
	 * cpp-legal spelling: comparing a Float-typed value against null is rejected on static targets.
	 */
	public static function toNum(v:Dynamic, fallback:Float = 0.0):Float {
		if (v == null) return fallback;
		if (Std.isOfType(v, Float)) return cast(v, Float);
		if (Std.isOfType(v, Int)) return cast(v, Int) * 1.0;
		var parsed = Std.parseFloat(Std.string(v));
		return (parsed != parsed) ? fallback : parsed;
	}

	public static function toInt(v:Dynamic, fallback:Int = 0):Int {
		if (v == null) return fallback;
		if (Std.isOfType(v, Int)) return cast(v, Int);
		if (Std.isOfType(v, Float)) {
			var f:Float = v;
			if (f != f) return fallback;
			return Std.int(f);
		}
		var parsed = Std.parseInt(Std.string(v));
		if (parsed != null) return parsed;
		var f2 = Std.parseFloat(Std.string(v));
		return (f2 != f2) ? fallback : Std.int(f2);
	}

	public static function intOf(row:Dynamic, field:String, fallback:Int = 0):Int {
		if (row == null) return fallback;
		return toInt(Reflect.field(row, field), fallback);
	}

	public static function numOrNull(row:Dynamic, field:String):Null<Float> {
		if (row == null) return null;
		var v:Dynamic = Reflect.field(row, field);
		if (v == null) return null;
		return num(row, field, 0.0);
	}

	public static function intOrNull(row:Dynamic, field:String):Null<Int> {
		if (row == null) return null;
		var v:Dynamic = Reflect.field(row, field);
		if (v == null) return null;
		return toInt(v, 0);
	}

	public static function boolOf(row:Dynamic, field:String, fallback:Bool = false):Bool {
		if (row == null) return fallback;
		var v:Dynamic = Reflect.field(row, field);
		if (v == null) return fallback;
		if (Std.isOfType(v, Bool)) return cast(v, Bool);
		if (Std.isOfType(v, Int)) return cast(v, Int) != 0;
		var s = Std.string(v).toLowerCase();
		return s == "1" || s == "true" || s == "yes";
	}

	/** Parses a TEXT column holding JSON; malformed content degrades to the fallback. */
	public static function jsonOf(row:Dynamic, field:String, fallback:Dynamic = null):Dynamic {
		var s = str(row, field);
		if (s == null || s == "") return fallback;
		try {
			return Json.parse(s);
		} catch (e:Dynamic) {
			return fallback;
		}
	}

	public static function stringArray(row:Dynamic, field:String):Array<String> {
		var v = jsonOf(row, field, null);
		var out:Array<String> = [];
		if (v == null || !Std.isOfType(v, Array)) return out;
		for (item in (cast v:Array<Dynamic>)) {
			if (item == null) continue;
			out.push(Std.string(item));
		}
		return out;
	}

	public static function dynamicArray(row:Dynamic, field:String):Array<Dynamic> {
		var v = jsonOf(row, field, null);
		if (v == null || !Std.isOfType(v, Array)) return [];
		return cast v;
	}
}
