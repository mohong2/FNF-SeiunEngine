package online_server;

import haxe.Json;
import online_server.db.Db;
import online_server.db.LeaderboardRepo;
// Account is a secondary type of the online_server.AccountStore module.
import online_server.AccountStore.Account;

using StringTools;

/** One leaderboard score (the fields returned to the client). */
typedef ScoreEntry = {
	var id:String;
	var songId:String;
	var song:String;
	var difficulty:String;
	var chartHash:String;
	var player:String; // account id
	var playerName:String;
	var strum:Int;
	var keys:Int;
	var score:Float;
	var accuracy:Float;
	var points:Float;
	var misses:Float;
	var sicks:Float;
	var goods:Float;
	var bads:Float;
	var shits:Float;
	var playbackRate:Float;
	var modURL:String;
	var category:String;
	var replay:String;
	var submitted:String;
	/** submitted as a seconds timestamp, cached for sorting / 'week' filtering. */
	var submittedTs:Float;
}

typedef CommentEntry = {
	var id:String;
	var songId:String;
	var player:String;
	var content:String;
	var at:Float;
}

typedef ReportEntry = {
	var id:String;
	var reporter:String;
	var content:String;
	var submitted:String;
}

typedef SubmitResult = {
	var ok:Bool;
	var ?error:String;
	var ?entry:ScoreEntry;
}

/** Result of /api/score/delete, including the recomputed player stats for Api to write back. */
typedef RemoveResult = {
	var ok:Bool;
	var ?error:String;
	var ?playerId:String;
	var points:Float;
	var accuracy:Float;
	var games:Int;
}

/** Aggregate stats over all of a player's scores. */
typedef PlayerStats = {
	var points:Float;
	var accuracy:Float;
	var games:Int;
}

/**
 * Scores / replays / song comments / reports, stored in SQLite through LeaderboardRepo.
 * Submission validation: ReplayData version 4, non-empty inputs, and points / score caps.
 * Pagination is a fixed PAGE_ROWS and 'week' is approximated as the last 7 days.
 *
 * This class is the validation / response-assembly facade: parameter checks, the key-mode and
 * category filters, the legacy comparators and the return shapes live here, while every statement
 * and row projection lives in LeaderboardRepo. All database work runs under Db's single lock, so
 * cross-store calls (AccountStore) still happen outside it in Api, exactly as before.
 *
 * storagePath() still reports the legacy JSON path; db/LegacyImport reads that file once, and the
 * database itself is opened through Db.openFor() from init().
 */
class LeaderboardStore {
	/**
	 * Leaderboard page size. The client's Scoreboard row count is hard-coded to 15
	 * (TopPlayerSubstate.hx:9), so returning more (20 was tried) makes Scoreboard.setRow(i)
	 * index rows[15] out of bounds, a null dereference crash on cpp.
	 *
	 * Named PAGE_ROWS, not PAGE_SIZE: the Android NDK's <sys/user.h> defines PAGE_SIZE as a
	 * C macro, and hxcpp emits statics under their Haxe name, so a Haxe `static var PAGE_SIZE`
	 * becomes `static int PAGE_SIZE;` -> `static int 4096;` and the module fails to compile on
	 * Android (the in-client LAN host links server/src into the APK). Same reason
	 * PLAYER_PAGE_SIZE/SEARCH_PAGE_SIZE are safe: those are not macros.
	 */
	public static inline var PAGE_ROWS:Int = 15;
	static inline var WEEK_SECONDS:Float = 7 * 24 * 60 * 60;

	static var path:String = null;

	/**
	 * Records the legacy data path and opens the process-wide SQLite database that replaced the
	 * JSON file; nothing is read from or written to the JSON path here (db/LegacyImport owns the
	 * one-shot import). Idempotent, matching the old "reload the store" behavior. The isOpen()
	 * guard only avoids Db.open()'s "called twice" warning when an earlier Store.init already
	 * opened the shared file.
	 */
	public static function init(file:String):Void {
		path = file;
		if (!Db.isOpen()) Db.openFor(file);
	}

	public static function storagePath():String return path;

	// ---- parsing helpers (replay is arbitrary client JSON) ----

	static function numOf(o:Dynamic, field:String, fallback:Float = 0.0):Float {
		try {
			var v = Reflect.field(o, field);
			if (v == null) return fallback;
			if (Std.isOfType(v, Float)) return cast v;
			var parsed = Std.parseFloat(Std.string(v));
			return Math.isNaN(parsed) ? fallback : parsed;
		} catch (e:Dynamic) return fallback;
	}

	static function boolOf(o:Dynamic, field:String, fallback:Bool = false):Bool {
		try {
			var v = Reflect.field(o, field);
			if (v == null) return fallback;
			if (Std.isOfType(v, Bool)) return cast v;
			return Std.string(v) == "true";
		} catch (e:Dynamic) return fallback;
	}

	static function strOf(o:Dynamic, field:String, fallback:String = ""):String {
		try {
			var v = Reflect.field(o, field);
			return v == null ? fallback : Std.string(v);
		} catch (e:Dynamic) return fallback;
	}

	public static function slug(s:String):String {
		if (s == null) return "";
		return StringTools.trim(s.toLowerCase()).replace(" ", "-");
	}

	// ---- submission ----

	/** Validates and stores a score; on failure result.error is the client-facing message. */
	public static function submit(a:Account, replay:Dynamic):SubmitResult {
		if (replay == null)
			return { ok: false, error: "Empty Replay Data!", entry: null };

		var version = numOf(replay, "version", 0);
		if (version != 4)
			return { ok: false, error: "Replay version mismatch error, can't submit!\nPlease update!", entry: null };

		var inputs:Dynamic = try Reflect.field(replay, "inputs") catch (e:Dynamic) null;
		var inputCount:Int = (inputs != null && Std.isOfType(inputs, Array)) ? (cast inputs : Array<Dynamic>).length : -1;

		var sicks = numOf(replay, "sicks");
		var goods = numOf(replay, "goods");
		var bads = numOf(replay, "bads");
		var shits = numOf(replay, "shits");
		var noteEvents = sicks + goods + bads + shits;
		if (noteEvents <= 0 || inputCount == 0)
			return { ok: false, error: "Empty Replay", entry: null };

		var points = numOf(replay, "points");
		var score = numOf(replay, "score");
		if (points < 0 || points > 10000 || score > 100000000)
			return { ok: false, error: "Illegal Score Value in the Replay Data", entry: null };

		var keys = Std.int(numOf(replay, "keys", 4));
		if (keys <= 0) keys = 4;
		var song = strOf(replay, "song");
		var difficulty = strOf(replay, "difficulty");
		var chartHash = strOf(replay, "chart_hash");
		var songId = slug(song) + "-" + slug(difficulty) + "-" + slug(chartHash);
		var strum = boolOf(replay, "opponent_mode", false) ? 1 : 2;

		return Db.lockTx(function() {
			// One counter is shared by scores / comments / reports, so ids stay s4 / c1 / r3.
			var seq = LeaderboardRepo.nextSeq();
			var entry:ScoreEntry = {
				id: "s" + seq,
				songId: songId,
				song: song,
				difficulty: difficulty,
				chartHash: chartHash,
				player: a.id,
				playerName: a.name,
				strum: strum,
				keys: keys,
				score: score,
				accuracy: numOf(replay, "accuracy"),
				points: points,
				misses: numOf(replay, "misses"),
				sicks: sicks,
				goods: goods,
				bads: bads,
				shits: shits,
				playbackRate: numOf(replay, "playback_rate", 1),
				modURL: strOf(replay, "mod_url"),
				category: strOf(replay, "category"),
				replay: Json.stringify(replay),
				submitted: JsonStore.isoNow(),
				submittedTs: Date.now().getTime() / 1000
			};
			LeaderboardRepo.insertScore(entry);
			return { ok: true, error: null, entry: entry };
		});
	}

	public static function count():Int {
		return Db.lock(function() return LeaderboardRepo.countScores());
	}

	public static function getScore(id:String):ScoreEntry {
		return Db.lock(function() return LeaderboardRepo.scoreById(id));
	}

	// ---- leaderboard ----

	static function matchesKeys(entry:ScoreEntry, keys:Int):Bool {
		// 4 (or no value) means the default key mode.
		return keys <= 0 || keys == 4 ? (entry.keys <= 4) : (entry.keys == keys);
	}

	static function withinCategory(entry:ScoreEntry, category:String):Bool {
		if (category == null || category == "") return true;
		if (category == "week") return (Date.now().getTime() / 1000 - entry.submittedTs) < WEEK_SECONDS;
		return entry.category == category;
	}

	public static function topSongs(songId:String, strum:Int, page:Int, keys:Int, category:String, sort:String):Array<ScoreEntry> {
		return Db.lock(function() {
			var out:Array<ScoreEntry> = [];
			for (s in LeaderboardRepo.scoresBySongId(songId)) {
				if (strum > 0 && s.strum != strum) continue;
				if (!matchesKeys(s, keys)) continue;
				if (!withinCategory(s, category)) continue;
				out.push(s);
			}
			sortEntries(out, sort);
			var start = (page <= 0 ? 0 : page) * PAGE_ROWS;
			if (start >= out.length) return [];
			return out.slice(start, start + PAGE_ROWS);
		});
	}

	static function sortEntries(list:Array<ScoreEntry>, sort:String, defaultSortBy:String = "score"):Void {
		var sortBy = defaultSortBy;
		var direction = "desc";
		if (sort != null && sort != "") {
			var parts = sort.split(":");
			if (parts.length > 0 && ["points", "accuracy", "score", "submitted", "misses"].indexOf(parts[0]) >= 0) sortBy = parts[0];
			if (parts.length > 1 && ["asc", "desc"].indexOf(parts[1]) >= 0) direction = parts[1];
		}
		var asc = direction == "asc";
		list.sort(function(a:ScoreEntry, b:ScoreEntry) {
			var cmp = compareEntries(a, b, sortBy);
			return asc ? cmp : -cmp;
		});
	}

	static function compareEntries(a:ScoreEntry, b:ScoreEntry, sortBy:String):Int {
		var va:Float;
		var vb:Float;
		switch (sortBy) {
			case "points":
				va = a.points; vb = b.points;
			case "accuracy":
				va = a.accuracy; vb = b.accuracy;
			case "misses":
				va = a.misses; vb = b.misses;
			case "submitted":
				va = a.submittedTs; vb = b.submittedTs;
			default:
				va = a.score; vb = b.score;
		}
		if (va < vb) return -1;
		if (va > vb) return 1;
		return 0;
	}

	// ---- reports ----

	public static function report(reporter:Account, content:String):ReportEntry {
		return Db.lockTx(function() {
			var seq = LeaderboardRepo.nextSeq();
			var entry:ReportEntry = {
				id: "r" + seq,
				reporter: reporter != null ? reporter.name : "anonymous",
				content: content,
				submitted: JsonStore.isoNow()
			};
			LeaderboardRepo.insertReport(entry);
			return entry;
		});
	}

	public static function reportCount():Int {
		return Db.lock(function() return LeaderboardRepo.countReports());
	}

	// ---- song comments ----

	public static function comments(songId:String):Array<CommentEntry> {
		return Db.lock(function() return LeaderboardRepo.commentsBySongId(songId));
	}

	/** Console: newest-first comment page across all songs. */
	public static function recentComments(page:Int, size:Int):{total:Int, rows:Array<CommentEntry>} {
		return Db.lock(function() {
			var all = LeaderboardRepo.allCommentsNewestFirst();
			var start = (page <= 0 ? 0 : page) * size;
			var rows = (start >= all.length) ? [] : all.slice(start, start + size);
			return { total: all.length, rows: rows };
		});
	}

	public static function addComment(player:String, songId:String, content:String, at:Float):Array<CommentEntry> {
		return Db.lockTx(function() {
			var seq = LeaderboardRepo.nextSeq();
			var entry:CommentEntry = {
				id: "c" + seq,
				songId: ServerConfig.repairUtf8(songId),
				player: ServerConfig.repairUtf8(player),
				content: ServerConfig.repairUtf8(content),
				at: at
			};
			LeaderboardRepo.insertComment(entry);
			return LeaderboardRepo.commentsBySongId(songId);
		});
	}

	// ------------------------------------------------------------------
	// /api/user/scores, /api/score/{delete,set/modurl} and /api/search/songs
	// ------------------------------------------------------------------

	public static inline var PLAYER_PAGE_SIZE:Int = 15;
	public static inline var SEARCH_PAGE_SIZE:Int = 50;

	/**
	 * A player's score list. The default sort is points (unlike topSongs' score), take 15 /
	 * skip 15*page.
	 */
	public static function playerScores(playerId:String, page:Int, keys:Int, category:String, sort:String):Array<ScoreEntry> {
		return Db.lock(function() {
			var out:Array<ScoreEntry> = [];
			for (s in LeaderboardRepo.scoresByPlayer(playerId)) {
				if (!matchesKeys(s, keys)) continue;
				if (!withinCategory(s, category)) continue;
				out.push(s);
			}
			sortEntries(out, sort, "points");
			var start = (page <= 0 ? 0 : page) * PLAYER_PAGE_SIZE;
			if (start >= out.length) return [];
			return out.slice(start, start + PLAYER_PAGE_SIZE);
		});
	}

	/** /api/search/songs: contains match, take 50 / skip 50*page, returns {id, fp}. */
	public static function searchSongs(q:String, page:Int):Array<Dynamic> {
		return Db.lock(function() {
			var needle = q == null ? "" : q.toLowerCase();
			var ids:Array<String> = [];
			var best:Map<String, Float> = new Map();
			for (s in LeaderboardRepo.allScores()) {
				if (s.songId == null || s.songId.toLowerCase().indexOf(needle) < 0) continue;
				if (!best.exists(s.songId)) {
					ids.push(s.songId);
					best.set(s.songId, s.points);
				} else if (s.points > best.get(s.songId)) {
					best.set(s.songId, s.points);
				}
			}
			ids.sort(function(a:String, b:String) return a < b ? -1 : (a > b ? 1 : 0));
			var start = (page <= 0 ? 0 : page) * SEARCH_PAGE_SIZE;
			var out:Array<Dynamic> = [];
			var i = start;
			while (i < ids.length && out.length < SEARCH_PAGE_SIZE) {
				out.push({ id: ids[i], fp: best.get(ids[i]) });
				i++;
			}
			return out;
		});
	}

	/**
	 * /api/score/delete. Returns the player's stats after deletion. Stats are not written back
	 * to AccountStore here because Db's Mutex is not reentrant; Api does the cross-store write
	 * outside the lock.
	 */
	public static function removeScore(id:String, checkPlayerID:String):RemoveResult {
		return Db.lockTx(function() {
			var entry = LeaderboardRepo.scoreById(id);
			if (entry == null) return { ok: true, error: null, playerId: null, points: 0.0, accuracy: 0.0, games: 0 };
			if (checkPlayerID != null && entry.player != checkPlayerID)
				return { ok: false, error: "Unauthorized!", playerId: null, points: 0.0, accuracy: 0.0, games: 0 };

			var playerId = entry.player;
			LeaderboardRepo.deleteScore(entry.id);

			var sum = 0.0;
			var acc = 0.0;
			var games = 0;
			for (s in LeaderboardRepo.scoresByPlayer(playerId)) {
				sum += s.points;
				acc += s.accuracy;
				games++;
			}
			return {
				ok: true,
				error: null,
				playerId: playerId,
				points: sum,
				accuracy: games == 0 ? 0 : acc / games,
				games: games
			};
		});
	}

	/** /api/score/set/modurl. Returns false when the score does not exist. */
	public static function setModURL(id:String, url:String):Bool {
		return Db.lockTx(function() return LeaderboardRepo.setModURL(id, url));
	}

	// ------------------------------------------------------------------
	// Admin-side reports and ban/delete data cleanup
	// ------------------------------------------------------------------

	/** Aggregate stats over all of a player's scores. */
	public static function statsOf(playerId:String):PlayerStats {
		return Db.lock(function() {
			var sum = 0.0;
			var acc = 0.0;
			var games = 0;
			for (s in LeaderboardRepo.scoresByPlayer(playerId)) {
				sum += s.points;
				acc += s.accuracy;
				games++;
			}
			return { points: sum, accuracy: games == 0 ? 0 : acc / games, games: games };
		});
	}

	/** Ids of players with a score in a category (used by /api/admin/updateweekly). */
	public static function playerIdsWithCategory(category:String):Array<String> {
		return Db.lock(function() return LeaderboardRepo.playerIdsWithCategory(category));
	}

	/**
	 * /api/admin/endweekly: deletes every score in a category. Returns the affected player ids;
	 * Api writes the stats back outside the lock.
	 */
	public static function purgeCategory(category:String):Array<String> {
		return Db.lockTx(function() return LeaderboardRepo.purgeCategory(category));
	}

	/** All reports, in insertion order. */
	public static function reports():Array<ReportEntry> {
		return Db.lock(function() return LeaderboardRepo.allReports());
	}

	/** /api/admin/report/content. Returns null when not found. */
	public static function reportOf(id:String):ReportEntry {
		return Db.lock(function() return LeaderboardRepo.reportById(id));
	}

	/** Removes a report. Returns false when there is no such report. */
	public static function removeReport(id:String):Bool {
		return Db.lockTx(function() return LeaderboardRepo.deleteReport(id));
	}

	/**
	 * On ban/delete, clears the player's scores, comments and reports. Scores match by account
	 * id; comments and reports match by player name (both store names locally).
	 */
	public static function purgePlayer(playerId:String, playerName:String):Void {
		Db.lockTx(function() {
			if (playerId != null) LeaderboardRepo.purgeScoresByPlayer(playerId);
			if (playerName != null) {
				LeaderboardRepo.purgeCommentsByPlayer(playerName);
				LeaderboardRepo.purgeReportsByReporter(playerName);
			}
			return true;
		});
	}
}
