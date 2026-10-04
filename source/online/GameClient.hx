package online;

/**
 * Online game-room client (join / reconnect / leave, state-switch hooks).
 * Package paths are remapped (`backend.Song` -> `Song`, `backend.Rating` -> `Conductor.Rating`,
 * `LoadingState` -> `states.LoadingState`). Haxe 4.2.5 has no `??`/safe-navigation, so null
 * checks are explicit; flixel 4.11's `FlxG.switchState` takes a `FlxState`, not a factory.
 */
import io.colyseus.serializer.schema.types.IRef;
import io.colyseus.serializer.schema.Callbacks;
import online.http.HTTPHandler;
import io.colyseus.serializer.schema.Schema;
import backend.NoteSkinData;
import flixel.FlxState;
import online.network.Auth;
import online.network.FunkinNetwork;
import states.OutdatedState;
import haxe.crypto.Md5;
import Song; // declared in the root package
import Conductor.Rating; // declared in source/Conductor.hx:189
import online.backend.schema.Player;
import haxe.Http;
import sys.io.File;
import sys.FileSystem;
import online.states.OnlineState;
import lime.app.Application;
import io.colyseus.events.EventHandler;
import states.MainMenuState;
import online.backend.schema.Room as GameRoom;
import io.colyseus.Client;
import io.colyseus.Room;
import online.util.OnlineLang;
import online.util.ServerList;

typedef Error = #if (colyseus < "0.15.3") io.colyseus.error.MatchMakeError #else io.colyseus.error.HttpException #end;

/**
 * Outcome of probeServer(): reachability, round-trip time and the parsed /api/config body.
 *
 * It is a real class on purpose. As an anonymous typedef hxcpp compiled every access through
 * __Field/__SetField (the local was emitted as ::Dynamic), and the real machine hit
 * "Invalid field:reachable" at runtime while the server list was probing. A class makes all of
 * those accesses plain member offsets, so that whole failure mode is gone.
 */
class ServerProbe {
	public var reachable:Bool = false;
	public var ok:Bool = false;
	public var pingMs:Int = -1;
	public var status:Int = 0;
	public var config:Dynamic = null;

	public function new() {}
}

class GameClient {
    public static var client:Client;
	public static var room(default, set):Room<GameRoom>;
	static function set_room(v) {
		callbacks = v == null ? null : Callbacks.get(v);
		return room = v; 
	}
	public static var callbacks(default, null):SchemaCallbacks<GameRoom>;
	public static var isOwner(get, never):Bool;
	public static var address:String;
	public static var reconnecting:Bool = false;
	public static var rpcClientRoomID:String;

	/**
	 * the game server address that the player set, if the player has set nothing then it returns `serverAddresses[0]`
	 */
	public static var serverAddress(get, set):String;

	/**
	 * the network server address that the player set, if the player has set nothing then it returns `serverAddresses[0]`
	 */
	public static var networkServerAddress(get, set):String;

	/**
	 * server list retrieved from github every launch
	 */
	@:unreflective
	public static var serverAddresses(default, null):Array<String> = [];

	public static function createRoom(address:String, ?onJoin:(err:Dynamic)->Void) {
		// onJoin doubles as the abort callback: a refused handshake must reach the caller or its
		// "waiting" flag (OnlineState.disableInput) never clears.
		verifyServer(address, () -> createRoomVerified(address, onJoin), onJoin);
	}

	private static function createRoomVerified(address:String, ?onJoin:(err:Dynamic)->Void) {
		LoadingScreen.toggle(true);

		leaveRoom('Switching Rooms.');
		ChatBox.clearLogs();
		
		Thread.run(() -> {
			client = new Client(address);
			_pendingMessages = [];

			client.create("room", getOptions(true, address), GameRoom, (err, room) -> _onJoin(err, room, true, address, onJoin));
		}, (exc) -> {
			onJoin(exc);
			LoadingScreen.toggle(false);
			trace(exc.details());
			Alert.alert(OnlineLang.L('net.connectFailed', 'Failed to connect!'), exc.details());
		});
    }

	public static function joinRoom(roomSecret:String, ?onJoin:(err:Dynamic)->Void) {
		var roomID = roomSecret.trim();
		var roomAddress = GameClient.serverAddress;
		var coolIndex = roomSecret.indexOf(";");
		if (coolIndex != -1) {
			roomID = roomSecret.substring(0, coolIndex).trim();
			roomAddress = roomSecret.substring(coolIndex + 1).trim();
		}

		verifyServer(roomAddress, () -> joinRoomVerified(roomID, roomAddress, onJoin), onJoin);
	}

	private static function joinRoomVerified(roomID:String, roomAddress:String, ?onJoin:(err:Dynamic)->Void) {
		LoadingScreen.toggle(true);

		leaveRoom('Switching Rooms.');
		ChatBox.clearLogs();

		Thread.run(() -> {
			client = new Client(roomAddress);
			_pendingMessages = [];

			client.joinById(roomID, getOptions(false, roomAddress), GameRoom, (err, room) -> _onJoin(err, room, false, roomAddress, onJoin));
		}, (exc) -> {
			onJoin(exc);
			LoadingScreen.toggle(false);
			trace(exc.details());
			Alert.alert(OnlineLang.L('net.connectFailed', 'Failed to connect!'), exc.toString());
		});
    }

	private static function _onJoin(err:Error, room:Room<GameRoom>, isHost:Bool, address:String, ?onJoin:(err:Dynamic)->Void) {
		if (err != null) {
			trace(err.code + " - " + err.message);
			Alert.alert(OnlineLang.L('net.connectFailedShort', "Couldn't connect!"), "JOIN ERROR: " + ShitUtil.prettyStatus(err.code) + "\n" + ShitUtil.readableError(err.message));
			onJoin(err);
			leaveRoom();
			LoadingScreen.toggle(false);
			if (err.code == 5003)
				Waiter.putPersist(() -> {
					// flixel 4.11: switchState takes a state, not a factory.
					FlxG.switchState(new OutdatedState());
				});
			else if (err.code == 5007)
				// The server said we are not speaking its handshake (a foreign server that
				// happens to answer like ours, or a hand-forged attach).
				Waiter.putPersist(() -> Alert.alert(
					OnlineLang.L('net.notSeiunServer', 'This is not a SeiunEngine server'),
					OnlineLang.L('net.notSeiunServer.desc', 'The server did not accept the SeiunEngine handshake. Nothing was joined.')));
			return;
		}
		LoadingScreen.toggle(false);

		GameClient.room = room;
		GameClient.address = address;
		GameClient.rpcClientRoomID = Md5.encode(FlxG.random.int(0, 1000000).hex());
		clearOnMessage();
		reconnecting = false;

		#if ONLINE_ALLOWED
		// Reconnection has a single owner; see disableLibraryAutoReconnect().
		disableLibraryAutoReconnect(room);
		#end

		// `Room.connect()` points `connection.onMessage` at `Room.onMessageCallback`, and the
		// websocket thread (`_online_libs/io/colyseus/Connection.hx:75`) has no try/catch: a
		// decode exception reaches `hxThreadFunc` with no global uncaught handler and kills the
		// process (0xE06D7363). Wrap it on the engine side; a bad packet only logs.
		try
		{
			var gameConn = GameClient.room.connection;
			if (gameConn != null)
			{
				var innerOnMessage = gameConn.onMessage;
				gameConn.onMessage = function(bytes) {
					try
					{
						if (innerOnMessage != null)
							innerOnMessage(bytes);
					}
					catch (e:Dynamic)
					{
						var msg:String = Std.string(e);
						Waiter.putPersist(() -> trace('Room.onMessage failed (bad packet?): ' + msg));
					}
				};
			}
		}
		catch (exc) {}

		// These handlers are dispatched synchronously on the websocket background thread
		// (`Connection.hx:75` -> `ws.process()` -> `onclose` -> `Room.onClose`), so they used to
		// write GameClient's static fields off-thread; under hxcpp's generational GC
		// (Project.xml:229) a missed write barrier can free a live object and crash natively.
		// Marshal them back to the main thread.
		GameClient.room.onError += (code:Int, e:String) -> {
			Waiter.putPersist(() -> {
				Sys.println("Room.onError: " + code + " - " + e);
				if (code == 524)
					return;
				Alert.alert(OnlineLang.L('net.roomError', 'Room error!'), "room.onError: " + ShitUtil.prettyStatus(code) + "\n" + ShitUtil.readableError(e));
			});
		}

		GameClient.room.onLeave += (code) -> {
			Waiter.putPersist(() -> {
				trace(code);
				// Haxe 4.2.5 has no safe-navigation; the null check is explicit.
				if (room == null ? false : room.roomId != null)
					trace("Left/Kicked from room: " + room.roomId);
				else
					trace("Left/Kicked from unknown room!");

				if (client == null) {
					leaveRoom();
				}
				else {
					reconnect();
				}
			});
		}

		Waiter.putPersist(() -> {
			var tries = 50;
			// great stuff colyseus
			while (getPlayerSelf() == null) {
				trace(getPlayerSelf() == null);
				if (tries-- < 0) {
					Alert.alert(OnlineLang.L('net.connectFailedShort', "Couldn't connect!"), OnlineLang.L('net.noStateData', "Client couldn't receive server's state data!"));
					onJoin(new Error(-1, 'no state data'));
					leaveRoom();
					LoadingScreen.toggle(false);
					return;
				}
				Sys.sleep(0.2);
			}

			trace("Joined!");

			FlxG.autoPause = false;

			if (onJoin != null)
				onJoin(null);
		});

		//maybe just make it global
		//if (address.contains(".onrender.com")) {
		//	trace("onrender server detected");
		Waiter.pingServer = address;
		//}
	}

	public static function reconnect(?debugReconnectDelay:Float = 0) {
		if (reconnecting)
			return;
		reconnecting = true;

		if (room == null) {
			leaveRoom('Room Disposed?');
			return;
		}

		var reconnectToken = room.reconnectionToken;

		trace("Reconnecting with Token: " + reconnectToken);
		Alert.alert(OnlineLang.L('net.reconnecting', 'Reconnecting...'));

		#if ONLINE_ALLOWED
		// The old Room may have library reconnection queued; clear its retry budget first.
		disableLibraryAutoReconnect(GameClient.room);
		#end

		try {
			GameClient.room.teardown();
			GameClient.room.leave(false);
		}
		catch (exc) {}

		Thread.run(() -> {
			if (debugReconnectDelay > 0)
				Sys.sleep(debugReconnectDelay);
			if (client == null)
				return;
			client.reconnect(reconnectToken, GameRoom, (err, newRoom:Room<GameRoom>) -> {
				try {
					if (reconnectToken != room.reconnectionToken) {
						reconnecting = false;
						return;
					}

					if (err != null) {
						trace(err.code + " - " + err.message);
						Waiter.putPersist(() -> {
							Alert.alert(OnlineLang.L('net.reconnectFailed', "Couldn't reconnect!"), "RECONNECT ERROR: " + ShitUtil.prettyStatus(err.code) + " - " + ShitUtil.readableError(err.message));
						});
						leaveRoom();
						return;
					}

					newRoom.onStateChange += _ -> {
						newRoom.onStateChange = new EventHandler<Dynamic->Void>();

						_onJoin(err, newRoom, GameClient.isOwner, GameClient.address);
						if (addListeners != null)
							addListeners();
						sendPending();
						Waiter.putPersist(() -> {
							Alert.alert(OnlineLang.L('net.reconnected', 'Reconnected!'));
						});
					};
				}
				catch (exc) {
					Waiter.putPersist(() -> {
						Alert.alert(OnlineLang.L('net.reconnectCritical', 'Critically failed to reconnect!'), "RECONNECT ERROR: " + ShitUtil.prettyStatus(err.code) + " - " + ShitUtil.readableError(err.message));
					});
					leaveRoom();
				}
			});
		});
	}

	#if ONLINE_ALLOWED
	/**
	 * Single-owner reconnection: GameClient.reconnect() (HTTP matchmaking), library auto-reconnect
	 * stopped. An empty Close frame becomes 1005, which the library treats as reconnectable
	 * (Room.hx:113-121) while HTTP reconnects the same session, so the two fight. teardown() only
	 * clears the serializer (Room.hx:225-235); zeroing the retry budget yields
	 * onLeave(FAILED_TO_RECONNECT) (Room.hx:394-399) instead.
	 */
	static function disableLibraryAutoReconnect(r:Room<GameRoom>):Void {
		if (r == null)
			return;

		r.reconnection.maxRetries = 0;
		r.reconnection.isReconnecting = false;
		r.reconnection.retryCount = 0;
	}
	#end

	@:unreflective
	static function getOptions(asHost:Bool, reqAddress:String):Map<String, Dynamic> {
		var options:Map<String, Dynamic> = [
			"name" => ClientPrefs.getNickname(), 
			"protocol" => Main.CLIENT_PROTOCOL,
			// The server refuses anything that does not present our magic + version.
			"engine" => Protocol.MAGIC,
			"points" => FunkinPoints.funkinPoints,
			"arrowRGB" => ClientPrefs.getArrowRGBCompleteMaps(),
			"gameplaySettings" => ClientPrefs.data.gameplaySettings
		];

		// A LAN host is account-free: the embedded server keeps accounts in its own local DB, so
		// the player's global networkId/token are never sent to it while hosting.
		if (lanLocalOverride == null && reqAddress == networkServerAddress && Auth.authID != null && Auth.authToken != null) {
			options.set("networkId", Auth.authID);
			options.set("networkToken", Auth.authToken);
		}

		if (ClientPrefs.data.currentSkin != null) {
			options.set("skin", ClientPrefs.data.currentSkin);
			options.set("skinURL", OnlineMods.getModURL(ClientPrefs.data.currentSkin[3]));
		}

		var data:NoteSkinStructure = NoteSkinData.getCurrent(-1);
#if ONLINE_ALLOWED
		// Hard guard: getCurrent() returns null when noteSkins was never reloaded
		// (TitleState now calls reloadNoteSkins()), so a null entry cannot become a
		// native null dereference here.
		options.set('noteSkin', data != null ? data.skin : "Default");
		options.set('noteSkinMod', data != null ? data.folder : "");
		options.set('noteSkinURL', data != null ? data.url : null);
#end

		return options;
	}

	/**
	 * Release builds show no `trace()` output, so append the leave path to
	 * `logs/online_leave_trace.log` to tell whether `leaveRoom` ran and whether
	 * `leaveRoomCleanup` was blocked by flixel 4.11's `_state == _requestedState`.
	 */
	public static function leaveTrace(msg:String):Void {
		try {
			if (!sys.FileSystem.exists('logs'))
				sys.FileSystem.createDirectory('logs');
			var out = sys.io.File.append('logs/online_leave_trace.log', false);
			out.writeString(haxe.Timer.stamp() + ' | ' + msg + '\n');
			out.close();
		} catch (e:Dynamic) {}
	}

	public static function leaveRoom(?reason:String = null, forceStateChange:Bool = false) {
		leaveTrace('leaveRoom reason=' + reason + ' force=' + forceStateChange
			+ ' connected=' + isConnected() + ' room=' + (room != null) + ' client=' + (client != null));
		Waiter.pingServer = null;
		reconnecting = false;
		_pendingMessages = [];

		if (!isConnected()) {
			// A disconnected client returns early here: a player holding BACK to leave
			// (online/objects/LeavePie.hx) would otherwise get no feedback and no state change,
			// and LeavePie's `finished` is already set so a second press does nothing.
			// `forceStateChange` is only passed by LeavePie; createRoom/joinRoom swap the room silently.
			if (forceStateChange)
				Waiter.putPersist(() -> leaveRoomCleanup(reason));
			return;
		}

		GameClient.client = null;

		Waiter.putPersist(() -> leaveRoomCleanup(reason));
	}

	/**
	 * Actual teardown of `leaveRoom`. It lives outside the `Waiter.putPersist` closure so the
	 * "connected" and "disconnected but player asked to leave" paths share one teardown,
	 * instead of duplicating it in both.
	 */
	static function leaveRoomCleanup(?reason:String):Void {
		var canSwitch:Bool = @:privateAccess FlxG.game._state == @:privateAccess FlxG.game._requestedState;
		leaveTrace('leaveRoomCleanup reason=' + reason + ' canSwitch=' + canSwitch + ' room=' + (room != null));
		if (reason != null)
			Alert.alert(OnlineLang.L('net.disconnected', 'Disconnected!'), reason.trim() != "" ? reason : null);
		trace("Leaving the Room, Reason: " + reason);

		// Match ClientPrefs.hx:885 / OptionsState.hx:1501: `runInBackground` implies autoPause off.
		// Reading only data.autoPause made users with background running fall back to
		// "pause on focus loss" as soon as they left a room.
		FlxG.autoPause = ClientPrefs.data.runInBackground ? false : ClientPrefs.data.autoPause;

		// A state switch is queued when `FlxG.game._state != FlxG.game._requestedState`. Flixel
		// 4.11 has no `_nextState` and never clears `_requestedState` (`FlxGame.hx:270`;
		// transition test at `FlxGame.hx:844`), so the equivalent check is `_state == _requestedState`
		// -- true when nothing is pending: do not queue a second switch.
		if (@:privateAccess FlxG.game._state == @:privateAccess FlxG.game._requestedState) {
			// flixel 4.11: switchState takes a state, not a factory.
			FlxG.switchState(new OnlineState());
		}
		FlxG.sound.play(Paths.sound('cancelMenu'));
		states.TitleState.playFreakyMusic();

		try {
			// Haxe 4.2.5 has no safe-navigation; the null checks are explicit.
			if (GameClient.room != null && GameClient.room.connection != null) {
				GameClient.room.teardown();
				GameClient.room.leave(true);
			}
		}
		catch (exc) {}

		GameClient.room = null;
		GameClient.address = null;
		GameClient.rpcClientRoomID = null;

		//Downloader.cancelAll();
	}

    public static function isConnected() {
		return client != null || reconnecting;
    }

	public static function initStateListeners(state:FlxState, listenersCallback:Void->Void) {
		ensureStateSwitchHook();
		addListenersState = state;
		addListeners = listenersCallback;
	}
	private static var addListenersState:FlxState;
	private static var addListeners(default, null):Void->Void;

	private static var hasStateCallback:Bool = false;

	/**
	 * Clear `Waiter.stateQueue` on the `preStateSwitch` hook.
	 *
	 * Crash path: `Waiter.update -> _processQueue -> _tryQueueCall` ran a PlayState onMessage
	 * closure while `FlxG.state` was already `states.FreeplayState` -- native ACCESS_VIOLATION.
	 * Only `clearOnMessage()` used to clear the queue, and that runs once in `createRoom()`.
	 */
	static function ensureStateSwitchHook():Void {
		if (hasStateCallback)
			return;

		hasStateCallback = true;

		FlxG.signals.preStateSwitch.add(() -> {
			Waiter.clearStateQueue();
			// Clearing Waiter.stateQueue is not enough: closures left in
			// `room.onMessageHandlers` still queue work into the new state after the switch.
			// A leaving state's handlers must be disposed with it.
			disposeStateHandlers(FlxG.state);
		});

		FlxG.signals.postStateSwitch.add(() -> {
			if (addListenersState != FlxG.state)
				addListeners = null;
		});
	}

	// ------------------------------------------------------------------
	// ------------------------------------------------------------------
	// State-level handler registration and disposal
	// ------------------------------------------------------------------
	/**
	 * Invariant: room-level handlers (ping / gameStarted / alert / requestSkin / checkChart /
	 * isPrivate) live with the room, while state-level handlers (PlayState / RoomState onMessage
	 * and schema callbacks) must die with their state via a registered disposer.
	 *
	 * `room.onMessageHandlers` closures outlive a state switch, so a later websocket message can
	 * queue a closure into the new state and hit a destroyed object -> ACCESS_VIOLATION.
	 */
	private static var stateDisposers:Map<FlxState, Array<Void->Void>> = new Map();

	static function addStateDisposer(state:FlxState, dispose:Void->Void):Void {
		var list = stateDisposers.get(state);
		if (list == null) {
			list = [];
			stateDisposers.set(state, list);
		}
		list.push(dispose);
	}

	/**
	 * Register a state-level `room.onMessage`. It is removed when `state` is destroyed; if `key`
	 * already had a handler (e.g. the room-level `checkChart`, or a previous state's `charPlay`),
	 * unregistering restores that handler instead of leaving a hole.
	 */
	@:access(io.colyseus.Room.onMessageHandlers)
	public static function registerStateMessage(state:FlxState, key:String, fn:Dynamic->Void):Void {
		if (state == null || fn == null)
			return;

		var r = GameClient.room;
		if (r == null || r.onMessageHandlers == null)
			return;

		var previous = r.onMessageHandlers.get(key);
		r.onMessageHandlers.set(key, fn);

		addStateDisposer(state, () -> {
			if (r.onMessageHandlers == null)
				return;
			if (r.onMessageHandlers.get(key) != fn)
				return; // already overwritten by a later registration; do not remove that one
			if (previous != null)
				r.onMessageHandlers.set(key, previous);
			else
				r.onMessageHandlers.remove(key);
		});
	}

	/** Register a state-level disposer (returned by SchemaCallbacks.listen/onAdd/onRemove/onChange). */
	public static function registerStateDisposer(state:FlxState, dispose:Void->Void):Void {
		if (state == null || dispose == null)
			return;
		addStateDisposer(state, dispose);
	}

	/** Run and clear all disposers registered for a state. Idempotent. */
	public static function disposeStateHandlers(state:FlxState):Void {
		if (state == null)
			return;

		var list = stateDisposers.get(state);
		if (list == null)
			return;

		stateDisposers.remove(state);
		for (d in list) {
			try {
				d();
			} catch (e:Dynamic) {}
		}
	}

	@:access(io.colyseus.Room.onMessageHandlers)
	public static function clearOnMessage() {
		// clear waiter queue to avoid tasks that want to access stuff from the previous state
		// and then lead to a crash
		Waiter.clearStateQueue();

		// Haxe 4.2.5 has no safe-navigation; the null checks are explicit.
		if (!GameClient.isConnected() || GameClient.room == null || GameClient.room.onMessageHandlers == null)
			return;

		ensureStateSwitchHook();

		GameClient.room.onMessageHandlers.clear();

		for (sid => player in GameClient.room.state.players) {
			if (player == null)
				continue;

			clearCallbacks(player);
			// clearCallbacks(player.arrowColors);
			// clearCallbacks(player.arrowColorsPixel);
		}
		clearCallbacks(GameClient.room.state);
		// clearCallbacks(GameClient.room.state, "diffList");
		// clearCallbacks(GameClient.room.state, "gameplaySettings");
		
		ChatBox.tryRegisterLogs();

		GameClient.room.onMessage("ping", function(message) {
			GameClient.send("pong");
		});

		GameClient.room.onMessage("gameStarted", function(message) {
			Waiter.putPersist(() -> {
				if (GameClient.room == null || GameClient.room.state == null)
					return;

				// Do not loadSong("", "") when no song is selected.
				var song:String = GameClient.room.state.song;
				if (song == null || song.trim() == "") {
					Alert.alert(OnlineLang.L('room.noSong', "Song isn't selected!"));
					return;
				}

				FlxG.mouse.visible = false;

				// Switch the asset directory only when this mod is actually installed locally.
				var modDir:String = GameClient.room.state.modDir;
				if (modDir != null && modDir != "" && Mods.getModDirectories().contains(modDir))
					Mods.currentModDirectory = modDir;
				else
					Mods.currentModDirectory = "";

				Difficulty.list = CoolUtil.asta(GameClient.room.state.diffList);
				PlayState.storyDifficulty = GameClient.room.state.diff;
				PlayState.loadSong(song, GameClient.room.state.folder);
				PlayState.isStoryMode = false;
				// This engine's LoadingState lives in `states/`.
				states.LoadingState.loadAndSwitchState(new PlayState());

				FlxG.sound.music.volume = 0;

				#if (MODS_ALLOWED && DISCORD_ALLOWED)
				DiscordClient.loadModRPC();
				#end
			});
		});

		GameClient.room.onMessage("alert", function(message:Dynamic) {
			if (message == null)
				return;

			switch (Type.typeof(message)) {
				case Type.ValueType.TClass(String):
					Alert.alert(cast message);

				case Type.ValueType.TClass(Array):
					var arrMsg:Array<Dynamic> = cast message;
					if (arrMsg.length >= 2)
						Alert.alert(arrMsg[0], arrMsg[1]);

				default:
			}
		});

		GameClient.room.onMessage("requestSkin", function(?msg:Dynamic) {
			Waiter.putPersist(() -> {
				if (ClientPrefs.data.currentSkin != null) {
					GameClient.send("setSkin", [
						ClientPrefs.data.currentSkin,
						OnlineMods.getModURL(ClientPrefs.data.currentSkin[3])
					]);
				}
				else {
					GameClient.send("setSkin", null);
				}
			});
		});

		GameClient.room.onMessage("checkChart", function(message) {
			Waiter.putPersist(() -> {
				var chartSong:String = GameClient.room.state.song;
				var chartFolder:String = GameClient.room.state.folder;
				var chartModDir:String = GameClient.room.state.modDir;

				// A segmented chart has no one-file chart to hash: refuse it loudly instead of
				// letting hashRawSong throw and leaving the room waiting for hasSong forever.
				if (GameClient.chartIsSegmented(chartSong, chartFolder, chartModDir)) {
					GameClient.refuseSegmentedChart();
					return;
				}

				try {
					var hash = Song.hashRawSong(chartSong, chartFolder);
					trace("verifying song: " + chartSong + " | " + chartFolder + " : " + hash);
					GameClient.send("verifyChart", hash);
					states.FreeplayState.destroyFreeplayVocals();
					// flixel 4.11: switchState takes a state, not a factory.
					FlxG.switchState(new RoomState());
					// Match leaveRoomCleanup: respect the "run in background" setting.
					FlxG.autoPause = ClientPrefs.data.runInBackground ? false : ClientPrefs.data.autoPause;
				}
				catch (exc:Dynamic) {
					// The room cannot start without this client's hasSong, so the failure must not be
					// swallowed: the local player gets the alert, the room gets the status line.
					Sys.println(exc);
					GameClient.refuseUnhashableChart(exc);
				}
			});
		});

		#if DISCORD_ALLOWED
		GameClient.callbacks.listen("isPrivate", (value, prev) -> {
			DiscordClient.updateOnlinePresence();
		});
		#end
	}

	public static function clearCallbacks(irefSchema:IRef, ?fieldNameOrOperation:String) @:privateAccess {
		if (irefSchema == null)
			return;

		final refId = irefSchema.__refId;

		// if specific field wasn't provided the whole schema gets purged
		if (fieldNameOrOperation == null) {
			callbacks.decoder.refs.callbacks.set(refId, new Map<String, Array<Dynamic>>());

			for (field in Reflect.fields(irefSchema)) {
				final childIRef = Reflect.field(irefSchema, field);
				if (childIRef is IRef)
					clearCallbacks(childIRef);
			}

			return;
		}

		// remove child fields that have their own IRefs???
		if (Std.isOfType(fieldNameOrOperation, String) && Reflect.hasField(irefSchema, fieldNameOrOperation)) {
			final childIRef = Reflect.field(irefSchema, fieldNameOrOperation);
			if (childIRef is IRef)
				clearCallbacks(childIRef);
		}

		final key = (Std.isOfType(fieldNameOrOperation, String))
            ? fieldNameOrOperation
            : "#" + fieldNameOrOperation;

		callbacks.decoder.refs.callbacks.get(refId).remove(key);
	}

	private static var _pendingMessages:Array<Array<Dynamic>> = [];
	public static function sendPending() {
		if (_pendingMessages.length == 0)
			return;

		Sys.println('resending ' + _pendingMessages.length + " packets");
		while (_pendingMessages.length > 0) {
			var msg = _pendingMessages.shift();
			GameClient.send(msg[0], msg[1]);
		}
	}

	public static function send(type:Dynamic, ?message:Null<Dynamic>) {
		if (GameClient.isConnected() && type != null)
			Waiter.putPersist(() -> {
				try {
					room.send(type, message);
				}
				catch (exc) {
					_pendingMessages.push([type, message]);

					if (!reconnecting) {
						trace(exc + " : FAILED TO SEND: " + type + " -> " + message);
						reconnect();
					}
				}
			});
	}

	static function get_isOwner() {
		if (GameClient.room == null || GameClient.room.state == null)
			return false;
		return GameClient.room.state.host == GameClient.room.sessionId;
	}

	public static function hasPerms() {
		if (!GameClient.isConnected())
			return false;

		return GameClient.isOwner || GameClient.room.state.anarchyMode;
	}

	/**
	 * Whether a play of `song` would load a segmented (ChartParts) chart.
	 *
	 * The online slice only promises one-file charts: the host hashes the chart text
	 * (`Song.hashRawSong`) and the server verifies that hash, which a chart merged from part files
	 * has no single file for. `Song.loadRawSong()` throws `Missing file:` for such a chart, so the
	 * online paths must refuse it *before* the hash -- otherwise `verifyChart` is never sent and the
	 * room waits for `hasSong` forever.
	 *
	 * The detection itself is `ChartParts.resolveForChart()`, the same call `Song` loads by and the
	 * one `FreeplayState.songHasSegmentedChart()` makes. MODE_AUTO is deliberate: the question is
	 * "does this chart have parts on disk", not "did the player choose to merge them" -- the parts
	 * are what a play uses, whatever the saved preference says.
	 *
	 * `song` is the chart key and `folder` the song folder, exactly as `Song.loadRawSong(song,
	 * folder)` receives them. `modDir` is the song's mod directory when it is not the active one
	 * (the room remembers it); null falls back to `Paths.currentModDirectory`.
	 */
	public static function chartIsSegmented(song:String, ?folder:String, ?modDir:String):Bool
	{
		#if sys
		if (song == null || song.length == 0) return false;

		var formattedFolder:String = Paths.formatToSongPath(folder == null ? song : folder);
		var formattedSong:String = Paths.formatToSongPath(song);
		// "" from the room means "this song has no mod dir": do not fall back to whatever
		// mod happens to be active, which would probe an unrelated folder.
		var mod:String = (modDir != null) ? modDir : Paths.currentModDirectory;

		var dirs:Array<String> = [];
		#if MODS_ALLOWED
		if (mod != null && mod.length > 0)
			dirs.push(Paths.mods(mod + '/data/' + formattedFolder));
		dirs.push(Paths.mods('data/' + formattedFolder));
		#end
		dirs.push(Paths.getPreloadPath('data/' + formattedFolder));

		for (dir in dirs)
			if (ChartParts.resolveForChart(dir, formattedFolder, formattedSong, ChartParts.MODE_AUTO) != null)
				return true;
		#end
		return false;
	}

	/**
	 * Player-facing refusal for a segmented (ChartParts) chart on an online path.
	 *
	 * Shared by every `verifyChart` / `setSong` site so the reason reads the same wherever the
	 * player meets it, and mirrored into the room-wide `status` field (an existing protocol
	 * message, so the wire format is unchanged) so the host can see why this player's `hasSong`
	 * stays false instead of waiting for a room that can never start.
	 */
	public static function refuseSegmentedChart():Void
	{
		Alert.alert(
			OnlineLang.L('room.chartSegmented', 'Segmented chart: unsupported online\n分段谱面：联机不支持'),
			OnlineLang.L('room.chartSegmented.desc',
				'Online play only supports one-file charts (data/<song>/<song>.json).\n'
				+ 'This chart is split into several part files, so its hash cannot be verified and the room cannot start.\n'
				+ '联机只支持单文件谱面（data/<歌曲>/<歌曲>.json）。本谱面被拆分为多个分段文件，无法校验谱面哈希，房间无法开局。'));
		if (GameClient.isConnected())
			GameClient.send("status", "Segmented chart (unsupported online)");
	}

	/**
	 * Player-facing refusal for a chart that exists but could not be hashed (unreadable file,
	 * missing chart). Same contract as refuseSegmentedChart(): a failure is never silent, because
	 * the room cannot start without this client's `hasSong`.
	 */
	public static function refuseUnhashableChart(exc:Dynamic):Void
	{
		Alert.alert(
			OnlineLang.L('room.chartHashFailed', 'Chart hash failed\n谱面哈希失败'),
			ShitUtil.readableError(exc));
		if (GameClient.isConnected())
			GameClient.send("status", "Chart hash failed");
	}

	/**
	 * Runtime-only override of the server address used while this process hosts a LAN server
	 * (design temp/lan-host-recon/design.md 2.6). While set it wins over ServerList/ClientPrefs
	 * in BOTH address getters, so the game room and the social/network room talk to the local
	 * server - one server, never two (user ruling: the embedded host IS the server).
	 *
	 * It is deliberately NOT persisted: setLanLocalOverride() must never touch
	 * ClientPrefs.saveSettings() / ServerList, so the player's saved server selection survives
	 * hosting untouched.
	 */
	@:unreflective
	public static var lanLocalOverride:String = null;

	/**
	 * Runtime-only address a copied room code advertises while hosting (the host's LAN IPv4).
	 * getRoomSecret() uses it so a friend can paste "ROOMID;ws://192.168.x.y:port" straight into
	 * JOIN, instead of the loopback address the host itself connects to.
	 */
	@:unreflective
	public static var lanShareAddress:String = null;

	/**
	 * Set (or clear) the local-hosting override and re-point the derived clients exactly like
	 * set_networkServerAddress() does (see below) - minus every ClientPrefs and ServerList write.
	 * Clearing restores the player's selected network server.
	 */
	public static function setLanLocalOverride(address:String):Void {
		var next:String = (address == null || address.trim() == '') ? null : address.trim();
		if (next == lanLocalOverride)
			return;

		lanLocalOverride = next;

		var social = get_networkServerAddress();
		FunkinNetwork.client = new online.http.HTTPHandler(GameClient.addressToUrl(social));
		if (NetworkClient.room != null) {
			NetworkClient.room.leave();
			NetworkClient.room = null;
			NetworkClient.connecting = false;
			NetworkClient.connect();
		}
	}

	static function get_serverAddress():String {
		// While hosting, the local embedded server is the server for every online feature.
		if (lanLocalOverride != null && lanLocalOverride != '')
			return lanLocalOverride;

		// The selected ServerList entry wins; the legacy single-address fields stay as a mirror
		// so older saves keep working.
		var fromList = ServerList.selectedAddress();
		if (fromList != null && fromList != "")
			return fromList;
		if (ClientPrefs.data.serverAddress != null) {
			return ClientPrefs.data.serverAddress;
		}
		return getDefaultServer();
	}

	static function set_serverAddress(v:String):String {
		if (v != null)
			v = v.trim();
		if (v == "" || v == "null")
			v = ServerList.DEFAULT_ADDRESS;

		ServerList.setSelectedAddress(v);
		ClientPrefs.data.serverAddress = v;
		ClientPrefs.saveSettings();
		return serverAddress;
	}

	static function get_networkServerAddress():String {
		// Same override as get_serverAddress(): hosting must not leave the social/chat room
		// connected to the player's remote server (user ruling: everything local, like MC).
		if (lanLocalOverride != null && lanLocalOverride != '')
			return lanLocalOverride;

		var fromList = ServerList.selectedNetworkAddress();
		if (fromList != null && fromList != "")
			return fromList;
		if (ClientPrefs.data.networkServerAddress != null) {
			return ClientPrefs.data.networkServerAddress;
		}
		return getDefaultServer();
	}

	static function set_networkServerAddress(v:String):String {
		if (v != null)
			v = v.trim();
		if (v == "" || v == "null")
			v = ServerList.DEFAULT_ADDRESS;

		ServerList.setSelectedAddress(ServerList.selectedAddress(), v);
		ClientPrefs.data.networkServerAddress = v;
		ClientPrefs.saveSettings();
		FunkinNetwork.client = new online.http.HTTPHandler(GameClient.addressToUrl(v));
		if (NetworkClient.room != null) {
			NetworkClient.room.leave();
			NetworkClient.room = null;
			NetworkClient.connecting = false;
			NetworkClient.connect();
		}
		return serverAddress;
	}

	/**
	 * Re-point the derived state (ClientPrefs mirrors, HTTP handler, social room) at the entry
	 * ServerList has selected. Called after the player picks / adds / removes a server.
	 */
	public static function applySelectedServer():Void {
		var rooms = ServerList.selectedAddress();
		ClientPrefs.data.serverAddress = rooms;
		var social = ServerList.selectedNetworkAddress();
		ClientPrefs.data.networkServerAddress = social;
		ClientPrefs.saveSettings();

		// Credentials are per entry now, so the active id/token follow the selection too.
		Auth.onServerChanged();

		FunkinNetwork.client = new online.http.HTTPHandler(GameClient.addressToUrl(social));
		if (NetworkClient.room != null) {
			NetworkClient.room.leave();
			NetworkClient.room = null;
			NetworkClient.connecting = false;
			NetworkClient.connect();
		}
	}

	/**
	 * Async reachability / latency / config probe for one address, run through the engine's HTTP
	 * client on a worker thread (haxe.Http natively crashes on its failure paths) and returned
	 * through Waiter.
	 */
	/** Addresses that already answered our own handshake in this session. */
	static var verifiedServers:Map<String, Bool> = new Map();

	/**
	 * Confirm the peer speaks this engine's handshake before entering a room. `GET /api/config`
	 * returns `engine` + `protocol`; missing fields, a version mismatch, or a different colyseus
	 * server (PsychOnline's /api/config is 404) pop an alert and refuse to join, instead of
	 * silently connecting to a PsychOnline server.
	 */
	public static function verifyServer(address:String, proceed:Void->Void, ?onAbort:(err:Dynamic)->Void):Void {
		if (address == null || address == '') {
			proceed();
			return;
		}
		if (verifiedServers.exists(address)) {
			proceed();
			return;
		}

		LoadingScreen.toggle(true);
		probeServer(address, (result) -> {
			LoadingScreen.toggle(false);

			var config:Dynamic = result != null ? result.config : null;
			var engine:Dynamic = (config != null && Reflect.hasField(config, 'engine')) ? config.engine : null;
			var protocol:Dynamic = (config != null && Reflect.hasField(config, 'protocol')) ? config.protocol : null;

			if (result != null && result.ok && engine != null && Std.string(engine) == Protocol.MAGIC) {
				if (protocol != null && Std.parseFloat(Std.string(protocol)) == Main.CLIENT_PROTOCOL) {
					verifiedServers.set(address, true);
					proceed();
					return;
				}
				refuseServer(
					OnlineLang.L('net.engineMismatch', 'This server runs a different SeiunEngine version'),
					OnlineLang.L('net.engineMismatch.desc', 'Update the game (or the server) and try again.'),
					onAbort);
				return;
			}

			// A reachable colyseus server with no /api/config is what PsychOnline (and any other
			// colyseus deployment) looks like from here.
			if (result != null && result.reachable && result.status == 404)
				refuseServer(
					OnlineLang.L('net.psychOnlineServer', 'This is a PsychOnline server'),
					OnlineLang.L('net.psychOnlineServer.desc', 'This engine no longer speaks the PsychOnline protocol. Pick a SeiunEngine server in the server list.'),
					onAbort);
			else
				refuseServer(
					OnlineLang.L('net.notSeiunServer', 'This is not a SeiunEngine server'),
					OnlineLang.L('net.notSeiunServer.desc', 'The server did not answer the SeiunEngine handshake. Nothing was joined.'),
					onAbort);
		});
	}

	/**
	 * Refuse to enter a room, with a reason the player can act on.
	 *
	 * The caller's join callback *must* still run: callers set a "waiting" flag before calling
	 * createRoom/joinRoom and clear it only from that callback (OnlineState.disableInput), so a
	 * silent refusal used to freeze the menu.
	 */
	static function refuseServer(title:String, message:String, ?onAbort:(err:Dynamic)->Void):Void {
		LoadingScreen.toggle(false);
		Alert.alert(title, message);
		if (onAbort != null) {
			try {
				onAbort({ code: 5007, message: "Not a SeiunEngine server/client handshake" });
			} catch (e:Dynamic) {
				trace('[verify] abort callback failed: ' + Std.string(e));
			}
		}
	}

	public static function probeServer(address:String, callback:ServerProbe->Void):Void {
		if (address == null || address == '') {
			callback(new ServerProbe());
			return;
		}

		Thread.run(() -> {
			var result = new ServerProbe();
			var start:Float = Sys.time();
			try {
				var http = new HTTPHandler(GameClient.addressToUrl(address));
				var response = http.request('/api/config');
				if (response != null) {
					result.reachable = response.status > 0 || response.exception == null;
					result.status = response.status;
					result.pingMs = Std.int((Sys.time() - start) * 1000);
					if (!response.isFailed()) {
						result.ok = true;
						try {
							result.config = haxe.Json.parse(response.getString());
						} catch (e:Dynamic) {
							result.config = null;
						}
					}
				}
			} catch (e:Dynamic) {
				result.reachable = false;
			}

			Waiter.put(() -> callback(result));
		}, (exc) -> {
			// A probe is best-effort: an exception here used to be rethrown on the main thread by
			// Thread.run (that is how "Invalid field:reachable" became a crash report), which also
			// left the player on a screen whose loading flag was never cleared. Report it as
			// "unreachable" instead and let the caller show its message.
			trace('[probe] ' + address + ' failed: ' + Std.string(exc));
			Waiter.put(() -> callback(new ServerProbe()));
		});
	}

	public static function addressToUrl(?address:Null<String>) {
		// Haxe 4.2.5 has no null-coalescing; an explicit fallback is used.
		var copyAddress = address != null ? address : GameClient.serverAddress;
		if (copyAddress.startsWith("wss://")) {
			copyAddress = "https://" + copyAddress.substr("wss://".length);
		}
		else if (copyAddress.startsWith("ws://")) {
			copyAddress = "http://" + copyAddress.substr("ws://".length);
		}
		return copyAddress;
	}

	public static function getAvailableRooms(address:String, result:(Error, Array<RoomAvailable>) -> Void) {
		Thread.run(() -> {
			var http = new Http(addressToUrl(address) + "/rooms/room");

			http.onData = function(data:String) {
				try {
					result(null, haxe.Json.parse(data));
				}
				catch (exc) {
					result(new Error(0, 'failed to parse json request'), null);
				}
			}

			http.onError = function(error) {
				result(new Error(0, error), null);
			}

			http.request();
		});
	}

	public static function getServerPlayerCount(?address:String, ?callback:(v:Null<Int>)->Void) {
		if (address == null)
			address = serverAddress;

		Thread.run(() -> {
			var http = new Http(addressToUrl(address) + "/api/onlinecount");

			http.onData = function(data:String) {
				if (callback != null)
					Waiter.put(() -> {
						callback(Std.parseInt(data));
					});
			}

			http.onError = function(error) {
				if (callback != null)
					Waiter.put(() -> {
						callback(null);
					});
			}

			http.request();
		}, _ -> { return; });
	}

	private static var ratingsData:Array<Rating> = Rating.loadDefault(); // from PlayState

	public static function getPlayerAccuracyPercent(player:Player) {
		var totalPlayed = player.sicks + player.goods + player.bads + player.shits + player.misses; // all the encountered notes
		var totalNotesHit = 
			(player.sicks * ratingsData[0].ratingMod) + 
			(player.goods * ratingsData[1].ratingMod) + 
			(player.bads * ratingsData[2].ratingMod) +
			(player.shits * ratingsData[3].ratingMod)
		;

		if (totalPlayed == 0)
			return 0.0;
		
		return CoolUtil.floorDecimal(Math.min(1, Math.max(0, totalNotesHit / totalPlayed)) * 100, 2);
	}

	public static function getPlayerRating(player:Player) {
		var ratingFC = 'Clear';
		if (player.misses < 1) {
			if (player.bads > 0 || player.shits > 0)
				ratingFC = 'FC';
			else if (player.goods > 0)
				ratingFC = 'GFC';
			else if (player.sicks > 0)
				ratingFC = 'SFC';
		}
		else if (player.misses < 10)
			ratingFC = 'SDCB';
		return ratingFC;
	}

	public static function getRoomSecret(?forceAddress:Bool = false) {
		// While hosting, advertise the LAN address instead of the loopback address the host
		// itself connects to, so the copied code is directly joinable by a friend on the LAN.
		if (lanShareAddress != null && lanShareAddress != '' && GameClient.room != null)
			return '${GameClient.room.roomId};${lanShareAddress}';

		if (forceAddress || GameClient.address != GameClient.getDefaultServer())
			return '${GameClient.room.roomId};${GameClient.address}';
		return GameClient.room.roomId;
	}

	public static function getGameplaySetting(key:String):Dynamic {
		if (key == 'songspeed' || key == 'mania') {
			var daSetting:String = room.state.gameplaySettings.get(key);
			if (daSetting == null)
				return null;

			if (daSetting == "true" || daSetting == "false") {
				return daSetting == "true" ? true : false;
			}

			var hasNonNumbers = false;
			var i = daSetting.length;
			var charCode = -1;
			while (i > 0) {
				i--;
				charCode = daSetting.charCodeAt(i);

				if (charCode < 48 || charCode > 57)
					hasNonNumbers = true;
			}

			if (!hasNonNumbers) {
				var _tryNum:Null<Float> = Std.parseFloat(daSetting);
				if (_tryNum != null && !Math.isNaN(_tryNum)) {
					return _tryNum;
				}
			}
			
			return daSetting;
		}

		return ClientPrefs.data.gameplaySettings.get(key);
	}

	public static function getPlayerCount():Int {
		if (!GameClient.isConnected())
			return 0;

		// Haxe 4.2.5 has no safe-navigation or null-coalescing; the checks are explicit.
		if (GameClient.room == null || GameClient.room.state == null || GameClient.room.state.players == null)
			return 0;
		return GameClient.room.state.players.length;
	}

	public static function getPlayerSelf() {
		if (!GameClient.isConnected() || GameClient.room == null)
			return null;

		return GameClient.room.state.players.get(GameClient.room.sessionId);
	}

	public static function listPlayersBySide(isBf:Bool):Array<Player> {
		if (!GameClient.isConnected())
			return null;

		var arr = [];
		for (sid => player in GameClient.room.state.players) {
			if (player.bfSide == isBf)
				arr.push(player);
		}
		return arr;
	}

	public static function getDefaultServer() {
		return serverAddresses[0];
	}
	
	@:unreflective
	public static var hasAddresses:Bool = false;
#if ONLINE_ALLOWED
	/** Self-hosted default; another server can be typed in the Online options. */
	public static inline var DEFAULT_SERVER_ADDRESS:String = "ws://localhost:2567";

	/**
	 * updateAddresses() assigns FunkinNetwork.client, but the async path only *starts* a worker
	 * thread and returns. The first caller -- OnlineState.create()'s ping/fetchFront worker
	 * threads -- then reached client.request(...) (FunkinNetwork.requestAPI:345) with a null
	 * handler, and a null call on cpp is a native null dereference, not a Haxe exception.
	 * Build the handler synchronously once instead.
	 */
	static var clientReady:Bool = false;

	static function ensureNetworkState():Void {
		if (clientReady)
			return;

		clientReady = true;

		try {
			updateAddresses();
		} catch (e:Dynamic) {
			trace('updateAddresses() failed: ' + Std.string(e));
		}

		if (serverAddresses.length == 0) {
			// updateAddresses() threw / never filled the list; getDefaultServer() reads
			// serverAddresses[0], and that empty-array read would be used as a String.
			serverAddresses.push(DEFAULT_SERVER_ADDRESS);
		}

		if (FunkinNetwork.client == null) {
			var url:String = null;
			try {
				url = GameClient.addressToUrl(networkServerAddress);
			} catch (e:Dynamic) {
				url = null;
			}
			if (url != null)
				FunkinNetwork.client = new online.http.HTTPHandler(url);
		}
	}
#end
	public static function asyncUpdateAddresses() {
#if ONLINE_ALLOWED
		// Make sure the handler exists before anyone (requestAPI) can use it.
		if (!clientReady) {
			ensureNetworkState();
			return;
		}
#end
		if (hasAddresses)
			return;

		Thread.run(() -> {
			if (hasAddresses)
				return;

			updateAddresses();
		});
	}

	public static function updateAddresses() {
		// Self-hosted: no remote address list is fetched any more. The built-in default is the
		// local server, and players can point at any other one from the Online options.
		if (!hasAddresses) {
			GameClient.serverAddresses = [DEFAULT_SERVER_ADDRESS];
			hasAddresses = true;
		}

		FunkinNetwork.client = new HTTPHandler(GameClient.addressToUrl(networkServerAddress));
	}
}
