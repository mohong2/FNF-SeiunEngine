package online_server;

import sys.FileSystem;

/**
 * Mod repository storage (local JSON, <data-dir>/mods.json). No outbound HEAD probes, so size
 * stays -1 and downloads redirect to the first URL; favorited holds account ids that Api maps
 * to names. Shares JsonStore's Mutex; never re-enter a lock.
 */
typedef Mod = {
	var id:String;
	var title:String;
	var description:String;
	var keywords:Array<String>;
	var images:Array<String>;
	/** Account ids of the users who favourited this mod. */
	var favorited:Array<String>;
	var favoritedCount:Int;
	var downloadHits:Int;
	/** Millisecond timestamp; viewOf / detailsU render it as ISO for output. */
	var submitted:Float;
	var ?updated:Null<Float>;
	var downloads:Array<ModDownload>;
}

typedef ModDownload = {
	/** Primary key in the form `<modID>:<dlID>`. */
	var id:String;
	var urls:Array<String>;
	var hits:Float;
	/** Always -1: no HEAD probe is sent, so the real size is unknown. */
	var size:Float;
	var modID:String;
}

/** Result of create / edit / toggleFav: a non-null error means the call was rejected (mod is non-null only on success). */
typedef ModResult = {
	var mod:Mod;
	var error:String;
}

class ModStore {
	/** Page size for search: take 15, skip 15 * page. */
	public static inline var PAGE_SIZE:Int = 15;

	static var path:String = null;
	/** { mods:Array<Mod> } */
	static var db:Dynamic = null;

	public static function init(file:String):Void {
		path = file;
		JsonStore.lock(function() {
			var loaded = JsonStore.read(path, null);
			if (loaded == null || loaded.mods == null) {
				loaded = { mods: [] };
			}
			db = loaded;
			migrateU();
			if (!FileSystem.exists(path)) JsonStore.write(path, db);
			return true;
		});
	}

	public static function storagePath():String return path;

	static function allU():Array<Mod> return cast db.mods;

	/** Backfill for old or hand-edited JSON: ensures the array and counter fields exist. */
	static function migrateU():Bool {
		var changed = false;
		for (m in allU()) {
			if (m.keywords == null) {
				m.keywords = [];
				changed = true;
			}
			if (m.images == null) {
				m.images = [];
				changed = true;
			}
			if (m.favorited == null) {
				m.favorited = [];
				changed = true;
			}
			if (m.downloads == null) {
				m.downloads = [];
				changed = true;
			}
			if (Reflect.field(m, "favoritedCount") == null) {
				m.favoritedCount = m.favorited.length;
				changed = true;
			}
			if (Reflect.field(m, "downloadHits") == null) {
				m.downloadHits = sumHitsU(m);
				changed = true;
			}
			if (Reflect.field(m, "submitted") == null) {
				m.submitted = nowMs();
				changed = true;
			}
		}
		return changed;
	}

	// ------------------------------------------------------------------
	// Lookup
	// ------------------------------------------------------------------

	/** Exact primary-key match, case-sensitive. */
	static function byIdU(id:String):Mod {
		if (id == null) return null;
		for (m in allU()) if (m.id == id) return m;
		return null;
	}

	/** Case-insensitive duplicate-name check. */
	static function byIdInsensitiveU(id:String):Mod {
		if (id == null) return null;
		var lower = id.toLowerCase();
		for (m in allU()) if (m.id != null && m.id.toLowerCase() == lower) return m;
		return null;
	}

	static function downloadByIdU(id:String):ModDownload {
		if (id == null) return null;
		for (m in allU()) {
			if (m.downloads == null) continue;
			for (d in m.downloads) if (d.id == id) return d;
		}
		return null;
	}

	static function downloadByIdInsensitiveU(id:String):ModDownload {
		if (id == null) return null;
		var lower = id.toLowerCase();
		for (m in allU()) {
			if (m.downloads == null) continue;
			for (d in m.downloads) if (d.id != null && d.id.toLowerCase() == lower) return d;
		}
		return null;
	}

	public static function byId(id:String):Mod return JsonStore.lock(function() return byIdU(id));

	public static function count():Int return JsonStore.lock(function() return allU().length);

	// ------------------------------------------------------------------
	// Validation
	// ------------------------------------------------------------------

	/**
	 * Mod ID validation: trimmed length >= 3 and only `[a-z0-9_-]` characters.
	 * The character test runs on the **untrimmed** input, so `"abc "` is rejected as invalid
	 * characters even though its trimmed length is 3.
	 */
	public static function modIdError(raw:String):String {
		var s = raw == null ? "" : raw;
		if (StringTools.trim(s).length < 3) return "ID needs 3 letters at least";
		if (hasInvalidChars(s, false)) return "ID Contains invalid characters";
		return null;
	}

	/** Download ID validation: trimmed length >= 1 and the same character set plus `.`. */
	public static function dlIdError(raw:String):String {
		var s = raw == null ? "" : raw;
		if (StringTools.trim(s).length < 1) return "ID needs a letter at least";
		if (hasInvalidChars(s, true)) return "ID Contains invalid characters";
		return null;
	}

	static function hasInvalidChars(s:String, allowDot:Bool):Bool {
		for (i in 0...s.length) {
			var c = s.charCodeAt(i);
			var ok = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 45
				|| (allowDot && c == 46);
			if (!ok) return true;
		}
		return false;
	}

	public static function titleError(raw:String):String {
		if (StringTools.trim(raw == null ? "" : raw).length < 3) return "Title needs 3 letters at least";
		return null;
	}

	// ------------------------------------------------------------------
	// Write: mod
	// ------------------------------------------------------------------

	public static function create(data:Dynamic):ModResult {
		var id = strField(data, "id");
		var idError = modIdError(id);
		if (idError != null) return { mod: null, error: idError };
		var title = strField(data, "title");
		var tError = titleError(title);
		if (tError != null) return { mod: null, error: tError };

		return JsonStore.lock(function() {
			if (byIdInsensitiveU(id) != null) return { mod: null, error: "The ID for this mod is already taken!" };
			var now = nowMs();
			var m:Mod = {
				id: id,
				title: title,
				description: strField(data, "description"),
				keywords: strArrayField(data, "keywords"),
				images: strArrayField(data, "images"),
				favorited: [],
				favoritedCount: 0,
				downloadHits: 0,
				submitted: now,
				updated: now,
				downloads: []
			};
			allU().push(m);
			JsonStore.write(path, db);
			return { mod: m, error: null };
		});
	}

	public static function edit(data:Dynamic):ModResult {
		var title = strField(data, "title");
		var tError = titleError(title);
		if (tError != null) return { mod: null, error: tError };
		var id = strField(data, "id");

		return JsonStore.lock(function() {
			var m = byIdU(id);
			if (m == null) return { mod: null, error: "Failed to submit..." };
			m.title = title;
			var desc = strField(data, "description");
			if (desc != null) m.description = desc;
			m.keywords = strArrayField(data, "keywords");
			m.images = strArrayField(data, "images");
			m.updated = nowMs();
			JsonStore.write(path, db);
			return { mod: m, error: null };
		});
	}

	/** Deletes the mod together with all of its downloads. */
	public static function remove(data:Dynamic):String {
		var id = strField(data, "id");
		return JsonStore.lock(function() {
			var m = byIdU(id);
			if (m == null) return "Failed to submit...";
			var i = allU().indexOf(m);
			if (i >= 0) allU().splice(i, 1);
			JsonStore.write(path, db);
			return null;
		});
	}

	// ------------------------------------------------------------------
	// Write: download
	// ------------------------------------------------------------------

	/** Adds a download to an existing mod; a missing mod yields "None found...". */
	public static function addDownload(modId:String, rawDlId:String, urls:Array<String>):String {
		var idError = dlIdError(rawDlId);
		if (idError != null) return idError;

		return JsonStore.lock(function() {
			var m = byIdU(modId);
			if (m == null) return "None found...";
			var full = modId + ":" + rawDlId;
			if (downloadByIdInsensitiveU(full) != null) return "The ID for this download is already taken!";
			if (m.downloads == null) m.downloads = [];
			m.downloads.push({
				id: full,
				urls: urls == null ? [] : urls,
				hits: 0,
				size: -1,
				modID: modId
			});
			m.updated = nowMs();
			JsonStore.write(path, db);
			return null;
		});
	}

	/** A missing download yields "Failed to submit...". */
	public static function editDownload(id:String, urls:Array<String>):String {
		return JsonStore.lock(function() {
			var d = downloadByIdU(id);
			if (d == null) return "Failed to submit...";
			d.urls = urls == null ? [] : urls;
			// Size stays -1 because no HEAD probe is sent.
			d.size = -1;
			JsonStore.write(path, db);
			return null;
		});
	}

	/** Removes a download; the id must contain ':', and a missing mod/download yields "None found...". */
	public static function removeDownload(id:String):String {
		if (id == null || id.indexOf(":") < 0) return "ID incomplete!";
		return JsonStore.lock(function() {
			var modId = id.split(":")[0];
			var m = byIdU(modId);
			if (m == null || m.downloads == null) return "None found...";
			var kept:Array<ModDownload> = [];
			var removed = false;
			for (d in m.downloads) {
				if (d.id == id) removed = true;
				else kept.push(d);
			}
			if (!removed) return "None found...";
			m.downloads = kept;
			m.downloadHits = sumHitsU(m);
			m.updated = nowMs();
			JsonStore.write(path, db);
			return null;
		});
	}

	/**
	 * Picks a download URL: increments the download's hits, recomputes the mod's downloadHits,
	 * and returns the first entry of sortUrls(). No HEAD probe is sent, so this is the URL the
	 * route redirects to; an empty url list returns null.
	 */
	public static function pickDownloadURL(id:String):String {
		return JsonStore.lock(function() {
			var d = downloadByIdU(id);
			if (d == null) return null;
			var sorted = sortUrls(d.urls);
			if (sorted.length == 0) return null;
			var picked = sorted[0];
			if (picked == null || picked == "") return null;

			d.hits = (d.hits == null ? 0 : d.hits) + 1;
			var m = byIdU(d.modID);
			if (m != null) m.downloadHits = sumHitsU(m);
			JsonStore.write(path, db);
			return picked;
		});
	}

	/** Sort priority: Drive 3 > MediaFire 2 > GameBanana 1 > anything else 0. */
	public static function sortUrls(urls:Array<String>):Array<String> {
		var out:Array<String> = urls == null ? [] : urls.copy();
		out.sort(function(a, b) {
			var p1 = downloadPriority(a);
			var p2 = downloadPriority(b);
			return p1 == p2 ? 0 : (p1 > p2 ? -1 : 1);
		});
		return out;
	}

	static function downloadPriority(url:String):Int {
		if (url == null) return 0;
		if (StringTools.startsWith(url, "https://drive.google.com/file/d/")) return 3;
		if (StringTools.startsWith(url, "https://www.mediafire.com/file/")) return 2;
		if (StringTools.startsWith(url, "https://gamebanana.com/dl/")) return 1;
		return 0;
	}

	// ------------------------------------------------------------------
	// Write: favourites
	// ------------------------------------------------------------------

	/** Removes the user from favourites if present, otherwise inserts them at the front (forceRemove only removes). A missing mod is rejected. */
	public static function toggleFav(userId:String, modId:String, forceRemove:Bool = false):ModResult {
		return JsonStore.lock(function() {
			var m = byIdU(modId);
			if (m == null) return { mod: null, error: "Failed to submit..." };
			if (m.favorited == null) m.favorited = [];
			var idx = m.favorited.indexOf(userId);
			if (idx >= 0) m.favorited.splice(idx, 1);
			else if (!forceRemove) m.favorited.unshift(userId);
			m.favoritedCount = m.favorited.length;
			JsonStore.write(path, db);
			return { mod: m, error: null };
		});
	}

	/**
	 * Drops the user from every mod's favourites list, e.g. when the account is banned or
	 * deleted. Returns the number of favourites cleared.
	 */
	public static function removeFavoritesOf(userId:String):Int {
		return JsonStore.lock(function() {
			var n = 0;
			for (m in allU()) {
				if (m.favorited == null) continue;
				var before = m.favorited.length;
				var idx = m.favorited.indexOf(userId);
				while (idx >= 0) {
					m.favorited.splice(idx, 1);
					n++;
					idx = m.favorited.indexOf(userId);
				}
				if (m.favorited.length != before) m.favoritedCount = m.favorited.length;
			}
			if (n > 0) JsonStore.write(path, db);
			return n;
		});
	}

	// ------------------------------------------------------------------
	// Read: details / search
	// ------------------------------------------------------------------

	/** Mod details including downloads; null when the mod does not exist. */
	public static function details(id:String):Dynamic {
		return JsonStore.lock(function() {
			var m = byIdU(id);
			if (m == null) return null;
			return detailsU(m);
		});
	}

	static function detailsU(m:Mod):Dynamic {
		var downloads:Array<Dynamic> = [];
		if (m.downloads != null) {
			for (d in m.downloads) {
				downloads.push({
					id: d.id,
					urls: d.urls == null ? [] : d.urls,
					hits: d.hits == null ? 0 : d.hits,
					size: d.size == null ? -1 : d.size,
					modID: d.modID
				});
			}
		}
		return {
			id: m.id,
			title: m.title,
			description: m.description,
			keywords: m.keywords,
			images: m.images,
			// Api replaces this with a name array outside the lock.
			favorited: m.favorited,
			favoritedCount: m.favoritedCount,
			downloadHits: m.downloadHits,
			// Extra field on the details payload: the sum of all download hits (note the trailing s).
			downloadsHits: sumHitsU(m),
			submitted: JsonStore.isoOf(m.submitted),
			updated: m.updated == null ? null : JsonStore.isoOf(m.updated),
			downloads: downloads
		};
	}

	/** Public view of a mod without its downloads (used by create/edit responses). */
	public static function viewOf(m:Mod):Dynamic {
		if (m == null) return null;
		return {
			id: m.id,
			title: m.title,
			description: m.description,
			keywords: m.keywords,
			images: m.images,
			favorited: m.favorited,
			favoritedCount: m.favoritedCount,
			downloadHits: m.downloadHits,
			submitted: JsonStore.isoOf(m.submitted),
			updated: m.updated == null ? null : JsonStore.isoOf(m.updated)
		};
	}

	/** Search result projection: no description or favourited list. */
	public static function searchViews(query:String, page:Int, sort:String):Array<Dynamic> {
		var matched = search(query, page, sort);
		var out:Array<Dynamic> = [];
		for (m in matched) {
			out.push({
				id: m.id,
				images: m.images,
				title: m.title,
				keywords: m.keywords,
				downloadHits: m.downloadHits,
				favoritedCount: m.favoritedCount,
				submitted: JsonStore.isoOf(m.submitted)
			});
		}
		return out;
	}

	public static function search(query:String, page:Int, sort:String):Array<Mod> {
		return JsonStore.lock(function() {
			var sortBy = "submitted";
			var sortDir = "desc";
			if (sort != null && sort != "") {
				var parts = sort.split(":");
				var by = parts.length > 0 ? parts[0] : "";
				var dir = parts.length > 1 ? parts[1] : "";
				if (by == "title" || by == "submitted" || by == "favoritedCount" || by == "downloadHits") sortBy = by;
				if (dir == "desc" || dir == "asc") sortDir = dir;
			}

			var q = query == null ? "" : query;
			var words = q.split(" ");
			var matched:Array<Mod> = [];
			for (m in allU()) if (matchesU(m, q, words)) matched.push(m);
			matched.sort(function(a, b) return compareU(a, b, sortBy, sortDir));

			var start = (page <= 0 ? 0 : page) * PAGE_SIZE;
			var out:Array<Mod> = [];
			var i = start;
			while (i < matched.length && out.length < PAGE_SIZE) {
				out.push(matched[i]);
				i++;
			}
			return out;
		});
	}

	/**
	 * A mod matches when any keyword equals a query word, or the lowercased id or title
	 * contains the lowercased query. An empty query matches everything, since every string
	 * contains "".
	 */
	static function matchesU(m:Mod, q:String, words:Array<String>):Bool {
		if (m.keywords != null) {
			for (k in m.keywords) if (words.indexOf(k) >= 0) return true;
		}
		var lower = q.toLowerCase();
		if (m.id != null && m.id.toLowerCase().indexOf(lower) >= 0) return true;
		if (m.title != null && m.title.toLowerCase().indexOf(lower) >= 0) return true;
		return false;
	}

	/** Comparator for the requested sort field and direction. */
	static function compareU(a:Mod, b:Mod, by:String, dir:String):Int {
		var c = 0;
		switch (by) {
			case "title": c = strCompare(a.title, b.title);
			case "favoritedCount": c = numCompare(a.favoritedCount, b.favoritedCount);
			case "downloadHits": c = numCompare(a.downloadHits, b.downloadHits);
			case _: c = numCompare(a.submitted, b.submitted);
		}
		return dir == "asc" ? c : -c;
	}

	static function strCompare(a:String, b:String):Int {
		var x = a == null ? "" : a;
		var y = b == null ? "" : b;
		if (x == y) return 0;
		return x < y ? -1 : 1;
	}

	static function numCompare(a:Float, b:Float):Int {
		var x = a == null ? 0 : a;
		var y = b == null ? 0 : b;
		if (x == y) return 0;
		return x < y ? -1 : 1;
	}

	// ------------------------------------------------------------------
	// Utilities
	// ------------------------------------------------------------------

	/** neko's Date.now() has only second precision; use Timer.stamp() * 1000 for milliseconds. */
	static function nowMs():Float return haxe.Timer.stamp() * 1000;

	/** Sum of every download's hits. */
	static function sumHitsU(m:Mod):Int {
		var total:Float = 0;
		if (m.downloads != null) for (d in m.downloads) total += (d.hits == null ? 0 : d.hits);
		return Std.int(total);
	}

	static function strField(o:Dynamic, field:String):String {
		if (o == null) return null;
		try {
			var v = Reflect.field(o, field);
			return v == null ? null : Std.string(v);
		} catch (e:Dynamic) return null;
	}

	static function strArrayField(o:Dynamic, field:String):Array<String> {
		var out:Array<String> = [];
		if (o == null) return out;
		try {
			var v = Reflect.field(o, field);
			if (v == null || !Std.isOfType(v, Array)) return out;
			for (item in (cast v : Array<Dynamic>)) out.push(Std.string(item));
		} catch (e:Dynamic) {}
		return out;
	}
}
