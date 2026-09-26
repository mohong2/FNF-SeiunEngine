package online_server;

import haxe.Http;
import haxe.Json;

/**
 * Newgrounds gateway_v3.php client (App.startSession / App.checkSession / App.endSession).
 * haxe.Http is used with --ng-app-id <id> (no .env is read). Any failure becomes a 400 in the
 * handler's catch.
 */
class Ngio {
	public static inline var GATEWAY:String = "https://www.newgrounds.io/gateway_v3.php";

	static var appId:String = null;

	public static function init(?id:String):Void {
		appId = (id != null && StringTools.trim(id) != "") ? StringTools.trim(id) : null;
	}

	public static function available():Bool return appId != null;

	/**
	 * Request shape: form field request=<JSON.stringify({app_id, execute, session_id})> POSTed
	 * to the gateway as x-www-form-urlencoded. A non-200 status or empty body throws 'NG Refused';
	 * a non-true success throws the returned error; otherwise result.data is returned.
	 */
	public static function request(execute:Dynamic, ?sessionId:String):Dynamic {
		if (!available()) throw 'NG not configured';

		var payload = {
			app_id: appId,
			execute: execute,
			session_id: sessionId
		};
		var form = "request=" + StringTools.urlEncode(Json.stringify(payload));

		var status = 0;
		var body:String = null;
		var errored:String = null;
		try {
			var http = new Http(GATEWAY);
			http.setHeader("content-type", "application/x-www-form-urlencoded");
			http.setPostData(form);
			http.onStatus = function(s:Int) status = s;
			http.onData = function(d:String) body = d;
			http.onError = function(e:String) errored = e;
			http.request(true);
		} catch (e:Dynamic) {
			throw 'NG request failed: ' + Std.string(e);
		}

		if (errored != null) throw 'NG request failed: ' + errored;
		if (status != 200 || body == null || StringTools.trim(body) == "") throw 'NG Refused';

		var parsed:Dynamic = null;
		try parsed = Json.parse(body) catch (e:Dynamic) throw 'NG Refused';
		if (parsed == null || Reflect.field(parsed, "success") != true) {
			throw (parsed != null ? Reflect.field(parsed, "error") : 'NG Refused');
		}
		var result = Reflect.field(parsed, "result");
		return result != null ? Reflect.field(result, "data") : null;
	}
}
