package online_server;

import haxe.io.Bytes;
import haxe.io.BytesOutput;
import haxe.net.WebSocket;
import io.colyseus.Protocol;
import online.backend.schema.Player;
import online.backend.schema.Room;
// Empty schema used by the network room.
import online.backend.schema.NetworkSchema;

/**
 * Server-side session record for one player.
 *
 * Session lifetime is not the same as a connection's:
 *   * a network drop (not an explicit leave) only removes the conn from conns; the session and
 *     its state.players entry stay for RECONNECT_WINDOW seconds.
 *   * an explicit leave / kick (removed = true) and window timeout both go through removePlayer,
 *     which removes the player from state.players and broadcasts it.
 */
typedef SessionRecord = {
	var sessionId:String;
	var reconnectionToken:String;
	var options:Dynamic;
	/** Source IP of the matchmaking request. */
	var ip:String;
	var createdAt:Float;
	/** Whether the [10] ack has been received (i.e. the client really entered the room). */
	var everConnected:Bool;
	/** Time of the last disconnect; -1 means currently online (acked and still connected). */
	var disconnectedAt:Float;
	/** Time of the last "pong". */
	var lastPing:Float;
	/** Time of the last business activity. */
	var aliveTime:Float;
	/** Set on kick / explicit leave: the session must not reconnect. */
	var removed:Bool;
	/**
	 * The connection this session is currently bound to. On reconnect attach swaps in the new
	 * conn, so a late onclose from the old conn can tell it was superseded and must not mark the
	 * session as disconnected.
	 */
	var conn:ClientConn;
	/** Timestamps of recent reconnect attaches, used by the reconnect-storm guard (see Main.attach). */
	var attachTimes:Array<Float>;
}

class ClientConn {
	public var ws:WebSocket;
	public var sessionId:String;
	public var roomId:String;
	public var acked:Bool = false;
	public var player:Player = null;
	/** This connection is a reconnect reuse -- onAck takes the "resend full state only" path. */
	public var reconnected:Bool = false;
	/** Idempotency flag for disconnect (the ws.close() callback can re-enter disconnect). */
	public var closed:Bool = false;
	/** Degraded identity name for the network room (join-options name / networkId / sessionId). */
	public var networkName:String = null;
	/** Account id from the join options' networkId (null for guests); used to kick a banned account. */
	public var accountId:String = null;

	public function new(ws:WebSocket) {
		this.ws = ws;
	}
}

/**
 * Server-side state and protocol codec for one room.
 *
 * Frame formats follow source/_online_libs/io/colyseus/{Protocol,Room,Client}.hx:
 *   JOIN_ROOM        [10][len][reconnectionToken][len]["schema"]      (no handshake:
 *                     the client's SchemaSerializer.handshake() is empty)
 *   ROOM_STATE       [14][schema payload]
 *   ROOM_STATE_PATCH [15][schema payload]
 *   ROOM_DATA        [13][msgpack fixstr type][msgpack body]
 *   PING / PONG      [18]
 * The client only sends its [10] ack after dispatching onJoin from JOIN_ROOM, so the server
 * must **wait for the ack before sending ROOM_STATE**, or the state arrives before the user's
 * onStateChange listener is registered.
 */
class GameRoom {
	/** Settable from config.toml / the console. */
	public static var MAX_CLIENTS:Int = 6;
	/** Reconnect window in seconds. */
	public static inline var RECONNECT_WINDOW:Float = 20.0;
	/** Ping broadcast interval in seconds. */
	public static inline var PING_INTERVAL:Float = 3.0;
	/** No-pong timeout in seconds. */
	public static inline var PING_TIMEOUT:Float = 60.0;
	/** Inactivity timeout in seconds (20 minutes). */
	public static inline var ALIVE_TIMEOUT:Float = 20 * 60.0;
	/** Grace period for a matchmaking session that never acks; it is garbage-collected afterwards. */
	public static inline var UNCONNECTED_GRACE:Float = 30.0;
	/**
	 * Sliding window (seconds) and attach cap for the reconnect-storm guard (see Main.attach).
	 */
	public static inline var RECONNECT_STORM_WINDOW:Float = 5.0;
	public static inline var RECONNECT_STORM_LIMIT:Int = 12;

	/** Fixed roomId of the network room. The client calls `joinById('0')` (NetworkClient.hx:39),
	 *  so it must be pre-registered. */
	public static inline var NETWORK_ROOM_ID:String = "0";

	/** Global "lowercase nickname -> game room id", used to fill roomid for network-room invites. */
	public static var gameRoomOfPlayer:Map<String, String> = new Map();

	public var roomId:String;
	public var processId:String;
	public var state:Room;
	public var encoder:SchemaEncoder;

	public var sessions:Array<SessionRecord> = [];
	public var conns:Array<ClientConn> = [];
	public var patchRound:Int = 0;

	/** This is the resident network room (empty schema, social messages, not swept). */
	public var isNetwork:Bool = false;
	/** Lowercase nickname -> connection in the network room. */
	public var networkNames:Map<String, ClientConn> = new Map();

	/** Room creation time, used by ServerHub to sweep stale rooms with no connections. */
	public var createdAt:Float = haxe.Timer.stamp();

	/** Business-layer one-shot flags (not schema fields; never encoded into state). */
	public var songStarted:Bool = false;
	public var songEnded:Bool = false;

	/** Time of the last broadcast "ping". */
	public var lastPingTime:Float = 0;

	/** Room metadata: aggregate player points, verification state and host ping. */
	public var metaPoints:Float = 0;
	public var metaVerified:Bool = false;
	public var metaPing:Float = 0;

	var lastPingBroadcast:Float = 0;
	var lastPingCheck:Float = 0;
	var lastReconnectCheck:Float = 0;
	var deferred:Array<{at:Float, fn:Void->Void}> = [];

	/** When non-null, every outbound payload's hex is written here (for regression fixtures). */
	public static var fixtureDir:String = null;

	static function dumpFixture(name:String, payload:Bytes):Void {
		if (fixtureDir == null) {
			return;
		}
		try {
			if (!sys.FileSystem.exists(fixtureDir)) {
				sys.FileSystem.createDirectory(fixtureDir);
			}
			sys.io.File.saveContent(fixtureDir + "/" + name, payload.toHex());
		} catch (e:Dynamic) {
			trace('[fixture] write failed: ' + Std.string(e));
		}
	}

	public function new(roomId:String, processId:String) {
		this.roomId = roomId;
		this.processId = processId;
		this.state = new Room();
		this.encoder = new SchemaEncoder();
	}

	// ------------------------------------------------------------------
	// Sessions
	// ------------------------------------------------------------------

	public function addSession(sessionId:String, reconnectionToken:String, options:Dynamic, ip:String):SessionRecord {
		var now:Float = haxe.Timer.stamp();
		var record:SessionRecord = {
			sessionId: sessionId,
			reconnectionToken: reconnectionToken,
			options: options,
			ip: ip,
			createdAt: now,
			everConnected: false,
			disconnectedAt: -1,
			lastPing: now,
			aliveTime: now,
			removed: false,
			conn: null,
			attachTimes: []
		};
		sessions.push(record);
		return record;
	}

	public function sessionOf(sessionId:String):SessionRecord {
		for (s in sessions) {
			if (s.sessionId == sessionId) {
				return s;
			}
		}
		return null;
	}

	/** Matchmaking reconnect only gets a token; this looks the session back up. */
	public function sessionOfToken(token:String):SessionRecord {
		for (s in sessions) {
			if (s.reconnectionToken == token) {
				return s;
			}
		}
		return null;
	}

	public function connOf(sessionId:String):ClientConn {
		for (c in conns) {
			if (c.sessionId == sessionId) {
				return c;
			}
		}
		return null;
	}

	public function playerOf(sessionId:String):Player {
		return state.players.items.get(sessionId);
	}

	// ------------------------------------------------------------------
	// Network room's degraded identity and maps (roomId '0')
	// ------------------------------------------------------------------

	/**
	 * Degraded identity of the network room: join-options name (a local nickname) -> networkId
	 * -> sessionId. Accounts are not consulted. The client NetworkClient.hx:39-43 sends
	 * protocol/networkId/networkToken; the engine also supplies name.
	 */
	public function networkIdentity(record:SessionRecord):String {
		if (record == null) {
			return "";
		}
		var n:String = optionString(record, "name", "");
		if (n == "") {
			n = optionString(record, "networkId", "");
		}
		if (n == "") {
			n = record.sessionId;
		}
		return n;
	}

	/** Looks up a connection by nickname (case-insensitive). */
	public function networkConnOf(name:String):ClientConn {
		if (name == null) {
			return null;
		}
		return networkNames.get(name.toLowerCase());
	}

	/** Online name list (`/list`): acked connections only, in stable order. */
	public function networkNamesList():Array<String> {
		var out:Array<String> = [];
		for (c in conns) {
			if (c.acked && c.networkName != null && c.networkName != "") {
				out.push(c.networkName);
			}
		}
		return out;
	}

	function registerNetworkName(conn:ClientConn, record:SessionRecord):Void {
		conn.networkName = networkIdentity(record);
		if (conn.networkName != null && conn.networkName != "") {
			networkNames.set(conn.networkName.toLowerCase(), conn);
		}
	}

	/**
	 * "Unauthorized" handling for the network room: clear the nickname mapping and drop the
	 * connection. Unlike a game room there is no reconnect window, so the session is removed
	 * at once and cannot reconnect.
	 */
	public function kickNetwork(conn:ClientConn):Void {
		var record = sessionOf(conn.sessionId);
		if (record != null) {
			record.removed = true;
			removePlayer(record);
		}
		closeConn(conn);
	}

	public function playerCount():Int {
		var n = 0;
		for (c in conns) {
			if (c.acked) {
				n++;
			}
		}
		return n;
	}

	/** Whether any session is inside the reconnect window (such a room is not an empty, sweepable one). */
	public function hasPendingReconnect():Bool {
		for (s in sessions) {
			if (!s.removed && s.everConnected && s.disconnectedAt >= 0) {
				return true;
			}
		}
		return false;
	}

	/** Only real game rooms broadcast business pings (protocol-test rooms must not receive them). */
	public function hasGameSession():Bool {
		for (s in sessions) {
			if (RoomLogic.isGameRoom(s.options)) {
				return true;
			}
		}
		return false;
	}

	// ------------------------------------------------------------------
	// Frame assembly
	// ------------------------------------------------------------------

	public static function frameJoinRoom(reconnectionToken:String):Bytes {
		var out = new BytesOutput();
		out.writeByte(Protocol.JOIN_ROOM);
		writeLengthPrefixed(out, reconnectionToken);
		writeLengthPrefixed(out, "schema");
		return out.getBytes();
	}

	public static function frameState(payload:Bytes):Bytes {
		var out = new BytesOutput();
		out.writeByte(Protocol.ROOM_STATE);
		out.writeBytes(payload, 0, payload.length);
		return out.getBytes();
	}

	public static function framePatch(payload:Bytes):Bytes {
		var out = new BytesOutput();
		out.writeByte(Protocol.ROOM_STATE_PATCH);
		out.writeBytes(payload, 0, payload.length);
		return out.getBytes();
	}

	public static function frameRoomData(type:String, message:Dynamic):Bytes {
		var out = new BytesOutput();
		out.writeByte(Protocol.ROOM_DATA);

		var typeBytes = Bytes.ofString(type);
		out.writeByte(0xA0 | (typeBytes.length & 0x1F)); // msgpack fixstr
		out.writeBytes(typeBytes, 0, typeBytes.length);

		if (message != null) {
			var encoded = org.msgpack.MsgPack.encode(message);
			out.writeBytes(encoded, 0, encoded.length);
		}

		return out.getBytes();
	}

	public static function framePing():Bytes {
		var out = new BytesOutput();
		out.writeByte(Protocol.PING);
		return out.getBytes();
	}

	public static function frameError(code:Int, message:String):Bytes {
		var out = new BytesOutput();
		out.writeByte(Protocol.ERROR);

		// msgpack int32: the same shape SchemaEncoder.encodeNumber writes and the client's
		// Decode.number reads. A one-byte code would truncate values >= 128.
		out.writeByte(0xD2);
		out.writeInt32(code);
		writeLengthPrefixed(out, message);

		return out.getBytes();
	}

	static function writeLengthPrefixed(out:BytesOutput, s:String):Void {
		var bytes = Bytes.ofString(s);
		out.writeByte(bytes.length & 0xFF);
		out.writeBytes(bytes, 0, bytes.length);
	}

	// ------------------------------------------------------------------
	// Connection lifecycle
	// ------------------------------------------------------------------

	public function onOpen(conn:ClientConn):Void {
		var record = sessionOf(conn.sessionId);
		// The reconnectionToken in JOIN_ROOM must be the record's token: the client's Room.hx:279
		// stores roomId + ":" + token in room.reconnectionToken, and
		// GameClient.reconnect() / Client.reconnect() split it for backend reconnect.
		var token = (record != null) ? record.reconnectionToken : conn.sessionId;
		send(conn, frameJoinRoom(token));
	}

	public function onAck(conn:ClientConn):Void {
		if (conn.acked) {
			return;
		}
		conn.acked = true;

		var record = sessionOf(conn.sessionId);
		if (record != null) {
			record.everConnected = true;
			record.disconnectedAt = -1;
			record.lastPing = haxe.Timer.stamp();
			record.aliveTime = haxe.Timer.stamp();
		}

		// The network room (roomId '0') uses an empty schema with no Player / host / checkChart.
		// The client NetworkClient decodes with online.backend.schema.NetworkSchema, so send the
		// full NetworkSchema, not the game room's schema. Reconnects take this path too.
		if (isNetwork) {
			send(conn, frameState(encoder.encodeAll(new NetworkSchema())));
			registerNetworkName(conn, record);
			if (!conn.reconnected) {
				// Welcome message; not repeated on reconnect.
				NetworkLogic.sendLog(this, "Welcome, " + conn.networkName + "!\nYou should also check /help!", conn);
			}
			return;
		}

		// Reused connection for a reconnect: server state is unchanged, so the full state is
		// resent only to this client (it rebuilt the Room and its local state is empty); no ADD patch.
		if (conn.reconnected) {
			trace('[room $roomId] session ${conn.sessionId} reconnected, resending full state');
			send(conn, frameState(encoder.encodeAll(state)));
			return;
		}

		// Room-level state that has to be in the first encodeAll. A joining client decodes the full
		// state once, and RoomState installs no callback on room.song (RoomState.hx:172), so a later
		// patch would not refresh the lobby UI. host is the first session to ack; a game room also
		// gets the default song/difficulty so the lobby can start without a song picker.
		if (state.host == "") {
			state.host = conn.sessionId;
		}
		var isGameRoom = RoomLogic.isGameRoom(record == null ? null : record.options);
		if (isGameRoom) {
			RoomLogic.applyRoomDefaults(state);
		}

		var player = new Player();
		player.name = optionString(record, "name", conn.sessionId);
		// The protocol test build pinned hasSong/hasLoaded true; a game room goes through the real
		// "verifyChart" round trip instead (RoomState.hx:818-841), and the server sets hasSong there.
		player.hasSong = !isGameRoom;
		player.hasLoaded = true;
		conn.player = player;

		// The HUD row index ox for same-side players must be written before the first ADD patch
		// below; otherwise already-joined clients receive a copy with ox=0 and the HUD rows overlap.
		// See RoomLogic.onPlayerJoined.
		if (isGameRoom) {
			// Join-options profile fields (skin / noteSkin / arrowRGB / points) must be written
			// before the first ADD patch and the full state, or already-joined clients get a
			// copy missing them.
			RoomLogic.applyPlayerOptions(this, record, player);
			RoomLogic.onPlayerJoined(this, conn);

			// Records which game room this nickname is in, for the network room's invite flow.
			if (player.name != null && player.name != "") {
				GameRoom.gameRoomOfPlayer.set(player.name.toLowerCase(), roomId);
			}

			// Room metadata is written when the first player joins.
			if (playerCount() == 1) {
				metaPoints = optionNumber(record, "points");
				metaVerified = false;
			}
		}

		// 1) Clients already in the room see this player incrementally (ADD).
		var hadPlayers = state.players.length > 0;
		var addPatch = encoder.encodeMapAdd(state.players, conn.sessionId, player);
		if (hadPlayers) {
			broadcast(framePatch(addPatch), conn.sessionId);
		}

		// 2) The new client gets the full state (players already includes it).
		var fullPayload = encoder.encodeAll(state);
		dumpFixture("room-state.hex", fullPayload);
		send(conn, frameState(fullPayload));

		// Send checkChart twice to the new player (immediately and after 1 second); the client's
		// chart / mod verification waits on it (GameClient.hx:684, RoomState.hx:169).
		send(conn, frameRoomData("checkChart", ""));
		var sid = conn.sessionId;
		deferredCall(1.0, function() {
			var c = connOf(sid);
			if (c != null && c.acked) {
				send(c, frameRoomData("checkChart", ""));
			}
		});
	}

	public function onLeave(conn:ClientConn, ?consented:Bool = false):Void {
		disconnect(conn, consented, false);
	}

	/**
	 * Unified entry point for a connection leaving.
	 *
	 *   * explicit leave (client sends LEAVE_ROOM) or a kick -> removePlayer at once, no reconnect.
	 *   * network drop in a game room -> keep the session / Player and enter the
	 *     RECONNECT_WINDOW second reconnect window.
	 *   * non-game rooms (protocol-test rooms) are not kept: removePlayer immediately.
	 */
	public function disconnect(conn:ClientConn, ?consented:Bool = false, ?kicked:Bool = false):Void {
		// Idempotent: closeConn()'s onclose re-enters here (LEAVE_ROOM frame and onclose are two paths).
		if (conn == null || conn.closed) {
			return;
		}
		conn.closed = true;

		conns.remove(conn);
		closeConn(conn);

		var record = sessionOf(conn.sessionId);
		if (record == null || record.removed) {
			return;
		}

		// On reconnect, attach binds the session to the new conn, so the old conn's onclose must
		// not mark the just-reconnected session as disconnected (it would be swept after 20 seconds).
		if (record.conn != null && record.conn != conn) {
			return;
		}

		if (kicked || consented || !(RoomLogic.isGameRoom(record.options) || isNetwork) || !record.everConnected) {
			record.removed = true;
			removePlayer(record);
			return;
		}

		if (record.disconnectedAt < 0) {
			record.disconnectedAt = haxe.Timer.stamp();
		}
		trace('[room $roomId] session ${record.sessionId} disconnected; reconnect window ${RECONNECT_WINDOW}s');
	}

	/**
	 * Removes a session from the room. The order matters: broadcast "<name> has left the room!"
	 * first (the Player is still in state.players and the broadcast needs its name), reset
	 * isReady, then emit the map DELETE patch.
	 */
	public function removePlayer(record:SessionRecord):Void {
		if (record == null) {
			return;
		}

		var player = playerOf(record.sessionId);
		var playerName = (player != null) ? player.name : null;
		trace('[room ' + roomId + '] removePlayer ' + record.sessionId + ' (player=' + playerName + ')');

		// The network room has no Player, so only the nickname mapping must be cleared.
		if (isNetwork) {
			var netName:String = networkIdentity(record);
			if (netName != null && netName != "") {
				networkNames.remove(netName.toLowerCase());
			}
		}

		// The cross-room "nickname -> game room" index must be cleared too, or invites point at a destroyed room.
		if (playerName != null && playerName != "") {
			GameRoom.gameRoomOfPlayer.remove(playerName.toLowerCase());
		}

		if (playerName != null && playerName != "") {
			RoomLogic.sendLog(this, playerName + " has left the room!");
		}

		// Outside a running round, everyone must READY up again.
		if (!state.isStarted) {
			for (c in conns) {
				if (c.acked && c.player != null && c.player.isReady) {
					RoomLogic.setPlayerField(this, c.player, "isReady", false);
				}
			}
		}

		if (player != null) {
			var removePatch = encoder.encodeMapRemove(state.players, record.sessionId);
			broadcast(framePatch(removePatch), null);
		}

		sessions.remove(record);

		// After the host leaves, hand host to the first player in the room; otherwise host
		// forever points at the departed sid and the room can never change song/stage.
		if (state.host == record.sessionId) {
			var next = (sessions.length > 0) ? sessions[0].sessionId : "";
			RoomLogic.setRoomField(this, "host", next);
			trace('[room $roomId] host transferred from ${record.sessionId} to "${next}"');
		}

		// Re-number the HUD rows after the leave.
		RoomLogic.reassignOx(this);
	}

	// ------------------------------------------------------------------
	// Main-loop scheduling (delayed callbacks, ping, reconnect timeouts)
	// ------------------------------------------------------------------

	/** Delayed callback -- runs only on the WS main-loop thread, avoiding schema / WS races. */
	public function deferredCall(delay:Float, fn:Void->Void):Void {
		deferred.push({at: haxe.Timer.stamp() + delay, fn: fn});
	}

	function runDeferred(now:Float):Void {
		if (deferred.length == 0) {
			return;
		}
		var keep:Array<{at:Float, fn:Void->Void}> = [];
		for (d in deferred) {
			if (now >= d.at) {
				try {
					d.fn();
				} catch (e:Dynamic) {
					trace('[room $roomId] deferred error: ' + Std.string(e));
				}
			} else {
				keep.push(d);
			}
		}
		deferred = keep;
	}

	/**
	 * Called every turn of ServerHub.run()'s WS main loop (now = haxe.Timer.stamp()).
	 * Drives delayed callbacks, the periodic ping / timeout sweep and reconnect-window timeouts.
	 */
	public function tick(now:Float):Void {
		runDeferred(now);

		// Broadcast "ping" every 3 seconds; clients reply "pong". The network room sends no
		// business ping.
		if (!isNetwork && hasGameSession() && now - lastPingBroadcast >= PING_INTERVAL) {
			lastPingBroadcast = now;
			lastPingTime = now;
			broadcast(frameRoomData("ping", null), null);
		}

		// Periodic sweep for sessions with no pong / no activity.
		if (now - lastPingCheck >= PING_TIMEOUT) {
			lastPingCheck = now;
			checkPingTimeouts(now);
		}

		// Reconnect windows are in seconds, so they cannot wait for the 60-second sweep.
		if (now - lastReconnectCheck >= 1.0) {
			lastReconnectCheck = now;
			checkSessionTimeouts(now);
		}
	}

	function checkPingTimeouts(now:Float):Void {
		// The network room has no ping, so a ping timeout would kick everyone by mistake.
		if (isNetwork) {
			return;
		}

		var expired:Array<SessionRecord> = [];
		for (record in sessions) {
			if (record.removed || !record.everConnected || record.disconnectedAt >= 0) {
				continue;
			}
			if (now - record.lastPing > PING_TIMEOUT) {
				trace('[room $roomId] session ${record.sessionId} stopped ponging; kicking');
				expired.push(record);
			} else if (now - record.aliveTime > ALIVE_TIMEOUT) {
				trace('[room $roomId] session ${record.sessionId} inactive; kicking');
				expired.push(record);
			}
		}
		for (record in expired) {
			// A timed-out session must not reconnect, so mark it removed.
			record.removed = true;
			removePlayer(record);
		}
	}

	function checkSessionTimeouts(now:Float):Void {
		var expired:Array<SessionRecord> = [];
		for (record in sessions) {
			if (record.removed) {
				continue;
			}
			if (!record.everConnected) {
				if (now - record.createdAt > UNCONNECTED_GRACE) {
					expired.push(record);
				}
				continue;
			}
			if (record.disconnectedAt >= 0 && now - record.disconnectedAt > RECONNECT_WINDOW) {
				trace('[room $roomId] session ${record.sessionId} reconnect window expired');
				expired.push(record);
			}
		}
		for (record in expired) {
			record.removed = true;
			removePlayer(record);
		}
	}

	public function closeConn(conn:ClientConn):Void {
		try {
			conn.ws.close();
		} catch (e:Dynamic) {}
	}

	// ------------------------------------------------------------------
	// Messages
	// ------------------------------------------------------------------

	public function onRoomData(conn:ClientConn, type:Dynamic, message:Dynamic):Void {
		trace('[room $roomId] <- "${type}" from ${conn.sessionId}: ' + haxe.Json.stringify(message));

		// Echo back to verify msgpack in both directions.
		broadcast(frameRoomData("alert", {
			echo: Std.string(type),
			payload: message,
			from: conn.sessionId
		}), null);
	}

	/** Contract-required field patches: a root scalar, a scalar inside a map child, and a boolean. */
	public function applyContractPatch():Void {
		patchRound++;

		var songPayload = encoder.encodeFieldChange(state, "song", "Bopeebo-Online");
		dumpFixture("patch-song.hex", songPayload);
		broadcast(framePatch(songPayload), null);

		var startedPayload = encoder.encodeFieldChange(state, "isStarted", true);
		dumpFixture("patch-isStarted.hex", startedPayload);
		broadcast(framePatch(startedPayload), null);

		broadcast(framePatch(encoder.encodeFieldChange(state, "health", 1.5)), null);

		for (conn in conns) {
			if (!conn.acked || conn.player == null) {
				continue;
			}
			var scorePayload = encoder.encodeFieldChange(conn.player, "score", 1000 + patchRound * 7);
			dumpFixture("patch-score.hex", scorePayload);
			broadcast(framePatch(scorePayload), null);

			broadcast(framePatch(encoder.encodeFieldChange(conn.player, "isReady", true)), null);
		}
	}

	public function broadcast(data:Bytes, ?exceptSessionId:String):Void {
		for (conn in conns) {
			if (exceptSessionId != null && conn.sessionId == exceptSessionId) {
				continue;
			}
			if (!conn.acked) {
				continue;
			}
			send(conn, data);
		}
	}

	public function send(conn:ClientConn, data:Bytes):Void {
		try {
			conn.ws.sendBytes(data);
		} catch (e:Dynamic) {
			trace('send failed to ${conn.sessionId}: ' + Std.string(e));
		}
	}

	static function optionString(record:SessionRecord, name:String, fallback:String):String {
		if (record == null || record.options == null) {
			return fallback;
		}
		var value:Dynamic = Reflect.field(record.options, name);
		if (value == null) {
			return fallback;
		}
		return Std.string(value);
	}

	static function optionNumber(record:SessionRecord, name:String, fallback:Float = 0):Float {
		if (record == null || record.options == null) {
			return fallback;
		}
		var value:Dynamic = Reflect.field(record.options, name);
		if (value == null) {
			return fallback;
		}
		var parsed = Std.parseFloat(Std.string(value));
		return Math.isNaN(parsed) ? fallback : parsed;
	}
}
