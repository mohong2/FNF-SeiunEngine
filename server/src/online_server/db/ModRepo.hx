package online_server.db;

import online_server.ModStore.Mod;
import online_server.ModStore.ModDownload;

/** A download together with the mod that owns it. Both are freshly built copies. */
typedef DownloadRef = {
	var mod:Mod;
	var download:ModDownload;
}

/**
 * SQLite repository for the mod repository (table mods): one row per mod, with the list-valued
 * fields kept as JSON TEXT columns (keywords / images / favorited / downloads), exactly the shape
 * the legacy JSON document had.
 *
 * Every method expects the caller to already hold Db's lock (ModStore does that through Db.lock)
 * and every method returns freshly built structs -- a raw result row never leaves this class.
 *
 * Column notes:
 *  - mods has no sequence counter: seq is written as 0 and the implicit rowid reproduces the
 *    legacy array order (appends at the end, deletes compact the list).
 *  - A download lookup is a scan over the small mod list because downloads live inside
 *    downloads_json and are never queried element-wise, same as the JSON layer.
 *  - favorited_count and download_hits are denormalised counters the callers keep in sync with
 *    the JSON columns.
 */
class ModRepo {
	static inline var MOD_COLUMNS = 'id, seq, title, description, keywords_json, images_json, favorited_json,'
		+ ' favorited_count, download_hits, submitted, updated, downloads_json';

	// ------------------------------------------------------------------
	// Reads (caller holds the lock)
	// ------------------------------------------------------------------

	public static function count():Int {
		return Db.scalar('SELECT COUNT(*) FROM mods', 0);
	}

	public static function byId(id:String):Mod {
		if (id == null) return null;
		return toMod(Db.queryOne('SELECT * FROM mods WHERE id = ' + Db.quote(id) + ' LIMIT 1'));
	}

	/** Full snapshot in legacy array order (rowid == insertion order). */
	public static function all():Array<Mod> {
		var rows = Db.query('SELECT * FROM mods ORDER BY rowid ASC');
		var out:Array<Mod> = [];
		for (r in rows) out.push(toMod(r));
		return out;
	}

	/**
	 * Case-insensitive duplicate check. It scans the projected list so the comparison is the exact
	 * Haxe toLowerCase() the JSON layer used (SQLite's lower() only folds ASCII).
	 */
	public static function byIdInsensitive(id:String):Mod {
		if (id == null) return null;
		var lower = id.toLowerCase();
		for (m in all()) if (m.id != null && m.id.toLowerCase() == lower) return m;
		return null;
	}

	/** Case-sensitive lookup of a download by its <modID>:<dlID> id (null when missing). */
	public static function downloadById(id:String):ModDownload {
		var ref = findDownload(id, false);
		return ref == null ? null : ref.download;
	}

	/** Case-insensitive variant, used for the duplicate-id check. */
	public static function downloadByIdInsensitive(id:String):ModDownload {
		var ref = findDownload(id, true);
		return ref == null ? null : ref.download;
	}

	/**
	 * Finds a download together with its owning mod. Both are fresh copies, so the caller may
	 * mutate them (the legacy read-modify-write shape) and hand the mod back to update().
	 */
	public static function findDownload(id:String, insensitive:Bool):DownloadRef {
		if (id == null) return null;
		var lower = insensitive ? id.toLowerCase() : null;
		for (m in all()) {
			for (d in m.downloads) {
				var hit = insensitive ? (d.id != null && d.id.toLowerCase() == lower) : (d.id == id);
				if (hit) return { mod: m, download: d };
			}
		}
		return null;
	}

	// ------------------------------------------------------------------
	// Writes (caller holds the lock)
	// ------------------------------------------------------------------

	public static function insert(m:Mod):Void {
		Db.exec('INSERT INTO mods (' + MOD_COLUMNS + ') VALUES (' + values(m) + ')');
	}

	public static function update(m:Mod):Void {
		Db.exec('UPDATE mods SET ' + assignments(m) + ' WHERE id = ' + Db.quote(m.id));
	}

	public static function remove(id:String):Void {
		if (id == null) return;
		Db.exec('DELETE FROM mods WHERE id = ' + Db.quote(id));
	}

	// ------------------------------------------------------------------
	// Row projection and statement fragments
	// ------------------------------------------------------------------

	public static function toMod(row:Dynamic):Mod {
		if (row == null) return null;
		var m:Mod = {
			id: Sqlite.str(row, 'id', ''),
			title: Sqlite.str(row, 'title', null),
			description: Sqlite.str(row, 'description', null),
			keywords: Sqlite.stringArray(row, 'keywords_json'),
			images: Sqlite.stringArray(row, 'images_json'),
			favorited: Sqlite.stringArray(row, 'favorited_json'),
			favoritedCount: Sqlite.intOf(row, 'favorited_count', 0),
			downloadHits: Sqlite.intOf(row, 'download_hits', 0),
			submitted: Sqlite.num(row, 'submitted', 0),
			updated: Sqlite.numOrNull(row, 'updated'),
			downloads: downloadsOf(row)
		};
		return m;
	}

	static function downloadsOf(row:Dynamic):Array<ModDownload> {
		var out:Array<ModDownload> = [];
		for (item in Sqlite.dynamicArray(row, 'downloads_json')) {
			if (item == null) continue;
			out.push({
				id: Sqlite.str(item, 'id', null),
				urls: urlArray(item),
				hits: Sqlite.num(item, 'hits', 0),
				size: Sqlite.num(item, 'size', -1),
				modID: Sqlite.str(item, 'modID', null)
			});
		}
		return out;
	}

	/** URL list of one embedded download object ([] for a missing or malformed field). */
	static function urlArray(item:Dynamic):Array<String> {
		var out:Array<String> = [];
		try {
			var v:Dynamic = Reflect.field(item, 'urls');
			if (v == null || !Std.isOfType(v, Array)) return out;
			for (u in (cast v : Array<Dynamic>)) {
				if (u == null) continue;
				out.push(Std.string(u));
			}
		} catch (e:Dynamic) {}
		return out;
	}

	static function values(m:Mod):String {
		return [
			Db.quote(m.id),
			Sqlite.int(0),
			Db.quote(m.title),
			Db.quote(m.description),
			Db.quote(Sqlite.json(m.keywords)),
			Db.quote(Sqlite.json(m.images)),
			Db.quote(Sqlite.json(m.favorited)),
			Sqlite.int(m.favoritedCount),
			Sqlite.int(m.downloadHits),
			Sqlite.real(m.submitted),
			Sqlite.real(m.updated),
			Db.quote(Sqlite.json(m.downloads))
		].join(', ');
	}

	static function assignments(m:Mod):String {
		return 'seq = ' + Sqlite.int(0)
			+ ', title = ' + Db.quote(m.title)
			+ ', description = ' + Db.quote(m.description)
			+ ', keywords_json = ' + Db.quote(Sqlite.json(m.keywords))
			+ ', images_json = ' + Db.quote(Sqlite.json(m.images))
			+ ', favorited_json = ' + Db.quote(Sqlite.json(m.favorited))
			+ ', favorited_count = ' + Sqlite.int(m.favoritedCount)
			+ ', download_hits = ' + Sqlite.int(m.downloadHits)
			+ ', submitted = ' + Sqlite.real(m.submitted)
			+ ', updated = ' + Sqlite.real(m.updated)
			+ ', downloads_json = ' + Db.quote(Sqlite.json(m.downloads));
	}
}
