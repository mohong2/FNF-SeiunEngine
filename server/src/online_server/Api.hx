package online_server;

import haxe.Json;
import haxe.crypto.Base64;
import haxe.io.Bytes;
import sys.thread.Mutex;
// ServerHub and Account are secondary types of their modules (same file, second declaration).
import online_server.Main.ServerHub;
import online_server.AccountStore.Account;
import online_server.ClubStore.Club;
import online_server.HttpServer.HttpRequest;
import online_server.HttpServer.HttpResponse;
import online_server.ServerMail.SmtpConfig;

/**
 * Account and core HTTP API over local JSON storage. Only endpoints the client actually calls
 * are implemented (auth, account, front/sez/online/stats, song comments, mods, search, user,
 * score, top). Protected endpoints first pass requireAccess (four checks); roles are Member and
 * Admin (--admin-email -> ["*"]). No mail is sent (any non-empty code is accepted, but the
 * two-step shape stays), a random token is the credential, mod size is always -1, and
 * /api/user/avatar/:user is always 404.
 */
class Api {
	static var adminEmail:String = null;
	static var dataDir:String = null;
	/**
	 * /api/online's network field: account names that called /api/account/me or
	 * /api/account/info, append-only.
	 */
	static var onlinePlayers:Array<String> = [];

	/**
	 * EMAIL_BLACKLIST file (one "domain note" per line, comments start with a space). Looked up
	 * at server/EMAIL_BLACKLIST and cwd/EMAIL_BLACKLIST; empty when absent.
	 */
	static var emailBlacklist:Array<String> = [];

	/**
	 * Credential TTL policy. ttlMinutes = 0 means no expiry; ttlLocked = true ignores the
	 * client-requested minutes. Set by CLI --auth-ttl-minutes and config.toml [auth] (CLI wins).
	 */
	public static var DEFAULT_AUTH_TTL_MINUTES:Int = 43200;
	/** Grace period (minutes) after expiry during which a credential may still be refreshed. */
	public static inline var REFRESH_GRACE_MINUTES:Int = 43200;
	static var authTtlMinutes:Int = 43200;
	static var authTtlLocked:Bool = false;

	public static function authTtl():Int return authTtlMinutes;
	public static function authTtlIsLocked():Bool return authTtlLocked;

	public static function init(dir:String, ?admin:String, ?smtp:SmtpConfig, ?ngAppId:String, ?discordWebhook:String, ?authTtl:Int, ?authLocked:Bool):Void {
		if (authTtl != null) authTtlMinutes = authTtl < 0 ? 0 : authTtl;
		if (authLocked != null) authTtlLocked = authLocked;
		dataDir = dir;
		adminEmail = admin;
		AccountStore.init(dir + "/accounts.json");
		LeaderboardStore.init(dir + "/leaderboard.json");
		// Local JSON for front messages, weekly reset and day-player stats.
		PublicStore.init(dir + "/public.json");
		// Warnings and mod action log.
		AdminStore.init(dir + "/admin.json");
		// Clubs.
		ClubStore.init(dir + "/clubs.json");
		// Mod repository.
		ModStore.init(dir + "/mods.json");
		// Local binary storage for avatars/backgrounds.
		ImageStore.init(dir);
		// Verification codes and outbound mail; without --smtp-* only mail.log is written.
		ServerMail.init(dir, smtp);
		// Newgrounds gateway and Discord webhook (unconfigured = degraded/no-op).
		Ngio.init(ngAppId);
		DiscordBridge.init(discordWebhook);
		loadEmailBlacklist();
		// Registered cooldown entries. Paths that are not registered have no cooldown.
		registerCooldown("/api/sez", 86400);
		registerCooldown("/api/song/comment", 20);
		registerCooldown("/api/account/rename", 60);
		registerCooldown("/api/score/report", 20);
		registerCooldown("/api/score/submit", 30);
		registerCooldown("/api/account/profile/set", 3);
		// Auto-login refresh (named timer, separate from the request path, like the console cooldowns).
		registerCooldown("auth.refresh", 3);
		// Club cooldowns. "club.edit.tag" is invoked manually by clubEdit with entityId
		// "club.<clubId>".
		registerCooldown("/api/club/banner", 10);
		registerCooldown("/api/club/edit", 5);
		registerCooldown("club.edit.tag", 604800);
		// Account image and Newgrounds cooldowns.
		registerCooldown("/api/account/avatar", 10);
		registerCooldown("/api/account/background", 10);
		registerCooldown("/api/account/link/newgrounds", 5);
		// Console: short cooldowns on the console's write actions (anti double-click).
		// Timer ids deliberately differ from the request paths: the console page GETs
		// /api/console/config to draw the form, and that read must not spend the write cooldown.
		registerCooldown("console.config", 3);
		registerCooldown("console.reload", 2);
		registerCooldown("console.announce", 3);
		registerCooldown("console.kick", 1);
		registerCooldown("console.room.close", 2);
		registerCooldown("console.mod.delete", 2);
		// Revoking a credential (rotate token + kick) also gets a short cooldown against double-clicks.
		registerCooldown("console.revoke", 3);
	}

	/** In-memory Newgrounds sessions, one per account. */
	static var ngSessions:Map<String, Dynamic> = new Map();

	public static function storageDir():String return dataDir;

	// ------------------------------------------------------------------
	// ------------------------------------------------------------------
	// Routing
	// ------------------------------------------------------------------

	/** Returns null when this module does not handle the path (the caller replies 404). */
	public static function handle(request:HttpRequest, hub:ServerHub):Null<HttpResponse> {
		var path = request.path;
		var method = request.method;
		try {
			switch (path) {
				case "/api/auth/register": if (method == "POST") return authRegister(request);
				case "/api/auth/login": if (method == "POST") return authLogin(request);
				case "/api/auth/refresh": if (method == "POST") return authRefresh(request);
				case "/api/auth/cookie": return authCookie(request);
				case "/api/auth/logout": return authLogout(request);

				case "/api/account/me": return accountMe(request);
				case "/api/account/rename": if (method == "POST") return accountRename(request);
				case "/api/account/email/set": if (method == "POST") return accountEmailSet(request);
				case "/api/account/delete": return accountDelete(request);
				case "/api/account/friends": return accountFriends(request);
				case "/api/account/notifications": return accountNotifications(request);
				// Remaining account routes (notifications/delete is a path param, below).
				case "/api/account/info": return accountInfo(request);
				case "/api/account/profile/set": if (method == "POST") return accountProfileSet(request);
				case "/api/account/resetsecret": return accountResetSecret(request);
				// Club tag for the account.
				case "/api/account/club": return accountClub(request);
				// Image upload/delete + Newgrounds linking.
				case "/api/account/avatar": if (method == "POST") return accountAvatar(request);
				case "/api/account/background": if (method == "POST") return accountBackground(request);
				case "/api/account/removeimages": return accountRemoveImages(request);
				case "/api/account/link/newgrounds": return accountLinkNewgrounds(request);
				case "/api/account/unlink/newgrounds": return accountUnlinkNewgrounds(request);
				case "/api/club/details": return clubDetails(request);
				case "/api/club/pending": return clubPending(request);
				case "/api/club/create": if (method == "POST") return clubCreate(request);
				case "/api/club/join": return clubJoin(request, hub);
				case "/api/club/accept": return clubAccept(request, hub);
				case "/api/club/reject": return clubReject(request);
				case "/api/club/kick": return clubKick(request);
				case "/api/club/promote": return clubPromote(request);
				case "/api/club/demote": return clubDemote(request);
				case "/api/club/leave": return clubLeave(request);
				case "/api/club/edit": if (method == "POST") return clubEdit(request);
				case "/api/club/banner": if (method == "POST") return clubBannerUpload(request);

				// Of the three endpoints the client really calls, the two a switch can hold (avatar is a path param, below).
				case "/api/user/info": return userInfo(request);
				// user.ts friend endpoints.
				case "/api/user/friends/request": return userFriendRequest(request, hub);
				case "/api/user/friends/remove": return userFriendRemove(request);
				// user.ts remainder.
				case "/api/user/details": return userDetails(request);
				case "/api/user/scores": return userScores(request);

				// Mod repository (all write endpoints are protected; favourites skip the action log).
			case "/api/mod/dl/submit": if (method == "POST") return modDownloadSubmit(request);
			case "/api/mod/dl/edit": if (method == "POST") return modDownloadEdit(request);
			case "/api/mod/dl/delete": if (method == "POST") return modDownloadDelete(request);
			case "/api/mod/fav": if (method == "POST") return modFav(request);
			case "/api/mod/submit": if (method == "POST") return modSubmit(request);
			case "/api/mod/edit": if (method == "POST") return modEdit(request);
			case "/api/mod/delete": if (method == "POST") return modDelete(request);

			case "/api/search/mods": return searchMods(request);
				// search.ts remainder.
				case "/api/search/songs": return searchSongsRoute(request);
				case "/api/search/users": return searchUsersRoute(request);

				// root.ts remainder.
				case "/api/sezdetal": return sezDetail();
				case "/api/online": return onlineList(hub);
				case "/api/nextweekreset": return nextWeekReset();

				case "/api/front": return front(request, hub);
				case "/api/sez": if (method == "POST") return postSez(request);
				case "/api/song/comment": if (method == "POST") return postComment(request);
				case "/api/song/comments": return getComments(request);

				case "/api/score/submit": if (method == "POST") return scoreSubmit(request);
				case "/api/score/report": if (method == "POST") return scoreReport(request);
				case "/api/score/replay": return scoreReplay(request);
				// score.ts remainder.
				case "/api/score/delete": return scoreDelete(request);
				case "/api/score/set/modurl": return scoreSetModURL(request);

				case "/api/top/song": return topSong(request);
				case "/api/top/players": return topPlayers(request);
				case "/api/top/clubs": return topClubs(request);

				// stats.ts.
				case "/api/stats/day_players": return statsDayPlayers(hub);
				case "/api/stats/country_players": return statsCountryPlayers();

				case "/api/admin/song/submit": if (method == "POST") return adminSongSubmit(request);
				default:
			}
			if (StringTools.startsWith(path, "/api/mod/details/"))
				return modDetails(path.substr("/api/mod/details/".length));
			if (StringTools.startsWith(path, "/api/user/avatar/"))
				return userAvatar(path.substr("/api/user/avatar/".length));
			// /api/user/background/:user
			if (StringTools.startsWith(path, "/api/user/background/"))
				return userBackground(path.substr("/api/user/background/".length));
			// GET /mod/:mod_id/dl/:dl_id -- note it has no /api/ prefix.
			if (StringTools.startsWith(path, "/mod/")) {
				var dl = modDownloadRedirect(path);
				if (dl != null) return dl;
			}
			// Notification delete path parameter.
			if (StringTools.startsWith(path, "/api/account/notifications/delete/"))
				return accountNotificationDelete(request, path.substr("/api/account/notifications/delete/".length));
			// GET /api/club/banner/:tag (path parameter).
			if (StringTools.startsWith(path, "/api/club/banner/"))
				return clubBanner(path.substr("/api/club/banner/".length));
			// All admin routes (unmatched paths return null from handleAdmin -> 404).
			if (StringTools.startsWith(path, "/api/admin/")) {
				var admin = handleAdmin(request, hub);
				if (admin != null) return admin;
			}
			// Console JSON endpoints (the page itself is served by Main's /console route via ConsoleWeb).
			if (StringTools.startsWith(path, "/api/console/")) {
				var con = ConsoleApi.handle(request, hub);
				if (con != null) return con;
			}
			return json(404, { error: "not found: " + path });
		} catch (e:Dynamic) {
			trace('[api] ' + method + ' ' + path + ' failed: ' + Std.string(e));
			return json(500, { error: "internal error: " + Std.string(e) });
		}
	}

	// ------------------------------------------------------------------
	// /api/auth/*
	// ------------------------------------------------------------------

	static function authRegister(request:HttpRequest):HttpResponse {
		var body = parseBody(request);
		if (body == null) return fail(400, "Invalid JSON body");

		var email = strOf(body, "email");
		var name = strOf(body, "username");
		if (email == null || email.indexOf('@') < 0) return fail(400, "Invalid Email Address!");
		// Blocked email hosts (EMAIL_BLACKLIST).
		if (!validateEmail(email)) return fail(400, "This Email Host is Blocked!");

		var code = Reflect.field(body, "code");
		if (code == null || Std.string(code) == "") {
			// Reply 200; an already-registered email gets no code (do not reveal existence).
			if (AccountStore.byEmail(email) == null) sendCode(email);
			return json(200, { needCode: true, mail: ServerMail.smtpConfigured() });
		}

		// Wrong code -> 400 'Invalid Code!'; the code is consumed either way.
		if (!ServerMail.verifyAndConsume(email, Std.string(code))) return fail(400, "Invalid Code!");
		// No per-IP daily limit on account creation: one machine may register several accounts.
		var account = AccountStore.issueCredentials(name, email, effectiveTtlMinutes(body));
		applyAdmin(account);
		return json(200, { id: account.id, token: account.token, secret: "local-json", expiresAt: expiresOf(account), ttlMinutes: account.tokenTtlMinutes });
	}

	static function authLogin(request:HttpRequest):HttpResponse {
		var body = parseBody(request);
		if (body == null) return fail(400, "Invalid JSON body");

		var email = strOf(body, "email");
		if (email == null || email.indexOf('@') < 0) return fail(400, "Invalid Email Address!");

		var account = AccountStore.byEmail(email);
		// Banned accounts never receive a token.
		if (AccountStore.isBanned(account)) return fail(403, AccountStore.banMessage(account));
		var code = Reflect.field(body, "code");
		if (code == null || Std.string(code) == "") {
			// Reply 200; an unknown email gets no code (do not reveal existence).
			if (account != null) sendCode(email);
			return json(200, { needCode: true, known: account != null });
		}

		if (account == null) return fail(400, "Player with that email does not exist!");
		// Wrong code -> 400 'Invalid Code!'.
		if (!ServerMail.verifyAndConsume(email, Std.string(code))) return fail(400, "Invalid Code!");
		// Login rotates the token (the old one dies immediately) and renews the TTL.
		account = AccountStore.issueCredentials(account.name, email, effectiveTtlMinutes(body));
		applyAdmin(account);
		return json(200, { id: account.id, token: account.token, secret: "local-json", expiresAt: expiresOf(account), ttlMinutes: account.tokenTtlMinutes });
	}

	/**
	 * The only auto-login entry point, called with Basic credentials (id + current token):
	 *   - token matches and is unexpired -> rotate and renew;
	 *   - token matches, expired but inside the grace period (tokenExpiresAt +
	 *     REFRESH_GRACE_MINUTES) -> renew as well (the "remember me" path);
	 *   - outside the grace period or token mismatch -> 401 { error: "Session expired",
	 *     expired: true }.
	 * Named cooldown auth.refresh (3 s, per account).
	 */
	static function authRefresh(request:HttpRequest):HttpResponse {
		var cred = credentialOf(request);
		if (cred == null) return sessionExpired();

		var account = AccountStore.byId(cred.id);
		// The stored credential is a hash: compare it in constant time instead of reading a token back.
		if (account == null || !AccountStore.verifyToken(account, cred.token)) return sessionExpired();
		if (!cooldownOk(account.id, "auth.refresh")) return fail(429, "Too many requests");
		if (AccountStore.isBanned(account)) return fail(403, AccountStore.banMessage(account));

		var now = Date.now().getTime();
		if (account.tokenExpiresAt != null && account.tokenExpiresAt > 0) {
			var graceEnd = account.tokenExpiresAt + REFRESH_GRACE_MINUTES * 60000.0;
			if (now > graceEnd) return sessionExpired();
		}

		var body = parseBody(request);
		// Rotate the token (the old one dies immediately) and renew the TTL in one locked write.
		account = AccountStore.issueCredentials(account.name, account.email, effectiveTtlMinutes(body));
		applyAdmin(account);
		return json(200, { id: account.id, token: account.token, secret: "local-json", expiresAt: expiresOf(account), ttlMinutes: account.tokenTtlMinutes });
	}

	/** Uniform shape for an expired credential (the client uses the expired field to re-login). */
	static function sessionExpired():HttpResponse {
		return json(401, { error: "Session expired", expired: true });
	}

	/**
	 * The TTL actually used for this login (minutes). A server-fixed TTL (ttlLocked) ignores
	 * the request value; otherwise the request wins (clamped 1..525600), falling back to the default.
	 */
	static function effectiveTtlMinutes(body:Dynamic):Int {
		var minutes = authTtlMinutes;
		if (!authTtlLocked && body != null) {
			var requested = Reflect.field(body, "ttlMinutes");
			if (requested != null) {
				var parsed = Std.parseInt(Std.string(requested));
				if (parsed != null && parsed > 0) minutes = parsed > 525600 ? 525600 : parsed;
			}
		}
		return minutes;
	}

	/** Account expiry in ms; no expiry (null / 0) means 0. */
	static function expiresOf(account:Account):Float {
		if (account == null || account.tokenExpiresAt == null) return 0;
		return account.tokenExpiresAt;
	}

	/**
	 * The HttpServer does not support Set-Cookie (it serves Haxe clients only), so this endpoint
	 * only echoes 200.
	 */
	static function authCookie(request:HttpRequest):HttpResponse {
		var params = query(request);
		var id = params.get("id");
		if (id == null) return fail(400, "missing id");
		var account = AccountStore.byId(id);
		return plain(200, account != null ? ("user: " + account.name) : "unknown user");
	}

	static function authLogout(request:HttpRequest):HttpResponse {
		var account = authAccount(request);
		if (account != null) AccountStore.rotateToken(account);
		return plain(200, "ok");
	}

	// ------------------------------------------------------------------
	// Email verification codes
	// ------------------------------------------------------------------
	// ------------------------------------------------------------------

	/** generateCode -> tempSetCode -> sendCodeMail. */
	static function sendCode(email:String):Void {
		if (email == null || email == "") return;
		var daCode = ServerMail.generateCode();
		ServerMail.tempSetCode(email, daCode);
		ServerMail.sendCodeMail(email, daCode);
	}

	/** Rejects an email whose host ends with a blacklisted domain (case-sensitive). */
	static function validateEmail(email:String):Bool {
		if (email == null) return true;
		var parts = email.split('@');
		if (parts.length < 2) return true; // callers already checked for '@'
		var host = StringTools.trim(parts[1]);
		for (v in emailBlacklist) {
			var domain = StringTools.trim(v.split(' ')[0]);
			if (domain.length > 0 && StringTools.endsWith(host, domain)) return false;
		}
		return true;
	}

	static function loadEmailBlacklist():Void {
		emailBlacklist = [];
		for (path in ["server/EMAIL_BLACKLIST", "EMAIL_BLACKLIST"]) {
			if (!sys.FileSystem.exists(path)) continue;
			try {
				var text = sys.io.File.getContent(path);
				for (line in text.split("\n")) {
					var v = StringTools.trim(line);
					if (v == "" || StringTools.startsWith(v, "#")) continue;
					emailBlacklist.push(v);
				}
				trace('[api] email blacklist loaded from ' + path + ' (' + emailBlacklist.length + ' entries)');
				return;
			} catch (e:Dynamic) {
				trace('[api] email blacklist read failed: ' + Std.string(e));
			}
		}
		trace('[api] no EMAIL_BLACKLIST found -> validateEmail accepts every host');
	}

	// ------------------------------------------------------------------
	// /api/account/*
	// ------------------------------------------------------------------

	static function accountMe(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var account = access.account;

		// Every /api/account/me refreshes lastActive.
		var now = Date.now().getTime();
		AccountStore.touch(account, now);
		account.lastActive = now;
		// Records the visitor in the online list used by /api/online.
		rememberOnline(account.name);

		return json(200, {
			name: account.name,
			points: account.points,
			avgAccuracy: account.avgAccuracy,
			role: roleName(account),
			profileHue: account.profileHue,
			profileHue2: account.profileHue2,
			country: account.country,
			access: account.access,
			club: ClubStore.tagOf(account.id),
			notifs: AccountStore.notificationCount(account)
		});
	}

	static function accountRename(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var account = access.account;

		var body = parseBody(request);
		if (body == null) return fail(400, "Invalid JSON body");

		var renamed = AccountStore.rename(account, strOf(body, "username"));
		if (renamed == null) return fail(400, "Couldn't change your handle...");
		// The client uses the response body directly as the new name, so it must be a bare string.
		return plain(200, renamed);
	}

	static function accountEmailSet(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var account = access.account;

		var body = parseBody(request);
		if (body == null) return fail(400, "Invalid JSON body");
		var email = strOf(body, "email");
		if (email == null || email.indexOf('@') < 0) return fail(400, "Invalid Email Address!");
		// Email host check followed by the old-email check.
		if (!validateEmail(email)) return fail(400, "This Email Host is Blocked!");
		var oldEmail = strOf(body, "old_email");
		if (account.email != null && account.email != "" && account.email != oldEmail) {
			return fail(400, "Currently Set Email is Not Provided!");
		}

		var code = Reflect.field(body, "code");
		if (code == null || Std.string(code) == "") {
			// Reply 200; an email already in use gets no code.
			if (AccountStore.byEmail(email) == null) sendCode(email);
			return json(200, { needCode: true, mail: ServerMail.smtpConfigured() });
		}
		// Wrong code -> 400 'Invalid Code!'.
		if (!ServerMail.verifyAndConsume(email, Std.string(code))) return fail(400, "Invalid Code!");
		// One email cannot belong to two accounts.
		var other = AccountStore.byEmail(email);
		if (other != null && other.id != account.id) return fail(400, "Can't set the same email for two accounts!");
		if (!AccountStore.setEmail(account, email)) return fail(400, "Couldn't set your email...");
		return json(200, { ok: true });
	}

	static function accountDelete(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var account = access.account;

		var params = query(request);
		var code = params.get("code");
		if (code == null || code == "") {
			// Without a code, send it to the account's current email; reply 200 either way.
			if (account.email != null && account.email != "") sendCode(account.email);
			return json(200, { needCode: true, mail: ServerMail.smtpConfigured() });
		}
		// Wrong code -> 400 'Invalid Code!'.
		if (!ServerMail.verifyAndConsume(account.email, code)) return fail(400, "Invalid Code!");
		// Deleting an account also clears its mod favourites, avatar and background.
		ModStore.removeFavoritesOf(account.id);
		ImageStore.remove(account.id);
		if (!AccountStore.remove(account)) return fail(400, "Couldn't delete your account...");
		return json(200, { ok: true });
	}

	/**
	 * /api/account/notifications. Entries are written by sendNotification (friend requests and
	 * acceptances).
	 */
	static function accountNotifications(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		return json(200, AccountStore.notificationsOf(access.account));
	}

	/**
	 * /api/account/friends. friends = [{name, status, hue, hue2}] with status ONLINE/Offline
	 * (online = accounts that called account/me|info). pending = outgoing requests (target
	 * names), requests = incoming (requester names).
	 */
	static function accountFriends(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;

		var overview = AccountStore.friendsOverview(access.account);
		var online = onlinePlayerNames();
		var friends:Array<Dynamic> = [];
		for (f in overview.friends) {
			friends.push({
				name: f.name,
				status: online.indexOf(f.name) >= 0 ? "ONLINE" : "Offline",
				hue: f.hue,
				hue2: f.hue2
			});
		}
		return json(200, { friends: friends, pending: overview.pending, requests: overview.requests });
	}

	// ------------------------------------------------------------------
	// /api/user/*, /api/search/*
	// ------------------------------------------------------------------

	/**
	 * /api/user/info. A missing `?name=` -> 400, unknown -> 404. There is a single points pool
	 * and no keys/category breakdown, so points/avgAccuracy come straight from the account and
	 * role uses the local lowercase tiers (same as accountMe). The client
	 * (FunkinNetwork.fetchUserInfo) just Json.parses the body.
	 */
	static function userInfo(request:HttpRequest):HttpResponse {
		var params = query(request);
		var name = params.get("name");
		if (name == null || name == "") return fail(400, "missing name");

		var account = AccountStore.byNameExact(name);
		if (account == null) return fail(404, "user not found");

		return json(200, {
			role: roleName(account),
			// The client shows ban status and reason in the online menu with this.
			banned: AccountStore.isBanned(account),
			banReason: AccountStore.banReasonOf(account),
			joined: JsonStore.isoOf(account.createdAt),
			lastActive: JsonStore.isoOf(account.lastActive),
			profileHue: account.profileHue,
			profileHue2: account.profileHue2,
			points: account.points,
			avgAccuracy: account.avgAccuracy,
			rank: AccountStore.rankOf(account.id),
			country: account.country,
			club: null
		});
	}

	/**
	 * Returns raw image bytes, or 404 when there is no avatar. The client falls back to
	 * getDefaultAvatar() on 404 (FunkinNetwork.hx:309-312), so a permanent 404 is acceptable.
	 */
	static function userAvatar(rawUser:String):HttpResponse {
		return userImage(rawUser, "avatar");
	}

	/** GET /api/user/background/:user. */
	static function userBackground(rawUser:String):HttpResponse {
		return userImage(rawUser, "background");
	}

	/**
	 * Both image endpoints behave the same: unknown user or missing image -> 404, otherwise raw
	 * bytes. They do not require access, so images are readable while logged out (the client's
	 * ProfileBox relies on that). content-type is application/octet-stream; the client sniffs
	 * the magic bytes instead of the header.
	 */
	static function userImage(rawUser:String, kind:String):HttpResponse {
		var user = StringTools.urlDecode(rawUser == null ? "" : rawUser);
		if (user == "") return fail(400, "missing user");
		var account = AccountStore.byNameExact(user);
		if (account == null) return fail(404, "no " + kind);
		var data = ImageStore.get(account.id, kind);
		if (data == null) return fail(404, "no " + kind);
		return bytes(200, data, "application/octet-stream");
	}

	/**
	 * ?q=&page=&sort= -> searchMods select projection (take 15, skip 15*page). The client's
	 * FunkinNetwork.searchMods calls it.
	 */
	static function searchMods(request:HttpRequest):HttpResponse {
		var params = query(request);
		var q = params.get("q");
		return json(200, ModStore.searchViews(q == null ? "" : q, parseIntParam(params, "page", 0), params.get("sort")));
	}

	// ------------------------------------------------------------------
	// sezdetal / online / nextweekreset
	// ------------------------------------------------------------------

	/** The latest 5 front messages; the player name is stored directly. */
	static function sezDetail():HttpResponse {
		var out:Array<Dynamic> = [];
		for (m in PublicStore.frontMessages()) out.push({
			player: ServerConfig.repairUtf8(m.player), message: ServerConfig.repairUtf8(m.message)
		});
		return json(200, out);
	}

	/**
	 * `network` = account names that called account/me or account/info (append-only).
	 * `playing` approximates the online connection count; `rooms` comes from the public room list.
	 */
	static function onlineList(hub:ServerHub):HttpResponse {
		var rooms:Array<Dynamic> = [];
		var listed:Array<Dynamic> = cast hub.roomList();
		for (r in listed) {
			var md = Reflect.field(r, "metadata");
			rooms.push({
				code: Reflect.field(r, "roomId"),
				player: Reflect.field(md, "name"),
				ping: Reflect.field(md, "ping")
			});
		}
		return json(200, { network: onlinePlayerNames(), playing: hub.onlineCount(), rooms: rooms });
	}

	/**
	 * Returns the timestamp as a bare string with content-type text/html.
	 * Do not use Std.int(): neko Int is 32-bit and a 13-digit millisecond timestamp overflows;
	 * Std.string(Float) prints the integer form.
	 */
	static function nextWeekReset():HttpResponse {
		return plain(200, Std.string(PublicStore.nextWeeklyDate()), "text/html");
	}

	static function rememberOnline(name:String):Void {
		if (name == null) return;
		JsonStore.lock(function() {
			if (onlinePlayers.indexOf(name) < 0) onlinePlayers.push(name);
			return true;
		});
	}

	static function onlinePlayerNames():Array<String> {
		return JsonStore.lock(function() return onlinePlayers.copy());
	}

	// ------------------------------------------------------------------
	// info / profile/set / resetsecret / notifications/delete
	// ------------------------------------------------------------------

	/** Like /api/account/me but without profileHue/access/notifs; also refreshes lastActive. */
	static function accountInfo(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var account = access.account;
		var now = Date.now().getTime();
		AccountStore.touch(account, now);
		account.lastActive = now;
		rememberOnline(account.name);

		return json(200, {
			name: account.name,
			role: roleName(account),
			joined: JsonStore.isoOf(account.createdAt),
			lastActive: JsonStore.isoOf(now),
			points: account.points,
			avgAccuracy: account.avgAccuracy,
			club: null
		});
	}

	/** Sets bio / hue / country. Limited to one call every 3 seconds. */
	static function accountProfileSet(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;

		var body = parseBody(request);
		if (body == null) return fail(400, "Invalid JSON body");

		var err = AccountStore.setProfile(access.account, strOf(body, "bio"),
			numOfDefault(body, "hue", 250), strOf(body, "country"), numOfDefault(body, "hue2", 0));
		if (err != null) return fail(400, err);
		return plain(200, "OK");
	}

	/**
	 * Rotates the token; the old token immediately gets 403, so the client has to log in again.
	 */
	static function accountResetSecret(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		AccountStore.rotateToken(access.account);
		return plain(200, "OK");
	}

	// ------------------------------------------------------------------
	// Image upload/delete
	// ------------------------------------------------------------------

	/**
	 * POST /api/account/avatar. The file part is parsed by firstFilePart. Validation order:
	 * size (413), then mimetype (415), then write (500). Image dimensions are not checked.
	 */
	static function accountAvatar(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var account = access.account;

		var file = firstFilePart(request);
		// A missing file part is rejected with 400 "Couldn't upload...".
		if (file == null) return fail(400, "Couldn't upload...");
		// Files above 1024 * 250 bytes are rejected with 413.
		if (file.data.length > 1024 * 250) return plain(413, "Payload Too Large");
		var mt = file.contentType == null ? "" : file.contentType.toLowerCase();
		if (mt != "image/png" && mt != "image/jpeg" && mt != "image/gif") return plain(415, "Unsupported Media Type");
		if (!ImageStore.put(account.id, "avatar", file.data)) return fail(500, "Couldn't upload...");
		return plain(200, "OK");
	}

	/**
	 * POST /api/account/background. Requires at least 1000 points (418 otherwise); the points
	 * check runs before the size / mimetype checks.
	 */
	static function accountBackground(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var account = access.account;

		if (account.points < 1000) return plain(418, "I'm a teapot");

		var file = firstFilePart(request);
		if (file == null) return fail(400, "Couldn't upload...");
		if (file.data.length > 1024 * 1000) return plain(413, "Payload Too Large");
		var mt = file.contentType == null ? "" : file.contentType.toLowerCase();
		if (mt != "image/png" && mt != "image/jpeg") return plain(415, "Unsupported Media Type");
		if (!ImageStore.put(account.id, "background", file.data)) return fail(500, "Couldn't upload...");
		return plain(200, "OK");
	}

	/** GET /api/account/removeimages: removes both images; failure -> 500. */
	static function accountRemoveImages(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		if (!ImageStore.remove(access.account.id)) return fail(500, "Couldn't remove...");
		return plain(200, "OK");
	}

	// ------------------------------------------------------------------
	// Newgrounds linking
	// ------------------------------------------------------------------

	/**
	 * Already linked -> 200; otherwise run the gateway's three-step session: checkSession
	 * (unexpired: return passport_url if not yet signed in, link if signed in) / endSession /
	 * startSession. The positive flow cannot be exercised without an app id, so an unconfigured
	 * gateway is treated as a failed request -> 400.
	 */
	static function accountLinkNewgrounds(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var account = access.account;

		if (account.ngId != null) return plain(200, "OK");
		if (!Ngio.available()) return fail(400, "Newgrounds linking is not configured on this server");

		try {
			var lastSession:Dynamic = ngSessions.get(account.id);
			if (lastSession != null) {
				var sessionId = Std.string(Reflect.field(lastSession, "id"));
				var response = Ngio.request({ component: "App.checkSession" }, sessionId);
				if (Reflect.field(response, "expired") != true) {
					var session = Reflect.field(response, "session");
					var user = session != null ? Reflect.field(session, "user") : null;
					if (user == null) {
						// Not yet confirmed on Newgrounds: return the passport URL to the client.
						ngSessions.set(account.id, session);
						return plain(200, Std.string(Reflect.field(session, "passport_url")));
					}
					linkNg(account, user);
					ngSessions.remove(account.id);
					return plain(200, "OK");
				}
				Ngio.request({ component: "App.endSession" }, sessionId);
				ngSessions.remove(account.id);
			}

			var started = Ngio.request({ component: "App.startSession" });
			var fresh = Reflect.field(started, "session");
			if (fresh == null) return fail(400, "Newgrounds refused the session");
			ngSessions.set(account.id, fresh);
			return plain(200, Std.string(Reflect.field(fresh, "passport_url")));
		} catch (e:Dynamic) {
			trace('[ng] link failed: ' + Std.string(e));
			return fail(400, "Unknown error...");
		}
	}

	/** Clears the in-memory session and unlinks the account. */
	static function accountUnlinkNewgrounds(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var account = access.account;
		ngSessions.remove(account.id);
		AccountStore.linkNewgrounds(account, null, null);
		return plain(200, "OK");
	}

	/** Stores the Newgrounds id and profile URL on the account. */
	static function linkNg(account:Account, user:Dynamic):Void {
		var ngId = Reflect.field(user, "id");
		if (ngId == null) return;
		var ngUrl = Reflect.field(user, "url");
		AccountStore.linkNewgrounds(account, Std.string(ngId), ngUrl == null ? null : Std.string(ngUrl));
	}

	/** Deletes one notification: unknown id -> 401, success -> 200. */
	static function accountNotificationDelete(request:HttpRequest, rawId:String):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var id = StringTools.urlDecode(rawId == null ? "" : rawId);
		if (!AccountStore.deleteNotification(access.account, id)) return fail(401, "No such notification");
		return plain(200, "OK");
	}

	// ------------------------------------------------------------------
	// details / scores
	// ------------------------------------------------------------------

	/**
	 * /api/user/friends/request. Missing name -> 400; unknown target -> 404; already friends ->
	 * 400 ("Already frens :)"); mutual request -> add both ways + notify the target + push WS
	 * to self -> 200; already sent -> 200 (no duplicate, no notification); otherwise write to
	 * the target's friendRequests + notify -> 200.
	 */
	static function userFriendRequest(request:HttpRequest, hub:ServerHub):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var me = access.account;

		var name = query(request).get("name");
		if (name == null || name == "") return fail(400, "missing name");

		var target = AccountStore.byNameExact(name);
		if (target == null) return fail(404, "Target not found!");

		switch (AccountStore.addFriendRequest(me, target)) {
			case "already":
				return fail(400, "Already frens :)");
			case "mutual":
				// Order: notify the target first, then push the WS message to the caller.
				sendNotification(hub, target, "Friend Request Accepted",
					"You are now friends with " + me.name + "!",
					"/api/user/avatar/" + StringTools.urlEncode(me.name),
					"/user/" + StringTools.urlEncode(me.name));
				notifyPlayer(hub, me.name, "You are now friends with " + target.name + "!");
				return plain(200, "OK");
			case "duplicate":
				return plain(200, "OK");
			case "sent":
				sendNotification(hub, target, "Friend Request",
					me.name + " sent you a friend request!",
					"/api/user/avatar/" + StringTools.urlEncode(me.name),
					"/user/" + StringTools.urlEncode(me.name));
				return plain(200, "OK");
			case "error":
				return fail(400, "Player not found");
			default:
				return fail(400, "Unknown error...");
		}
	}

	/**
	 * /api/user/friends/remove. Missing name -> 400; unknown or not a friend -> 400
	 * ("Not on friend list"); mutual removal -> 200. `name` is the person to remove, the
	 * authenticated identity is self.
	 */
	static function userFriendRemove(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;

		var name = query(request).get("name");
		if (name == null || name == "") return fail(400, "missing name");

		var target = AccountStore.byNameExact(name);
		if (target == null) return fail(400, "Player not found");

		if (!AccountStore.removeFriendBetween(target, access.account)) return fail(400, "Not on friend list");
		return plain(200, "OK");
	}

	/**
	 * Writes into the target's notifications, then pushes the content (or title) over the
	 * network room.
	 */
	static function sendNotification(hub:ServerHub, to:Account, title:String, content:String, image:String, href:String):Void {
		AccountStore.addNotification(to, title, content, image, href);
		notifyPlayer(hub, to.name, content != null && content != "" ? content : title);
	}

	/** The WS push half, implemented in Main.ServerHub.notifyPlayer. */
	static function notifyPlayer(hub:ServerHub, name:String, content:String):Void {
		if (hub != null) hub.notifyPlayer(name, content);
	}

	/**
	 * /api/user/details. `friends` is the real friend list and `canFriend` looks at the target's
	 * friendRequests. `warns` is always [] and `ng` mirrors account.ngUrl. `isSelf` only checks
	 * the credential (not access rights).
	 */
	static function userDetails(request:HttpRequest):HttpResponse {
		var params = query(request);
		var name = params.get("name");
		if (name == null || name == "") return fail(400, "missing name");

		var viewer = authAccount(request);
		var account = AccountStore.byNameExact(name);
		if (account == null) return fail(404, "user not found");

		var friends = AccountStore.friendNames(account);
		var warns:Array<Dynamic> = [];
		return json(200, {
			role: roleName(account),
			joined: JsonStore.isoOf(account.createdAt),
			lastActive: JsonStore.isoOf(account.lastActive),
			isSelf: viewer != null && viewer.id == account.id,
			bio: account.bio,
			friends: friends,
			canFriend: AccountStore.canFriend(account, viewer == null ? null : viewer.id),
			profileHue: account.profileHue,
			profileHue2: account.profileHue2,
			points: account.points,
			avgAccuracy: account.avgAccuracy,
			rank: AccountStore.rankOf(account.id),
			country: account.country,
			club: ClubStore.tagOf(account.id),
			ng: account.ngUrl,
			warns: warns
		});
	}

	/**
	 * /api/user/scores. `name` is the readable song name: the songId without its last segment
	 * (the chart hash).
	 */
	static function userScores(request:HttpRequest):HttpResponse {
		var params = query(request);
		var name = params.get("name");
		if (name == null || name == "") return fail(400, "missing name");

		var account = AccountStore.byNameExact(name);
		if (account == null) return fail(404, "user not found");

		var entries = LeaderboardStore.playerScores(
			account.id,
			parseIntParam(params, "page", 0),
			parseIntParam(params, "keys", 4),
			params.get("category"),
			params.get("sort")
		);

		var out:Array<Dynamic> = [];
		for (s in entries) {
			var parts = s.songId.split("-");
			if (parts.length > 0) parts.pop();
			out.push({
				name: parts.join(" "),
				songId: s.songId,
				strum: s.strum,
				score: s.score,
				accuracy: s.accuracy,
				points: s.points,
				submitted: s.submitted,
				id: s.id,
				modURL: s.modURL,
				misses: s.misses
			});
		}
		return json(200, out);
	}

	// ------------------------------------------------------------------
	// delete / set/modurl
	// ------------------------------------------------------------------

	/**
	 * Deletes one of the caller's own scores; removing someone else's returns 403.
	 */
	static function scoreDelete(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;

		var id = query(request).get("id");
		if (id == null || id == "") return fail(400, "missing id");

		var res = LeaderboardStore.removeScore(id, access.account.id);
		if (!res.ok) return fail(403, res.error == null ? "Unauthorized!" : res.error);
		if (res.playerId != null) AccountStore.setStats(access.account, res.points, res.accuracy, res.games);
		return plain(200, "OK");
	}

	/** Only the score's owner may change its modURL; others get 403, a missing/unknown id gets 400/404. */
	static function scoreSetModURL(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;

		var params = query(request);
		var id = params.get("id");
		if (id == null || id == "") return fail(400, "missing id");

		var score = LeaderboardStore.getScore(id);
		if (score == null) return fail(404, "score not found");
		if (score.player != access.account.id) return fail(403, "Missing permission");

		LeaderboardStore.setModURL(id, params.get("url"));
		return plain(200, "OK");
	}

	// ------------------------------------------------------------------
	// search / stats
	// ------------------------------------------------------------------

	/** A q shorter than 3 characters -> 400 (a bare string); success -> [{id, fp}]. */
	static function searchSongsRoute(request:HttpRequest):HttpResponse {
		var params = query(request);
		var q = params.get("q");
		if (q == null) q = "";
		// 3 CHARACTERS (song titles can be CJK; byte counting accepted a single CJK character).
		if (ServerConfig.utf8Length(StringTools.trim(q)) < 3) return plain(400, "Search query needs to be longer than 3!");
		return json(200, LeaderboardStore.searchSongs(q, parseIntParam(params, "page", 0)));
	}

	/** Same 3-character threshold; output is [{name, role}]. */
	static function searchUsersRoute(request:HttpRequest):HttpResponse {
		var params = query(request);
		var q = params.get("q");
		if (q == null) q = "";
		// 3 CHARACTERS (same threshold as searchSongsRoute).
		if (ServerConfig.utf8Length(StringTools.trim(q)) < 3) return plain(400, "Search query needs to be longer than 3!");
		return json(200, AccountStore.searchUsers(q, parseIntParam(params, "page", 0)));
	}

	/** [[player count, millisecond timestamp], ...]. */
	static function statsDayPlayers(hub:ServerHub):HttpResponse {
		return json(200, PublicStore.recordDayPlayers(hub.onlineCount()));
	}

	/**
	 * {country code: distinct IP count}. There is no IP -> country resolution here, so the
	 * response is always {} (with the right shape).
	 */
	static function statsCountryPlayers():HttpResponse {
		var empty:Dynamic = {};
		return json(200, empty);
	}

	// ------------------------------------------------------------------
	// front / sez / song comments / mod details
	// ------------------------------------------------------------------

	static function front(request:HttpRequest, hub:ServerHub):HttpResponse {
		// Front messages are persisted by PublicStore (/api/sez writes, this returns the latest).
		var latest = PublicStore.latestFrontMessage();
		return json(200, {
			online: hub.onlineCount(),
			rooms: hub.publicRoomCount(),
			// Repair on read: a row written by an older build could carry invalid UTF-8 (2-D1 class).
			sez: latest == null ? "" : ServerConfig.repairUtf8(latest.message),
			// Additive field: the console announcement stored in config.toml, so a player who was not
			// connected when it was published can still see the current announcement. online / rooms /
			// sez keep their existing values and types.
			announcement: ServerConfig.announcement()
		});
	}

	/**
	 * POST /api/sez. A missing message -> 418; >= 100 chars or a newline -> 413; the same player
	 * just posted -> 418; success -> 200. The client only checks isFailed.
	 */
	static function postSez(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var account = access.account;
		var body = parseBody(request);
		if (body == null) return fail(400, "Invalid JSON body");
		var message = strOf(body, "message");
		if (message == null || message == "") return plain(418, "I'm a teapot");
		// 100 CHARACTERS, not bytes: String.length counts UTF-8 bytes on neko/hxcpp, so the old check
		// rejected a 34-character CJK message (102 bytes) that is well under the documented cap.
		if (ServerConfig.utf8Length(message) >= 100 || message.indexOf("\n") >= 0) return plain(413, "Payload Too Large");
		if (!PublicStore.addFrontMessage(account.name, StringTools.trim(message))) return plain(418, "I'm a teapot");
		return plain(200, "OK");
	}

	static function getComments(request:HttpRequest):HttpResponse {
		var params = query(request);
		var id = params.get("id");
		if (id == null || id == "") return fail(400, "missing id");
		return json(200, publicComments(LeaderboardStore.comments(id)));
	}

	static function postComment(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var account = access.account;
		var body = parseBody(request);
		if (body == null) return fail(400, "Invalid JSON body");

		var id = strOf(body, "id");
		var content = strOf(body, "content");
		if (id == null || id == "") return fail(400, "missing id");
		if (content == null || StringTools.trim(content) == "") return fail(400, "Empty comment");

		// A missing/non-numeric "at" must become a real timestamp: NaN formats as SQL NULL, and the
		// comments.at column is NOT NULL, so the old default made every such post fail with a 500.
		var at:Float = Date.now().getTime();
		var atField:Dynamic = null;
		try atField = Reflect.field(body, "at") catch (e:Dynamic) atField = null;
		if (atField != null && (Std.isOfType(atField, Float) || Std.isOfType(atField, Int))) at = cast atField;

		return json(200, publicComments(LeaderboardStore.addComment(account.name, id, content, at)));
	}

	static function publicComments(entries:Array<LeaderboardStore.CommentEntry>):Array<Dynamic> {
		var out:Array<Dynamic> = [];
		for (c in entries) out.push({ player: c.player, content: c.content, at: c.at });
		return out;
	}

	/**
	 * GET /api/mod/details/:mod_id. Includes downloads and 404s when not found; the favorited
	 * account-id array is mapped to names. The client calls this (FunkinNetwork.fetchMod).
	 */
	static function modDetails(rawId:String):HttpResponse {
		var id = StringTools.urlDecode(rawId == null ? "" : rawId);
		if (id == "") return fail(404, "mod not found");
		var detail = ModStore.details(id);
		if (detail == null) return fail(404, "mod not found");
		var ids:Array<String> = cast Reflect.field(detail, "favorited");
		Reflect.setField(detail, "favorited", AccountStore.namesOf(ids));
		return json(200, detail);
	}

	/**
	 * GET /mod/:mod_id/dl/:dl_id -> 302 to the resolved download address, or 404 when the
	 * download is missing or has no URLs. No HEAD probe is sent, so an empty url list is the
	 * 404 case. Note the path has no /api/ prefix; handle()'s default branch picks it up.
	 */
	static function modDownloadRedirect(path:String):HttpResponse {
		var rest = path.substr("/mod/".length);
		var parts = rest.split("/");
		if (parts.length != 3 || parts[1] != "dl") return null;
		var full = StringTools.urlDecode(parts[0]) + ":" + StringTools.urlDecode(parts[2]);
		var picked = ModStore.pickDownloadURL(full);
		if (picked == null) return plain(404, "Not Found");
		var headers = new Map<String, String>();
		headers.set("Location", picked);
		// The 302 body keeps the standard redirect text.
		return { status: 302, contentType: "text/plain", body: "Found. Redirecting to " + picked, headers: headers };
	}

	/** POST /api/mod/dl/submit (protected, logged). */
	static function modDownloadSubmit(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		adminLog(access.account, request);
		var body = parseBody(request);
		if (body == null) return fail(400, "None found...");
		var modId = strOf(body, "mod_id");
		if (modId == null || modId == "") return fail(400, "None found...");
		var err = ModStore.addDownload(modId, strOf(body, "id"), strArrayOf(body, "urls"));
		if (err != null) return fail(400, err);
		return ok();
	}

	/** POST /api/mod/dl/delete (errors use "None found..."). */
	static function modDownloadDelete(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		adminLog(access.account, request);
		var body = parseBody(request);
		if (body == null) return fail(400, "None found...");
		var err = ModStore.removeDownload(strOf(body, "id"));
		if (err != null) return fail(400, err);
		return ok();
	}

	/** POST /api/mod/dl/edit (errors use "Failed to submit..."). */
	static function modDownloadEdit(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		adminLog(access.account, request);
		var body = parseBody(request);
		if (body == null) return fail(400, "Failed to submit...");
		var err = ModStore.editDownload(strOf(body, "id"), strArrayOf(body, "urls"));
		if (err != null) return fail(400, err);
		return ok();
	}

	/** POST /api/mod/fav: not logged, and a bare 200 on success. */
	static function modFav(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var body = parseBody(request);
		if (body == null) return fail(400, "Failed to submit...");
		var result = ModStore.toggleFav(access.account.id, strOf(body, "id"));
		if (result.error != null) return fail(400, result.error);
		return ok();
	}

	/** POST /api/mod/submit: returns the created mod record. */
	static function modSubmit(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		adminLog(access.account, request);
		var body = parseBody(request);
		if (body == null) return fail(400, "Failed to submit...");
		var result = ModStore.create(body);
		if (result.error != null) return fail(400, result.error);
		return json(200, ModStore.viewOf(result.mod));
	}

	/** POST /api/mod/edit: returns the updated mod record. */
	static function modEdit(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		adminLog(access.account, request);
		var body = parseBody(request);
		if (body == null) return fail(400, "Failed to submit...");
		var result = ModStore.edit(body);
		if (result.error != null) return fail(400, result.error);
		return json(200, ModStore.viewOf(result.mod));
	}

	/** POST /api/mod/delete: an empty 200 on success. */
	static function modDelete(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		adminLog(access.account, request);
		var body = parseBody(request);
		if (body == null) return fail(400, "Failed to submit...");
		var err = ModStore.remove(body);
		if (err != null) return fail(400, err);
		return plain(200, "");
	}

	// ------------------------------------------------------------------
	// Leaderboard / scores
	// ------------------------------------------------------------------

	static function scoreSubmit(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var account = access.account;

		var body = parseBody(request);
		if (body == null) return fail(400, "Invalid JSON body");

		var result = LeaderboardStore.submit(account, body);
		if (!result.ok) return fail(400, result.error);
		AccountStore.addStats(account, result.entry.points, result.entry.accuracy);
		// Recompute club points after updating player stats.
		refreshClubPoints(ClubStore.tagOf(account.id));
		return json(200, { ok: true, id: result.entry.id, songId: result.entry.songId });
	}

	static function scoreReport(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var account = access.account;

		var body = parseBody(request);
		if (body == null) return fail(400, "Invalid JSON body");
		var entry = LeaderboardStore.report(account, strOf(body, "content"));
		return json(200, { ok: true, id: entry.id });
	}

	static function scoreReplay(request:HttpRequest):HttpResponse {
		var params = query(request);
		var id = params.get("id");
		if (id == null || id == "") return fail(400, "missing id");

		var score = LeaderboardStore.getScore(id);
		if (score == null) return fail(404, "score not found");

		var replay:Dynamic = null;
		try replay = Json.parse(score.replay) catch (e:Dynamic) replay = null;
		if (replay == null) return fail(404, "replay not found");
		Reflect.setField(replay, "player", score.playerName);
		Reflect.setField(replay, "songId", score.songId);
		return json(200, replay);
	}

	static function topSong(request:HttpRequest):HttpResponse {
		var params = query(request);
		var song = params.get("song");
		if (song == null || song == "") return fail(400, "missing song");

		var strum = parseIntParam(params, "strum", 2);
		var page = parseIntParam(params, "page", 0);
		var keys = parseIntParam(params, "keys", 4);
		var category = params.get("category");
		var sort = params.get("sort");

		var entries = LeaderboardStore.topSongs(song, strum, page, keys, category, sort);
		var out:Array<Dynamic> = [];
		for (s in entries) {
			out.push({
				score: s.score,
				accuracy: s.accuracy,
				points: s.points,
				player: s.playerName,
				submitted: s.submitted,
				id: s.id,
				misses: s.misses,
				modURL: s.modURL,
				sicks: s.sicks,
				goods: s.goods,
				bads: s.bads,
				shits: s.shits,
				playbackRate: s.playbackRate
			});
		}
		return json(200, out);
	}

	static function topPlayers(request:HttpRequest):HttpResponse {
		var params = query(request);
		var page = parseIntParam(params, "page", 0);
		var sortField = params.get("sort");
		if (sortField == null || ["points", "avgAccuracy"].indexOf(sortField) < 0) sortField = "points";

		var accounts = AccountStore.snapshot();
		accounts.sort(function(a:Account, b:Account) {
			var va = sortField == "avgAccuracy" ? a.avgAccuracy : a.points;
			var vb = sortField == "avgAccuracy" ? b.avgAccuracy : b.points;
			if (va < vb) return 1;
			if (va > vb) return -1;
			return 0;
		});

		var start = (page <= 0 ? 0 : page) * LeaderboardStore.PAGE_ROWS;
		var out:Array<Dynamic> = [];
		var i = start;
		while (i < accounts.length && out.length < LeaderboardStore.PAGE_ROWS) {
			var a = accounts[i];
			var obj:Dynamic = {
				player: a.name,
				profileHue: a.profileHue,
				profileHue2: null,
				country: null,
				// Club tag for the player.
				club: ClubStore.tagOf(a.id)
			};
			Reflect.setField(obj, sortField, sortField == "avgAccuracy" ? a.avgAccuracy : a.points);
			out.push(obj);
			i++;
		}
		return json(200, out);
	}

	static function adminSongSubmit(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var account = access.account;
		if (!isAdmin(account)) return fail(403, "Missing permission");
		var body = parseBody(request);
		if (body == null) return fail(400, "Invalid JSON body");
		return json(200, { ok: true, id: strOf(body, "id") });
	}

	// ------------------------------------------------------------------
	// Clubs
	// ------------------------------------------------------------------

	/**
	 * GET /api/club/details. Leaders sort first, then members by descending points; `created`
	 * is an ISO string.
	 */
	static function clubDetails(request:HttpRequest):HttpResponse {
		var tag = query(request).get("tag");
		if (tag == null || tag == "") return plain(400, "Bad Request");
		var club = ClubStore.byTag(tag);
		if (club == null) return fail(400, "No club!");

		var members:Array<Dynamic> = [];
		for (id in club.members) {
			var a = AccountStore.byId(id);
			if (a == null) continue;
			members.push({
				player: a.name,
				points: a.points,
				profileHue: a.profileHue,
				profileHue2: a.profileHue2,
				country: a.country
			});
		}
		var leaders:Array<String> = [];
		for (id in club.leaders) {
			var a = AccountStore.byId(id);
			if (a != null) leaders.push(a.name);
		}
		members.sort(function(x:Dynamic, y:Dynamic) {
			var xn = Std.string(Reflect.field(x, "player"));
			var yn = Std.string(Reflect.field(y, "player"));
			var lx = leaders.indexOf(xn) >= 0;
			var ly = leaders.indexOf(yn) >= 0;
			if (lx != ly) return lx ? -1 : 1;
			var px:Float = Reflect.field(x, "points");
			var py:Float = Reflect.field(y, "points");
			if (px < py) return 1;
			if (px > py) return -1;
			return 0;
		});

		return json(200, {
			name: club.name,
			tag: club.tag,
			members: members,
			leaders: leaders,
			content: club.content,
			created: JsonStore.isoOf(club.createdAt),
			points: club.points,
			rank: ClubStore.rank(club.tag),
			hue: club.hue
		});
	}

	/** GET /api/club/banner/:tag: no banner -> 404, otherwise raw bytes. */
	static function clubBanner(rawTag:String):HttpResponse {
		var tag = StringTools.urlDecode(rawTag == null ? "" : rawTag);
		if (tag == "") return plain(400, "Bad Request");
		var club = ClubStore.byTag(tag);
		if (club == null || club.banner == null) return plain(404, "Not Found");
		var data:Bytes = null;
		try data = Base64.decode(club.banner) catch (e:Dynamic) data = null;
		if (data == null) return plain(404, "Not Found");
		return bytes(200, data, "application/octet-stream");
	}

	/** GET /api/club/pending: leaders only. */
	static function clubPending(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var account = access.account;

		var club = ClubStore.byMemberId(account.id);
		if (club == null) return fail(400, "You are not in a club!");
		if (club.leaders.indexOf(account.id) < 0) return fail(400, "Only club leaders can do that!");

		var pending:Array<String> = [];
		for (id in club.pending) {
			var a = AccountStore.byId(id);
			if (a != null) pending.push(a.name);
		}
		return json(200, pending);
	}

	/**
	 * POST /api/club/create. Requires at least 250 points; success returns the bare tag string.
	 */
	static function clubCreate(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var account = access.account;

		if (ClubStore.byMemberId(account.id) != null) return fail(400, "You're already in a club!");
		if (account.points < 250) return fail(400, "You need at least 4k 250FP!");

		var body = parseBody(request);
		if (body == null) return fail(400, "Missing fields!");
		var name = strOf(body, "name");
		var tag = strOf(body, "tag");
		if (name == null || tag == null || StringTools.trim(name) == "" || StringTools.trim(tag) == "") {
			return fail(400, "Missing fields!");
		}

		var res = ClubStore.create(account.id, name, tag, account.points);
		if (res.error != null) return fail(400, res.error);
		return plain(200, res.club.tag);
	}

	/** GET /api/club/join: request to join and notify every leader. */
	static function clubJoin(request:HttpRequest, hub:ServerHub):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var account = access.account;

		var tag = query(request).get("tag");
		if (tag == null || tag == "") return plain(400, "Bad Request");
		var club = ClubStore.byTag(tag);
		if (club == null) return plain(400, "No club!");

		var err = ClubStore.requestJoin(tag, account.id);
		if (err != null) return plain(400, err);

		for (leaderId in club.leaders) {
			var leader = AccountStore.byId(leaderId);
			if (leader == null) continue;
			sendNotification(hub, leader, "Club Join Request", account.name + " wants to join your club!",
				"/api/user/avatar/" + StringTools.urlEncode(account.name), "/club/" + tag);
		}
		return ok();
	}

	/** GET /api/club/accept: a leader accepts a pending request. */
	static function clubAccept(request:HttpRequest, hub:ServerHub):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var account = access.account;

		var userName = query(request).get("user");
		if (userName == null || userName == "") return plain(400, "Bad Request");
		var club = ClubStore.byMemberId(account.id);
		if (club == null) return plain(400, "You are not in a club!");
		if (club.leaders.indexOf(account.id) < 0) return plain(400, "Only club leaders can do that!");

		var target = AccountStore.byNameExact(userName);
		// An unknown user is treated as having no pending request.
		if (target == null) return plain(400, "The user hasn't sent a request!");

		var err = ClubStore.acceptJoin(club.tag, target.id);
		if (err != null) return plain(400, err);
		refreshClubPoints(club.tag);
		sendNotification(hub, target, "Club Join", "You've been accepted to the " + club.tag + " club!",
			"/api/user/avatar/" + StringTools.urlEncode(target.name), "/club/" + club.tag);
		return ok();
	}

	/** GET /api/club/reject: a leader rejects a request. */
	static function clubReject(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var account = access.account;

		var userName = query(request).get("user");
		if (userName == null || userName == "") return plain(400, "Bad Request");
		var club = ClubStore.byMemberId(account.id);
		if (club == null) return plain(400, "You are not in a club!");
		if (club.leaders.indexOf(account.id) < 0) return plain(400, "Only club leaders can do that!");

		var target = AccountStore.byNameExact(userName);
		if (target == null) return plain(400, "The user hasn't sent a request!");
		var err = ClubStore.rejectJoin(club.tag, target.id);
		if (err != null) return plain(400, err);
		return ok();
	}

	/** GET /api/club/kick: a leader removes a member. */
	static function clubKick(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var account = access.account;

		var userName = query(request).get("user");
		if (userName == null || userName == "") return plain(400, "Bad Request");
		var club = ClubStore.byMemberId(account.id);
		if (club == null) return plain(400, "You are not in a club!");

		var target = AccountStore.byNameExact(userName);
		if (target == null) return plain(400, "Unknown user...");
		if (target.id == account.id) return plain(400, "You cannot kick yourself!");
		if (club.leaders.indexOf(account.id) < 0) return plain(400, "Only club leaders can do that!");

		var targetClub = ClubStore.byMemberId(target.id);
		if (targetClub == null || targetClub.tag != club.tag) return plain(400, "You can't manage this club!");

		var tag = club.tag;
		ClubStore.removeMember(target.id);
		refreshClubPoints(tag);
		return ok();
	}

	/** GET /api/club/promote: a leader promotes a member. */
	static function clubPromote(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var account = access.account;

		var userName = query(request).get("user");
		if (userName == null || userName == "") return plain(400, "Bad Request");
		var club = ClubStore.byMemberId(account.id);
		if (club == null) return plain(400, "You are not in a club!");

		var target = AccountStore.byNameExact(userName);
		if (target == null) return plain(400, "Unknown user...");
		if (club.leaders.indexOf(account.id) < 0) return plain(400, "Only club leaders can do that!");

		var targetClub = ClubStore.byMemberId(target.id);
		if (targetClub == null || targetClub.tag != club.tag) return plain(400, "You can't manage this club!");

		var err = ClubStore.promote(club.tag, target.id);
		if (err != null) return plain(400, err);
		return ok();
	}

	/** GET /api/club/demote: a leader demotes a member. */
	static function clubDemote(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var account = access.account;

		var userName = query(request).get("user");
		if (userName == null || userName == "") return plain(400, "Bad Request");
		var club = ClubStore.byMemberId(account.id);
		if (club == null) return plain(400, "You are not in a club!");

		var target = AccountStore.byNameExact(userName);
		if (target == null) return plain(400, "Unknown user...");
		if (club.leaders.indexOf(account.id) < 0) return plain(400, "Only club leaders can do that!");

		var targetClub = ClubStore.byMemberId(target.id);
		if (targetClub == null || targetClub.tag != club.tag) return plain(400, "You can't manage this club!");

		var err = ClubStore.demote(club.tag, target.id);
		if (err != null) return plain(400, err);
		return ok();
	}

	/** GET /api/club/leave: the caller leaves the club. */
	static function clubLeave(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var account = access.account;

		var club = ClubStore.byMemberId(account.id);
		if (club == null) return plain(400, "You are not in a club!");
		var tag = club.tag;
		ClubStore.removeMember(account.id);
		refreshClubPoints(tag);
		return ok();
	}

	/**
	 * POST /api/club/edit. admin.club.edit (Moderator+) may force changes; a tag change has a
	 * 7-day cooldown keyed by "club.<clubId>". The cooldown message does not include the
	 * remaining seconds.
	 */
	static function clubEdit(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var account = access.account;

		var tag = query(request).get("tag");
		if (tag == null || tag == "") return fail(400, "Invalid Request!");
		var club = ClubStore.byTag(tag);
		if (club == null) return fail(400, "No club!");

		var canForce = hasAccess(account, "admin.club.edit");
		if (!canForce && club.leaders.indexOf(account.id) < 0) return fail(400, "Only club leaders can do that!");

		var body = parseBody(request);
		if (body == null) return fail(400, "Invalid JSON body");
		var name = strOf(body, "name");
		var newTag = strOf(body, "tag");
		if (name == null || newTag == null) return fail(400, "Missing fields!");

		var terr = ClubStore.tagFormatError(newTag);
		if (terr != null) return fail(400, terr);
		var upper = ClubStore.upperTag(newTag);
		if (upper != tag) {
			var other = ClubStore.byTag(upper);
			if (other != null && other.tag != club.tag) return fail(400, "Tag taken!");
			if (!canForce && !cooldownOk("club." + club.id, "club.edit.tag")) {
				return fail(400, "Tag change is on cooldown!");
			}
		}

		var content = strOf(body, "content");
		if (content != null) content = sanitizeText(content);
		var hue = numOfDefault(body, "hue", 250);
		if (hue > 360) hue = 360;
		if (hue < 0) hue = 0;

		var err = ClubStore.edit(tag, name, content, hue, upper);
		if (err != null) return fail(400, err);
		return ok();
	}

	/**
	 * POST /api/club/banner?tag=. The multipart body is parsed locally and the dimensions are
	 * read from the image header only (no canvas).
	 */
	static function clubBannerUpload(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var account = access.account;

		var tag = query(request).get("tag");
		if (tag == null || tag == "") return fail(400, "Invalid Request!");
		var club = ClubStore.byTag(tag);
		if (club == null) return fail(400, "No club!");
		if (!hasAccess(account, "admin.club.edit") && club.leaders.indexOf(account.id) < 0) {
			return fail(400, "Only club leaders can do that!");
		}

		var file = firstFilePart(request);
		if (file == null) return fail(400, "Couldn't upload...");
		if (file.data.length > 1024 * 350) return plain(413, "Payload Too Large");

		var mt = file.contentType == null ? "" : file.contentType.toLowerCase();
		if (mt != "image/png" && mt != "image/jpeg" && mt != "image/gif") {
			return plain(415, "Unsupported Media Type");
		}

		var size = imageSize(file.data);
		if (size.error != null) return json(500, { error: size.error });
		// Both dimensions must match exactly, so this uses ||.
		if (size.w != 256 || size.h != 128) return json(400, { error: "Image must be in size of 256x128!" });

		ClubStore.setBanner(tag, Base64.encode(file.data), mt);
		return ok();
	}

	/** GET /api/top/clubs: page is required; take 15, skip 15*page. */
	static function topClubs(request:HttpRequest):HttpResponse {
		var params = query(request);
		var rawPage = params.get("page");
		if (rawPage == null || rawPage == "") return plain(400, "Bad Request");
		var out:Array<Dynamic> = [];
		for (c in ClubStore.top(parseIntParam(params, "page", 0))) {
			out.push({ name: c.name, points: c.points, tag: c.tag, hue: c.hue });
		}
		return json(200, out);
	}

	/** GET /api/account/club: not in a club -> 404, otherwise the bare tag string. */
	static function accountClub(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var tag = ClubStore.tagOf(access.account.id);
		if (tag == null) return plain(404, "Not Found");
		return plain(200, tag);
	}

	/** GET /api/admin/club/delete. */
	static function adminClubDelete(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		adminLog(access.account, request);
		var tag = query(request).get("tag");
		if (tag == null || tag == "") return fail(400, "missing tag");
		// An unknown tag returns 404.
		if (!ClubStore.delete(tag)) return fail(404, "club not found");
		return ok();
	}

	/** GET /api/admin/club/updatefp. */
	static function adminClubUpdatePoints(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		adminLog(access.account, request);
		var tag = query(request).get("tag");
		if (tag == null || tag == "") return fail(400, "missing tag");
		if (ClubStore.byTag(tag) == null) return fail(404, "club not found");
		refreshClubPoints(tag);
		return ok();
	}

	/** Recomputes club points: member accounts are read outside the lock, then written back. */
	static function refreshClubPoints(tag:String):Void {
		if (tag == null) return;
		var club = ClubStore.byTag(tag);
		if (club == null) return;
		var total = 0.0;
		for (id in club.members) {
			var a = AccountStore.byId(id);
			if (a != null) total += a.points;
		}
		ClubStore.setPoints(tag, total);
	}

	/** Strips angle brackets (same rule as the bio). */
	static function sanitizeText(s:String):String {
		if (s == null) return null;
		return StringTools.replace(StringTools.replace(s, "<", ""), ">", "");
	}

	static function bytes(status:Int, data:Bytes, contentType:String):HttpResponse {
		return { status: status, contentType: contentType, body: "", bodyBytes: data };
	}

	// ------------------------------------------------------------------
	// multipart/form-data + image header dimensions (only for /api/club/banner)
	// ------------------------------------------------------------------

	static function multipartBoundary(request:HttpRequest):String {
		var ct = request.headers.get("content-type");
		if (ct == null) return null;
		var idx = ct.toLowerCase().indexOf("boundary=");
		if (idx < 0) return null;
		var b = StringTools.trim(ct.substr(idx + 9));
		if (b.length > 1 && b.charAt(0) == '"') b = b.substr(1, b.length - 2);
		return b;
	}

	static function findBytes(hay:Bytes, needle:Bytes, from:Int):Int {
		if (hay == null || needle == null || needle.length == 0) return -1;
		var limit = hay.length - needle.length;
		var i = from < 0 ? 0 : from;
		while (i <= limit) {
			var j = 0;
			while (j < needle.length && hay.get(i + j) == needle.get(j)) j++;
			if (j == needle.length) return i;
			i++;
		}
		return -1;
	}

	static function sliceBytes(b:Bytes, start:Int, len:Int):Bytes {
		var out = Bytes.alloc(len);
		var i = 0;
		while (i < len) {
			out.set(i, b.get(start + i));
			i++;
		}
		return out;
	}

	/** Returns the first name="file" part of the multipart body. */
	static function firstFilePart(request:HttpRequest):{contentType:String, data:Bytes} {
		var body = request.bodyBytes;
		if (body == null) return null;
		var boundary = multipartBoundary(request);
		if (boundary == null) return null;

		var dash = Bytes.ofString("--" + boundary);
		var headSep = Bytes.ofString("\r\n\r\n");
		var pos = findBytes(body, dash, 0);
		while (pos >= 0) {
			var start = pos + dash.length;
			var hs = findBytes(body, headSep, start);
			if (hs < 0) break;
			var rawHead = sliceBytes(body, start, hs - start).toString();
			var dataStart = hs + headSep.length;
			var next = findBytes(body, dash, dataStart);
			if (next < 0) break;
			var dataEnd = next;
			if (dataEnd >= 2 && body.get(dataEnd - 2) == 13 && body.get(dataEnd - 1) == 10) dataEnd -= 2;
			if (dataEnd < dataStart) break;
			if (rawHead.indexOf('name="file"') >= 0) {
				var ct = "application/octet-stream";
				for (line in rawHead.split("\r\n")) {
					var l = StringTools.trim(line);
					if (StringTools.startsWith(l.toLowerCase(), "content-type:")) ct = StringTools.trim(l.substr(13));
				}
				return { contentType: ct, data: sliceBytes(body, dataStart, dataEnd - dataStart) };
			}
			pos = next;
		}
		return null;
	}

	/** Parses only header dimensions (PNG / GIF / JPEG); this server does not pull in canvas. */
	static function imageSize(data:Bytes):{w:Int, h:Int, error:String} {
		if (data == null || data.length < 10) return { w: 0, h: 0, error: "Server failed to read the image." };
		if (data.length >= 24 && data.get(0) == 0x89 && data.get(1) == 0x50 && data.get(2) == 0x4E && data.get(3) == 0x47) {
			return { w: be32(data, 16), h: be32(data, 20), error: null };
		}
		var magic = sliceBytes(data, 0, 6).toString();
		if (StringTools.startsWith(magic, "GIF")) {
			return { w: le16(data, 6), h: le16(data, 8), error: null };
		}
		if (data.get(0) == 0xFF && data.get(1) == 0xD8) return jpegSize(data);
		return { w: 0, h: 0, error: "Server failed to read the image." };
	}

	static function be32(b:Bytes, off:Int):Int {
		return Std.int(b.get(off) * 16777216.0 + b.get(off + 1) * 65536.0 + b.get(off + 2) * 256.0 + b.get(off + 3));
	}

	static function le16(b:Bytes, off:Int):Int {
		return b.get(off) + b.get(off + 1) * 256;
	}

	static function jpegSize(d:Bytes):{w:Int, h:Int, error:String} {
		var i = 2;
		while (i + 8 < d.length) {
			if (d.get(i) != 0xFF) {
				i++;
				continue;
			}
			var marker = d.get(i + 1);
			if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
				i += 2;
				continue;
			}
			var len = d.get(i + 2) * 256 + d.get(i + 3);
			var isSof = (marker >= 0xC0 && marker <= 0xCF) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
			if (isSof) return { w: d.get(i + 7) * 256 + d.get(i + 8), h: d.get(i + 5) * 256 + d.get(i + 6), error: null };
			i += 2 + len;
		}
		return { w: 0, h: 0, error: "Server failed to read the image." };
	}

	// ------------------------------------------------------------------
	// All admin routes
	// ------------------------------------------------------------------

	/**
	 * Admin route dispatch. handle() routes the /api/admin/ prefix here and returns null when
	 * unmatched.
	 */
	static function handleAdmin(request:HttpRequest, hub:ServerHub):Null<HttpResponse> {
		switch (request.path) {
			case "/api/admin/user/ips": return adminUserIps(request);
			case "/api/admin/user/data": return adminUserData(request);
			case "/api/admin/user/set/email": return adminUserSetEmail(request);
			case "/api/admin/user/delete": return adminUserDelete(request, hub);
			case "/api/admin/user/ban": return adminUserBan(request, hub);
			case "/api/admin/user/warn": return adminUserWarn(request, hub);
			case "/api/admin/user/warn/delete": return adminUserWarnDelete(request);
			case "/api/admin/user/warn/list": return adminUserWarnList(request);
			case "/api/admin/score/delete": return adminScoreDelete(request);
			case "/api/admin/club/delete": return adminClubDelete(request);
			case "/api/admin/club/updatefp": return adminClubUpdatePoints(request);
			case "/api/admin/players": return adminPlayersRoute(request, hub);
			case "/api/admin/reloadconfig": return adminReloadConfig(request);
			case "/api/admin/user/grant": return adminUserGrant(request);
			case "/api/admin/user/notify": return adminUserNotify(request, hub);
			case "/api/admin/user/rename": return adminUserRename(request);
			case "/api/admin/report/list": return adminReportList(request);
			case "/api/admin/report/content": return adminReportContent(request);
			case "/api/admin/report/delete": return adminReportDelete(request);
			case "/api/admin/logs": return adminLogsRoute(request);
			case "/api/admin/logs/process": return adminLogsProcess(request);
			case "/api/admin/cooldown/clear": return adminCooldownClear(request);
			case "/api/admin/endweekly": return adminEndWeekly(request);
			case "/api/admin/updateweekly": return adminUpdateWeekly(request);
			default: return null;
		}
	}

	/** Bare 200 response with body "OK". */
	static function ok():HttpResponse return plain(200, "OK");

	/**
	 * Local read-only console (user ruling D-R3-5). Off by default. When on, the console's own auth
	 * wrapper accepts a GET from a loopback peer without a credential, because the embedded game
	 * host has no admin account at all (ServerOptions.adminEmail is null there), so nobody could
	 * ever log in. requireAccess itself is untouched: writes and non-loopback peers still go
	 * through its four checks, and the LAN is never opened up.
	 */
	static var localConsoleReadOnly:Bool = false;

	/** Stable id of the synthetic read-only session; never stored, never carries a credential. */
	public static inline var LOCAL_CONSOLE_ID:String = "local-console";

	/** Set once by ServerBoot.start() from ServerOptions.localConsoleReadOnly; Api.init stays unchanged. */
	public static function setLocalConsoleReadOnly(on:Bool):Void localConsoleReadOnly = on;

	public static function localConsoleReadOnlyEnabled():Bool return localConsoleReadOnly;

	/** True when this account is the synthetic loopback read-only session. */
	public static function isLocalConsoleAccount(account:Account):Bool {
		return account != null && account.id == LOCAL_CONSOLE_ID;
	}

	static var localConsoleSession:Account = null;

	/**
	 * The synthetic account handed to the console's read endpoints in local read-only mode. It has
	 * no token and only the console path prefix in its access table, so it is useless anywhere the
	 * normal four checks or the admin routes are consulted.
	 */
	static function localConsoleAccount():Account {
		if (localConsoleSession == null) {
			localConsoleSession = {
				id: LOCAL_CONSOLE_ID,
				name: "local-console (read-only)",
				email: "",
				token: null,
				points: 0,
				avgAccuracy: 0,
				games: 0,
				profileHue: 0,
				role: "Member",
				ips: [],
				access: ["/api/console/*"],
				createdAt: 0
			};
		}
		return localConsoleSession;
	}

	/**
	 * Loopback peer: 127.0.0.0/8, "::1", the fully expanded IPv6 loopback, the IPv4-mapped form of a
	 * loopback address, and the literal "localhost".
	 *
	 * Any OTHER string containing a colon is not loopback. The earlier version took the tail after
	 * the last colon and tested it as a dotted quad, so a textual peer such as "evil:127.0.0.1"
	 * matched. request.ip is kernel-assigned, but this check should not rely on that.
	 */
	static function isLoopbackPeer(ip:String):Bool {
		if (ip == null) return false;
		var s = StringTools.trim(ip).toLowerCase();
		if (s == "") return false;
		if (s == "localhost" || s == "::1") return true;
		if (s.indexOf(":") >= 0) {
			// Exactly the expanded IPv6 loopback ...
			if (s == "0:0:0:0:0:0:0:1") return true;
			// ... or the IPv4-mapped spelling "::ffff:a.b.c.d" with a loopback quad in the tail.
			// Everything else with a colon (e.g. "evil:127.0.0.1", "fe80::1") is not loopback.
			if (StringTools.startsWith(s, "::ffff:")) return isLoopbackIpv4(s.substr("::ffff:".length));
			return false;
		}
		return isLoopbackIpv4(s);
	}

	/** Strict dotted-quad test for 127.0.0.0/8: a name like "127.example.com" must not match. */
	static function isLoopbackIpv4(s:String):Bool {
		var parts = s.split(".");
		if (parts.length != 4) return false;
		for (p in parts) {
			if (p.length == 0 || p.length > 3) return false;
			for (i in 0...p.length) {
				var c = p.charCodeAt(i);
				if (c < 48 || c > 57) return false;
			}
		}
		return parts[0] == "127";
	}

	/**
	 * Console: public wrapper around requireAccess (AccessResult is module-private and
	 * ConsoleApi cannot see it). Same semantics: missing credential / no permission -> 401,
	 * rate limited -> 429, right id with wrong token -> 403.
	 *
	 * Local read-only mode (D-R3-5) short-circuits only for a GET whose peer is loopback; every
	 * write and every other peer falls through to the normal four checks below.
	 */
	public static function consoleAuth(request:HttpRequest):{denied:HttpResponse, account:Account} {
		if (localConsoleReadOnly && request.method == "GET" && isLoopbackPeer(request.ip)) {
			return { denied: null, account: localConsoleAccount() };
		}
		var a = requireAccess(request);
		return { denied: a.denied, account: a.account };
	}

	/**
	 * Console: custom cooldown for write actions (timerId decoupled from the request path,
	 * see Api.init). A non-null return means 429 and the caller replies with it directly.
	 */
	public static function consoleCooldown(request:HttpRequest, account:Account, timerId:String):HttpResponse {
		if (account == null) return fail(401, "Not authenticated");
		if (!cooldownOk(account.id, timerId)) return fail(429, "Too many requests");
		return null;
	}

	/** Console: the registered cooldown table (shown on the console's "Cooldowns" page). */
	public static function cooldownTable():Array<Dynamic> {
		var out:Array<Dynamic> = [];
		for (path in cooldownSeconds.keys()) out.push({ path: path, seconds: cooldownSeconds.get(path) });
		out.sort(function(a, b) return Reflect.field(a, "path") < Reflect.field(b, "path") ? -1 : 1);
		return out;
	}

	/**
	 * Records the request URL and body in the mod action log. The read-only routes
	 * (logs / logs/process / cooldown/clear / endweekly / updateweekly) do not log.
	 */
	static function adminLog(account:Account, request:HttpRequest):Void {
		var who = account == null ? null : account.name;
		var url = request.path;
		if (request.query != null && request.query != "") url += "?" + request.query;
		var body = request.body == null ? "" : StringTools.trim(request.body);
		AdminStore.addLog(who, url + " " + body);
	}

	/** Target account lookup for admin endpoints (case-sensitive). */
	static function targetByName(name:String):Account {
		if (name == null || name == "") return null;
		return AccountStore.byNameExact(name);
	}

	/** Account role priority. A null target does not participate. */
	static function priorityOfAccount(a:Account):Int {
		if (a == null) return -10000;
		return AccountStore.priorityOf(AccountStore.normalizeRole(a.role));
	}

	// ---- user ----

	/** Other accounts that share an IP with this account (name array). */
	static function adminUserIps(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		adminLog(access.account, request);
		var target = targetByName(query(request).get("username"));
		if (target == null) return fail(404, "No user found with this name!");
		return json(200, AccountStore.namesOf(AccountStore.sameIpIds(target)));
	}

	/** Full account data (no token / access array; see AccountStore.viewOf). */
	static function adminUserData(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		adminLog(access.account, request);
		var target = targetByName(query(request).get("username"));
		if (target == null) return fail(404, "No user found with this name!");
		return json(200, AccountStore.viewOf(target));
	}

	/** Sets the target account's email and returns the updated account. */
	static function adminUserSetEmail(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		adminLog(access.account, request);
		var target = targetByName(query(request).get("username"));
		if (target == null) return fail(404, "No user found with this name!");
		var err = AccountStore.setEmailById(target.id, query(request).get("email"));
		if (err != null) return fail(400, err);
		return json(200, AccountStore.viewOf(target));
	}

	/** Deletes the account: ban and purge first, then remove the record. */
	static function adminUserDelete(request:HttpRequest, hub:ServerHub):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		adminLog(access.account, request);
		var target = targetByName(query(request).get("username"));
		if (target == null) return fail(404, "No user found with this name!");
		if (priorityOfAccount(target) >= priorityOfAccount(access.account)) return fail(403, "Missing permission");
		// Ban and purge first, then delete the account record.
		AccountStore.setBanRole(target, true, null);
		LeaderboardStore.purgePlayer(target.id, target.name);
		// The cleanup also includes the account's mod favourites.
		ModStore.removeFavoritesOf(target.id);
		hub.disconnectPlayer(target.name);
		AccountStore.remove(target);
		return ok();
	}

	/** Ban / unban; banning first issues a warning. */
	static function adminUserBan(request:HttpRequest, hub:ServerHub):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		adminLog(access.account, request);
		var params = query(request);
		var target = targetByName(params.get("username"));
		if (target == null) return fail(404, "No user found with this name!");
		if (priorityOfAccount(target) >= priorityOfAccount(access.account)) return fail(403, "Missing permission");
		var to = params.get("to") == "true";
		if (to) {
			var reason = params.get("reason");
			// A reason shorter than 5 CHARACTERS is rejected with 500 (bytes let 2 CJK chars pass).
			if (reason == null || ServerConfig.utf8Length(StringTools.trim(reason)) < 5) return fail(500, "Reason too short!");
			sendNotification(hub, target, "You have been warned by a moderator!", "Reason: " + reason, null, null);
			AdminStore.addWarn(target.id, access.account.id, reason);
			AccountStore.setBanRole(target, true, reason);
			LeaderboardStore.purgePlayer(target.id, target.name);
			// The cleanup also includes the account's mod favourites.
			ModStore.removeFavoritesOf(target.id);
			hub.disconnectPlayer(target.name);
			// The in-game nickname may differ from the account name, so kick by account id as well.
			hub.kickAccount(target.id);
		} else {
			AccountStore.setBanRole(target, false, null);
		}
		return ok();
	}

	/** Issues a warning; a reason shorter than 5 characters -> 400. */
	static function adminUserWarn(request:HttpRequest, hub:ServerHub):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		adminLog(access.account, request);
		var params = query(request);
		var target = targetByName(params.get("username"));
		if (target == null) return fail(404, "No user found with this name!");
		if (priorityOfAccount(target) >= priorityOfAccount(access.account)) return fail(403, "Missing permission");
		var reason = params.get("reason");
		// 5 CHARACTERS (same as adminUserBan).
		if (reason == null || ServerConfig.utf8Length(StringTools.trim(reason)) < 5) return fail(400, "Reason too short!");
		sendNotification(hub, target, "You have been warned by a moderator!", "Reason: " + reason, null, null);
		AdminStore.addWarn(target.id, access.account.id, reason);
		return ok();
	}

	/** Deletes one warning. */
	static function adminUserWarnDelete(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		adminLog(access.account, request);
		if (!AdminStore.removeWarn(query(request).get("id"))) return fail(404, "No such warning");
		return ok();
	}

	/** Warning list grouped by player name, skipping banned accounts. */
	static function adminUserWarnList(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		adminLog(access.account, request);
		var out:Dynamic = {};
		for (w in AdminStore.warns()) {
			var target = AccountStore.byId(w.on);
			if (target == null) continue;
			if (AccountStore.normalizeRole(target.role) == "Banned") continue;
			var list:Array<Dynamic> = Reflect.field(out, target.name);
			if (list == null) {
				list = [];
				Reflect.setField(out, target.name, list);
			}
			// The id is included so warn/delete has a usable key.
			list.push({ id: w.id, reason: w.reason, date: w.date });
		}
		return json(200, out);
	}

	/** Grants / revokes a role; the caller cannot act on an equal or higher priority account. */
	static function adminUserGrant(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		adminLog(access.account, request);
		var params = query(request);
		var target = targetByName(params.get("username"));
		if (target == null) return fail(404, "No user found with this name!");
		var role = params.get("role");
		if (priorityOfAccount(target) >= priorityOfAccount(access.account)
			|| AccountStore.priorityOf(AccountStore.normalizeRole(role)) >= priorityOfAccount(access.account))
			return fail(403, "Missing permission");
		if (!AccountStore.setRole(target, role)) return fail(400, "Couldn't grant that role");
		return ok();
	}

	/** Sends a notification to a player (query params title / content / image / href). */
	static function adminUserNotify(request:HttpRequest, hub:ServerHub):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		adminLog(access.account, request);
		var params = query(request);
		var target = targetByName(params.get("user"));
		if (target == null) return fail(404, "No user found with this name!");
		var title = params.get("title");
		sendNotification(hub, target, title == null ? "Notification" : title,
			params.get("content"), params.get("image"), params.get("href"));
		return ok();
	}

	/** Renames the target account; an invalid name -> 400. */
	static function adminUserRename(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		adminLog(access.account, request);
		var params = query(request);
		var target = targetByName(params.get("user"));
		if (target == null) return fail(404, "No user found with this name!");
		var err = AccountStore.renameById(target.id, params.get("new"));
		if (err != null) return fail(400, err);
		return ok();
	}

	// ---- score / players / config ----

	/** Deletes a score without owner checks and recomputes the player's stats. */
	static function adminScoreDelete(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		adminLog(access.account, request);
		var id = query(request).get("id");
		if (id == null || id == "") return fail(400, "missing id");
		var res = LeaderboardStore.removeScore(id, null);
		if (!res.ok) return fail(400, res.error);
		if (res.playerId != null) {
			var owner = AccountStore.byId(res.playerId);
			if (owner != null) AccountStore.setStats(owner, res.points, res.accuracy, res.games);
		}
		return ok();
	}

	/** Room list plus a username -> roomId map. */
	static function adminPlayersRoute(request:HttpRequest, hub:ServerHub):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		adminLog(access.account, request);
		return json(200, hub.adminPlayers());
	}

	/** Reloads config: re-reads the four JSON stores. */
	static function adminReloadConfig(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		adminLog(access.account, request);
		AccountStore.init(AccountStore.storagePath());
		LeaderboardStore.init(LeaderboardStore.storagePath());
		PublicStore.init(PublicStore.storagePath());
		AdminStore.init(AdminStore.storagePath());
		return ok();
	}

	// ---- report ----

	/** Report list; reporter names are stored directly. */
	static function adminReportList(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		adminLog(access.account, request);
		var out:Array<Dynamic> = [];
		for (r in LeaderboardStore.reports())
			out.push({ id: r.id, by: r.reporter, content: r.content, date: r.submitted });
		return json(200, out);
	}

	/** Report content: returned as JSON when it starts with '{', otherwise as text/plain. */
	static function adminReportContent(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		adminLog(access.account, request);
		var report = LeaderboardStore.reportOf(query(request).get("id"));
		if (report == null) return fail(404, "No such report");
		if (StringTools.startsWith(report.content, "{")) return json(200, Json.parse(report.content));
		return plain(200, report.content);
	}

	/** Deletes a report. */
	static function adminReportDelete(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		adminLog(access.account, request);
		if (!LeaderboardStore.removeReport(query(request).get("id"))) return fail(404, "No such report");
		return ok();
	}

	// ---- logs / cooldown / weekly ----

	/** Mod action log. */
	static function adminLogsRoute(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		return json(200, AdminStore.logs());
	}

	/**
	 * Tail of the mod action log: at most `lines` entries, newest first.
	 */
	static function adminLogsProcess(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		var all = AdminStore.logs();
		var lines = parseIntParam(query(request), "lines", -1);
		if (lines <= 0 || lines >= all.length) return json(200, all);
		return json(200, all.slice(0, lines));
	}

	/** Clears the in-memory cooldown registry. */
	static function adminCooldownClear(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		cooldownMutex.acquire();
		cooldownUntil = new Map();
		cooldownMutex.release();
		return ok();
	}

	/** Weekly reset: deletes every "week" category score. */
	static function adminEndWeekly(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		for (id in LeaderboardStore.purgeCategory("week")) {
			var owner = AccountStore.byId(id);
			if (owner == null) continue;
			var stats = LeaderboardStore.statsOf(id);
			AccountStore.setStats(owner, stats.points, stats.accuracy, stats.games);
		}
		return ok();
	}

	/** Recomputes weekly stats from each week player's full score set. */
	static function adminUpdateWeekly(request:HttpRequest):HttpResponse {
		var access = requireAccess(request);
		if (access.denied != null) return access.denied;
		for (id in LeaderboardStore.playerIdsWithCategory("week")) {
			var owner = AccountStore.byId(id);
			if (owner == null) continue;
			var stats = LeaderboardStore.statsOf(id);
			AccountStore.setStats(owner, stats.points, stats.accuracy, stats.games);
		}
		return ok();
	}

	// ------------------------------------------------------------------
	// Access checks
	// ------------------------------------------------------------------

	/** Cooldown table (timerId -> seconds) and the pending id.path -> expiry map. */
	static var cooldownSeconds:Map<String, Float> = new Map();
	static var cooldownUntil:Map<String, Float> = new Map();
	static var cooldownMutex:Mutex = new Mutex();

	/** Registers a cooldown; only registered paths are rate limited. */
	static function registerCooldown(path:String, seconds:Float):Void {
		cooldownSeconds.set(path, seconds);
	}

	/**
	 * One pass per account and path within the window; returns false for a 429. The check runs
	 * before the handler, so a rejected request also spends the cooldown. One thread per HTTP
	 * connection, so the table needs a lock.
	 */
	static function cooldownOk(id:String, path:String):Bool {
		var seconds = cooldownSeconds.get(path);
		if (seconds == null) return true;
		var key = id + "." + path;
		cooldownMutex.acquire();
		var now = haxe.Timer.stamp();
		var until = cooldownUntil.get(key);
		if (until != null && until >= now) {
			cooldownMutex.release();
			return false;
		}
		cooldownUntil.set(key, now + seconds);
		cooldownMutex.release();
		return true;
	}

	/**
	 * Four checks against the local "token is the credential" model:
	 *   1. no credential / unknown player id -> 401
	 *   2. the wildcard access table lacks the path -> 401
	 *   3. the account is rate limited on the path -> 429
	 *   4. the token does not match the account -> 403
	 * denied == null means allowed (account is set), otherwise the denied response is returned.
	 */
	static function requireAccess(request:HttpRequest):AccessResult {
		var cred = credentialOf(request);
		if (cred == null) return { account: null, denied: fail(401, "Not authenticated") };

		var account = AccountStore.byId(cred.id);
		if (account == null) return { account: null, denied: fail(401, "Not authenticated") };

		if (!hasAccess(account, request.path)) return { account: null, denied: fail(401, "Missing permission") };
		if (!cooldownOk(account.id, request.path)) return { account: null, denied: fail(429, "Too many requests") };

		// An expired credential forces a re-login. Legacy accounts have tokenExpiresAt = null
		// and therefore never expire.
		if (account.tokenExpiresAt != null && account.tokenExpiresAt > 0
			&& Date.now().getTime() > account.tokenExpiresAt)
			return { account: null, denied: sessionExpired() };

		if (!AccountStore.verifyToken(account, cred.token)) return { account: null, denied: fail(403, "Invalid token") };

		// Record the IP for the account: unseen IPs only, loopback excluded.
		AccountStore.recordIp(account, request.ip);
		return { account: account, denied: null };
	}

	/** Wildcard access table for the account's role patterns. */
	static function hasAccess(account:Account, to:String):Bool {
		if (account == null || account.access == null) return false;
		for (pattern in account.access) if (wildcardMatch(pattern, to)) return true;
		return false;
	}

	/**
	 * Wildcard match: `*` = any run, `?` = one character, anchored to the whole string,
	 * case-insensitive.
	 */
	static function wildcardMatch(pattern:String, to:String):Bool {
		if (pattern == null || to == null) return false;
		var p = pattern.toLowerCase();
		var t = to.toLowerCase();
		var pi = 0;
		var ti = 0;
		var star = -1;
		var mark = 0;
		while (ti < t.length) {
			if (pi < p.length && (p.charAt(pi) == "?" || p.charAt(pi) == t.charAt(ti))) {
				pi++;
				ti++;
			} else if (pi < p.length && p.charAt(pi) == "*") {
				star = pi;
				mark = ti;
				pi++;
			} else if (star >= 0) {
				pi = star + 1;
				mark++;
				ti = mark;
			} else {
				return false;
			}
		}
		while (pi < p.length && p.charAt(pi) == "*") pi++;
		return pi == p.length;
	}

	/**
	 * Only Basic auth is accepted: HttpServer does not parse cookies, and network-room
	 * identity travels in the WS join options rather than HTTP headers.
	 */
	static function credentialOf(request:HttpRequest):Null<Credential> {
		var header = request.headers.get("authorization");
		if (header == null || !StringTools.startsWith(header, "Basic ")) return null;
		var decoded:String = null;
		try decoded = Base64.decode(header.substr(6)).toString() catch (e:Dynamic) return null;
		if (decoded == null) return null;
		var idx = decoded.indexOf(":");
		if (idx < 0) return null;
		return { id: decoded.substr(0, idx), token: decoded.substr(idx + 1) };
	}

	// ------------------------------------------------------------------
	// Utilities
	// ------------------------------------------------------------------

	/** Role name for output, normalized to lowercase. */
	static function roleName(account:Account):String {
		if (isAdmin(account)) return "admin";
		return AccountStore.normalizeRole(account.role).toLowerCase();
	}

	static function isAdmin(account:Account):Bool {
		if (account == null) return false;
		if (adminEmail != null && account.email != null && account.email.toLowerCase() == adminEmail.toLowerCase()) return true;
		return account.access != null && account.access.indexOf("*") >= 0;
	}

	/** The --admin-email account automatically gets ["*"] on create / login. */
	static function applyAdmin(account:Account):Void {
		if (account == null || adminEmail == null) return;
		if (account.access != null && account.access.indexOf("*") >= 0) return;
		if (account.email != null && account.email.toLowerCase() == adminEmail.toLowerCase()) {
			account.access = ["*"];
			account.role = "Admin";
			// Projected accounts are detached values now, so the grant has to be written explicitly.
			AccountStore.grantRootAccess(account);
		}
	}

	/** The "id and token both match" authentication; only /api/auth/logout still uses it. */
	static function authAccount(request:HttpRequest):Account {
		var cred = credentialOf(request);
		if (cred == null) return null;
		return AccountStore.auth(cred.id, cred.token);
	}

	static function query(request:HttpRequest):Map<String, String> {
		var params = new Map<String, String>();
		var raw = request.query;
		if (raw == null || raw == "") return params;
		for (pair in raw.split("&")) {
			if (pair == "") continue;
			var idx = pair.indexOf("=");
			try {
				if (idx < 0) params.set(StringTools.urlDecode(pair), "");
				else params.set(StringTools.urlDecode(pair.substr(0, idx)), StringTools.urlDecode(pair.substr(idx + 1)));
			} catch (e:Dynamic) {}
		}
		return params;
	}

	static function parseIntParam(params:Map<String, String>, name:String, fallback:Int):Int {
		var raw = params.get(name);
		if (raw == null || raw == "") return fallback;
		var parsed = Std.parseInt(raw);
		return parsed == null ? fallback : parsed;
	}

	static function parseBody(request:HttpRequest):Dynamic {
		if (request.body == null || StringTools.trim(request.body) == "") return null;
		try return Json.parse(request.body) catch (e:Dynamic) return null;
	}

	/** JSON array field -> Array<String> (missing / not an array -> []). */
	static function strArrayOf(o:Dynamic, field:String):Array<String> {
		var out:Array<String> = [];
		try {
			var v = Reflect.field(o, field);
			if (v == null || !Std.isOfType(v, Array)) return out;
			for (item in (cast v : Array<Dynamic>)) out.push(Std.string(item));
		} catch (e:Dynamic) {}
		return out;
	}

	static function strOf(o:Dynamic, field:String):String {
		try {
			var v = Reflect.field(o, field);
			return v == null ? null : Std.string(v);
		} catch (e:Dynamic) return null;
	}

	/** Numeric fields for /api/account/profile/set (missing / unparsable use the fallback). */
	static function numOfDefault(o:Dynamic, field:String, fallback:Float):Float {
		try {
			var v = Reflect.field(o, field);
			if (v == null) return fallback;
			var parsed = Std.parseFloat(Std.string(v));
			return Math.isNaN(parsed) ? fallback : parsed;
		} catch (e:Dynamic) return fallback;
	}

	static function json(status:Int, data:Dynamic):HttpResponse {
		// Response-boundary guarantee: ServerConfig.jsonEncode repairs invalid UTF-8 in every string
		// (legacy rows included) and keeps non-BMP characters intact on the cpp target.
		return { status: status, contentType: "application/json", body: ServerConfig.jsonEncode(data) };
	}

	static function fail(status:Int, message:String):HttpResponse {
		return json(status, { error: message });
	}

	static function plain(status:Int, body:String, ?contentType:String = "text/plain"):HttpResponse {
		// Non-JSON bodies are written as raw UTF-8, so only invalid bytes need repair.
		return { status: status, contentType: contentType, body: ServerConfig.repairUtf8(body) };
	}
}

/** Basic credentials (id + token). */
typedef Credential = {
	var id:String;
	var token:String;
}

/** Result of requireAccess (denied != null means rejected; account is only set when allowed). */
typedef AccessResult = {
	var account:Account;
	var denied:Null<HttpResponse>;
}
