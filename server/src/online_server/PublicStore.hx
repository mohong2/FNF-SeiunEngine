package online_server;

import sys.FileSystem;

/** A front-page message; player holds a name here (not an account id). */
typedef FrontMessage = {
	var player:String;
	var message:String;
}

/**
 * Shared public data (local JSON): FRONT_MESSAGES, NEXT_WEEKLY_DATE (defaults to the current
 * time, not +7 days) and DAY_PLAYERS (one row per 10 minutes, max 300, lazily recorded).
 * Shares JsonStore's global Mutex.
 */
class PublicStore {
	static inline var DAY_INTERVAL_MS:Float = 10 * 60 * 1000;
	static inline var DAY_MAX:Int = 300;
	static inline var FRONT_MAX:Int = 5;

	static var path:String = null;
	/** { frontMessages:Array<FrontMessage>, nextWeeklyDate:Float, dayPlayers:Array<Array<Dynamic>> } */
	static var db:Dynamic = null;

	public static function init(file:String):Void {
		path = file;
		JsonStore.lock(function() {
			var loaded:Dynamic = JsonStore.read(path, null);
			if (loaded == null) loaded = {};
			if (loaded.frontMessages == null) loaded.frontMessages = [];
			if (loaded.nextWeeklyDate == null) loaded.nextWeeklyDate = nowMs();
			if (loaded.dayPlayers == null) loaded.dayPlayers = [];
			db = loaded;
			if (!FileSystem.exists(path)) JsonStore.write(path, db);
			return true;
		});
	}

	public static function storagePath():String return path;

	static inline function frontU():Array<FrontMessage> return cast db.frontMessages;
	static inline function dayU():Array<Array<Dynamic>> return cast db.dayPlayers;

	// ---- FRONT_MESSAGES ----

	/**
	 * Inserts at the front and drops the oldest past 5 entries. Returns false when this player
	 * just posted (Api decides the 418 status).
	 */
	public static function addFrontMessage(player:String, message:String):Bool {
		return JsonStore.lock(function() {
			var list = frontU();
			if (list.length > 0 && list[0].player == player) return false;
			list.unshift({ player: player, message: message });
			while (list.length > FRONT_MAX) list.pop();
			JsonStore.write(path, db);
			return true;
		});
	}

	/**
	 * /api/front only looks at the newest entry, and it is returned as the raw message: the
	 * client OnlineState.hx:315 shows this field as the body, and that user-visible text is
	 * unchanged.
	 */
	public static function latestFrontMessage():FrontMessage {
		return JsonStore.lock(function() {
			var list = frontU();
			return list.length == 0 ? null : list[0];
		});
	}

	/** Full table for /api/sezdetal, newest first. */
	public static function frontMessages():Array<FrontMessage> {
		return JsonStore.lock(function() return frontU().copy());
	}

	// ---- NEXT_WEEKLY_DATE ----

	public static function nextWeeklyDate():Float {
		return JsonStore.lock(function() return db.nextWeeklyDate);
	}

	// ---- DAY_PLAYERS ----

	/**
	 * Records lazily on request instead of with a background timer: appends only when the last
	 * row is >= 10 minutes old, dropping the oldest past 300. Returns the current full table.
	 */
	public static function recordDayPlayers(count:Int):Array<Array<Dynamic>> {
		return JsonStore.lock(function() {
			var list = dayU();
			var now = nowMs();
			var last:Float = list.length == 0 ? -1 : numAt(list[list.length - 1], 1);
			if (last < 0 || now - last >= DAY_INTERVAL_MS) {
				var row:Array<Dynamic> = [count, now];
				list.push(row);
				while (list.length > DAY_MAX) list.shift();
				JsonStore.write(path, db);
			}
			return list.copy();
		});
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
