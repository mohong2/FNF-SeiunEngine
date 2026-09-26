package online_server;

import haxe.Json;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import sys.io.FileSeek;
import online_server.Main.ServerHub;
import online_server.HttpServer.HttpRequest;
import online_server.HttpServer.HttpResponse;
import online_server.AccountStore.Account;
import online_server.ClubStore.Club;

/**
 * Server console: JSON endpoints under /api/console/* (page itself is served by ConsoleWeb).
 *
 * Every endpoint goes through Api.consoleAuth = the same four-step checkAccess the game API
 * uses (401 no credential / no access, 429 cooldown, 403 id-vs-token mismatch); write endpoints
 * register a short cooldown so a double click cannot hammer them (a rejected call consumes it).
 * Read endpoints keep no cooldown so they can be polled by the page.
 */
class ConsoleApi {
	/** Mirrors Project.xml / installers; the console does not read the exe. */
	public static inline var VERSION = "0.2.2preonline1";

	public static function handle(request:HttpRequest, hub:ServerHub):Null<HttpResponse> {
		var path = request.path;
		var method = request.method;
		// Write endpoints first: each one spends its own named cooldown (see Api.init), so a
		// rejected call also consumes it, while reads stay free.
		switch (path) {
			case "/api/console/config":
				if (method == "POST") return withWrite(request, "console.config", function(account) return saveConfig(request, hub));
			case "/api/console/reload":
				if (method == "POST") return withWrite(request, "console.reload", function(account) return reloadConfig(hub));
			case "/api/console/announce":
				if (method == "POST") return withWrite(request, "console.announce", function(account) return announce(request, hub));
			case "/api/console/kick":
				if (method == "POST") return withWrite(request, "console.kick", function(account) return kick(request, hub));
			case "/api/console/room/close":
				if (method == "POST") return withWrite(request, "console.room.close", function(account) return closeRoom(request, hub));
			case "/api/console/mod/delete":
				if (method == "POST") return withWrite(request, "console.mod.delete", function(account) return modDelete(request));
			case "/api/console/account/revoke":
				if (method == "POST") return withWrite(request, "console.revoke", function(account) return revoke(request, hub));
			default:
		}
		switch (path) {
			case "/api/console/status": return withAuth(request, function(account) return status(hub, account));
			case "/api/console/rooms": return withAuth(request, function(account) return rooms(hub));
			case "/api/console/players": return withAuth(request, function(account) return players(hub));
			case "/api/console/accounts": return withAuth(request, function(account) return accounts(request));
			case "/api/console/leaderboard": return withAuth(request, function(account) return leaderboard(request));
			case "/api/console/clubs": return withAuth(request, function(account) return clubs(request));
			case "/api/console/mods": return withAuth(request, function(account) return mods(request));
			case "/api/console/comments": return withAuth(request, function(account) return comments(request));
			case "/api/console/logs": return withAuth(request, function(account) return logs(request));
			case "/api/console/config": return withAuth(request, function(account) return config(request));
			default: return null;
		}
	}

	// ------------------------------------------------------------------
	// auth plumbing
	// ------------------------------------------------------------------

	static function withAuth(request:HttpRequest, fn:Account->HttpResponse):HttpResponse {
		var auth = Api.consoleAuth(request);
		if (auth.denied != null) return auth.denied;
		return fn(auth.account);
	}

	/** Console: a write action = requireAccess followed by a named cooldown (429). */
	static function withWrite(request:HttpRequest, timerId:String, fn:Account->HttpResponse):HttpResponse {
		return withAuth(request, function(account) {
			var denied = Api.consoleCooldown(request, account, timerId);
			if (denied != null) return denied;
			return fn(account);
		});
	}

	// ------------------------------------------------------------------
	// read endpoints
	// ------------------------------------------------------------------

	static function status(hub:ServerHub, account:Account):HttpResponse {
		var c = hub.counters();
		return ok({
			version: VERSION,
			protocol: ServerHub.CLIENT_PROTOCOL,
			now: Std.string(Math.ffloor(haxe.Timer.stamp() * 1000)),
			process: {
				args: Sys.args(),
				uptime: Math.ffloor((haxe.Timer.stamp() - c.startedAt) * 1000) / 1000,
				httpRequests: c.httpRequests,
				httpErrors: c.httpErrors,
				wsConnections: c.wsConnections,
				wsAccepted: c.wsAccepted,
				memory: memory(),
				dataDir: Api.storageDir(),
				configPath: ServerConfig.storagePath,
				logFile: logFile(),
				webRoot: ConsoleWeb.root()
			},
			rooms: { total: hub.roomCount(), players: hub.onlineCount(), network: networkCount(hub) },
			stores: {
				accounts: AccountStore.count(),
				scores: LeaderboardStore.count(),
				reports: LeaderboardStore.reportCount(),
				clubs: ClubStore.count(),
				mods: ModStore.count(),
				warns: AdminStore.warns().length,
				actionLog: AdminStore.logs().length,
				frontMessages: PublicStore.frontMessages().length
			},
			config: limitsView(),
			me: { id: account.id, name: account.name, role: AccountStore.normalizeRole(account.role), access: account.access },
			announcement: ServerConfig.limits.announcement,
			configWarnings: ServerConfig.warnings,
			configFile: ServerConfig.fileExists
		});
	}

	static function networkCount(hub:ServerHub):Int {
		var net:Dynamic = Reflect.field(hub.consoleRooms(), "network");
		var members:Dynamic = Reflect.field(net, "members");
		return members == null ? 0 : (cast members : Array<Dynamic>).length;
	}

	static function rooms(hub:ServerHub):HttpResponse return ok(hub.consoleRooms());

	static function players(hub:ServerHub):HttpResponse {
		var data:Dynamic = hub.consoleRooms();
		var out:Array<Dynamic> = [];
		var roomArr:Array<Dynamic> = Reflect.field(data, "rooms");
		for (r in roomArr) {
			var rid = Std.string(Reflect.field(r, "roomId"));
			var list:Array<Dynamic> = cast Reflect.field(r, "players");
			for (p in list) {
				Reflect.setField(p, "roomId", rid);
				out.push(p);
			}
		}
		var members:Array<Dynamic> = Reflect.field(Reflect.field(data, "network"), "members");
		for (m in members) {
			Reflect.setField(m, "roomId", GameRoom.NETWORK_ROOM_ID);
			out.push(m);
		}
		return ok({ total: out.length, rows: out });
	}

	static function accounts(request:HttpRequest):HttpResponse {
		var p = params(request);
		var q = (p.get("q") == null ? "" : p.get("q")).toLowerCase();
		var page = pageOf(p);
		var size = sizeOf(p, 25);
		var all = AccountStore.snapshot();
		var rows:Array<Dynamic> = [];
		for (a in all) {
			if (q != "" && a.name.toLowerCase().indexOf(q) < 0 && (a.email == null || a.email.toLowerCase().indexOf(q) < 0)) continue;
			rows.push(accountView(a));
		}
		rows.sort(function(x, y) return numField(y, "createdAt") > numField(x, "createdAt") ? 1 : -1);
		return ok({ total: rows.length, page: page, size: size, rows: slice(rows, page, size) });
	}

	static function leaderboard(request:HttpRequest):HttpResponse {
		var p = params(request);
		var page = pageOf(p);
		var size = sizeOf(p, 25);
		var q = (p.get("q") == null ? "" : p.get("q")).toLowerCase();
		var rows:Array<Dynamic> = [];
		for (a in AccountStore.snapshot()) {
			if (q != "" && a.name.toLowerCase().indexOf(q) < 0) continue;
			rows.push({
				id: a.id, name: a.name, role: AccountStore.normalizeRole(a.role),
				points: a.points, avgAccuracy: a.avgAccuracy, games: a.games,
				lastActive: a.lastActive, club: ClubStore.tagOf(a.id)
			});
		}
		rows.sort(function(x, y) {
			var d = numField(y, "points") - numField(x, "points");
			return d > 0 ? 1 : (d < 0 ? -1 : 0);
		});
		return ok({ total: rows.length, page: page, size: size, rows: slice(rows, page, size) });
	}

	static function clubs(request:HttpRequest):HttpResponse {
		var p = params(request);
		var page = pageOf(p);
		var rows:Array<Dynamic> = [];
		for (c in ClubStore.top(page)) {
			rows.push({
				tag: c.tag, name: c.name, points: c.points,
				members: c.members.length, pending: c.pending.length, leaders: c.leaders.length,
				createdAt: c.createdAt, banner: c.banner != null && c.banner != ""
			});
		}
		return ok({ total: ClubStore.count(), page: page, size: ClubStore.PAGE_SIZE, rows: rows });
	}

	static function mods(request:HttpRequest):HttpResponse {
		var p = params(request);
		var page = pageOf(p);
		var q = p.get("q") == null ? "" : p.get("q");
		var sort = p.get("sort") == null ? "submitted:desc" : p.get("sort");
		// searchViews has no download list; the console wants the count (and the row action needs ids).
		var rows:Array<Dynamic> = [];
		for (m in ModStore.search(q, page, sort)) {
			rows.push({
				id: m.id,
				title: m.title,
				downloadHits: m.downloadHits,
				favoritedCount: m.favoritedCount,
				submitted: JsonStore.isoOf(m.submitted),
				downloads: m.downloads == null ? 0 : m.downloads.length
			});
		}
		return ok({ total: ModStore.count(), page: page, size: ModStore.PAGE_SIZE, rows: rows });
	}

	static function comments(request:HttpRequest):HttpResponse {
		var p = params(request);
		var page = pageOf(p);
		var size = sizeOf(p, 25);
		var res = LeaderboardStore.recentComments(page, size);
		var rows:Array<Dynamic> = [];
		for (c in res.rows) rows.push({ id: c.id, songId: c.songId, player: c.player, content: c.content, at: c.at });
		return ok({ total: res.total, page: page, size: size, rows: rows });
	}

	static function logs(request:HttpRequest):HttpResponse {
		var p = params(request);
		var lines = clampInt(parseIntParam(p, "lines", 200), 1, 2000);
		var source = p.get("source") == null ? "actions" : p.get("source");
		if (source == "server") {
			var path = logFile();
			var tail = readTail(path, lines);
			return ok({ source: source, path: path, encoding: tail.encoding, lines: tail.lines });
		}
		var all = AdminStore.logs();
		var out = all.length > lines ? all.slice(all.length - lines) : all;
		out.reverse();
		return ok({ source: "actions", path: AdminStore.storagePath(), lines: out });
	}

	static function config(request:HttpRequest):HttpResponse {
		var raw = "";
		try {
			if (ServerConfig.storagePath != null && FileSystem.exists(ServerConfig.storagePath))
				raw = File.getContent(ServerConfig.storagePath);
		} catch (e:Dynamic) raw = "";
		if (raw == "") raw = ServerConfig.toToml();
		return ok({
			path: ServerConfig.storagePath,
			exists: ServerConfig.fileExists,
			raw: raw,
			limits: ServerConfig.limits,
			smtp: ServerConfig.smtpView(),
			smtpDefined: ServerConfig.smtpDefined,
			permissions: ServerConfig.effectiveRoles(),
			codeDefaults: {
				limits: ServerConfig.codeDefaults(),
				permissions: ServerConfig.codeRolesView(),
				smtp: { host: "", port: 25, user: "", pass: "", from: "" }
			},
			backups: ServerConfig.listBackups(),
			warnings: ServerConfig.warnings,
			cooldowns: Api.cooldownTable(),
			args: Sys.args(),
			restartOnly: [
				"ports / host / data-dir / log file are fixed at startup (use server/start.ps1 flags)"
			]
		});
	}

	// ------------------------------------------------------------------
	// write endpoints
	// ------------------------------------------------------------------

	static function saveConfig(request:HttpRequest, hub:ServerHub):HttpResponse {
		var body = parseBody(request);
		if (body == null) return fail(400, "Invalid JSON body");
		var changed = ServerConfig.setFromJson(body);
		var saved = ServerConfig.save();
		if (!saved.ok) return fail(500, "cannot write " + ServerConfig.storagePath + ": " + saved.error);
		applyLive(hub);
		return ok({
			saved: true, path: ServerConfig.storagePath, backup: saved.backup,
			changed: changed, applied: changed, restartRequired: []
		});
	}

	static function reloadConfig(hub:ServerHub):HttpResponse {
		ServerConfig.load(ServerConfig.storagePath);
		applyLive(hub);
		return ok({ reloaded: true, path: ServerConfig.storagePath, limits: ServerConfig.limits, warnings: ServerConfig.warnings });
	}

	static function announce(request:HttpRequest, hub:ServerHub):HttpResponse {
		var body = parseBody(request);
		if (body == null) return fail(400, "Invalid JSON body");
		var text = Std.string(Reflect.field(body, "text") == null ? "" : Reflect.field(body, "text"));
		var broadcast = Reflect.field(body, "broadcast") != false;
		ServerConfig.limits.announcement = StringTools.trim(text).substr(0, 500);
		ServerConfig.save();
		var sent = broadcast && ServerConfig.limits.announcement != "" ? hub.broadcastNotification(ServerConfig.limits.announcement) : 0;
		return ok({ announcement: ServerConfig.limits.announcement, sent: sent });
	}

	/**
	 * Revokes an account's credential: rotate the token (the old one gets 403 at once: right id,
	 * wrong token; /api/auth/refresh on the same old credential takes its own expiry path and
	 * returns 401 expired:true) and kick its current connections so the revocation is visible to
	 * the client. Uses requireAccess' four steps + the named cooldown console.revoke +
	 * AccountStore's own atomic write.
	 */
	static function revoke(request:HttpRequest, hub:ServerHub):HttpResponse {
		var body = parseBody(request);
		var name = body == null ? null : Std.string(Reflect.field(body, "name") == null ? "" : Reflect.field(body, "name"));
		if (name == null || StringTools.trim(name) == "") {
			var p = params(request);
			name = p.get("name");
		}
		if (name == null || StringTools.trim(name) == "") return fail(400, "missing name");

		var account = AccountStore.byName(StringTools.trim(name));
		if (account == null) return fail(404, "player not found: " + name);

		var token = AccountStore.rotateToken(account);
		var kicked = hub.kickAccount(account.id);
		return ok({ name: account.name, id: account.id, revoked: token != null, kicked: kicked });
	}

	static function kick(request:HttpRequest, hub:ServerHub):HttpResponse {
		var body = parseBody(request);
		var name = body == null ? null : Std.string(Reflect.field(body, "name") == null ? "" : Reflect.field(body, "name"));
		if (name == null || StringTools.trim(name) == "") {
			var p = params(request);
			name = p.get("name");
		}
		if (name == null || StringTools.trim(name) == "") return fail(400, "missing name");
		var n = hub.kickPlayer(StringTools.trim(name));
		return ok({ name: StringTools.trim(name), kicked: n });
	}

	/** Console: moderation delete of a mod page (its downloads live inside the record). */
	static function modDelete(request:HttpRequest):HttpResponse {
		var body = parseBody(request);
		var id = body == null ? null : Std.string(Reflect.field(body, "id") == null ? "" : Reflect.field(body, "id"));
		if (id == null || StringTools.trim(id) == "") return fail(400, "missing id");
		id = StringTools.trim(id);
		var mod = ModStore.byId(id);
		if (mod == null) return fail(404, "no such mod");
		var err = ModStore.remove({ id: id });
		if (err != null) return fail(400, err);
		var title = mod.title == null ? "" : mod.title;
		AdminStore.addLog("console", "delete mod " + id + " (" + title + ")");
		return ok({ id: id, deleted: true, title: title });
	}

	static function closeRoom(request:HttpRequest, hub:ServerHub):HttpResponse {
		var body = parseBody(request);
		var roomId = body == null ? null : Std.string(Reflect.field(body, "roomId") == null ? "" : Reflect.field(body, "roomId"));
		if (roomId == null || StringTools.trim(roomId) == "") roomId = params(request).get("roomId");
		if (roomId == null || StringTools.trim(roomId) == "") return fail(400, "missing roomId");
		var closed = hub.closeRoom(StringTools.trim(roomId));
		if (!closed) return fail(404, "no such room");
		return ok({ roomId: roomId, closed: true });
	}

	// ------------------------------------------------------------------
	// helpers
	// ------------------------------------------------------------------

	public static function applyLive(hub:ServerHub):Void {
		var l = ServerConfig.limits;
		hub.applyLimits(l.ipLock, l.ipLockLimit, l.reconnectGuard, l.reconnectLimit);
		GameRoom.MAX_CLIENTS = l.maxClients;
		// [smtp] is applied live too: ServerMail.init() swaps the outbox path + smtp config.
		if (ServerConfig.smtpDefined) ServerMail.init(Api.storageDir(), ServerConfig.smtpConfig());
		if (ServerConfig.permissionRoles != null) {
			for (key in ServerConfig.ROLE_KEYS) {
				if (!ServerConfig.permissionRoles.exists(key)) continue;
				ServerConfig.setRoleAccess(key, ServerConfig.permissionRoles.get(key));
			}
			AccountStore.reapplyRoleAccess();
		}
	}

	static function limitsView():Dynamic {
		var l = ServerConfig.limits;
		return {
			ipLock: l.ipLock, ipLockLimit: l.ipLockLimit,
			reconnectGuard: l.reconnectGuard, reconnectLimit: l.reconnectLimit,
			maxClients: l.maxClients, announcement: l.announcement
		};
	}

	static function accountView(a:Account):Dynamic {
		return {
			id: a.id, name: a.name, email: a.email,
			role: AccountStore.normalizeRole(a.role),
			admin: a.access != null && a.access.indexOf("*") >= 0,
			banned: AccountStore.normalizeRole(a.role) == "Banned",
			points: a.points, avgAccuracy: a.avgAccuracy, games: a.games,
			createdAt: a.createdAt, lastActive: a.lastActive,
			access: a.access == null ? [] : a.access,
			ips: a.ips == null ? [] : a.ips,
			ng: a.ngId != null,
			club: ClubStore.tagOf(a.id)
		};
	}

	static function memory():Dynamic {
		#if neko
		try {
			var s = neko.vm.Gc.stats();
			var out:Dynamic = {};
			for (f in Reflect.fields(s)) Reflect.setField(out, f, Reflect.field(s, f));
			return out;
		} catch (e:Dynamic) return null;
		#else
		return null;
		#end
	}

	/** Server stdout log: `<server>/logs/p5_server.out.log` next to the data dir (start.ps1 layout). */
	static function logFile():String {
		var base = Path.directory(Api.storageDir());
		for (name in ["p5_server.out.log", "p5_server.err.log"]) {
			var p = base + "/logs/" + name;
			if (FileSystem.exists(p)) return p;
		}
		return base + "/logs/p5_server.out.log";
	}

	/**
	 * Tail of a text file without assuming an encoding.
	 *
	 * The log file is whatever the launcher redirected into it: `cmd > file` writes UTF-8, while
	 * Windows PowerShell's `>` writes **UTF-16LE with a BOM**. neko's File.getContent turns those
	 * bytes into a string that Json.stringify cannot encode back to UTF-8, which surfaces as
	 * `{"error":"internal error: std@utf8_buf_add"}` on GET /api/console/logs?source=server.
	 * So: read bytes, detect the encoding, always return valid text.
	 */
	static function readTail(path:String, lines:Int):{lines:Array<String>, encoding:String} {
		if (path == null || !FileSystem.exists(path)) return { lines: [], encoding: "missing" };
		var bytes:Bytes = null;
		var partial = false;
		try {
			var size = FileSystem.stat(path).size;
			var cap = 512 * 1024;
			// neko's FileInput.read throws Eof when asked for more bytes than the file has.
			var want = (size > cap) ? cap : size;
			var f = File.read(path, true);
			if (size > cap) {
				f.seek(size - cap, FileSeek.SeekBegin);
				partial = true;
			}
			bytes = f.read(want);
			f.close();
		} catch (e:Dynamic) {
			return { lines: ["<cannot read " + path + ": " + Std.string(e) + ">"], encoding: "unreadable" };
		}
		var dec = decodeText(bytes);
		var arr = dec.text.split("\n");
		for (i in 0...arr.length) {
			var line = arr[i];
			if (StringTools.endsWith(line, "\r")) arr[i] = line.substr(0, line.length - 1);
		}
		// A tail read starts mid-line; that first fragment is noise.
		if (partial && arr.length > 1) arr.shift();
		while (arr.length > 0 && StringTools.trim(arr[arr.length - 1]) == "") arr.pop();
		if (arr.length > lines) arr = arr.slice(arr.length - lines);
		return { lines: arr, encoding: dec.encoding };
	}

	static function decodeText(bytes:Bytes):{text:String, encoding:String} {
		var n = bytes.length;
		if (n >= 2 && bytes.get(0) == 0xFF && bytes.get(1) == 0xFE) return { text: decodeUtf16(bytes, 2, true), encoding: "utf-16le" };
		if (n >= 2 && bytes.get(0) == 0xFE && bytes.get(1) == 0xFF) return { text: decodeUtf16(bytes, 2, false), encoding: "utf-16be" };
		// BOM-less UTF-16: a NUL at (almost) every other byte in the head.
		var probe = (n < 64) ? n : 64;
		var nuls = 0;
		for (i in 0...probe) if (bytes.get(i) == 0) nuls++;
		if (probe >= 8 && nuls * 4 >= probe) {
			var lePairs = 0;
			var i = 0;
			while (i + 1 < probe) {
				if (bytes.get(i + 1) == 0) lePairs++;
				i += 2;
			}
			var le = lePairs * 2 >= (probe >> 1);
			return { text: decodeUtf16(bytes, 0, le), encoding: le ? "utf-16le" : "utf-16be" };
		}
		var start = (n >= 3 && bytes.get(0) == 0xEF && bytes.get(1) == 0xBB && bytes.get(2) == 0xBF) ? 3 : 0;
		return { text: decodeUtf8(bytes, start), encoding: start > 0 ? "utf-8-bom" : "utf-8" };
	}

	static function decodeUtf16(bytes:Bytes, offset:Int, le:Bool):String {
		var out = new BytesBuffer();
		var i = offset;
		while (i + 1 < bytes.length) {
			var a = bytes.get(i);
			var b = bytes.get(i + 1);
			var code = le ? (a | (b << 8)) : ((a << 8) | b);
			i += 2;
			if (code >= 0xD800 && code <= 0xDFFF) {
				var high = code;
				code = 0xFFFD;
				if (i + 1 < bytes.length) {
					var c = bytes.get(i);
					var d = bytes.get(i + 1);
					var low = le ? (c | (d << 8)) : ((c << 8) | d);
					if (low >= 0xDC00 && low <= 0xDFFF) {
						// surrogate pair
						code = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00);
						i += 2;
					}
				}
			}
			if (code == 0) continue;
			appendUtf8(out, code);
		}
		return out.getBytes().toString();
	}

	/** Validating UTF-8 decode: invalid bytes become U+FFFD so JSON can never choke on them. */
	static function decodeUtf8(bytes:Bytes, start:Int):String {
		var out = new BytesBuffer();
		var i = start;
		var n = bytes.length;
		while (i < n) {
			var b = bytes.get(i);
			if (b < 0x80) {
				if (b != 0) out.addByte(b);
				i++;
				continue;
			}
			var need = 0;
			var code = 0;
			if (b >= 0xC2 && b <= 0xDF) {
				need = 1;
				code = b & 0x1F;
			} else if (b >= 0xE0 && b <= 0xEF) {
				need = 2;
				code = b & 0x0F;
			} else if (b >= 0xF0 && b <= 0xF4) {
				need = 3;
				code = b & 0x07;
			}
			if (need == 0 || i + need >= n) {
				appendUtf8(out, 0xFFFD);
				i++;
				continue;
			}
			var ok = true;
			for (k in 1...(need + 1)) {
				var c = bytes.get(i + k);
				if (c < 0x80 || c > 0xBF) {
					ok = false;
					break;
				}
				code = (code << 6) | (c & 0x3F);
			}
			if (!ok || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) {
				appendUtf8(out, 0xFFFD);
				i++;
				continue;
			}
			// Valid sequence: copy the original bytes through.
			for (k in 0...(need + 1)) out.addByte(bytes.get(i + k));
			i += need + 1;
		}
		return out.getBytes().toString();
	}

	/** UTF-8 encode one code point into the buffer (neko strings are byte strings). */
	static function appendUtf8(out:BytesBuffer, cp:Int):Void {
		if (cp < 0x80) {
			out.addByte(cp);
		} else if (cp < 0x800) {
			out.addByte(0xC0 | (cp >> 6));
			out.addByte(0x80 | (cp & 0x3F));
		} else if (cp < 0x10000) {
			out.addByte(0xE0 | (cp >> 12));
			out.addByte(0x80 | ((cp >> 6) & 0x3F));
			out.addByte(0x80 | (cp & 0x3F));
		} else {
			out.addByte(0xF0 | (cp >> 18));
			out.addByte(0x80 | ((cp >> 12) & 0x3F));
			out.addByte(0x80 | ((cp >> 6) & 0x3F));
			out.addByte(0x80 | (cp & 0x3F));
		}
	}

	static function slice(rows:Array<Dynamic>, page:Int, size:Int):Array<Dynamic> {
		var start = page * size;
		if (start >= rows.length) return [];
		return rows.slice(start, start + size);
	}

	static function pageOf(p:Map<String, String>):Int {
		var v = Std.parseInt(p.get("page"));
		return (v == null || v < 0) ? 0 : v;
	}

	static function sizeOf(p:Map<String, String>, fallback:Int):Int {
		var v = Std.parseInt(p.get("size"));
		return clampInt(v == null ? fallback : v, 1, 200);
	}

	static function numField(o:Dynamic, name:String):Float {
		var v = Reflect.field(o, name);
		if (v == null) return 0;
		var f = Std.parseFloat(Std.string(v));
		return Math.isNaN(f) ? 0 : f;
	}

	static function params(request:HttpRequest):Map<String, String> {
		var out = new Map<String, String>();
		if (request.query == null || request.query == "") return out;
		for (pair in request.query.split("&")) {
			if (pair == "") continue;
			var eq = pair.indexOf("=");
			var k = (eq < 0) ? pair : pair.substring(0, eq);
			var v = (eq < 0) ? "" : pair.substring(eq + 1);
			out.set(StringTools.urlDecode(k), StringTools.urlDecode(v));
		}
		return out;
	}

	static inline function parseIntParam(p:Map<String, String>, name:String, fallback:Int):Int {
		var v = Std.parseInt(p.get(name));
		return v == null ? fallback : v;
	}

	static inline function clampInt(v:Int, lo:Int, hi:Int):Int return v < lo ? lo : (v > hi ? hi : v);

	static function parseBody(request:HttpRequest):Dynamic {
		if (request.body == null || StringTools.trim(request.body) == "") return null;
		try return Json.parse(request.body) catch (e:Dynamic) return null;
	}

	static function ok(data:Dynamic):HttpResponse return json(200, data);
	static function fail(status:Int, message:String):HttpResponse return json(status, { error: message });

	static function json(status:Int, data:Dynamic):HttpResponse {
		return { status: status, contentType: "application/json", body: Json.stringify(data) };
	}
}
