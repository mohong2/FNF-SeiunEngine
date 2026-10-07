package online_server.db;

import sys.db.Connection;

/**
 * Versioned schema. Only additive: a published step is never edited, a new step is appended and
 * SQLITE user_version decides which ones still need to run. That keeps an already-migrated
 * server (and a rollback to an older build) from being re-shaped by a newer binary.
 *
 * Storage notes (documented in server/README.md as well):
 *  - Scalars live in typed columns so they can be indexed, ordered and compared by SQLite.
 *  - List-valued fields (access, friends, ips, club members, mod keywords, download URLs, ...)
 *    are stored in TEXT columns as JSON arrays. They are never queried element-wise, and JSON
 *    keeps the exact legacy shape without a join for every read.
 *  - Credentials are never stored in plaintext: sessions holds HMAC-SHA256(token) plus an
 *    8-character lookup prefix.
 */
class Migrations {
	/** Bump when appending a step; also surfaced by /api/health as dbSchemaVersion. */
	public static inline var SCHEMA_VERSION:Int = 1;

	/** Applies every step newer than the file's user_version, inside one transaction. */
	public static function migrate(conn:Connection):Int {
		var current = userVersion(conn);
		if (current >= SCHEMA_VERSION) return current;
		Sqlite.exec(conn, "BEGIN IMMEDIATE");
		try {
			if (current < 1) step1(conn);
			Sqlite.exec(conn, "PRAGMA user_version = " + SCHEMA_VERSION);
			Sqlite.exec(conn, "COMMIT");
		} catch (e:Dynamic) {
			try Sqlite.exec(conn, "ROLLBACK") catch (e2:Dynamic) {}
			throw "migration failed (user_version " + current + " -> " + SCHEMA_VERSION + "): " + Std.string(e);
		}
		return SCHEMA_VERSION;
	}

	public static function userVersion(conn:Connection):Int {
		return Sqlite.scalarInt(conn, "PRAGMA user_version", 0);
	}

	/** v1: the whole legacy JSON model, one table per entity. */
	static function step1(conn:Connection):Void {
		for (sql in STEP_1) Sqlite.exec(conn, sql);
	}

	static var STEP_1:Array<String> = [
		"CREATE TABLE IF NOT EXISTS meta (
			key TEXT PRIMARY KEY,
			value TEXT NOT NULL DEFAULT ''
		)",

		"CREATE TABLE IF NOT EXISTS accounts (
			id TEXT PRIMARY KEY,
			seq INTEGER NOT NULL DEFAULT 0,
			name TEXT NOT NULL DEFAULT '',
			email TEXT,
			points REAL NOT NULL DEFAULT 0,
			avg_accuracy REAL NOT NULL DEFAULT 0,
			games INTEGER NOT NULL DEFAULT 0,
			profile_hue REAL NOT NULL DEFAULT 250,
			profile_hue2 REAL,
			country TEXT,
			last_active REAL,
			bio TEXT,
			role TEXT,
			ng_url TEXT,
			ng_id TEXT,
			created_at REAL NOT NULL DEFAULT 0,
			access_json TEXT NOT NULL DEFAULT '[]',
			notifications_json TEXT NOT NULL DEFAULT '[]',
			friends_json TEXT NOT NULL DEFAULT '[]',
			friend_requests_json TEXT NOT NULL DEFAULT '[]',
			ips_json TEXT NOT NULL DEFAULT '[]',
			current_session_id TEXT
		)",
		"CREATE INDEX IF NOT EXISTS idx_accounts_email ON accounts(email)",
		"CREATE INDEX IF NOT EXISTS idx_accounts_name ON accounts(name)",
		"CREATE INDEX IF NOT EXISTS idx_accounts_ngid ON accounts(ng_id)",
		"CREATE INDEX IF NOT EXISTS idx_accounts_session ON accounts(current_session_id)",

		// Bearer credentials. One row per issued token; rotating a login revokes the previous row
		// instead of overwriting a plaintext field in a JSON blob.
		"CREATE TABLE IF NOT EXISTS sessions (
			id TEXT PRIMARY KEY,
			account_id TEXT NOT NULL,
			token_hash TEXT NOT NULL,
			token_prefix TEXT NOT NULL,
			issued_at REAL NOT NULL DEFAULT 0,
			expires_at REAL,
			ttl_minutes INTEGER,
			revoked_at REAL,
			last_used_at REAL,
			ip TEXT
		)",
		"CREATE INDEX IF NOT EXISTS idx_sessions_prefix ON sessions(token_prefix)",
		"CREATE INDEX IF NOT EXISTS idx_sessions_account ON sessions(account_id)",

		"CREATE TABLE IF NOT EXISTS scores (
			id TEXT PRIMARY KEY,
			seq INTEGER NOT NULL DEFAULT 0,
			song_id TEXT,
			song TEXT,
			difficulty TEXT,
			chart_hash TEXT,
			player TEXT,
			player_name TEXT,
			strum INTEGER NOT NULL DEFAULT 0,
			keys INTEGER NOT NULL DEFAULT 0,
			score REAL NOT NULL DEFAULT 0,
			accuracy REAL NOT NULL DEFAULT 0,
			points REAL NOT NULL DEFAULT 0,
			misses REAL NOT NULL DEFAULT 0,
			sicks REAL NOT NULL DEFAULT 0,
			goods REAL NOT NULL DEFAULT 0,
			bads REAL NOT NULL DEFAULT 0,
			shits REAL NOT NULL DEFAULT 0,
			playback_rate REAL NOT NULL DEFAULT 1,
			mod_url TEXT,
			category TEXT,
			replay TEXT,
			submitted TEXT,
			submitted_ts REAL NOT NULL DEFAULT 0
		)",
		"CREATE INDEX IF NOT EXISTS idx_scores_player ON scores(player)",
		"CREATE INDEX IF NOT EXISTS idx_scores_song ON scores(song_id)",

		"CREATE TABLE IF NOT EXISTS comments (
			id TEXT PRIMARY KEY,
			seq INTEGER NOT NULL DEFAULT 0,
			song_id TEXT,
			player TEXT,
			content TEXT,
			at REAL NOT NULL DEFAULT 0
		)",
		"CREATE INDEX IF NOT EXISTS idx_comments_song ON comments(song_id)",

		"CREATE TABLE IF NOT EXISTS reports (
			id TEXT PRIMARY KEY,
			seq INTEGER NOT NULL DEFAULT 0,
			reporter TEXT,
			content TEXT,
			submitted TEXT
		)",

		"CREATE TABLE IF NOT EXISTS clubs (
			id TEXT PRIMARY KEY,
			seq INTEGER NOT NULL DEFAULT 0,
			name TEXT NOT NULL DEFAULT '',
			tag TEXT NOT NULL DEFAULT '',
			content TEXT,
			hue REAL,
			points REAL NOT NULL DEFAULT 0,
			created_at REAL NOT NULL DEFAULT 0,
			banner TEXT,
			banner_type TEXT,
			members_json TEXT NOT NULL DEFAULT '[]',
			pending_json TEXT NOT NULL DEFAULT '[]',
			leaders_json TEXT NOT NULL DEFAULT '[]'
		)",
		"CREATE INDEX IF NOT EXISTS idx_clubs_tag ON clubs(tag)",

		"CREATE TABLE IF NOT EXISTS mods (
			id TEXT PRIMARY KEY,
			seq INTEGER NOT NULL DEFAULT 0,
			title TEXT,
			description TEXT,
			keywords_json TEXT NOT NULL DEFAULT '[]',
			images_json TEXT NOT NULL DEFAULT '[]',
			favorited_json TEXT NOT NULL DEFAULT '[]',
			favorited_count INTEGER NOT NULL DEFAULT 0,
			download_hits INTEGER NOT NULL DEFAULT 0,
			submitted REAL NOT NULL DEFAULT 0,
			updated REAL,
			downloads_json TEXT NOT NULL DEFAULT '[]'
		)",

		"CREATE TABLE IF NOT EXISTS warns (
			id TEXT PRIMARY KEY,
			seq INTEGER NOT NULL DEFAULT 0,
			on_id TEXT,
			by_id TEXT,
			reason TEXT,
			date TEXT
		)",

		// Admin action log: newest first, capped, one line per row instead of one JSON string array.
		"CREATE TABLE IF NOT EXISTS admin_logs (
			seq INTEGER PRIMARY KEY AUTOINCREMENT,
			line TEXT NOT NULL
		)",

		"CREATE TABLE IF NOT EXISTS front_messages (
			seq INTEGER PRIMARY KEY AUTOINCREMENT,
			player TEXT,
			message TEXT
		)",

		"CREATE TABLE IF NOT EXISTS day_players (
			seq INTEGER PRIMARY KEY AUTOINCREMENT,
			count INTEGER NOT NULL DEFAULT 0,
			ts REAL NOT NULL DEFAULT 0
		)",

		"CREATE TABLE IF NOT EXISTS public_state (
			id INTEGER PRIMARY KEY CHECK (id = 1),
			next_weekly_date REAL NOT NULL DEFAULT 0
		)"
	];
}
