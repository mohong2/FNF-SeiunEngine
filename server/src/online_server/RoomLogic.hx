package online_server;

import online.backend.schema.ColorArray;
import online.backend.schema.Player;
import online.backend.schema.Room;
import online_server.GameRoom.ClientConn;
import online_server.GameRoom.SessionRecord;

/**
 * Game logic layer for the online protocol: two clients create a room, lobby, start a song,
 * drive the online HUD and remote animations, and end it. Semantics follow the client sources
 * (PlayState.registerMessages() 10001-10142). verifyChart trusts the chart hash, rooms default
 * to bopeebo, setSong ignores diffList, isReady is not echoed, and "ping"/"pong" replaces the
 * ping timer.
 */
class RoomLogic {
	/** Default chart: assets/preload/data/<folder>/<song>.json must exist. */
	public static inline var DEFAULT_SONG:String = "bopeebo";
	public static inline var DEFAULT_FOLDER:String = "bopeebo";
	public static inline var DEFAULT_DIFF:Int = 1;
	/** Default chat hue; the server has no account system, so every chat line uses it. */
	public static inline var DEFAULT_HUE:Float = 250;

	// ------------------------------------------------------------------
	// Room initialization (called by GameRoom.onAck before the first encodeAll)
	// ------------------------------------------------------------------

	/**
	 * Whether this is a game room. The business client's getOptions() (GameClient.hx:297) always
	 * includes "protocol"; the protocol test client only sends name (Probe.hx:74), so this check
	 * separates the protocol contract from the business layer and leaves the existing
	 * "new room state.song == \"\"" assertion (Probe.hx:95) intact.
	 */
	public static function isGameRoom(options:Dynamic):Bool {
		if (options == null) {
			return false;
		}
		return Reflect.field(options, "protocol") != null;
	}

	/**
	 * Default song and difficulty. Must be written before the first business client's
	 * ROOM_STATE (encodeAll): RoomState only registers callbacks on player fields
	 * (RoomState.hx:172), so changing room.song later does not refresh the UI.
	 */
	public static function applyRoomDefaults(state:Room):Void {
		// Initial value of the shared room health bar Room.health. The schema default is 0, but
		// online clients treat it as authoritative (initOnlineHealthSync), so without 1 the bar
		// starts empty and players are declared dead immediately.
		state.health = 1;
		if (state.song != "") {
			return;
		}
		state.song = DEFAULT_SONG;
		state.folder = DEFAULT_FOLDER;
		state.diff = DEFAULT_DIFF;
		// Rooms are private by default; the client schema (online/backend/schema/Room.hx:51)
		// defaults false and the host flips it via `togglePrivate`, so write it only on first
		// initialization, never on join.
		state.isPrivate = true;
		if (state.diffList.length == 0) {
			state.diffList.items.push("Easy");
			state.diffList.items.push("Normal");
			state.diffList.items.push("Hard");
		}
	}

	// ------------------------------------------------------------------
	// Message dispatch
	// ------------------------------------------------------------------

	public static function handle(room:GameRoom, conn:ClientConn, type:Dynamic, message:Dynamic):Void {
		var typeName:String = Std.string(type);
		var self:Player = conn.player;

		if (self == null) {
			// Connections that have not acked yet are not part of the room state.
			return;
		}

		// Record that this player is still active; the 20-minute inactivity sweep relies on it.
		var session:SessionRecord = room.sessionOf(conn.sessionId);
		if (session != null) {
			session.aliveTime = haxe.Timer.stamp();
		}

		// Debug tracing: log only low-frequency key messages (addScore/noteHit fire every frame).
		if (isLoggedMessage(typeName)) {
			trace('[room ' + room.roomId + '] <- "' + typeName + '" from ' + conn.sessionId
				+ (message == null ? "" : ": " + haxe.Json.stringify(message)));
		}

		switch (typeName) {
			case "pong":
				// RTT = now - time of the last ping broadcast, written to Player.ping (the online
				// HUD source, PlayState.hx:10338); the host's RTT also goes to room metadata.
				var nowPong:Float = haxe.Timer.stamp();
				if (session != null) {
					session.lastPing = nowPong;
				}
				var rtt:Float = (room.lastPingTime > 0) ? (nowPong - room.lastPingTime) * 1000 : 0;
				setPlayerField(room, self, "ping", rtt);
				if (room.state.host == conn.sessionId) {
					room.metaPing = rtt;
				}

			case "status":
				setPlayerField(room, self, "status", Std.string(message));

			case "noteHold":
				setPlayerField(room, self, "noteHold", toBool(message));

			case "botplay":
				// Only flip false -> true, matching the client condition (PlayState.hx:462).
				if (toBool(message == null ? true : message) && !self.botplay) {
					setPlayerField(room, self, "botplay", true);
				}

			case "verifyChart":
				// The server cannot read client assets, so it trusts the client, but a song must
				// exist first: setting hasSong with song="" makes loadSong("", "") fail with a
				// missing file error.
				if (room.state.song != null && room.state.song != "") {
					setPlayerField(room, self, "hasSong", true);
				}

			case "setSong":
				applySong(room, conn, message);

			case "setStage":
				applyStage(room, conn, message);

			case "startGame":
				startGame(room, conn);

			case "playerReady":
				setPlayerField(room, self, "isReady", true, conn);
				maybeStartSong(room);

			case "addScore":
				setPlayerField(room, self, "score", num(self.score) + num(message));

			case "addHitJudge":
				addHitJudge(room, self, message);

			case "addMiss":
				setPlayerField(room, self, "misses", num(self.misses) + 1);

			case "updateMaxCombo":
				var combo:Float = num(message);
				if (combo > num(self.maxCombo)) {
					setPlayerField(room, self, "maxCombo", combo);
				}

			case "updateSongFP":
				setPlayerField(room, self, "songPoints", num(message));

			case "updateFP":
				setPlayerField(room, self, "points", num(message));

			case "updateHealth":
				// Clients send the delta of their local health; the server accumulates it into the
				// shared Room.health bar and broadcasts to everyone (including the sender), so both
				// clients show identical health.
				applyHealth(room, message);

			case "playerEnded":
				setPlayerField(room, self, "hasEnded", true);
				maybeEndSong(room);

			case "requestEndSong":
				// An explicit end (the pause menu's "Exit to lobby") also ends the round, setting
				// songEnded so the next startGame goes through resetRound instead of staying on isStarted.
				room.songEnded = true;
				trace('[room ' + room.roomId + '] -> broadcast "endSong" (requestEndSong)');
				room.broadcast(GameRoom.frameRoomData("endSong", null), null);


			case "chat":
				applyChat(room, conn, message);

			case "command":
				applyCommand(room, conn, message);

			case "custom":
				// Broadcast to everyone except the sender, keeping the message name and appending the sender sid.
				if (isArrayMin(message, 2)) {
					room.broadcast(GameRoom.frameRoomData("custom", [conn.sessionId, message]), conn.sessionId);
				}

			case "customTo":
				applyCustomTo(room, conn, message);

			case "notifyInstall":
				applyNotifyInstall(room, conn, message);

			case "setSkin":
				applySkin(room, conn, message);

			case "updateNoteSkinData":
				applyNoteSkinData(room, conn, message);

			case "nextWinCondition":
				nextWinCondition(room, conn);

			case "togglePrivate":
				toggleRoomBool(room, conn, "isPrivate");

			case "toggleNetworkOnly":
				toggleRoomBool(room, conn, "networkOnly");

			case "anarchyMode":
				toggleRoomBool(room, conn, "anarchyMode");

			case "togglePlayersCanChoose":
				toggleRoomBool(room, conn, "allPlayersChoose");

			case "toggleGF":
				toggleRoomBool(room, conn, "hideGF");

			case "toggleSkins":
				toggleSkins(room, conn);

			case "swapSides":
				// The client's RoomSettingsSubstate "Boyfriend Side" switch sends this message
				// (RoomSettingsSubstate.hx:96-102); without handling it bfSide stays at the schema
				// default and both players render on the opponent side.
				swapSides(room, conn);

			case "teamMode":
				toggleRoomBool(room, conn, "teamMode");

			case "royalMode":
				toggleRoomBool(room, conn, "royalMode");

			case "royalModeDadSide":
				toggleRoomBool(room, conn, "royalModeDadSide");

			default:
				// Everything else is relayed to the other room members (noteHit / noteMiss /
				// strumPlay / charPlay / custom / chat / command ...), using this engine's inbound
				// listener shapes.
				forward(room, conn, typeName, message);
		}
	}

	// ------------------------------------------------------------------
	// Room-level operations
	// ------------------------------------------------------------------

	static function applySong(room:GameRoom, conn:ClientConn, message:Dynamic):Void {
		if (!canChangeRoom(room, conn) || !Std.isOfType(message, Array)) {
			return;
		}
		var data:Array<Dynamic> = cast message;
		if (data.length < 7) {
			return;
		}
		// Payload shape sent by the client (FreeplayState.hx:1163-1175):
		//   [songLowercase, formattedChart, diff, md5, modDir, modUrl, diffList]
		setRoomField(room, "song", Std.string(data[1]));
		setRoomField(room, "folder", Std.string(data[0]));
		setRoomField(room, "diff", num(data[2]));
		setRoomField(room, "modDir", Std.string(data[4]));
		setRoomField(room, "modURL", data[5] == null ? "" : Std.string(data[5]));
		// data[6] is the difficulty list; it is not updated at runtime.

		// Changing the song starts a new round: reset the one-shot flags left from the previous
		// round and make everyone re-verify the new chart (otherwise hasSong stays true and the
		// client skips verifyChart straight to startGame).
		resetRound(room);
		invalidateHasSong(room);
	}

	static function applyStage(room:GameRoom, conn:ClientConn, message:Dynamic):Void {
		if (!canChangeRoom(room, conn) || !Std.isOfType(message, Array)) {
			return;
		}
		var data:Array<Dynamic> = cast message;
		if (data.length < 3) {
			return;
		}
		setRoomField(room, "stageName", Std.string(data[0]));
		setRoomField(room, "stageMod", data[1] == null ? "" : Std.string(data[1]));
		setRoomField(room, "stageURL", data[2] == null ? "" : Std.string(data[2]));
		// RoomState listens for "checkStage" and re-runs its local validation (RoomState.hx:166).
		room.broadcast(GameRoom.frameRoomData("checkStage", null), conn.sessionId);
	}

	// ------------------------------------------------------------------
	// Room-level handlers
	// ------------------------------------------------------------------

	/**
	 * Writes the profile from the join options into the Player when a new player acks
	 * (`GameRoom.onAck`). **Must run before the first ADD patch / full encodeAll**, otherwise
	 * the copy already in the room is missing fields.
	 */
	public static function applyPlayerOptions(room:GameRoom, record:SessionRecord, player:Player):Void {
		if (record == null || record.options == null || player == null) {
			return;
		}
		var o:Dynamic = record.options;

		if (!room.state.disableSkins) {
			for (v in normalizeSkin(Reflect.field(o, "skin"))) {
				player.skin.items.push(v);
			}
			player.skinURL = str(Reflect.field(o, "skinURL"));
		}

		player.noteSkin = str(Reflect.field(o, "noteSkin"));
		player.noteSkinMod = str(Reflect.field(o, "noteSkinMod"));
		player.noteSkinURL = str(Reflect.field(o, "noteSkinURL"));

		updateArrowColors(player, Reflect.field(o, "arrowRGB"));
		player.points = num(Reflect.field(o, "points"));
	}

	/** The `log` payload is a **JSON string**, not an object. */
	static function formatLog(content:String, ?hue:Float, isPM:Bool = false):String {
		return haxe.Json.stringify({
			content: content,
			hue: hue,
			date: Date.now().getTime(),
			isPM: isPM
		});
	}

	/** Broadcasts a `log` to the whole room (sender included); a non-null `to` targets one connection. */
	public static function sendLog(room:GameRoom, content:String, ?to:ClientConn, ?hue:Float):Void {
		var frame = GameRoom.frameRoomData("log", formatLog(content, hue));
		if (to != null) {
			room.send(to, frame);
		} else {
			room.broadcast(frame, null);
		}
	}

	/** Player chat. */
	static function applyChat(room:GameRoom, conn:ClientConn, message:Dynamic):Void {
		if (!Std.isOfType(message, String)) {
			return;
		}
		// Newlines become spaces; the server has no word filter, so that is the only sanitizing step.
		var text:String = (message : String).split("\n").join(" ");
		if (text.length >= 300) {
			sendLog(room, "The message is too long!", conn);
			return;
		}
		if (StringTools.trim(text) == "") {
			return;
		}
		// The server has no account system, so every chat line uses the default hue.
		sendLog(room, conn.player.name + ": " + text, null, DEFAULT_HUE);
	}

	/** Chat commands. */
	static function applyCommand(room:GameRoom, conn:ClientConn, message:Dynamic):Void {
		if (!isArrayMin(message, 1)) {
			return;
		}
		var parts:Array<Dynamic> = (message : Array<Dynamic>);
		var cmd:String = Std.string(parts[0]).toLowerCase();
		var args:Array<String> = [];
		for (i in 1...parts.length) {
			args.push(Std.string(parts[i]));
		}

		switch (cmd) {
			case "roll":
				{
					var roll:Int = Std.random(6) + 1;
					sendLog(room, "> " + conn.player.name + " has rolled " + roll);
				}
			case "help":
				sendLog(room, "> Global Commands: /roll, /kick <name>", conn);
			case "kick":
				commandKick(room, conn, args);
			default:
				sendLog(room, "> Unknown command; try /help to see the command list!", conn);
		}
	}

	/** `/kick <name>`: only affects players with a real connection (dummies are out of scope). */
	static function commandKick(room:GameRoom, conn:ClientConn, args:Array<String>):Void {
		if (room.state.host != conn.sessionId) {
			sendLog(room, "> Just leave the game bro", conn);
			return;
		}
		var username:String = args.join(" ").toLowerCase();
		var targets:Array<ClientConn> = [];
		for (c in room.conns) {
			if (!c.acked || c.player == null || c.sessionId == room.state.host) {
				continue;
			}
			if (username == "" || c.player.name.toLowerCase() == username) {
				targets.push(c);
			}
		}
		for (c in targets) {
			// A kicked player cannot reconnect.
			room.disconnect(c, false, true);
		}
		sendLog(room, "> Kicked " + targets.length + " people", conn);
	}

	/** `customTo`: sends to the target only, always under the "custom" message name. */
	static function applyCustomTo(room:GameRoom, conn:ClientConn, message:Dynamic):Void {
		if (!isArrayMin(message, 3)) {
			return;
		}
		var data:Array<Dynamic> = (message : Array<Dynamic>);
		var target = room.connOf(Std.string(data[0]));
		if (target == null || !target.acked) {
			return;
		}
		room.send(target, GameRoom.frameRoomData("custom", [conn.sessionId, data.slice(1)]));
	}

	/** `notifyInstall` handler. */
	static function applyNotifyInstall(room:GameRoom, conn:ClientConn, message:Dynamic):Void {
		if (!Std.isOfType(message, String)) {
			return;
		}
		var url:String = (message : String);
		if (url.length >= 200) {
			sendLog(room, conn.player.name + " has finished installing the mod!");
			return;
		}
		sendLog(room, conn.player.name + " has finished installing: " + url);
	}

	/** `setSkin`: ignored while `disableSkins` is on. */
	static function applySkin(room:GameRoom, conn:ClientConn, message:Dynamic):Void {
		var self:Player = conn.player;
		if (self == null || room.state.disableSkins) {
			return;
		}
		if (!isArrayMin(message, 2)) {
			setPlayerSkin(room, self, null);
			setPlayerField(room, self, "skinURL", "");
			return;
		}
		var data:Array<Dynamic> = (message : Array<Dynamic>);
		setPlayerSkin(room, self, data[0]);
		setPlayerField(room, self, "skinURL", data[1] == null ? "" : Std.string(data[1]));
	}

	/** `updateNoteSkinData` handler. */
	static function applyNoteSkinData(room:GameRoom, conn:ClientConn, message:Dynamic):Void {
		if (conn.player == null || !isArrayMin(message, 3)) {
			return;
		}
		var data:Array<Dynamic> = (message : Array<Dynamic>);
		setPlayerField(room, conn.player, "noteSkin", str(data[0]));
		setPlayerField(room, conn.player, "noteSkinMod", str(data[1]));
		setPlayerField(room, conn.player, "noteSkinURL", str(data[2]));
	}

	/** `nextWinCondition`: 0 accuracy / 1 score / 2 misses / 3 points / 4 combo. */
	static function nextWinCondition(room:GameRoom, conn:ClientConn):Void {
		if (!canChangeRoom(room, conn)) {
			return;
		}
		var next:Float = num(room.state.winCondition) + 1;
		if (next > 4) {
			next = 0;
		}
		setRoomField(room, "winCondition", Math.max(0, next));
	}

	/** `toggleSkins`: clearing skins resets everyone; enabling them asks everyone to report again. */
	static function toggleSkins(room:GameRoom, conn:ClientConn):Void {
		if (!canChangeRoom(room, conn)) {
			return;
		}
		var disabled:Bool = !(cast Reflect.field(room.state, "disableSkins"));
		setRoomField(room, "disableSkins", disabled);

		if (disabled) {
			for (c in room.conns) {
				if (!c.acked || c.player == null) {
					continue;
				}
				setPlayerSkin(room, c.player, null);
				setPlayerField(room, c.player, "skinURL", "");
			}
		} else {
			room.broadcast(GameRoom.frameRoomData("requestSkin", null), null);
		}
	}

	/** A skin must have exactly 4 entries; anything else is treated as empty. */
	static function setPlayerSkin(room:GameRoom, player:Player, value:Dynamic):Void {
		setPlayerStringArray(room, player, "skin", normalizeSkin(value));
	}

	/** Replaces a string array via `SchemaEncoder.encodeStringArrayReplace` (CLEAR + ADD) and broadcasts it. */
	static function setPlayerStringArray(room:GameRoom, player:Player, field:String, values:Array<String>):Void {
		var payload = room.encoder.encodeStringArrayReplace(player, field, values);
		room.broadcast(GameRoom.framePatch(payload), null);
	}

	/** Maps `[maniaRgbMap, maniaPixelRgbMap]` onto the `ColorArray` maps. */
	static function updateArrowColors(player:Player, message:Dynamic):Void {
		if (player == null || !Std.isOfType(message, Array)) {
			return;
		}
		var maps:Array<Dynamic> = (message : Array<Dynamic>);
		for (i in 0...maps.length) {
			var map:Dynamic = maps[i];
			if (map == null) {
				continue;
			}
			var target = (i == 0) ? player.arrowColors : player.arrowColorsPixel;
			for (key in Reflect.fields(map)) {
				var colors2D:Dynamic = Reflect.field(map, key);
				if (!Std.isOfType(colors2D, Array)) {
					continue;
				}
				var colors = new ColorArray();
				for (rgb in (colors2D : Array<Dynamic>)) {
					if (!Std.isOfType(rgb, Array)) {
						continue;
					}
					for (n in (rgb : Array<Dynamic>)) {
						colors.value.items.push(num(n));
					}
				}
				target.items.set(key, colors);
			}
		}
	}

	static function normalizeSkin(value:Dynamic):Array<String> {
		var out:Array<String> = [];
		if (!Std.isOfType(value, Array)) {
			return out;
		}
		var arr:Array<Dynamic> = (value : Array<Dynamic>);
		if (arr.length != 4) {
			return out;
		}
		for (v in arr) {
			out.push(v == null ? "" : Std.string(v));
		}
		return out;
	}

	static function str(value:Dynamic):String {
		return value == null ? "" : Std.string(value);
	}

	static function isArrayMin(value:Dynamic, min:Int):Bool {
		if (!Std.isOfType(value, Array)) {
			return false;
		}
		return (value : Array<Dynamic>).length >= min;
	}

	static function startGame(room:GameRoom, conn:ClientConn):Void {
		// Only an in-progress round (isStarted with the song not yet ended) blocks a new game;
		// resetRound() clears the flags before the next round starts.
		if (room.state.isStarted && !room.songEnded) {
			trace('[room ' + room.roomId + '] startGame ignored (round already in progress)');
			return;
		}
		// No host check here: the play button is sent by whoever clicks it (RoomState.hx:982),
		// while song/stage/room toggles still go through canChangeRoom (host-only).
		resetRound(room);
		setRoomField(room, "isStarted", true);
		// The host receives it too: this broadcast is its own entry into the song (GameClient.hx:426).
		trace('[room ' + room.roomId + '] -> broadcast "gameStarted"');
		room.broadcast(GameRoom.frameRoomData("gameStarted", null), null);
	}

	/** Once everyone is ready, broadcast startSong so the gated countdown can begin. */
	static function maybeStartSong(room:GameRoom):Void {
		if (room.songStarted) {
			return;
		}

		var players = readyPlayers(room);
		if (players.length == 0) {
			return;
		}
		for (c in players) {
			if (!c.player.isReady) {
				// Debugging aid: log the sid of every player who has not READYed yet.
				trace('[room ' + room.roomId + '] maybeStartSong waiting for ' + c.sessionId + ' (not ready)');
				return;
			}
		}

		room.songStarted = true;
		trace('[room ' + room.roomId + '] -> broadcast "startSong" (' + players.length + ' players ready)');
		room.broadcast(GameRoom.frameRoomData("startSong", null), null);
	}

	/** Once everyone has ended, broadcast endSong (closes PlayState.canEndSongOnline). */
	static function maybeEndSong(room:GameRoom):Void {
		if (room.songEnded) {
			return;
		}

		var players = readyPlayers(room);
		if (players.length == 0) {
			return;
		}
		for (c in players) {
			if (!c.player.hasEnded) {
				return;
			}
		}

		room.songEnded = true;
		trace('[room ' + room.roomId + '] -> broadcast "endSong"');
		room.broadcast(GameRoom.frameRoomData("endSong", null), null);
	}

	// ------------------------------------------------------------------
	// New-round reset
	// ------------------------------------------------------------------

	/**
	 * Clears every room-level / player-level one-shot flag left over from the previous round and
	 * resets the shared health bar to 1. Called from the two "a new round begins" signals:
	 * applySong (host changed the song) and startGame (before entering a new round).
	 */
	static function resetRound(room:GameRoom):Void {
		room.songStarted = false;
		room.songEnded = false;

		if (room.state.isStarted) {
			setRoomField(room, "isStarted", false);
		}
		if (num(room.state.health) != 1) {
			setRoomField(room, "health", 1);
		}

		for (c in room.conns) {
			if (!c.acked || c.player == null) {
				continue;
			}
			if (c.player.isReady) {
				// The reset must reach everyone including the sender, or the local lobby still shows READY.
				setPlayerField(room, c.player, "isReady", false);
			}
			if (c.player.hasEnded) {
				setPlayerField(room, c.player, "hasEnded", false);
			}
		}
	}

	/** Invalidates everyone's hasSong on a song change: the new chart must be verified again. */
	static function invalidateHasSong(room:GameRoom):Void {
		for (c in room.conns) {
			if (!c.acked || c.player == null) {
				continue;
			}
			if (c.player.hasSong) {
				setPlayerField(room, c.player, "hasSong", false);
			}
		}
	}

	/**
	 * Shared health bar (Room.health): clients report a delta, which is accumulated and broadcast
	 * here. There is no server-side game simulation, so clients report their local health delta;
	 * both clients then see the same bar.
	 */
	static function applyHealth(room:GameRoom, message:Dynamic):Void {
		var delta:Float = num(message);
		if (delta == 0) {
			return;
		}
		var value:Float = num(room.state.health) + delta;
		if (value < 0) {
			value = 0;
		}
		if (value > 2) {
			value = 2;
		}
		setRoomField(room, "health", value);
	}

	// ------------------------------------------------------------------
	// Utilities
	// ------------------------------------------------------------------

	static function readyPlayers(room:GameRoom):Array<ClientConn> {
		var list:Array<ClientConn> = [];
		for (c in room.conns) {
			if (c.acked && c.player != null) {
				list.push(c);
			}
		}
		return list;
	}

	static function canChangeRoom(room:GameRoom, conn:ClientConn):Bool {
		return room.state.host == conn.sessionId || room.state.anarchyMode;
	}

	public static function setPlayerField(room:GameRoom, player:Player, field:String, value:Dynamic, ?except:ClientConn):Void {
		var payload = room.encoder.encodeFieldChange(player, field, value);
		room.broadcast(GameRoom.framePatch(payload), except == null ? null : except.sessionId);
	}

	public static function setRoomField(room:GameRoom, field:String, value:Dynamic, ?except:ClientConn):Void {
		var payload = room.encoder.encodeFieldChange(room.state, field, value);
		room.broadcast(GameRoom.framePatch(payload), except == null ? null : except.sessionId);
	}

	static function toggleRoomBool(room:GameRoom, conn:ClientConn, field:String):Void {
		if (!canChangeRoom(room, conn)) {
			return;
		}
		var current:Bool = cast Reflect.field(room.state, field);
		setRoomField(room, field, !current);
	}

	// ------------------------------------------------------------------
	// Side assignment (bfSide / ox)
	// ------------------------------------------------------------------

	/**
	 * Called on a new player's ack (GameRoom.onAck, before the first ADD patch): assigns the
	 * player an ox (their index on their side). The client's createScoreText() offsets by
	 * scoreTxtOriginY - ox * 20 (PlayState.hx:1354). Only the new player's value is written; all
	 * clients receive it via onAck's ADD patch / full state.
	 */
	public static function onPlayerJoined(room:GameRoom, conn:ClientConn):Void {
		var bfCount:Int = 0;
		var dadCount:Int = 0;
		for (c in room.conns) {
			if (c.player == null) {
				continue;
			}
			if (c == conn) {
				// Assign bfSide as well: the new player joins the smaller side (BF wins ties);
				// "swapSides" can still change it later.
				c.player.bfSide = bfCount <= dadCount;
				c.player.ox = c.player.bfSide ? bfCount : dadCount;
				return;
			}
			if (c.player.bfSide) {
				bfCount++;
			}
			else {
				dadCount++;
			}
		}
	}

	/** Switches the player's own `bfSide` (RoomSettingsSubstate's "Boyfriend Side"). */
	static function swapSides(room:GameRoom, conn:ClientConn):Void {
		var self:Player = conn.player;
		if (self == null) {
			return;
		}
		self.bfSide = !self.bfSide;
		setPlayerField(room, self, "bfSide", self.bfSide);
		reassignOx(room);
	}

	/** Renumbers everyone's `ox` after a side change (join order within each side) and broadcasts only changes. */
	public static function reassignOx(room:GameRoom):Void {
		var bfCount:Int = 0;
		var dadCount:Int = 0;
		for (c in room.conns) {
			if (!c.acked || c.player == null) {
				continue;
			}
			var newOx:Int = c.player.bfSide ? bfCount : dadCount;
			if (c.player.bfSide) {
				bfCount++;
			}
			else {
				dadCount++;
			}
			if (num(c.player.ox) != newOx) {
				c.player.ox = newOx;
				setPlayerField(room, c.player, "ox", newOx);
			}
		}
	}

	static function addHitJudge(room:GameRoom, player:Player, rating:Dynamic):Void {
		var field:String = switch (Std.string(rating)) {
			// Ratings.hx has 5 tiers but the Player schema has 4 counters, so marvelous counts
			// as sick.
			case "marvelous", "sick": "sicks";
			case "good": "goods";
			case "bad": "bads";
			case "shit": "shits";
			default: null;
		}
		if (field == null) {
			return;
		}
		setPlayerField(room, player, field, num(Reflect.field(player, field)) + 1);
	}

	static function isLoggedMessage(typeName:String):Bool {
		switch (typeName) {
			case "verifyChart", "setSong", "setStage", "startGame", "playerReady", "playerEnded",
				"requestEndSong", "setSkin", "updateNoteSkinData", "custom", "customTo", "chat", "command",
				"notifyInstall", "nextWinCondition", "swapSides":
				return true;
			default:
				return false;
		}
	}

	static function forward(room:GameRoom, conn:ClientConn, typeName:String, message:Dynamic):Void {
		room.broadcast(GameRoom.frameRoomData(typeName, [conn.sessionId, message]), conn.sessionId);
	}

	static function num(value:Dynamic):Float {
		if (value == null) {
			return 0;
		}
		switch (Type.typeof(value)) {
			case TInt:
				return cast(value, Int);
			case TFloat:
				return cast(value, Float);
			default:
				var parsed = Std.parseFloat(Std.string(value));
				return Math.isNaN(parsed) ? 0 : parsed;
		}
	}

	static function toBool(value:Dynamic):Bool {
		if (value == null) {
			return false;
		}
		switch (Type.typeof(value)) {
			case TBool:
				return cast(value, Bool);
			default:
				return Std.string(value) == "true";
		}
	}
}
