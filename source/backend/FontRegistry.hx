package backend;

import lime.system.System as LimeSystem;
import mohong.TraceManager;
import openfl.text.Font;

#if sys
import sys.FileSystem;
#end

/**
 * Fallback resolution for bundled fonts.
 *
 * `FlxText.setFormat()` accepts a font key and asks openfl whether it exists:
 * `Assets.exists(key, FONT)` matches the asset manifest, then
 * `Assets.getFont(key).fontName` reads the file through lime. When that read
 * fails (the manifest and lime's asset root disagree about where the file is, or
 * the extraction never produced it) openfl returns an *empty* Font, its
 * `fontName` is null, and every text object silently falls back to the platform
 * font: the "fonts are not mounted" report.
 *
 * This class only runs for fonts the working directory cannot provide. It looks
 * for the bundled copy in the places a packaged build can keep it, loads the first
 * real file with `Font.fromFile()` and registers it, then returns the family name.
 */
class FontRegistry
{
	/** Font key -> usable name (the original key when nothing could be loaded). */
	static var resolved:Map<String, String> = new Map<String, String>();
	/** Keys already reported, so a broken install logs one line per font. */
	static var warned:Map<String, Bool> = new Map<String, Bool>();
	static var appDir:String = null;

	/**
	 * @param key          the key the caller asked for (`Paths.font(key)`)
	 * @param relativePath the path the engine uses for it, relative to the working directory
	 */
	public static function resolve(key:String, relativePath:String):String
	{
		if (resolved.exists(key))
		{
			return resolved.get(key);
		}

		var result:String = relativePath;

		#if sys
		// Normal case: the extracted copy is there. Leave the path alone - the asset
		// system and the file system both resolve a path, a family name only the font
		// registry.
		var present:Bool = false;
		try
		{
			present = FileSystem.exists(relativePath);
		}
		catch (e:Dynamic) {}

		if (present)
		{
			resolved.set(key, result);
			return result;
		}

		for (candidate in candidates(relativePath))
		{
			var exists:Bool = false;
			try
			{
				exists = FileSystem.exists(candidate);
			}
			catch (e:Dynamic) {}
			if (!exists)
			{
				continue;
			}

			try
			{
				var font:Font = Font.fromFile(candidate);
				if (font != null && font.fontName != null && font.fontName.length > 0)
				{
					Font.registerFont(font);
					result = font.fontName;
					TraceManager.info('trace.fonts.bundleFallback',
						'Font {} resolved from the bundled copy {} (family {})', [key, candidate, result]);
					break;
				}
			}
			catch (e:Dynamic)
			{
				TraceManager.warn('trace.fonts.loadFailed', 'Could not load font file {}: {}', [candidate, e]);
			}
		}

		if (result == relativePath && !warned.exists(key))
		{
			warned.set(key, true);
			TraceManager.warn('trace.fonts.unresolved',
				'Font {} is neither in the working directory nor in the bundle; text will use a fallback font', [key]);
		}
		#end

		resolved.set(key, result);
		return result;
	}

	/**
	 * Places the bundled copy of `relativePath` can live, in priority order: lime
	 * prefixes asset reads with `assets/` (ManifestResources.rootPath on native), the
	 * application directory is the bundle (iOS, macOS) or the install folder, and a
	 * portable build keeps everything next to the executable.
	 */
	static function candidates(relativePath:String):Array<String>
	{
		var list:Array<String> = [];
		var dir:String = applicationDirectory();

		if (dir != null && dir.length > 0)
		{
			if (!dir.endsWith('/'))
			{
				dir += '/';
			}
			list.push(dir + relativePath);
			list.push(dir + 'assets/' + relativePath);
		}

		#if sys
		try
		{
			var exeDir:String = haxe.io.Path.directory(Sys.programPath());
			if (exeDir != null && exeDir.length > 0)
			{
				if (!exeDir.endsWith('/') && !exeDir.endsWith('\\'))
				{
					exeDir += '/';
				}
				list.push(exeDir + relativePath);
				list.push(exeDir + 'assets/' + relativePath);
				list.push(exeDir + '../Resources/' + relativePath);
				list.push(exeDir + '../Resources/assets/' + relativePath);
			}
		}
		catch (e:Dynamic) {}
		#end

		list.push(relativePath);
		return list;
	}

	static function applicationDirectory():String
	{
		if (appDir != null)
		{
			return appDir;
		}
		try
		{
			appDir = LimeSystem.applicationDirectory;
		}
		catch (e:Dynamic)
		{
			appDir = null;
		}
		if (appDir == null)
		{
			appDir = '';
		}
		return appDir;
	}
}
