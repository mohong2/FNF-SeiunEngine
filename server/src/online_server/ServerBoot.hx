package online_server;

import online_server.Main.ServerHub;
import online_server.ServerMail.SmtpConfig;
import online_server.db.Db;
import online_server.db.LegacyImport;

/**
 * Options of ServerBoot.start. This is the interface contract shared with the embedded host in the
 * game client (source/online/lan/LanHost.hx). Every field is required on purpose: adding one forces
 * both construction sites (Main.hx, LanHost.hx) to decide its value instead of silently drifting.
 */
typedef ServerOptions = {
	var host:String;
	var httpPort:Int;
	var wsPort:Int;
	var dataDir:String;
	var logDir:String;
	var logLevel:String;
	var adminEmail:String;
	var publicHost:Null<String>;
	/**
	 * Loopback read-only console (user ruling D-R3-5). When true, a GET from 127.0.0.1 needs no
	 * credential (Api.consoleAuth); the embedded game host sets it because it has no admin account,
	 * the dedicated server keeps the default false and its normal login.
	 */
	var localConsoleReadOnly:Bool;
}

/**
 * CLI-only knobs of the dedicated server. They are deliberately NOT part of ServerOptions: an
 * embedded host belongs to the game client, which has no SMTP credentials, no fixture directory
 * and no legacy import to configure. server/src/online_server/Main.hx (the argv shim) is the only
 * caller that passes this, and every field is optional.
 */
typedef ServerCliOptions = {
	/** --disable-ip-lock / --ip-lock-limit (0 = use config.toml). */
	var ?disableIpLock:Bool;
	var ?ipLockLimit:Int;
	/** --disable-reconnect-guard / --reconnect-limit (0 = use config.toml). */
	var ?disableReconnectGuard:Bool;
	var ?reconnectLimit:Int;
	/** --smtp-*: wins over config.toml [smtp]; host and mail are both required to enable sending. */
	var ?smtpHost:String;
	var ?smtpPort:Int;
	var ?smtpUser:String;
	var ?smtpPass:String;
	var ?smtpMail:String;
	/** --auth-ttl-minutes (-1 = use config.toml / the 30 day default). */
	var ?authTtlMinutes:Int;
	/** --ng-app-id / --discord-webhook. */
	var ?ngAppId:String;
	var ?discordWebhook:String;
	/** --import-legacy-json. */
	var ?importLegacyJson:Bool;
	/** --fixture-dir (GameRoom test fixtures). */
	var ?fixtureDir:String;
}

/** Startup failure of ServerBoot.start. A normal Haxe exception so callers can catch it. */
class ServerBootError extends haxe.Exception {
	public function new(message:String) {
		super(message);
	}
}

/**
 * In-process server boot: the startup that used to live in Main.main() (logging, config.toml,
 * SQLite storage, HTTP + WebSocket listeners, room hub), parameterised by ServerOptions instead of
 * argv so the game client can host a server from inside the running game ("Open to LAN").
 *
 * Lifecycle: start() binds everything and returns without blocking; runLoop() is the blocking serve
 * loop and belongs on a background sys.thread.Thread; stop() releases both listen ports and lets
 * runLoop() return. start() never calls Sys.exit - every failure is reported as a ServerBootError or
 * as the underlying target exception.
 *
 * Restart policy: Host -> Stop -> Host again works in the same process for the SAME data directory
 * (the SQLite handle stays open and keeps its data); a different data directory needs a process
 * restart, because server/src/online_server/db/Db.hx keeps the first opened connection forever.
 */
class ServerBoot {
	/** The one boot of this process, or null when no server was started in this process. */
	static var instance:ServerBoot = null;

	/** Data directory this boot opened (SQLite + JSON storage + config.toml). */
	var dataDir:String;
	var host:String;

	public var httpPort(default, null):Int;
	public var wsPort(default, null):Int;

	var hub:ServerHub;
	var http:HttpServer;
	/** True between a successful start() and stop(). */
	var running:Bool = false;
	var stopped:Bool = false;
	/** Guards runLoop() against a second hub loop in this process. */
	var loopActive:Bool = false;

	/** ServerBoot instances are created by start(); the constructor is not part of the contract. */
	function new() {}

	/** The boot created by start() in this process, or null. */
	public static function current():ServerBoot {
		return instance;
	}

	/**
	 * Starts the server in this process and returns it; does not block and never calls Sys.exit.
	 *
	 * Any startup failure (invalid options, a port already in use, an unreadable data directory) is
	 * thrown as a normal Haxe exception, so an embedded host can show an error and keep running.
	 * Probing that the ports are free is the caller's job; start() only reports the bind failure.
	 *
	 * One active server per process: start() while a previous boot is still running throws. After
	 * stop() the same data directory may be hosted again (Host -> Stop -> Host again); the new boot
	 * re-runs Log / ServerConfig.load / Api.init and the stores on top of the still-open SQLite
	 * handle, so the data survives. A DIFFERENT data directory throws: db/Db.hx keeps the first
	 * opened connection for the lifetime of the process, so that needs a process restart.
	 *
	 * cli carries the dedicated server's command line flags (see ServerCliOptions); an embedded
	 * caller omits it and gets config.toml + code defaults.
	 */
	public static function start(opts:ServerOptions, ?cli:ServerCliOptions):ServerBoot {
		if (opts == null) throw new ServerBootError("start: options are required");
		if (instance != null) {
			// One active server per process: a second start() would double-bind both ports.
			if (instance.running) {
				throw new ServerBootError("start: a server is already running in this process; call stop() first");
			}
			// The previous boot was stopped. Replacing it is only safe once its serve loop has really
			// left; sys.thread.Thread has no join() in Haxe 4.3, so the loop publishes its own flag.
			if (!instance.waitForLoopExit(5.0)) {
				throw new ServerBootError("start: the previous serve loop has not left its socket loop yet; retry in a moment");
			}
		}

		var host = opts.host;
		if (host == null || host == "") throw new ServerBootError("start: host must not be empty");
		var httpPort = checkPort("httpPort", opts.httpPort);
		var wsPort = checkPort("wsPort", opts.wsPort);
		if (httpPort == wsPort) throw new ServerBootError("start: httpPort and wsPort must differ (both " + httpPort + ")");
		var dataDir = opts.dataDir;
		if (dataDir == null || dataDir == "") throw new ServerBootError("start: dataDir must not be empty");
		// Logs default to <data-dir>/logs: an embedded caller has no server/ working directory.
		var logDir = (opts.logDir == null || opts.logDir == "") ? dataDir + "/logs" : opts.logDir;
		var logLevel = (opts.logLevel == null || opts.logLevel == "") ? "info" : opts.logLevel;

		// CLI-only knobs (absent for embedded callers).
		var disableIpLock = false;
		var ipLockLimit = 0;
		var disableReconnectGuard = false;
		var reconnectLimit = 0;
		var smtpHost:String = null;
		var smtpPort = 25;
		var smtpUser:String = null;
		var smtpPass:String = null;
		var smtpMail:String = null;
		var cliAuthTtl = -1;
		var ngAppId:String = null;
		var discordWebhook:String = null;
		var importLegacyJson = false;
		var fixtureDir:String = null;
		if (cli != null) {
			if (cli.disableIpLock != null) disableIpLock = cli.disableIpLock;
			if (cli.ipLockLimit != null) ipLockLimit = cli.ipLockLimit;
			if (cli.disableReconnectGuard != null) disableReconnectGuard = cli.disableReconnectGuard;
			if (cli.reconnectLimit != null) reconnectLimit = cli.reconnectLimit;
			if (cli.smtpHost != null) smtpHost = cli.smtpHost;
			if (cli.smtpPort != null) smtpPort = cli.smtpPort;
			if (cli.smtpUser != null) smtpUser = cli.smtpUser;
			if (cli.smtpPass != null) smtpPass = cli.smtpPass;
			if (cli.smtpMail != null) smtpMail = cli.smtpMail;
			if (cli.authTtlMinutes != null) cliAuthTtl = cli.authTtlMinutes;
			if (cli.ngAppId != null) ngAppId = cli.ngAppId;
			if (cli.discordWebhook != null) discordWebhook = cli.discordWebhook;
			if (cli.importLegacyJson != null) importLegacyJson = cli.importLegacyJson;
			if (cli.fixtureDir != null) fixtureDir = cli.fixtureDir;
		}

		// Db keeps the first opened connection for the whole process (db/Db.hx), so a boot can only
		// ever use one data directory. Re-hosting the SAME directory is supported (Host -> Stop ->
		// Host again, right below); a different one must not silently reuse the first database.
		var expectedDb = Db.defaultFileFor(dataDir + "/accounts.json");
		if (Db.isOpen() && Db.filePath() != expectedDb) {
			throw new ServerBootError("start: this process already owns the SQLite handle at " + Db.filePath()
				+ "; a different data directory (" + dataDir + ") needs a process restart");
		}

		// Embedded hosts may point at a data directory that does not exist yet.
		try {
			if (!sys.FileSystem.exists(dataDir)) sys.FileSystem.createDirectory(dataDir);
		} catch (e:Dynamic) {
			throw new ServerBootError("start: cannot create data directory " + dataDir + ": " + Std.string(e));
		}

		// Structured logging first, so the storage / import / session code paths have a destination.
		Log.init(logDir, logLevel);
		Log.info("server", "starting", { dataDir: dataDir, httpPort: httpPort, wsPort: wsPort, logDir: logDir, level: logLevel });
		// --import-legacy-json is consumed by Db.open (called from AccountStore.init below).
		LegacyImport.force = importLegacyJson;

		// <data-dir>/config.toml (CLI options win; a missing file means code defaults).
		ServerConfig.load(dataDir + "/config.toml");
		var cfgLimits = ServerConfig.limits;
		if (!disableIpLock) disableIpLock = !cfgLimits.ipLock;
		if (ipLockLimit == 0) ipLockLimit = cfgLimits.ipLockLimit;
		if (!disableReconnectGuard) disableReconnectGuard = !cfgLimits.reconnectGuard;
		if (reconnectLimit == 0) reconnectLimit = cfgLimits.reconnectLimit;
		GameRoom.MAX_CLIENTS = cfgLimits.maxClients;
		if (fixtureDir != null) GameRoom.fixtureDir = fixtureDir;

		// SMTP is fully configured only with both host and sender (user/password may be empty = anonymous
		// relay). Without --smtp-* a config.toml without an [smtp] table leaves mail outbox-only:
		// verification codes go to <data-dir>/mail.log and nothing is sent.
		var smtp:SmtpConfig = null;
		if (smtpHost != null && smtpHost != "" && smtpMail != null && smtpMail != "") {
			smtp = { host: smtpHost, port: smtpPort, user: smtpUser, pass: smtpPass, from: smtpMail };
		}
		if (smtp == null && ServerConfig.smtpDefined) smtp = ServerConfig.smtpConfig();

		// Credential TTL (fixed when given on the CLI; otherwise config.toml [auth], default 30 days).
		var authTtl = cliAuthTtl >= 0 ? cliAuthTtl : ServerConfig.authTtlMinutes;
		var authTtlLocked = cliAuthTtl >= 0 ? true : ServerConfig.authTtlLocked;

		// A second boot for the same data directory reuses the open connection: the stores below are
		// re-initialised on top of it and the rows (accounts, scores, ...) stay where they are.
		if (Db.isOpen()) {
			Log.info("db", "re-hosting on the existing SQLite connection", { path: Db.filePath() });
		}

		// Local JSON/SQLite storage for accounts / leaderboard / comments.
		Api.init(dataDir, opts.adminEmail, smtp, ngAppId, discordWebhook, authTtl, authTtlLocked);
		// User ruling D-R3-5: the embedded host has no admin account, so its loopback console gets a
		// GET-only read-only session instead of a login wall nobody could pass. Api.init's signature
		// stays untouched (existing probes call it), the switch lives here.
		Api.setLocalConsoleReadOnly(opts.localConsoleReadOnly);

		// Console: the [permissions] table overrides role access (absent entries keep the code defaults).
		if (ServerConfig.permissionRoles != null) {
			for (key in ServerConfig.ROLE_KEYS) {
				if (!ServerConfig.permissionRoles.exists(key)) continue;
				ServerConfig.setRoleAccess(key, ServerConfig.permissionRoles.get(key));
			}
			AccountStore.reapplyRoleAccess();
		}

		var boot = new ServerBoot();
		boot.host = host;
		boot.dataDir = dataDir;
		boot.httpPort = httpPort;
		boot.wsPort = wsPort;

		// ServerHub's constructor binds the WS listen port, HttpServer's binds HTTP. If the second
		// bind fails the first one is released, so a failed start() leaks no port.
		var hub:ServerHub = null;
		try {
			hub = new ServerHub(host, wsPort, opts.publicHost, disableIpLock, ipLockLimit, disableReconnectGuard, reconnectLimit);
		} catch (e:Dynamic) {
			Log.error("server", "WS bind failed", { host: host, wsPort: wsPort, error: Std.string(e) });
			throw e;
		}

		var http:HttpServer = null;
		try {
			http = new HttpServer(host, httpPort, hub.handleHttp);
		} catch (e:Dynamic) {
			try hub.stop() catch (e2:Dynamic) {}
			Log.error("server", "HTTP bind failed", { host: host, httpPort: httpPort, error: Std.string(e) });
			throw e;
		}
		try {
			http.start();
		} catch (e:Dynamic) {
			try http.stop() catch (e2:Dynamic) {}
			try hub.stop() catch (e2:Dynamic) {}
			Log.error("server", "HTTP accept thread failed", { host: host, httpPort: httpPort, error: Std.string(e) });
			throw e;
		}

		boot.hub = hub;
		boot.http = http;
		boot.running = true;
		instance = boot;

		trace('[server] HTTP http://$host:$httpPort  WS ws://$host:$wsPort');
		// Operator-visible one-liner: where the data lives, what the schema version is and whether the
		// random source is the OS entropy device or the documented HMAC-SHA256 DRBG fallback.
		trace('[db] ' + Db.filePath() + '  schema v' + Db.schemaVersion() + '  journal ' + Db.journalMode()
			+ '  rng ' + (Crypto.osEntropyAvailable ? '/dev/urandom' : 'HMAC-SHA256 DRBG (no OS entropy device; see server/README.md)'));
		Log.info("server", "storage ready", {
			dbPath: Db.filePath(),
			dbSchemaVersion: Db.schemaVersion(),
			dbJournalMode: Db.journalMode(),
			rng: Crypto.osEntropyAvailable ? "os-urandom" : "hmac-sha256-drbg"
		});
		// Console: print the web-console entry on the command line so nobody has to guess it.
		var consoleHost = (host == "" || host == "0.0.0.0" || host == "::") ? "127.0.0.1" : host;
		var lanNote = (consoleHost == host) ? "" : '  (局域网用本机 IP / LAN: use this machine IP)';
		trace('[console] 网页控制台 / Web console: http://$consoleHost:$httpPort/console' + lanNote);
		trace('[auth] 凭据有效期 / credential lifetime: ' + (authTtl <= 0 ? "不过期 / never" : authTtl + ' min')
			+ (authTtlLocked ? '（服务端固定 / pinned by the server）' : '（玩家可自选 / player may choose）'));
		trace('[console] 登录 / Sign in: ' + (opts.adminEmail == null || opts.adminEmail == "" ? "需要 --admin-email / needs --admin-email" : opts.adminEmail)
			+ '   ·   ' + (smtp == null ? '验证码在 ' + dataDir + '/mail.log / codes go to mail.log' : 'SMTP 已配置 / SMTP enabled'));

		return boot;
	}

	/**
	 * Blocking serve loop (HTTP is already served by its own accept thread; this drives the WS hub).
	 * Run it on a background thread: sys.thread.Thread.create(boot.runLoop). Returns after stop().
	 * A second concurrent call is ignored: one hub loop per process.
	 */
	public function runLoop():Void {
		if (!running || loopActive) return;
		loopActive = true;
		try {
			hub.run();
		} catch (e:Dynamic) {
			loopActive = false;
			throw e;
		}
		loopActive = false;
	}

	/**
	 * Bounded wait until the serve loop has returned from hub.run(). sys.thread.Thread has no join()
	 * in Haxe 4.3, so the loop publishes loopActive and the stop/restart path polls it.
	 * Returns false when the loop is still inside the socket loop after the timeout.
	 */
	public function waitForLoopExit(timeoutSeconds:Float):Bool {
		var deadline = Sys.time() + timeoutSeconds;
		while (loopActive && Sys.time() < deadline) {
			Sys.sleep(0.005);
		}
		return !loopActive;
	}

	/**
	 * Releases BOTH listen ports and asks runLoop() to return. Idempotent, and safe to call from a
	 * different thread than runLoop() (the client stops hosting from the game thread). In-flight
	 * HTTP requests finish; they are all Connection: close.
	 *
	 * Before returning it waits (bounded) for the serve loop to leave hub.run(), so a following
	 * start() cannot race the old loop for the sockets.
	 *
	 * The process-wide storage (SQLite connection, stores, config) stays open; see start() for the
	 * Host -> Stop -> Host again rule.
	 */
	public function stop():Void {
		if (stopped) return;
		stopped = true;
		// Flags first, then both listen sockets: closing a listen socket is what frees the port, and
		// each accept loop leaves on its own flag.
		running = false;
		if (http != null) {
			try http.stop() catch (e:Dynamic) Log.warn("server", "HTTP stop failed", { error: Std.string(e) });
		}
		if (hub != null) {
			try hub.stop() catch (e:Dynamic) Log.warn("server", "hub stop failed", { error: Std.string(e) });
		}
		if (!waitForLoopExit(2.0)) {
			Log.warn("server", "serve loop did not leave within the stop budget; canRestart() stays false",
				{ httpPort: httpPort, wsPort: wsPort });
		}
		Log.info("server", "stopped", { host: host, httpPort: httpPort, wsPort: wsPort, dataDir: dataDir });
	}

	public function isRunning():Bool {
		return running;
	}

	/**
	 * True once stop() has completed and the serve loop thread has actually left hub.run(): a
	 * following start() on the same data directory is then safe. False while a boot is running and
	 * false during the short stop window, so the client can poll this instead of guessing.
	 */
	public function canRestart():Bool {
		return stopped && !loopActive;
	}

	/**
	 * The room hub that drives the WS side. Exposed for the host' diagnostics (counters, room list)
	 * and for tests of the stop path; ServerBoot owns its lifecycle.
	 */
	public function serverHub():ServerHub {
		return hub;
	}

	/** True when stop() has already released the listeners (stop() is idempotent either way). */
	public function isStopped():Bool {
		return stopped;
	}

	static function checkPort(name:String, port:Int):Int {
		var value:Null<Int> = port;
		if (value == null || value < 1 || value > 65535) {
			throw new ServerBootError("start: " + name + " must be 1..65535, got " + Std.string(port));
		}
		return value;
	}
}
