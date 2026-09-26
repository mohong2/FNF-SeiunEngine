package online_server;

import haxe.io.Bytes;
import sys.net.Host;
import sys.net.Socket;
import sys.thread.Thread;

typedef HttpRequest = {
	var method:String;
	var path:String;
	var query:String;
	var headers:Map<String, String>;
	var body:String;
	/** Raw request body bytes, for binary uploads (multipart); JSON still uses body. */
	var ?bodyBytes:Bytes;
	/** Request source IP (peer.host); used by IP accounting and session records. */
	var ip:String;
}

typedef HttpResponse = {
	var status:Int;
	var contentType:String;
	var body:String;
	/** Binary response body (/api/club/banner/:tag); takes precedence over body when set. */
	var ?bodyBytes:Bytes;
	/**
	 * Extra response headers, used for the 302 + Location of GET /mod/:mod_id/dl/:dl_id.
	 * Optional, so existing construction sites are unchanged.
	 */
	var ?headers:Map<String, String>;
}

/**
 * Minimal HTTP/1.1 server for the matchmaking handshake and the REST endpoints.
 * Each connection gets its own thread; `Connection: close` means no keep-alive.
 */
class HttpServer {
	var listenSocket:Socket;
	var handler:HttpRequest->HttpResponse;

	public function new(host:String, port:Int, handler:HttpRequest->HttpResponse) {
		this.handler = handler;

		listenSocket = new Socket();
		listenSocket.bind(new Host(host), port);
		listenSocket.listen(32);
	}

	public function start():Void {
		Thread.create(acceptLoop);
	}

	function acceptLoop():Void {
		while (true) {
			try {
				var client = listenSocket.accept();
				Thread.create(function() handleClient(client));
			} catch (e:Dynamic) {
				Sys.sleep(0.01);
			}
		}
	}

	function handleClient(client:Socket):Void {
		try {
			var request = readRequest(client);
			if (request == null) {
				client.close();
				return;
			}

			var response = handler(request);
			writeResponse(client, response);

		} catch (e:Dynamic) {
			try {
				writeResponse(client, {
					status: 500,
					contentType: "application/json",
					body: '{"error":"' + Std.string(e) + '"}'
				});
			} catch (_:Dynamic) {}
		}

		try {
			client.close();
		} catch (_:Dynamic) {}
	}

	function readRequest(client:Socket):HttpRequest {
		var input = client.input;

		var requestLine = input.readLine();
		if (requestLine == null || requestLine == "") {
			return null;
		}

		var parts = requestLine.split(" ");
		if (parts.length < 2) {
			return null;
		}

		var headers = new Map<String, String>();
		while (true) {
			var line = input.readLine();
			if (line == null || line == "") {
				break;
			}
			var idx = line.indexOf(":");
			if (idx > 0) {
				headers.set(line.substr(0, idx).toLowerCase(), StringTools.trim(line.substr(idx + 1)));
			}
		}

		var body = "";
		var bodyBytes:Bytes = null;
		if (headers.exists("content-length")) {
			var len = Std.parseInt(headers.get("content-length"));
			if (len != null && len > 0) {
				// Keep the raw bytes first (multipart uploads), then expose them as a string for JSON.
				bodyBytes = input.read(len);
				body = bodyBytes.toString();
			}
		}

		var path = parts[1];
		var query = "";
		var qIdx = path.indexOf("?");
		if (qIdx >= 0) {
			query = path.substr(qIdx + 1);
			path = path.substr(0, qIdx);
		}

		return {
			method: parts[0],
			path: path,
			query: query,
			headers: headers,
			body: body,
			bodyBytes: bodyBytes,
			ip: peerIp(client)
		};
	}

	/** peer() gives the remote address (neko/sys Socket); degrade to an empty string if unavailable. */
	static function peerIp(client:Socket):String {
		try {
			var peer = client.peer();
			if (peer != null && peer.host != null) {
				return peer.host.toString();
			}
		} catch (e:Dynamic) {}
		return "";
	}

	function writeResponse(client:Socket, response:HttpResponse):Void {
		// Binary responses (club banners) use bodyBytes; everything else still uses the body string.
		var bytes = response.bodyBytes != null ? response.bodyBytes : Bytes.ofString(response.body);
		var lines = [
			'HTTP/1.1 ${response.status} ${statusText(response.status)}',
			'Content-Type: ${response.contentType}',
			'Content-Length: ${bytes.length}',
			'Connection: close'
		];
		// Extra response headers (the 302 Location). Map iteration order is unspecified, but there is only one.
		if (response.headers != null) {
			for (name in response.headers.keys()) {
				lines.push(name + ': ' + response.headers.get(name));
			}
		}
		lines.push('');
		lines.push('');
		var head = lines.join("\r\n");

		client.output.writeString(head);
		client.output.writeBytes(bytes, 0, bytes.length);
		client.output.flush();
	}

	static function statusText(status:Int):String {
		// checkAccess can return 401/403/429; without these the status line would read
		// "HTTP/1.1 401 OK". The status code alone is fine for clients, but that is misleading.
		return switch (status) {
			case 200: "OK";
			// Redirect for GET /mod/:mod_id/dl/:dl_id.
			case 302: "Found";
			case 400: "Bad Request";
			case 401: "Unauthorized";
			case 403: "Forbidden";
			case 404: "Not Found";
			case 413: "Payload Too Large";
			// Image type validation for /api/club/banner.
			case 415: "Unsupported Media Type";
			case 418: "I'm a teapot";
			case 429: "Too Many Requests";
			case 500: "Internal Server Error";
			case _: "OK";
		}
	}
}
