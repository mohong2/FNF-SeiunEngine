package online.util;

import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * The player's server list.
 *
 * One JSON file next to the credential file:
 *   <applicationStorageDirectory>/seiun_servers.json
 *   (%APPDATA%\mo_hong\SeiunEngine\seiun_servers.json on Windows)
 *
 * This is storage only -- no UI, no protocol change. GameClient reads the selected entry
 * through its serverAddress / networkServerAddress getters and mirrors it into ClientPrefs so
 * the old single-address path keeps working. Credentials are owned by Auth.
 */
typedef ServerEntry = {
	var id:String;
	var name:String;
	var note:String;
	/** Game-room address, e.g. ws://127.0.0.1:2567. */
	var address:String;
	/** Social / HTTP address; empty means "same host as address". */
	var networkAddress:String;
	/** Last successful contact (ms epoch, 0 = never) and the ping seen then (-1 = unknown). */
	var lastOkAt:Float;
	var lastPingMs:Int;
}

typedef ServerListData = {
	var version:Int;
	var selected:Null<String>;
	var servers:Array<ServerEntry>;
}

class ServerList {
	public static inline var FILE_NAME:String = 'seiun_servers.json';
	public static inline var VERSION:Int = 1;

	public static var data(default, null):ServerListData = null;
	static var savePath:String = null;
	static var seq:Int = 0;

	/** Kept here so the list can be created before GameClient is ever asked for an address. */
	public static inline var DEFAULT_ADDRESS:String = 'ws://localhost:2567';

	/** Plaintext (ws://) default port; see normalizeAddress(). Must match DEFAULT_ADDRESS. */
	public static inline var DEFAULT_PORT:Int = 2567;

	public static function load():Void {
		if (data != null)
			return;

		savePath = lime.system.System.applicationStorageDirectory + FILE_NAME;

		if (FileSystem.exists(savePath)) {
			try {
				data = Json.parse(File.getContent(savePath));
			} catch (e:Dynamic) {
				trace('Could not read ' + FILE_NAME + ': ' + Std.string(e));
				data = null;
			}
		}

		if (data == null || data.servers == null) {
			data = { version: VERSION, selected: null, servers: [] };
			createFirstEntry();
			return;
		}

		// Normalise every entry: a hand-edited or older file can miss fields.
		var fixed:Array<ServerEntry> = [];
		for (entry in data.servers) {
			if (entry == null || entry.address == null || entry.address == "")
				continue;
			fixed.push({
				id: entry.id != null && entry.id != "" ? entry.id : nextId(),
				name: entry.name == null ? "" : entry.name,
				note: entry.note == null ? "" : entry.note,
				address: entry.address,
				networkAddress: entry.networkAddress == null ? "" : entry.networkAddress,
				lastOkAt: Reflect.hasField(entry, 'lastOkAt') ? entry.lastOkAt : 0,
				lastPingMs: Reflect.hasField(entry, 'lastPingMs') ? entry.lastPingMs : -1
			});
		}
		data.servers = fixed;

		if (data.servers.length == 0)
			createFirstEntry();

		if (find(data.selected) == null)
			data.selected = data.servers[0].id;

		save();
	}

	// ------------------------------------------------------------------
	// Queries
	// ------------------------------------------------------------------

	public static function all():Array<ServerEntry> {
		load();
		return data.servers;
	}

	public static function find(?id:Null<String>):Null<ServerEntry> {
		load();
		if (id == null)
			return null;
		for (entry in data.servers)
			if (entry.id == id)
				return entry;
		return null;
	}

	public static function selectedId():String {
		load();
		return data.selected;
	}

	public static function selected():ServerEntry {
		load();
		var entry = find(data.selected);
		return entry != null ? entry : data.servers[0];
	}

	/** Address to use for game rooms (never empty). */
	public static function selectedAddress():String {
		var entry = selected();
		return entry != null && entry.address != "" ? entry.address : DEFAULT_ADDRESS;
	}

	/** Address to use for the social / HTTP backend; falls back to the game-room address. */
	public static function selectedNetworkAddress():String {
		var entry = selected();
		if (entry == null)
			return DEFAULT_ADDRESS;
		return entry.networkAddress != "" ? entry.networkAddress : entry.address;
	}

	// ------------------------------------------------------------------
	// Mutations
	// ------------------------------------------------------------------

	public static function select(id:String):Bool {
		load();
		if (find(id) == null)
			return false;
		data.selected = id;
		save();
		return true;
	}

	public static function create(name:String, address:String, ?note:String = ""):ServerEntry {
		load();
		var entry:ServerEntry = {
			id: nextId(),
			name: name == null ? "" : name,
			note: note == null ? "" : note,
			address: address == null || address == "" ? DEFAULT_ADDRESS : address,
			networkAddress: "",
			lastOkAt: 0,
			lastPingMs: -1
		};
		data.servers.push(entry);
		if (data.selected == null)
			data.selected = entry.id;
		save();
		return entry;
	}

	public static function rename(id:String, name:String, note:String):Bool {
		var entry = find(id);
		if (entry == null)
			return false;
		entry.name = name == null ? "" : name;
		entry.note = note == null ? "" : note;
		save();
		return true;
	}

	public static function setAddresses(id:String, address:String, networkAddress:String):Bool {
		var entry = find(id);
		if (entry == null || address == null || address == "")
			return false;
		entry.address = address;
		entry.networkAddress = networkAddress == null ? "" : networkAddress;
		save();
		return true;
	}

	/** Updates the currently selected entry (this is what the address inputs do). */
	public static function setSelectedAddress(address:String, ?networkAddress:Null<String> = null):Bool {
		var entry = selected();
		if (entry == null)
			return false;
		var net = networkAddress != null ? networkAddress : entry.networkAddress;
		return setAddresses(entry.id, address, net);
	}

	public static function remove(id:String):Bool {
		load();
		var entry = find(id);
		if (entry == null)
			return false;
		data.servers.remove(entry);
		if (data.servers.length == 0)
			create('', DEFAULT_ADDRESS);
		if (data.selected == id)
			data.selected = data.servers[0].id;
		save();
		return true;
	}

	/** Moves an entry by delta slots (-1 = up, +1 = down); keeps the selection. */
	public static function move(id:String, delta:Int):Bool {
		load();
		var from = -1;
		for (i in 0...data.servers.length)
			if (data.servers[i].id == id)
				from = i;
		if (from < 0)
			return false;
		var to = from + delta;
		if (to < 0 || to >= data.servers.length)
			return false;
		var entry = data.servers[from];
		data.servers.splice(from, 1);
		data.servers.insert(to, entry);
		save();
		return true;
	}

	/** Records the outcome of a contact attempt (drives the latency column later). */
	public static function markResult(id:String, pingMs:Int, ok:Bool):Void {
		var entry = find(id);
		if (entry == null)
			return;
		if (ok) {
			entry.lastOkAt = nowMs();
			entry.lastPingMs = pingMs;
		}
		save();
	}

	// ------------------------------------------------------------------
	// Persistence helpers
	// ------------------------------------------------------------------

	public static function save():Void {
		if (data == null || savePath == null)
			return;
		var dir = Path.directory(savePath);
		if (!FileSystem.exists(dir))
			FileSystem.createDirectory(dir);
		data.version = VERSION;
		File.saveContent(savePath, Json.stringify(data));
	}

	/** Path of the list file; useful for logs and for the next step's credential mapping. */
	public static function path():String {
		load();
		return savePath;
	}

	static function nextId():String {
		var n = seq + 1;
		while (find('srv' + Std.string(n)) != null)
			n++;
		seq = n;
		return 'srv' + Std.string(n);
	}

	static function nowMs():Float {
		return Math.ffloor(Date.now().getTime());
	}

	/**
	 * Accept what players actually type (http://host, bare host, a bare LAN IP, the historical
	 * double-prefixed values) and return a ws(s):// URL, like the old
	 * OnlineOptionsState.prepareAddress().
	 *
	 * Port rule: an address that ends up on plaintext ws:// and carries no explicit port gets
	 * DEFAULT_PORT appended exactly once. That is what makes a bare LAN IP such as 192.168.1.50
	 * work -- without it the player's entry became ws://192.168.1.50 and the socket went to port
	 * 80 instead of the server's 2567. Addresses that keep their TLS default port (wss:// / https://,
	 * including the two hosted aliases below) are never given a port: they sit behind an HTTPS
	 * reverse proxy on 443.
	 */
	public static function normalizeAddress(address:String):String {
		if (address == null)
			return DEFAULT_ADDRESS;

		address = address.trim();

		if (address.startsWith('ws://http://'))
			address = 'ws://' + address.substr('ws://http://'.length);
		else if (address.startsWith('wss://https://'))
			address = 'wss://' + address.substr('wss://https://'.length);
		else if (address.startsWith('ws://https://'))
			address = 'wss://' + address.substr('ws://https://'.length);
		else if (address.startsWith('wss://http://'))
			address = 'ws://' + address.substr('wss://http://'.length);

		if (address == "2567" || address == "0" || address == "local")
			address = "localhost";

		if (address.startsWith('https://'))
			address = 'wss://' + address.substr('https://'.length);
		else if (address.startsWith('http://'))
			address = 'ws://' + address.substr('http://'.length);

		if (address.length > 0 && !(address.startsWith('wss://') || address.startsWith('ws://')))
			address = 'ws://' + address;

		// Hosted SeiunEngine servers. Mapped to TLS *before* the port rule below so they keep 443;
		// these two lines are the only hosts where the scheme changes on their own.
		if (address == "ws://funkin.sniro.boo")
			address = "wss://funkin.sniro.boo";

		if (address == "ws://gettinfreaky.onrender.com")
			address = "wss://gettinfreaky.onrender.com";

		// Exactly once, and only after the URL is otherwise final: on the finished ws:// URL the
		// helper can tell "no port yet" from "already has one".
		address = withDefaultPort(address);

		return address == "" ? DEFAULT_ADDRESS : address;
	}

	/**
	 * Adds the plaintext default port to a ws:// URL that has none. The authority ends at the first
	 * '/' after the scheme, so a path stays a path: ws://host/room becomes ws://host:2567/room
	 * instead of ws://host/room:2567. A URL that already names a port -- or the degenerate "ws://"
	 * with no host at all -- is returned unchanged. Non-ws URLs (wss:// and everything else) are
	 * never touched.
	 */
	static function withDefaultPort(wsUrl:String):String {
		if (!wsUrl.startsWith('ws://'))
			return wsUrl;

		var rest = wsUrl.substr('ws://'.length);
		var path = rest.indexOf('/');
		var authority = path < 0 ? rest : rest.substr(0, path);
		if (authority == '' || authorityHasPort(authority))
			return wsUrl;

		return 'ws://' + authority + ':' + DEFAULT_PORT + (path < 0 ? '' : rest.substr(path));
	}

	/**
	 * True when an authority already names a port. Inside a bracketed IPv6 literal the colons belong
	 * to the address, so only what follows the closing ']' counts as a port there.
	 */
	static function authorityHasPort(authority:String):Bool {
		if (StringTools.startsWith(authority, '[')) {
			var close = authority.indexOf(']');
			return close >= 0 && authority.indexOf(':', close) >= 0;
		}

		return authority.indexOf(':') >= 0;
	}

	static function legacyAddress():String {
		var old = ClientPrefs.data.serverAddress;
		return old != null && old != "" ? old : DEFAULT_ADDRESS;
	}

	static function legacyName():String {
		return '';
	}

	/**
	 * First run: seed one entry from the legacy single-address fields so an existing player keeps
	 * talking to the same two endpoints (rooms and social are separate fields).
	 */
	static function createFirstEntry():ServerEntry {
		var entry = create(legacyName(), legacyAddress());
		var legacyNet = ClientPrefs.data.networkServerAddress;
		if (legacyNet != null && legacyNet != "") {
			entry.networkAddress = legacyNet;
			save();
		}
		return entry;
	}

	// ------------------------------------------------------------------
	// LAN helpers
	// ------------------------------------------------------------------

	/** ws:// URL of a LAN host, with the engine's default port (what the UI's "this PC" row uses). */
	public static function lanAddress(ip:String):String {
		return 'ws://' + ip + ':' + DEFAULT_PORT;
	}

	/**
	 * Best-effort list of this machine's private (RFC 1918) IPv4 addresses, in the order the
	 * platform's interface lister prints them and without duplicates. The server-list UI turns each
	 * one into a one-click "this PC" entry, so the LAN host does not have to read ipconfig and type
	 * an IP by hand.
	 *
	 * Desktop only. On mobile the platform owns the interfaces and the player types the host's
	 * address, so the empty array here is the documented fallback (the UI then shows the hint).
	 * Nothing is guaranteed: a missing tool, an unusual locale or a virtual-only adapter all end in
	 * an empty result, which is a normal outcome rather than an error.
	 */
	public static function localLanAddresses():Array<String> {
		// Neko is included because it is a desktop-class sys target (the server tooling runs on it)
		// and that makes this path observable from a probe; mobile targets stay excluded.
		#if (desktop || neko)
		var system:Null<String> = Sys.systemName();
		for (command in lanCommands(system)) {
			var output = runInterfaceCommand(command);
			if (output == null)
				continue;
			var addresses = parseLanAddresses(system, output);
			if (addresses.length > 0)
				return addresses;
		}
		return [];
		#else
		return [];
		#end
	}

	#if (desktop || neko)
	/** argv of the platform commands that list interfaces; the first one is preferred. */
	static function lanCommands(system:Null<String>):Array<Array<String>> {
		return switch (system) {
			case 'Windows': [['ipconfig']];
			// The ip tool is the modern Linux lister; ifconfig is the fallback on older installs.
			case 'Linux': [['ip', '-4', 'addr', 'show'], ['ifconfig']];
			case 'Mac': [['ifconfig']];
			default: [];
		};
	}

	/** Runs one lister and returns its stdout, or null when the command is missing / cannot run. */
	static function runInterfaceCommand(command:Array<String>):Null<String> {
		if (command == null || command.length == 0)
			return null;
		try {
			var process = new sys.io.Process(command[0], command.slice(1));
			var output = process.stdout.readAll().toString();
			process.exitCode();
			process.close();
			return output;
		} catch (e:Dynamic) {
			// A missing lister throws here; the caller just tries the next command.
			return null;
		}
	}
	#end

	/**
	 * Pull the private IPv4 addresses out of one interface listing. Pure (no process, no state) so
	 * the probe can feed it ipconfig / ip / ifconfig text from all three platforms.
	 *
	 * Windows ipconfig marks its lines with the literal token "IPv4" (localised builds keep it) and
	 * puts the address after the last ':'; the ip and ifconfig tools write "inet <addr>[/prefix]".
	 */
	public static function parseLanAddresses(systemName:Null<String>, output:String):Array<String> {
		var found:Array<String> = [];
		if (output == null)
			return found;

		for (line in output.split('\n')) {
			var candidate:String = null;
			if (systemName == 'Windows') {
				if (line.indexOf('IPv4') < 0)
					continue;
				var colon = line.lastIndexOf(':');
				if (colon < 0)
					continue;
				candidate = line.substr(colon + 1);
			} else {
				// "inet 192.168.1.5/24 ..." and "inet 192.168.1.5 netmask ..."; "inet6" has no
				// space after "inet" and is skipped by the search below.
				var marker = line.indexOf('inet ');
				if (marker < 0)
					continue;
				candidate = line.substr(marker + 'inet '.length);
			}

			var token = StringTools.trim(candidate);
			var space = token.indexOf(' ');
			if (space >= 0)
				token = token.substr(0, space);
			var slash = token.indexOf('/');
			if (slash >= 0)
				token = token.substr(0, slash);

			if (isPrivateIPv4(token) && found.indexOf(token) < 0)
				found.push(token);
		}

		return found;
	}

	/** True for a plain RFC 1918 IPv4 literal: 10/8, 172.16/12 and 192.168/16. */
	static function isPrivateIPv4(token:String):Bool {
		if (token == null || token == '')
			return false;

		var parts = token.split('.');
		if (parts.length != 4)
			return false;
		for (part in parts) {
			var value = Std.parseInt(part);
			// Reject "", "+1", "01" and anything outside a byte, so only dotted decimals pass.
			if (value == null || value < 0 || value > 255 || Std.string(value) != part)
				return false;
		}

		var a = Std.parseInt(parts[0]);
		var b = Std.parseInt(parts[1]);
		if (a == 10)
			return true;
		if (a == 172 && b >= 16 && b <= 31)
			return true;
		return a == 192 && b == 168;
	}
}
