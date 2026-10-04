package online_server;

import online_server.GameRoom.ClientConn;
import online_server.GameRoom.SessionRecord;

/**
 * Business layer for the network room (roomId is always '0'). Message handling matches the
 * client listeners in source/online/NetworkClient.hx:69-118. Without accounts, identity falls
 * back to the join-options name: name -> networkId -> sessionId (see GameRoom.networkIdentity).
 */
class NetworkLogic {
	/**
	 * Handshake version for the network room, kept in sync with ServerHub.NETWORK_VERSION and
	 * the client's Main.NETWORK_PROTOCOL.
	 */
	public static inline var PROTOCOL_VERSION:Int = 1;
	/** History cap: the most recent 100 entries. */
	public static inline var MAX_LOGGED:Int = 100;

	/** Chat history as `[content, date]`, capped at 100 entries. */
	public static var loggedMessages:Array<{content:String, date:Float}> = [];

	/** Read-only diagnostic: number of retained history entries (used by tests). */
	public static function loggedCount():Int {
		return loggedMessages.length;
	}

	public static function handle(room:GameRoom, conn:ClientConn, type:Dynamic, message:Dynamic):Void {
		var typeName:String = Std.string(type);
		var record:SessionRecord = room.sessionOf(conn.sessionId);
		if (record != null) {
			record.aliveTime = haxe.Timer.stamp();
		}

		switch (typeName) {
			case "chat":
				applyChat(room, conn, record, message);
			case "loggedMessagesAfter":
				applyLoggedMessagesAfter(room, conn, message);
			case "inviteplayertoroom":
				applyInvitePlayerToRoom(room, conn, record, message);
			case "pong":
				// The network room sends no business ping (GameRoom.tick skips isNetwork), but
				// the client may still answer a PING frame with a pong -- just record it.
				if (record != null) {
					record.lastPing = haxe.Timer.stamp();
				}
			default:
				// Unknown message types are ignored, never broadcast.
		}
	}

	// ------------------------------------------------------------------
	// chat
	// ------------------------------------------------------------------

	static function applyChat(room:GameRoom, conn:ClientConn, record:SessionRecord, message:Dynamic):Void {
		if (!Std.isOfType(message, String)) {
			return;
		}

		// Newlines become spaces; there is no word-list filter here.
		var text:String = (message : String).split("\n").join(" ");
		if (ServerConfig.utf8Length(text) > 300) {
			// Exactly 300 CHARACTERS is allowed; only longer messages are rejected. String.length
			// counts UTF-8 bytes on neko/hxcpp, which capped Chinese chat at 100 characters.
			sendLog(room, "Message length reached!", conn);
			return;
		}

		var identity:String = room.networkIdentity(record);
		if (identity == null || identity == "") {
			// A missing identity mapping means unauthorized: kick.
			room.kickNetwork(conn);
			return;
		}

		text = StringTools.trim(text);
		if (text.length <= 0) {
			return;
		}

		if (StringTools.startsWith(text, ">")) {
			// Direct message: `>{user} {msg}`
			var parts:Array<String> = text.split(" ");
			var target:String = parts.shift().substr(1);
			var msg:String = parts.join(" ");
			if (msg.length <= 0) {
				return;
			}
			var to:ClientConn = room.networkConnOf(target);
			if (to != null) {
				sendLog(room, "[" + identity + "->YOU]: " + msg, to, 40, true);
				sendLog(room, "[YOU->" + target + "]: " + msg, conn, 40);
			} else {
				sendLog(room, "Player not found!", conn);
			}
			return;
		}

		if (StringTools.startsWith(text, "/")) {
			if (StringTools.startsWith(text, "/list")) {
				// The online list goes only to the sender.
				var names:Array<String> = room.networkNamesList();
				sendLog(room, "Online: " + names.join(", "), conn);
			} else if (StringTools.startsWith(text, "/help")) {
				sendLog(room, HELP_TEXT, conn);
			} else if (StringTools.startsWith(text, "/announce")) {
				// /announce needs command.announce access, which requires an account; without
				// one the caller counts as non-admin, so the command is silently ignored.
				trace('[network] /announce ignored (no account system yet)');
			} else {
				sendLog(room, "Command not found! (Try /help)", conn);
			}
			return;
		}

		// ordinary broadcast
		var hue:Float = 250; // default profile hue when there is no account
		logToAll(room, formatLog(identity + ": " + text, hue), true);
		// Mirror the chat line to Discord (webhook, with the sender's nickname).
		DiscordBridge.sendWebhookMessage(text, identity);
	}

	static inline var HELP_TEXT:String = "DM players with the following format >{user} {message}\nSee the online player list with /list!\nIf you want to receive notifications for all messages then type /notify!\nTo view someone's profile use /profile <user>";

	// ------------------------------------------------------------------
	// loggedMessagesAfter
	// ------------------------------------------------------------------

	static function applyLoggedMessagesAfter(room:GameRoom, conn:ClientConn, message:Dynamic):Void {
		// The client sends `Date.now().toString()` (a string); parse it to a number.
		var after:Float = 0;
		if (message != null) {
			var n:Float = Std.parseFloat(Std.string(message));
			if (!Math.isNaN(n)) {
				after = n;
			}
		}

		var out:Array<String> = [];
		for (m in loggedMessages) {
			if (m.date > after) {
				out.push(m.content);
			}
		}
		// batchLog's payload is a JSON array string, not an object.
		room.send(conn, GameRoom.frameRoomData("batchLog", ServerConfig.jsonEncode(out)));
	}

	// ------------------------------------------------------------------
	// inviteplayertoroom
	// ------------------------------------------------------------------

	static function applyInvitePlayerToRoom(room:GameRoom, conn:ClientConn, record:SessionRecord, message:Dynamic):Void {
		if (!Std.isOfType(message, String)) {
			return;
		}
		var target:String = (message : String);
		var identity:String = room.networkIdentity(record);
		if (identity == null || identity == "") {
			room.send(conn, GameRoom.frameRoomData("notification", "Authorization Error"));
			room.kickNetwork(conn);
			return;
		}

		var to:ClientConn = room.networkConnOf(target);
		if (to == null) {
			room.send(conn, GameRoom.frameRoomData("notification", "Player isn't online in-game!"));
			return;
		}

		// Only "target is online" is required here: friend checks and a cooldown need accounts
		// and cross-room queries. roomid comes from GameRoom.gameRoomOfPlayer (maintained by
		// onAck/removePlayer), empty when unknown.
		var roomId:String = GameRoom.gameRoomOfPlayer.get(identity.toLowerCase());
		if (roomId == null) {
			roomId = "";
		}

		// The recipient reads inviteData.name / inviteData.roomid.
		room.send(to, GameRoom.frameRoomData("roominvite", ServerConfig.jsonEncode({
			name: identity,
			roomid: roomId
		})));
		room.send(conn, GameRoom.frameRoomData("notification", "Invite sent!"));
	}

	// ------------------------------------------------------------------
	// helpers
	// ------------------------------------------------------------------

	/** Builds a `log` payload; it is a JSON string, not an object. */
	public static function formatLog(content:String, ?hue:Float, isPM:Bool = false):String {
		return ServerConfig.jsonEncode({
			content: content,
			hue: hue,
			date: Date.now().getTime(),
			isPM: isPM
		});
	}

	/** Broadcasts or targets one `log`. */
	public static function sendLog(room:GameRoom, content:String, ?to:ClientConn, ?hue:Float, isPM:Bool = false):Void {
		var frame = GameRoom.frameRoomData("log", formatLog(content, hue, isPM));
		if (to != null) {
			room.send(to, frame);
		} else {
			room.broadcast(frame, null);
		}
	}

	/** Appends to history (capped at 100) and broadcasts a `log`. */
	public static function logToAll(room:GameRoom, content:String, ?notDiscord:Bool = false):Void {
		loggedMessages.push({content: content, date: Date.now().getTime()});
		if (loggedMessages.length > MAX_LOGGED) {
			loggedMessages.shift();
		}
		room.broadcast(GameRoom.frameRoomData("log", content), null);
		// content is itself a formatLog JSON string, so the mirror extracts its content field.
		// notDiscord = true means the line came from Discord (or the caller asked not to echo
		// it), so it is not sent back.
		if (!notDiscord && DiscordBridge.available()) {
			var text = content;
			try {
				var inner = Reflect.field(haxe.Json.parse(content), "content");
				if (inner != null) text = Std.string(inner);
			} catch (e:Dynamic) {}
			DiscordBridge.sendNetworkMessage(text);
		}
	}
}
