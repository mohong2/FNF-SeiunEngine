package backend.gfx;

import openfl.display.BitmapData;
import openfl.utils.AssetType;
import openfl.utils.Assets as OpenFlAssets;

#if sys
import sys.FileSystem;
#end

/**
 * Re-decodes an image from the same source key the engine originally used.
 *
 * This is the only place the residency manager touches storage. It never goes
 * through Paths/FlxG caches, so a restore can never recurse back into the
 * graphic cache or resurrect a destroyed FlxGraphic.
 */
class GfxSource
{
	public static function load(key:String):BitmapData
	{
		if (key == null || key.length == 0) return null;

		var candidates:Array<String> = [];
		add(candidates, key);

		#if sys
		var colon:Int = key.indexOf(':');
		if (colon > 0)
		{
			add(candidates, key.substr(colon + 1));
		}
		for (candidate in candidates.copy())
		{
			try
			{
				if (FileSystem.exists(candidate) && !FileSystem.isDirectory(candidate))
				{
					var bmp = BitmapData.fromFile(candidate);
					if (bmp != null) return bmp;
				}
			}
			catch (e:Dynamic) {}
		}
		#end

		// Try the original key first, then the prefix-stripped form, then the
		// shared-library alias used by older Psych assets.
		for (candidate in candidates)
		{
			var result = tryAsset(candidate);
			if (result != null) return result;
		}

		#if sys
		if (key.startsWith('assets/shared/'))
			return tryAsset('shared:' + key);
		var colon2:Int = key.indexOf(':');
		if (colon2 > 0)
		{
			var rest:String = key.substr(colon2 + 1);
			if (rest.startsWith('assets/shared/'))
				return tryAsset('shared:' + rest);
		}
		#end

		return null;
	}

	static function tryAsset(key:String):BitmapData
	{
		if (key == null || key.length == 0) return null;
		try
		{
			if (!OpenFlAssets.exists(key, AssetType.IMAGE)) return null;
			var bmp = OpenFlAssets.getBitmapData(key);
			// Match Paths.getBitmapDataOnce(): OpenFL must not retain a second
			// strong reference to pixels that the FlxGraphic now owns.
			try openfl.Assets.cache.removeBitmapData(key) catch (e:Dynamic) {}
			return bmp;
		}
		catch (e:Dynamic)
		{
			return null;
		}
	}

	static inline function add(list:Array<String>, value:String):Void
	{
		if (value != null && value.length > 0 && list.indexOf(value) < 0)
			list.push(value);
	}
}
