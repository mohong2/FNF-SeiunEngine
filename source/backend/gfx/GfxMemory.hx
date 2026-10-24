package backend.gfx;

import flixel.FlxG;
import flixel.graphics.FlxGraphic;
import openfl.display.BitmapData;
import mohong.TraceManager;

/**
 * Image residency backend.
 *
 * The only resource this class manages is the CPU copy of a decoded image.
 * Large images are uploaded to the GPU during normal rendering, then their
 * CPU buffer is released. The GPU texture keeps rendering exactly as before,
 * and any later pixel access re-decodes the image through GfxSource.
 *
 * Design rules (learned from the old GfxLru/GfxPolicy backend):
 *  - no private strong-reference cache of FlxGraphic objects;
 *  - no manual FlxGraphic.destroy() and no cache eviction from here;
 *  - no forced GC, no GC disable/enable, no native-thread publishing;
 *  - all work happens on the main thread after a draw, never inside create().
 *
 * Graphics created by the engine (text canvases, generated bars, ...) have no
 * reload source and are never touched.
 */
class GfxMemory
{
	/** Minimum RGBA pixel count before a CPU copy is worth releasing (~1 MB). */
	public static var minPixels:Int = 512 * 512;

	/** How many queued images may be released in one rendered frame. */
	public static var maxDropsPerFrame:Int = 4;

	/** Frames an unpainted image may wait before its texture is forced. */
	public static var forceUploadAfterFrames:Int = 120;

	/** Re-scan the cache every N rendered frames for context-restored images. */
	public static var sweepIntervalFrames:Int = 120;

	public static var releasedCountTotal:Int = 0;
	public static var releasedBytesTotal:Float = 0;
	public static var restoredCountTotal:Int = 0;
	public static var restoredBytesTotal:Float = 0;
	public static var restoreFailTotal:Int = 0;

	static var pending:Map<String, Int> = new Map();
	static var installed:Bool = false;
	static var frameCounter:Int = 0;
	static var sweepCounter:Int = 0;

	public static var enabled(get, never):Bool;

	static inline function get_enabled():Bool
	{
		return ClientPrefs.data.gfxCpuRelease;
	}

	static inline function eligible(bmp:BitmapData):Bool
	{
		return bmp != null && bmp.restorable && bmp.hasCPU && bmp.width > 0 && bmp.height > 0
			&& bmp.width * bmp.height >= minPixels;
	}

	public static function install():Void
	{
		if (installed) return;
		installed = true;
		FlxG.signals.postDraw.add(onPostDraw);
		TraceManager.info('trace.gfx.install',
			'GfxMemory ready (min {} px, {} drops/frame)', [Std.string(minPixels), Std.string(maxDropsPerFrame)]);
	}

	/**
	 * Attach a reload source to a freshly cached graphic. Safe to call more than
	 * once; the first source wins so aliases cannot overwrite the real path.
	 */
	public static function attach(graphic:FlxGraphic, ?source:String):Void
	{
		if (graphic == null || graphic.bitmap == null) return;

		var bmp = graphic.bitmap;
		if (!bmp.restorable)
		{
			var sourceKey:String = source != null && source.length > 0 ? source : graphic.assetsKey;
			if (sourceKey == null || sourceKey.length == 0) return;

			var size:Float = bmp.width * bmp.height * 4;
			bmp.setCPURestore(function()
			{
				var fresh = GfxSource.load(sourceKey);
				if (fresh == null)
				{
					restoreFailTotal++;
					return null;
				}
				restoredCountTotal++;
				restoredBytesTotal += size;
				#if sys
				if (Sys.getEnv('FNF_GFX_TRACE') == '1')
					Sys.println('[GfxMemory] restore ' + sourceKey + ' (' + Std.string(size) + ' bytes)');
				#end
				return fresh;
			});
		}

		if (graphic.key != null && eligible(bmp))
			note(graphic.key);
	}

	/** Queue one key for release after the next draws have uploaded it. */
	public static function note(key:String):Void
	{
		if (key == null || key.length == 0) return;
		if (!pending.exists(key)) pending.set(key, 0);
	}

	/** Forget queued keys when the active state goes away. */
	public static function onStateSwitch():Void
	{
		pending = new Map();
		sweepCounter = 0;
	}

	/**
	 * Release one graphic now, forcing the upload only if it is already in the
	 * current context or can be uploaded safely. Returns true when pixels moved
	 * from RAM to VRAM.
	 */
	public static function releaseNow(graphic:FlxGraphic):Bool
	{
		if (!enabled || graphic == null || graphic.bitmap == null) return false;
		var bmp = graphic.bitmap;
		if (!eligible(bmp) || bmp.cpuReleased) return false;

		var ctx = FlxG.stage != null ? FlxG.stage.context3D : null;
		if (ctx == null) return false;

		if (!bmp.hasTexture(ctx))
		{
			try bmp.getTexture(ctx, false) catch (e:Dynamic) { return false; }
		}
		if (!bmp.hasTexture(ctx)) return false;

		return drop(bmp);
	}

	static function drop(bmp:BitmapData):Bool
	{
		var bytes:Float = bmp.width * bmp.height * 4;
		if (!bmp.dropCPU()) return false;
		releasedCountTotal++;
		releasedBytesTotal += bytes;
		if (releasedCountTotal == 1)
		{
			TraceManager.info('trace.gfx.firstDrop',
				'GfxMemory: first CPU release ({}x{}, {} MB RAM -> VRAM)',
				[Std.string(bmp.width), Std.string(bmp.height), mb(bytes)]);
			#if sys
			if (Sys.getEnv('FNF_GFX_TRACE') == '1')
				Sys.println('[GfxMemory] first drop ' + Std.string(bmp.width) + 'x' + Std.string(bmp.height)
					+ ' (' + mb(bytes) + ' MB)');
			// Opt-in device self-test: prove that the reload callback can rebuild
			// the CPU buffer and that the texture path survives the round trip.
			if (Sys.getEnv('FNF_GFX_SELFTEST') == '1')
			{
				var restored:Bool = bmp.restoreCPU();
				Sys.println('[GfxMemory] self-test restore ' + (restored ? 'OK' : 'FAILED'));
				if (restored) bmp.dropCPU();
			}
			#end
		}
		return true;
	}

	static function onPostDraw():Void
	{
		if (!enabled) return;
		frameCounter++;
		try
		{
			processPending();
		}
		catch (e:Dynamic)
		{
			TraceManager.warn('trace.gfx.queue', 'GfxMemory queue error: {}', [Std.string(e)]);
		}

		sweepCounter++;
		if (sweepCounter >= sweepIntervalFrames)
		{
			sweepCounter = 0;
			try sweepCache() catch (e:Dynamic) {}
		}
	}

	static function processPending():Void
	{
		if (!pending.keys().hasNext()) return;

		var ctx = FlxG.stage != null ? FlxG.stage.context3D : null;
		if (ctx == null) return;

		var budget:Int = maxDropsPerFrame;
		var remove:Array<String> = [];
		var update:Array<{key:String, waited:Int}> = [];

		for (key => waited in pending)
		{
			if (budget <= 0) break;

			var graphic = FlxG.bitmap.get(key);
			if (graphic == null || graphic.bitmap == null)
			{
				remove.push(key);
				continue;
			}

			var bmp = graphic.bitmap;
			if (bmp.cpuReleased || !bmp.hasCPU || !bmp.restorable || !eligible(bmp))
			{
				remove.push(key);
				continue;
			}

			if (bmp.hasTexture(ctx))
			{
				drop(bmp);
				remove.push(key);
				budget--;
			}
			else if (waited >= forceUploadAfterFrames)
			{
				// The image never reached the renderer (hidden layer, precached
				// asset, ...). Upload once after the grace period, then release.
				try bmp.getTexture(ctx, false) catch (e:Dynamic) {}
				if (bmp.hasTexture(ctx)) drop(bmp);
				remove.push(key);
				budget--;
			}
			else
			{
				update.push({key: key, waited: waited + 1});
			}
		}

		for (key in remove) pending.remove(key);
		for (item in update) pending.set(item.key, item.waited);
	}

	/**
	 * Re-queue large CPU-resident images that already have a texture. This is
	 * how graphics are dropped again after a GL context restore (OpenFL
	 * re-decodes them in getTexture) without any context-loss hook.
	 */
	static function sweepCache():Void
	{
		var ctx = FlxG.stage != null ? FlxG.stage.context3D : null;
		if (ctx == null) return;

		@:privateAccess
		for (key in FlxG.bitmap._cache.keys())
		{
			var graphic = FlxG.bitmap._cache.get(key);
			if (graphic == null || graphic.bitmap == null) continue;
			var bmp = graphic.bitmap;
			if (bmp.cpuReleased || !bmp.hasCPU || !bmp.restorable || !eligible(bmp)) continue;
			if (bmp.hasTexture(ctx)) note(key);
		}
	}

	/** CPU bytes currently parked in VRAM across the FlxG bitmap cache. */
	public static function liveBytes():Float
	{
		var total:Float = 0;
		var seen:Map<FlxGraphic, Bool> = new Map();
		@:privateAccess
		for (key in FlxG.bitmap._cache.keys())
		{
			var graphic = FlxG.bitmap._cache.get(key);
			if (graphic == null || graphic.bitmap == null || !graphic.bitmap.cpuReleased || seen.exists(graphic)) continue;
			seen.set(graphic, true);
			total += graphic.bitmap.width * graphic.bitmap.height * 4;
		}
		return total;
	}

	public static function liveCount():Int
	{
		var total:Int = 0;
		var seen:Map<FlxGraphic, Bool> = new Map();
		@:privateAccess
		for (key in FlxG.bitmap._cache.keys())
		{
			var graphic = FlxG.bitmap._cache.get(key);
			if (graphic == null || graphic.bitmap == null || !graphic.bitmap.cpuReleased || seen.exists(graphic)) continue;
			seen.set(graphic, true);
			total++;
		}
		return total;
	}

	public static function pendingCount():Int
	{
		return Lambda.count(pending);
	}

	public static function statsLine():String
	{
		return 'GfxMemory: cpuDropped=' + Std.string(liveCount())
			+ ' (~' + mb(liveBytes()) + ' MB RAM->VRAM), released=' + Std.string(releasedCountTotal)
			+ ' (~' + mb(releasedBytesTotal) + ' MB total), restored=' + Std.string(restoredCountTotal)
			+ ', restoreFail=' + Std.string(restoreFailTotal) + ', pending=' + Std.string(pendingCount());
	}

	static inline function mb(bytes:Float):String
	{
		return Std.string(Math.round(bytes / 1048576 * 10) / 10);
	}
}
