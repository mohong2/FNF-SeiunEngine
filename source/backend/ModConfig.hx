package backend;

import haxe.Json;
import mohong.TraceManager;

#if MODS_ALLOWED
import sys.FileSystem;
import sys.io.File;
#end

#if (desktop && MODS_ALLOWED)
import openfl.display.BitmapData;
import openfl.geom.Matrix;
import lime.graphics.Image;
import openfl.Lib;
#end

/**
 * Mod configuration loader.
 *
 * Reads `pack.json` from a mod folder and provides typed access
 * to all metadata, replacements, and compatibility info.
 *
 * ### API_VERSION
 * Used for forward‑compatibility checks:
 *   - `apiVersion == 0`  → not set (treated as legacy, assumed compatible)
 *   - `apiVersion <= ENGINE_API_VERSION` → compatible
 *   - `apiVersion  > ENGINE_API_VERSION` → mod needs a newer engine
 */
class ModConfig
{
	/** Current engine API version. Bump when breaking changes are made. */
	public static final ENGINE_API_VERSION:Int = 1;

	/** Maximum size (px) for the window icon before scaling. */
	public static final WINDOW_ICON_MAX_SIZE:Int = 64;

	public function new() 
    {

    }

	// ── Metadata ──
	public var name:String = "";
	public var description:String = "";
	public var author:String = "";
	public var version:String = "";
	public var apiVersion:Int = 0; // 0 = not set / legacy
	public var downloadLink:String = "";
	public var iconPath:String = "";

	// ── Multi‑resolution icons (CNE‑style) ──
	/** 64×64 icon (taskbar, alt‑tab). */
	public var iconPath64:String = "";
	/** 32×32 icon (small taskbar, window corner). */
	public var iconPath32:String = "";
	/** 24×24 icon (context menus). */
	public var iconPath24:String = "";
	/** 16×16 icon (title bar, tray). */
	public var iconPath16:String = "";

	// ── Behaviour ──
	public var restartRequired:Bool = false;
	public var runsGlobally:Bool = false;

	/** If true, the engine's warning screen (if any) will be skipped. */
	public var disableWarningScreen:Bool = false;
	/** If true, the language‑selection UI will be hidden. */
	public var disableLanguages:Bool = false;

	/** List of mod folder names this mod depends on (loaded first). */
	public var dependencies:Array<String> = [];

	// ── Appearance ──
	public var color:Array<Int> = [170, 0, 255];
	public var iconFramerate:Int = 10;

	/** If true, use the old FPS counter style instead of the new one. */
	public var useOldFPS:Bool = false;

	// ── Window ──
	public var windowTitle:String = "";

	// ── State redirects ──
	public var stateReplacements:Map<String, String> = new Map<String, String>();
	public var substateReplacements:Map<String, String> = new Map<String, String>();

	// ── Discord ──
	public var discordClientId:String = "";
	public var discordLogoKey:String = "";
	public var discordLogoText:String = "";

	/**
	 * Load configuration from a mod folder's `pack.json`.
	 * Returns an empty ModConfig if no pack.json exists.
	 */
	public static function load(modFolder:String):ModConfig
	{
		var cfg = new ModConfig();
		#if MODS_ALLOWED
		if (modFolder == null || modFolder.length == 0) return cfg;

		var path:String = Paths.mods(modFolder + '/pack.json');
		if (!FileSystem.exists(path)) return cfg;

		try
		{
			var raw:String = File.getContent(path);
			if (raw == null || raw.length == 0) return cfg;

			// pack.json 在 1.0.4 里用 tjson 解析：容忍尾随逗号（{...,}）与注释。
			var json:Dynamic = JsonUtil.parseTolerant(raw);

			// ── Metadata ──
			readStr(json, "name", function(v) { if (v != "Name") cfg.name = v; });
			readStr(json, "description", function(v) { if (v != "Description") cfg.description = v; });
			readStr(json, "author", function(v) cfg.author = v);
			readStr(json, "version", function(v) cfg.version = v);
			cfg.apiVersion = readInt(json, "apiVersion", 0);
			if (cfg.apiVersion == 0) cfg.apiVersion = readInt(json, "API_VERSION", 0); // uppercase fallback
			readStr(json, "downloadLink", function(v) cfg.downloadLink = v);

			// ── Behaviour ──
			cfg.restartRequired = readBool(json, "restart", false);
			cfg.runsGlobally = readBool(json, "runsGlobally", false);
			cfg.disableWarningScreen = readBool(json, "disableWarningScreen", false);
			cfg.disableLanguages = readBool(json, "disableLanguages", false);

			// ── Dependencies ──
			readStrArray(json, "dependencies", function(v) cfg.dependencies = v);

			// ── Appearance ──
			var c:Array<Dynamic> = (json != null && Reflect.hasField(json, "color")) ? cast Reflect.field(json, "color") : null;
			if (c != null && Std.isOfType(c, Array) && c.length >= 3)
				cfg.color = [Std.int(c[0]), Std.int(c[1]), Std.int(c[2])];
			cfg.iconFramerate = readInt(json, "iconFramerate", 10);
			readStr(json, "iconPath", function(v) cfg.iconPath = v);
			readStr(json, "iconPath64", function(v) cfg.iconPath64 = v);
			readStr(json, "iconPath32", function(v) cfg.iconPath32 = v);
			readStr(json, "iconPath24", function(v) cfg.iconPath24 = v);
			readStr(json, "iconPath16", function(v) cfg.iconPath16 = v);
			cfg.useOldFPS = readBool(json, "useOldFPS", false);

			// ── Window ──
			readStr(json, "windowTitle", function(v) cfg.windowTitle = v);

			// ── State replacements ──
			readMap(json, "stateReplacements", cfg.stateReplacements);
			readMap(json, "substateReplacements", cfg.substateReplacements);

			// ── Discord ──
			readStr(json, "discordRPC", function(v) cfg.discordClientId = v);
			readStr(json, "discordLogoKey", function(v) cfg.discordLogoKey = v);
			readStr(json, "discordLogoText", function(v) cfg.discordLogoText = v);
		}
		catch (e:Dynamic)
		{
			TraceManager.error('trace.modConfig.loadError', 'Failed to load pack.json: {}', [e]);
		}
		#end
		return cfg;
	}

	// ── Runtime window‑icon helpers ──

	/**
	 * Set the native OS window icon from the given mod folder's pack.json.
	 * Picks the best‑fitting icon size (prefers 64×64, falls back through
	 * 32 → 24 → 16 → `iconPath`).
	 *
	 * Can be called at any time (e.g. after mod switching) to update the
	 * window icon in real time.  Silently fails (no crash) if the image
	 * file doesn't exist.
	 *
	 * @param modFolder  Folder name inside `mods/`.  If null/empty, no-op.
	 */
	#if (desktop && MODS_ALLOWED)
	public static function setWindowIcon(?modFolder:String):Void
	{
		if (modFolder == null || modFolder.length == 0) return;

		try
		{
			var cfg:ModConfig = ModConfig.load(modFolder);
			var relPath:String = cfg.getBestIconPath();
			if (relPath == null || relPath.length == 0) return;

			var fullPath:String = Paths.mods(modFolder + '/images/' + relPath + '.png');
			if (!sys.FileSystem.exists(fullPath))
			{
				// Try without 'images/' prefix (relative to mod root)
				fullPath = Paths.mods(modFolder + '/' + relPath + '.png');
				if (!sys.FileSystem.exists(fullPath)) return;
			}

			var bmp:BitmapData = BitmapData.fromFile(fullPath);
			if (bmp == null) return;

			// Scale down if larger than WINDOW_ICON_MAX_SIZE
			if (bmp.width > WINDOW_ICON_MAX_SIZE || bmp.height > WINDOW_ICON_MAX_SIZE)
			{
				var scale:Float = Math.min(WINDOW_ICON_MAX_SIZE / bmp.width, WINDOW_ICON_MAX_SIZE / bmp.height);
				var w:Int = Math.floor(bmp.width * scale);
				var h:Int = Math.floor(bmp.height * scale);
				var matrix:Matrix = new Matrix();
				matrix.scale(scale, scale);
				var resized:BitmapData = new BitmapData(w, h, true, 0);
				resized.draw(bmp, matrix, null, null, null, true);
				bmp = resized;
			}

			var iconImg:Image = Image.fromBitmapData(bmp);
			Lib.current.stage.window.setIcon(iconImg);
		}
		catch (e:Dynamic)
		{
			TraceManager.warn('trace.modConfig.iconError', 'Failed to set window icon: {}', [e]);
		}
	}
	#end

	/**
	 * Pick the best‑fitting icon path for the OS window icon.
	 * Priority: 64×64 → 32×32 → 24×24 → 16×16 → `iconPath`.
	 */
	public function getBestIconPath():String
	{
		if (iconPath64.length > 0) return iconPath64;
		if (iconPath32.length > 0) return iconPath32;
		if (iconPath24.length > 0) return iconPath24;
		if (iconPath16.length > 0) return iconPath16;
		if (iconPath.length > 0) return iconPath;
		return "";
	}

	// ── Compatibility helpers ──

	/** Returns true if the mod's API version is compatible with this engine. */
	public static function isCompatible(cfg:ModConfig):Bool
	{
		return cfg.apiVersion <= ENGINE_API_VERSION;
	}

	/** Returns a human-readable message if the mod is incompatible, or null. */
	public static function incompatibilityReason(cfg:ModConfig):Null<String>
	{
		if (cfg.apiVersion == 0) return null; // legacy, assume ok
		if (cfg.apiVersion > ENGINE_API_VERSION)
			return 'Mod requires API v${cfg.apiVersion}, engine only supports v$ENGINE_API_VERSION';
		return null;
	}

	// ── Internal helpers ──

	static function readStr(json:Dynamic, field:String, cb:String->Void):Void
	{
		if (json == null || !Reflect.hasField(json, field)) return;
		var v:Dynamic = Reflect.field(json, field);
		if (v != null && Std.isOfType(v, String) && Std.string(v).length > 0) cb(Std.string(v));
	}

	static function readInt(json:Dynamic, field:String, def:Int):Int
	{
		if (json == null || !Reflect.hasField(json, field)) return def;
		var v:Dynamic = Reflect.field(json, field);
		return (v != null && (Std.isOfType(v, Int) || Std.isOfType(v, Float))) ? Std.int(v) : def;
	}

	static function readBool(json:Dynamic, field:String, def:Bool):Bool
	{
		if (json == null || !Reflect.hasField(json, field)) return def;
		var v:Dynamic = Reflect.field(json, field);
		return (v != null && Std.isOfType(v, Bool)) ? v == true : def;
	}

	static function readStrArray(json:Dynamic, field:String, cb:Array<String>->Void):Void
	{
		if (json == null || !Reflect.hasField(json, field)) return;
		var v:Array<Dynamic> = cast Reflect.field(json, field);
		if (v != null && Std.isOfType(v, Array)) cb(v.map(function(e) return Std.string(e)));
	}

	static function readMap(json:Dynamic, field:String, target:Map<String, String>):Void
	{
		if (json == null || !Reflect.hasField(json, field)) return;
		var reps:Dynamic = Reflect.field(json, field);
		if (reps != null && Reflect.isObject(reps))
		{
			for (orig in Reflect.fields(reps))
			{
				var custom:String = Reflect.field(reps, orig);
				if (custom != null && custom.length > 0)
					target[orig] = custom;
			}
		}
	}
}
