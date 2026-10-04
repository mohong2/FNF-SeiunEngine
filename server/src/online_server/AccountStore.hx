package online_server;

import online_server.db.AccountRepo;
import online_server.db.Db;

/**
 * Account storage facade: id + name + email + points/profile data, plus the credential state.
 *
 * Persistence moved from an in-memory JSON document rewritten in full to the SQLite repository in
 * online_server.db.AccountRepo. This class keeps the public surface identical for Api.hx /
 * ConsoleApi.hx / probe, but the internal rules changed where the user asked for it:
 *
 *  - Credentials are sessions. A login issues a new session row and deletes the account's previous
 *    ones, so the old token stops working at once. Only HMAC-SHA256(token) and an 8-character
 *    lookup prefix are stored; the plaintext token is returned exactly once, by
 *    issueCredentials/createOrGet/rotateToken, through Account.token.
 *  - An Account projected from the database has token == null. Callers authenticate with
 *    verifyToken() (constant time) instead of comparing plaintext.
 *  - Rows are written individually (UPDATE ... WHERE id = ...), never as a whole-document rewrite,
 *    and every multi-step mutation runs under the one storage mutex.
 */
typedef Account = {
	var id:String;
	var name:String;
	var email:String;
	/**
	 * Plaintext bearer token. Only set on the value returned by issueCredentials / createOrGet /
	 * rotateToken (the one moment the server legitimately holds it); always null on a projected
	 * account, because the database stores only its hash.
	 */
	var token:String;
	var points:Float;
	var avgAccuracy:Float;
	/** Number of scored submissions; avgAccuracy is maintained as an incremental mean over it. */
	var games:Int;
	var profileHue:Float;
	/** Second gradient hue for /api/user/info. No local setter, always null. */
	var ?profileHue2:Null<Float>;
	/** Country for /api/user/info. No local setter, always null. */
	var ?country:Null<String>;
	/** Last-active timestamp (ms), refreshed on every /api/account/me call. */
	var ?lastActive:Null<Float>;
	/** When the current session's credential was issued (ms). */
	var ?tokenIssuedAt:Null<Float>;
	/** Credential expiry (ms); null = never expires (legacy accounts lack this field). */
	var ?tokenExpiresAt:Null<Float>;
	/** Effective credential TTL for this account (minutes); null / 0 = never expires. */
	var ?tokenTtlMinutes:Null<Int>;
	/** Self-introduction for /api/account/profile/set; capped at 1500 characters. */
	var ?bio:Null<String>;
	/** Notification list for /api/account/notifications. */
	var ?notifications:Array<Dynamic>;
	/** Friend account ids. */
	var ?friends:Array<String>;
	/** Incoming pending friend requests (account ids). */
	var ?friendRequests:Array<String>;
	/** The ng field of /api/user/details; written by /api/account/link/newgrounds. */
	var ?ngUrl:Null<String>;
	/** Newgrounds user id. One ngId can bind only one local account. */
	var ?ngId:Null<String>;
	/** Role name. */
	var ?role:Null<String>;
	/** Source IP. */
	var ?ips:Array<String>;
	var access:Array<String>;
	var createdAt:Float;
}

class AccountStore {
	/**
	 * Access table for the default Member role (default = true).
	 * Api.hx's four-step checkAccess uses it for per-path authorization; --admin-email is ["*"].
	 */
	public static var MEMBER_ACCESS:Array<String> = [
		"/api/sez",
		"/api/account/*",
		"/api/song/*",
		"/api/score/*",
		"/api/user/*",
		"/api/club/*",
		"/api/mod/fav",
		"room.auth"
	];

	/*
	 * The four roles (Admin / Moderator / Helper / Member) plus Banned.
	 * Roles are pre-expanded into flat access tables so hasAccess queries one table. Only
	 * Member is default, so a missing or invalid role falls back to Member.
	 */
	public static var HELPER_ACCESS:Array<String> = MEMBER_ACCESS.concat([
		"/api/admin/score/delete",
		"/api/admin/user/warn",
		"/api/admin/user/warn/delete",
		"/api/admin/user/warn/list",
		"/api/admin/user/ips",
		"/api/admin/report/*",
		"/api/mod/dl/*",
		"/api/mod/submit",
		"/api/mod/edit",
		"/admin"
	]);
	public static var MODERATOR_ACCESS:Array<String> = HELPER_ACCESS.concat([
		"/api/admin/user/set/email",
		"/api/admin/user/ban",
		"/api/admin/user/grant",
		"/api/admin/user/rename",
		"/api/admin/user/notify",
		"/api/admin/players",
		"/api/admin/club/delete",
		"/api/admin/club/rename",
		"/api/admin/logs",
		"/api/admin/logs/process",
		"/api/admin/user/delete",
		"/api/mod/delete",
		"command.announce",
		"admin.club.edit",
		"mod.warns"
	]);
	/** Admin is the root role; its access table is ["*"]. */
	public static var ADMIN_ACCESS:Array<String> = ["*"];

	public static inline var DEFAULT_ROLE:String = "Member";

	/**
	 * Role priority. Admin 9999 is root; a Moderator may only act on a strictly lower priority
	 * (403 when priorityOf(target) >= priorityOf(requesting player)).
	 */
	public static function priorityOf(role:String):Int {
		return switch (role) {
			case "Admin": 9999;
			case "Moderator": 2;
			case "Helper": 1;
			case "Banned": -1;
			case _: 0;
		}
	}

	/** Normalizes a role name: null / unknown -> Member; case-insensitive. */
	public static function normalizeRole(role:String):String {
		if (role == null) return DEFAULT_ROLE;
		return switch (role.toLowerCase()) {
			case "admin": "Admin";
			case "moderator": "Moderator";
			case "helper": "Helper";
			case "banned": "Banned";
			case "member": "Member";
			case _: DEFAULT_ROLE;
		}
	}

	/** Role -> expanded access table. */
	public static function accessForRole(role:String):Array<String> {
		return switch (normalizeRole(role)) {
			case "Admin": ADMIN_ACCESS.copy();
			case "Moderator": MODERATOR_ACCESS.copy();
			case "Helper": HELPER_ACCESS.copy();
			case "Banned": [];
			case _: MEMBER_ACCESS.copy();
		}
	}

	/**
	 * Console: override one role's access table (config.toml [permissions]).
	 * Banned stays empty by design.
	 */
	public static function setAccessForRole(role:String, patterns:Array<String>):Void {
		var list = patterns == null ? [] : patterns.copy();
		switch (normalizeRole(role)) {
			case "Admin": ADMIN_ACCESS = list;
			case "Moderator": MODERATOR_ACCESS = list;
			case "Helper": HELPER_ACCESS = list;
			case "Banned":
			case _: MEMBER_ACCESS = list;
		}
	}

	/**
	 * Console: re-derive every account's access array from its role.
	 * Accounts carrying "*" (the --admin-email root) are skipped so a bad permission
	 * table can never lock the operator out.
	 */
	public static function reapplyRoleAccess():Int {
		return Db.lock(function() {
			var changed = 0;
			for (a in AccountRepo.all()) {
				if (a.access != null && a.access.indexOf("*") >= 0) continue;
				var next = accessForRole(a.role);
				if (a.access == null || a.access.join(",") != next.join(",")) {
					a.access = next;
					AccountRepo.update(a);
					changed++;
				}
			}
			return changed;
		});
	}

	/** Legacy JSON path, kept because the console displays it through storagePath(). */
	static var path:String = null;

	public static function init(file:String):Void {
		path = file;
		// Opens (and migrates) <data-dir>/seiun.sqlite3; every other Store.init reuses this handle.
		Db.openFor(file);
		Db.lock(function() return migrateU());
	}

	/**
	 * Brings legacy accounts into the current model: an empty access array has no "Banned"
	 * meaning here (only Member / Admin exist), so it becomes Member; a missing lastActive
	 * falls back to createdAt. Rows are written only when something actually changed.
	 */
	static function migrateU():Bool {
		var changed = false;
		for (a in AccountRepo.all()) {
			var dirty = false;
			if (a.access == null || a.access.length == 0) {
				// Banned accounts already have an empty access table (not legacy data) and must not become Member.
				if (normalizeRole(a.role) != "Banned") {
					a.access = accessForRole(a.role);
					dirty = true;
				}
			}
			if (a.lastActive == null) {
				a.lastActive = a.createdAt;
				dirty = true;
			}
			if (a.bio == null) {
				a.bio = "";
				dirty = true;
			}
			if (a.role == null) {
				a.role = (a.access != null && a.access.indexOf("*") >= 0) ? "Admin" : DEFAULT_ROLE;
				dirty = true;
			}
			if (dirty) {
				AccountRepo.update(a);
				changed = true;
			}
		}
		if (changed) Log.info("accounts", "migrated legacy account defaults", { rows: AccountRepo.count() });
		return changed;
	}

	public static function storagePath():String return path;

	public static function byId(id:String):Account return Db.lock(function() return AccountRepo.byId(id));
	public static function byEmail(email:String):Account return Db.lock(function() return AccountRepo.byEmail(email));
	public static function byName(name:String):Account return Db.lock(function() return AccountRepo.byName(name));

	/**
	 * /api/user/info needs a case-sensitive exact lookup, unlike the case-insensitive byName
	 * used for rename-collision checks.
	 */
	public static function byNameExact(name:String):Account {
		return Db.lock(function() return AccountRepo.byNameExact(name));
	}

	/** Refreshes lastActive; /api/account/me calls this on every request. */
	public static function touch(a:Account, now:Float):Void {
		if (a == null) return;
		Db.lock(function() {
			var cur = AccountRepo.byId(a.id);
			if (cur == null) return false;
			cur.lastActive = now;
			AccountRepo.update(cur);
			return true;
		});
	}

	/**
	 * Rank by points descending (1-based); 0 when not found. There are no keys/category tiers
	 * here (a single points pool), so those filters do not exist.
	 */
	public static function rankOf(id:String, byAccuracy:Bool = false):Int {
		return Db.lock(function() {
			if (id == null) return 0;
			var accounts = AccountRepo.all();
			accounts.sort(function(a:Account, b:Account) {
				var va = byAccuracy ? a.avgAccuracy : a.points;
				var vb = byAccuracy ? b.avgAccuracy : b.points;
				if (va < vb) return 1;
				if (va > vb) return -1;
				return 0;
			});
			for (i in 0...accounts.length) if (accounts[i].id == id) return i + 1;
			return 0;
		});
	}

	public static function count():Int return Db.lock(function() return AccountRepo.count());

	/** Account count / snapshot to iterate (used by tests and /api/top/players). */
	public static function snapshot():Array<Account> return Db.lock(function() return AccountRepo.all());

	/**
	 * Bearer authentication. The presented token is hashed and compared in constant time against
	 * the account's current session; plaintext is never read back from storage.
	 */
	public static function verifyToken(a:Account, token:String):Bool {
		if (a == null) return false;
		return Db.lock(function() return AccountRepo.verifyToken(a.id, token));
	}

	/** Basic auth: id and token must both match. */
	public static function auth(id:String, token:String):Account {
		return Db.lock(function() {
			var a = AccountRepo.byId(id);
			if (a == null || token == null) return null;
			return AccountRepo.verifyToken(id, token) ? a : null;
		});
	}

	/** Field shape of a new account; shared by createOrGet / issueCredentials so they cannot drift. */
	static function newAccountU(name:String, email:String):Account {
		var seq = AccountRepo.nextSeq();
		var newName = ServerConfig.repairUtf8((name != null && StringTools.trim(name) != "") ? StringTools.trim(name) : ('player' + seq));
		var now = Date.now().getTime();
		var a:Account = {
			id: 'u' + seq,
			name: newName,
			email: email,
			token: null,
			points: 0,
			avgAccuracy: 0,
			games: 0,
			profileHue: 250,
			profileHue2: null,
			country: null,
			lastActive: now,
			bio: "",
			notifications: [],
			friends: [],
			friendRequests: [],
			ngUrl: null,
			ngId: null,
			role: DEFAULT_ROLE,
			ips: [],
			access: MEMBER_ACCESS.copy(),
			createdAt: now
		};
		AccountRepo.insert(a);
		return a;
	}

	/**
	 * Get-or-create shared by register / login: an existing email is returned (token refreshed,
	 * name filled in), otherwise a new account is created. The returned token is valid.
	 */
	public static function createOrGet(name:String, email:String):Account {
		return Db.lock(function() {
			var existing = AccountRepo.byEmail(email);
			if (existing != null) {
				if (name != null && StringTools.trim(name) != "") {
					existing.name = ServerConfig.repairUtf8(StringTools.trim(name));
					AccountRepo.update(existing);
				}
				var ttl = existing.tokenTtlMinutes == null ? 0 : existing.tokenTtlMinutes;
				return issueFor(existing, ttl);
			}
			return issueFor(newAccountU(name, email), 0);
		});
	}

	/**
	 * Shared by login / register / refresh: get-or-create, rotate the credential and store the TTL
	 * in one transaction, because login already writes the token and the TTL must ride along.
	 * ttlMinutes <= 0 means no expiry (session expires_at = NULL).
	 */
	public static function issueCredentials(name:String, email:String, ttlMinutes:Int):Account {
		return Db.lock(function() {
			var a = AccountRepo.byEmail(email);
			if (a == null) {
				a = newAccountU(name, email);
			} else if (name != null && StringTools.trim(name) != "") {
				a.name = StringTools.trim(name);
				AccountRepo.update(a);
			}
			return issueFor(a, ttlMinutes);
		});
	}

	/** Issues a session for an account and returns a fresh projection carrying the one-time plaintext token. */
	static function issueFor(a:Account, ttlMinutes:Int):Account {
		var token = Crypto.randomHexChars(64);
		AccountRepo.issueSession(a.id, token, ttlMinutes, Date.now().getTime(), null);
		var fresh = AccountRepo.byId(a.id);
		if (fresh == null) fresh = a;
		fresh.token = token;
		return fresh;
	}

	/** Revokes the current session and issues a new token; returns the new plaintext token. */
	public static function rotateToken(a:Account):String {
		return Db.lock(function() {
			var cur = AccountRepo.byId(a.id);
			if (cur == null) return null;
			var ttl = cur.tokenTtlMinutes == null ? 0 : cur.tokenTtlMinutes;
			var token = Crypto.randomHexChars(64);
			AccountRepo.issueSession(a.id, token, ttl, Date.now().getTime(), null);
			return token;
		});
	}

	/** Renames an account. Returns the new name, or null on a taken / empty name. */
	public static function rename(a:Account, name:String):String {
		return Db.lock(function() {
			var cur = AccountRepo.byId(a.id);
			if (cur == null || name == null || StringTools.trim(name) == "") return null;
			var trimmed = StringTools.trim(name);
			var other = AccountRepo.byName(trimmed);
			if (other != null && other.id != cur.id) return null;
			cur.name = trimmed;
			AccountRepo.update(cur);
			return cur.name;
		});
	}

	public static function setEmail(a:Account, email:String):Bool {
		return Db.lock(function() {
			var cur = AccountRepo.byId(a.id);
			if (cur == null || email == null || email.indexOf('@') < 0) return false;
			cur.email = ServerConfig.repairUtf8(email);
			AccountRepo.update(cur);
			return true;
		});
	}

	/**
	 * Unbinds any other account holding the same ngId (ngId/ngUrl set to null) before writing
	 * this one; passing null unlinks.
	 */
	public static function linkNewgrounds(a:Account, ngId:String, ngUrl:String):Bool {
		return Db.lock(function() {
			var cur = AccountRepo.byId(a.id);
			if (cur == null) return false;
			if (ngId != null) {
				for (other in AccountRepo.all()) {
					if (other.id != cur.id && other.ngId != null && other.ngId == ngId) {
						other.ngId = null;
						other.ngUrl = null;
						AccountRepo.update(other);
					}
				}
			}
			cur.ngId = ngId;
			cur.ngUrl = ngUrl;
			AccountRepo.update(cur);
			return true;
		});
	}

	/** Finds the account bound to an ngId (used to prevent double binding). */
	public static function byNgId(ngId:String):Account {
		return Db.lock(function() return AccountRepo.byNgId(ngId));
	}

	/** Adds submission stats (points / incremental mean accuracy) for /api/top/players. */
	public static function addStats(a:Account, points:Float, accuracy:Float):Void {
		Db.lock(function() {
			var cur = AccountRepo.byId(a.id);
			if (cur == null) return false;
			cur.points = cur.points + points;
			cur.games = cur.games + 1;
			cur.avgAccuracy = cur.avgAccuracy + (accuracy - cur.avgAccuracy) / cur.games;
			AccountRepo.update(cur);
			return true;
		});
	}

	public static function remove(a:Account):Bool {
		return Db.lock(function() {
			var cur = AccountRepo.byId(a.id);
			if (cur == null) return false;
			return AccountRepo.remove(cur.id);
		});
	}

	// ------------------------------------------------------------------
	// Profile / notifications / search / stats recomputation
	// ------------------------------------------------------------------

	/**
	 * Landing point for /api/account/profile/set. Returns null on success, otherwise a
	 * client-facing error message. Only < and > are stripped; nothing here renders the bio as
	 * HTML, so no fuller sanitizer is needed.
	 */
	public static function setProfile(a:Account, bio:String, hue:Float, country:String, hue2:Float):Null<String> {
		return Db.lock(function() {
			var cur = AccountRepo.byId(a.id);
			if (cur == null) return "No such account";
			var text = ServerConfig.repairUtf8(bio == null ? "" : bio);
			// 1500 CHARACTERS: String.length counts UTF-8 bytes on neko/hxcpp, which capped a
			// Chinese bio at 500 characters.
			if (ServerConfig.utf8Length(text) > 1500) return "Your bio reaches 1500 characters!";
			cur.bio = StringTools.replace(StringTools.replace(text, "<", ""), ">", "");
			cur.profileHue = clampHue(hue);
			// hue2 stays null below 500 points.
			cur.profileHue2 = cur.points < 500 ? null : clampHue(hue2);
			cur.country = validCountry(country);
			AccountRepo.update(cur);
			return null;
		});
	}

	static function clampHue(v:Float):Float {
		if (v > 360) return 360;
		if (v < 0) return 0;
		return v;
	}

	/**
	 * Minimal equivalent of an ISO-3166-1 alpha-2 whitelist: exactly two letters are accepted
	 * (uppercased); anything else, including an empty string, becomes null (no country shown).
	 */
	static function validCountry(code:String):String {
		if (code == null) return null;
		var c = StringTools.trim(code).toUpperCase();
		if (c.length != 2) return null;
		for (i in 0...2) {
			var ch = c.charCodeAt(i);
			if (ch < 65 || ch > 90) return null;
		}
		return c;
	}

	/** Full list for /api/account/notifications. */
	public static function notificationsOf(a:Account):Array<Dynamic> {
		return Db.lock(function() {
			var cur = AccountRepo.byId(a.id);
			if (cur == null || cur.notifications == null) return [];
			return cur.notifications.copy();
		});
	}

	public static function notificationCount(a:Account):Int {
		return Db.lock(function() {
			var cur = AccountRepo.byId(a.id);
			return (cur == null || cur.notifications == null) ? 0 : cur.notifications.length;
		});
	}

	/** /api/account/notifications/delete/:id. Returns false when the account has no such notification. */
	public static function deleteNotification(a:Account, id:String):Bool {
		return Db.lock(function() {
			var cur = AccountRepo.byId(a.id);
			if (cur == null || cur.notifications == null || id == null || id == "") return false;
			var list:Array<Dynamic> = cur.notifications;
			var i = 0;
			while (i < list.length) {
				var n = list[i];
				if (n != null && Std.string(Reflect.field(n, "id")) == id) {
					list.splice(i, 1);
					AccountRepo.update(cur);
					return true;
				}
				i++;
			}
			return false;
		});
	}

	/**
	 * /api/search/users. Case-insensitive name contains match, take 50 / skip 50*page; role uses
	 * the local lowercase tier names (same as userInfo).
	 */
	public static function searchUsers(q:String, page:Int):Array<Dynamic> {
		return Db.lock(function() {
			var out:Array<Dynamic> = [];
			var needle = q == null ? "" : q.toLowerCase();
			var skip = (page <= 0 ? 0 : page) * 50;
			for (a in AccountRepo.all()) {
				if (a.name == null || a.name.toLowerCase().indexOf(needle) < 0) continue;
				if (skip > 0) {
					skip--;
					continue;
				}
				var role = normalizeRole(a.role);
				out.push({ name: a.name, role: (role == "Admin" ? "admin" : role.toLowerCase()) });
				if (out.length >= 50) break;
			}
			return out;
		});
	}

	/**
	 * Recomputes player stats after /api/score/delete. LeaderboardStore computes the values
	 * under its own lock and passes them in: the whole storage layer shares one Mutex, so this
	 * class's public methods cannot be called from inside another store's lock callback.
	 */
	public static function setStats(a:Account, points:Float, accuracy:Float, games:Int):Void {
		Db.lock(function() {
			var cur = AccountRepo.byId(a.id);
			if (cur == null) return false;
			cur.points = points;
			cur.avgAccuracy = accuracy;
			cur.games = games;
			AccountRepo.update(cur);
			return true;
		});
	}

	// ------------------------------------------------------------------
	// Friends + notifications
	// ------------------------------------------------------------------

	/**
	 * The three /api/account/friends datasets computed in one pass (same lock = consistent
	 * snapshot): friends (name + hue), requests (incoming) and pending (outgoing). Api adds
	 * ONLINE/Offline.
	 */
	public static function friendsOverview(a:Account):FriendsOverview {
		return Db.lock(function() {
			var friends:Array<FriendEntry> = [];
			var requests:Array<String> = [];
			var pending:Array<String> = [];
			var all = AccountRepo.all();
			var index = new Map<String, Account>();
			for (x in all) index.set(x.id, x);
			var cur = index.get(a.id);
			if (cur == null) return { friends: friends, requests: requests, pending: pending };

			if (cur.friends != null) {
				for (id in cur.friends) {
					var f = index.get(id);
					if (f == null) continue;
					friends.push({ name: f.name, hue: f.profileHue, hue2: f.profileHue2 });
				}
			}
			if (cur.friendRequests != null) {
				for (id in cur.friendRequests) {
					var r = index.get(id);
					if (r != null) requests.push(r.name);
				}
			}
			for (other in all) {
				if (other.id == cur.id || other.friendRequests == null) continue;
				if (other.friendRequests.indexOf(cur.id) >= 0) pending.push(other.name);
			}
			return { friends: friends, requests: requests, pending: pending };
		});
	}

	/** /api/user/details' friends as names. */
	public static function friendNames(a:Account):Array<String> {
		return Db.lock(function() {
			var out:Array<String> = [];
			var cur = AccountRepo.byId(a.id);
			if (cur == null || cur.friends == null) return out;
			for (id in cur.friends) {
				var f = AccountRepo.byId(id);
				if (f != null) out.push(f.name);
			}
			return out;
		});
	}

	/**
	 * /api/user/details' canFriend: true when the target's incoming requests do not contain the
	 * viewer. A null viewer yields true.
	 */
	public static function canFriend(a:Account, viewerId:String):Bool {
		return Db.lock(function() {
			var cur = AccountRepo.byId(a.id);
			if (cur == null || cur.friendRequests == null) return true;
			return viewerId == null || cur.friendRequests.indexOf(viewerId) < 0;
		});
	}

	/**
	 * /api/user/friends/request, fully inside the lock; the result code drives Api's
	 * notifications: "already" -> 400, "mutual" (add both ways + clear both requests),
	 * "duplicate" (200 without notifying), "sent" (write into to.friendRequests), "error".
	 */
	public static function addFriendRequest(from:Account, to:Account):String {
		return Db.lock(function() {
			var user = AccountRepo.byId(from.id);
			var target = AccountRepo.byId(to.id);
			if (user == null || target == null) return "error";
			if (user.friends != null && user.friends.indexOf(target.id) >= 0) return "already";

			// They already asked me: become friends and clear both pending requests.
			if (user.friendRequests != null && user.friendRequests.indexOf(target.id) >= 0) {
				user.friendRequests.remove(target.id);
				if (user.friends == null) user.friends = [];
				if (user.friends.indexOf(target.id) < 0) user.friends.push(target.id);
				AccountRepo.update(user);

				if (target.friendRequests != null) target.friendRequests.remove(user.id);
				if (target.friends == null) target.friends = [];
				if (target.friends.indexOf(user.id) < 0) target.friends.push(user.id);
				AccountRepo.update(target);
				return "mutual";
			}

			// I already sent one: report a duplicate without notifying.
			if (target.friendRequests != null && target.friendRequests.indexOf(user.id) >= 0) return "duplicate";

			if (target.friendRequests == null) target.friendRequests = [];
			target.friendRequests.push(user.id);
			AccountRepo.update(target);
			return "sent";
		});
	}

	/**
	 * /api/user/friends/remove. Note the argument direction: target is the person to remove and
	 * self is the authenticated caller. self.id must be in target.friends, otherwise this
	 * returns false ("Not on friend list", 400).
	 */
	public static function removeFriendBetween(target:Account, self:Account):Bool {
		return Db.lock(function() {
			var me = AccountRepo.byId(target.id);
			var other = AccountRepo.byId(self.id);
			if (me == null || other == null) return false;
			if (me.friends == null || me.friends.indexOf(other.id) < 0) return false;

			me.friends.remove(other.id);
			AccountRepo.update(me);
			if (other.friends != null) {
				other.friends.remove(me.id);
				AccountRepo.update(other);
			}
			return true;
		});
	}

	/**
	 * Landing point for sendNotification: writes into the target account's notifications (newest
	 * first) and returns the new notification (Api pushes it over WS). id is a random 24-char hex
	 * string; date is an ISO string.
	 */
	public static function addNotification(a:Account, title:String, content:String, image:String, href:String):Dynamic {
		return Db.lock(function() {
			var cur = AccountRepo.byId(a.id);
			if (cur == null) return null;
			if (cur.notifications == null) cur.notifications = [];
			var notif:Dynamic = {
				id: JsonStore.randomHex(24),
				date: JsonStore.isoNow(),
				title: ServerConfig.repairUtf8(title),
				content: ServerConfig.repairUtf8(content),
				image: ServerConfig.repairUtf8(image),
				href: ServerConfig.repairUtf8(href)
			};
			cur.notifications.unshift(notif);
			AccountRepo.update(cur);
			return notif;
		});
	}

	// ------------------------------------------------------------------
	// Roles / bans / IPs / admin rename and email change
	// ------------------------------------------------------------------

	/**
	 * A missing player or an unchanged role returns false (the admin endpoint answers 400). Also
	 * refreshes the account's flattened access table.
	 */
	public static function setRole(a:Account, role:String):Bool {
		return Db.lock(function() {
			var cur = AccountRepo.byId(a.id);
			if (cur == null) return false;
			var normalized = normalizeRole(role);
			if (cur.role == normalized) return false;
			cur.role = normalized;
			cur.access = accessForRole(normalized);
			AccountRepo.update(cur);
			return true;
		});
	}

	/**
	 * Grants the root access table and Admin role in one row update. Replaces the old
	 * "mutate the live object, then persist()" pattern used by Api.applyAdmin: projected accounts
	 * are detached values now, so the write has to be explicit.
	 */
	public static function grantRootAccess(a:Account):Bool {
		if (a == null) return false;
		return Db.lock(function() {
			var cur = AccountRepo.byId(a.id);
			if (cur == null) return false;
			cur.access = ADMIN_ACCESS.copy();
			cur.role = "Admin";
			AccountRepo.update(cur);
			return true;
		});
	}

	/** Ban check, used by both the login and room-join gates. */
	public static function isBanned(a:Account):Bool {
		return a != null && normalizeRole(a.role) == "Banned";
	}

	/** Reason written on the second bio line by setBanRole; empty string when absent. */
	public static function banReasonOf(a:Account):String {
		if (a == null || a.bio == null) return "";
		var idx = a.bio.indexOf("Reason: ");
		return idx < 0 ? "" : StringTools.trim(a.bio.substr(idx + "Reason: ".length));
	}

	/** Full message shown to a banned player (shared by login 403 and join 5006). */
	public static function banMessage(a:Account):String {
		var reason = banReasonOf(a);
		return "This account was banned by a moderator!" + (reason == "" ? "" : ("\nReason: " + reason));
	}

	/** Admin ban/unban: sets the role and access table. */
	public static function setBanRole(a:Account, to:Bool, reason:String):Bool {
		return Db.lock(function() {
			var cur = AccountRepo.byId(a.id);
			if (cur == null) return false;
			cur.role = to ? "Banned" : DEFAULT_ROLE;
			cur.access = accessForRole(cur.role);
			if (to) {
				cur.bio = "This account was banned by a moderator!"
					+ (reason == null ? "" : ("\nReason: " + ServerConfig.repairUtf8(reason)));
				// A ban clears the player's stats.
				cur.points = 0;
				cur.avgAccuracy = 0;
				cur.games = 0;
			}
			AccountRepo.update(cur);
			return true;
		});
	}

	/**
	 * Only new IPs are recorded, and the row is not rewritten when the IP already exists.
	 * Loopback addresses are skipped.
	 */
	public static function recordIp(a:Account, ip:String):Void {
		if (a == null || ip == null || ip == "") return;
		if (ip == "127.0.0.1" || ip == "::1" || ip == "::ffff:127.0.0.1" || ip == "0:0:0:0:0:0:0:1") return;
		Db.lock(function() {
			var cur = AccountRepo.byId(a.id);
			if (cur == null) return false;
			if (cur.ips == null) cur.ips = [];
			if (cur.ips.indexOf(ip) >= 0) return false;
			cur.ips.push(ip);
			AccountRepo.update(cur);
			return true;
		});
	}

	/** /api/admin/user/ips: ids of other accounts sharing any IP. */
	public static function sameIpIds(a:Account):Array<String> {
		if (a == null) return [];
		return Db.lock(function() return AccountRepo.sameIpIds(a.id));
	}

	/** Maps an id list to names; unknown ids are skipped. */
	public static function namesOf(ids:Array<String>):Array<String> {
		return Db.lock(function() return AccountRepo.namesOf(ids));
	}

	/**
	 * /api/admin/user/data. Token and access are omitted (credentials and the internal permission
	 * table need not go to the admin UI); role is normalized.
	 */
	public static function viewOf(a:Account):Dynamic {
		return Db.lock(function() {
			var cur = AccountRepo.byId(a.id);
			if (cur == null) return null;
			return {
				id: cur.id,
				name: cur.name,
				email: cur.email,
				role: normalizeRole(cur.role),
				joined: JsonStore.isoOf(cur.createdAt),
				lastActive: JsonStore.isoOf(cur.lastActive),
				bio: cur.bio,
				profileHue: cur.profileHue,
				profileHue2: cur.profileHue2,
				country: cur.country,
				points: cur.points,
				avgAccuracy: cur.avgAccuracy,
				games: cur.games,
				ips: cur.ips,
				friends: cur.friends,
				friendRequests: cur.friendRequests,
				ngUrl: cur.ngUrl
			};
		});
	}

	/**
	 * /api/admin/user/set/email. Returns null on success, otherwise an error message (the admin
	 * endpoint answers 400).
	 */
	public static function setEmailById(id:String, email:String):Null<String> {
		return Db.lock(function() {
			var cur = AccountRepo.byId(id);
			if (cur == null) return "No player found with that name!";
			if (email == null || email.indexOf('@') < 0) return "Invalid Email Address!";
			var other = AccountRepo.byEmail(email);
			if (other != null && other.id != cur.id) return "Can't set the same email for two accounts!";
			cur.email = ServerConfig.repairUtf8(email);
			AccountRepo.update(cur);
			return null;
		});
	}

	/**
	 * /api/admin/user/rename. Allows letters/digits/underscore and 3..14 characters (the error
	 * message says max 15 but the check rejects anything over 14). Returns null on success.
	 */
	public static function renameById(id:String, name:String):Null<String> {
		return Db.lock(function() {
			var cur = AccountRepo.byId(id);
			if (cur == null) return "No player found with that name!";
			if (name == null) return "Your username contains invalid characters!";
			if (name.length < 3) return "Your username is too short! (min 3 characters)";
			if (name.length > 14) return "Your username is too long! (max 15 characters)";
			for (i in 0...name.length) {
				var c = name.charCodeAt(i);
				var ok = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95;
				if (!ok) return "Your username contains invalid characters!";
			}
			var other = AccountRepo.byName(name);
			if (other != null && other.id != cur.id) return "Player with that username exists!";
			cur.name = ServerConfig.repairUtf8(name);
			AccountRepo.update(cur);
			return null;
		});
	}

	/**
	 * Kept for call-site compatibility: row writes are immediate now, so there is no buffered
	 * document left to flush. Api.applyAdmin uses grantRootAccess() instead of mutating a
	 * projected account and relying on this method.
	 */
	public static function persist():Void {
		Log.debug("accounts", "persist() is a no-op; SQLite writes are immediate");
	}

	/** Name by id; null when not found. */
	public static function nameOf(id:String):String {
		return Db.lock(function() return AccountRepo.nameOf(id));
	}

	/** Account snapshot sorted by id ascending, for the admin player list / stats. */
	public static function roleOf(a:Account):String {
		return Db.lock(function() {
			var cur = AccountRepo.byId(a.id);
			return cur == null ? DEFAULT_ROLE : normalizeRole(cur.role);
		});
	}
}

/** Friend entry for /api/account/friends (name plus two gradient hues). */
typedef FriendEntry = {
	var name:String;
	var hue:Float;
	var hue2:Null<Float>;
}

/** The three datasets of friendsOverview (Api fills in status from its online list). */
typedef FriendsOverview = {
	var friends:Array<FriendEntry>;
	var requests:Array<String>;
	var pending:Array<String>;
}
