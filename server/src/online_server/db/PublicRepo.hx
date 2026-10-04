package online_server.db;

import online_server.PublicStore.FrontMessage;

/**
 * SQLite repository for the shared public data: front-page messages, the weekly reset timestamp
 * and the per-10-minute player counts.
 *
 * Every mutation is one transaction, so the legacy single-Mutex behaviour is preserved: the
 * "same player again -> false" check and the insert cannot interleave, and the cap trim runs in
 * the same commit as the insert. The caps themselves stay in PublicStore and are passed in.
 */
class PublicRepo {
	/** Creates the single public_state row on first init (nextWeeklyDate defaults to now). */
	public static function ensureState(defaultNow:Float):Void {
		Db.lockTx(function() {
			Db.exec("INSERT OR IGNORE INTO public_state (id, next_weekly_date) VALUES (1, " + Sqlite.real(defaultNow) + ")");
			return true;
		});
	}

	public static function nextWeeklyDate(defaultNow:Float):Float {
		return Db.lock(function() {
			var row = Db.queryOne("SELECT next_weekly_date FROM public_state WHERE id = 1");
			if (row == null) return defaultNow;
			return Sqlite.num(row, "next_weekly_date", defaultNow);
		});
	}

	/**
	 * False when the newest entry is already from this player (Api turns that into the 418).
	 * hasRow distinguishes "no entries yet" from a stored NULL player, which the legacy
	 * list.length > 0 && list[0].player == player check also did.
	 */
	public static function addFront(player:String, message:String, frontMax:Int):Bool {
		return Db.lockTx(function() {
			var row = Db.queryOne("SELECT player FROM front_messages ORDER BY seq DESC LIMIT 1");
			if (row != null && Sqlite.str(row, "player") == player) return false;
			Db.exec("INSERT INTO front_messages (player, message) VALUES ("
				+ Db.quote(player) + ", " + Db.quote(message) + ")");
			Db.exec("DELETE FROM front_messages WHERE seq NOT IN (SELECT seq FROM front_messages ORDER BY seq DESC LIMIT " + frontMax + ")");
			return true;
		});
	}

	/** Newest first, at most frontMax entries. */
	public static function frontMessages(frontMax:Int):Array<FrontMessage> {
		return Db.lock(function() {
			var rows = Db.query("SELECT player, message FROM front_messages ORDER BY seq DESC LIMIT " + frontMax);
			var out:Array<FrontMessage> = [];
			for (r in rows) out.push({ player: Sqlite.str(r, "player"), message: Sqlite.str(r, "message") });
			return out;
		});
	}

	/**
	 * Appends a row only when the newest one is at least intervalMs old, trims to dayMax and
	 * returns the full table oldest-first (the legacy array order).
	 */
	public static function recordDayPlayers(count:Int, now:Float, intervalMs:Float, dayMax:Int):Array<Array<Dynamic>> {
		return Db.lockTx(function() {
			var last = -1.0;
			var row = Db.queryOne("SELECT ts FROM day_players ORDER BY seq DESC LIMIT 1");
			if (row != null) last = Sqlite.num(row, "ts", -1);
			if (last < 0 || now - last >= intervalMs) {
				Db.exec("INSERT INTO day_players (count, ts) VALUES (" + Sqlite.int(count) + ", " + Sqlite.real(now) + ")");
				Db.exec("DELETE FROM day_players WHERE seq NOT IN (SELECT seq FROM day_players ORDER BY seq DESC LIMIT " + dayMax + ")");
			}
			var rows = Db.query("SELECT count, ts FROM day_players ORDER BY seq ASC");
			var out:Array<Array<Dynamic>> = [];
			for (r in rows) out.push([Sqlite.intOf(r, "count", 0), Sqlite.num(r, "ts", 0)]);
			return out;
		});
	}
}
