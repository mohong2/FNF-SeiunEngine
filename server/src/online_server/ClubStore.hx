package online_server;

import online_server.db.ClubRepo;
import online_server.db.Db;

/**
 * Club storage (SQLite: one row per club in the "clubs" table, statements in db/ClubRepo.hx).
 * Points use one account pool, banners are stored as base64 on the club's own row, and there is
 * no separate cache.
 *
 * This class is a facade: it keeps the legacy public API, validation rules, error strings, sort
 * order and id format (c1, c2, ...) exactly as the JSON implementation had them, and holds Db's
 * lock across each check-then-write so the legacy single-Mutex atomicity is preserved. The
 * repository projects rows into fresh Club structs; no DB row crosses a lock.
 */
typedef Club = {
	var id:String;
	var name:String;
	var tag:String;
	/** Member account ids. */
	var members:Array<String>;
	/** Pending join requests (account ids). */
	var pending:Array<String>;
	/** Leader account ids. */
	var leaders:Array<String>;
	var ?content:Null<String>;
	var ?hue:Null<Float>;
	/** Club points: sum of all member account points. */
	var points:Float;
	var createdAt:Float;
	/** Club banner (base64 PNG/JPEG/GIF), served by GET /api/club/banner/:tag. */
	var ?banner:Null<String>;
	var ?bannerType:Null<String>;
}

/** Result of a create / validation: error != null means rejected (club is only non-null on success). */
typedef ClubResult = {
	var club:Club;
	var error:String;
}

class ClubStore {
	/**
	 * Page size for the club leaderboard.
	 *
	 * Named PAGE_ROWS, not PAGE_SIZE: the Android NDK's <sys/user.h> defines PAGE_SIZE as a
	 * C macro, and hxcpp emits statics under their Haxe name, so a Haxe `static var PAGE_SIZE`
	 * becomes `static int PAGE_SIZE;` -> `static int 4096;` and the module fails to compile on
	 * Android (the in-client LAN host links server/src into the APK). Same reason
	 * PLAYER_PAGE_SIZE/SEARCH_PAGE_SIZE are safe: those are not macros.
	 */
	public static inline var PAGE_ROWS:Int = 15;

	static var path:String = null;

	/**
	 * Records the legacy storage path for storagePath() / diagnostics. Every store opens the same
	 * database (Db.openFor derives <data-dir>/seiun.sqlite3 from the legacy file name), so there is
	 * no per-store JSON file left to load or create.
	 */
	public static function init(file:String):Void {
		path = file;
		Db.openFor(file);
		// Adopt the highest stored seq so a pre-existing / imported row can never collide with a
		// newly generated "c<n>" id.
		Db.lock(function() {
			var stored = ClubRepo.maxSeq();
			if (stored > Db.seqOfLocked(ClubRepo.SEQ_KEY)) Db.metaSetLocked(ClubRepo.SEQ_KEY, Std.string(stored));
			return true;
		});
	}

	public static function storagePath():String return path;

	public static function byTag(tag:String):Club return Db.lock(function() return ClubRepo.byTag(tag));

	public static function byMemberId(id:String):Club return Db.lock(function() return ClubRepo.byMemberId(id));

	/** Club tag of a member; null when the account is in no club. */
	public static function tagOf(id:String):String {
		var c = byMemberId(id);
		return c == null ? null : c.tag;
	}

	public static function count():Int return Db.lock(function() return ClubRepo.count());

	// ------------------------------------------------------------------
	// tag validation
	// ------------------------------------------------------------------

	/** Returns an error message for an invalid tag, otherwise null (2..5 letters/digits). */
	public static function tagFormatError(raw:String):String {
		var t = raw == null ? "" : StringTools.trim(raw);
		if (t.length < 2 || t.length > 5) return "Too short/long tag!";
		for (i in 0...t.length) {
			var code = t.charCodeAt(i);
			var ok = (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
			if (!ok) return "Tag can't contain non latin letters!";
		}
		return null;
	}

	public static function upperTag(raw:String):String {
		return StringTools.trim(raw == null ? "" : raw).toUpperCase();
	}

	// ------------------------------------------------------------------
	// mutations
	// ------------------------------------------------------------------

	/** Creates a club. The points threshold is checked by Api, which has the account. */
	public static function create(ownerId:String, name:String, rawTag:String, points:Float):ClubResult {
		return Db.lock(function() {
			var nm = ServerConfig.repairUtf8(name == null ? "" : StringTools.trim(name));
			// 20 CHARACTERS: String.length counts UTF-8 bytes, which capped a CJK club name at 6.
			if (ServerConfig.utf8Length(nm) > 20) return { club: null, error: "Name too long!" };
			var terr = tagFormatError(rawTag);
			if (terr != null) return { club: null, error: terr };
			var t = upperTag(rawTag);
			if (ClubRepo.byTag(t) != null) return { club: null, error: "Tag taken!" };
			if (ClubRepo.nameTaken(nm)) return { club: null, error: "Name taken!" };

			var seq = Db.nextSeqLocked(ClubRepo.SEQ_KEY);
			var club:Club = {
				id: "c" + Std.string(seq),
				name: nm,
				tag: t,
				members: [ownerId],
				pending: [],
				leaders: [ownerId],
				content: null,
				hue: null,
				points: points,
				createdAt: Date.now().getTime(),
				banner: null,
				bannerType: null
			};
			ClubRepo.insert(club, seq);
			return { club: club, error: null };
		});
	}

	/** Requests to join a club. Returns an error message or null. */
	public static function requestJoin(tag:String, id:String):String {
		return Db.lock(function() {
			var c = ClubRepo.byTag(tag);
			if (c == null) return "No club!";
			if (ClubRepo.byMemberId(id) != null) return "You're already in a club!";
			if (c.pending.indexOf(id) >= 0) return "Already pending!";
			c.pending.push(id);
			ClubRepo.setPending(c.id, c.pending);
			return null;
		});
	}

	/** Accepts a pending join request. */
	public static function acceptJoin(tag:String, id:String):String {
		return Db.lock(function() {
			var other = ClubRepo.byMemberId(id);
			if (other != null) {
				// Clear the id from its current club's pending list before returning the error.
				if (other.pending.remove(id)) ClubRepo.setPending(other.id, other.pending);
				return "The user is already in a club!";
			}
			var c = ClubRepo.byTag(tag);
			if (c == null) return "No club!";
			if (c.pending.indexOf(id) < 0) return "The user hasn't sent a request!";
			c.pending.remove(id);
			c.members.push(id);
			ClubRepo.setMembers(c.id, c.members, c.pending, c.leaders);
			return null;
		});
	}

	/** Rejects a pending join request. */
	public static function rejectJoin(tag:String, id:String):String {
		return Db.lock(function() {
			var c = ClubRepo.byTag(tag);
			if (c == null) return "No club!";
			if (c.pending.indexOf(id) < 0) return "The user hasn't sent a request!";
			c.pending.remove(id);
			ClubRepo.setPending(c.id, c.pending);
			return null;
		});
	}

	/** Promotes a member to leader. */
	public static function promote(tag:String, id:String):String {
		return Db.lock(function() {
			var c = ClubRepo.byTag(tag);
			if (c == null) return "No club!";
			if (c.members.indexOf(id) < 0) return "The user is not in a club!";
			if (c.leaders.indexOf(id) >= 0) return "The user is already a mod!";
			c.leaders.push(id);
			ClubRepo.setMembers(c.id, c.members, c.pending, c.leaders);
			return null;
		});
	}

	/** Demotes a leader back to member. */
	public static function demote(tag:String, id:String):String {
		return Db.lock(function() {
			var c = ClubRepo.byTag(tag);
			if (c == null) return "No club!";
			if (c.leaders.indexOf(id) < 0) return "The user is not a mod!";
			if (c.leaders.length == 1) return "A club can't have no leaders!";
			c.leaders.remove(id);
			ClubRepo.setMembers(c.id, c.members, c.pending, c.leaders);
			return null;
		});
	}

	/**
	 * Last member leaving disbands the club; the last leader leaving promotes members[0].
	 */
	public static function removeMember(playerId:String):Bool {
		return Db.lock(function() {
			var c = ClubRepo.byMemberId(playerId);
			if (c == null) return false;
			c.members.remove(playerId);
			c.leaders.remove(playerId);
			c.pending.remove(playerId);
			if (c.members.length == 0) {
				ClubRepo.deleteById(c.id);
				return true;
			}
			if (c.leaders.length == 0) c.leaders.push(c.members[0]);
			ClubRepo.setMembers(c.id, c.members, c.pending, c.leaders);
			return true;
		});
	}

	/** Deletes a club (admin/club/delete). */
	public static function delete(tag:String):Bool {
		return Db.lock(function() return ClubRepo.deleteByTag(tag));
	}

	/** Edits a club; the 7-day tag-change cooldown is checked by Api, which owns the cooldown table. */
	public static function edit(tag:String, name:String, content:String, hue:Float, newTag:String):String {
		return Db.lock(function() {
			var c = ClubRepo.byTag(tag);
			if (c == null) return "No club!";
			var nm = ServerConfig.repairUtf8(name == null ? "" : StringTools.trim(name));
			// 20 CHARACTERS (same cap as create()).
			if (ServerConfig.utf8Length(nm) > 20) return "Name too long!";
			var terr = tagFormatError(newTag);
			if (terr != null) return terr;
			var t = upperTag(newTag);
			if (t != tag) {
				var other = ClubRepo.byTag(t);
				if (other != null && other.id != c.id) return "Tag taken!";
			}
			if (ClubRepo.nameTaken(nm, c.id)) return "Name taken!";
			ClubRepo.updateFields(c.id, nm, t, ServerConfig.repairUtf8(content), hue);
			return null;
		});
	}

	/** Sets club points; Api computes them from member accounts outside the lock. */
	public static function setPoints(tag:String, points:Float):Void {
		Db.lock(function() {
			var c = ClubRepo.byTag(tag);
			if (c != null) ClubRepo.setPoints(c.id, points);
			return true;
		});
	}

	public static function setBanner(tag:String, base64:String, contentType:String):Bool {
		return Db.lock(function() {
			var c = ClubRepo.byTag(tag);
			if (c == null) return false;
			ClubRepo.setBanner(c.id, base64, contentType);
			return true;
		});
	}

	// ------------------------------------------------------------------
	// leaderboard
	// ------------------------------------------------------------------

	public static function rank(tag:String):Int {
		return Db.lock(function() return ClubRepo.rankOf(tag));
	}

	public static function top(page:Int):Array<Club> {
		return Db.lock(function() {
			var start = (page <= 0 ? 0 : page) * PAGE_ROWS;
			return ClubRepo.page(start, PAGE_ROWS);
		});
	}
}
