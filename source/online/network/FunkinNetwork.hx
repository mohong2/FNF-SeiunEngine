package online.network;

import openfl.Assets;
import online.http.HTTPClient;
import haxe.io.BytesOutput;
import openfl.display.BitmapData;
import online.http.HTTPHandler;
import haxe.CallStack;
import openfl.net.FileReference;
import haxe.io.Bytes;
import haxe.crypto.Base64;
import lime.ui.FileDialog;
import haxe.Http;
import haxe.Json;
import online.objects.NicommentsView.SongComment;
import haxe.ds.Either;
import online.util.OnlineLang;

@:unreflective
class FunkinNetwork {
	public static var client:HTTPHandler = null;
	public static var nickname(default, null):String = null;
	public static var points(default, null):Float = 0;
	public static var avgAccuracy(default, null):Float = 0;
	public static var profileHue(default, null):Float = 0;
	public static var loggedIn:Bool = false;
	public static var access:Array<String> = [];

	public static function requestLogin(email:String, ?code:String) {
		var response = requestAPI({
			path: "/api/auth/login",
			headers: ["content-type" => "application/json"],
			// JsonSafe, not haxe.Json: cpp's printer turns a non-BMP character (emoji) into two
			// U+FFFD bytes, which would mangle a nickname/bio/message sent from the game.
			body: JsonSafe.stringify({
				email: email,
				code: code,
				// The per-server switches are decided before logging in; a server that pins its
				// own lifetime simply ignores these.
				remember: Auth.remember(),
				ttlMinutes: Auth.ttlMinutes()
			}),
			post: true
		});

		if (response == null || response.isFailed())
			return false;

		if (code != null)
			saveCredentials(Json.parse(response.getString()));

		return true;
	}

	public static function setEmail(email:String, ?code:String) {
		var emailSplit = email.trim().split(' from ');

		var response = requestAPI({
			path: "/api/account/email/set",
			headers: ["content-type" => "application/json"],
			body: JsonSafe.stringify({
				email: emailSplit[0].trim(),
				old_email: emailSplit[1].trim(),
				code: code
			}),
			post: true
		});

		if (response == null || response.isFailed())
			return false;

		return true;
	}

	public static function deleteAccount(?code:String) {
		var response = requestAPI("/api/account/delete" + (code != null ? '?code=' + code : ''));

		if (response == null || response.isFailed())
			return false;

		if (code != null) {
			logout();
		}
		return true;
	}

	public static function logout() {
		Auth.save(null, null);
		loggedIn = false;
		nickname = null;
		points = 0;
		NetworkClient.leave();
	}

	/**
	 * Automatic-login path: reuse the stored credential (Basic header) to ask for a fresh token.
	 * The server accepts it inside its refresh grace window even after the credential expired;
	 * on refusal the credential is dropped and the player is told to log in again.
	 */
	public static function refreshLogin():Bool {
		if (Auth.authID == null || Auth.authToken == null)
			return false;

		var response = requestAPI({
			path: "/api/auth/refresh",
			headers: ["content-type" => "application/json"],
			body: JsonSafe.stringify({
				remember: Auth.remember(),
				ttlMinutes: Auth.ttlMinutes()
			}),
			post: true
		}, false);

		if (response == null || response.isFailed()) {
			expireSession();
			return false;
		}

		saveCredentials(Json.parse(response.getString()), false);
		return true;
	}

	/** The server's "that credential is gone" answer (401 + expired:true). */
	static function isExpiredResponse(response:HTTPResponse):Bool {
		if (response == null || response.status != 401)
			return false;
		try {
			var body:Dynamic = Json.parse(response.getString());
			return body != null && Reflect.hasField(body, 'expired') && body.expired == true;
		} catch (e:Dynamic) {
			return false;
		}
	}

	/** Drop a dead credential and say why the player has to log in again. */
	static function expireSession():Bool {
		Auth.clear();
		nickname = null;
		points = 0;
		Waiter.putPersist(() -> Alert.alert(
			OnlineLang.L('net.sessionExpired', 'Session expired'),
			OnlineLang.L('net.sessionExpired.desc', 'Log in again with a new code.')));
		return loggedIn = false;
	}

	public static function ping():Bool {
		if (Auth.authID == null || Auth.authToken == null)
			return loggedIn = false;

		// The stored credential carries a date. Past it, refreshing is what "remember me / auto
		// login" buys; without auto login it is dropped with a prompt.
		if (Auth.expired()) {
			if (!Auth.autoLogin())
				return expireSession();
			if (!refreshLogin())
				return loggedIn = false;
		}

		var response = requestAPI("/api/account/me", false);

		// The server has the last word: a 401 marked expired also covers credentials that were
		// rotated or dropped elsewhere while the local date had not passed yet.
		if (isExpiredResponse(response) && Auth.autoLogin()) {
			if (!refreshLogin())
				return loggedIn = false;
			response = requestAPI("/api/account/me", false);
		}

		if (response == null || response.isFailed())
			return loggedIn = false;

		var json = Json.parse(response.getString());
		nickname = json.name;
		points = json.points;
		avgAccuracy = json.avgAccuracy;
		profileHue = json.profileHue;
		access = json.access;
		loggedIn = true;
		// Keep a display name next to the per-server credential so the server list can show which
		// account is logged in without an extra request.
		Auth.setAccountName(nickname);
		NetworkClient.connect();
		return loggedIn;
	}

	public static function requestRegister(username:String, email:String, ?code:String) {
		var response = requestAPI({
			path: "/api/auth/register",
			headers: ["content-type" => "application/json"],
			body: JsonSafe.stringify({
				username: username,
				email: email,
				code: code
			}),
			post: true
		});

		if (response == null || response.isFailed())
			return false;

		if (code != null)
			saveCredentials(Json.parse(response.getString()));

		return true;
	}

	static function saveCredentials(json:Dynamic, ?doPing:Bool = true) {
		trace("Saving credentials");
		Auth.saveLogin(json);
		// new FileReference().save(json.id + "\n" + json.secret, "recovery_token.txt");
		if (doPing)
			ping();

		Waiter.putPersist(() -> {
			// Open the sidebar once a credential exists. Guarded on `instance` because the
			// overlay is created in Main.main() and may not exist in a headless build.
			var side = online.gui.sidebar.SideUI.instance;
			if (side != null && !side.active)
				side.active = true;
		});
	}

    // public static function postResults(path:String) {
	// 	var http = new Http(API_URL + "/api/rankings/post");
	// 	var input = File.read(path);
	// 	http.fileTransfer("replay", "replay.funkinreplay", input, FileSystem.stat(path).size);
	// 	http.request(true);
	// 	input.close();
    // }

	public static function updateName(name:String):String {
		var response = requestAPI({
			path: "/api/account/rename",
			headers: ["content-type" => "application/json"],
			body: JsonSafe.stringify({
				username: name
			}),
			post: true
		});

		if (response == null || response.isFailed())
			return nickname;

		return nickname = response.getString();
	}

	public static function postFrontMessage(message:String):Bool {
		var response = requestAPI({
			path: "/api/sez",
			headers: ["content-type" => "application/json"],
			body: JsonSafe.stringify({
				message: message
			}),
			post: true
		});

		if (response == null || response.isFailed())
			return false;

		return true;
	}

	public static function fetchFront():Dynamic {
		var response = requestAPI("/api/front", false);

		if (response == null || response.isFailed())
			return null;

		try {
			return Json.parse(response.getString());
		}
		catch (exc) {
			trace(exc);
			return null;
		}
	}

	public static function fetchSongComments(songId:String):Array<SongComment> {
		var response = requestAPI("/api/song/comments?id=" + StringTools.urlEncode(songId), false);

		if (response == null || response.isFailed())
			return null;

		try {
			return Json.parse(response.getString());
		}
		catch (exc) {
			trace(exc);
			return null;
		}
	}

	public static function postSongComment(songId:String, content:String, at:Float):Array<SongComment> {
		var response = requestAPI({
			path: "/api/song/comment",
			headers: ["content-type" => "application/json"],
			body: JsonSafe.stringify({
				id: songId,
				content: content,
				at: at
			}),
			post: true
		});

		if (response == null || response.isFailed())
			return null;

		try {
			return Json.parse(response.getString());
		}
		catch (exc) {
			trace(exc);
			return null;
		}
	}

	public static function searchMods(query:String, page:Int, sort:String):Array<PEOMod> {
		// Haxe 4.2.5 has no null-coalescing; expand `query ?? ''`.
		var response = requestAPI("/api/search/mods?q=" + StringTools.urlEncode(query != null ? query : '') + "&page=" + page + (sort != null ? '&sort=' + sort : ''));

		if (response == null)
			return null;

		try {
			return Json.parse(response.getString());
		}
		catch (exc) {
			trace(exc);
			return null;
		}
	}

	public static function fetchMod(id:String):PEOModDetailed {
		if (id == null)
			return null;

		var response = requestAPI("/api/mod/details/" + StringTools.urlEncode(id));

		if (response == null)
			return null;

		try {
			return Json.parse(response.getString());
		}
		catch (exc) {
			trace(exc);
			return null;
		}
	}

	public static function fetchUserInfo(user:String):Dynamic {
		if (user == null)
			return null;

		var response = requestAPI("/api/user/info?name=" + StringTools.urlEncode(user));

		if (response == null)
			return null;

		try {
			return Json.parse(response.getString());
		}
		catch (exc) {
			trace(exc);
			return null;
		}
	}

	public static var cacheAvatar:Map<String, Bytes> = [];
	public static function getUserAvatar(user:String):Bytes {
		if (cacheAvatar.exists(user)) {
			var bytes = cacheAvatar.get(user);
			return bytes;
		}

		var avatarResponse = FunkinNetwork.requestAPI('/api/user/avatar/' + StringTools.urlEncode(user), false);
#if ONLINE_ALLOWED
		// requestAPI() returns null when the HTTP handler is missing (offline box), which the old
		// code assumed could never happen; dereferencing null here is a native crash on cpp.
		if (avatarResponse == null || avatarResponse.isFailed())
			return null;
#end

		// Haxe 4.2.5 has no safe-navigation or null-coalescing; `avatarResponse` is non-null here
		// (`.isFailed()` above already dereferenced it).
		var bytes = avatarResponse != null ? avatarResponse.getBytes() : null;
		if (bytes == null || !ShitUtil.isSupportedImage(bytes)) {
			cacheAvatar.set(user, null);
			return null;
		}

		try {
			cacheAvatar.set(user, bytes);
			return bytes;
		}
		catch (exc) {
			trace(exc);
			return null;
		}
	}

	public static function getDefaultAvatar():BitmapData {
		return Assets.getBitmapData('assets/images/' + 'bf' + FlxG.random.int(1, 2) + '.png');
	}

	public static function requestAPI(data:OneOf<HTTPRequest, String>, ?alertError:Bool = true):Null<HTTPResponse> {
		GameClient.asyncUpdateAddresses();

		var request:HTTPRequest;

		switch (data) {
			case Left(v):
				request = v;
			case Right(v):
				request = {
					path: v
				};
			case null:
				request = {};
		}

		if (request.headers == null)
			request.headers = new Map<String, String>();

		if (Auth.authID != null && Auth.authToken != null)
			request.headers.set("authorization", Auth.getAuthHeader());
		
#if ONLINE_ALLOWED
		// Keep a hard guard so a null handler can never become a native null dereference again
		// (the crash was exactly client.request(...) with client == null).
		if (client == null)
			return null;
#end
		var response = client.request(request);

		if (response.isFailed()) {
			if (alertError) {
				// Read the body once: getString() goes through getBytes(), which closes the underlying
				// buffer, so a second call reads freed memory (native ACCESS_VIOLATION in
				// BytesBuffer.getBytes / BytesOutput.getBytes). Resolve every field here, then the
				// closure captures plain values only.
				var networkErrorBody:String = null;
				var networkErrorTitle:String = null;
				var networkErrorDetails:Dynamic = null;
				try {
					networkErrorBody = response.getString();
					networkErrorTitle = response.getErrorTitle();
					networkErrorDetails = response.exception != null ? response.getErrorDetails() : (
						networkErrorBody != null && networkErrorBody.ltrim().startsWith("{")
							? Json.parse(networkErrorBody).error : networkErrorBody
					);
				} catch (e:Dynamic) {
					networkErrorDetails = networkErrorBody != null ? networkErrorBody : Std.string(e);
				}
				Waiter.putPersist(() -> Alert.alert(
					networkErrorTitle != null ? networkErrorTitle : OnlineLang.L('net.requestFailed', 'Request failed'),
					networkErrorDetails));
			}
			return response;
		}

		return response;
	}

	public static function hasAccess(to:String) {
		for (perm in access)
			if (matchWildcard(perm, to))
				return true;
		return false;
	}

	private static function matchWildcard(wildString:String, to:String) {
		final wildIndex = wildString.indexOf('*');
		if (wildIndex == -1)
			return wildString == to;
		return wildString.substr(0, wildIndex) == to.substr(0, wildIndex);
	}
}

typedef PEOMod = {
	id: String,
	images: Array<String>,
	title: String,
	keywords: Array<String>,
	downloadHits: Float,
	favoritedCount: Float,
}

typedef PEOModDetailed = {
	>PEOMod,
	submitted: String,
	favorited: Array<String>,
	description: String,
	downloads: Array<PEOModDownload>,
}

typedef PEOModDownload = {
	id: String,
	urls: Array<String>,
	hits: Float,
	size: Float,
	modID: String
}