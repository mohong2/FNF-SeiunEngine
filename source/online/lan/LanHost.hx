package online.lan;

#if ONLINE_ALLOWED
import haxe.Json;
import online.GameClient;
import online.backend.Thread;
import online.backend.Waiter;
import online.http.HTTPHandler;
import online.util.OnlineLang;
import online.util.ServerList;
import online_server.ServerBoot;
import sys.net.Host;
import sys.net.Socket;

/**
 * Host settings taken from the LAN panel (persisted in ClientPrefs by the caller).
 */
typedef LanHostConfig = {
	/** Preferred HTTP port; the WS port is always this + 1. 0/negative = the built-in default. */
	var port:Int;
	/** 1..64; 0 = keep the server's own default (GameRoom.MAX_CLIENTS). */
	var maxClients:Int;
	/** True = the room is listed in FIND on the hosted server. */
	var publicRoom:Bool;
	/** True = several sessions from one IP are allowed (the panel's "Allow players from this PC"). */
	var allowSamePc:Bool;
	/** Empty = <applicationStorageDirectory>/lanhost. */
	var dataDir:String;
}

/**
 * Live view of the host, mutated by LanHost's worker threads and read by LanHostState on the
 * render thread. A real class on purpose: hxcpp compiles field access on a Dynamic-typed local
 * through __Field/__SetField, which is both slow and a source of "Invalid field" crashes (same
 * reason GameClient.ServerProbe is a class). Only the fields are shared; no callback lives here.
 */
class LanHostStatus {
	public var running:Bool = false;
	public var starting:Bool = false;
	public var stopping:Bool = false;
	public var httpPort:Int = 0;
	public var wsPort:Int = 0;
	public var lanIps:Array<String> = [];
	/** "ws://<lan ip>:<http port>" handed to friends; null while not hosting. */
	public var shareAddress:String = null;
	public var clients:Int = 0;
	/** Last start/stop failure, shown by the panel once per errorId. */
	public var error:String = null;
	public var errorId:Int = 0;
	/** Bumped on every change so a polling panel can cheaply detect one. */
	public var revision:Int = 0;

	public function new() {}
}

/**
 * In-client LAN hosting (design temp/lan-host-recon/design.md section 2.3, variant A).
 *
 * The server itself is server/src/online_server/ServerBoot, compiled into this binary by the
 * ONLINE_ALLOWED classpath in project.xml. LanHost owns the process-wide singleton rules:
 *
 *  - start() probes free ports, resolves a writable data dir, starts the embedded server, runs
 *    its blocking loop on a background thread and only then joins the room as a normal player.
 *  - Every step that can block (dir creation, ipconfig, listener bind, /api/health polling) runs
 *    on a worker thread. Nothing here touches Flixel directly: results are handed to the render
 *    thread through Waiter.put / plain status fields, exactly like online/backend/Thread.hx does.
 *  - stop() is idempotent and leaves no listener behind (ServerBoot.stop closes the sockets).
 *  - Hosting never writes ClientPrefs or ServerList: the player's saved server selection survives
 *    (the runtime-only GameClient.lanLocalOverride / lanShareAddress carry the local address).
 *
 * One host at a time per process: the server's config/DB state is process-global (design R3),
 * so start() is refused while another host is starting, running or stopping. A restart after
 * stop() is supported (same data directory); only a data-directory change needs a game restart
 * (ServerBoot keeps its SQLite handle for the whole process).
 */
class LanHost {
	/** A LAN host must be reachable from other machines, so it never binds loopback. */
	public static inline var BIND_HOST:String = '0.0.0.0';
	/** First port tried when the pref is unset; matches ServerList.DEFAULT_PORT. */
	public static inline var DEFAULT_PORT:Int = 2567;
	static inline var MAX_CLIENTS_MIN:Int = 1;
	static inline var MAX_CLIENTS_MAX:Int = 64;
	/** How long /api/health is polled before a start is treated as failed. */
	static inline var HEALTH_TIMEOUT_SECONDS:Float = 15;
	static inline var HEALTH_POLL_SECONDS:Float = 0.25;
	/** How many (port, port+1) pairs the probe walks upward before giving up. */
	static inline var PORT_SCAN_RANGE:Int = 50;
	/** Bind attempts per start(): a restart can lose the race against the previous stop. */
	static inline var START_ATTEMPTS:Int = 5;
	static inline var START_RETRY_SECONDS:Float = 0.25;

	public static var status(default, null):LanHostStatus = new LanHostStatus();

	/** The running embedded server, or null. Only ever touched from the render thread. */
	static var boot:ServerBoot = null;
	/**
	 * The last boot this process created. Kept after stop() so a restart can wait for it to finish
	 * releasing its listen sockets, and so a refusal can be explained as "still in use".
	 */
	static var lastBoot:ServerBoot = null;
	/** "ws://127.0.0.1:<http port>" while hosting; null otherwise. */
	static var localAddress:String = null;
	/**
	 * Start/stop epoch. Every start() and stop() bumps it, and each worker remembers the value it
	 * was created with: a worker whose epoch is stale must not publish status and must release the
	 * boot it created. This is what makes "Stop during Starting" safe.
	 */
	static var generation:Int = 0;
	static var refreshing:Bool = false;
	static var changeListener:Void->Void = null;

	/**
	 * The panel registers one listener; notifications are always delivered on the render thread
	 * through Waiter, so a worker thread can call notify() safely.
	 */
	public static function setChangeListener(listener:Void->Void):Void {
		changeListener = listener;
	}

	public static function isRunning():Bool {
		return status.running;
	}

	/** The address the host's own client uses; null while not hosting. */
	public static function localServerAddress():String {
		return localAddress;
	}

	/**
	 * Start hosting. Returns immediately: the UI follows LanHost.status (and the listener).
	 * A second call while running/starting does nothing.
	 */
	public static function start(config:LanHostConfig):Void {
		// A stop that is still releasing its sockets owns the machine until it finishes; start()
		// re-binds the same port pair, so Host -> Stop -> Host must serialise behind it.
		if (status.running || status.starting || status.stopping || boot != null)
			return;

		generation++;
		var gen = generation;

		status.starting = true;
		status.error = null;
		notify();

		Thread.run(function() bootWorker(config, gen), function(exc) {
			// Last-resort handler: release a boot this worker already created, if any.
			var instance = (generation == gen) ? boot : null;
			abortStart(Std.string(exc), gen, instance);
		});
	}

	/**
	 * Stop hosting and release the listener. Idempotent; must be called from the render thread
	 * because it may leave the local room and re-point the player's network handler.
	 */
	public static function stop():Void {
		if (status.stopping)
			return;
		if (!status.running && !status.starting && boot == null)
			return;

		// Invalidate any start still in flight: its worker will clean itself up.
		generation++;

		status.stopping = true;
		notify();

		var instance = boot;
		boot = null;

		// Clear the runtime plumbing first so nothing advertises a dead address.
		var wasLocal = localAddress;
		localAddress = null;
		GameClient.lanShareAddress = null;
		GameClient.setLanLocalOverride(null);

		// Leave the local room before its listener disappears (main thread: GameClient is not
		// thread safe).
		if (wasLocal != null && GameClient.address == wasLocal && GameClient.isConnected())
			GameClient.leaveRoom('LAN host stopped.');

		status.running = false;
		status.starting = false;
		status.httpPort = 0;
		status.wsPort = 0;
		status.shareAddress = null;
		status.clients = 0;
		status.lanIps = [];
		notify();

		if (instance == null) {
			status.stopping = false;
			notify();
			return;
		}

		// Closing the sockets can block briefly; keep it off the render thread.
		Thread.run(function() {
			try instance.stop() catch (e:Dynamic) trace('[lanhost] stop failed: ' + Std.string(e));
			Waiter.put(function() {
				status.stopping = false;
				notify();
			});
		}, function(exc) {
			status.stopping = false;
			notify();
		});
	}

	/**
	 * Re-read /api/health for the client count, throttled and off-thread. The panel calls this
	 * from update(); a dead health endpoint only clears the count, it never stops the host.
	 */
	public static function refreshStatus():Void {
		if (!status.running || refreshing || status.httpPort <= 0)
			return;

		refreshing = true;
		var port = status.httpPort;
		Thread.run(function() {
			var healthy = isHealthy(port);
			var online = healthy ? readOnlineCount(port, status.clients) : 0;
			refreshing = false;

			if (online != status.clients || !healthy) {
				status.clients = online;
				notify();
			}
		}, function(exc) refreshing = false);
	}

	/** Empty pref = <applicationStorageDirectory>/lanhost (a writable local volume; design 2.4). */
	public static function resolveDataDir(configured:String):String {
		if (configured != null && configured.trim() != '')
			return configured.trim();

		var base = lime.system.System.applicationStorageDirectory;
		if (base == null || base == '')
			base = 'lanhost/';
		return base + 'lanhost';
	}

	/**
	 * Probe free (http, ws) ports by trial use. httpPort is preferred, wsPort is httpPort + 1
	 * (both the panel and the standalone server use that pairing).
	 *
	 * The probe is a connect plus a bind: on Windows SO_REUSEADDR lets bind() succeed while
	 * another socket already listens, so a bare bind is not enough to prove a port is free.
	 */
	public static function findFreePortPair(preferred:Int):{http:Int, ws:Int} {
		if (preferred < 1024)
			preferred = DEFAULT_PORT;

		for (i in 0...PORT_SCAN_RANGE) {
			var http = preferred + i;
			var ws = http + 1;
			if (ws > 65535)
				break;
			if (!portIsUsed(http) && !portIsUsed(ws) && portCanBind(http) && portCanBind(ws))
				return {http: http, ws: ws};
		}
		return null;
	}

	// ------------------------------------------------------------------
	// Worker-thread implementation
	// ------------------------------------------------------------------

	static function bootWorker(config:LanHostConfig, gen:Int):Void {
		var dir = resolveDataDir(config == null ? null : config.dataDir);
		if (!ensureDirectory(dir) || !ensureDirectory(dir + '/logs')) {
			abortStart(OnlineLang.L('lan.error.dataDir', 'Could not create the LAN host data folder:') + '\n' + dir, gen, null);
			return;
		}

		// A restart right after stop() must not race the sockets the previous boot is still
		// releasing: wait for it to report that it stopped BEFORE probing the port pair, so the
		// preferred port is reused instead of silently shifting upward.
		waitForPreviousBoot(2.0);
		if (generation != gen)
			return;

		var preferred = (config != null && config.port > 0) ? config.port : DEFAULT_PORT;
		var ports = findFreePortPair(preferred);
		if (ports == null) {
			abortStart(OnlineLang.L('lan.error.portBusy', 'No free port was found near ') + preferred + '.', gen, null);
			return;
		}

		if (generation != gen)
			return;

		status.httpPort = ports.http;
		status.wsPort = ports.ws;

		// ServerConfig.load(<dataDir>/config.toml) is what maps max clients and the per-IP lock
		// onto GameRoom.MAX_CLIENTS / ServerConfig.limits (server Main.hx:157-163). The frozen
		// ServerOptions typedef carries neither, so the file is the interface for the two panel
		// settings. A failure here is not fatal: the server keeps its code defaults.
		try writeHostConfig(dir, config == null ? 0 : config.maxClients, config != null && config.allowSamePc)
		catch (e:Dynamic) trace('[lanhost] config.toml not written: ' + Std.string(e));

		var instance:ServerBoot = null;
		var lastError:Dynamic = null;
		for (attempt in 0...START_ATTEMPTS) {
			// stop() invalidates this start: give up before binding anything.
			if (generation != gen)
				return;
			try {
				instance = ServerBoot.start({
					host: BIND_HOST,
					httpPort: ports.http,
					wsPort: ports.ws,
					dataDir: dir,
					logDir: dir + '/logs',
					// The embedded host is not an operator console: warnings only (design R14).
					logLevel: 'warn',
					// No admin account in embedded mode (design R8), so nobody could pass the console
					// login wall. D-R3-5: this machine gets a GET-only read-only console session
					// instead (writes and other peers still get 401).
					localConsoleReadOnly: true,
					adminEmail: null,
					// null = echo the HTTP Host header, so a friend who opens
					// http://192.168.1.50:2567 is told to use ws://192.168.1.50:2568 while the host
					// itself is told 127.0.0.1:2568 (server publicAddressFor()).
					publicHost: null
				});
				break;
			} catch (e:Dynamic) {
				lastError = e;
				// The first attempt after a stop can lose the bind race; the rest of the retries
				// are for that transient case only.
				Sys.sleep(START_RETRY_SECONDS);
			}
		}

		if (instance == null) {
			// ServerBoot is single-instance per process and keeps its SQLite handle open after
			// stop() (ServerBoot.hx:106-120): re-hosting in the same data directory is supported,
			// but a data directory change or a boot that never stopped still needs a game restart.
			var detail = lastError == null ? 'ServerBoot.start returned null' : Std.string(lastError);
			if (lastBoot != null)
				abortStart(OnlineLang.L('lan.error.alreadyStarted', 'The embedded server is still in use by this game session (or was started with another data folder). Restart the game to host again.') + '\n' + detail, gen, null);
			else
				abortStart(OnlineLang.L('lan.error.start', 'The LAN server could not start:') + '\n' + detail, gen, null);
			return;
		}

		// stop() arrived while the listeners were binding: release what this worker created and
		// leave the status the stop already published alone.
		if (generation != gen) {
			try instance.stop() catch (e:Dynamic) {}
			return;
		}

		boot = instance;
		lastBoot = instance;

		// The listener loop blocks; it must never run on the render thread.
		sys.thread.Thread.create(function() {
			try instance.runLoop()
			catch (e:Dynamic) trace('[lanhost] server loop stopped: ' + Std.string(e));
		});

		if (!waitForHealth(ports.http, HEALTH_TIMEOUT_SECONDS)) {
			abortStart(OnlineLang.L('lan.error.timeout', 'The LAN server did not answer /api/health in time.'), gen, instance);
			return;
		}

		if (generation != gen) {
			// stop() during the health wait: release this worker's boot.
			if (boot == instance)
				boot = null;
			try instance.stop() catch (e:Dynamic) {}
			return;
		}

		var local = 'ws://127.0.0.1:' + ports.http;
		localAddress = local;

		var ips = ServerList.localLanAddresses();
		status.lanIps = ips;
		status.clients = readOnlineCount(ports.http, 0);
		status.shareAddress = shareAddressFor(ips, ports.http);

		// Everything below touches Flixel/GameClient state: hand it to the render thread.
		Waiter.put(function() {
			// A newer start()/stop() owns the state now; this stale worker must not publish.
			if (generation != gen || boot != instance)
				return;

			status.running = true;
			status.starting = false;

			GameClient.setLanLocalOverride(local);
			// getRoomSecret() then produces "ROOMID;ws://192.168.x.y:port" (design 2.6), so the
			// copied room code is directly joinable by a LAN friend.
			GameClient.lanShareAddress = status.shareAddress;
			notify();

			// The same call OnlineState's HOST row makes: the host becomes a player of its own
			// room, so the room code in the panel is real and the room is playable.
			GameClient.createRoom(local, function(err:Dynamic) {
				if (err != null) {
					status.error = OnlineLang.L('lan.error.join', 'The room could not be created:') + '\n' + Std.string(err);
					status.errorId++;
					notify();
					return;
				}

				// The server creates game rooms private (RoomLogic.hx:60) and exposes the same
				// toggle the room settings screen uses, so the panel's "Public room" switch is
				// what makes a hosted room appear in FIND on this server.
				if (config != null && config.publicRoom && GameClient.room != null && GameClient.room.state.isPrivate)
					GameClient.send('togglePrivate');
			});
		});
	}

	/**
	 * Failure (or cancellation) path for workers. A stale generation only releases the listener
	 * it was handed; it never rewrites the status a newer start/stop already published.
	 */
	static function abortStart(message:String, gen:Int, instance:ServerBoot):Void {
		var isCurrent = generation == gen;
		if (isCurrent) {
			boot = null;
			localAddress = null;
		}

		if (instance != null) {
			try instance.stop() catch (e:Dynamic) {}
		}

		if (!isCurrent)
			return;

		status.running = false;
		status.starting = false;
		status.stopping = false;
		status.httpPort = 0;
		status.wsPort = 0;
		status.clients = 0;
		status.lanIps = [];
		status.shareAddress = null;
		status.error = message;
		status.errorId++;
		notify();
	}

	static function notify():Void {
		status.revision++;

		var listener = changeListener;
		if (listener == null)
			return;

		// Waiter is a global FlxG plugin (source/Main.hx:294), so this is safe from any thread.
		Waiter.put(listener);
	}

	static function writeHostConfig(dir:String, maxClients:Int, allowSamePc:Bool):Void {
		var toml = '[server]\n';
		toml += 'ip_lock = ' + (allowSamePc ? 'false' : 'true') + '\n';
		if (maxClients > 0) {
			var clamped = maxClients < MAX_CLIENTS_MIN ? MAX_CLIENTS_MIN : (maxClients > MAX_CLIENTS_MAX ? MAX_CLIENTS_MAX : maxClients);
			toml += 'max_clients = ' + clamped + '\n';
		}
		sys.io.File.saveContent(dir + '/config.toml', toml);
	}

	static function shareAddressFor(ips:Array<String>, httpPort:Int):String {
		// A detected LAN IPv4 is what a friend can actually reach; loopback is the honest fallback
		// when the interfaces cannot be listed (mobile) or none is private (design 2.9).
		var host = (ips != null && ips.length > 0) ? ips[0] : '127.0.0.1';
		return 'ws://' + host + ':' + httpPort;
	}

	static function ensureDirectory(path:String):Bool {
		if (path == null || path == '')
			return false;

		try {
			if (!sys.FileSystem.exists(path))
				sys.FileSystem.createDirectory(path);
			return sys.FileSystem.exists(path);
		} catch (e:Dynamic) {
			return false;
		}
	}

	/**
	 * Wait until the previously started boot reports that it stopped (or timeout). ServerBoot
	 * closes its listen sockets from stop(), and the OS can take a moment to make them bindable
	 * again, so a restart must not bind before the previous boot says it is done.
	 */
	static function waitForPreviousBoot(seconds:Float):Void {
		var deadline = Sys.time() + seconds;
		while (Sys.time() < deadline) {
			var previous = lastBoot;
			if (previous == null || !previous.isRunning())
				return;
			Sys.sleep(0.1);
		}
	}

	static function waitForHealth(port:Int, timeoutSeconds:Float):Bool {
		var deadline = Sys.time() + timeoutSeconds;
		while (Sys.time() < deadline) {
			if (isHealthy(port))
				return true;
			Sys.sleep(HEALTH_POLL_SECONDS);
		}
		return isHealthy(port);
	}

	static function isHealthy(port:Int):Bool {
		var raw = getBody(port, '/api/health');
		if (raw == null)
			return false;

		var parsed:Dynamic = null;
		try parsed = Json.parse(raw) catch (e:Dynamic) return false;
		if (parsed == null || !Reflect.hasField(parsed, 'status'))
			return false;
		return Std.string(Reflect.field(parsed, 'status')) == 'ok';
	}

	/** /api/health's "online" counter, or 'fallback' when the probe fails. */
	static function readOnlineCount(port:Int, fallback:Int):Int {
		var raw = getBody(port, '/api/health');
		if (raw == null)
			return fallback;

		var parsed:Dynamic = null;
		try parsed = Json.parse(raw) catch (e:Dynamic) return fallback;
		if (parsed == null || !Reflect.hasField(parsed, 'online'))
			return fallback;

		var online = Reflect.field(parsed, 'online');
		if (online == null)
			return fallback;
		return Std.int(online);
	}

	/**
	 * One blocking GET through the engine's HTTP handler (haxe.Http natively crashes on its own
	 * failure paths on cpp). Always called from a worker thread.
	 */
	static function getBody(port:Int, path:String):String {
		try {
			var http = new HTTPHandler('http://127.0.0.1:' + port);
			var response = http.request(path);
			if (response == null || response.isFailed())
				return null;
			return response.getString();
		} catch (e:Dynamic) {
			return null;
		}
	}

	/** True when something already accepts TCP connections on the port. */
	static function portIsUsed(port:Int):Bool {
		var socket:Socket = null;
		try {
			socket = new Socket();
			// No explicit timeout: Haxe's Socket.connect has none, and a loopback connect either
			// completes at once (a listener is there) or fails at once (connection refused).
			socket.connect(new Host('127.0.0.1'), port);
			socket.close();
			return true;
		} catch (e:Dynamic) {
			if (socket != null) {
				try socket.close() catch (e2:Dynamic) {}
			}
			return false;
		}
	}

	static function portCanBind(port:Int):Bool {
		var socket:Socket = null;
		try {
			socket = new Socket();
			socket.bind(new Host(BIND_HOST), port);
			socket.close();
			return true;
		} catch (e:Dynamic) {
			if (socket != null) {
				try socket.close() catch (e2:Dynamic) {}
			}
			return false;
		}
	}
}
#end
