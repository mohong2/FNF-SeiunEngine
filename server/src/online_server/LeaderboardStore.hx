package online_server;

import haxe.Json;
import sys.FileSystem;
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
 * Local JSON storage for scores / replays / song comments / reports (no new dependencies).
 * Submission validation: ReplayData version 4, non-empty inputs, and points / score caps.
 * Pagination is a fixed PAGE_SIZE and 'week' is approximated as the last 7 days.
 */
class LeaderboardStore {
	/**
	 * Leaderboard page size. The client's Scoreboard row count is hard-coded to 15
	 * (TopPlayerSubstate.hx:9), so returning more (20 was tried) makes Scoreboard.setRow(i)
	 * index rows[15] out of bounds, a null dereference crash on cpp.
	 */
	public static inline var PAGE_SIZE:Int = 15;
	static inline var WEEK_SECONDS:Float = 7 * 24 * 60 * 60;

	static var path:String = null;
	/** { seq:Int, scores:Array<ScoreEntry>, comments:Array<CommentEntry>, reports:Array<ReportEntry> } */
	static var db:Dynamic = null;

	public static function init(file:String):Void {
		path = file;
		JsonStore.lock(function() {
			var loaded = JsonStore.read(path, null);
			if (loaded == null || loaded.scores == null) {
				loaded = { seq: 0, scores: [], comments: [], reports: [] };
			}
			if (loaded.comments == null) loaded.comments = [];
			if (loaded.reports == null) loaded.reports = [];
			db = loaded;
			if (!FileSystem.exists(path)) JsonStore.write(path, db);
			return true;
		});
	}

	public static function storagePath():String return path;

	static inline function scoresU():Array<ScoreEntry> return cast db.scores;
	static inline function commentsU():Array<CommentEntry> return cast db.comments;
	static inline function reportsU():Array<ReportEntry> return cast db.reports;

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

		return JsonStore.lock(function() {
			db.seq = db.seq + 1;
			var entry:ScoreEntry = {
				id: "s" + db.seq,
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
			scoresU().push(entry);
			JsonStore.write(path, db);
			return { ok: true, error: null, entry: entry };
		});
	}

	public static function count():Int return JsonStore.lock(function() return scoresU().length);

	public static function getScore(id:String):ScoreEntry {
		return JsonStore.lock(function() {
			for (s in scoresU()) if (s.id == id) return s;
			return null;
		});
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
		return JsonStore.lock(function() {
			var out:Array<ScoreEntry> = [];
			for (s in scoresU()) {
				if (s.songId != songId) continue;
				if (strum > 0 && s.strum != strum) continue;
				if (!matchesKeys(s, keys)) continue;
				if (!withinCategory(s, category)) continue;
				out.push(s);
			}
			sortEntries(out, sort);
			var start = (page <= 0 ? 0 : page) * PAGE_SIZE;
			if (start >= out.length) return [];
			return out.slice(start, start + PAGE_SIZE);
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
		return JsonStore.lock(function() {
			db.seq = db.seq + 1;
			var entry:ReportEntry = {
				id: "r" + db.seq,
				reporter: reporter != null ? reporter.name : "anonymous",
				content: content,
				submitted: JsonStore.isoNow()
			};
			reportsU().push(entry);
			JsonStore.write(path, db);
			return entry;
		});
	}

	public static function reportCount():Int return JsonStore.lock(function() return reportsU().length);

	// ---- song comments ----

	public static function comments(songId:String):Array<CommentEntry> {
		return JsonStore.lock(function() {
			var out:Array<CommentEntry> = [];
			for (c in commentsU()) if (c.songId == songId) out.push(c);
			return out;
		});
	}

	/** Console: newest-first comment page across all songs. */
	public static function recentComments(page:Int, size:Int):{total:Int, rows:Array<CommentEntry>} {
		return JsonStore.lock(function() {
			var all = commentsU().copy();
			all.reverse();
			var start = (page <= 0 ? 0 : page) * size;
			var rows = (start >= all.length) ? [] : all.slice(start, start + size);
			return { total: all.length, rows: rows };
		});
	}

	public static function addComment(player:String, songId:String, content:String, at:Float):Array<CommentEntry> {
		return JsonStore.lock(function() {
			db.seq = db.seq + 1;
			var entry:CommentEntry = {
				id: "c" + db.seq,
				songId: songId,
				player: player,
				content: content,
				at: at
			};
			commentsU().push(entry);
			JsonStore.write(path, db);
			var out:Array<CommentEntry> = [];
			for (c in commentsU()) if (c.songId == songId) out.push(c);
			return out;
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
		return JsonStore.lock(function() {
			var out:Array<ScoreEntry> = [];
			for (s in scoresU()) {
				if (s.player != playerId) continue;
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
		return JsonStore.lock(function() {
			var needle = q == null ? "" : q.toLowerCase();
			var ids:Array<String> = [];
			var best:Map<String, Float> = new Map();
			for (s in scoresU()) {
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
	 * to AccountStore here because JsonStore has a single global Mutex; Api does the cross-store
	 * write outside the lock.
	 */
	public static function removeScore(id:String, checkPlayerID:String):RemoveResult {
		return JsonStore.lock(function() {
			var entry:ScoreEntry = null;
			for (s in scoresU()) if (s.id == id) {
				entry = s;
				break;
			}
			if (entry == null) return { ok: true, error: null, playerId: null, points: 0.0, accuracy: 0.0, games: 0 };
			if (checkPlayerID != null && entry.player != checkPlayerID)
				return { ok: false, error: "Unauthorized!", playerId: null, points: 0.0, accuracy: 0.0, games: 0 };

			var playerId = entry.player;
			scoresU().remove(entry);
			JsonStore.write(path, db);

			var sum = 0.0;
			var acc = 0.0;
			var games = 0;
			for (s in scoresU()) {
				if (s.player != playerId) continue;
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
		return JsonStore.lock(function() {
			for (s in scoresU()) {
				if (s.id == id) {
					s.modURL = url;
					JsonStore.write(path, db);
					return true;
				}
			}
			return false;
		});
	}

	// ------------------------------------------------------------------
	// Admin-side reports and ban/delete data cleanup
	// ------------------------------------------------------------------

	/** Aggregate stats over all of a player's scores. */
	public static function statsOf(playerId:String):PlayerStats {
		return JsonStore.lock(function() {
			var sum = 0.0;
			var acc = 0.0;
			var games = 0;
			for (s in scoresU()) {
				if (s.player != playerId) continue;
				sum += s.points;
				acc += s.accuracy;
				games++;
			}
			return { points: sum, accuracy: games == 0 ? 0 : acc / games, games: games };
		});
	}

	/** Ids of players with a score in a category (used by /api/admin/updateweekly). */
	public static function playerIdsWithCategory(category:String):Array<String> {
		return JsonStore.lock(function() {
			var out:Array<String> = [];
			for (s in scoresU()) {
				if (category != null && s.category != category) continue;
				if (out.indexOf(s.player) < 0) out.push(s.player);
			}
			return out;
		});
	}

	/**
	 * /api/admin/endweekly: deletes every score in a category. Returns the affected player ids;
	 * Api writes the stats back outside the lock.
	 */
	public static function purgeCategory(category:String):Array<String> {
		return JsonStore.lock(function() {
			var affected:Array<String> = [];
			var i = scoresU().length - 1;
			while (i >= 0) {
				if (category == null || scoresU()[i].category == category) {
					if (affected.indexOf(scoresU()[i].player) < 0) affected.push(scoresU()[i].player);
					scoresU().splice(i, 1);
				}
				i--;
			}
			JsonStore.write(path, db);
			return affected;
		});
	}

	/** All reports, in insertion order. */
	public static function reports():Array<ReportEntry> {
		return JsonStore.lock(function() return reportsU().copy());
	}

	/** /api/admin/report/content. Returns null when not found. */
	public static function reportOf(id:String):ReportEntry {
		return JsonStore.lock(function() {
			for (r in reportsU()) if (r.id == id) return r;
			return null;
		});
	}

	/** Removes a report. Returns false when there is no such report. */
	public static function removeReport(id:String):Bool {
		return JsonStore.lock(function() {
			if (id == null || id == "") return false;
			var i = reportsU().length - 1;
			while (i >= 0) {
				if (reportsU()[i].id == id) {
					reportsU().splice(i, 1);
					JsonStore.write(path, db);
					return true;
				}
				i--;
			}
			return false;
		});
	}

	/**
	 * On ban/delete, clears the player's scores, comments and reports. Scores match by account
	 * id; comments and reports match by player name (both store names locally).
	 */
	public static function purgePlayer(playerId:String, playerName:String):Void {
		JsonStore.lock(function() {
			if (playerId != null) {
				var i = scoresU().length - 1;
				while (i >= 0) {
					if (scoresU()[i].player == playerId) scoresU().splice(i, 1);
					i--;
				}
			}
			if (playerName != null) {
				var j = commentsU().length - 1;
				while (j >= 0) {
					if (commentsU()[j].player == playerName) commentsU().splice(j, 1);
					j--;
				}
				var k = reportsU().length - 1;
				while (k >= 0) {
					if (reportsU()[k].reporter == playerName) reportsU().splice(k, 1);
					k--;
				}
			}
			JsonStore.write(path, db);
			return true;
		});
	}
}
