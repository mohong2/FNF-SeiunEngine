package online_server.db;

import online_server.ClubStore.Club;

/**
 * SQLite repository for clubs (Migrations v1 "clubs" table).
 *
 * Every method expects the caller to already hold Db's lock (ClubStore does that through Db.lock)
 * and returns freshly built structs -- raw result rows never leave this class.
 *
 * Column notes:
 *  - seq keeps the legacy insertion order (the JSON layer appended to one array, and byMemberId
 *    plus the leaderboard tie-break still rely on that order, so reads are ORDER BY ... seq ASC).
 *  - members/pending/leaders are TEXT columns holding JSON arrays. They are never queried
 *    element-wise, so byMemberId scans the projected arrays instead of matching raw text.
 *  - banner/banner_type hold the base64 image on the club's own row, so a banner upload rewrites
 *    one column instead of the whole legacy JSON document.
 */
class ClubRepo {
	/** meta counter key holding the next club seq; ids keep the legacy shape c1, c2, ... */
	public static inline var SEQ_KEY:String = "clubs.seq";

	static inline var COLUMNS = 'id, seq, name, tag, content, hue, points, created_at, banner,'
		+ ' banner_type, members_json, pending_json, leaders_json';

	/** Leaderboard order: points desc, then newer createdAt first (legacy sortedU comparator). */
	static inline var ORDER = ' ORDER BY points DESC, created_at DESC, seq ASC, rowid ASC';

	// ------------------------------------------------------------------
	// Reads (caller holds the lock)
	// ------------------------------------------------------------------

	public static function count():Int {
		return Db.scalar('SELECT COUNT(*) FROM clubs', 0);
	}

	/** Highest stored seq; ClubStore.init uses it to adopt pre-existing / imported rows. */
	public static function maxSeq():Int {
		return Db.scalar('SELECT COALESCE(MAX(seq), 0) FROM clubs', 0);
	}

	public static function byTag(tag:String):Club {
		if (tag == null) return null;
		return toClub(Db.queryOne('SELECT ' + COLUMNS + ' FROM clubs WHERE tag = ' + Db.quote(tag)
			+ ' ORDER BY seq ASC, rowid ASC LIMIT 1'));
	}

	public static function byId(id:String):Club {
		if (id == null) return null;
		return toClub(Db.queryOne('SELECT ' + COLUMNS + ' FROM clubs WHERE id = ' + Db.quote(id) + ' LIMIT 1'));
	}

	/**
	 * First club (legacy array order) whose members list contains id. The scan reads only the two
	 * small columns per row; the full row (banner included) is fetched once for the match.
	 */
	public static function byMemberId(id:String):Club {
		if (id == null) return null;
		var rows = Db.query('SELECT id, members_json FROM clubs ORDER BY seq ASC, rowid ASC');
		for (r in rows) {
			var members = Sqlite.stringArray(r, 'members_json');
			if (members.indexOf(id) >= 0) return byId(Sqlite.str(r, 'id', null));
		}
		return null;
	}

	/** True when a club already uses this name (exceptId excludes the club being edited). */
	public static function nameTaken(name:String, ?exceptId:String):Bool {
		var sql = 'SELECT COUNT(*) FROM clubs WHERE name = ' + Db.quote(name);
		if (exceptId != null) sql += ' AND id <> ' + Db.quote(exceptId);
		return Db.scalar(sql, 0) > 0;
	}

	/** 1-based position in the leaderboard, 0 when the tag is unknown. */
	public static function rankOf(tag:String):Int {
		if (tag == null) return 0;
		var rows = Db.query('SELECT tag FROM clubs' + ORDER);
		for (i in 0...rows.length) {
			if (Sqlite.str(rows[i], 'tag', null) == tag) return i + 1;
		}
		return 0;
	}

	/** One leaderboard page; same ordering as rankOf. */
	public static function page(offset:Int, limit:Int):Array<Club> {
		if (limit <= 0 || offset < 0) return [];
		var rows = Db.query('SELECT ' + COLUMNS + ' FROM clubs' + ORDER
			+ ' LIMIT ' + Sqlite.int(limit) + ' OFFSET ' + Sqlite.int(offset));
		var out:Array<Club> = [];
		for (r in rows) out.push(toClub(r));
		return out;
	}

	// ------------------------------------------------------------------
	// Writes (caller holds the lock)
	// ------------------------------------------------------------------

	public static function insert(club:Club, seq:Int):Void {
		Db.exec('INSERT INTO clubs (' + COLUMNS + ') VALUES (' + values(club, seq) + ')');
	}

	public static function deleteById(id:String):Void {
		Db.exec('DELETE FROM clubs WHERE id = ' + Db.quote(id));
	}

	/** Removes every row carrying this tag (legacy removeU removed all matches). True if any did. */
	public static function deleteByTag(tag:String):Bool {
		if (tag == null) return false;
		if (Db.scalar('SELECT COUNT(*) FROM clubs WHERE tag = ' + Db.quote(tag), 0) == 0) return false;
		Db.exec('DELETE FROM clubs WHERE tag = ' + Db.quote(tag));
		return true;
	}

	/** Metadata edit: name, tag, content and hue (the columns Api's club/edit rewrites). */
	public static function updateFields(id:String, name:String, tag:String, content:Null<String>, hue:Null<Float>):Void {
		Db.exec('UPDATE clubs SET name = ' + Db.quote(name)
			+ ', tag = ' + Db.quote(tag)
			+ ', content = ' + Db.quote(content)
			+ ', hue = ' + Sqlite.real(hue)
			+ ' WHERE id = ' + Db.quote(id));
	}

	public static function setPending(id:String, pending:Array<String>):Void {
		Db.exec('UPDATE clubs SET pending_json = ' + Sqlite.jsonText(Db.connection(), pending, '[]')
			+ ' WHERE id = ' + Db.quote(id));
	}

	public static function setMembers(id:String, members:Array<String>, pending:Array<String>, leaders:Array<String>):Void {
		var conn = Db.connection();
		Db.exec('UPDATE clubs SET members_json = ' + Sqlite.jsonText(conn, members, '[]')
			+ ', pending_json = ' + Sqlite.jsonText(conn, pending, '[]')
			+ ', leaders_json = ' + Sqlite.jsonText(conn, leaders, '[]')
			+ ' WHERE id = ' + Db.quote(id));
	}

	public static function setPoints(id:String, points:Float):Void {
		Db.exec('UPDATE clubs SET points = ' + Sqlite.real(points) + ' WHERE id = ' + Db.quote(id));
	}

	public static function setBanner(id:String, banner:String, bannerType:String):Void {
		Db.exec('UPDATE clubs SET banner = ' + Db.quote(banner) + ', banner_type = ' + Db.quote(bannerType)
			+ ' WHERE id = ' + Db.quote(id));
	}

	// ------------------------------------------------------------------
	// Row projection / literal helpers
	// ------------------------------------------------------------------

	static function toClub(row:Dynamic):Club {
		if (row == null) return null;
		return {
			id: Sqlite.str(row, 'id', ''),
			name: Sqlite.str(row, 'name', ''),
			tag: Sqlite.str(row, 'tag', ''),
			members: Sqlite.stringArray(row, 'members_json'),
			pending: Sqlite.stringArray(row, 'pending_json'),
			leaders: Sqlite.stringArray(row, 'leaders_json'),
			content: Sqlite.str(row, 'content', null),
			hue: Sqlite.numOrNull(row, 'hue'),
			points: Sqlite.num(row, 'points', 0.0),
			createdAt: Sqlite.num(row, 'created_at', 0.0),
			banner: Sqlite.str(row, 'banner', null),
			bannerType: Sqlite.str(row, 'banner_type', null)
		};
	}

	static function values(club:Club, seq:Int):String {
		var conn = Db.connection();
		return Db.quote(club.id) + ', ' + Sqlite.int(seq) + ', ' + Db.quote(club.name)
			+ ', ' + Db.quote(club.tag) + ', ' + Db.quote(club.content)
			+ ', ' + Sqlite.real(club.hue) + ', ' + Sqlite.real(club.points) + ', ' + Sqlite.real(club.createdAt)
			+ ', ' + Db.quote(club.banner) + ', ' + Db.quote(club.bannerType)
			+ ', ' + Sqlite.jsonText(conn, club.members, '[]')
			+ ', ' + Sqlite.jsonText(conn, club.pending, '[]')
			+ ', ' + Sqlite.jsonText(conn, club.leaders, '[]');
	}
}
