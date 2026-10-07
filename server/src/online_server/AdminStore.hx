package online_server;

import online_server.db.AdminRepo;

/**
 * Admin-side data: warnings and the moderator action log, stored in SQLite (db/AdminRepo.hx).
 * Reports live in LeaderboardStore.reports.
 *
 * The class is now a thin facade: it keeps the public API, the id format (w1, w2, ...), the log
 * line format and the 1000-line cap exactly as the JSON implementation had them, while the
 * repository owns the statements and the transaction. Nothing crosses a lock as a live record.
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

	/**
	 * Records the legacy storage path for storagePath() / diagnostics. The tables themselves are
	 * created by Db.open() -> Migrations, so there is no file to load or create here anymore.
	 */
	public static function init(file:String):Void {
		path = file;
	}

	public static function storagePath():String return path;

	/** Writes a warning; Api does the notification / WS push outside the lock. */
	public static function addWarn(onId:String, byId:String, reason:String):WarnEntry {
		return AdminRepo.insertWarn(onId, byId, ServerConfig.repairUtf8(reason));
	}

	/** Removes a warning. Returns false when there is no such warning. */
	public static function removeWarn(id:String):Bool {
		return AdminRepo.deleteWarn(id);
	}

	/** Raw warning list; Api resolves on / by to names and skips banned accounts. */
	public static function warns():Array<WarnEntry> {
		return AdminRepo.warns();
	}

	/**
	 * Log line format is [ISO]: who: content, newest first, capped at 1000. who is resolved by
	 * the caller (server-written logs pass SERVER); this class never looks up accounts.
	 */
	public static function addLog(who:String, content:String):Void {
		var role = (who == null || who == "") ? "SERVER" : ServerConfig.repairUtf8(who);
		AdminRepo.insertLog("[" + JsonStore.isoNow() + "]: " + role + ": " + ServerConfig.repairUtf8(content), LOG_CAP);
	}

	/** Returns the whole log array (newest first). */
	public static function logs():Array<String> {
		return AdminRepo.logs(LOG_CAP);
	}
}
