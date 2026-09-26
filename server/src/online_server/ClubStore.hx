package online_server;

import sys.FileSystem;

/**
 * Club storage (local JSON, <data-dir>/clubs.json). Points use one account pool, banners are
 * stored as base64, and there is no separate cache. Shares JsonStore's Mutex; never re-enter a
 * locking method.
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
	/** Page size for the club leaderboard. */
	public static inline var PAGE_SIZE:Int = 15;

	static var path:String = null;
	/** { seq:Int, clubs:Array<Club> } */
	static var db:Dynamic = null;

	public static function init(file:String):Void {
		path = file;
		JsonStore.lock(function() {
			var loaded = JsonStore.read(path, null);
			if (loaded == null || loaded.clubs == null) {
				loaded = { seq: 0, clubs: [] };
			}
			db = loaded;
			migrateU();
			if (!FileSystem.exists(path)) JsonStore.write(path, db);
			return true;
		});
	}

	public static function storagePath():String return path;

	static function allU():Array<Club> return cast db.clubs;

	/** Fills in the three arrays for legacy / hand-edited JSON (the caller decides whether to write). */
	static function migrateU():Bool {
		var changed = false;
		for (c in allU()) {
			if (c.members == null) {
				c.members = [];
				changed = true;
			}
			if (c.pending == null) {
				c.pending = [];
				changed = true;
			}
			if (c.leaders == null) {
				c.leaders = [];
				changed = true;
			}
		}
		return changed;
	}

	static function byTagU(tag:String):Club {
		if (tag == null) return null;
		for (c in allU()) if (c.tag == tag) return c;
		return null;
	}

	static function byMemberIdU(id:String):Club {
		if (id == null) return null;
		for (c in allU()) if (c.members != null && c.members.indexOf(id) >= 0) return c;
		return null;
	}

	public static function byTag(tag:String):Club return JsonStore.lock(function() return byTagU(tag));

	public static function byMemberId(id:String):Club return JsonStore.lock(function() return byMemberIdU(id));

	/** Club tag of a member; null when the account is in no club. */
	public static function tagOf(id:String):String {
		var c = byMemberId(id);
		return c == null ? null : c.tag;
	}

	public static function count():Int return JsonStore.lock(function() return allU().length);

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
		return JsonStore.lock(function() {
			var nm = name == null ? "" : StringTools.trim(name);
			if (nm.length > 20) return { club: null, error: "Name too long!" };
			var terr = tagFormatError(rawTag);
			if (terr != null) return { club: null, error: terr };
			var t = upperTag(rawTag);
			if (byTagU(t) != null) return { club: null, error: "Tag taken!" };
			for (c in allU()) if (c.name == nm) return { club: null, error: "Name taken!" };

			db.seq = db.seq + 1;
			var club:Club = {
				id: "c" + Std.string(db.seq),
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
			allU().push(club);
			JsonStore.write(path, db);
			return { club: club, error: null };
		});
	}

	/** Requests to join a club. Returns an error message or null. */
	public static function requestJoin(tag:String, id:String):String {
		return JsonStore.lock(function() {
			var c = byTagU(tag);
			if (c == null) return "No club!";
			if (byMemberIdU(id) != null) return "You're already in a club!";
			if (c.pending.indexOf(id) >= 0) return "Already pending!";
			c.pending.push(id);
			JsonStore.write(path, db);
			return null;
		});
	}

	/** Accepts a pending join request. */
	public static function acceptJoin(tag:String, id:String):String {
		return JsonStore.lock(function() {
			var other = byMemberIdU(id);
			if (other != null) {
				// Clear the id from its current club's pending list before returning the error.
				if (other.pending.remove(id)) JsonStore.write(path, db);
				return "The user is already in a club!";
			}
			var c = byTagU(tag);
			if (c == null) return "No club!";
			if (c.pending.indexOf(id) < 0) return "The user hasn't sent a request!";
			c.pending.remove(id);
			c.members.push(id);
			JsonStore.write(path, db);
			return null;
		});
	}

	/** Rejects a pending join request. */
	public static function rejectJoin(tag:String, id:String):String {
		return JsonStore.lock(function() {
			var c = byTagU(tag);
			if (c == null) return "No club!";
			if (c.pending.indexOf(id) < 0) return "The user hasn't sent a request!";
			c.pending.remove(id);
			JsonStore.write(path, db);
			return null;
		});
	}

	/** Promotes a member to leader. */
	public static function promote(tag:String, id:String):String {
		return JsonStore.lock(function() {
			var c = byTagU(tag);
			if (c == null) return "No club!";
			if (c.members.indexOf(id) < 0) return "The user is not in a club!";
			if (c.leaders.indexOf(id) >= 0) return "The user is already a mod!";
			c.leaders.push(id);
			JsonStore.write(path, db);
			return null;
		});
	}

	/** Demotes a leader back to member. */
	public static function demote(tag:String, id:String):String {
		return JsonStore.lock(function() {
			var c = byTagU(tag);
			if (c == null) return "No club!";
			if (c.leaders.indexOf(id) < 0) return "The user is not a mod!";
			if (c.leaders.length == 1) return "A club can't have no leaders!";
			c.leaders.remove(id);
			JsonStore.write(path, db);
			return null;
		});
	}

	/**
	 * Last member leaving disbands the club; the last leader leaving promotes members[0].
	 */
	public static function removeMember(playerId:String):Bool {
		return JsonStore.lock(function() {
			var c = byMemberIdU(playerId);
			if (c == null) return false;
			c.members.remove(playerId);
			c.leaders.remove(playerId);
			c.pending.remove(playerId);
			JsonStore.write(path, db);
			if (c.members.length == 0) {
				removeU(c.tag);
				JsonStore.write(path, db);
				return true;
			}
			if (c.leaders.length == 0) {
				c.leaders.push(c.members[0]);
				JsonStore.write(path, db);
			}
			return true;
		});
	}

	static function removeU(tag:String):Void {
		var i = 0;
		while (i < allU().length) {
			if (allU()[i].tag == tag) allU().splice(i, 1);
			else i++;
		}
	}

	/** Deletes a club (admin/club/delete). */
	public static function delete(tag:String):Bool {
		return JsonStore.lock(function() {
			var before = allU().length;
			removeU(tag);
			var found = allU().length != before;
			if (found) JsonStore.write(path, db);
			return found;
		});
	}

	/** Edits a club; the 7-day tag-change cooldown is checked by Api, which owns the cooldown table. */
	public static function edit(tag:String, name:String, content:String, hue:Float, newTag:String):String {
		return JsonStore.lock(function() {
			var c = byTagU(tag);
			if (c == null) return "No club!";
			var nm = name == null ? "" : StringTools.trim(name);
			if (nm.length > 20) return "Name too long!";
			var terr = tagFormatError(newTag);
			if (terr != null) return terr;
			var t = upperTag(newTag);
			if (t != tag) {
				var other = byTagU(t);
				if (other != null && other != c) return "Tag taken!";
			}
			for (o in allU()) if (o != c && o.name == nm) return "Name taken!";
			c.name = nm;
			c.content = content;
			c.hue = hue;
			c.tag = t;
			JsonStore.write(path, db);
			return null;
		});
	}

	/** Sets club points; Api computes them from member accounts outside the lock. */
	public static function setPoints(tag:String, points:Float):Void {
		JsonStore.lock(function() {
			var c = byTagU(tag);
			if (c != null) {
				c.points = points;
				JsonStore.write(path, db);
			}
			return true;
		});
	}

	public static function setBanner(tag:String, base64:String, contentType:String):Bool {
		return JsonStore.lock(function() {
			var c = byTagU(tag);
			if (c == null) return false;
			c.banner = base64;
			c.bannerType = contentType;
			JsonStore.write(path, db);
			return true;
		});
	}

	// ------------------------------------------------------------------
	// leaderboard
	// ------------------------------------------------------------------

	static function sortedU():Array<Club> {
		var out = allU().copy();
		out.sort(function(a:Club, b:Club) {
			if (a.points < b.points) return 1;
			if (a.points > b.points) return -1;
			if (a.createdAt < b.createdAt) return 1;
			if (a.createdAt > b.createdAt) return -1;
			return 0;
		});
		return out;
	}

	public static function rank(tag:String):Int {
		return JsonStore.lock(function() {
			var s = sortedU();
			for (i in 0...s.length) if (s[i].tag == tag) return i + 1;
			return 0;
		});
	}

	public static function top(page:Int):Array<Club> {
		return JsonStore.lock(function() {
			var s = sortedU();
			var start = (page <= 0 ? 0 : page) * PAGE_SIZE;
			return s.slice(start, start + PAGE_SIZE);
		});
	}
}
