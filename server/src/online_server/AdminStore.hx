package online_server;

import sys.FileSystem;

/**
 * Admin-side JSON data: warnings and the mod action log. Reports live in
 * LeaderboardStore.reports. Shares JsonStore's global Mutex: never call another store's
 * public method inside a lock callback (self-deadlock); Api does cross-store work outside.
 */
typedef WarnEntry = {
	var id:String;
	/** Warned account id. */
	var on:String;
	/** Account id of the moderator who issued the warning. */
	var by:String;
	var reason:String;
	/** ISO-8601 timestamp. */
	var date:String;
}

class AdminStore {
	/** Oldest entries are dropped past this cap. */
	public static inline var LOG_CAP:Int = 1000;

	static var path:String = null;
	/** { seq:Int, warns:Array<WarnEntry>, logs:Array<String> } */
	static var db:Dynamic = null;

	public static function init(file:String):Void {
		path = file;
		JsonStore.lock(function() {
			var loaded = JsonStore.read(path, null);
			if (loaded == null || loaded.warns == null) {
				loaded = { seq: 0, warns: [], logs: [] };
			}
			if (loaded.logs == null) loaded.logs = [];
			db = loaded;
			if (!FileSystem.exists(path)) JsonStore.write(path, db);
			return true;
		});
	}

	public static function storagePath():String return path;

	static inline function warnsU():Array<WarnEntry> return cast db.warns;
	static inline function logsU():Array<String> return cast db.logs;

	/** Writes a warning; Api does the notification / WS push outside the lock. */
	public static function addWarn(onId:String, byId:String, reason:String):WarnEntry {
		return JsonStore.lock(function() {
			db.seq = db.seq + 1;
			var entry:WarnEntry = {
				id: "w" + db.seq,
				on: onId,
				by: byId,
				reason: reason,
				date: JsonStore.isoNow()
			};
			warnsU().push(entry);
			JsonStore.write(path, db);
			return entry;
		});
	}

	/** Removes a warning. Returns false when there is no such warning. */
	public static function removeWarn(id:String):Bool {
		return JsonStore.lock(function() {
			if (id == null || id == "") return false;
			for (w in warnsU()) {
				if (w.id == id) {
					warnsU().remove(w);
					JsonStore.write(path, db);
					return true;
				}
			}
			return false;
		});
	}

	/** Raw warning list; Api resolves on / by to names and skips banned accounts. */
	public static function warns():Array<WarnEntry> {
		return JsonStore.lock(function() return warnsU().copy());
	}

	/**
	 * Log line format is [ISO]: who: content, newest first, capped at 1000. who is resolved by
	 * the caller (server-written logs pass SERVER); this class never looks up accounts, to avoid
	 * crossing stores inside the lock.
	 */
	public static function addLog(who:String, content:String):Void {
		JsonStore.lock(function() {
			var role = (who == null || who == "") ? "SERVER" : who;
			logsU().unshift("[" + JsonStore.isoNow() + "]: " + role + ": " + content);
			while (logsU().length > LOG_CAP) logsU().pop();
			JsonStore.write(path, db);
			return true;
		});
	}

	/** Returns the whole log array (newest first). */
	public static function logs():Array<String> {
		return JsonStore.lock(function() return logsU().copy());
	}
}
