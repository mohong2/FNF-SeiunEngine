package online;

import haxe.Json;
// This engine has no online/gui/sidebar/**, so the ChatTab import and its 5 call sites were
// replaced by `trace` of the same text; nothing in this room path reads the sidebar.
import online.GameClient.Error;
import online.backend.schema.NetworkSchema;
import online.network.Auth;
import online.util.OnlineLang;
import io.colyseus.Client;
import io.colyseus.Room;

class NetworkClient {
	@:unreflective
	public static var client:Client;
	public static var room:Room<NetworkSchema>;
    public static var connecting:Bool = false;

	public static function leave() {
		if (room != null) {
			room.leave();
			room = null;
		}
		client = null;
		connecting = false;
	}

	public static function connect() {
		if (connecting || NetworkClient.room != null)
            return;

		GameClient.asyncUpdateAddresses();

		connecting = true;
		var client = new Client(GameClient.networkServerAddress);
		#if ONLINE_ALLOWED
		// NetworkClient.client was never assigned: the `var client` below shadows the static field,
		// while onLeave's `client.reconnect(...)` reads the static one. A null receiver then reads
		// this.http at object offset 0x10 -> ACCESS_VIOLATION (fault addr 0x10 matches). Mirror the
		// local value into the static field.
		NetworkClient.client = client;
		#end

		Thread.run(() -> {
			client.joinById('0', [
				"protocol" => Main.NETWORK_PROTOCOL,
			// Same handshake as game rooms, with the network magic.
			"engine" => Protocol.NETWORK_MAGIC,
				"networkId" => Auth.authID,
				"networkToken" => Auth.authToken,
				#if ONLINE_ALLOWED
				// This server has no account system, so identity is a temporary local nickname.
				// The server's fallback order is name -> networkId -> sessionId
				// (GameRoom.networkIdentity).
				"name" => ClientPrefs.getNickname(),
				#end
			], NetworkSchema, (err, room) -> {
				joinCallback(err, room);
            });
		}, (exc) -> {
			connecting = false;
            trace(ShitUtil.prettyError(exc));
		});
    }

	static function joinCallback(err:Error, room:Room<NetworkSchema>, ?reconnect:Bool = false) {
		connecting = false;
		NetworkClient.room = null;
        if (err != null) {
			Waiter.putPersist(() -> {
				trace('Failed to connect to the network chatroom! (Reopen this tab to try again)');
			});
            //trace(err);
            return;
        }

		Waiter.putPersist(() -> {
			trace('Connected to the network chatroom!');
        });

		NetworkClient.room = room;

		#if ONLINE_ALLOWED
		// Same convergence as GameClient.disableLibraryAutoReconnect(): the network room's library
		// auto-reconnect (Room.retryReconnection, 15 attempts) and onLeave's client.reconnect (HTTP
		// matchmaking) are two paths. Zeroing the retry budget makes onDrop report
		// onLeave(FAILED_TO_RECONNECT) (Room.hx:394-399) immediately, leaving HTTP only.
		room.reconnection.maxRetries = 0;
		room.reconnection.isReconnecting = false;
		room.reconnection.retryCount = 0;
		#end

		room.onMessage("log", function(message) {
			Waiter.putPersist(() -> {
				trace(message);
			});
		});

		room.onMessage("batchLog", function(message) {
			var logs:Array<String> = Json.parse(message);
			Waiter.putPersist(() -> {
				for (log in logs) {
					trace(log);
				}
			});
		});

		room.onMessage("notification", function(message) {
			Waiter.putPersist(() -> {
				Alert.alert(message);
			});
		});

		room.onMessage("roominvite", function(message:String) {
			if (message == null || ClientPrefs.data.disableRoomInvites)
				return;
			var inviteData = Json.parse(message);

			Waiter.putPersist(() -> {
				Alert.alert(inviteData.name + OnlineLang.L('net.invited', ' has invited you to their room!'), OnlineLang.L('net.clickToJoin', '(Click to Join)'), () -> {
					OnlineState.inviteRoomID = inviteData.roomid;

					if (GameClient.isConnected()) {
						GameClient.leaveRoom('Switching States');
					}
					else {
						Waiter.putPersist(() -> {
							FlxG.switchState(new OnlineState());
						});
					}
				});
			});
		});

		room.onMessage("friendOnlineNotif", function(player:String) {
			if (player == null || !ClientPrefs.data.friendOnlineNotification)
				return;

			Waiter.putPersist(() -> {
				Alert.alert(player + OnlineLang.L('net.friendOnline', ' is now online!'), null);
			});
		});

		room.onError += (code:Int, e:String) -> {
			Thread.safeCatch(() -> {
				Sys.println("NetworkRoom.onError: " + code + " - " + e);
				if (code == 524)
					return;
				Alert.alert(OnlineLang.L('net.roomError', 'Network Room error!'), "room.onError: " + ShitUtil.prettyStatus(code) + "\n" + ShitUtil.readableError(e));
            }, e -> {
				trace(ShitUtil.prettyError(e));
            });
		}

		room.onLeave += (code) -> {
			Thread.safeCatch(() -> {
				trace(code);

				Waiter.putPersist(() -> {
					trace('Disconnected from the chatroom');
				});

				#if ONLINE_ALLOWED
				// Defense in depth: no path may call client.reconnect on null (see connect()).
				// An explicit leave() nulls room / client, and onLeave can arrive asynchronously.
				if (client == null || NetworkClient.room == null) {
					connecting = false;
					return;
				}
				#end

				var recToken = NetworkClient.room.reconnectionToken;
				NetworkClient.room = null;

				Thread.safeCatch(() -> {
					trace("Left/Kicked from the Network room!");

					connecting = true;
					client.reconnect(recToken, NetworkSchema, (err, newRoom) -> {
						trace("Reconnecting to the Network room");
						joinCallback(err, newRoom, true);
					});
				}, e -> {
					NetworkClient.room = null;
					connecting = false;
					trace(ShitUtil.prettyError(e));
				});
			}, e -> {
				trace(ShitUtil.prettyError(e));
			});
		}

		// Cursor for "messages after this timestamp". This client keeps no chat log, so send
		// the equivalent "now" cursor.
		room.send('loggedMessagesAfter', Date.now().toString());

        trace("Joined Network Room!");
    }
}