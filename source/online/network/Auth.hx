package online.network;

import haxe.io.Bytes;
import haxe.crypto.Base64;
import haxe.io.Path;
import haxe.Json;
import online.util.ServerList;
import sys.FileSystem;
import sys.io.File;

/**
 * Credentials, keyed by server-list entry.
 *
 *   <applicationStorageDirectory>/seiun_auth.json
 *   { "version":1, "accounts":{ "<serverId>":{ id, token, expiresAt, remember, autoLogin, ttlMinutes, accountName } } }
 *
 * Stored next to seiun_servers.json. Tokens stay plain text like before; what changes is that every
 * write lands on disk right away (the old code only wrote on saveClose(), which nothing ever called)
 * and that nothing writes to FlxG.save any more -- the legacy save-data fields are migrated once and
 * then wiped.
 */
typedef ServerAuth = {
	var id:String;
	var token:String;
	/** ms epoch; 0 = the server handed out no date, treated as "no expiry". */
	var expiresAt:Float;
	/** Keep the credential across restarts. */
	var remember:Bool;
	/** Refresh it automatically on the next launch. */
	var autoLogin:Bool;
	/** Minutes the player asked this server for; 0 = the server default. */
	var ttlMinutes:Int;
	/** Cached display name; never used for authentication. */
	var accountName:String;
}

@:unreflective
class Auth {
	public static inline var FILE_NAME:String = 'seiun_auth.json';
	public static inline var LEGACY_FILE_NAME:String = 'peo_auth.json';
	public static inline var VERSION:Int = 1;

	public static var authID:String = null;
	public static var authToken:String = null;

	static var savePath:String = null;
	static var accounts:Map<String, ServerAuth> = null;
	static var loaded:Bool = false;

	public static function getAuthHeader(?authID:String, ?authToken:String) {
		return "Basic " + Base64.encode(Bytes.ofString((authID != null ? authID : Auth.authID) + ":" + (authToken != null ? authToken : Auth.authToken)));
	}

	public static function load():Void {
		if (loaded) {
			bind();
			return;
		}
		loaded = true;

		savePath = lime.system.System.applicationStorageDirectory + FILE_NAME;
		accounts = new Map<String, ServerAuth>();

		readFile();
		migrateFromSaveData();
		migrateLegacyFiles();
		// "Remember me" off means the credential only lives for the session that created it.
		dropUnremembered();
		bind();
	}

	/** Starting up: a credential the player chose not to remember is thrown away here. */
	static function dropUnremembered():Void {
		var doomed:Array<String> = [];
		for (key => entry in accounts)
			if (!entry.remember)
				doomed.push(key);
		if (doomed.length == 0)
			return;

		for (key in doomed)
			accounts.remove(key);

		if (hasEntries())
			writeFile();
		else
			deleteFile();
	}

	/** Re-reads the selected server's credential into authID/authToken (after a server switch). */
	public static function onServerChanged():Void {
		load();
		bind();
	}

	// ------------------------------------------------------------------
	// Queries
	// ------------------------------------------------------------------

	public static function isLoggedIn():Bool {
		load();
		return authID != null && authToken != null;
	}

	public static function current():Null<ServerAuth> {
		load();
		return accounts.get(ServerList.selectedId());
	}

	public static function find(?serverId:Null<String>):Null<ServerAuth> {
		load();
		if (serverId == null)
			return null;
		return accounts.get(serverId);
	}

	/** True when the stored date has passed; an entry without a date never expires client-side. */
	public static function expired(?serverId:Null<String>):Bool {
		load();
		var entry = serverId != null ? accounts.get(serverId) : current();
		return entry != null && entry.expiresAt > 0 && nowMs() > entry.expiresAt;
	}

	/** Formatted expiry for the UI; empty string when the server gave no date. */
	public static function expiryLabel():String {
		var entry = current();
		if (entry == null || entry.expiresAt <= 0)
			return '';
		return Date.fromTime(entry.expiresAt).toString();
	}

	public static function remember():Bool {
		var entry = current();
		return entry != null && entry.remember;
	}

	public static function autoLogin():Bool {
		var entry = current();
		return entry != null && entry.autoLogin;
	}

	public static function ttlMinutes():Int {
		var entry = current();
		return entry != null ? entry.ttlMinutes : 0;
	}

	public static function accountName():String {
		var entry = current();
		return entry != null ? entry.accountName : '';
	}

	// ------------------------------------------------------------------
	// Mutations
	// ------------------------------------------------------------------

	/** Stores a login / register response for the selected server. */
	public static function saveLogin(json:Dynamic):Void {
		load();
		if (json == null || json.id == null || json.token == null)
			return;

		var key = ServerList.selectedId();
		var old = accounts.get(key);
		store(key, json.id, json.token,
			Reflect.hasField(json, 'expiresAt') ? num(json.expiresAt, 0) : 0,
			old != null ? old.remember : true,
			old != null ? old.autoLogin : true,
			old != null ? old.ttlMinutes : 0,
			Reflect.hasField(json, 'name') && json.name != null ? json.name : (old != null ? old.accountName : ''));
		writeFile();
		bind();
	}

	/** Refreshes the date of the selected server's credential after /api/auth/refresh. */
	public static function updateExpiry(expiresAt:Float):Void {
		load();
		var entry = current();
		if (entry == null)
			return;
		entry.expiresAt = expiresAt;
		writeFile();
	}

	/** Keeps the credential for the selected server, or drops it (logout). */
	public static function save(id:String, token:String):Void {
		load();
		if (id == null || token == null) {
			clear();
			return;
		}
		var key = ServerList.selectedId();
		var old = accounts.get(key);
		store(key, id, token,
			old != null ? old.expiresAt : 0,
			old != null ? old.remember : true,
			old != null ? old.autoLogin : true,
			old != null ? old.ttlMinutes : 0,
			old != null ? old.accountName : '');
		writeFile();
		bind();
	}

	public static function setRemember(value:Bool):Void {
		var entry = require();
		if (entry == null)
			return;
		entry.remember = value;
		writeFile();
	}

	public static function setAutoLogin(value:Bool):Void {
		var entry = require();
		if (entry == null)
			return;
		entry.autoLogin = value;
		writeFile();
	}

	/** 0 = ask the server for its default; the server can pin its own value. */
	public static function setTtlMinutes(minutes:Int):Void {
		var entry = require();
		if (entry == null)
			return;
		entry.ttlMinutes = minutes < 0 ? 0 : (minutes > 525600 ? 525600 : minutes);
		writeFile();
	}

	public static function setAccountName(name:String):Void {
		var entry = require();
		if (entry == null)
			return;
		entry.accountName = name == null ? '' : name;
		writeFile();
	}

	/** Drops one server's credential (default: the selected one). */
	public static function clear(?serverId:String):Void {
		load();
		var key = serverId != null ? serverId : ServerList.selectedId();
		accounts.remove(key);
		if (hasEntries())
			writeFile();
		else
			deleteFile();
		bind();
	}

	/** Path of the credential file; logged on startup and shown in the console UI docs. */
	public static function path():String {
		load();
		return savePath;
	}

	// ------------------------------------------------------------------
	// Internals
	// ------------------------------------------------------------------

	static function bind():Void {
		var entry = ServerList.selectedId() != null ? accounts.get(ServerList.selectedId()) : null;
		authID = entry != null ? entry.id : null;
		authToken = entry != null ? entry.token : null;
	}

	/**
	 * The selected server's record, created on demand so the remember / auto-login / lifetime
	 * switches keep a value even before the first login.
	 */
	static function require():Null<ServerAuth> {
		load();
		var entry = current();
		if (entry == null) {
			entry = {
				id: null,
				token: null,
				expiresAt: 0,
				remember: true,
				autoLogin: true,
				ttlMinutes: 0,
				accountName: ''
			};
			accounts.set(ServerList.selectedId(), entry);
			writeFile();
		}
		return entry;
	}

	static function store(serverId:String, id:String, token:String, expiresAt:Float, remember:Bool, autoLogin:Bool, ttlMinutes:Int, accountName:String):Void {
		accounts.set(serverId, {
			id: id,
			token: token,
			expiresAt: expiresAt,
			remember: remember,
			autoLogin: autoLogin,
			ttlMinutes: ttlMinutes,
			accountName: accountName == null ? '' : accountName
		});
	}

	static function hasEntries():Bool {
		for (_ in accounts.keys())
			return true;
		return false;
	}

	static function readFile():Void {
		if (!FileSystem.exists(savePath))
			return;

		var raw:Dynamic = null;
		try {
			raw = Json.parse(File.getContent(savePath));
		} catch (e:Dynamic) {
			trace('Could not read ' + FILE_NAME + ': ' + Std.string(e));
			return;
		}

		if (raw == null || !Reflect.hasField(raw, 'accounts') || raw.accounts == null)
			return;

		for (key in Reflect.fields(raw.accounts)) {
			var entry:Dynamic = Reflect.field(raw.accounts, key);
			if (entry == null)
				continue;
			// id/token may be null: that is a preference-only record (the player unticked a box
			// before ever logging in), which still has to survive a restart.
			store(key, entry.id, entry.token,
				Reflect.hasField(entry, 'expiresAt') ? num(entry.expiresAt, 0) : 0,
				Reflect.hasField(entry, 'remember') ? entry.remember == true : true,
				Reflect.hasField(entry, 'autoLogin') ? entry.autoLogin == true : true,
				Reflect.hasField(entry, 'ttlMinutes') ? Std.int(num(entry.ttlMinutes, 0)) : 0,
				entry.accountName != null ? entry.accountName : '');
		}
	}

	static function writeFile():Void {
		if (savePath == null)
			return;

		var accountsJson:Dynamic = {};
		for (key => entry in accounts) {
			var json:Dynamic = {};
			Reflect.setField(json, 'id', entry.id);
			Reflect.setField(json, 'token', entry.token);
			Reflect.setField(json, 'expiresAt', entry.expiresAt);
			Reflect.setField(json, 'remember', entry.remember);
			Reflect.setField(json, 'autoLogin', entry.autoLogin);
			Reflect.setField(json, 'ttlMinutes', entry.ttlMinutes);
			Reflect.setField(json, 'accountName', entry.accountName);
			Reflect.setField(accountsJson, key, json);
		}

		var root:Dynamic = {};
		Reflect.setField(root, 'version', VERSION);
		Reflect.setField(root, 'accounts', accountsJson);

		var dir = Path.directory(savePath);
		if (!FileSystem.exists(dir))
			FileSystem.createDirectory(dir);
		File.saveContent(savePath, Json.stringify(root));
	}

	static function deleteFile():Void {
		if (savePath != null && FileSystem.exists(savePath))
			FileSystem.deleteFile(savePath);
	}

	/**
	 * One-time: the historical save-data fields become a normal entry for whichever server the old
	 * network address pointed at, and the fields are wiped so nothing writes there again.
	 */
	static function migrateFromSaveData():Void {
		if (FlxG.save == null || FlxG.save.data == null)
			return;

		var legacyID:String = FlxG.save.data.networkAuthID;
		var legacyToken:String = FlxG.save.data.networkAuthToken;
		if (legacyID == null || legacyToken == null)
			return;

		var key = legacyServerId();
		if (!accounts.exists(key))
			store(key, legacyID, legacyToken, 0, true, true, 0, '');

		FlxG.save.data.networkAuthID = null;
		FlxG.save.data.networkAuthToken = null;
		FlxG.save.flush();
		writeFile();
		trace('Moved the old save-data credentials into ' + FILE_NAME + '.');
	}

	/**
	 * One-time: the single-server file (plus the even older ShadowMario/PsychEngine one) is folded
	 * into the new file and renamed to .bak -- kept around on purpose so a downgrade still works.
	 */
	static function migrateLegacyFiles():Void {
		for (legacyPath in legacyCredentialPaths()) {
			if (legacyPath == null || !FileSystem.exists(legacyPath))
				continue;

			try {
				var old:Dynamic = Json.parse(File.getContent(legacyPath));
				if (old != null && old.id != null && old.token != null) {
					var key = legacyServerId();
					if (!accounts.exists(key))
						store(key, old.id, old.token, 0, true, true, 0, '');
					writeFile();
				}
			} catch (e:Dynamic) {
				trace('Could not read legacy ' + LEGACY_FILE_NAME + ': ' + Std.string(e));
			}

			var backup = legacyPath + '.bak';
			if (FileSystem.exists(backup))
				FileSystem.deleteFile(backup);
			FileSystem.rename(legacyPath, backup);
			trace('Moved ' + legacyPath + ' to .bak');
		}
	}

	static function legacyCredentialPaths():Array<String> {
		var current = lime.system.System.applicationStorageDirectory + LEGACY_FILE_NAME;
		var paths = [current];
		try {
			var shadow = Path.normalize(current).replace(
				FlxG.stage.application.meta.get('company') + '/' + FlxG.stage.application.meta.get('file'),
				'ShadowMario/PsychEngine');
			if (shadow != current)
				paths.push(shadow);
		} catch (e:Dynamic) {}
		return paths;
	}

	/** Which entry the pre-list credentials belonged to: the old network address first. */
	static function legacyServerId():String {
		var network = ClientPrefs.data.networkServerAddress;
		if (network != null && network != '')
			for (entry in ServerList.all())
				if (entry.networkAddress == network || entry.address == network)
					return entry.id;

		var rooms = ClientPrefs.data.serverAddress;
		if (rooms != null && rooms != '')
			for (entry in ServerList.all())
				if (entry.address == rooms || entry.networkAddress == rooms)
					return entry.id;

		return ServerList.selectedId();
	}

	static function nowMs():Float {
		return Math.ffloor(Date.now().getTime());
	}

	static function num(value:Dynamic, fallback:Float):Float {
		if (value == null)
			return fallback;
		var parsed = Std.parseFloat(Std.string(value));
		return Math.isNaN(parsed) ? fallback : parsed;
	}
}
