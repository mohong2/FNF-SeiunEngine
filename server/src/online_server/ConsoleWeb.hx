package online_server;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import online_server.HttpServer.HttpResponse;

/**
 * Serves the built-in console page (server/web/**) at /console with zero dependencies.
 *
 * Two sources, in this order:
 *   1. server/web on disk -- read on every request, so a dev edit shows up on refresh (no build step);
 *   2. ConsoleWebAssets -- the same assets generated into the server (server/tools/gen_console_assets.ps1).
 *
 * The fallback exists because the game client hosts this server in-process for "Open to LAN" and
 * its export never ships server/web: there, root() finds nothing and the disk source always misses.
 */
class ConsoleWeb {
	static var cachedRoot:String = null;

	/**
	 * Source that answered the most recent serve() call: "disk", "embedded" or "none".
	 * Diagnostics only (the console status endpoint reports it). A request thread only ever assigns
	 * one of those three constants, so concurrency can make the value more recent, never corrupt it.
	 */
	public static var lastSource(default, null):String = "none";

	/** True when the built-in assets were compiled in (the generated class ships all three). */
	public static function hasEmbedded():Bool return ConsoleWebAssets.count() > 0;

	/** True when the last serve() could not use the disk copy and fell back to the embedded one. */
	public static function usedEmbedded():Bool return lastSource == "embedded";

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

	/** True when root() really is a directory (the disk source is usable in this process). */
	public static function rootExists():Bool {
		var dir = root();
		if (dir == null || dir == "") return false;
		return FileSystem.exists(dir) && FileSystem.isDirectory(dir);
	}

	/**
	 * The request path relative to the console root, or null when it is not a plain asset name.
	 * Traversal is impossible by construction: "..", its URL-encoded forms (%2e%2e and the
	 * double-encoded %252e%252e), backslashes, drive/ADS colons and control characters are all
	 * rejected before any path reaches the file system.
	 */
	static function safeName(path:String):Null<String> {
		var name = path.substr("/console".length);
		if (name == "" || name == "/") name = "/index.html";
		if (!StringTools.startsWith(name, "/")) return null;
		var rel = name.substr(1);
		if (rel == "") rel = "index.html";
		// Browsers percent-encode; decode once so "%2e%2e%2f" cannot slip past the ".." test.
		// A '%' that survives decoding means double encoding, and is rejected below.
		var decoded = rel;
		try decoded = StringTools.urlDecode(rel) catch (e:Dynamic) return null;
		if (decoded == "" || StringTools.startsWith(decoded, "/")) return null;
		if (decoded.indexOf("..") >= 0) return null;
		if (decoded.indexOf("\\") >= 0) return null;
		if (decoded.indexOf(":") >= 0) return null;
		if (decoded.indexOf("%") >= 0) return null;
		for (i in 0...decoded.length) {
			var c = decoded.charCodeAt(i);
			if (c < 0x20 || c == 0x7F) return null;
		}
		return decoded;
	}

	public static function serve(path:String):HttpResponse {
		var rel = safeName(path);
		if (rel == null) {
			lastSource = "none";
			return notFound();
		}
		// Disk first: a present server/web stays the source of truth for live editing.
		var fromDisk = readDisk(rel);
		if (fromDisk != null) {
			lastSource = "disk";
			return file(rel, fromDisk);
		}
		var embedded = ConsoleWebAssets.lookup(rel);
		if (embedded != null) {
			lastSource = "embedded";
			return file(rel, embedded);
		}
		lastSource = "none";
		return notFound();
	}

	static function readDisk(rel:String):Null<String> {
		var dir = root();
		if (dir == null || dir == "") return null;
		var full = dir + "/" + rel;
		try {
			if (!FileSystem.exists(full) || FileSystem.isDirectory(full)) return null;
			return File.getContent(full);
		} catch (e:Dynamic) {
			return null;
		}
	}

	static function file(rel:String, body:String):HttpResponse {
		var headers = new Map<String, String>();
		// The console is edited in place; never let the browser cache a stale page.
		headers.set("Cache-Control", "no-store");
		return { status: 200, contentType: mimeOf(rel), body: body, headers: headers };
	}

	/**
	 * 404 body. "put ... in server/web/" is only honest when this build has no embedded copy: with
	 * the generated assets present the directory is optional, so the message must not ask the user
	 * to install what the binary already carries.
	 */
	static function notFound():HttpResponse {
		var body = hasEmbedded()
			? "<!doctype html><meta charset=\"utf-8\"><title>Console</title><p>not found: no such console asset (the built-in console serves /console, /console/app.js and /console/style.css)</p>"
			: "<!doctype html><meta charset=\"utf-8\"><title>Console</title><p>not found: put index.html / app.js / style.css in server/web/</p>";
		return { status: 404, contentType: "text/html; charset=utf-8", body: body };
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
