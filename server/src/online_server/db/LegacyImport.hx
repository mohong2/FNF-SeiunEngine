package online_server.db;

import haxe.Json;
import haxe.io.Path;
import online_server.Crypto;
import online_server.JsonStore;
import online_server.Log;
import sys.FileSystem;
import sys.io.File;

/**
 * One-shot importer from the legacy JSON documents to SQLite.
 *
 * Rules (from the migration decision):
 *  - Runs automatically when every legacy table is still empty and at least one legacy file
 *    exists, so an existing server upgrades on first start with no operator action.
 *  - --import-legacy-json re-runs it from scratch: previously imported rows (tracked by the
 *    meta key legacy.imported) are wiped first. A database that holds data we did not import is
 *    never overwritten -- that case aborts with an error instead.
 *  - Everything happens in one transaction. Any failure rolls back and throws, which aborts
 *    startup; a partial import is impossible and no source file is touched before COMMIT.
 *  - After a successful commit each source file is renamed to <name>.imported-<timestamp>. User
 *    data is never deleted.
 *  - A summary (per-file row counts, source sizes, timestamp) is written to the meta table.
 *
 * Called from Db.open() while the storage mutex is already held: this class must only use the
 * *Locked Db helpers (no Db.lock / Db.tx).
 */
class LegacyImport {
	/** Set by Main from --import-legacy-json (available when Api.init opens the database). */
	public static var force:Bool = false;

	public static var SOURCES:Array<String> = [
		"accounts.json", "leaderboard.json", "admin.json", "clubs.json", "mods.json", "public.json"
	];

	public static var LEGACY_TABLES:Array<String> = [
		"accounts", "sessions", "scores", "comments", "reports", "clubs", "mods", "warns",
		"admin_logs", "front_messages", "day_players"
	];

	static var done:Bool = false;

	/**
	 * Entry point. Returns true when files were imported. Throws on any failure so the caller can
	 * abort startup instead of silently losing data.
	 */
	public static function bootstrap(dataDir:String, forceRun:Bool):Bool {
		if (done) return false;
		done = true;
		if (dataDir == null || dataDir == "") return false;

		var present:Array<String> = [];
		for (name in SOURCES) if (FileSystem.exists(dataDir + "/" + name)) present.push(name);
		if (present.length == 0) return false;

		var importedAt = Db.metaGetLocked("legacy.imported");
		var empty = isEmpty();

		if (!forceRun && !empty) {
			Log.info("import", "legacy JSON found but the database already holds data; skipping", {
				dataDir: dataDir,
				importedAt: importedAt,
				files: present.join(",")
			});
			return false;
		}

		if (forceRun && !empty && importedAt == null) {
			throw "refusing to run --import-legacy-json: " + dataDir
				+ " already contains data that was not produced by a legacy import. Move the database aside first.";
		}

		var started = Date.now().getTime();
		var summary:Dynamic = { startedAt: started, dir: dataDir, files: [] };
		var counts:Dynamic = {};
		var renames:Array<{from:String, to:String}> = [];

		Db.tx(function() {
			if (forceRun && importedAt != null) {
				// Deliberate re-import: drop only rows this importer created before.
				for (table in LEGACY_TABLES) Db.exec("DELETE FROM " + table);
				for (key in ["accounts.seq", "leaderboard.seq", "admin.seq", "clubs.seq"]) Db.metaSetLocked(key, "0");
				Db.metaSetLocked("public.next_weekly_date", "");
				Log.warn("import", "re-import: cleared previously imported rows", { tables: LEGACY_TABLES.length });
			}

			var files:Array<Dynamic> = [];
			for (name in present) {
				var full = dataDir + "/" + name;
				counts = importFile(name, full, counts);
				var size = 0;
				try size = FileSystem.stat(full).size catch (e:Dynamic) {}
				files.push({ name: name, bytes: size });
				renames.push({ from: full, to: dataDir + "/" + name + ".imported-" + started });
			}
			summary.files = files;
			summary.counts = counts;
			summary.finishedAt = Date.now().getTime();
			Db.metaSetLocked("legacy.imported", Std.string(started));
			Db.metaSetLocked("legacy.source", Json.stringify(summary));
			return true;
		});

		// COMMIT succeeded: only now are the sources renamed.
		for (r in renames) {
			try {
				FileSystem.rename(r.from, r.to);
			} catch (e:Dynamic) {
				Log.error("import", "could not rename imported source", { from: r.from, to: r.to, error: Std.string(e) });
				throw "import committed but renaming " + r.from + " failed: " + Std.string(e);
			}
		}

		Log.info("import", "legacy JSON imported", { dir: dataDir, counts: counts, ms: Std.int(Date.now().getTime() - started) });
		return true;
	}

	static function isEmpty():Bool {
		for (table in LEGACY_TABLES) {
			if (Db.scalar("SELECT COUNT(*) FROM " + table, 0) > 0) return false;
		}
		return true;
	}

	static function importFile(name:String, full:String, counts:Dynamic):Dynamic {
		var raw:Dynamic = JsonStore.read(full, null);
		if (raw == null) throw "legacy import: " + full + " is missing or not valid JSON";
		switch (name) {
			case "accounts.json": importAccounts(raw);
			case "leaderboard.json": importLeaderboard(raw);
			case "admin.json": importAdmin(raw);
			case "clubs.json": importClubs(raw);
			case "mods.json": importMods(raw);
			case "public.json": importPublic(raw);
		}
		Reflect.setField(counts, name, rowCounts());
		return counts;
	}

	static function rowCounts():Dynamic {
		var out:Dynamic = {};
		for (name in ["accounts", "sessions", "scores", "comments", "reports", "clubs", "mods", "warns",
			"admin_logs", "front_messages", "day_players"]) {
			Reflect.setField(out, name, Db.scalar("SELECT COUNT(*) FROM " + name, 0));
		}
		return out;
	}

	// ------------------------------------------------------------------
	// Per-file importers
	// ------------------------------------------------------------------

	static function importAccounts(raw:Dynamic):Void {
		var list:Array<Dynamic> = arr(raw, "accounts");
		for (o in list) {
			if (o == null) continue;
			var id = str(o, "id");
			if (id == null || id == "") continue;
			var created = num(o, "createdAt", Date.now().getTime());
			var lastActive = numOrNull(o, "lastActive");
			if (lastActive == null) lastActive = created;
			Db.exec("INSERT OR REPLACE INTO accounts (id, seq, name, email, points, avg_accuracy, games, profile_hue,"
				+ " profile_hue2, country, last_active, bio, role, ng_url, ng_id, created_at, access_json,"
				+ " notifications_json, friends_json, friend_requests_json, ips_json, current_session_id) VALUES ("
				+ Db.quote(id) + ", " + Sqlite.int(seqOfId(id)) + ", " + Db.quote(str(o, "name")) + ", "
				+ Db.quote(str(o, "email")) + ", " + Sqlite.real(num(o, "points", 0)) + ", "
				+ Sqlite.real(num(o, "avgAccuracy", 0)) + ", " + Sqlite.int(intOf(o, "games", 0)) + ", "
				+ Sqlite.real(num(o, "profileHue", 250)) + ", " + Sqlite.real(numOrNull(o, "profileHue2")) + ", "
				+ Db.quote(str(o, "country")) + ", " + Sqlite.real(lastActive) + ", " + Db.quote(str(o, "bio")) + ", "
				+ Db.quote(str(o, "role")) + ", " + Db.quote(str(o, "ngUrl")) + ", " + Db.quote(str(o, "ngId")) + ", "
				+ Sqlite.real(created) + ", " + Db.quote(Sqlite.json(arrayField(o, "access"))) + ", "
				+ Db.quote(Sqlite.json(arrayField(o, "notifications"))) + ", "
				+ Db.quote(Sqlite.json(arrayField(o, "friends"))) + ", "
				+ Db.quote(Sqlite.json(arrayField(o, "friendRequests"))) + ", "
				+ Db.quote(Sqlite.json(arrayField(o, "ips"))) + ", NULL)");

			// Preserve live logins: the legacy plaintext token is hashed here and stored as the
			// account's first session, so nobody has to log in again after the migration.
			var token = str(o, "token");
			if (token != null && token != "") {
				AccountRepo.insertSessionRaw("imp-" + id, id, Crypto.hashToken(token), Crypto.tokenPrefix(token),
					num(o, "tokenIssuedAt", created),
					numOrNull(o, "tokenExpiresAt"),
					{ var t = intOrNull(o, "tokenTtlMinutes"); t == null ? 0 : t; },
					null);
			}
		}
		var legacySeq = intOrNull(raw, "seq");
		if (legacySeq != null) Db.metaSetLocked("accounts.seq", Std.string(legacySeq));
	}

	static function importLeaderboard(raw:Dynamic):Void {
		for (o in arr(raw, "scores")) {
			if (o == null) continue;
			var id = str(o, "id");
			if (id == null || id == "") continue;
			Db.exec("INSERT OR REPLACE INTO scores (id, seq, song_id, song, difficulty, chart_hash, player, player_name,"
				+ " strum, keys, score, accuracy, points, misses, sicks, goods, bads, shits, playback_rate, mod_url,"
				+ " category, replay, submitted, submitted_ts) VALUES ("
				+ Db.quote(id) + ", " + Sqlite.int(seqOfId(id)) + ", " + Db.quote(str(o, "songId")) + ", "
				+ Db.quote(str(o, "song")) + ", " + Db.quote(str(o, "difficulty")) + ", " + Db.quote(str(o, "chartHash")) + ", "
				+ Db.quote(str(o, "player")) + ", " + Db.quote(str(o, "playerName")) + ", "
				+ Sqlite.int(intOf(o, "strum", 0)) + ", " + Sqlite.int(intOf(o, "keys", 0)) + ", "
				+ Sqlite.real(num(o, "score", 0)) + ", " + Sqlite.real(num(o, "accuracy", 0)) + ", "
				+ Sqlite.real(num(o, "points", 0)) + ", " + Sqlite.real(num(o, "misses", 0)) + ", "
				+ Sqlite.real(num(o, "sicks", 0)) + ", " + Sqlite.real(num(o, "goods", 0)) + ", "
				+ Sqlite.real(num(o, "bads", 0)) + ", " + Sqlite.real(num(o, "shits", 0)) + ", "
				+ Sqlite.real(num(o, "playbackRate", 1)) + ", " + Db.quote(str(o, "modURL")) + ", "
				+ Db.quote(str(o, "category")) + ", " + Db.quote(str(o, "replay")) + ", " + Db.quote(str(o, "submitted")) + ", "
				+ Sqlite.real(num(o, "submittedTs", 0)) + ")");
		}
		for (o in arr(raw, "comments")) {
			if (o == null) continue;
			var id = str(o, "id");
			if (id == null || id == "") continue;
			Db.exec("INSERT OR REPLACE INTO comments (id, seq, song_id, player, content, at) VALUES ("
				+ Db.quote(id) + ", " + Sqlite.int(seqOfId(id)) + ", " + Db.quote(str(o, "songId")) + ", "
				+ Db.quote(str(o, "player")) + ", " + Db.quote(str(o, "content")) + ", " + Sqlite.real(num(o, "at", 0)) + ")");
		}
		for (o in arr(raw, "reports")) {
			if (o == null) continue;
			var id = str(o, "id");
			if (id == null || id == "") continue;
			Db.exec("INSERT OR REPLACE INTO reports (id, seq, reporter, content, submitted) VALUES ("
				+ Db.quote(id) + ", " + Sqlite.int(seqOfId(id)) + ", " + Db.quote(str(o, "reporter")) + ", "
				+ Db.quote(str(o, "content")) + ", " + Db.quote(str(o, "submitted")) + ")");
		}
		var legacySeq = intOrNull(raw, "seq");
		if (legacySeq != null) Db.metaSetLocked("leaderboard.seq", Std.string(legacySeq));
	}

	static function importAdmin(raw:Dynamic):Void {
		for (o in arr(raw, "warns")) {
			if (o == null) continue;
			var id = str(o, "id");
			if (id == null || id == "") continue;
			Db.exec("INSERT OR REPLACE INTO warns (id, seq, on_id, by_id, reason, date) VALUES ("
				+ Db.quote(id) + ", " + Sqlite.int(seqOfId(id)) + ", " + Db.quote(str(o, "on")) + ", "
				+ Db.quote(str(o, "by")) + ", " + Db.quote(str(o, "reason")) + ", " + Db.quote(str(o, "date")) + ")");
		}
		// logs[0] is the newest line (addLog unshifted). Insert oldest-first so that ORDER BY
		// seq DESC reproduces the original newest-first array exactly.
		var logs = arr(raw, "logs");
		var i = logs.length - 1;
		while (i >= 0) {
			var line = logs[i];
			if (line != null) Db.exec("INSERT INTO admin_logs (line) VALUES (" + Db.quote(Std.string(line)) + ")");
			i--;
		}
		var legacySeq = intOrNull(raw, "seq");
		if (legacySeq != null) Db.metaSetLocked("admin.seq", Std.string(legacySeq));
	}

	static function importClubs(raw:Dynamic):Void {
		for (o in arr(raw, "clubs")) {
			if (o == null) continue;
			var id = str(o, "id");
			if (id == null || id == "") continue;
			Db.exec("INSERT OR REPLACE INTO clubs (id, seq, name, tag, content, hue, points, created_at, banner, banner_type,"
				+ " members_json, pending_json, leaders_json) VALUES ("
				+ Db.quote(id) + ", " + Sqlite.int(seqOfId(id)) + ", " + Db.quote(str(o, "name")) + ", "
				+ Db.quote(str(o, "tag")) + ", " + Db.quote(str(o, "content")) + ", " + Sqlite.real(numOrNull(o, "hue")) + ", "
				+ Sqlite.real(num(o, "points", 0)) + ", " + Sqlite.real(num(o, "createdAt", 0)) + ", "
				+ Db.quote(str(o, "banner")) + ", " + Db.quote(str(o, "bannerType")) + ", "
				+ Db.quote(Sqlite.json(arrayField(o, "members"))) + ", "
				+ Db.quote(Sqlite.json(arrayField(o, "pending"))) + ", "
				+ Db.quote(Sqlite.json(arrayField(o, "leaders"))) + ")");
		}
		var legacySeq = intOrNull(raw, "seq");
		if (legacySeq != null) Db.metaSetLocked("clubs.seq", Std.string(legacySeq));
	}

	static function importMods(raw:Dynamic):Void {
		for (o in arr(raw, "mods")) {
			if (o == null) continue;
			var id = str(o, "id");
			if (id == null || id == "") continue;
			Db.exec("INSERT OR REPLACE INTO mods (id, seq, title, description, keywords_json, images_json, favorited_json,"
				+ " favorited_count, download_hits, submitted, updated, downloads_json) VALUES ("
				+ Db.quote(id) + ", 0, " + Db.quote(str(o, "title")) + ", " + Db.quote(str(o, "description")) + ", "
				+ Db.quote(Sqlite.json(arrayField(o, "keywords"))) + ", "
				+ Db.quote(Sqlite.json(arrayField(o, "images"))) + ", "
				+ Db.quote(Sqlite.json(arrayField(o, "favorited"))) + ", "
				+ Sqlite.int(intOf(o, "favoritedCount", 0)) + ", " + Sqlite.int(intOf(o, "downloadHits", 0)) + ", "
				+ Sqlite.real(num(o, "submitted", 0)) + ", " + Sqlite.real(numOrNull(o, "updated")) + ", "
				+ Db.quote(Sqlite.json(arrayField(o, "downloads"))) + ")");
		}
	}

	static function importPublic(raw:Dynamic):Void {
		// frontMessages[0] is the newest entry; see importAdmin for the ordering argument.
		var fronts = arr(raw, "frontMessages");
		var i = fronts.length - 1;
		while (i >= 0) {
			var o = fronts[i];
			if (o != null) {
				Db.exec("INSERT INTO front_messages (player, message) VALUES ("
					+ Db.quote(str(o, "player")) + ", " + Db.quote(str(o, "message")) + ")");
			}
			i--;
		}
		// dayPlayers rows are [count, timestamp] pushed oldest-first.
		for (row in arr(raw, "dayPlayers")) {
			if (row == null || !Std.isOfType(row, Array)) continue;
			var pair:Array<Dynamic> = cast row;
			var count = pair.length > 0 ? pair[0] : 0;
			var ts = pair.length > 1 ? pair[1] : 0;
			Db.exec("INSERT INTO day_players (count, ts) VALUES ("
				+ Sqlite.int(toInt(count, 0)) + ", " + Sqlite.real(toNum(ts, 0)) + ")");
		}
		var weekly = numOrNull(raw, "nextWeeklyDate");
		Db.exec("INSERT OR REPLACE INTO public_state (id, next_weekly_date) VALUES (1, "
			+ Sqlite.real(weekly == null ? haxe.Timer.stamp() * 1000 : weekly) + ")");
	}

	// ------------------------------------------------------------------
	// Legacy Dynamic accessors (missing fields are normal in old documents)
	// ------------------------------------------------------------------

	static function arr(o:Dynamic, field:String):Array<Dynamic> {
		if (o == null) return [];
		var v:Dynamic = Reflect.field(o, field);
		if (v == null || !Std.isOfType(v, Array)) return [];
		return cast v;
	}

	static function arrayField(o:Dynamic, field:String):Dynamic {
		var v = arr(o, field);
		return v.length == 0 ? [] : v;
	}

	static function str(o:Dynamic, field:String):String {
		if (o == null) return null;
		var v:Dynamic = Reflect.field(o, field);
		return v == null ? null : Std.string(v);
	}

	static function num(o:Dynamic, field:String, fallback:Float):Float {
		if (o == null) return fallback;
		return toNum(Reflect.field(o, field), fallback);
	}

	static function toNum(v:Dynamic, fallback:Float):Float {
		if (v == null) return fallback;
		if (Std.isOfType(v, Float)) return cast(v, Float);
		if (Std.isOfType(v, Int)) return cast(v, Int) * 1.0;
		var parsed = Std.parseFloat(Std.string(v));
		return (parsed != parsed) ? fallback : parsed;
	}

	static function numOrNull(o:Dynamic, field:String):Null<Float> {
		if (o == null) return null;
		var v:Dynamic = Reflect.field(o, field);
		return v == null ? null : toNum(v, 0);
	}

	static function intOf(o:Dynamic, field:String, fallback:Int):Int {
		if (o == null) return fallback;
		return toInt(Reflect.field(o, field), fallback);
	}

	static function intOrNull(o:Dynamic, field:String):Null<Int> {
		if (o == null) return null;
		var v:Dynamic = Reflect.field(o, field);
		if (v == null) return null;
		return toInt(v, 0);
	}

	static function toInt(v:Dynamic, fallback:Int):Int {
		if (v == null) return fallback;
		if (Std.isOfType(v, Int)) return cast(v, Int);
		if (Std.isOfType(v, Float)) return Std.int((cast v:Float));
		var parsed = Std.parseInt(Std.string(v));
		if (parsed != null) return parsed;
		var f = Std.parseFloat(Std.string(v));
		return (f != f) ? fallback : Std.int(f);
	}

	/** Legacy ids encode their counter (u12 / s4 / c1 / w2 / r3); unknown shapes become 0. */
	static function seqOfId(id:String):Int {
		if (id == null || id.length < 2) return 0;
		var parsed = Std.parseInt(id.substr(1));
		return parsed == null ? 0 : parsed;
	}
}