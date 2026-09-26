package online_server;

import haxe.Http;
import haxe.Json;
import sys.thread.Thread;

/**
 * Outbound-only Discord webhook bridge: POSTs mirror network-room chat. Inbound and
 * /matchmake are not implemented (no Discord Gateway client in Haxe 4.2.5, no new
 * dependencies allowed). Switch: --discord-webhook; unconfigured means all calls no-op.
 */
class DiscordBridge {
	static var webhookUrl:String = null;

	public static function init(?url:String):Void {
		webhookUrl = (url != null && StringTools.trim(url) != "") ? StringTools.trim(url) : null;
	}

	public static function available():Bool return webhookUrl != null;

	/** Defuses <@ / @everyone / @here mention injection. */
	public static function filterText(content:String):String {
		if (content == null) return null;
		var out = content.split("<@").join("?");
		out = out.split("@everyone").join("?");
		out = out.split("@here").join("?");
		return out;
	}

	/** Mirrors one network-room chat message out. */
	public static function sendNetworkMessage(content:String):Void {
		if (!available() || content == null) return;
		post({ content: filterText(content) });
	}

	/** Sends a message with a nickname; no avatar URL is configured. */
	public static function sendWebhookMessage(content:String, ?username:String):Void {
		if (!available() || content == null) return;
		var body:Dynamic = { content: filterText(content) };
		if (username != null && username != "") Reflect.setField(body, "username", username);
		post(body);
	}

	static function post(body:Dynamic):Void {
		var url = webhookUrl;
		var text = Json.stringify(body);
		// Outbound delivery runs on its own thread so chat is never blocked by a slow / dead webhook.
		Thread.create(function() {
			try {
				var http = new Http(url);
				http.setHeader("content-type", "application/json");
				http.setPostData(text);
				http.onStatus = function(_s:Int) {};
				http.onError = function(e:String) trace('[discord] webhook failed: ' + e);
				http.request(true);
			} catch (e:Dynamic) {
				trace('[discord] webhook failed: ' + Std.string(e));
			}
		});
	}
}
