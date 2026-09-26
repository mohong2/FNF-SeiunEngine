package online_server;

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
			if (srv.exists("announcement")) limits.announcement = Std.string(srv.get("announcement"));
			if (srv.exists("ip_lock")) limits.ipLock = boolOf(srv.get("ip_lock"), limits.ipLock);
			if (srv.exists("ip_lock_limit")) limits.ipLockLimit = intOf(srv.get("ip_lock_limit"), limits.ipLockLimit);
			if (srv.exists("reconnect_guard")) limits.reconnectGuard = boolOf(srv.get("reconnect_guard"), limits.reconnectGuard);
			if (srv.exists("reconnect_limit")) limits.reconnectLimit = intOf(srv.get("reconnect_limit"), limits.reconnectLimit);
			if (srv.exists("max_clients")) limits.maxClients = intOf(srv.get("max_clients"), limits.maxClients);
		}
		var mail = sections.get("smtp");
		if (mail != null) {
			smtpDefined = true;
			if (mail.exists("host")) smtp.host = Std.string(mail.get("host"));
			if (mail.exists("port")) smtp.port = intOf(mail.get("port"), smtp.port);
			if (mail.exists("user")) smtp.user = Std.string(mail.get("user"));
			if (mail.exists("pass")) smtp.pass = Std.string(mail.get("pass"));
			if (mail.exists("from")) smtp.from = Std.string(mail.get("from"));
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
				permissionRoles.set(key, arr);
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
		if (Reflect.hasField(body, "announcement")) next.announcement = sanitize(Std.string(Reflect.field(body, "announcement")), 500);
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
				out.push({ name: name, size: st.size, mtime: Std.string(st.mtime) });
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

	public static function smtpView():SmtpView return smtp;

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

	static function sanitize(s:String, max:Int):String {
		var v = s == null ? "" : s;
		v = StringTools.replace(v, "\r", "");
		if (v.length > max) v = v.substring(0, max);
		return v;
	}
}
