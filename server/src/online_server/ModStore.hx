package online_server;

import online_server.db.Db;
import online_server.db.ModRepo;
import online_server.db.Sqlite;

/**
 * Mod repository storage, backed by SQLite (table `mods`, see db/Migrations.hx and
 * db/ModRepo.hx). This class is the public facade: validation, the role/business rules and the
 * response shapes stay exactly as the JSON implementation had them, while ModRepo owns the
 * statements. No outbound HEAD probes, so size stays -1 and downloads redirect to the first URL;
 * favorited holds account ids that Api maps to names.
 *
 * Locking: every public method takes Db's lock (or lockTx for the multi-row favourite cleanup) and
 * ModRepo assumes it is already held; the lock is never re-entered.
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
	/**
	 * Page size for search: take 15, skip 15 * page.
	 *
	 * Named PAGE_ROWS, not PAGE_SIZE: the Android NDK's <sys/user.h> defines PAGE_SIZE as a
	 * C macro, and hxcpp emits statics under their Haxe name, so a Haxe `static var PAGE_SIZE`
	 * becomes `static int PAGE_SIZE;` -> `static int 4096;` and the module fails to compile on
	 * Android (the in-client LAN host links server/src into the APK). Same reason
	 * PLAYER_PAGE_SIZE/SEARCH_PAGE_SIZE are safe: those are not macros.
	 */
	public static inline var PAGE_ROWS:Int = 15;

	/** Legacy JSON path, kept only so storagePath() keeps reporting the same string. */
	static var path:String = null;

	/**
	 * Records the legacy path and makes sure the shared database is open (idempotent, first caller
	 * wins). No JSON file is read or created here: the tables come from Db.open() -> Migrations and
	 * all mod data already lives in SQLite.
	 */
	public static function init(file:String):Void {
		path = file;
		if (!Db.isOpen()) Db.openFor(file);
	}

	public static function storagePath():String return path;

	// ------------------------------------------------------------------
	// Lookup
	// ------------------------------------------------------------------

	/** Exact primary-key match, case-sensitive. */
	public static function byId(id:String):Mod {
		return Db.lock(function():Mod return ModRepo.byId(id));
	}

	public static function count():Int {
		return Db.lock(function():Int return ModRepo.count());
	}

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
		// 3 CHARACTERS: byte counting let a single CJK character (3 bytes) pass while rejecting
		// two ASCII letters.
		if (ServerConfig.utf8Length(StringTools.trim(raw == null ? "" : raw)) < 3) return "Title needs 3 letters at least";
		return null;
	}

	// ------------------------------------------------------------------
	// Write: mod
	// ------------------------------------------------------------------

	public static function create(data:Dynamic):ModResult {
		var id = strField(data, "id");
		var idError = modIdError(id);
		if (idError != null) return { mod: null, error: idError };
		var title = ServerConfig.repairUtf8(strField(data, "title"));
		var tError = titleError(title);
		if (tError != null) return { mod: null, error: tError };

		return Db.lock(function():ModResult {
			if (ModRepo.byIdInsensitive(id) != null) return { mod: null, error: "The ID for this mod is already taken!" };
			var now = nowMs();
			var m:Mod = {
				id: id,
				title: title,
				description: ServerConfig.repairUtf8(strField(data, "description")),
				keywords: ServerConfig.repairUtf8List(strArrayField(data, "keywords")),
				images: ServerConfig.repairUtf8List(strArrayField(data, "images")),
				favorited: [],
				favoritedCount: 0,
				downloadHits: 0,
				submitted: now,
				updated: now,
				downloads: []
			};
			ModRepo.insert(m);
			return { mod: m, error: null };
		});
	}

	public static function edit(data:Dynamic):ModResult {
		var title = ServerConfig.repairUtf8(strField(data, "title"));
		var tError = titleError(title);
		if (tError != null) return { mod: null, error: tError };
		var id = strField(data, "id");

		return Db.lock(function():ModResult {
			var m = ModRepo.byId(id);
			if (m == null) return { mod: null, error: "Failed to submit..." };
			m.title = title;
			var desc = ServerConfig.repairUtf8(strField(data, "description"));
			if (desc != null) m.description = desc;
			m.keywords = ServerConfig.repairUtf8List(strArrayField(data, "keywords"));
			m.images = ServerConfig.repairUtf8List(strArrayField(data, "images"));
			m.updated = nowMs();
			ModRepo.update(m);
			return { mod: m, error: null };
		});
	}

	/** Deletes the mod together with all of its downloads. */
	public static function remove(data:Dynamic):String {
		var id = strField(data, "id");
		return Db.lock(function():String {
			var m = ModRepo.byId(id);
			if (m == null) return "Failed to submit...";
			ModRepo.remove(id);
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

		return Db.lock(function():String {
			var m = ModRepo.byId(modId);
			if (m == null) return "None found...";
			var full = modId + ":" + rawDlId;
			if (ModRepo.downloadByIdInsensitive(full) != null) return "The ID for this download is already taken!";
			m.downloads.push({
				id: full,
				urls: urls == null ? [] : ServerConfig.repairUtf8List(urls),
				hits: 0,
				size: -1,
				modID: modId
			});
			m.updated = nowMs();
			ModRepo.update(m);
			return null;
		});
	}

	/** A missing download yields "Failed to submit...". */
	public static function editDownload(id:String, urls:Array<String>):String {
		return Db.lock(function():String {
			var ref = ModRepo.findDownload(id, false);
			if (ref == null) return "Failed to submit...";
			ref.download.urls = urls == null ? [] : ServerConfig.repairUtf8List(urls);
			// Size stays -1 because no HEAD probe is sent.
			ref.download.size = -1;
			ModRepo.update(ref.mod);
			return null;
		});
	}

	/** Removes a download; the id must contain ':', and a missing mod/download yields "None found...". */
	public static function removeDownload(id:String):String {
		if (id == null || id.indexOf(":") < 0) return "ID incomplete!";
		return Db.lock(function():String {
			var modId = id.split(":")[0];
			var m = ModRepo.byId(modId);
			if (m == null) return "None found...";
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
			ModRepo.update(m);
			return null;
		});
	}

	/**
	 * Picks a download URL: increments the download's hits, recomputes the mod's downloadHits,
	 * and returns the first entry of sortUrls(). No HEAD probe is sent, so this is the URL the
	 * route redirects to; an empty url list returns null.
	 */
	public static function pickDownloadURL(id:String):String {
		return Db.lock(function():String {
			var ref = ModRepo.findDownload(id, false);
			if (ref == null) return null;
			var sorted = sortUrls(ref.download.urls);
			if (sorted.length == 0) return null;
			var picked = sorted[0];
			if (picked == null || picked == "") return null;

			ref.download.hits = Sqlite.toNum(ref.download.hits, 0) + 1;
			ref.mod.downloadHits = sumHitsU(ref.mod);
			ModRepo.update(ref.mod);
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
		return Db.lock(function():ModResult {
			var m = ModRepo.byId(modId);
			if (m == null) return { mod: null, error: "Failed to submit..." };
			var idx = m.favorited.indexOf(userId);
			if (idx >= 0) m.favorited.splice(idx, 1);
			else if (!forceRemove) m.favorited.unshift(userId);
			m.favoritedCount = m.favorited.length;
			ModRepo.update(m);
			return { mod: m, error: null };
		});
	}

	/**
	 * Drops the user from every mod's favourites list, e.g. when the account is banned or
	 * deleted. Returns the number of favourites cleared.
	 */
	public static function removeFavoritesOf(userId:String):Int {
		return Db.lockTx(function():Int {
			var n = 0;
			for (m in ModRepo.all()) {
				var before = m.favorited.length;
				var idx = m.favorited.indexOf(userId);
				while (idx >= 0) {
					m.favorited.splice(idx, 1);
					n++;
					idx = m.favorited.indexOf(userId);
				}
				if (m.favorited.length != before) {
					m.favoritedCount = m.favorited.length;
					ModRepo.update(m);
				}
			}
			return n;
		});
	}

	// ------------------------------------------------------------------
	// Read: details / search
	// ------------------------------------------------------------------

	/** Mod details including downloads; null when the mod does not exist. */
	public static function details(id:String):Dynamic {
		return Db.lock(function():Dynamic {
			var m = ModRepo.byId(id);
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
					hits: Sqlite.toNum(d.hits, 0),
					size: Sqlite.toNum(d.size, -1),
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
		return Db.lock(function():Array<Mod> {
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
			for (m in ModRepo.all()) if (matchesU(m, q, words)) matched.push(m);
			matched.sort(function(a, b) return compareU(a, b, sortBy, sortDir));

			var start = (page <= 0 ? 0 : page) * PAGE_ROWS;
			var out:Array<Mod> = [];
			var i = start;
			while (i < matched.length && out.length < PAGE_ROWS) {
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
		var x = Sqlite.toNum(a, 0);
		var y = Sqlite.toNum(b, 0);
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
		if (m.downloads != null) for (d in m.downloads) total += Sqlite.toNum(d.hits, 0);
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
