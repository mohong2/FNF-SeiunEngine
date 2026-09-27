package;

import haxe.Json;
import sys.FileSystem;
import sys.io.File;

/**
 * Discovery of "segmented" charts: one logical chart whose sections are split across several
 * files and played back in order.
 *
 * Why this exists: a chart with hundreds of millions of notes cannot be written into one JSON
 * file, so authors split it. This module answers only one question -- "which files are this
 * chart's parts, and in what order". The merge itself is ChartStream.scanParts(), and Song
 * decides when a segmented chart is used at all.
 *
 * Two conventions are understood:
 *
 *   1. Explicit manifest, `data/<song>/<song>.parts.json`:
 *          ["<song>-0", "<song>-1", ...]   or   {"parts": ["<song>-0", ...]}
 *      Entries may omit the .json suffix and may point into a subdirectory. A manifest is
 *      explicit intent, so it wins even when a one-file chart exists.
 *
 *   2. Automatic numbering: `data/<song>/<song>-0.json`, `<song>-1.json`, ... numbered from
 *      0 with no gap and at least MIN_PARTS files. This is only accepted when
 *      `data/<song>/<song>.json` does NOT exist, so the numeric difficulties of a normal song
 *      are never mistaken for the parts of a segmented one.
 *
 * Deliberately flixel-free: probes compile this file without the engine.
 */
class ChartParts
{
	public static inline final JSON_EXT:String = '.json';
	public static inline final MANIFEST_EXT:String = '.parts.json';

	/** A chart counts as segmented only from this many part files up. */
	public static inline final MIN_PARTS:Int = 2;

	// User-facing modes, stored in ClientPrefs.data.segmentedCharts and picked in Options > Advanced.
	// The engine never decides on its own: the player chooses how much to trust the layout.
	/** Detect parts automatically, and honour a manifest when one exists. */
	public static inline final MODE_AUTO:String = 'Auto';
	/** Only a `<song>.parts.json` manifest counts; numbered difficulties are left alone. */
	public static inline final MODE_MANIFEST:String = 'Manifest';
	/** No segmentation at all, not even a manifest: every file is its own chart. */
	public static inline final MODE_OFF:String = 'Off';

	/** Any stored value that is not a known mode degrades to MODE_AUTO. */
	public static function normalizeMode(mode:String):String
	{
		if (mode == MODE_MANIFEST) return MODE_MANIFEST;
		if (mode == MODE_OFF) return MODE_OFF;
		return MODE_AUTO;
	}

	/**
	 * Per-song choice made at song select, keyed by song folder: MODE_AUTO / MODE_OFF, or absent to
	 * follow the saved global option.
	 *
	 * Session-scoped on purpose -- the Options entry is the preference that gets saved, this is the
	 * "this song, right now" override the player flips with the hotkey. MODE_MANIFEST is deliberately
	 * not offered per song: it is an author-facing mode, not a way to play.
	 */
	static var songOverrides:Map<String, String> = new Map<String, String>();

	/** The mode chosen for `song` at song select, or null when the global option applies. */
	public static function songOverride(song:String):String
	{
		if (song == null) return null;
		return songOverrides.get(song);
	}

	/** The mode a chart load should use: the per-song choice when there is one, else `globalMode`. */
	public static function effectiveSongMode(song:String, globalMode:String):String
	{
		var chosen:String = songOverride(song);
		return (chosen != null) ? chosen : normalizeMode(globalMode);
	}

	/**
	 * Advances the per-song choice and returns the new effective mode:
	 * follow-global -> merge (MODE_AUTO) -> segments only (MODE_OFF) -> follow-global.
	 */
	public static function cycleSongOverride(song:String, globalMode:String):String
	{
		if (song == null || song.length == 0) return normalizeMode(globalMode);
		if (songOverride(song) == null)
		{
			songOverrides.set(song, MODE_AUTO);
			return MODE_AUTO;
		}
		if (songOverrides.get(song) == MODE_AUTO)
		{
			songOverrides.set(song, MODE_OFF);
			return MODE_OFF;
		}
		songOverrides.remove(song);
		return normalizeMode(globalMode);
	}

	/** Drops every per-song choice (used by the probe; the game keeps them for the session). */
	public static function clearSongOverrides():Void
	{
		songOverrides.clear();
	}

	/**
	 * Ordered part files for `song` inside `dir`, or null when that directory does not hold a
	 * segmented chart. `dir` is the directory that contains the chart files (with or without a
	 * trailing separator).
	 *
	 * `mode` is the player's choice (MODE_AUTO / MODE_MANIFEST / MODE_OFF; null means MODE_AUTO).
	 * A manifest is explicit intent from the author, so it wins over automatic numbering; MODE_OFF
	 * skips even the manifest, which keeps the stock one-chart-per-file behavior reachable.
	 */
	public static function resolve(dir:String, song:String, ?mode:String):Array<String>
	{
		if (dir == null || dir.length == 0 || song == null || song.length == 0) return null;
		var selected:String = normalizeMode(mode);
		if (selected == MODE_OFF) return null;

		var manifest:Array<String> = readManifest(dir, song);
		if (manifest != null) return manifest;
		if (selected == MODE_MANIFEST) return null;
		return detect(dir, song);
	}

	/**
	 * Names a split file's base may use: the song folder first, then the full chart key.
	 *
	 * Psych lays charts out as `data/<song>/<song>[-difficulty].json`, so the parts of "miragist"
	 * are miragist-0.json, miragist-1.json, ... even when the selected difficulty resolves the
	 * requested chart key to "miragist-0". The chart key is still tried, for layouts whose split
	 * files are named after the full key.
	 */
	public static function nameCandidates(songName:String, chartKey:String):Array<String>
	{
		var names:Array<String> = [];
		if (songName != null && songName.length > 0) names.push(songName);
		if (chartKey != null && chartKey.length > 0 && names.indexOf(chartKey) < 0) names.push(chartKey);
		return names;
	}

	/**
	 * resolve() for a chart request: Song.loadFromJson() receives the difficulty-suffixed key
	 * ("miragist-0") plus the song folder ("miragist"), and the parts are named after the song.
	 *
	 * The song folder has to be tried first and the chart key second. With the chart key first this
	 * silently loaded nothing, because detect() refuses a base name whose `<base>.json` exists --
	 * and `miragist-0.json` is exactly the one-file chart being replaced.
	 */
	public static function resolveForChart(dir:String, songName:String, chartKey:String, ?mode:String):Array<String>
	{
		for (name in nameCandidates(songName, chartKey))
		{
			var parts:Array<String> = resolve(dir, name, mode);
			if (parts != null && parts.length > 0) return parts;
		}
		return null;
	}

	/**
	 * Parts listed by `<song>.parts.json`, or null when there is no usable manifest.
	 * A manifest that names a file which does not exist is a configuration error: it is traced
	 * and ignored (null) rather than half-applied.
	 */
	public static function readManifest(dir:String, song:String):Array<String>
	{
		var manifestPath:String = join(dir, song + MANIFEST_EXT);
		if (!FileSystem.exists(manifestPath)) return null;

		var raw:String = null;
		try raw = File.getContent(manifestPath) catch (e:Dynamic) return null;
		if (raw == null) return null;
		raw = StringTools.trim(raw);
		if (raw.length > 0 && raw.charCodeAt(0) == 0xFEFF) raw = raw.substr(1); // UTF-8 BOM

		var data:Dynamic = null;
		try data = Json.parse(raw) catch (e:Dynamic) return null;

		var names:Array<Dynamic> = null;
		if (Std.isOfType(data, Array))
			names = cast data;
		else if (data != null && Reflect.hasField(data, 'parts'))
		{
			var listed:Dynamic = Reflect.field(data, 'parts');
			if (Std.isOfType(listed, Array)) names = cast listed;
		}
		if (names == null) return null;

		var out:Array<String> = [];
		for (name in names)
		{
			if (name == null) continue;
			var entry:String = Std.string(name);
			if (entry.length == 0) continue;
			// Relative entries (subdirectories included) resolve against the manifest's own
			// directory, so a manifest stays valid wherever the engine is launched from.
			var full:String = isAbsolute(entry) ? entry : join(dir, entry.endsWith(JSON_EXT) ? entry : entry + JSON_EXT);
			if (!FileSystem.exists(full))
			{
				trace('ChartParts: "$manifestPath" lists a missing part "$full"');
				return null;
			}
			out.push(full);
		}
		return out.length > 0 ? out : null;
	}

	/**
	 * Auto-detected parts: `<song>-0.json` .. `<song>-N.json` with no gap, in ascending order.
	 * Returns null when `<song>.json` exists (an ordinary chart owns the name) or the numbering
	 * is not a complete run from 0.
	 */
	public static function detect(dir:String, song:String):Array<String>
	{
		if (!FileSystem.exists(dir)) return null;
		if (FileSystem.exists(join(dir, song + JSON_EXT))) return null;

		var entries:Array<String> = null;
		try entries = FileSystem.readDirectory(dir) catch (e:Dynamic) return null;
		if (entries == null) return null;

		var pattern:EReg = new EReg('^' + EReg.escape(song) + '-(\\d+)\\' + JSON_EXT + '$', 'i');
		var found:Map<Int, String> = new Map<Int, String>();
		var highest:Int = -1;
		for (name in entries)
		{
			if (!pattern.match(name)) continue;
			var index:Null<Int> = Std.parseInt(pattern.matched(1));
			if (index == null || index < 0) continue;
			if (found.exists(index)) continue;
			found.set(index, join(dir, name));
			if (index > highest) highest = index;
		}

		// A complete run from 0: exactly highest + 1 entries, every index present.
		if (highest < MIN_PARTS - 1 || found.exists(0) == false) return null;
		for (i in 0...highest + 1)
			if (!found.exists(i)) return null;

		var out:Array<String> = [];
		for (i in 0...highest + 1) out.push(found.get(i));
		return out;
	}

	/** Joins a directory and a file name with the separator `dir` already uses. */
	public static function join(dir:String, name:String):String
	{
		if (dir == null || dir.length == 0) return name;
		var last:String = dir.substr(dir.length - 1);
		if (last == '/' || last == '\\') return dir + name;
		return dir + '/' + name;
	}

	/** Absolute in the Windows ("C:\\dir", "C:/dir") or POSIX ("/dir") sense. */
	static function isAbsolute(path:String):Bool
	{
		if (path.length == 0) return false;
		var first:String = path.substr(0, 1);
		if (first == '/' || first == '\\') return true;
		if (path.length < 3 || path.charAt(1) != ':') return false;
		var third:String = path.substr(2, 1);
		return third == '/' || third == '\\';
	}
}
