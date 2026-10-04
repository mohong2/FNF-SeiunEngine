package online_server.db;

import online_server.AdminStore.WarnEntry;
import online_server.JsonStore;

/**
 * SQLite repository for the admin-side data: warnings and the moderator action log.
 *
 * One repository call owns one transaction, so the legacy "one global Mutex around the whole
 * read-modify-write" atomicity is preserved (and finally durable): adding a warning consumes the
 * counter and inserts the row in the same BEGIN IMMEDIATE, and the log insert plus its cap trim
 * cannot interleave with another writer.
 *
 * Ids keep the legacy shape (w1, w2, ...) and come from the meta counter "admin.seq".
 */
class AdminRepo {
	static inline var WARN_SEQ:String = "admin.seq";

	/** Appends a warning and returns the freshly built entry (never a DB row object). */
	public static function insertWarn(onId:String, byId:String, reason:String):WarnEntry {
		return Db.lockTx(function() {
			var seq = Db.nextSeqLocked(WARN_SEQ);
			var entry:WarnEntry = {
				id: "w" + seq,
				on: onId,
				by: byId,
				reason: reason,
				date: JsonStore.isoNow()
			};
			Db.exec("INSERT INTO warns (id, seq, on_id, by_id, reason, date) VALUES ("
				+ Db.quote(entry.id) + ", " + seq + ", "
				+ Db.quote(entry.on) + ", " + Db.quote(entry.by) + ", "
				+ Db.quote(entry.reason) + ", " + Db.quote(entry.date) + ")");
			return entry;
		});
	}

	/** True when a row was removed; false for a missing/empty id or no such warning. */
	public static function deleteWarn(id:String):Bool {
		if (id == null || id == "") return false;
		return Db.lockTx(function() {
			if (Db.queryOne("SELECT id FROM warns WHERE id = " + Db.quote(id)) == null) return false;
			Db.exec("DELETE FROM warns WHERE id = " + Db.quote(id));
			return true;
		});
	}

	/** All warnings in insertion order (the legacy array order). */
	public static function warns():Array<WarnEntry> {
		return Db.lock(function() {
			var rows = Db.query("SELECT id, on_id, by_id, reason, date FROM warns ORDER BY seq ASC, id ASC");
			var out:Array<WarnEntry> = [];
			for (r in rows) {
				out.push({
					id: Sqlite.str(r, "id", ""),
					on: Sqlite.str(r, "on_id"),
					by: Sqlite.str(r, "by_id"),
					reason: Sqlite.str(r, "reason"),
					date: Sqlite.str(r, "date")
				});
			}
			return out;
		});
	}

	/** Inserts one log line and drops everything past the cap, in one transaction. */
	public static function insertLog(line:String, cap:Int):Void {
		Db.lockTx(function() {
			Db.exec("INSERT INTO admin_logs (line) VALUES (" + Db.quote(line) + ")");
			Db.exec("DELETE FROM admin_logs WHERE seq NOT IN (SELECT seq FROM admin_logs ORDER BY seq DESC LIMIT " + cap + ")");
			return true;
		});
	}

	/** Newest first, at most cap lines. */
	public static function logs(cap:Int):Array<String> {
		return Db.lock(function() {
			var rows = Db.query("SELECT line FROM admin_logs ORDER BY seq DESC LIMIT " + cap);
			var out:Array<String> = [];
			for (r in rows) out.push(Sqlite.str(r, "line", ""));
			return out;
		});
	}
}
