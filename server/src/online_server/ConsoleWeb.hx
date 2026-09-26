package online_server;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import online_server.HttpServer.HttpResponse;

/**
 * Serves the built-in console page (server/web/**) at /console with zero dependencies.
 * Files are read from disk on every request so edits show up on refresh (no build step).
 */
class ConsoleWeb {
	static var cachedRoot:String = null;

	/** Resolve server/web relative to the running server.n first, then the cwd. */
	public static function root():String {
		if (cachedRoot != null) return cachedRoot;
		var candidates:Array<String> = [];
		try {
			var prog = Sys.programPath();
			if (prog != null && prog != "") {
				var binDir = Path.directory(prog);
				candidates.push(Path.directory(binDir) + "/web");
			}
		} catch (e:Dynamic) {}
		candidates.push("server/web");
		candidates.push("../web");
		for (c in candidates) {
			if (FileSystem.exists(c) && FileSystem.isDirectory(c)) {
				cachedRoot = c;
				return c;
			}
		}
		cachedRoot = candidates[0];
		return cachedRoot;
	}

	public static function serve(path:String):HttpResponse {
		var name = path.substr("/console".length);
		if (name == "" || name == "/") name = "/index.html";
		if (name.indexOf("..") >= 0) return notFound();
		var rel = name.substr(1);
		var full = root() + "/" + rel;
		if (!FileSystem.exists(full) || FileSystem.isDirectory(full)) return notFound();
		var body = "";
		try body = File.getContent(full) catch (e:Dynamic) return notFound();
		var headers = new Map<String, String>();
		// The console is edited in place; never let the browser cache a stale page.
		headers.set("Cache-Control", "no-store");
		return { status: 200, contentType: mimeOf(rel), body: body, headers: headers };
	}

	static function notFound():HttpResponse {
		return {
			status: 404,
			contentType: "text/html; charset=utf-8",
			body: "<!doctype html><meta charset=\"utf-8\"><title>Console</title><p>not found: put index.html / app.js / style.css in server/web/</p>"
		};
	}

	static function mimeOf(name:String):String {
		var lower = name.toLowerCase();
		if (StringTools.endsWith(lower, ".html")) return "text/html; charset=utf-8";
		if (StringTools.endsWith(lower, ".js")) return "application/javascript; charset=utf-8";
		if (StringTools.endsWith(lower, ".css")) return "text/css; charset=utf-8";
		if (StringTools.endsWith(lower, ".svg")) return "image/svg+xml";
		if (StringTools.endsWith(lower, ".json")) return "application/json; charset=utf-8";
		if (StringTools.endsWith(lower, ".txt")) return "text/plain; charset=utf-8";
		return "application/octet-stream";
	}
}
