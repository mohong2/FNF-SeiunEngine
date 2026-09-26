package online_server;

import sys.FileSystem;

/**
 * Account storage (local JSON): id + name + email + token (the password slot for Basic auth).
 * Non-admin access is empty and admins get ["*"]; there is no mail, so code validation accepts
 * any non-empty code (see Api.hx).
 */
typedef Account = {
	var id:String;
	var name:String;
	var email:String;
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
	/** When the credential was last issued (ms). */
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
	 * Access table for the default Member role (`default = true`).
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
		return JsonStore.lock(function() {
			var changed = 0;
			for (a in allU()) {
				if (a.access != null && a.access.indexOf("*") >= 0) continue;
				var next = accessForRole(a.role);
				if (a.access == null || a.access.join(",") != next.join(",")) {
					a.access = next;
					changed++;
				}
			}
			if (changed > 0) JsonStore.write(path, db);
			return changed;
		});
	}

	static var path:String = null;
	/** { seq:Int, accounts:Array<Account> } */
	static var db:Dynamic = null;

	public static function init(file:String):Void {
		path = file;
		JsonStore.lock(function() {
			var loaded = JsonStore.read(path, null);
			if (loaded == null || loaded.accounts == null) {
				loaded = { seq: 0, accounts: [] };
			}
			db = loaded;
			migrateU();
			if (!FileSystem.exists(path)) JsonStore.write(path, db);
			return true;
		});
	}

	/**
	 * Brings legacy accounts into the current model: an empty access array has no "Banned"
	 * meaning here (only Member / Admin exist), so it becomes Member; a missing lastActive
	 * falls back to createdAt. The file is written only when something actually changed.
	 */
	static function migrateU():Bool {
		var changed = false;
		for (a in allU()) {
			if (a.access == null || a.access.length == 0) {
				// Banned accounts already have an empty access table (not legacy data) and must not become Member.
				if (normalizeRole(a.role) != "Banned") {
					a.access = accessForRole(a.role);
					changed = true;
				}
			}
			if (a.lastActive == null) {
				a.lastActive = a.createdAt;
				changed = true;
			}
			if (a.bio == null) {
				a.bio = "";
				changed = true;
			}
			if (a.notifications == null) {
				a.notifications = [];
				changed = true;
			}
			if (a.friends == null) {
				a.friends = [];
				changed = true;
			}
			if (a.friendRequests == null) {
				a.friendRequests = [];
				changed = true;
			}
			// Legacy accounts infer their role from access (--admin-email accounts have access = "*").
			if (a.role == null) {
				a.role = (a.access != null && a.access.indexOf("*") >= 0) ? "Admin" : DEFAULT_ROLE;
				changed = true;
			}
			if (a.ips == null) {
				a.ips = [];
				changed = true;
			}
		}
		if (changed) JsonStore.write(path, db);
		return changed;
	}

	public static function storagePath():String return path;

	static inline function allU():Array<Account> return cast db.accounts;

	static function byIdU(id:String):Account {
		if (id == null) return null;
		for (a in allU()) if (a.id == id) return a;
		return null;
	}

	static function byEmailU(email:String):Account {
		if (email == null) return null;
		var needle = email.toLowerCase();
		for (a in allU()) if (a.email != null && a.email.toLowerCase() == needle) return a;
		return null;
	}

	static function byNameU(name:String):Account {
		if (name == null) return null;
		var needle = name.toLowerCase();
		for (a in allU()) if (a.name != null && a.name.toLowerCase() == needle) return a;
		return null;
	}

	public static function byId(id:String):Account return JsonStore.lock(function() return byIdU(id));
	public static function byEmail(email:String):Account return JsonStore.lock(function() return byEmailU(email));
	public static function byName(name:String):Account return JsonStore.lock(function() return byNameU(name));

	/**
	 * /api/user/info needs a case-sensitive exact lookup, unlike the case-insensitive byName
	 * used for rename-collision checks.
	 */
	public static function byNameExact(name:String):Account {
		return JsonStore.lock(function() {
			if (name == null) return null;
			for (a in allU()) if (a.name == name) return a;
			return null;
		});
	}

	/** Refreshes lastActive; /api/account/me calls this on every request. */
	public static function touch(a:Account, now:Float):Void {
		if (a == null) return;
		JsonStore.lock(function() {
			var cur = byIdU(a.id);
			if (cur == null) return false;
			cur.lastActive = now;
			JsonStore.write(path, db);
			return true;
		});
	}

	/**
	 * Rank by points descending (1-based); 0 when not found. There are no keys/category tiers
	 * here (a single points pool), so those filters do not exist.
	 */
	public static function rankOf(id:String, byAccuracy:Bool = false):Int {
		return JsonStore.lock(function() {
			if (id == null) return 0;
			var accounts = allU().copy();
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

	public static function count():Int return JsonStore.lock(function() return allU().length);

	/** Account count / snapshot to iterate (used by tests and /api/top/players). */
	public static function snapshot():Array<Account> return JsonStore.lock(function() return allU().copy());

	/** Basic auth: id and token must both match. */
	public static function auth(id:String, token:String):Account {
		return JsonStore.lock(function() {
			var a = byIdU(id);
			if (a == null || token == null || a.token == null) return null;
			return a.token == token ? a : null;
		});
	}

	/** Field shape of a new account; shared by createOrGet / issueCredentials so they cannot drift. */
	static function newAccountU(name:String, email:String):Account {
		db.seq = db.seq + 1;
		var newName = (name != null && StringTools.trim(name) != "") ? StringTools.trim(name) : ('player' + db.seq);
		var a:Account = {
			id: 'u' + db.seq,
			name: newName,
			email: email,
			token: JsonStore.randomHex(64),
			points: 0,
			avgAccuracy: 0,
			games: 0,
			profileHue: 250,
			profileHue2: null,
			country: null,
			lastActive: Date.now().getTime(),
			bio: "",
			notifications: [],
			friends: [],
			friendRequests: [],
			ngUrl: null,
			ngId: null,
			role: DEFAULT_ROLE,
			ips: [],
			access: MEMBER_ACCESS.copy(),
			createdAt: Date.now().getTime()
		};
		allU().push(a);
		return a;
	}

	/**
	 * Get-or-create shared by register / login: an existing email is returned (token refreshed,
	 * name filled in), otherwise a new account is created. The returned token is valid.
	 */
	public static function createOrGet(name:String, email:String):Account {
		return JsonStore.lock(function() {
			var existing = byEmailU(email);
			if (existing != null) {
				if (name != null && StringTools.trim(name) != "") existing.name = StringTools.trim(name);
				existing.token = JsonStore.randomHex(64);
				JsonStore.write(path, db);
				return existing;
			}
			var a = newAccountU(name, email);
			JsonStore.write(path, db);
			return a;
		});
	}

	/**
	 * Shared by login / register / refresh: get-or-create, rotate the token and write the TTL
	 * in one lock and one disk write, because login already writes the token and the TTL must
	 * ride along (a second full write would change timing on a 1000+ account store).
	 * ttlMinutes <= 0 means no expiry (tokenExpiresAt = null).
	 */
	public static function issueCredentials(name:String, email:String, ttlMinutes:Int):Account {
		return JsonStore.lock(function() {
			var a = byEmailU(email);
			if (a == null) {
				a = newAccountU(name, email);
			} else {
				if (name != null && StringTools.trim(name) != "") a.name = StringTools.trim(name);
				a.token = JsonStore.randomHex(64);
			}

			var now = Date.now().getTime();
			a.tokenIssuedAt = now;
			a.tokenTtlMinutes = ttlMinutes;
			a.tokenExpiresAt = ttlMinutes <= 0 ? null : now + ttlMinutes * 60000.0;

			JsonStore.write(path, db);
			return a;
		});
	}

	public static function rotateToken(a:Account):String {
		return JsonStore.lock(function() {
			var cur = byIdU(a.id);
			if (cur == null) return null;
			cur.token = JsonStore.randomHex(64);
			JsonStore.write(path, db);
			return cur.token;
		});
	}

	/** Renames an account. Returns the new name, or null on a taken / empty name. */
	public static function rename(a:Account, name:String):String {
		return JsonStore.lock(function() {
			var cur = byIdU(a.id);
			if (cur == null || name == null || StringTools.trim(name) == "") return null;
			var trimmed = StringTools.trim(name);
			var other = byNameU(trimmed);
			if (other != null && other.id != cur.id) return null;
			cur.name = trimmed;
			JsonStore.write(path, db);
			return cur.name;
		});
	}

	public static function setEmail(a:Account, email:String):Bool {
		return JsonStore.lock(function() {
			var cur = byIdU(a.id);
			if (cur == null || email == null || email.indexOf('@') < 0) return false;
			cur.email = email;
			JsonStore.write(path, db);
			return true;
		});
	}

	/**
	 * Unbinds any other account holding the same ngId (ngId/ngUrl set to null) before writing
	 * this one; passing null unlinks.
	 */
	public static function linkNewgrounds(a:Account, ngId:String, ngUrl:String):Bool {
		return JsonStore.lock(function() {
			var cur = byIdU(a.id);
			if (cur == null) return false;
			if (ngId != null) {
				for (other in allU()) {
					if (other.id != cur.id && other.ngId != null && other.ngId == ngId) {
						other.ngId = null;
						other.ngUrl = null;
					}
				}
			}
			cur.ngId = ngId;
			cur.ngUrl = ngUrl;
			JsonStore.write(path, db);
			return true;
		});
	}

	/** Finds the account bound to an ngId (used to prevent double binding). */
	public static function byNgId(ngId:String):Account {
		return JsonStore.lock(function() {
			if (ngId == null) return null;
			for (a in allU()) if (a.ngId != null && a.ngId == ngId) return a;
			return null;
		});
	}

	/** Adds submission stats (points / incremental mean accuracy) for /api/top/players. */
	public static function addStats(a:Account, points:Float, accuracy:Float):Void {
		JsonStore.lock(function() {
			var cur = byIdU(a.id);
			if (cur == null) return false;
			cur.points = cur.points + points;
			cur.games = cur.games + 1;
			cur.avgAccuracy = cur.avgAccuracy + (accuracy - cur.avgAccuracy) / cur.games;
			JsonStore.write(path, db);
			return true;
		});
	}

	public static function remove(a:Account):Bool {
		return JsonStore.lock(function() {
			var cur = byIdU(a.id);
			if (cur == null) return false;
			allU().remove(cur);
			JsonStore.write(path, db);
			return true;
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
		return JsonStore.lock(function() {
			var cur = byIdU(a.id);
			if (cur == null) return "No such account";
			var text = bio == null ? "" : bio;
			if (text.length > 1500) return "Your bio reaches 1500 characters!";
			cur.bio = StringTools.replace(StringTools.replace(text, "<", ""), ">", "");
			cur.profileHue = clampHue(hue);
			// hue2 stays null below 500 points.
			cur.profileHue2 = cur.points < 500 ? null : clampHue(hue2);
			cur.country = validCountry(country);
			JsonStore.write(path, db);
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
		return JsonStore.lock(function() {
			var cur = byIdU(a.id);
			if (cur == null || cur.notifications == null) return [];
			return cur.notifications.copy();
		});
	}

	public static function notificationCount(a:Account):Int {
		return JsonStore.lock(function() {
			var cur = byIdU(a.id);
			return (cur == null || cur.notifications == null) ? 0 : cur.notifications.length;
		});
	}

	/** /api/account/notifications/delete/:id. Returns false when the account has no such notification. */
	public static function deleteNotification(a:Account, id:String):Bool {
		return JsonStore.lock(function() {
			var cur = byIdU(a.id);
			if (cur == null || cur.notifications == null || id == null || id == "") return false;
			var list:Array<Dynamic> = cur.notifications;
			var i = 0;
			while (i < list.length) {
				var n = list[i];
				if (n != null && Std.string(Reflect.field(n, "id")) == id) {
					list.splice(i, 1);
					JsonStore.write(path, db);
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
		return JsonStore.lock(function() {
			var out:Array<Dynamic> = [];
			var needle = q == null ? "" : q.toLowerCase();
			var skip = (page <= 0 ? 0 : page) * 50;
			for (a in allU()) {
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
	 * under its own lock and passes them in: JsonStore has one global Mutex, so this class's
	 * public methods cannot be called from inside its lock callback.
	 */
	public static function setStats(a:Account, points:Float, accuracy:Float, games:Int):Void {
		JsonStore.lock(function() {
			var cur = byIdU(a.id);
			if (cur == null) return false;
			cur.points = points;
			cur.avgAccuracy = accuracy;
			cur.games = games;
			JsonStore.write(path, db);
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
		return JsonStore.lock(function() {
			var friends:Array<FriendEntry> = [];
			var requests:Array<String> = [];
			var pending:Array<String> = [];
			var cur = byIdU(a.id);
			if (cur == null) return { friends: friends, requests: requests, pending: pending };

			if (cur.friends != null) {
				for (id in cur.friends) {
					var f = byIdU(id);
					if (f == null) continue;
					friends.push({ name: f.name, hue: f.profileHue != null ? f.profileHue : 250, hue2: f.profileHue2 });
				}
			}
			if (cur.friendRequests != null) {
				for (id in cur.friendRequests) {
					var r = byIdU(id);
					if (r != null) requests.push(r.name);
				}
			}
			for (other in allU()) {
				if (other.id == cur.id || other.friendRequests == null) continue;
				if (other.friendRequests.indexOf(cur.id) >= 0) pending.push(other.name);
			}
			return { friends: friends, requests: requests, pending: pending };
		});
	}

	/** /api/user/details' friends as names. */
	public static function friendNames(a:Account):Array<String> {
		return JsonStore.lock(function() {
			var out:Array<String> = [];
			var cur = byIdU(a.id);
			if (cur == null || cur.friends == null) return out;
			for (id in cur.friends) {
				var f = byIdU(id);
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
		return JsonStore.lock(function() {
			var cur = byIdU(a.id);
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
		return JsonStore.lock(function() {
			var user = byIdU(from.id);
			var target = byIdU(to.id);
			if (user == null || target == null) return "error";
			if (user.friends != null && user.friends.indexOf(target.id) >= 0) return "already";

			// They already asked me: become friends and clear both pending requests.
			if (user.friendRequests != null && user.friendRequests.indexOf(target.id) >= 0) {
				user.friendRequests.remove(target.id);
				if (user.friends == null) user.friends = [];
				if (user.friends.indexOf(target.id) < 0) user.friends.push(target.id);

				if (target.friendRequests != null) target.friendRequests.remove(user.id);
				if (target.friends == null) target.friends = [];
				if (target.friends.indexOf(user.id) < 0) target.friends.push(user.id);

				JsonStore.write(path, db);
				return "mutual";
			}

			// I already sent one: report a duplicate without notifying.
			if (target.friendRequests != null && target.friendRequests.indexOf(user.id) >= 0) return "duplicate";

			if (target.friendRequests == null) target.friendRequests = [];
			target.friendRequests.push(user.id);
			JsonStore.write(path, db);
			return "sent";
		});
	}

	/**
	 * /api/user/friends/remove. Note the argument direction: target is the person to remove and
	 * self is the authenticated caller. self.id must be in target.friends, otherwise this
	 * returns false ("Not on friend list", 400).
	 */
	public static function removeFriendBetween(target:Account, self:Account):Bool {
		return JsonStore.lock(function() {
			var me = byIdU(target.id);
			var other = byIdU(self.id);
			if (me == null || other == null) return false;
			if (me.friends == null || me.friends.indexOf(other.id) < 0) return false;

			me.friends.remove(other.id);
			if (other.friends != null) other.friends.remove(me.id);

			JsonStore.write(path, db);
			return true;
		});
	}

	/**
	 * Landing point for sendNotification: writes into the target account's notifications (newest
	 * first) and returns the new notification (Api pushes it over WS). id is a random 24-char hex
	 * string; date is an ISO string.
	 */
	public static function addNotification(a:Account, title:String, content:String, image:String, href:String):Dynamic {
		return JsonStore.lock(function() {
			var cur = byIdU(a.id);
			if (cur == null) return null;
			if (cur.notifications == null) cur.notifications = [];
			var notif:Dynamic = {
				id: JsonStore.randomHex(24),
				date: JsonStore.isoNow(),
				title: title,
				content: content,
				image: image,
				href: href
			};
			cur.notifications.unshift(notif);
			JsonStore.write(path, db);
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
		return JsonStore.lock(function() {
			var cur = byIdU(a.id);
			if (cur == null) return false;
			var normalized = normalizeRole(role);
			if (cur.role == normalized) return false;
			cur.role = normalized;
			cur.access = accessForRole(normalized);
			JsonStore.write(path, db);
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
		return JsonStore.lock(function() {
			var cur = byIdU(a.id);
			if (cur == null) return false;
			cur.role = to ? "Banned" : DEFAULT_ROLE;
			cur.access = accessForRole(cur.role);
			if (to) {
				cur.bio = "This account was banned by a moderator!" + (reason == null ? "" : ("\nReason: " + reason));
				// A ban clears the player's stats.
				cur.points = 0;
				cur.avgAccuracy = 0;
				cur.games = 0;
			}
			JsonStore.write(path, db);
			return true;
		});
	}

	/**
	 * Only new IPs are recorded, and the file is not rewritten when the IP already exists.
	 * Loopback addresses are skipped.
	 */
	public static function recordIp(a:Account, ip:String):Void {
		if (a == null || ip == null || ip == "") return;
		if (ip == "127.0.0.1" || ip == "::1" || ip == "::ffff:127.0.0.1" || ip == "0:0:0:0:0:0:0:1") return;
		JsonStore.lock(function() {
			var cur = byIdU(a.id);
			if (cur == null) return false;
			if (cur.ips == null) cur.ips = [];
			if (cur.ips.indexOf(ip) >= 0) return false;
			cur.ips.push(ip);
			JsonStore.write(path, db);
			return true;
		});
	}

	/** /api/admin/user/ips: ids of other accounts sharing any IP. */
	public static function sameIpIds(a:Account):Array<String> {
		return JsonStore.lock(function() {
			var out:Array<String> = [];
			var cur = byIdU(a.id);
			if (cur == null || cur.ips == null || cur.ips.length == 0) return out;
			for (other in allU()) {
				if (other.id == cur.id || other.ips == null) continue;
				for (ip in other.ips) {
					if (cur.ips.indexOf(ip) >= 0) {
						out.push(other.id);
						break;
					}
				}
			}
			return out;
		});
	}

	/** Maps an id list to names; unknown ids are skipped. */
	public static function namesOf(ids:Array<String>):Array<String> {
		return JsonStore.lock(function() {
			var out:Array<String> = [];
			if (ids == null) return out;
			for (id in ids) {
				var a = byIdU(id);
				if (a != null) out.push(a.name);
			}
			return out;
		});
	}

	/**
	 * /api/admin/user/data. Token and access are omitted (credentials and the internal permission
	 * table need not go to the admin UI); role is normalized.
	 */
	public static function viewOf(a:Account):Dynamic {
		return JsonStore.lock(function() {
			var cur = byIdU(a.id);
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
		return JsonStore.lock(function() {
			var cur = byIdU(id);
			if (cur == null) return "No player found with that name!";
			if (email == null || email.indexOf("@") < 0) return "Invalid Email Address!";
			var other = byEmailU(email);
			if (other != null && other.id != cur.id) return "Can't set the same email for two accounts!";
			cur.email = email;
			JsonStore.write(path, db);
			return null;
		});
	}

	/**
	 * /api/admin/user/rename. Allows letters/digits/underscore and 3..14 characters (the error
	 * message says max 15 but the check rejects anything over 14). Returns null on success.
	 */
	public static function renameById(id:String, name:String):Null<String> {
		return JsonStore.lock(function() {
			var cur = byIdU(id);
			if (cur == null) return "No player found with that name!";
			if (name == null) return "Your username contains invalid characters!";
			if (name.length < 3) return "Your username is too short! (min 3 characters)";
			if (name.length > 14) return "Your username is too long! (max 15 characters)";
			for (i in 0...name.length) {
				var c = name.charCodeAt(i);
				var ok = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95;
				if (!ok) return "Your username contains invalid characters!";
			}
			var other = byNameU(name);
			if (other != null && other.id != cur.id) return "Player with that username exists!";
			cur.name = name;
			JsonStore.write(path, db);
			return null;
		});
	}

	/** Persists in-memory changes to disk (used after applyAdmin grants admin). */
	public static function persist():Void {
		JsonStore.lock(function() {
			JsonStore.write(path, db);
			return true;
		});
	}

	/** Name by id; null when not found. */
	public static function nameOf(id:String):String {
		return JsonStore.lock(function() {
			var a = byIdU(id);
			return a == null ? null : a.name;
		});
	}

	/** Account snapshot sorted by id ascending, for the admin player list / stats. */
	public static function roleOf(a:Account):String {
		return JsonStore.lock(function() {
			var cur = byIdU(a.id);
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
