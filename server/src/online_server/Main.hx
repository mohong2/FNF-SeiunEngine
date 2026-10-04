package online_server;

import haxe.Timer;
import haxe.io.Bytes;
import online_server.ServerMail.SmtpConfig;
import haxe.net.WebSocket;
import haxe.net.WebSocket.CloseEvent;
import haxe.net.WebSocketServer;
import io.colyseus.Protocol;
import io.colyseus.serializer.schema.Schema.It;
import io.colyseus.serializer.schema.Schema.SPEC;
import io.colyseus.serializer.schema.encoding.Decode;
import org.msgpack.MsgPack;
import online_server.Crypto;
import online_server.Log;
// Types declared in ServerBoot.hx (module path online_server.ServerBoot.<Type>).
import online_server.ServerBoot.ServerCliOptions;
import online_server.ServerBoot.ServerOptions;
import online_server.db.Db;
import online_server.db.LegacyImport;
import online_server.GameRoom.ClientConn;
import online_server.GameRoom.SessionRecord;
import online_server.HttpServer.HttpRequest;
import online_server.HttpServer.HttpResponse;
import sys.thread.Mutex;

/**
 * Server for the online protocol. Port split: HTTP 2567 for matchmaking and REST, WS 2568 for
 * room connections, advertised via publicAddress in the matchmaking response. Threading: one
 * thread per HTTP connection (the rooms map and reservations are guarded by a mutex); room
 * state and WebSockets live only on the main loop thread.
 */
class Main {
	static var host = "127.0.0.1";
	static var httpPort = 2567;
	static var wsPort = 2568;
	/** --public-host override (NAT / multiple network interfaces). */
	static var publicHost:String = null;
	/** --disable-ip-lock. */
	static var disableIpLock:Bool = false;
	/** --ip-lock-limit (0 = use the server default of 4). */
	static var ipLockLimit:Int = 0;
	/** --disable-reconnect-guard (turns off the reconnect-storm guard). */
	static var disableReconnectGuard:Bool = false;
	/** --reconnect-limit (0 = use the server default of 12). */
	static var reconnectLimit:Int = 0;
	/** Local JSON storage directory (accounts / leaderboard / comments). */
	static var dataDir:String = "server/data";
	/** Accounts named by --admin-email automatically get ["*"] access. */
	static var adminEmail:String = null;
	// Optional external-integration switches; when absent the service degrades but still works.
	/** --smtp-host: only sends codes when set; otherwise only <data-dir>/mail.log is written. */
	static var smtpHost:String = null;
	/** --smtp-port (default 25; only plaintext SMTP is implemented, see ServerMail). */
	static var smtpPort:Int = 25;
	static var smtpUser:String = null;
	static var smtpPass:String = null;
	/** --smtp-mail: sender address; requires --smtp-host to take effect. */
	static var smtpMail:String = null;
	/** --auth-ttl-minutes (absent = config.toml [auth], then 43200 = 30 days). */
	static var cliAuthTtl:Int = -1;
	/** --ng-app-id: Newgrounds gateway app id; absent means /api/account/link/newgrounds returns 400. */
	static var ngAppId:String = null;
	/** --discord-webhook: outbound mirror for network-room chat; absent means no-op. */
	static var discordWebhook:String = null;
	/** --log-dir: structured JSON Lines log directory (default server/logs). */
	static var logDir:String = "server/logs";
	/** --log-level: debug | info | warn | error (default info). */
	static var logLevel:String = "info";
	/** --import-legacy-json: re-run the JSON -> SQLite import even when the database already has data. */
	static var importLegacyJson:Bool = false;
	/**
	 * --console-local-readonly: answer GET /api/console/* from 127.0.0.1 without a credential
	 * (read-only, user ruling D-R3-5). The embedded LAN host always sets this via ServerOptions;
	 * the flag exists so the standalone neko server can be tested the same way. Default false.
	 */
	static var localConsoleReadOnly:Bool = false;

	public static function main() {
		var args = Sys.args();
		var i = 0;
		while (i < args.length) {
			switch (args[i]) {
				case "--http-port":
					httpPort = Std.parseInt(args[i + 1]);
					i += 2;
				case "--ws-port":
					wsPort = Std.parseInt(args[i + 1]);
					i += 2;
				case "--host":
					host = args[i + 1];
					i += 2;
				case "--fixture-dir":
					GameRoom.fixtureDir = args[i + 1];
					i += 2;
				case "--public-host":
					publicHost = args[i + 1];
					i += 2;
				case "--disable-ip-lock":
					disableIpLock = true;
					i++;
				case "--ip-lock-limit":
					var limit = Std.parseInt(args[i + 1]);
					ipLockLimit = (limit == null) ? 0 : limit;
					i += 2;
				case "--disable-reconnect-guard":
					disableReconnectGuard = true;
					i++;
				case "--reconnect-limit":
					var rlimit = Std.parseInt(args[i + 1]);
					reconnectLimit = (rlimit == null) ? 0 : rlimit;
					i += 2;
				case "--data-dir":
					dataDir = args[i + 1];
					i += 2;
				case "--admin-email":
					adminEmail = args[i + 1];
					i += 2;
				case "--smtp-host":
					smtpHost = args[i + 1];
					i += 2;
				case "--smtp-port":
					var sport = Std.parseInt(args[i + 1]);
					smtpPort = (sport == null) ? 25 : sport;
					i += 2;
				case "--smtp-user":
					smtpUser = args[i + 1];
					i += 2;
				case "--smtp-pass":
					smtpPass = args[i + 1];
					i += 2;
				case "--smtp-mail":
					smtpMail = args[i + 1];
					i += 2;
				case "--auth-ttl-minutes":
					var authTtl = Std.parseInt(args[i + 1]);
					cliAuthTtl = (authTtl == null) ? -1 : authTtl;
					i += 2;
				case "--ng-app-id":
					ngAppId = args[i + 1];
					i += 2;
				case "--discord-webhook":
					discordWebhook = args[i + 1];
					i += 2;
				case "--log-dir":
					logDir = args[i + 1];
					i += 2;
				case "--log-level":
					logLevel = args[i + 1];
					i += 2;
				case "--import-legacy-json":
					importLegacyJson = true;
					i++;
				case "--console-local-readonly":
					localConsoleReadOnly = true;
					i++;
				default:
					i++;
			}
		}

		// Thin CLI shim: the argv loop above filled these statics, and everything it produces is passed
		// to ServerBoot. The startup itself (logging, config.toml, SQLite storage, HTTP + WS listeners,
		// room hub) lives in ServerBoot so the game client can start the same server in-process.
		var opts:ServerOptions = {
			host: host,
			httpPort: httpPort,
			wsPort: wsPort,
			dataDir: dataDir,
			logDir: logDir,
			logLevel: logLevel,
			adminEmail: adminEmail,
			publicHost: publicHost,
			localConsoleReadOnly: localConsoleReadOnly
		};
		// Flags that are CLI-only (SMTP credentials, fixtures, legacy import, test switches); embedded
		// hosts never pass these, so a plain start(opts) always keeps the safe defaults.
		var cli:ServerCliOptions = {
			disableIpLock: disableIpLock,
			ipLockLimit: ipLockLimit,
			disableReconnectGuard: disableReconnectGuard,
			reconnectLimit: reconnectLimit,
			smtpHost: smtpHost,
			smtpPort: smtpPort,
			smtpUser: smtpUser,
			smtpPass: smtpPass,
			smtpMail: smtpMail,
			authTtlMinutes: cliAuthTtl,
			ngAppId: ngAppId,
			discordWebhook: discordWebhook,
			importLegacyJson: importLegacyJson,
			fixtureDir: GameRoom.fixtureDir
		};
		var boot = ServerBoot.start(opts, cli);
		boot.runLoop();
	}
}

class ServerHub {
	/**
	  * This engine's own application-layer handshake magic and version.
	  * The wire format is vendored Colyseus (matchmaking paths / WS frame codes / msgpack + schema);
	  * on top of it the client must send engine + protocol, and the server enforces both in
	  * handleMatchmake and attach.
	 */
	public static inline var PROTOCOL_MAGIC:String = "seiunengine-online";
	public static inline var NETWORK_MAGIC:String = "seiunengine-network";
	public static inline var PROTOCOL_VERSION:Int = 1;
	public static inline var NETWORK_VERSION:Int = 1;
	/** Legacy alias: the console and /api/config still read this name. */
	public static inline var CLIENT_PROTOCOL:Int = 1;
	/** Application version reported by /api/health (not the wire protocol version). */
	public static inline var SERVER_VERSION:String = "1.0.0";
	/** Default max sessions per IP. */
	public static inline var DEFAULT_IP_LOCK_LIMIT:Int = 4;
	/** Alphabet used for generated room ids. */
	static inline var ROOM_ID_LETTERS:String = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";

	public var rooms:Map<String, GameRoom> = new Map();
	public var processId:String = "local-process";

	var host:String;
	var wsPort:Int;
	var publicHost:String;
	var disableIpLock:Bool;
	var maxSessionsPerIp:Int;
	/** Reconnect-storm guard switch and window cap (--disable-reconnect-guard / --reconnect-limit). */
	var reconnectGuard:Bool;
	var reconnectLimit:Int;
	var mutex:Mutex = new Mutex();
	var wsServer:WebSocketServer;
	/**
	 * False once stop() runs: run() leaves its loop and the WS listen socket is closed, which is
	 * what frees the port (accept() returns null immediately afterwards). Plain Bool, like the
	 * rest of the server: the flag only ever goes true -> false, and run() re-reads it per tick.
	 */
	public var running:Bool = true;

	var pending:Array<WebSocket> = [];
	var pendingSince:Array<Float> = [];

	/** Console: process counters (HTTP requests / errors, WS connections, start time). */
	public var httpRequests:Int = 0;
	public var httpErrors:Int = 0;
	public var wsAccepted:Int = 0;
	public var startedAt:Float = haxe.Timer.stamp();

	var sessionSeq:Int = 0;

	/** Timestamp of the last stale-room sweep. */
	var lastSweep:Float = 0;

	/** A room with no connections for this many seconds is stale (rejected by joinById, removed by sweepRooms). */
	static inline var STALE_ROOM_SECONDS:Float = 30.0;

	public function new(host:String, wsPort:Int, ?publicHost:String = null, ?disableIpLock:Bool = false, ?ipLockLimit:Int = 0, ?disableReconnectGuard:Bool = false, ?reconnectLimit:Int = 0) {
		this.host = host;
		this.wsPort = wsPort;
		this.publicHost = publicHost;
		this.disableIpLock = disableIpLock;
		this.maxSessionsPerIp = (ipLockLimit != null && ipLockLimit > 0) ? ipLockLimit : DEFAULT_IP_LOCK_LIMIT;
		this.reconnectGuard = !disableReconnectGuard;
		this.reconnectLimit = (reconnectLimit != null && reconnectLimit > 0) ? reconnectLimit : GameRoom.RECONNECT_STORM_LIMIT;
		this.wsServer = WebSocketServer.create(host, wsPort, 64, false, false);

		// The network room (fixed roomId '0') is pre-registered as a resident room: the client calls
		// `joinById('0')` directly (NetworkClient.hx:39) without create. It is never swept and never
		// listed.
		var net = new GameRoom(GameRoom.NETWORK_ROOM_ID, processId);
		net.isNetwork = true;
		this.rooms.set(GameRoom.NETWORK_ROOM_ID, net);
	}

	// ------------------------------------------------------------------
	// HTTP
	// ------------------------------------------------------------------

	/** Console: request and error counters (status >= 400), used by the console overview. */
	public function handleHttp(request:HttpRequest):HttpResponse {
		httpRequests++;
		var response = routeHttp(request);
		if (response.status >= 400) httpErrors++;
		return response;
	}

	function routeHttp(request:HttpRequest):HttpResponse {
		var path = request.path;

		// Console: the built-in web console (zero-dependency static page; JSON endpoints under /api/console/*).
		if (path == "/console" || StringTools.startsWith(path, "/console/")) {
			return ConsoleWeb.serve(path);
		}

		if (StringTools.startsWith(path, "/matchmake/")) {
			return handleMatchmake(request);
		}
		if (path == "/rooms/room") {
			return jsonResponse(200, roomList());
		}
		if (path == "/api/onlinecount") {
			return { status: 200, contentType: "text/plain", body: Std.string(onlineCount()) };
		}
		// Read-only health probe (status / uptime / rooms / version / dbSchemaVersion / dbPath).
		// Added endpoint: it does not change the shape of any existing response.
		if (path == "/api/health") {
			return jsonResponse(200, health());
		}
		// Read-only server config, used by tests to verify defaults (maxClients=6 / IP lock 4 / reconnect window 20s).
		if (path == "/api/config") {
			return jsonResponse(200, {
				// Application-layer handshake magic; the client reads these two fields before connecting.
				engine: PROTOCOL_MAGIC,
				networkEngine: NETWORK_MAGIC,
				protocol: CLIENT_PROTOCOL,
				maxClients: GameRoom.MAX_CLIENTS,
				ipLock: !disableIpLock,
				maxSessionsPerIp: maxSessionsPerIp,
				reconnectWindow: GameRoom.RECONNECT_WINDOW,
				pingInterval: GameRoom.PING_INTERVAL,
				// Reconnect-storm guard (defence in depth); caps the attach count per sliding window.
				reconnectGuard: reconnectGuard,
				reconnectLimit: reconnectLimit,
				reconnectStormWindow: GameRoom.RECONNECT_STORM_WINDOW,
				// Fixed id of the network room (tests join it with joinById).
				networkRoomId: GameRoom.NETWORK_ROOM_ID,
				networkProtocol: NetworkLogic.PROTOCOL_VERSION,
				// Credential policy (the client shows "server-fixed" and decides whether to send custom minutes).
				auth: {
					ttlMinutes: Api.authTtl(),
					ttlLocked: Api.authTtlIsLocked()
				},
				// Image upload and external-integration switches (unconfigured integrations degrade cleanly).
				integrations: {
					imageUpload: true,
					mail: ServerMail.smtpConfigured(),
					mailOutbox: ServerMail.outbox(),
					newgrounds: Ngio.available(),
					discord: DiscordBridge.available()
				}
			});
		}

		// HTTP APIs backed by local JSON for accounts / leaderboard / comments (null = not matched).
		var api = Api.handle(request, this);
		if (api != null) return api;

		return jsonResponse(404, { error: "not found: " + path });
	}

	/**
	 * Application-layer handshake check. Options carrying neither engine nor protocol (the protocol
	 * test client only sends name) pass through; everything else must carry our magic and own version,
	 * with game rooms and network rooms having their own magic.
	 */
	public static function handshakeOk(options:Dynamic):Bool {
		if (options == null) return true;
		var engine:Dynamic = Reflect.field(options, "engine");
		var proto:Dynamic = Reflect.field(options, "protocol");
		if (engine == null && proto == null) return true;
		if (engine == null || proto == null) return false;
		var e = Std.string(engine);
		var p = Std.parseInt(Std.string(proto));
		if (p == null) return false;
		return (e == PROTOCOL_MAGIC && p == PROTOCOL_VERSION) || (e == NETWORK_MAGIC && p == NETWORK_VERSION);
	}

	function handleMatchmake(request:HttpRequest):HttpResponse {
		var rest = request.path.substr("/matchmake/".length);
		var parts = rest.split("/");
		var method = parts[0];
		var argument = parts.length > 1 ? parts[1] : "";

		var options:Dynamic = {};
		if (request.body != null && request.body != "") {
			try {
				options = haxe.Json.parse(request.body);
			} catch (e:Dynamic) {
				options = {};
			}
		}

		// Unknown clients / servers are stopped here by the handshake magic (error code 5007).
		if (!handshakeOk(options)) {
			trace('[matchmake] reject (5007): not a SeiunEngine handshake');
			return jsonResponse(400, { error: "Not a SeiunEngine server/client handshake", code: 5007 });
		}

		// Reconnect reuses the old session by token (no new sessionId / token) and returns the same
		// seat reservation.
		if (method == "reconnect") {
			return handleReconnect(argument, options, request);
		}

		// At most maxSessionsPerIp sessions per IP.
		if (!ipAllowed(request)) {
			trace('[ip-lock] rejecting ${ipOf(request)} (limit $maxSessionsPerIp)');
			return jsonResponse(400, {
				// Only single-quoted Haxe strings interpolate `$`, so this must be concatenated.
				error: "Can't join/create " + maxSessionsPerIp + " servers on the same IP!",
				code: 5002
			});
		}

		if (method == "create" || method == "joinOrCreate") {
			var room = createRoom();
			var session = addSession(room, options, request);
			trace('[matchmake] $method -> room ${room.roomId} session ${session.sessionId}');
			return jsonResponse(200, seatReservation(room, session, request));
		}

		if (method == "joinById") {
			var room = getRoom(argument);
			// After the host leaves, the room is not cleaned up and an old room code can still
			// seat a client in an empty room. The criterion is now "no connections and no
			// sessions waiting to reconnect" (see isStaleRoom).
			if (room != null && isStaleRoom(room)) {
				trace('[sweep] joinById hit stale room $argument, removing');
				mutex.acquire();
				rooms.remove(argument);
				mutex.release();
				room = null;
			}
			if (room == null) {
				trace('[matchmake] joinById -> room not found: $argument');
				return jsonResponse(404, { error: "room not found: " + argument });
			}
			var session = addSession(room, options, request);
			trace('[matchmake] joinById -> room ${room.roomId} session ${session.sessionId}');
			return jsonResponse(200, seatReservation(room, session, request));
		}

		return jsonResponse(404, { error: "unknown matchmake method: " + method });
	}

	function createRoom():GameRoom {
		mutex.acquire();
		var id = generateRoomId();
		var room = new GameRoom(id, processId);
		rooms.set(id, room);
		mutex.release();
		return room;
	}

	/**
	 * Generates a 4-uppercase-letter room id, deduplicated against the rooms map.
	 * The caller must already hold the mutex (guaranteed by createRoom).
	 */
	function generateRoomId():String {
		var id:String = "";
		var tries = 0;
		do {
			var sb = new StringBuf();
			for (_ in 0...4) {
				sb.add(ROOM_ID_LETTERS.charAt(Std.random(ROOM_ID_LETTERS.length)));
			}
			id = sb.toString();
			tries++;
		} while (rooms.exists(id) && tries < 512);
		return id;
	}

	function getRoom(roomId:String):GameRoom {
		mutex.acquire();
		var room = rooms.get(roomId);
		mutex.release();
		return room;
	}

	function addSession(room:GameRoom, options:Dynamic, request:HttpRequest):SessionRecord {
		mutex.acquire();
		sessionSeq++;
		var suffix = Std.string(Std.random(100000));
		var record = room.addSession(
			"sess" + sessionSeq + "-" + suffix,
			"tok" + sessionSeq + "-" + suffix,
			options,
			ipOf(request)
		);
		mutex.release();
		return record;
	}

	/**
	 * POST /matchmake/reconnect/<roomId>, body {"reconnectionToken": "..."}.
	 *
	 * The client's Client.reconnect() (Client.hx:98-101) splits room.reconnectionToken (= roomId +
	 * ":" + token) into roomId + token and sends it here; Client.hx:168-170 overwrites the response's
	 * reconnectionToken back into token. Returning the same seat reservation (same sessionId and
	 * token) is enough; the client then reconnects the WS to
	 * ws://<publicAddress>/<processId>/<roomId>?sessionId=...&reconnectionToken=....
	 */
	function handleReconnect(roomId:String, options:Dynamic, request:HttpRequest):HttpResponse {
		var token:String = (options == null) ? null : Reflect.field(options, "reconnectionToken");
		var room = getRoom(roomId);
		if (room == null || isStaleRoom(room)) {
			return jsonResponse(404, { error: "room not found: " + roomId });
		}

		var record = (token == null || token == "") ? null : room.sessionOfToken(token);
		if (record == null || record.removed) {
			// A kicked / explicitly departed player cannot reconnect.
			trace('[matchmake] reconnect denied for room $roomId');
			return jsonResponse(400, { error: "reconnection not allowed", code: 4010 });
		}

		trace('[matchmake] reconnect -> room ${room.roomId} session ${record.sessionId}');
		return jsonResponse(200, seatReservation(room, record, request));
	}

	// ------------------------------------------------------------------
	// IP lock
	// ------------------------------------------------------------------

	function ipOf(request:HttpRequest):String {
		if (request == null || request.ip == null || request.ip == "") {
			return "unknown";
		}
		return request.ip;
	}

	/** Number of sessions currently held by this IP, across all rooms. */
	function sessionsForIp(ip:String):Int {
		var n = 0;
		mutex.acquire();
		for (room in rooms) {
			for (record in room.sessions) {
				if (!record.removed && record.ip == ip) {
					n++;
				}
			}
		}
		mutex.release();
		return n;
	}

	function ipAllowed(request:HttpRequest):Bool {
		if (disableIpLock) {
			return true;
		}
		return sessionsForIp(ipOf(request)) < maxSessionsPerIp;
	}

	// ------------------------------------------------------------------
	// Seat reservations and the advertised address
	// ------------------------------------------------------------------

	function seatReservation(room:GameRoom, session:SessionRecord, request:HttpRequest):Dynamic {
		return {
			name: room.roomId,
			roomId: room.roomId,
			sessionId: session.sessionId,
			processId: room.processId,
			publicAddress: publicAddressFor(request),
			reconnectionToken: session.reconnectionToken
		};
	}

	/**
	 * Separates the bind address from the advertised address: echoing $host:$wsPort would
	 * advertise 0.0.0.0:2568 when bound to all interfaces, which clients cannot connect to.
	 * The HTTP request's Host header (parsed by HttpServer.readRequest) is used instead,
	 * overridable with --public-host for NAT / multiple network interfaces.
	 */
	function publicAddressFor(request:HttpRequest):String {
		if (publicHost != null && publicHost != "") {
			return '$publicHost:$wsPort';
		}
		var hostHeader = (request == null || request.headers == null) ? null : request.headers.get("host");
		if (hostHeader != null && hostHeader != "") {
			var colon = hostHeader.indexOf(":");
			var hostOnly = (colon >= 0) ? hostHeader.substr(0, colon) : hostHeader;
			if (hostOnly != "") {
				return '$hostOnly:$wsPort';
			}
		}
		return '$host:$wsPort';
	}

	/** A room is stale only when it has no connections and no session waiting to reconnect. */
	function isStaleRoom(room:GameRoom):Bool {
		if (room == null) {
			return true;
		}
		// The resident network room is never stale.
		if (room.isNetwork) {
			return false;
		}
		// A session inside the reconnect window still counts as someone in the room and is not cleared.
		if (room.conns.length > 0 || room.hasPendingReconnect()) {
			return false;
		}
		if (room.sessions.length > 0) {
			return false;
		}
		return Timer.stamp() - room.createdAt > STALE_ROOM_SECONDS;
	}

	/** An empty room (no connections and no sessions) is removed at once; otherwise the stale rule applies. */
	function sweepRooms(now:Float):Void {
		mutex.acquire();
		var dead:Array<String> = [];
		for (room in rooms) {
			// The resident network room is never reclaimed.
			if (room.isNetwork) {
				continue;
			}
			if (room.conns.length == 0 && room.sessions.length == 0) {
				dead.push(room.roomId);
			} else if (room.conns.length == 0 && !room.hasPendingReconnect()
				&& now - room.createdAt > STALE_ROOM_SECONDS
				&& room.sessions.length == 0) {
				dead.push(room.roomId);
			}
		}
		for (id in dead) {
			rooms.remove(id);
			trace('[sweep] removed empty room ' + id);
		}
		mutex.release();
	}

	/**
	 * Room list.
	 *
	 * FindRoomState.hx:168-184 reads everything from metadata (name / ping / points / verified /
	 * clients / maxClients), so those fields must all be present.
	 */
	public function roomList():Dynamic {
		mutex.acquire();
		var list = [];
		for (room in rooms) {
			if (isStaleRoom(room)) {
				continue;
			}
			// The network room is not a joinable match room and is excluded from FindRoomState's list.
			if (room.isNetwork) {
				continue;
			}
			// Public rooms only: private rooms and full rooms must not appear in the find list.
			if (room.state.isPrivate) {
				continue;
			}
			var online = room.playerCount();
			if (online >= GameRoom.MAX_CLIENTS) {
				continue;
			}
			var metadata = {
				name: room.roomId,
				clients: online,
				maxClients: GameRoom.MAX_CLIENTS,
				points: room.metaPoints,
				verified: room.metaVerified,
				ping: room.metaPing,
				networkOnly: room.state.networkOnly
			};
			list.push({
				roomId: room.roomId,
				clients: online,
				maxClients: GameRoom.MAX_CLIENTS,
				metadata: metadata
			});
		}
		mutex.release();
		return list;
	}

	/**
	 * Health snapshot for GET /api/health. Read-only: room counters come from the hub lock, the
	 * database fields from one indexed query each, and nothing here writes.
	 */
	public function health():Dynamic {
		var counts:Dynamic = null;
		try counts = Db.tableCounts() catch (e:Dynamic) { counts = null; }
		return {
			status: "ok",
			uptime: Math.ffloor((haxe.Timer.stamp() - startedAt) * 1000) / 1000,
			uptimeSeconds: Std.int(haxe.Timer.stamp() - startedAt),
			rooms: roomCount(),
			publicRooms: publicRoomCount(),
			online: onlineCount(),
			version: SERVER_VERSION,
			protocol: PROTOCOL_VERSION,
			engine: PROTOCOL_MAGIC,
			dbSchemaVersion: Db.schemaVersion(),
			dbPath: Db.filePath(),
			dbJournalMode: Db.journalMode(),
			dbCounts: counts,
			// Honest boundary: no OS CSPRNG binding exists for neko/cpp on Windows, so a fallback DRBG
			// is used there and is reported as such (see server/README.md).
			entropy: Crypto.osEntropyAvailable ? "os-urandom" : "hmac-sha256-drbg",
			logPath: Log.currentPath()
		};
	}

	public function onlineCount():Int {
		mutex.acquire();
		var total = 0;
		for (room in rooms) {
			total += room.playerCount();
		}
		mutex.release();
		return total;
	}

	/**
	 * Room count for /api/front: only public rooms count as available.
	 * (The console status page wants every room, so it uses roomCount().)
	 */
	public function publicRoomCount():Int {
		mutex.acquire();
		var total = 0;
		for (room in rooms) {
			if (!room.isNetwork && !room.state.isPrivate) total++;
		}
		mutex.release();
		return total;
	}

	/** Total rooms other than /api/front's (the resident network room excluded; used by the console status page). */
	public function roomCount():Int {
		mutex.acquire();
		var total = 0;
		for (room in rooms) {
			if (!room.isNetwork) total++;
		}
		mutex.release();
		return total;
	}

	/**
	 * Pushes a notification to a player's network-room connection (NetworkClient.hx:90).
	 * The room identifies players by their join-options nickname, so it needs a live connection
	 * whose nickname matches (case-insensitive).
	 */
	public function notifyPlayer(name:String, content:String):Bool {
		if (name == null || content == null) return false;
		mutex.acquire();
		var net = rooms.get(GameRoom.NETWORK_ROOM_ID);
		var conn = (net == null) ? null : net.networkConnOf(name);
		mutex.release();
		if (conn == null) return false;
		net.send(conn, GameRoom.frameRoomData("notification", content));
		return true;
	}

	/**
	 * /api/admin/players: iterate non-network rooms and list each acked connection's
	 * nickname/sessionId; playing_rooms uses a nickname -> room id map.
	 */
	public function adminPlayers():Dynamic {
		mutex.acquire();
		var roomsOut:Array<Dynamic> = [];
		var playing:Dynamic = {};
		for (room in rooms) {
			if (room.isNetwork) continue;
			var clients:Array<Dynamic> = [];
			for (conn in room.conns) {
				if (!conn.acked) continue;
				var playerName = connDisplayName(conn);
				clients.push({ sessionId: conn.sessionId, name: playerName });
				if (playerName != null && playerName != "") Reflect.setField(playing, playerName, room.roomId);
			}
			roomsOut.push({
				id: room.roomId,
				meta: {
					name: room.roomId,
					clients: room.playerCount(),
					maxClients: GameRoom.MAX_CLIENTS,
					points: room.metaPoints,
					verified: room.metaVerified,
					ping: room.metaPing
				},
				clients: clients
			});
		}
		mutex.release();
		return { rooms: roomsOut, playing_rooms: playing };
	}

	// ------------------------------------------------------------------
	// Read-only snapshots and a few admin actions for the web console
	// ------------------------------------------------------------------

	/** Console: process counters (stat cards on the overview page). */
	public function counters():Dynamic {
		mutex.acquire();
		var conns = 0;
		for (room in rooms) for (c in room.conns) if (!c.closed) conns++;
		mutex.release();
		return {
			startedAt: startedAt,
			httpRequests: httpRequests,
			httpErrors: httpErrors,
			wsConnections: conns,
			wsAccepted: wsAccepted
		};
	}

	/** Console: saved config.toml takes effect at once (IP lock / limits / reconnect guard). */
	public function applyLimits(ipLock:Bool, ipLockLimit:Int, reconnectGuard:Bool, reconnectLimit:Int):Void {
		this.disableIpLock = !ipLock;
		this.maxSessionsPerIp = (ipLockLimit > 0) ? ipLockLimit : DEFAULT_IP_LOCK_LIMIT;
		this.reconnectGuard = reconnectGuard;
		this.reconnectLimit = (reconnectLimit > 0) ? reconnectLimit : GameRoom.RECONNECT_STORM_LIMIT;
	}

	/**
	 * Console: room + player snapshot. Player fields are read from `conn.player` (available after
	 * ack) without iterating the schema MapSchema: the console is read-only and does not need a
	 * second schema iteration path.
	 */
	public function consoleRooms():Dynamic {
		mutex.acquire();
		var list:Array<Dynamic> = [];
		for (room in rooms) {
			if (room.isNetwork) continue;
			list.push(roomSnapshot(room));
		}
		var net = rooms.get(GameRoom.NETWORK_ROOM_ID);
		var members:Array<Dynamic> = [];
		if (net != null) {
			var names = net.networkNamesList();
			for (conn in net.conns) {
				if (!conn.acked) continue;
				members.push({ sid: conn.sessionId, name: connDisplayName(conn), networkName: conn.networkName });
			}
		}
		mutex.release();
		return { rooms: list, network: { members: members } };
	}

	static function roomSnapshot(room:GameRoom):Dynamic {
		var hostSid = room.state.host;
		var hostName = "";
		for (conn in room.conns) if (conn.sessionId == hostSid) hostName = connDisplayName(conn);
		var players:Array<Dynamic> = [];
		for (conn in room.conns) {
			var snap = clientSnapshot(conn);
			Reflect.setField(snap, "isHost", conn.sessionId == hostSid);
			players.push(snap);
		}
		var pending = 0;
		for (s in room.sessions) if (!s.removed && s.everConnected && s.disconnectedAt >= 0) pending++;
		return {
			roomId: room.roomId,
			isPrivate: room.state.isPrivate,
			networkOnly: room.state.networkOnly,
			isStarted: room.state.isStarted,
			song: room.state.song,
			folder: room.state.folder,
			diff: room.state.diff,
			stageName: room.state.stageName,
			modDir: room.state.modDir,
			health: room.state.health,
			host: room.state.host,
			hostName: hostName,
			winCondition: room.state.winCondition,
			anarchyMode: room.state.anarchyMode,
			createdAt: room.createdAt,
			maxClients: GameRoom.MAX_CLIENTS,
			sessions: room.sessions.length,
			pendingReconnect: pending,
			players: players
		};
	}

	static function clientSnapshot(conn:ClientConn):Dynamic {
		var out:Dynamic = {
			sid: conn.sessionId,
			name: connDisplayName(conn),
			networkName: conn.networkName,
			acked: conn.acked,
			closed: conn.closed,
			ping: null,
			score: null,
			misses: null,
			maxCombo: null,
			points: null,
			songPoints: null,
			botplay: null,
			isReady: null,
			hasEnded: null,
			status: null,
			noteHold: null
		};
		var p:Dynamic = conn.player;
		if (p != null) {
			for (f in ["ping", "score", "misses", "maxCombo", "points", "songPoints", "botplay", "isReady", "hasEnded", "status", "noteHold"])
				Reflect.setField(out, f, Reflect.field(p, f));
		}
		return out;
	}

	/** Console: kick a player by nickname from both their game room (no reconnect) and the network room; returns hits. */
	public function kickPlayer(name:String):Int {
		if (name == null || StringTools.trim(name) == "") return 0;
		var target = StringTools.trim(name).toLowerCase();
		mutex.acquire();
		var hits:Array<{room:GameRoom, conn:ClientConn}> = [];
		for (room in rooms) {
			for (conn in room.conns) {
				var display = connDisplayName(conn);
				var net = conn.networkName;
				var hit = (display != null && display.toLowerCase() == target)
					|| (net != null && net.toLowerCase() == target);
				if (hit) hits.push({ room: room, conn: conn });
			}
		}
		mutex.release();
		var n = 0;
		for (h in hits) {
			if (h.conn.closed) continue;
			if (h.room.isNetwork) h.room.kickNetwork(h.conn) else h.room.disconnect(h.conn, false, true);
			n++;
		}
		return n;
	}

	/** Kicks every online connection of an account id (used for bans; nickname may differ). */
	public function kickAccount(accountId:String):Int {
		if (accountId == null || accountId == "") return 0;
		mutex.acquire();
		var hits:Array<{room:GameRoom, conn:ClientConn}> = [];
		for (room in rooms) {
			for (conn in room.conns) {
				if (conn.accountId == accountId) hits.push({ room: room, conn: conn });
			}
		}
		mutex.release();
		var n = 0;
		for (h in hits) {
			if (h.conn.closed) continue;
			if (h.room.isNetwork) h.room.kickNetwork(h.conn) else h.room.disconnect(h.conn, false, true);
			n++;
		}
		return n;
	}

	/** Console: force-close a game room (the resident network room cannot be closed). */
	public function closeRoom(roomId:String):Bool {
		if (roomId == null || roomId == "") return false;
		mutex.acquire();
		var room = rooms.get(roomId);
		if (room == null || room.isNetwork) {
			mutex.release();
			return false;
		}
		var conns = room.conns.copy();
		mutex.release();
		for (c in conns) if (!c.closed) room.disconnect(c, false, true);
		mutex.acquire();
		rooms.remove(roomId);
		mutex.release();
		trace('[console] closed room $roomId');
		return true;
	}

	/** Console: push an announcement as the existing `notification` message to every network-room connection. */
	public function broadcastNotification(content:String):Int {
		if (content == null || content == "") return 0;
		mutex.acquire();
		var net = rooms.get(GameRoom.NETWORK_ROOM_ID);
		var conns:Array<ClientConn> = (net == null) ? [] : net.conns.copy();
		mutex.release();
		if (net == null) return 0;
		var n = 0;
		for (c in conns) {
			if (c.closed || !c.acked) continue;
			net.send(c, GameRoom.frameRoomData("notification", content));
			n++;
		}
		return n;
	}

	/** Display name for a connection in a game room (Player.name first, then networkName). */
	static function connDisplayName(conn:ClientConn):String {
		if (conn == null) return null;
		if (conn.player != null) {
			var n:Dynamic = Reflect.field(conn.player, "name");
			if (n != null && Std.string(n) != "") return Std.string(n);
		}
		return conn.networkName;
	}

	/**
	 * On ban/delete, kicks the player out of the network room. Same threading convention as
	 * notifyPlayer: room lookup inside hub.mutex, leave outside the lock.
	 */
	public function disconnectPlayer(name:String):Bool {
		if (name == null || name == "") return false;
		mutex.acquire();
		var net = rooms.get(GameRoom.NETWORK_ROOM_ID);
		var conn = (net == null) ? null : net.networkConnOf(name);
		mutex.release();
		if (conn == null) return false;
		net.kickNetwork(conn);
		return true;
	}

	function jsonResponse(status:Int, data:Dynamic):HttpResponse {
		return {
			status: status,
			contentType: "application/json",
			body: haxe.Json.stringify(data)
		};
	}

	// ------------------------------------------------------------------
	// WS main loop
	// ------------------------------------------------------------------

	/**
	 * Releases the WS listen port and asks run() to leave its loop. Idempotent, and safe to call
	 * from another thread than run() (ServerBoot.stop calls it from the client thread).
	 */
	public function stop():Void {
		if (!running) return;
		running = false;
		wsServer.closeListen();
	}

	/** True while run() may still serve WS connections (false after stop()). */
	public function isRunning():Bool return running;

	public function run():Void {
		// stop() sets running = false and closes the listen socket, so the loop leaves without a
		// forced kill (this is what makes an embedded host stoppable).
		while (running) {
			try {
				var ws = wsServer.accept();
				if (ws != null) {
					pending.push(ws);
					pendingSince.push(Timer.stamp());
				}

				processPending();
				processConnections();
				tickRooms(Timer.stamp());

				// Periodically sweeps stale rooms with no connections (ServerHub.rooms only ever grew).
				var now:Float = Timer.stamp();
				if (now - lastSweep > 5.0) {
					lastSweep = now;
					sweepRooms(now);
				}

				// Kept at 2 ms instead of 5 ms: the sleep only bounds how fast a newly connected socket
				// is picked up (the accept itself is non-blocking), so changing it would alter timing in
				// the dedicated and the embedded path without evidence that it is safe. The embedded
				// concern (sharing the hxcpp GC with the render thread) was measured instead: an idle
				// dedicated server spends 0.00 s of CPU over 10 s wall clock (external Get-Process .CPU
				// sampling, see temp/embed/EmbedProbe), so the loop is not a CPU hog.
				Sys.sleep(0.002);

			} catch (e:Dynamic) {
				trace('[server] loop error: ' + Std.string(e));
				Sys.sleep(0.05);
			}
		}
	}

	/** Runs all rooms' periodic work on the main-loop thread (delayed callbacks / ping / reconnect timeouts). */
	function tickRooms(now:Float):Void {
		mutex.acquire();
		var all:Array<GameRoom> = [];
		for (room in rooms) {
			all.push(room);
		}
		mutex.release();

		for (room in all) {
			try {
				room.tick(now);
			} catch (e:Dynamic) {
				trace('[room ' + room.roomId + '] tick error: ' + Std.string(e));
			}
		}
	}

	/** accept() returns before the handshake completes; call process() until WebSocketGeneric resolves the request path. */
	function processPending():Void {
		var keep:Array<WebSocket> = [];
		var keepSince:Array<Float> = [];

		for (i in 0...pending.length) {
			var ws = pending[i];
			ws.process();

			var path:String = Reflect.field(ws, "path");
			if (path != null && path.length > 1 && StringTools.startsWith(path, "/")) {
				attach(ws, path);
			} else if (Timer.stamp() - pendingSince[i] < 5.0) {
				keep.push(ws);
				keepSince.push(pendingSince[i]);
			} else {
				trace('[ws] handshake timeout, dropping socket');
				try {
					ws.close();
				} catch (e:Dynamic) {}
			}
		}

		pending = keep;
		pendingSince = keepSince;
	}

	function attach(ws:WebSocket, path:String):Void {
		wsAccepted++;
		var qIndex = path.indexOf("?");
		var query = qIndex >= 0 ? path.substr(qIndex + 1) : "";
		var pathOnly = qIndex >= 0 ? path.substr(0, qIndex) : path;

		var segments = pathOnly.split("/");
		var clean:Array<String> = [];
		for (segment in segments) {
			if (segment != "") {
				clean.push(segment);
			}
		}

		var roomId = clean.length > 1 ? clean[1] : "";
		var params = parseQuery(query);
		var sessionId = params.exists("sessionId") ? params.get("sessionId") : "";
		var token = params.exists("reconnectionToken") ? params.get("reconnectionToken") : "";

		trace('[ws] attach room=$roomId session=$sessionId');

		var room = getRoom(roomId);
		if (room == null) {
			rejectSocket(ws, 4004, "room not found");
			return;
		}

		// Sessions that did not go through matchmaking are rejected, so the reconnection token
		// can be validated.
		var record = room.sessionOf(sessionId);
		if (record == null) {
			rejectSocket(ws, 4004, "session not found");
			return;
		}

		// A kicked / explicitly departed / timed-out session cannot reconnect.
		if (record.removed) {
			trace('[ws] session $sessionId was removed; rejecting');
			rejectSocket(ws, 4010, "reconnection not allowed");
			return;
		}

		// This session acked before -> this is a reconnect and must carry the correct token.
		// A first-connection session has not acked yet (everConnected=false) and is not token-checked.
		var isReconnect = record.everConnected;
		if (isReconnect && token != record.reconnectionToken) {
			trace('[ws] bad reconnection token for session $sessionId');
			rejectSocket(ws, 4011, "invalid reconnection token");
			return;
		}

		// Reconnect-storm guard (defence in depth; the client-side fix is
		// GameClient.disableLibraryAutoReconnect() in source/online/GameClient.hx).
		// Two concurrent client reconnect paths (the library Room's auto-reconnect and
		// GameClient's HTTP matchmaking) can loop one session forever: attach evicts the old
		// connection, which then reconnects. Normal play reconnects 1-2 times, so exceeding
		// the cap removes the session from the room (equivalent to a kick, no more reconnects).
		if (isReconnect && !reconnectGuardAllows(record)) {
			trace('[ws] reconnect storm for session $sessionId (limit $reconnectLimit/${GameRoom.RECONNECT_STORM_WINDOW}s); rejecting');
			record.removed = true;
			room.removePlayer(record);
			rejectSocket(ws, 4010, "reconnection not allowed");
			return;
		}

		// Matchmaking already checked this; re-check the same conditions from record.options to
		// prevent bypassing matchmaking with a forged attach.
		if (!handshakeOk(record.options)) {
			trace('[ws] reject (5007): not a SeiunEngine handshake');
			rejectSocket(ws, 5007, "Not a SeiunEngine server/client handshake");
			return;
		}

		// Banned accounts may not (re)join any room. The client already sends networkId in the
		// join options, so no new protocol message is needed.
		var netAccountId:String = null;
		if (record.options != null) {
			var netIdValue:Dynamic = Reflect.field(record.options, "networkId");
			if (netIdValue != null && Std.string(netIdValue) != "") netAccountId = Std.string(netIdValue);
		}
		var netAccount = (netAccountId == null) ? null : AccountStore.byId(netAccountId);
		if (AccountStore.isBanned(netAccount)) {
			trace('[ws] banned account $netAccountId rejected at attach');
			rejectSocket(ws, 5006, AccountStore.banMessage(netAccount));
			return;
		}

		var conn = new ClientConn(ws);
		conn.sessionId = sessionId;
		conn.roomId = roomId;
		conn.accountId = netAccountId;
		conn.reconnected = isReconnect;

		// Bind the session to the new conn first, then evict any leftover old conn: the old conn's
		// onclose is a synchronous callback and needs record.conn to recognise that it was superseded.
		record.conn = conn;

		// If the same session still has an old conn (half-open), evict it.
		var stale = room.connOf(sessionId);
		if (stale != null && stale != conn) {
			room.conns.remove(stale);
			room.closeConn(stale);
		}

		ws.onmessageBytes = function(bytes:Bytes) handleClientData(room, conn, bytes);
		ws.onerror = function(message:String) trace('[ws] error session=$sessionId: $message');
		ws.onclose = function(?event:CloseEvent) {
			trace('[ws] closed session=$sessionId');
			room.disconnect(conn);
		};

		room.conns.push(conn);
		room.onOpen(conn);
	}

	function rejectSocket(ws:WebSocket, code:Int, message:String):Void {
		trace('[ws] reject ($code): $message');
		try {
			ws.sendBytes(GameRoom.frameError(code, message));
			ws.close();
		} catch (e:Dynamic) {}
	}

	/**
	 * Sliding-window check. Returns false when a reconnect storm is detected. Only called for
	 * reconnect attaches (sessions with everConnected); first connections are not counted.
	 */
	function reconnectGuardAllows(record:SessionRecord):Bool {
		if (!reconnectGuard) {
			return true;
		}

		var now:Float = Timer.stamp();
		var kept:Array<Float> = [];
		for (t in record.attachTimes) {
			if (now - t <= GameRoom.RECONNECT_STORM_WINDOW) {
				kept.push(t);
			}
		}
		kept.push(now);
		record.attachTimes = kept;
		return kept.length <= reconnectLimit;
	}

	function processConnections():Void {
		mutex.acquire();
		var all:Array<GameRoom> = [];
		for (room in rooms) {
			all.push(room);
		}
		mutex.release();

		for (room in all) {
			var snapshot = room.conns.copy();
			for (conn in snapshot) {
				try {
					conn.ws.process();
				} catch (e:Dynamic) {
					trace('[ws] process error: ' + Std.string(e));
				}
			}
		}
	}

	function parseQuery(query:String):Map<String, String> {
		var params = new Map<String, String>();
		if (query == null || query == "") {
			return params;
		}
		for (pair in query.split("&")) {
			if (pair == "") {
				continue;
			}
			var index = pair.indexOf("=");
			if (index < 0) {
				params.set(pair, "");
			} else {
				params.set(pair.substr(0, index), pair.substr(index + 1));
			}
		}
		return params;
	}

	// ------------------------------------------------------------------
	// Client messages
	// ------------------------------------------------------------------

	function handleClientData(room:GameRoom, conn:ClientConn, bytes:Bytes):Void {
		if (bytes == null || bytes.length == 0) {
			return;
		}

		var code = bytes.get(0);

		if (code == Protocol.JOIN_ROOM) {
			// The client sends this ack after dispatching onJoin, so the full state is safe to send now.
			room.onAck(conn);
			return;
		}

		if (code == Protocol.LEAVE_ROOM) {
			// Explicit leave = the client's own LEAVE_ROOM; cannot reconnect.
			room.onLeave(conn, true);
			return;
		}

		if (code == Protocol.PING) {
			room.send(conn, GameRoom.framePing());
			return;
		}

		if (code == Protocol.ROOM_DATA) {
			var it:It = { offset: 1 };
			var type:Dynamic = SPEC.stringCheck(bytes, it) ? Decode.string(bytes, it) : Decode.number(bytes, it);
			var message:Dynamic = (bytes.length > it.offset)
				? MsgPack.decode(bytes.sub(it.offset, bytes.length - it.offset))
				: null;
			handleRoomData(room, conn, type, message);
			return;
		}

		if (code == Protocol.ROOM_DATA_BYTES) {
			var it:It = { offset: 1 };
			var type:Dynamic = SPEC.stringCheck(bytes, it) ? Decode.string(bytes, it) : Decode.number(bytes, it);
			trace('[room] <- bytes message "' + Std.string(type) + '" (' + (bytes.length - it.offset) + ' bytes)');
			return;
		}

		trace('[room] unhandled protocol code $code');
	}

	function handleRoomData(room:GameRoom, conn:ClientConn, type:Dynamic, message:Dynamic):Void {
		var typeName = Std.string(type);

		// The network room goes through the separate social business layer: it has no Player and
		// cannot enter RoomLogic.handle (whose first line drops everything when self == null).
		if (room.isNetwork) {
			NetworkLogic.handle(room, conn, type, message);
			return;
		}

		if (typeName == "probe:patch") {
			trace('[room] applying contract patch, round ' + (room.patchRound + 1));
			room.applyContractPatch();
			return;
		}

		if (typeName == "probe:leave") {
			trace('[room] client requested leave: ' + conn.sessionId);
			room.onLeave(conn, true);
			return;
		}

		// The legacy protocol-test contract (Probe.hx:146 msgpack echo) only applies to the "probe:"
		// prefix; all other messages go to the business layer (RoomLogic). Echoing business messages
		// as "alert" would make real game clients pop an alert (GameClient.hx:446).
		if (StringTools.startsWith(typeName, "probe:")) {
			room.onRoomData(conn, type, message);
			return;
		}

		RoomLogic.handle(room, conn, type, message);
	}
}
