package online_server.db;

import haxe.io.Path;
import online_server.AccountStore.Account;
import online_server.Crypto;
import online_server.JsonStore;

/**
 * Accounts + sessions repository. Every method expects the caller to already hold Db's lock
 * (AccountStore does that through Db.lock), and every method returns freshly built structs --
 * raw result rows never leave this class.
 *
 * Column notes:
 *  - seq keeps the legacy insertion order (the JSON layer appended to one array, and several
 *    methods still rely on that order, so reads are ORDER BY seq).
 *  - access/notifications/friends/friend_requests/ips are TEXT columns holding JSON arrays.
 *  - Credentials live in `sessions`, never here: token_hash is HMAC-SHA256(token) and
 *    token_prefix is the first 8 characters, used only as an index-friendly lookup key.
 */
class AccountRepo {
	static inline var SELECT_ACCOUNT = 'SELECT a.*, s.token_prefix AS s_prefix, s.issued_at AS s_issued,'
		+ ' s.expires_at AS s_expires, s.ttl_minutes AS s_ttl, s.revoked_at AS s_revoked'
		+ ' FROM accounts a LEFT JOIN sessions s ON s.id = a.current_session_id';

	static inline var ACCOUNT_COLUMNS = 'id, seq, name, email, points, avg_accuracy, games, profile_hue, profile_hue2,'
		+ ' country, last_active, bio, role, ng_url, ng_id, created_at, access_json, notifications_json,'
		+ ' friends_json, friend_requests_json, ips_json, current_session_id';

	// ------------------------------------------------------------------
	// Reads (caller holds the lock)
	// ------------------------------------------------------------------

	public static function count():Int {
		return Db.scalar('SELECT COUNT(*) FROM accounts', 0);
	}

	public static function byId(id:String):Account {
		if (id == null) return null;
		return toAccount(Db.queryOne(SELECT_ACCOUNT + ' WHERE a.id = ' + Db.quote(id) + ' LIMIT 1'));
	}

	public static function byEmail(email:String):Account {
		if (email == null) return null;
		return toAccount(Db.queryOne(SELECT_ACCOUNT + ' WHERE a.email IS NOT NULL AND lower(a.email) = lower('
			+ Db.quote(email) + ') ORDER BY a.seq ASC LIMIT 1'));
	}

	public static function exactEmail(email:String):Account {
		if (email == null) return null;
		return toAccount(Db.queryOne(SELECT_ACCOUNT + ' WHERE a.email = ' + Db.quote(email) + ' LIMIT 1'));
	}

	public static function byName(name:String):Account {
		if (name == null) return null;
		return toAccount(Db.queryOne(SELECT_ACCOUNT + ' WHERE a.name IS NOT NULL AND lower(a.name) = lower('
			+ Db.quote(name) + ') ORDER BY a.seq ASC LIMIT 1'));
	}

	public static function byNameExact(name:String):Account {
		if (name == null) return null;
		return toAccount(Db.queryOne(SELECT_ACCOUNT + ' WHERE a.name = ' + Db.quote(name) + ' ORDER BY a.seq ASC LIMIT 1'));
	}

	public static function byNgId(ngId:String):Account {
		if (ngId == null) return null;
		return toAccount(Db.queryOne(SELECT_ACCOUNT + ' WHERE a.ng_id = ' + Db.quote(ngId) + ' ORDER BY a.seq ASC LIMIT 1'));
	}

	/** Full snapshot in legacy array order. Used by the admin list, /api/top/players and rankOf. */
	public static function all():Array<Account> {
		var rows = Db.query(SELECT_ACCOUNT + ' ORDER BY a.seq ASC');
		var out:Array<Account> = [];
		for (r in rows) out.push(toAccount(r));
		return out;
	}

	public static function namesOf(ids:Array<String>):Array<String> {
		var out:Array<String> = [];
		if (ids == null) return out;
		for (id in ids) {
			var name = Sqlite.scalarString(Db.connection(), 'SELECT name FROM accounts WHERE id = ' + Db.quote(id) + ' LIMIT 1', null);
			if (name != null) out.push(name);
		}
		return out;
	}

	public static function nameOf(id:String):String {
		return Sqlite.scalarString(Db.connection(), 'SELECT name FROM accounts WHERE id = ' + Db.quote(id) + ' LIMIT 1', null);
	}

	/** Account ids that share at least one recorded IP with `id`. */
	public static function sameIpIds(id:String):Array<String> {
		var out:Array<String> = [];
		var row = Db.queryOne('SELECT ips_json FROM accounts WHERE id = ' + Db.quote(id) + ' LIMIT 1');
		var mine = Sqlite.stringArray(row, 'ips_json');
		if (mine.length == 0) return out;
		for (other in all()) {
			if (other.id == id || other.ips == null || other.ips.length == 0) continue;
			for (ip in other.ips) {
				if (mine.indexOf(ip) >= 0) { out.push(other.id); break; }
			}
		}
		return out;
	}

	// ------------------------------------------------------------------
	// Writes (caller holds the lock)
	// ------------------------------------------------------------------

	public static function nextSeq():Int {
		return Db.nextSeqLocked('accounts.seq');
	}

	public static function insert(a:Account):Void {
		Db.exec('INSERT INTO accounts (' + ACCOUNT_COLUMNS + ') VALUES ('
			+ values(a, false) + ')');
	}

	public static function update(a:Account):Void {
		Db.exec('UPDATE accounts SET ' + assignments(a) + ' WHERE id = ' + Db.quote(a.id));
	}

	public static function remove(id:String):Bool {
		if (id == null) return false;
		Db.exec('DELETE FROM sessions WHERE account_id = ' + Db.quote(id));
		Db.exec('DELETE FROM accounts WHERE id = ' + Db.quote(id));
		return true;
	}

	// ------------------------------------------------------------------
	// Sessions (bearer credentials)
	// ------------------------------------------------------------------

	/**
	 * Replaces the account's credential with a fresh one: the previous session row is removed, so
	 * the old token stops working immediately (same behaviour as the old rotate-and-overwrite).
	 * Returns the generated session id.
	 */
	public static function issueSession(accountId:String, token:String, ttlMinutes:Int, issuedAt:Float, ip:String):String {
		var sessionId = 'se' + Crypto.randomHexChars(30);
		var expiresAt:Null<Float> = ttlMinutes <= 0 ? null : issuedAt + ttlMinutes * 60000.0;
		Db.exec('DELETE FROM sessions WHERE account_id = ' + Db.quote(accountId));
		Db.exec('INSERT INTO sessions (id, account_id, token_hash, token_prefix, issued_at, expires_at, ttl_minutes, revoked_at, last_used_at, ip) VALUES ('
			+ Db.quote(sessionId) + ', ' + Db.quote(accountId) + ', ' + Db.quote(Crypto.hashToken(token)) + ', '
			+ Db.quote(Crypto.tokenPrefix(token)) + ', ' + Sqlite.real(issuedAt) + ', ' + Sqlite.real(expiresAt) + ', '
			+ Sqlite.int(ttlMinutes) + ', NULL, ' + Sqlite.real(issuedAt) + ', ' + Db.quote(ip) + ')');
		Db.exec('UPDATE accounts SET current_session_id = ' + Db.quote(sessionId) + ' WHERE id = ' + Db.quote(accountId));
		return sessionId;
	}

	/** Inserts a session row verbatim (legacy import keeps the original issue/expiry timestamps). */
	public static function insertSessionRaw(id:String, accountId:String, tokenHash:String, tokenPrefix:String,
		issuedAt:Float, expiresAt:Null<Float>, ttlMinutes:Int, ip:String):Void {
		Db.exec('INSERT OR REPLACE INTO sessions (id, account_id, token_hash, token_prefix, issued_at, expires_at, ttl_minutes, revoked_at, last_used_at, ip) VALUES ('
			+ Db.quote(id) + ', ' + Db.quote(accountId) + ', ' + Db.quote(tokenHash) + ', ' + Db.quote(tokenPrefix) + ', '
			+ Sqlite.real(issuedAt) + ', ' + Sqlite.real(expiresAt) + ', ' + Sqlite.int(ttlMinutes) + ', NULL, '
			+ Sqlite.real(issuedAt) + ', ' + Db.quote(ip) + ')');
		Db.exec('UPDATE accounts SET current_session_id = ' + Db.quote(id) + ' WHERE id = ' + Db.quote(accountId));
	}

	public static function revokeSessions(accountId:String):Void {
		Db.exec('DELETE FROM sessions WHERE account_id = ' + Db.quote(accountId));
		Db.exec('UPDATE accounts SET current_session_id = NULL WHERE id = ' + Db.quote(accountId));
	}

	public static function sessionCount(accountId:String):Int {
		return Db.scalar('SELECT COUNT(*) FROM sessions WHERE account_id = ' + Db.quote(accountId), 0);
	}

	public static function upsertSessionById(sessionId:String, accountId:String, tokenHash:String, tokenPrefix:String,
		ttlMinutes:Int, issuedAt:Float, expiresAt:Null<Float>):Void {
		Db.exec('INSERT OR REPLACE INTO sessions (id, account_id, token_hash, token_prefix, issued_at, expires_at, ttl_minutes, revoked_at, last_used_at, ip) VALUES ('
			+ Db.quote(sessionId) + ', ' + Db.quote(accountId) + ', ' + Db.quote(tokenHash) + ', ' + Db.quote(tokenPrefix) + ', '
			+ Sqlite.real(issuedAt) + ', ' + Sqlite.real(expiresAt) + ', ' + Sqlite.int(ttlMinutes) + ', NULL, '
			+ Sqlite.real(issuedAt) + ', NULL)');
	}

	/**
	 * Constant-time comparison of a presented bearer token against the account's current session.
	 * A revoked or absent session always fails; expiry is checked by the caller through the
	 * projected Account fields so the two stay consistent.
	 */
	public static function verifyToken(accountId:String, token:String):Bool {
		if (accountId == null || token == null || token == '') return false;
		var row = Db.queryOne('SELECT token_hash, revoked_at FROM sessions WHERE account_id = ' + Db.quote(accountId)
			+ ' AND revoked_at IS NULL ORDER BY issued_at DESC LIMIT 1');
		if (row == null) return false;
		var stored = Sqlite.str(row, 'token_hash', null);
		if (stored == null) return false;
		return Crypto.equals(stored, Crypto.hashToken(token));
	}

	// ------------------------------------------------------------------
	// Row projection
	// ------------------------------------------------------------------

	public static function toAccount(row:Dynamic):Account {
		if (row == null) return null;
		var expires = Sqlite.numOrNull(row, 's_expires');
		var ttl = Sqlite.intOrNull(row, 's_ttl');
		// A session that does not exist (or was revoked) must not be reported as one.
		var hasSession = Sqlite.str(row, 's_prefix', null) != null && Sqlite.num(row, 's_revoked', 0) <= 0;
		var a:Account = {
			id: Sqlite.str(row, 'id', ''),
			name: Sqlite.str(row, 'name', ''),
			email: Sqlite.str(row, 'email', null),
			// Plaintext tokens are returned only by issueCredentials/createOrGet/rotateToken;
			// a projected account never carries a usable credential.
			token: null,
			points: Sqlite.num(row, 'points', 0),
			avgAccuracy: Sqlite.num(row, 'avg_accuracy', 0),
			games: Sqlite.intOf(row, 'games', 0),
			profileHue: Sqlite.num(row, 'profile_hue', 250),
			profileHue2: Sqlite.numOrNull(row, 'profile_hue2'),
			country: Sqlite.str(row, 'country', null),
			lastActive: Sqlite.numOrNull(row, 'last_active'),
			tokenIssuedAt: hasSession ? Sqlite.numOrNull(row, 's_issued') : null,
			tokenExpiresAt: hasSession ? expires : null,
			tokenTtlMinutes: hasSession ? ttl : null,
			bio: Sqlite.str(row, 'bio', null),
			notifications: Sqlite.dynamicArray(row, 'notifications_json'),
			friends: Sqlite.stringArray(row, 'friends_json'),
			friendRequests: Sqlite.stringArray(row, 'friend_requests_json'),
			ngUrl: Sqlite.str(row, 'ng_url', null),
			ngId: Sqlite.str(row, 'ng_id', null),
			role: Sqlite.str(row, 'role', null),
			ips: Sqlite.stringArray(row, 'ips_json'),
			access: Sqlite.stringArray(row, 'access_json'),
			createdAt: Sqlite.num(row, 'created_at', 0)
		};
		return a;
	}

	static function jsonColumn(json:String):String {
		return json;
	}

	static function values(a:Account, includeId:Bool):String {
		return [
			Db.quote(a.id),
			Sqlite.int(accountSeq(a)),
			Db.quote(a.name),
			Db.quote(a.email),
			Sqlite.real(a.points),
			Sqlite.real(a.avgAccuracy),
			Sqlite.int(a.games),
			Sqlite.real(a.profileHue),
			Sqlite.real(a.profileHue2),
			Db.quote(a.country),
			Sqlite.real(a.lastActive),
			Db.quote(a.bio),
			Db.quote(a.role),
			Db.quote(a.ngUrl),
			Db.quote(a.ngId),
			Sqlite.real(a.createdAt),
			Db.quote(Sqlite.json(a.access)),
			Db.quote(Sqlite.json(a.notifications)),
			Db.quote(Sqlite.json(a.friends)),
			Db.quote(Sqlite.json(a.friendRequests)),
			Db.quote(Sqlite.json(a.ips)),
			'NULL'
		].join(', ');
	}

	static function assignments(a:Account):String {
		return 'seq = ' + Sqlite.int(accountSeq(a))
			+ ', name = ' + Db.quote(a.name)
			+ ', email = ' + Db.quote(a.email)
			+ ', points = ' + Sqlite.real(a.points)
			+ ', avg_accuracy = ' + Sqlite.real(a.avgAccuracy)
			+ ', games = ' + Sqlite.int(a.games)
			+ ', profile_hue = ' + Sqlite.real(a.profileHue)
			+ ', profile_hue2 = ' + Sqlite.real(a.profileHue2)
			+ ', country = ' + Db.quote(a.country)
			+ ', last_active = ' + Sqlite.real(a.lastActive)
			+ ', bio = ' + Db.quote(a.bio)
			+ ', role = ' + Db.quote(a.role)
			+ ', ng_url = ' + Db.quote(a.ngUrl)
			+ ', ng_id = ' + Db.quote(a.ngId)
			+ ', created_at = ' + Sqlite.real(a.createdAt)
			+ ', access_json = ' + Db.quote(Sqlite.json(a.access))
			+ ', notifications_json = ' + Db.quote(Sqlite.json(a.notifications))
			+ ', friends_json = ' + Db.quote(Sqlite.json(a.friends))
			+ ', friend_requests_json = ' + Db.quote(Sqlite.json(a.friendRequests))
			+ ', ips_json = ' + Db.quote(Sqlite.json(a.ips));
	}

	/**
	 * The legacy insertion index. It is derived from the id (`u12` -> 12) so callers that only
	 * carry an Account struct still round-trip the ordering; new ids are always allocated before
	 * the struct is built.
	 */
	static function accountSeq(a:Account):Int {
		var parsed = null;
		if (a != null && a.id != null && a.id.length > 1 && a.id.charAt(0) == 'u') parsed = Std.parseInt(a.id.substr(1));
		return parsed == null ? 0 : parsed;
	}
}
