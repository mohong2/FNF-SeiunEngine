package online_server;

import online_server.db.PublicRepo;

/** A front-page message; player holds a name here (not an account id). */
typedef FrontMessage = {
	var player:String;
	var message:String;
}

/**
 * Shared public data stored in SQLite (db/PublicRepo.hx): FRONT_MESSAGES, NEXT_WEEKLY_DATE
 * (defaults to the current time, not +7 days) and DAY_PLAYERS (one row per 10 minutes, max 300,
 * lazily recorded). The caps and the timestamp helper are unchanged; only the storage moved.
 */
class PublicStore {
	static inline var DAY_INTERVAL_MS:Float = 10 * 60 * 1000;
	static inline var DAY_MAX:Int = 300;
	static inline var FRONT_MAX:Int = 5;

	static var path:String = null;

	/** Records the legacy storage path and makes sure the single public_state row exists. */
	public static function init(file:String):Void {
		path = file;
		PublicRepo.ensureState(nowMs());
	}

	public static function storagePath():String return path;

	// ---- FRONT_MESSAGES ----

	/**
	 * Inserts at the front and drops the oldest past 5 entries. Returns false when this player
	 * just posted (Api decides the 418 status).
	 */
	public static function addFrontMessage(player:String, message:String):Bool {
		return PublicRepo.addFront(ServerConfig.repairUtf8(player), ServerConfig.repairUtf8(message), FRONT_MAX);
	}

	/**
	 * /api/front only looks at the newest entry, and it is returned as the raw message: the
	 * client OnlineState.hx:315 shows this field as the body, and that user-visible text is
	 * unchanged.
	 */
	public static function latestFrontMessage():FrontMessage {
		var list = PublicRepo.frontMessages(1);
		return list.length == 0 ? null : list[0];
	}

	/** Full table for /api/sezdetal, newest first. */
	public static function frontMessages():Array<FrontMessage> {
		return PublicRepo.frontMessages(FRONT_MAX);
	}

	// ---- NEXT_WEEKLY_DATE ----

	public static function nextWeeklyDate():Float {
		return PublicRepo.nextWeeklyDate(nowMs());
	}

	// ---- DAY_PLAYERS ----

	/**
	 * Records lazily on request instead of with a background timer: appends only when the last
	 * row is >= 10 minutes old, dropping the oldest past 300. Returns the current full table.
	 */
	public static function recordDayPlayers(count:Int):Array<Array<Dynamic>> {
		return PublicRepo.recordDayPlayers(count, nowMs(), DAY_INTERVAL_MS, DAY_MAX);
	}

	static function numAt(row:Array<Dynamic>, index:Int):Float {
		if (row == null || index >= row.length) return -1;
		var parsed = Std.parseFloat(Std.string(row[index]));
		return Math.isNaN(parsed) ? -1 : parsed;
	}

	/**
	 * Millisecond timestamp: neko's Date.now() is only second-precision, so Timer.stamp is used.
	 * Math.ffloor (Float) must be used instead of Math.floor (32-bit Int): a 13-digit
	 * millisecond timestamp overflows to -2147483648 through Math.floor.
	 */
	static inline function nowMs():Float {
		return Math.ffloor(haxe.Timer.stamp() * 1000);
	}
}
