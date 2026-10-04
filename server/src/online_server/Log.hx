package online_server;

import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import sys.thread.Mutex;
import sys.thread.Thread;

/**
 * Structured server log: one JSON object per line (JSON Lines / .jsonl), appended to
 * <log-dir>/server-YYYYMMDD.jsonl. Rotating by date needs no configuration and keeps merge
 * conflicts away when two processes share a log directory.
 *
 * Line shape: {"ts":"2026-01-02T03:04:05.678Z","level":"info","component":"db","msg":"...", ...}
 *
 * This class is additive: it is used by the new SQLite / session / import code paths. Existing
 * trace() calls elsewhere were intentionally left alone, so a log reader sees both.
 */
class Log {
	/** Lowest level that is written; one of debug < info < warn < error. */
	public static var minLevel:String = "info";

	static var dir:String = "server/logs";
	static var path:String = null;
	static var dateStamp:String = null;
	static var mutex:Mutex = new Mutex();
	static var seq:Int = 0;

	public static function init(logDir:String, ?level:String):Void {
		mutex.acquire();
		try {
			if (logDir != null && logDir != "") dir = logDir;
			if (level != null && level != "") minLevel = level;
			if (!FileSystem.exists(dir)) FileSystem.createDirectory(dir);
			path = null;
			dateStamp = null;
		} catch (e:Dynamic) {
			dir = "server/logs";
		}
		mutex.release();
	}

	public static function directory():String return dir;

	/** Path of the file currently being appended to (resolved lazily, null when init failed). */
	public static function currentPath():String {
		mutex.acquire();
		var p = resolveU();
		mutex.release();
		return p;
	}

	public static function debug(component:String, msg:String, ?fields:Dynamic):Void write("debug", component, msg, fields);
	public static function info(component:String, msg:String, ?fields:Dynamic):Void write("info", component, msg, fields);
	public static function warn(component:String, msg:String, ?fields:Dynamic):Void write("warn", component, msg, fields);
	public static function error(component:String, msg:String, ?fields:Dynamic):Void write("error", component, msg, fields);

	public static function levelRank(level:String):Int {
		return switch (level) {
			case "debug": 0;
			case "info": 1;
			case "warn": 2;
			case "error": 3;
			case _: 1;
		}
	}

	/**
	 * Appends one line. Never throws: a logging failure must not take a request down. The line is
	 * built as JSON so field values may contain spaces, quotes or non-ASCII text.
	 */
	public static function write(level:String, component:String, msg:String, ?fields:Dynamic):Void {
		if (levelRank(level) < levelRank(minLevel)) return;
		mutex.acquire();
		try {
			var p = resolveU();
			if (p == null) {
				mutex.release();
				return;
			}
			seq++;
			var record:Dynamic = {
				ts: isoMs(Date.now().getTime()),
				level: level,
				component: component == null ? "server" : component,
				msg: msg == null ? "" : msg
			};
			if (fields != null) {
				switch (Type.typeof(fields)) {
					case TObject:
						for (f in Reflect.fields(fields)) Reflect.setField(record, f, Reflect.field(fields, f));
					case _:
						Reflect.setField(record, "value", fields);
				}
			}
			Reflect.setField(record, "seq", seq);
			// Only the thread's class name: Reflect.setField with the Thread object itself would be
			// serialised into a large, useless dump by Json.stringify.
			try {
				var threadName = Type.getClassName(Type.getClass(Thread.current()));
				if (threadName != null) Reflect.setField(record, "thread", threadName);
			} catch (e:Dynamic) {}
			var line = Json.stringify(record);
			if (line.indexOf("\n") >= 0) line = StringTools.replace(line, "\n", "\\n");
			var f = File.append(p, false);
			f.writeString(line + "\n");
			f.close();
		} catch (e:Dynamic) {
			// A full disk or a locked file must not break the request that is being logged.
		}
		mutex.release();
	}

	static function resolveU():String {
		var stamp = dateStampOf();
		if (path != null && stamp == dateStamp) return path;
		try {
			if (!FileSystem.exists(dir)) FileSystem.createDirectory(dir);
			dateStamp = stamp;
			path = dir + "/server-" + stamp + ".jsonl";
			return path;
		} catch (e:Dynamic) {
			path = null;
			return null;
		}
	}

	/** Local-time YYYYMMDD; the process owns its own timezone, so no UTC conversion is needed. */
	static function dateStampOf():String {
		var d = Date.now();
		return "" + d.getFullYear() + pad2(d.getMonth() + 1) + pad2(d.getDate());
	}

	public static function isoMs(ms:Float):String {
		var d = Date.fromTime(ms);
		return d.getUTCFullYear() + '-' + pad2(d.getUTCMonth() + 1) + '-' + pad2(d.getUTCDate())
			+ 'T' + pad2(d.getUTCHours()) + ':' + pad2(d.getUTCMinutes()) + ':' + pad2(d.getUTCSeconds())
			+ '.' + pad3(Std.int(ms - Math.ffloor(ms / 1000) * 1000)) + 'Z';
	}

	static function pad2(n:Int):String return (n < 10 ? '0' : '') + n;
	static function pad3(n:Int):String return (n < 10 ? '00' : (n < 100 ? '0' : '')) + n;
}
