package online_server.db;

import online_server.LeaderboardStore.CommentEntry;
import online_server.LeaderboardStore.ReportEntry;
import online_server.LeaderboardStore.ScoreEntry;

/**
 * Scores / song comments / reports repository.
 *
 * Every method expects the caller to already hold Db's lock (LeaderboardStore does that through
 * Db.lock / Db.lockTx); this class never acquires the lock itself. Rows are projected into freshly
 * built structs here, so no live result row ever leaves the repository.
 *
 * `seq` keeps the legacy insertion order several methods rely on (the old JSON layer appended to
 * one array). It is derived from the id (`s4` -> 4) so a legacy import keeps the original position
 * of every row without an extra column in the public typedefs.
 */
class LeaderboardRepo {
	/** Column lists. Table and column names are code constants, never caller input. */
	static inline var SCORE_COLUMNS = 'id, seq, song_id, song, difficulty, chart_hash, player, player_name, strum, keys, score, accuracy, points, misses, sicks, goods, bads, shits, playback_rate, mod_url, category, replay, submitted, submitted_ts';
	static inline var COMMENT_COLUMNS = 'id, seq, song_id, player, content, at';
	static inline var REPORT_COLUMNS = 'id, seq, reporter, content, submitted';

	/** One counter shared by scores (s), comments (c) and reports (r): ids stay s4 / c1 / r3. */
	static inline var COUNTER_KEY = 'leaderboard.seq';

	// ------------------------------------------------------------------
	// Counter (caller holds the lock)
	// ------------------------------------------------------------------

	public static function nextSeq():Int {
		return Db.nextSeqLocked(COUNTER_KEY);
	}

	// ------------------------------------------------------------------
	// Scores
	// ------------------------------------------------------------------

	public static function countScores():Int {
		return Db.scalar('SELECT COUNT(*) FROM scores', 0);
	}

	public static function scoreById(id:String):ScoreEntry {
		return toScore(Db.queryOne('SELECT ' + SCORE_COLUMNS + ' FROM scores WHERE id = ' + Db.quote(id) + ' LIMIT 1'));
	}

	/** Every score in insertion order. */
	public static function allScores():Array<ScoreEntry> {
		return projectScores(Db.query('SELECT ' + SCORE_COLUMNS + ' FROM scores ORDER BY seq ASC'));
	}

	public static function scoresBySongId(songId:String):Array<ScoreEntry> {
		var where = songId == null ? 'song_id IS NULL' : 'song_id = ' + Db.quote(songId);
		return projectScores(Db.query('SELECT ' + SCORE_COLUMNS + ' FROM scores WHERE ' + where + ' ORDER BY seq ASC'));
	}

	public static function scoresByPlayer(playerId:String):Array<ScoreEntry> {
		// A null player id must match legacy rows that carry no player, exactly like the old
		// "s.player != playerId" comparison did.
		var where = playerId == null ? 'player IS NULL' : 'player = ' + Db.quote(playerId);
		return projectScores(Db.query('SELECT ' + SCORE_COLUMNS + ' FROM scores WHERE ' + where + ' ORDER BY seq ASC'));
	}

	public static function insertScore(e:ScoreEntry):Void {
		Db.exec('INSERT INTO scores (' + SCORE_COLUMNS + ') VALUES ('
			+ Db.quote(e.id) + ', ' + Sqlite.int(seqOfId(e.id)) + ', ' + Db.quote(e.songId) + ', '
			+ Db.quote(e.song) + ', ' + Db.quote(e.difficulty) + ', ' + Db.quote(e.chartHash) + ', '
			+ Db.quote(e.player) + ', ' + Db.quote(e.playerName) + ', ' + Sqlite.int(e.strum) + ', '
			+ Sqlite.int(e.keys) + ', ' + Sqlite.real(e.score) + ', ' + Sqlite.real(e.accuracy) + ', '
			+ Sqlite.real(e.points) + ', ' + Sqlite.real(e.misses) + ', ' + Sqlite.real(e.sicks) + ', '
			+ Sqlite.real(e.goods) + ', ' + Sqlite.real(e.bads) + ', ' + Sqlite.real(e.shits) + ', '
			+ Sqlite.real(e.playbackRate) + ', ' + Db.quote(e.modURL) + ', ' + Db.quote(e.category) + ', '
			+ Db.quote(e.replay) + ', ' + Db.quote(e.submitted) + ', ' + Sqlite.real(e.submittedTs) + ')');
	}

	public static function deleteScore(id:String):Bool {
		if (id == null || id == '') return false;
		Db.exec('DELETE FROM scores WHERE id = ' + Db.quote(id));
		return true;
	}

	/** False when the score does not exist. */
	public static function setModURL(id:String, url:String):Bool {
		if (id == null || id == '') return false;
		if (Db.scalar('SELECT COUNT(*) FROM scores WHERE id = ' + Db.quote(id), 0) == 0) return false;
		Db.exec('UPDATE scores SET mod_url = ' + Db.quote(url) + ' WHERE id = ' + Db.quote(id));
		return true;
	}

	/** Distinct player ids with a score in `category` (all scores when null), insertion order. */
	public static function playerIdsWithCategory(category:String):Array<String> {
		var where = category == null ? '' : ' WHERE category = ' + Db.quote(category);
		var rows = Db.query('SELECT player FROM scores' + where + ' ORDER BY seq ASC');
		var out:Array<String> = [];
		for (r in rows) {
			var id = Sqlite.str(r, 'player', null);
			if (out.indexOf(id) < 0) out.push(id);
		}
		return out;
	}

	/**
	 * Deletes every score in `category` (all scores when null) and returns the affected player
	 * ids. The old array scan walked backwards, so the ids are collected newest-first to keep the
	 * returned order identical.
	 */
	public static function purgeCategory(category:String):Array<String> {
		var where = category == null ? '' : ' WHERE category = ' + Db.quote(category);
		var rows = Db.query('SELECT player FROM scores' + where + ' ORDER BY seq DESC');
		var affected:Array<String> = [];
		for (r in rows) {
			var id = Sqlite.str(r, 'player', null);
			if (affected.indexOf(id) < 0) affected.push(id);
		}
		Db.exec('DELETE FROM scores' + where);
		return affected;
	}

	public static function purgeScoresByPlayer(playerId:String):Void {
		Db.exec('DELETE FROM scores WHERE player = ' + Db.quote(playerId));
	}

	// ------------------------------------------------------------------
	// Comments
	// ------------------------------------------------------------------

	public static function commentsBySongId(songId:String):Array<CommentEntry> {
		var where = songId == null ? 'song_id IS NULL' : 'song_id = ' + Db.quote(songId);
		return projectComments(Db.query('SELECT ' + COMMENT_COLUMNS + ' FROM comments WHERE ' + where + ' ORDER BY seq ASC'));
	}

	/** Every comment newest-first (the console page reads the legacy reversed array). */
	public static function allCommentsNewestFirst():Array<CommentEntry> {
		return projectComments(Db.query('SELECT ' + COMMENT_COLUMNS + ' FROM comments ORDER BY seq DESC'));
	}

	public static function insertComment(c:CommentEntry):Void {
		Db.exec('INSERT INTO comments (' + COMMENT_COLUMNS + ') VALUES ('
			+ Db.quote(c.id) + ', ' + Sqlite.int(seqOfId(c.id)) + ', ' + Db.quote(c.songId) + ', '
			+ Db.quote(c.player) + ', ' + Db.quote(c.content) + ', ' + Sqlite.real(c.at) + ')');
	}

	public static function purgeCommentsByPlayer(playerName:String):Void {
		Db.exec('DELETE FROM comments WHERE player = ' + Db.quote(playerName));
	}

	// ------------------------------------------------------------------
	// Reports
	// ------------------------------------------------------------------

	public static function countReports():Int {
		return Db.scalar('SELECT COUNT(*) FROM reports', 0);
	}

	/** All reports in insertion order. */
	public static function allReports():Array<ReportEntry> {
		return projectReports(Db.query('SELECT ' + REPORT_COLUMNS + ' FROM reports ORDER BY seq ASC'));
	}

	public static function reportById(id:String):ReportEntry {
		return toReport(Db.queryOne('SELECT ' + REPORT_COLUMNS + ' FROM reports WHERE id = ' + Db.quote(id) + ' LIMIT 1'));
	}

	public static function insertReport(r:ReportEntry):Void {
		Db.exec('INSERT INTO reports (' + REPORT_COLUMNS + ') VALUES ('
			+ Db.quote(r.id) + ', ' + Sqlite.int(seqOfId(r.id)) + ', ' + Db.quote(r.reporter) + ', '
			+ Db.quote(r.content) + ', ' + Db.quote(r.submitted) + ')');
	}

	/** False when there is no such report (or the id is empty). */
	public static function deleteReport(id:String):Bool {
		if (id == null || id == '') return false;
		if (Db.scalar('SELECT COUNT(*) FROM reports WHERE id = ' + Db.quote(id), 0) == 0) return false;
		Db.exec('DELETE FROM reports WHERE id = ' + Db.quote(id));
		return true;
	}

	public static function purgeReportsByReporter(reporter:String):Void {
		Db.exec('DELETE FROM reports WHERE reporter = ' + Db.quote(reporter));
	}

	// ------------------------------------------------------------------
	// Row projection (raw rows never escape)
	// ------------------------------------------------------------------

	static function projectScores(rows:Array<Dynamic>):Array<ScoreEntry> {
		var out:Array<ScoreEntry> = [];
		for (r in rows) out.push(toScore(r));
		return out;
	}

	static function projectComments(rows:Array<Dynamic>):Array<CommentEntry> {
		var out:Array<CommentEntry> = [];
		for (r in rows) out.push(toComment(r));
		return out;
	}

	static function projectReports(rows:Array<Dynamic>):Array<ReportEntry> {
		var out:Array<ReportEntry> = [];
		for (r in rows) out.push(toReport(r));
		return out;
	}

	static function toScore(row:Dynamic):ScoreEntry {
		if (row == null) return null;
		var e:ScoreEntry = {
			id: Sqlite.str(row, 'id', ''),
			songId: Sqlite.str(row, 'song_id', ''),
			song: Sqlite.str(row, 'song', ''),
			difficulty: Sqlite.str(row, 'difficulty', ''),
			chartHash: Sqlite.str(row, 'chart_hash', ''),
			player: Sqlite.str(row, 'player', ''),
			playerName: Sqlite.str(row, 'player_name', ''),
			strum: Sqlite.intOf(row, 'strum', 0),
			keys: Sqlite.intOf(row, 'keys', 0),
			score: Sqlite.num(row, 'score', 0),
			accuracy: Sqlite.num(row, 'accuracy', 0),
			points: Sqlite.num(row, 'points', 0),
			misses: Sqlite.num(row, 'misses', 0),
			sicks: Sqlite.num(row, 'sicks', 0),
			goods: Sqlite.num(row, 'goods', 0),
			bads: Sqlite.num(row, 'bads', 0),
			shits: Sqlite.num(row, 'shits', 0),
			playbackRate: Sqlite.num(row, 'playback_rate', 1),
			modURL: Sqlite.str(row, 'mod_url', ''),
			category: Sqlite.str(row, 'category', ''),
			replay: Sqlite.str(row, 'replay', ''),
			submitted: Sqlite.str(row, 'submitted', ''),
			submittedTs: Sqlite.num(row, 'submitted_ts', 0)
		};
		return e;
	}

	static function toComment(row:Dynamic):CommentEntry {
		if (row == null) return null;
		var c:CommentEntry = {
			id: Sqlite.str(row, 'id', ''),
			songId: Sqlite.str(row, 'song_id', ''),
			player: Sqlite.str(row, 'player', ''),
			content: Sqlite.str(row, 'content', ''),
			at: Sqlite.num(row, 'at', 0)
		};
		return c;
	}

	static function toReport(row:Dynamic):ReportEntry {
		if (row == null) return null;
		var r:ReportEntry = {
			id: Sqlite.str(row, 'id', ''),
			reporter: Sqlite.str(row, 'reporter', ''),
			content: Sqlite.str(row, 'content', ''),
			submitted: Sqlite.str(row, 'submitted', '')
		};
		return r;
	}

	/**
	 * The legacy insertion index, derived from the id (`s12` -> 12, `c1` -> 1, `r3` -> 3). An
	 * imported row keeps its original position and a freshly allocated id always sorts last.
	 */
	static function seqOfId(id:String):Int {
		if (id == null || id.length < 2) return 0;
		var parsed = Std.parseInt(id.substr(1));
		return parsed == null ? 0 : parsed;
	}
}
