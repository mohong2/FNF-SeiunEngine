package online_server;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import online_server.Main.ServerHub;
import online_server.ServerMail.SmtpConfig;

/**
 * Console-managed runtime config: `<data-dir>/config.toml` (hand-rolled TOML subset, no library).
 *
 * Shape:
 *   [server]
 *   announcement = ""
 *   ip_lock = true
 *   ip_lock_limit = 4
 *   reconnect_guard = true
 *   reconnect_limit = 12
 *   max_clients = 6
 *   [permissions]
 *   member = [ "/api/sez", ... ]
 *
 * Precedence: CLI flags win at startup, console saves win afterwards.
 * No file -> code defaults, and permissions are left untouched (pre-config behaviour).
 */
typedef ServerLimits = {
	var announcement:String;
	var ipLock:Bool;
	var ipLockLimit:Int;
	var reconnectGuard:Bool;
	var reconnectLimit:Int;
	var maxClients:Int;
}

/**
 * [smtp] section. Only plain SMTP (no TLS socket in Haxe 4.2.5 std), so 465/587 cannot work;
 * see ServerMail's file header. Empty host/from = mail stays outbox-only (mail.log).
 */
typedef SmtpView = {
	var host:String;
	var port:Int;
	var user:String;
	var pass:String;
	var from:String;
	/** Implicit TLS (smtps). QQ/163 need 465 + this on; 587 STARTTLS is not supported. */
	var ssl:Bool;
}

class ServerConfig {
	/** Console role key -> Haxe role name used by AccountStore. */
	public static var ROLE_KEYS:Array<String> = ["member", "helper", "moderator", "admin", "banned"];

	public static var storagePath:String = null;
	/** True when the file existed on disk at load time. */
	public static var fileExists:Bool = false;
	/** Text of the currently effective config (the pre-write backup source). */
	static var lastToml:String = null;
	public static var limits:ServerLimits = null;
	/** Parsed [permissions] section; null = section absent (do not touch account access). */
	public static var permissionRoles:Map<String, Array<String>> = null;
	/** True when the [smtp] table was present in the file or set from the console. */
	public static var smtpDefined:Bool = false;
	public static var smtp:SmtpView = { host: "", port: 25, user: "", pass: "", from: "", ssl: false };
	/**
	 * [auth] table: credential TTL (minutes; 0 = never) and whether it is fixed.
	 * With ttl_locked = false (default) players may choose minutes in the client and the server
	 * only clamps the range; with true the player's request is ignored and ttl_minutes is used.
	 */
	public static var authTtlMinutes:Int = 43200;
	public static var authTtlLocked:Bool = false;
	/** Non-fatal parse notes shown in the console. */
	public static var warnings:Array<String> = [];

	/** Frozen code defaults (captured on the first load, before any console override). */
	static var codeLimits:ServerLimits = null;
	static var codeRoles:Map<String, Array<String>> = null;

	public static function roleNameOf(key:String):String {
		return switch (key) {
			case "member": "Member";
			case "helper": "Helper";
			case "moderator": "Moderator";
			case "admin": "Admin";
			case "banned": "Banned";
			case _: "Member";
		};
	}

	public static function defaultLimits():ServerLimits {
		return {
			announcement: "",
			ipLock: true,
			ipLockLimit: ServerHub.DEFAULT_IP_LOCK_LIMIT,
			reconnectGuard: true,
			reconnectLimit: GameRoom.RECONNECT_STORM_LIMIT,
			maxClients: GameRoom.MAX_CLIENTS
		};
	}

	/** Code-level defaults for a role key (used to fill / compare the [permissions] table). */
	public static function defaultAccessForRole(key:String):Array<String> {
		return AccountStore.accessForRole(roleNameOf(key));
	}

	public static function load(path:String):Void {
		storagePath = path;
		limits = defaultLimits();
		permissionRoles = null;
		smtpDefined = false;
		smtp = { host: "", port: 25, user: "", pass: "", from: "", ssl: false };
		authTtlMinutes = 43200;
		authTtlLocked = false;
		fileExists = false;
		warnings = [];
		if (codeLimits == null) codeLimits = defaultLimits();
		if (codeRoles == null) {
			codeRoles = new Map();
			for (key in ROLE_KEYS) codeRoles.set(key, AccountStore.accessForRole(roleNameOf(key)));
		}
		if (path == null || path == "") return;
		if (!FileSystem.exists(path)) {
			lastToml = toToml();
			return;
		}
		fileExists = true;
		var text = "";
		try text = File.getContent(path) catch (e:Dynamic) {
			warnings.push("cannot read " + path + ": " + Std.string(e));
			return;
		}
		var sections = parseToml(text);
		var srv = sections.get("server");
		if (srv != null) {
			// sanitizeAnnouncement() repairs an announcement whose UTF-8 was cut mid-codepoint by an
			// older build, so a config.toml already damaged on disk does not keep /api/console/status 500.
			if (srv.exists("announcement")) limits.announcement = sanitizeAnnouncement(Std.string(srv.get("announcement")));
			if (srv.exists("ip_lock")) limits.ipLock = boolOf(srv.get("ip_lock"), limits.ipLock);
			if (srv.exists("ip_lock_limit")) limits.ipLockLimit = intOf(srv.get("ip_lock_limit"), limits.ipLockLimit);
			if (srv.exists("reconnect_guard")) limits.reconnectGuard = boolOf(srv.get("reconnect_guard"), limits.reconnectGuard);
			if (srv.exists("reconnect_limit")) limits.reconnectLimit = intOf(srv.get("reconnect_limit"), limits.reconnectLimit);
			if (srv.exists("max_clients")) limits.maxClients = intOf(srv.get("max_clients"), limits.maxClients);
		}
		var mail = sections.get("smtp");
		if (mail != null) {
			smtpDefined = true;
			// repairUtf8: a hand-edited config.toml must not carry invalid bytes into a JSON response
			// (the console echoes the smtp view).
			if (mail.exists("host")) smtp.host = repairUtf8(Std.string(mail.get("host")));
			if (mail.exists("port")) smtp.port = intOf(mail.get("port"), smtp.port);
			if (mail.exists("user")) smtp.user = repairUtf8(Std.string(mail.get("user")));
			if (mail.exists("pass")) smtp.pass = repairUtf8(Std.string(mail.get("pass")));
			if (mail.exists("from")) smtp.from = repairUtf8(Std.string(mail.get("from")));
			if (mail.exists("ssl")) smtp.ssl = boolOf(mail.get("ssl"), smtp.ssl);
		}
		var auth = sections.get("auth");
		if (auth != null) {
			if (auth.exists("ttl_minutes")) authTtlMinutes = intOf(auth.get("ttl_minutes"), authTtlMinutes);
			if (auth.exists("ttl_locked")) authTtlLocked = boolOf(auth.get("ttl_locked"), authTtlLocked);
		}
		var perms = sections.get("permissions");
		if (perms != null) {
			permissionRoles = new Map();
			for (key in ROLE_KEYS) {
				if (!perms.exists(key)) continue;
				var arr = strArrayOf(perms.get(key));
				if (arr == null) {
					warnings.push("[permissions] " + key + " is not an array of strings; ignored");
					continue;
				}
				// Permission patterns are echoed by /api/console/config, so repair them on load too.
				var repaired:Array<String> = [];
				for (pattern in arr) repaired.push(repairUtf8(pattern));
				permissionRoles.set(key, repaired);
			}
			if (Lambda.count(permissionRoles) == 0) permissionRoles = null;
		}
		limits.maxClients = clamp(maxClients(), 1, 64);
		limits.ipLockLimit = clamp(maxSessionsPerIp(), 1, 1024);
		limits.reconnectLimit = clamp(reconnectLimit(), 1, 10000);
		authTtlMinutes = clamp(authTtlMinutes, 0, 525600);
		// Snapshot of what is currently effective -> becomes the pre-write backup.
		lastToml = text;
	}

	public static inline function maxClients():Int return limits.maxClients;
	public static inline function maxSessionsPerIp():Int return limits.ipLockLimit;
	public static inline function reconnectLimit():Int return limits.reconnectLimit;

	static inline function clamp(v:Int, lo:Int, hi:Int):Int return v < lo ? lo : (v > hi ? hi : v);

	/** Code-level defaults for the console's "revert" button. */
	public static function codeDefaults():ServerLimits {
		if (codeLimits == null) codeLimits = defaultLimits();
		return codeLimits;
	}

	public static function codeRolesView():Dynamic {
		if (codeRoles == null) {
			codeRoles = new Map();
			for (key in ROLE_KEYS) codeRoles.set(key, AccountStore.accessForRole(roleNameOf(key)));
		}
		var out:Dynamic = {};
		for (key in ROLE_KEYS) Reflect.setField(out, key, codeRoles.get(key));
		return out;
	}

	/** Apply one config role entry to AccountStore's runtime table. */
	public static function setRoleAccess(key:String, patterns:Array<String>):Void {
		AccountStore.setAccessForRole(roleNameOf(key), patterns);
	}

	/** Merge a JSON body (console save) into the in-memory limits; returns changed keys. */
	public static function setFromJson(body:Dynamic):Array<String> {
		var changed:Array<String> = [];
		if (body == null) return changed;
		var cur = limits;
		var next:ServerLimits = {
			announcement: cur.announcement,
			ipLock: cur.ipLock,
			ipLockLimit: cur.ipLockLimit,
			reconnectGuard: cur.reconnectGuard,
			reconnectLimit: cur.reconnectLimit,
			maxClients: cur.maxClients
		};
		if (Reflect.hasField(body, "announcement")) next.announcement = sanitizeAnnouncement(Std.string(Reflect.field(body, "announcement")));
		if (Reflect.hasField(body, "ipLock")) next.ipLock = boolOf(Reflect.field(body, "ipLock"), next.ipLock);
		if (Reflect.hasField(body, "ipLockLimit")) next.ipLockLimit = clamp(intOf(Reflect.field(body, "ipLockLimit"), next.ipLockLimit), 1, 1024);
		if (Reflect.hasField(body, "reconnectGuard")) next.reconnectGuard = boolOf(Reflect.field(body, "reconnectGuard"), next.reconnectGuard);
		if (Reflect.hasField(body, "reconnectLimit")) next.reconnectLimit = clamp(intOf(Reflect.field(body, "reconnectLimit"), next.reconnectLimit), 1, 10000);
		if (Reflect.hasField(body, "maxClients")) next.maxClients = clamp(intOf(Reflect.field(body, "maxClients"), next.maxClients), 1, 64);
		if (next.announcement != cur.announcement) changed.push("announcement");
		if (next.ipLock != cur.ipLock) changed.push("ipLock");
		if (next.ipLockLimit != cur.ipLockLimit) changed.push("ipLockLimit");
		if (next.reconnectGuard != cur.reconnectGuard) changed.push("reconnectGuard");
		if (next.reconnectLimit != cur.reconnectLimit) changed.push("reconnectLimit");
		if (next.maxClients != cur.maxClients) changed.push("maxClients");
		limits = next;

		var mail:Dynamic = null;
		try mail = Reflect.field(body, "smtp") catch (e:Dynamic) mail = null;
		if (mail != null) {
			var nextMail:SmtpView = {
				host: strField(mail, "host", smtp.host),
				port: clampIntField(mail, "port", smtp.port, 1, 65535),
				user: strField(mail, "user", smtp.user),
				pass: strField(mail, "pass", smtp.pass),
				from: strField(mail, "from", smtp.from),
				ssl: (Reflect.field(mail, "ssl") == null) ? smtp.ssl : boolOf(Reflect.field(mail, "ssl"), smtp.ssl)
			};
			smtpDefined = true;
			if (nextMail.host != smtp.host || nextMail.port != smtp.port || nextMail.user != smtp.user
				|| nextMail.pass != smtp.pass || nextMail.from != smtp.from || nextMail.ssl != smtp.ssl) changed.push("smtp");
			smtp = nextMail;
		}

		var perms:Dynamic = null;
		try perms = Reflect.field(body, "permissions") catch (e:Dynamic) perms = null;
		if (perms != null) {
			var map = new Map<String, Array<String>>();
			for (key in ROLE_KEYS) {
				var v:Dynamic = Reflect.field(perms, key);
				if (v == null) {
					if (permissionRoles != null && permissionRoles.exists(key)) map.set(key, permissionRoles.get(key));
					continue;
				}
				var arr = strArrayOf(v);
				if (arr == null) continue;
				map.set(key, arr);
			}
			permissionRoles = (Lambda.count(map) == 0) ? null : map;
			if (changed.indexOf("permissions") < 0) changed.push("permissions");
		}
		return changed;
	}

	/** Full effective table, including code defaults for roles the file does not list. */
	public static function effectiveRoles():Dynamic {
		var out:Dynamic = {};
		for (key in ROLE_KEYS) {
			var list = (permissionRoles != null && permissionRoles.exists(key))
				? permissionRoles.get(key) : defaultAccessForRole(key);
			Reflect.setField(out, key, list);
		}
		return out;
	}

	public static function toToml():String {
		var b = new StringBuf();
		b.add("# SeiunEngine server config -- managed by /console. CLI flags win at startup.\n");
		b.add("[server]\n");
		b.add('announcement = ' + quote(limits.announcement) + '\n');
		b.add('ip_lock = ' + (limits.ipLock ? "true" : "false") + '\n');
		b.add('ip_lock_limit = ' + limits.ipLockLimit + '\n');
		b.add('reconnect_guard = ' + (limits.reconnectGuard ? "true" : "false") + '\n');
		b.add('reconnect_limit = ' + limits.reconnectLimit + '\n');
		b.add('max_clients = ' + limits.maxClients + '\n');
		if (smtpDefined) {
			b.add('\n# Plain SMTP only (no TLS socket in Haxe 4.2.5 std): 465/587 will not work.\n');
			b.add('[smtp]\n');
			b.add('host = ' + quote(smtp.host) + '\n');
			b.add('port = ' + smtp.port + '\n');
			b.add('user = ' + quote(smtp.user) + '\n');
			b.add('pass = ' + quote(smtp.pass) + '\n');
			b.add('from = ' + quote(smtp.from) + '\n');
			b.add('ssl = ' + (smtp.ssl ? "true" : "false") + '\n');
		}
		b.add('\n# Credential lifetime (minutes). 0 = never expires.\n');
		b.add('# ttl_locked = true ignores the minutes a client asks for.\n');
		b.add('[auth]\n');
		b.add('ttl_minutes = ' + authTtlMinutes + '\n');
		b.add('ttl_locked = ' + (authTtlLocked ? "true" : "false") + '\n');
		b.add('\n[permissions]\n');
		for (key in ROLE_KEYS) {
			var list = (permissionRoles != null && permissionRoles.exists(key))
				? permissionRoles.get(key) : defaultAccessForRole(key);
			b.add(key + ' = [ ' + [for (p in list) quote(p)].join(", ") + ' ]\n');
		}
		return b.toString();
	}

	/** Atomic save: copy the old file into <data-dir>/backups, then tmp + rename. */
	public static function save():{ok:Bool, error:String, backup:String} {
		if (storagePath == null || storagePath == "") return { ok: false, error: "no config path", backup: null };
		var text = toToml();
		var backup:String = null;
		try {
			// Always keep a rollback point: the previous effective config (file or defaults).
			var previous = (lastToml != null) ? lastToml : text;
			backup = writeBackup(previous);
			var tmp = storagePath + ".tmp";
			File.saveContent(tmp, text);
			if (FileSystem.exists(storagePath)) FileSystem.deleteFile(storagePath);
			FileSystem.rename(tmp, storagePath);
			fileExists = true;
			lastToml = text;
		} catch (e:Dynamic) {
			return { ok: false, error: Std.string(e), backup: backup };
		}
		return { ok: true, error: null, backup: backup };
	}

	static function writeBackup(text:String):String {
		var dir = Path.directory(storagePath) + "/backups";
		if (!FileSystem.exists(dir)) FileSystem.createDirectory(dir);
		var stamp = Std.string(Math.ffloor(haxe.Timer.stamp() * 1000));
		var target = dir + "/config-" + stamp + ".toml";
		File.saveContent(target, text == null ? "" : text);
		return target;
	}

	public static function listBackups():Array<Dynamic> {
		var out:Array<Dynamic> = [];
		if (storagePath == null) return out;
		var dir = Path.directory(storagePath) + "/backups";
		if (!FileSystem.exists(dir)) return out;
		try {
			for (name in FileSystem.readDirectory(dir)) {
				if (!StringTools.endsWith(name, ".toml")) continue;
				var full = dir + "/" + name;
				var st = FileSystem.stat(full);
				out.push({ name: repairUtf8(name), size: st.size, mtime: Std.string(st.mtime) });
			}
		} catch (e:Dynamic) {}
		out.sort(function(a, b) return Reflect.field(a, "name") < Reflect.field(b, "name") ? 1 : -1);
		return out;
	}

	/** SmtpConfig for ServerMail: only when host + from are set (otherwise outbox-only). */
	public static function smtpConfig():SmtpConfig {
		var host = smtp == null ? "" : smtp.host;
		var from = smtp == null ? "" : smtp.from;
		if (host == null || host == "" || from == null || from == "") return null;
		// 465 is implicit TLS on every provider we care about; treat it as SSL even if a stale
		// config.toml (written before the switch existed) has no ssl key.
		var useSsl = smtp.ssl || smtp.port == 465;
		return { host: host, port: smtp.port, user: smtp.user, pass: smtp.pass, from: from, ssl: useSsl };
	}

	/** Repaired view for the console: invalid bytes in a hand-edited [smtp] table must not reach JSON. */
	public static function smtpView():SmtpView {
		return {
			host: repairUtf8(smtp.host), port: smtp.port, user: repairUtf8(smtp.user),
			pass: repairUtf8(smtp.pass), from: repairUtf8(smtp.from), ssl: smtp.ssl
		};
	}

	static function strField(o:Dynamic, name:String, fallback:String):String {
		var v = Reflect.field(o, name);
		if (v == null) return fallback;
		return Std.string(v);
	}

	static function clampIntField(o:Dynamic, name:String, fallback:Int, lo:Int, hi:Int):Int {
		var v = Reflect.field(o, name);
		if (v == null) return fallback;
		var n = Std.parseInt(Std.string(v));
		if (n == null) return fallback;
		return n < lo ? lo : (n > hi ? hi : n);
	}

	// ---- TOML subset ----

	static function parseToml(text:String):Map<String, Map<String, Dynamic>> {
		var sections = new Map<String, Map<String, Dynamic>>();
		var cur = "";
		sections.set("", new Map());
		var lines = text.split("\n");
		var i = 0;
		while (i < lines.length) {
			var line = StringTools.trim(stripComment(lines[i]));
			i++;
			if (line == "") continue;
			if (StringTools.startsWith(line, "[") && StringTools.endsWith(line, "]")) {
				cur = StringTools.trim(line.substring(1, line.length - 1));
				if (!sections.exists(cur)) sections.set(cur, new Map());
				continue;
			}
			var eq = line.indexOf("=");
			if (eq <= 0) continue;
			var key = StringTools.trim(line.substring(0, eq));
			var rest = StringTools.trim(line.substring(eq + 1));
			// Multi-line array support: keep reading until the brackets balance.
			while (rest.indexOf("[") >= 0 && countChar(rest, "[") > countChar(rest, "]") && i < lines.length) {
				rest += " " + StringTools.trim(stripComment(lines[i]));
				i++;
			}
			sections.get(cur).set(key, parseValue(rest));
		}
		return sections;
	}

	static function countChar(s:String, c:String):Int {
		var n = 0;
		for (i in 0...s.length) if (s.charAt(i) == c) n++;
		return n;
	}

	static function stripComment(line:String):String {
		var inStr = false;
		for (i in 0...line.length) {
			var c = line.charAt(i);
			if (c == '"') inStr = !inStr;
			else if (c == "#" && !inStr) return line.substring(0, i);
		}
		return line;
	}

	static function parseValue(raw:String):Dynamic {
		var v = StringTools.trim(raw);
		if (v == "") return "";
		if (v.charAt(0) == '"') return unquote(v);
		if (v.charAt(0) == "[") {
			var inner = v.substring(1, v.length - 1);
			var out:Array<String> = [];
			var inStr = false;
			var buf = new StringBuf();
			for (i in 0...inner.length) {
				var c = inner.charAt(i);
				if (c == '"') {
					inStr = !inStr;
					buf.add(c);
					continue;
				}
				if (c == "," && !inStr) {
					var item = StringTools.trim(buf.toString());
					if (item != "") out.push(unquote(item));
					buf = new StringBuf();
					continue;
				}
				buf.add(c);
			}
			var last = StringTools.trim(buf.toString());
			if (last != "") out.push(unquote(last));
			return out;
		}
		if (v == "true") return true;
		if (v == "false") return false;
		var n = Std.parseInt(v);
		return n == null ? v : n;
	}

	static function unquote(raw:String):String {
		var v = StringTools.trim(raw);
		if (v.length >= 2 && v.charAt(0) == '"' && v.charAt(v.length - 1) == '"')
			v = v.substring(1, v.length - 1);
		return v.split('\\n').join("\n").split('\\"').join('"').split("\\\\").join("\\");
	}

	static function quote(s:String):String {
		var v = s == null ? "" : s;
		v = v.split("\\").join("\\\\").split('"').join('\\"').split("\n").join('\\n');
		return '"' + v + '"';
	}

	static function strArrayOf(v:Dynamic):Array<String> {
		if (v == null) return null;
		if (Std.isOfType(v, String)) return [v];
		if (!Std.isOfType(v, Array)) return null;
		var out:Array<String> = [];
		for (item in (cast v : Array<Dynamic>)) {
			if (item == null) continue;
			if (!Std.isOfType(item, String)) return null;
			out.push(Std.string(item));
		}
		return out;
	}

	static function boolOf(v:Dynamic, fallback:Bool):Bool {
		if (v == null) return fallback;
		if (Std.isOfType(v, Bool)) return cast v;
		var s = Std.string(v).toLowerCase();
		if (s == "true") return true;
		if (s == "false") return false;
		return fallback;
	}

	static function intOf(v:Dynamic, fallback:Int):Int {
		if (v == null) return fallback;
		if (Std.isOfType(v, Int)) return cast v;
		var n = Std.parseInt(Std.string(v));
		return n == null ? fallback : n;
	}

	/** Announcement cap: the console form and the config field are used as a 500-CHARACTER field. */
	public static inline var ANNOUNCEMENT_MAX_CHARS:Int = 500;
	/**
	 * Hard byte ceiling for the announcement. 500 codepoints are at most 2000 UTF-8 bytes, so this
	 * never rejects a legal value; it only bounds how much a pathological payload can write into
	 * config.toml (and lets capUtf8 stop scanning early).
	 */
	public static inline var ANNOUNCEMENT_MAX_BYTES:Int = 2048;

	/**
	 * Generic byte cap: strip the CR characters a TOML basic string cannot hold, then keep at most
	 * max UTF-8 BYTES without splitting a codepoint (see truncateUtf8). Byte-based on purpose: only
	 * caps documented in characters should use sanitizeAnnouncement / capUtf8 with maxChars.
	 */
	public static function sanitize(s:String, max:Int):String {
		var v = s == null ? "" : s;
		v = StringTools.replace(v, "\r", "");
		return truncateUtf8(v, max);
	}

	/**
	 * Announcement text: strip CR, then cap at ANNOUNCEMENT_MAX_CHARS characters (codepoints) and
	 * ANNOUNCEMENT_MAX_BYTES bytes. Counting bytes here made the "500" field a ~166-character wall
	 * for Chinese text; the character cap is what the console UI implies.
	 */
	public static function sanitizeAnnouncement(s:String):String {
		var v = s == null ? "" : s;
		v = StringTools.replace(v, "\r", "");
		return capUtf8(v, ANNOUNCEMENT_MAX_CHARS, ANNOUNCEMENT_MAX_BYTES);
	}

	/**
	 * Keep at most maxChars codepoints and maxBytes UTF-8 bytes. The text is normalized first:
	 * invalid byte sequences are dropped and a CESU-8 surrogate pair is folded to its real
	 * codepoint. Never splits a codepoint, never emits an invalid sequence.
	 */
	public static function capUtf8(s:String, maxChars:Int, maxBytes:Int):String {
		return normalizeUtf8(s, maxChars, maxBytes);
	}
	
	/**
	 * Repair a string into well-formed UTF-8 with no length cap: drop NUL and every invalid
	 * sequence, fold CESU-8 surrogate pairs. Used by readers that echo stored or file text.
	 */
	public static function repairUtf8(s:String):String {
		return normalizeUtf8(s, -1, -1);
	}
	
	/**
	 * Normalize to well-formed UTF-8, copying codepoint by codepoint:
	 *   * a CESU-8 surrogate pair is folded into its real 4-byte codepoint,
	 *   * NUL is dropped (a TOML/JSON string cannot carry a raw NUL),
	 *   * every other invalid sequence is dropped, never guessed,
	 *   * stops when maxChars or maxBytes would be exceeded (negative = uncapped).
	 * The result is always valid UTF-8 (see validUtf8Bytes). Strictness rules: C0/C1 overlong leads,
	 * overlong E0/F0 forms, UTF-8-encoded surrogates (ED A0..BF), code points above U+10FFFF
	 * (F4 90..), orphan/truncated continuation bytes and NUL are all rejected.
	 */
	public static function normalizeUtf8(s:String, maxChars:Int, maxBytes:Int):String {
		if (s == null) return "";
		var b = Bytes.ofString(s);
		var out = new BytesBuffer();
		var i = 0;
		var chars = 0;
		var charLimit = maxChars < 0 ? 0x7FFFFFFF : maxChars;
		var byteLimit = maxBytes < 0 ? 0x7FFFFFFF : maxBytes;
		while (i < b.length && chars < charLimit) {
			var cp = -1;
			var len = 0;
			var pair = cesu8Pair(b, i);
			if (pair >= 0) {
				cp = pair;
				len = 6;
			} else {
				var dec = decodeUtf8Strict(b, i);
				if (dec == null) { i++; continue; }
				cp = dec.code;
				len = dec.len;
			}
			var need = utf8EncodedLength(cp);
			if (out.length + need > byteLimit) break;
			appendCodepoint(out, cp);
			i += len;
			chars++;
		}
		return out.getBytes().toString();
	}
	
	/**
	 * Strict UTF-8 decode of one sequence at b[i]; null when those bytes are not a well-formed
	 * scalar value. Rejects overlong forms, surrogates, > U+10FFFF, orphans/truncations and NUL.
	 */
	static function decodeUtf8Strict(b:Bytes, i:Int):Null<{code:Int, len:Int}> {
		var lead = b.get(i);
		if (lead == 0x00) return null;
		if (lead < 0x80) return { code: lead, len: 1 };
		var need = 0;
		var code = 0;
		var lo = 0x80;
		var hi = 0xBF;
		if (lead >= 0xC2 && lead <= 0xDF) { need = 1; code = lead & 0x1F; }
		else if (lead == 0xE0) { need = 2; lo = 0xA0; } // A0..BF: E0 80..9F would be overlong
		else if (lead >= 0xE1 && lead <= 0xEC) { need = 2; code = lead & 0x0F; }
		else if (lead == 0xED) { need = 2; code = 0x0D; hi = 0x9F; }
		else if (lead >= 0xEE && lead <= 0xEF) { need = 2; code = lead & 0x0F; }
		else if (lead == 0xF0) { need = 3; lo = 0x90; }
		else if (lead >= 0xF1 && lead <= 0xF3) { need = 3; code = lead & 0x07; }
		else if (lead == 0xF4) { need = 3; code = 0x04; hi = 0x8F; }
		else return null;
		if (i + need >= b.length) return null;
		var c1 = b.get(i + 1);
		if (c1 < lo || c1 > hi) return null;
		code = (code << 6) | (c1 & 0x3F);
		for (k in 2...(need + 1)) {
			var c = b.get(i + k);
			if ((c & 0xC0) != 0x80) return null;
			code = (code << 6) | (c & 0x3F);
		}
		return { code: code, len: need + 1 };
	}
	
	/**
	 * CESU-8 surrogate pair at b[i]: ED A0..AF xx followed by ED B0..BF xx. Returns the folded
	 * codepoint (>= U+10000) or -1. Python's json.dumps(ensure_ascii=True) and Java emit this
	 * encoding for astral characters.
	 */
	static function cesu8Pair(b:Bytes, i:Int):Int {
		if (i + 5 >= b.length) return -1;
		if (b.get(i) != 0xED) return -1;
		var h = b.get(i + 1);
		if (h < 0xA0 || h > 0xAF) return -1;
		if ((b.get(i + 2) & 0xC0) != 0x80) return -1;
		if (b.get(i + 3) != 0xED) return -1;
		var l = b.get(i + 4);
		if (l < 0xB0 || l > 0xBF) return -1;
		if ((b.get(i + 5) & 0xC0) != 0x80) return -1;
		var high = 0xD800 | ((h & 0x3F) << 6) | (b.get(i + 2) & 0x3F);
		var low = 0xDC00 | ((l & 0x3F) << 6) | (b.get(i + 5) & 0x3F);
		return 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00);
	}
	
	static inline function utf8EncodedLength(cp:Int):Int {
		if (cp < 0x80) return 1;
		if (cp < 0x800) return 2;
		if (cp < 0x10000) return 3;
		return 4;
	}
	
	/** UTF-8 encode one code point (all values produced by decodeUtf8Strict/cesu8Pair are valid). */
	public static function appendCodepoint(out:BytesBuffer, cp:Int):Void {
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
	
	/**
	 * Decode a byte range to well-formed UTF-8, replacing every invalid sequence with U+FFFD and
	 * folding CESU-8 pairs. This is the console log reader's decoder AND the same strict decoder the
	 * config/announce path uses (decodeUtf8Strict), so the two paths can never disagree.
	 */
	public static function decodeUtf8Replacing(b:Bytes, start:Int):String {
		var out = new BytesBuffer();
		var i = start < 0 ? 0 : start;
		while (i < b.length) {
			var pair = cesu8Pair(b, i);
			if (pair >= 0) {
				appendCodepoint(out, pair);
				i += 6;
				continue;
			}
			var d = decodeUtf8Strict(b, i);
			if (d == null) {
				appendCodepoint(out, 0xFFFD);
				i++;
				continue;
			}
			appendCodepoint(out, d.code);
			i += d.len;
		}
		return out.getBytes().toString();
	}

	/**
	 * Strict validity check of a byte string. A CESU-8 surrogate pair counts as invalid (it still
	 * needs folding), so callers that must store the original only when it is already well-formed
	 * use this.
	 */
	public static function validUtf8Bytes(b:Bytes):Bool {
		var i = 0;
		while (i < b.length) {
			var d = decodeUtf8Strict(b, i);
			if (d == null) return false;
			i += d.len;
		}
		return true;
	}
	
	/**
	 * The stored [server].announcement as a valid UTF-8 string. Defensive: every reader goes through
	 * sanitizeAnnouncement() so a value that reached memory before the codepoint-safe cap (or a
	 * hand-edited config.toml) can never make the JSON printer throw and brick the console page.
	 */
	public static function announcement():String {
		return limits == null ? "" : sanitizeAnnouncement(limits.announcement);
	}
	
	/** UTF-8 byte length. String.length is a byte count on neko/hxcpp, but say it out loud. */
	public static function utf8ByteLength(s:String):Int {
		return s == null ? 0 : Bytes.ofString(s).length;
	}
	
	/**
	 * Number of UTF-8 codepoints, counted with the strict decoder: a CESU-8 pair counts as one
	 * codepoint (the one normalizeUtf8 will store) and invalid bytes are not counted.
	 */
	public static function utf8Length(s:String):Int {
		if (s == null) return 0;
		var b = Bytes.ofString(s);
		var i = 0;
		var n = 0;
		while (i < b.length) {
			var pair = cesu8Pair(b, i);
			if (pair >= 0) { n++; i += 6; continue; }
			var d = decodeUtf8Strict(b, i);
			if (d == null) { i++; continue; }
			n++;
			i += d.len;
		}
		return n;
	}
	
	/**
	 * Keep at most maxBytes UTF-8 bytes and normalize away invalid sequences. Also repairs a
	 * config.toml damaged by an older build, which is why the load path uses it.
	 */
	public static function truncateUtf8(s:String, maxBytes:Int):String {
		if (s == null) return "";
		var b = Bytes.ofString(s);
		if (b.length <= maxBytes && validUtf8Bytes(b)) return s;
		return normalizeUtf8(s, -1, maxBytes);
	}

	// ------------------------------------------------------------------
	// JSON output (safe on every target)
	// ------------------------------------------------------------------
	
	/**
	 * JSON-encode a response or an embedded DB value with two guarantees:
	 *   * every string is repaired to well-formed UTF-8, so a legacy row with CESU-8 / overlong /
	 *     NUL bytes can never make a response body invalid, and
	 *   * non-BMP codepoints survive the cpp target. hxcpp's haxe.Json.stringify writes U+FFFD U+FFFD
	 *     for an astral character (proven by temp/announce/JsonCpp.hx), so each one is carried through
	 *     a NUL-delimited token and substituted with its \uXXXX escape after stringification. NUL is
	 *     dropped by repairUtf8, so a token can never collide with user text.
	 */
	public static function jsonEncode(data:Dynamic):String {
		var astral = new Map<Int, Bool>();
		var prepared = prepareJson(data, astral);
		var text = haxe.Json.stringify(prepared);
		if (text == null) text = "null";
		for (cp in astral.keys()) {
			var token = "\u0000" + StringTools.hex(cp, 6) + "\u0000";
			var serialized = haxe.Json.stringify(token);
			if (serialized == null || serialized.length < 2) continue;
			// replace the escaped token body inside the surrounding quotes of the user's string literal
			var inner = serialized.substr(1, serialized.length - 2);
			text = text.split(inner).join(surrogateEscape(cp));
		}
		return text;
	}
	
	/**
	 * Rebuild a JSON value with every string repaired and every astral codepoint tokenized.
	 * Anonymous structures and arrays are rebuilt (same fields, same order); anything else is passed
	 * through untouched, so exotic values keep haxe.Json's existing behaviour.
	 */
	static function prepareJson(v:Dynamic, astral:Map<Int, Bool>):Dynamic {
		if (v == null) return null;
		if (Std.isOfType(v, String)) return prepareJsonString(cast(v, String), astral);
		if (Std.isOfType(v, Array)) {
			var out:Array<Dynamic> = [];
			for (item in (cast v : Array<Dynamic>)) out.push(prepareJson(item, astral));
			return out;
		}
		if (Std.isOfType(v, haxe.ds.StringMap)) {
			var out:Dynamic = {};
			var m:haxe.ds.StringMap<Dynamic> = cast v;
			for (k in m.keys()) Reflect.setField(out, repairUtf8(k), prepareJson(m.get(k), astral));
			return out;
		}
		if (Std.isOfType(v, haxe.ds.IntMap)) {
			var out:Dynamic = {};
			var m:haxe.ds.IntMap<Dynamic> = cast v;
			for (k in m.keys()) Reflect.setField(out, Std.string(k), prepareJson(m.get(k), astral));
			return out;
		}
		switch (Type.typeof(v)) {
			case TObject:
				var out:Dynamic = {};
				for (f in Reflect.fields(v)) {
					var fv:Dynamic = null;
					try fv = Reflect.field(v, f) catch (e:Dynamic) fv = null;
					Reflect.setField(out, f, prepareJson(fv, astral));
				}
				return out;
			default:
				return v;
		}
	}
	
	/** One string: repair invalid bytes, fold CESU-8 pairs, tokenize non-BMP codepoints. */
	static function prepareJsonString(s:String, astral:Map<Int, Bool>):String {
		if (s == null) return "";
		var b = Bytes.ofString(s);
		var out = new BytesBuffer();
		var i = 0;
		while (i < b.length) {
			var pair = cesu8Pair(b, i);
			var code = -1;
			var len = 0;
			if (pair >= 0) {
				code = pair;
				len = 6;
			} else {
				var d = decodeUtf8Strict(b, i);
				if (d == null) { i++; continue; }
				code = d.code;
				len = d.len;
			}
			if (code >= 0x10000) {
				astral.set(code, true);
				out.add(Bytes.ofString("\u0000" + StringTools.hex(code, 6) + "\u0000"));
			} else {
				for (k in 0...len) out.addByte(b.get(i + k));
			}
			i += len;
		}
		return out.getBytes().toString();
	}
	
	/** repairUtf8 over a string list (null in = null out). */
	public static function repairUtf8List(list:Array<String>):Array<String> {
		if (list == null) return null;
		var out:Array<String> = [];
		for (s in list) out.push(repairUtf8(s));
		return out;
	}

	/** The two-escape form haxe.Json itself would emit for a non-BMP codepoint. */
	static function surrogateEscape(cp:Int):String {
		var v = cp - 0x10000;
		var hi = 0xD800 | (v >> 10);
		var lo = 0xDC00 | (v & 0x3FF);
		return "\\u" + StringTools.hex(hi, 4) + "\\u" + StringTools.hex(lo, 4);
	}
	}
