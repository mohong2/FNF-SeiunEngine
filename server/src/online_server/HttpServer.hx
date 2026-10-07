package online_server;

import haxe.io.Bytes;
import sys.net.Host;
import sys.net.Socket;
import sys.thread.Deque;
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
 *
 * A FIXED pool of WORKER_COUNT connection workers drains one blocking queue, instead of the
 * historical "one thread per connection": the engine runs the host's sqlite and HTTP layers in
 * the same process as the game (HAXCPP_GC_GENERATIONAL is on), and under hxcpp's generational GC
 * each HaxeThread carries a per-thread mOldReferrers mark chunk whose lifecycle races with rapid
 * thread create/destroy (crash evidence: StackContext::pushReferrer dereferenced a garbage chunk
 * pointer from the sqlite request's write barrier). Menus fire one request per state switch, so
 * mashing the back button used to spawn a short-lived-thread storm and crash the server thread
 * mid-query. Workers are created once per start() and only exit on the stop() sentinels, so the
 * game no longer creates/destroys threads while the player navigates. `Connection: close` means
 * no keep-alive.
 */
class HttpServer {
	static inline var WORKER_COUNT:Int = 4;

	var listenSocket:Socket;
	var handler:HttpRequest->HttpResponse;
	/**
	 * False once stop() has run: the accept loop leaves instead of spinning on a closed socket.
	 * A plain Bool (same style as the rest of the server) is enough here: the flag only ever goes
	 * true, and the loop re-reads it every iteration.
	 */
	var running:Bool = true;
	/** Set by start(): a second start() must not spawn a second accept thread on the same socket. */
	var started:Bool = false;
	/** Accepted connections, FIFO; a null is the shutdown sentinel (see stop()). */
	var connections:Deque<Socket>;

	public function new(host:String, port:Int, handler:HttpRequest->HttpResponse) {
		this.handler = handler;

		listenSocket = new Socket();
		// Bind errors (port already in use, unresolvable host) stay normal exceptions: an embedded
		// host catches them and shows an error instead of terminating the process.
		listenSocket.bind(new Host(host), port);
		listenSocket.listen(32);
	}

	/** Starts the accept thread and the connection workers. Idempotent; a no-op after stop(). */
	public function start():Void {
		if (!running || started) return;
		started = true;
		connections = new Deque<Socket>();
		for (_ in 0...WORKER_COUNT)
			Thread.create(workerLoop);
		Thread.create(acceptLoop);
	}

	/**
	 * Stops accepting new connections and releases the listen port. Idempotent and safe to call
	 * from a thread other than the one that called start(). Closing the listen socket is what
	 * frees the port, so the port is free when this returns; the accept thread leaves on its next
	 * iteration. In-flight connections are not interrupted: every response is Connection: close
	 * and short lived, and connections already queued ahead of the sentinels are still served.
	 */
	public function stop():Void {
		running = false;
		var socket = listenSocket;
		listenSocket = null;
		if (socket != null) {
			try socket.close() catch (e:Dynamic) {}
		}
		// Wake workers blocked on pop(true): each exits when it dequeues a null. FIFO order means
		// anything accepted before the sentinels is handled first.
		if (connections != null) {
			for (_ in 0...WORKER_COUNT)
				connections.add(null);
		}
	}

	/** True while the accept loop may still take new connections (false after stop()). */
	public function isAccepting():Bool return running;

	function acceptLoop():Void {
		while (running) {
			// Read the field once: stop() may null it between this check and accept().
			var socket = listenSocket;
			if (socket == null) break;
			try {
				var client = socket.accept();
				if (!running) {
					// stop() won the race: do not serve a connection accepted after the stop.
					try client.close() catch (e:Dynamic) {}
					break;
				}
				connections.add(client);
			} catch (e:Dynamic) {
				// A stop closes the listen socket under the blocked accept(); that is not an error.
				if (!running) break;
				Sys.sleep(0.01);
			}
		}
	}

	function workerLoop():Void {
		while (true) {
			// Blocks until a connection arrives or stop() enqueues its null sentinel.
			var client = connections.pop(true);
			if (client == null)
				return;
			handleClient(client);
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
