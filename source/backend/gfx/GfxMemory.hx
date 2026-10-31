package backend.gfx;

import backend.gfx.GfxAtlasRepack.GfxRepackPlan;
import backend.gfx.GfxPalette.GfxPalettePlan;
import flixel.FlxG;
import flixel.FlxState;
import flixel.graphics.FlxGraphic;
import haxe.Timer;
import openfl.display.BitmapData;
import openfl.display3D.Context3D;
import openfl.geom.Rectangle;
import openfl.media.Sound;
import mohong.TraceManager;
import Paths;

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
private typedef GfxStatEntry = {
	key:String,
	bytes:Float,
	rgbaBytes:Float,
	gpuBytes:Float,
	dropped:Bool,
	textured:Bool,
	opaque:Bool,
	palette:Bool
};

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

	/**
	 * CPU bytes parked in VRAM before the sweep starts releasing anything.
	 *
	 * Releasing a copy that the running code is about to read again costs a full
	 * image decode, and the same scene gets read every frame, so an unconditional
	 * sweep turns into a drop/decode loop. Below this mark there is nothing worth
	 * winning, so the sweep stays out of the way.
	 */
	public static var sweepAboveBytes:Float = 96 * 1024 * 1024;

	public static var releasedCountTotal:Int = 0;
	public static var releasedBytesTotal:Float = 0;
	public static var restoredCountTotal:Int = 0;
	public static var restoredBytesTotal:Float = 0;
	public static var restoreFailTotal:Int = 0;

	/** State accounting is cheap: one snapshot per state switch, never per frame. */
	public static var stateStatsEnabled:Bool = true;
	static var stateName:String = '(boot)';
	static var stateStartedAt:Float = 0;
	static var stateCreateStartedAt:Float = 0;
	static var stateLoadMs:Float = 0;
	static var stateDecodeMs:Float = 0;
	static var stateDecodeCount:Int = 0;
	static var stateAudioMs:Float = 0;
	static var stateAudioCount:Int = 0;
	static var stateRestoreMs:Float = 0;
	static var stateRestoreCount:Int = 0;
	static var stateOpaqueScanMs:Float = 0;
	static var stateOpaqueCount:Int = 0;

	static var pending:Map<String, Int> = new Map();
	static var installed:Bool = false;
	static var frameCounter:Int = 0;
	static var sweepCounter:Int = 0;
	static var opaqueRGBChecked:Bool = false;
	static var opaqueRGBOn:Bool = true;
	static var croppedProbe:BitmapData = null;
	static var paletteRestoreChecked:Bool = false;

	public static var enabled(get, never):Bool;

	static inline function get_enabled():Bool
	{
		return ClientPrefs.data.gfxCpuRelease;
	}

	/** Opt-out switch for bisecting the RGB texture path: FNF_GFX_RGB=0. */
	static function useOpaqueRGB():Bool
	{
		if (!opaqueRGBChecked)
		{
			opaqueRGBChecked = true;
			#if sys
			opaqueRGBOn = Sys.getEnv('FNF_GFX_RGB') != '0';
			#end
		}
		return opaqueRGBOn;
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
		GfxPalette.init();
		FlxG.signals.preDraw.add(onPreDrawPalette);
		FlxG.signals.postDraw.add(onPostDraw);
		// preStateSwitch fires while the outgoing state and its bitmap cache still
		// exist; preStateCreate/postStateSwitch bracket the new state's create().
		FlxG.signals.preStateSwitch.add(onPreStateSwitch);
		FlxG.signals.preStateCreate.add(onPreStateCreate);
		FlxG.signals.postStateSwitch.add(onPostStateSwitch);
		stateStartedAt = Timer.stamp();
		TraceManager.info('trace.gfx.install',
			'GfxMemory ready (min {} px, {} drops/frame)', [Std.string(minPixels), Std.string(maxDropsPerFrame)]);
	}

	/**
	 * Attach a reload source to a freshly cached graphic. Safe to call more than
	 * once; the first source wins so aliases cannot overwrite the real path.
	 */
	public static function attach(graphic:FlxGraphic, ?source:String, ?region:Rectangle):Void
	{
		if (graphic == null || graphic.bitmap == null) return;
		if (region == null && graphic.gfxCropRect != null) region = graphic.gfxCropRect;

		var bmp = graphic.bitmap;
		var plan:GfxRepackPlan = cast graphic.gfxRepackPlan;
		if (plan != null && (bmp.width != plan.canvasW || bmp.height != plan.canvasH)) plan = null;

		if (!bmp.restorable)
		{
			var sourceKey:String = source != null && source.length > 0 ? source : graphic.assetsKey;
			if (sourceKey == null || sourceKey.length == 0) sourceKey = graphic.key;
			if (sourceKey == null || sourceKey.length == 0) return;

			var crop:Rectangle = region != null ? new Rectangle(region.x, region.y, region.width, region.height) : null;
			var size:Float = plan != null ? bmp.width * bmp.height * 4
				: (crop != null ? crop.width * crop.height * 4 : bmp.width * bmp.height * 4);
			bmp.setCPURestore(function()
			{
				var started:Float = Timer.stamp();
				var fresh:BitmapData = null;
				if (plan != null)
				{
					// L2b: decode the original, apply the recorded crop, then copy
					// the plan's fixed cells. Packing is never re-run here.
					fresh = GfxAtlasRepack.restore(sourceKey, plan);
				}
				else
				{
					fresh = GfxSource.load(sourceKey);
					if (fresh != null && crop != null)
					{
						var cropped = cropBitmap(fresh, crop);
						if (cropped != fresh) fresh.dispose();
						fresh = cropped;
					}
				}
				if (fresh == null)
				{
					restoreFailTotal++;
					return null;
				}
				stateRestoreMs += (Timer.stamp() - started) * 1000;
				stateRestoreCount++;
				restoredCountTotal++;
				// A graphic that had to be decoded again is in active use: keep its CPU
				// copy for a while instead of letting the next sweep drop it straight
				// back into the decode path.
				if (graphic.key != null) restoredAt.set(graphic.key, Timer.stamp());
				restoredBytesTotal += size;
				#if sys
				if (Sys.getEnv('FNF_GFX_TRACE') == '1')
					Sys.println('[GfxMemory] restore ' + sourceKey + ' (' + Std.string(size) + ' bytes)');
				#end
				return fresh;
			});

			if (plan != null || crop != null)
			{
				#if sys
				if (Sys.getEnv('FNF_GFX_SELFTEST') == '1') croppedProbe = bmp;
				#end
			}

			// L1a: prove the image is opaque once, then let BitmapData allocate a
			// 3-byte RGB texture (BGRA upload rows, alpha dropped by the driver).
			// A palette graphic already has its own index texture decision.
			if (!bmp.paletteApplied && useOpaqueRGB())
			{
				var scanStarted:Float = Timer.stamp();
				try bmp.enableOpaqueTexture() catch (e:Dynamic) {}
				stateOpaqueScanMs += (Timer.stamp() - scanStarted) * 1000;
				stateOpaqueCount++;
			}
		}

		#if sys
		// Deterministic palette restore check: do it on the first palette graphic
		// that gets a reload callback, not on whichever image happens to be
		// dropped first (that is timing-dependent).
		if (bmp.paletteApplied && !paletteRestoreChecked && Sys.getEnv('FNF_GFX_PALETTE_VERIFY') == '1')
		{
			paletteRestoreChecked = true;
			var plan:GfxPalettePlan = cast bmp.palettePlan;
			var ctx = FlxG.stage != null ? FlxG.stage.context3D : null;
			var valid:Bool = false;
			if (ctx != null && plan != null)
			{
				try
				{
					bmp.getTexture(ctx);
					var dropped:Bool = bmp.dropCPU();
					var restored:Bool = dropped && bmp.restoreCPU();
					valid = restored && GfxPalette.validateRestore(bmp, plan);
					if (restored) bmp.dropCPU();
				}
				catch (e:Dynamic) { valid = false; }
			}
			Sys.println('[GfxPalette] self-test restore ' + (valid ? 'OK' : 'FAILED') + ' ' + Std.string(bmp.width) + 'x' + Std.string(bmp.height));
		}
		#end

		if (graphic.key != null && eligible(bmp))
		{
			note(graphic.key);
			// Plain images and late loads are converted before the next draw.
			// Atlases already ran GfxPalette.apply() from Paths.finishAtlas().
			if (!bmp.paletteApplied) GfxPalette.queueGraphic(graphic);
		}
	}

	/** Record one synchronous image decode for the current state's load report. */
	public static function recordDecode(key:String, width:Int, height:Int, elapsedMs:Float):Void
	{
		if (!stateStatsEnabled || width <= 0 || height <= 0) return;
		stateDecodeCount++;
		if (elapsedMs > 0) stateDecodeMs += elapsedMs;
	}

	/** Record one synchronous audio decode/load for the current state's load report. */
	public static function recordAudioLoad(key:String, elapsedMs:Float):Void
	{
		if (!stateStatsEnabled) return;
		stateAudioCount++;
		if (elapsedMs > 0) stateAudioMs += elapsedMs;
	}

	/** Keys whose CPU copy was rebuilt recently, with the timestamp of the rebuild. */
	static var restoredAt:Map<String, Float> = new Map();

	/**
	 * A graphic that had to be decoded again is being read from the CPU by the
	 * running code, so releasing it only buys a drop followed by an immediate
	 * re-decode - the exact loop that produced multi-megabyte frame spikes. Those
	 * keys stay CPU-resident for the rest of the session; the sweep keeps working
	 * on everything that is genuinely idle.
	 */
	static function isReadBackGraphic(key:String):Bool
	{
		return restoredAt.exists(key);
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
		// Keep the sweep cadence: resetting the counter made every state switch drop
		// the whole cache again, which is what started the decode loop.
		GfxPalette.clearQueue();
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

	static function cropBitmap(source:BitmapData, region:Rectangle):BitmapData
	{
		return GfxAtlasCrop.cropRaw(source, region);
	}

	static function drop(bmp:BitmapData):Bool
	{
		// Palette bitmaps keep their index bytes (w*h) for texture/restore, so only
		// the 3 RGBA bytes per pixel are actually released.
		var bytes:Float = bmp.paletteApplied ? bmp.width * bmp.height * 3 : bmp.width * bmp.height * 4;
		if (!bmp.dropCPU()) return false;
		#if sys
		if (croppedProbe == bmp && Sys.getEnv('FNF_GFX_SELFTEST') == '1')
		{
			croppedProbe = null;
			var w:Int = bmp.width;
			var h:Int = bmp.height;
			var ok:Bool = bmp.restoreCPU();
			Sys.println('[GfxMemory] self-test cropped restore ' + (ok ? 'OK' : 'FAILED') + ' ' + Std.string(w) + 'x' + Std.string(h));
			if (ok) bmp.dropCPU();
		}
		#end
		#if sys
		if (!paletteRestoreChecked && bmp.paletteApplied && Sys.getEnv('FNF_GFX_PALETTE_VERIFY') == '1')
		{
			paletteRestoreChecked = true;
			var plan:GfxPalettePlan = cast bmp.palettePlan;
			var restored:Bool = bmp.restoreCPU();
			var valid:Bool = restored && plan != null && GfxPalette.validateRestore(bmp, plan);
			Sys.println('[GfxPalette] self-test restore ' + (valid ? 'OK' : 'FAILED') + ' ' + Std.string(bmp.width) + 'x' + Std.string(bmp.height));
			if (valid) bmp.dropCPU();
		}
		#end
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

	static function onPreStateSwitch():Void
	{
		if (!stateStatsEnabled) return;
		emitState('leave', (Timer.stamp() - stateStartedAt) * 1000);
	}

	static function onPreStateCreate(next:FlxState):Void
	{
		stateName = typeName(next);
		stateStartedAt = Timer.stamp();
		stateCreateStartedAt = stateStartedAt;
		stateLoadMs = 0;
		stateDecodeMs = 0;
		stateDecodeCount = 0;
		stateAudioMs = 0;
		stateAudioCount = 0;
		stateRestoreMs = 0;
		stateRestoreCount = 0;
		stateOpaqueScanMs = 0;
		stateOpaqueCount = 0;
	}

	static function onPostStateSwitch():Void
	{
		stateLoadMs = (Timer.stamp() - stateCreateStartedAt) * 1000;
		emitState('load', 0);
	}

	static inline function typeName(value:Dynamic):String
	{
		if (value == null) return '(none)';
		var cls = Type.getClass(value);
		if (cls == null) return '(unknown)';
		var name = Type.getClassName(cls);
		return name == null ? '(unknown)' : name;
	}

	/**
	 * Build and emit one state snapshot. Called only at state boundaries, so it
	 * may walk the bitmap cache and the tracked sounds once; it must never run
	 * from a per-frame path.
	 */
	static function emitState(phase:String, stateMs:Float):Void
	{
		if (!stateStatsEnabled) return;
		var ctx:Context3D = FlxG.stage != null ? FlxG.stage.context3D : null;
		var seen:Map<FlxGraphic, Bool> = new Map();
		var entries:Array<GfxStatEntry> = [];

		@:privateAccess
		for (key in FlxG.bitmap._cache.keys())
			addEntry(key, FlxG.bitmap._cache.get(key), ctx, seen, entries);
		for (key in Paths.currentTrackedAssets.keys())
			addEntry(key, Paths.currentTrackedAssets.get(key), ctx, seen, entries);

		var decoded:Float = 0;
		var rgba:Float = 0;
		var dropped:Float = 0;
		var gpu:Float = 0;
		var rgbCount:Int = 0;
		var paletteCount:Int = 0;
		var paletteSaved:Float = 0;
		for (entry in entries)
		{
			decoded += entry.bytes;
			rgba += entry.rgbaBytes;
			if (entry.dropped) dropped += entry.bytes;
			if (entry.textured) gpu += entry.gpuBytes;
			if (entry.opaque) rgbCount++;
			if (entry.palette)
			{
				paletteCount++;
				paletteSaved += entry.rgbaBytes - entry.bytes;
			}
		}

		var audioPCM:Float = 0;
		var audioFile:Float = 0;
		var audioCount:Int = 0;
		for (key in Paths.currentTrackedSounds.keys())
		{
			var snd:Sound = Paths.currentTrackedSounds.get(key);
			if (snd == null) continue;
			audioCount++;
			var buffer = @:privateAccess snd.__buffer;
			if (buffer != null && buffer.data != null) audioPCM += buffer.data.length;
			else audioFile += snd.bytesTotal;
		}

		var top:Array<GfxStatEntry> = entries.copy();
		top.sort(function(a:GfxStatEntry, b:GfxStatEntry):Int
		{
			if (a.bytes > b.bytes) return -1;
			if (a.bytes < b.bytes) return 1;
			return 0;
		});
		var topParts:Array<String> = [];
		var limit:Int = Std.int(Math.min(10, top.length));
		for (i in 0...limit)
			topParts.push(top[i].key + ':' + mb(top[i].bytes));

		var line:String = 'phase=' + phase + ' state=' + stateName
			+ ' images=' + Std.string(entries.length)
			+ ' decodedMB=' + mb(decoded)
			+ ' rgbaMB=' + mb(rgba)
			+ ' paletteTextures=' + Std.string(paletteCount)
			+ ' paletteSavedMB=' + mb(paletteSaved)
			+ ' cpuResidentMB=' + mb(decoded - dropped)
			+ ' cpuDroppedMB=' + mb(dropped)
			+ ' gpuMB=' + mb(gpu)
			+ ' rgbTextures=' + Std.string(rgbCount)
			+ ' audioPCMmb=' + mb(audioPCM)
			+ ' audioFileMB=' + mb(audioFile)
			+ ' audioCount=' + Std.string(audioCount)
			+ ' loadMs=' + round1(stateLoadMs)
			+ ' decodeMs=' + round1(stateDecodeMs)
			+ ' decodeCount=' + Std.string(stateDecodeCount)
			+ ' audioLoadMs=' + round1(stateAudioMs)
			+ ' audioLoadCount=' + Std.string(stateAudioCount)
			+ ' restoreMs=' + round1(stateRestoreMs)
			+ ' restoreCount=' + Std.string(stateRestoreCount)
			+ ' opaqueScanMs=' + round1(stateOpaqueScanMs)
			+ ' opaqueScanCount=' + Std.string(stateOpaqueCount)
			+ ' stateMs=' + round1(stateMs)
			+ ' top=' + (topParts.length == 0 ? '(none)' : topParts.join(','));

		TraceManager.info('trace.gfx.state', 'GfxState ' + line);
		#if sys
		if (Sys.getEnv('FNF_GFX_TRACE') == '1')
			Sys.println('[GfxState] ' + line);
		#end
	}

	static function addEntry(key:String, graphic:FlxGraphic, ctx:Context3D, seen:Map<FlxGraphic, Bool>, entries:Array<GfxStatEntry>):Void
	{
		if (graphic == null || graphic.bitmap == null || seen.exists(graphic)) return;
		seen.set(graphic, true);
		var bmp:BitmapData = graphic.bitmap;
		var rgbaBytes:Float = bmp.width * bmp.height * 4;
		var bytes:Float = bmp.storedBytes;
		var gpuBytes:Float = bmp.textureBytes;
		var textured:Bool = ctx != null && bmp.hasTexture(ctx) && gpuBytes > 0;
		entries.push({
			key: key == null ? '(nokey)' : key,
			bytes: bytes,
			rgbaBytes: rgbaBytes,
			gpuBytes: gpuBytes,
			dropped: bmp.cpuReleased,
			textured: textured,
			opaque: bmp.opaqueTexture && gpuBytes > 0 && gpuBytes < bytes,
			palette: bmp.paletteApplied
		});
	}

	static inline function round1(value:Float):String
	{
		return Std.string(Math.round(value * 10) / 10);
	}

	static function onPreDrawPalette():Void
	{
		try GfxPalette.onPreDraw() catch (e:Dynamic)
		{
			TraceManager.warn('trace.gfx.paletteQueue', 'GfxPalette queue error: {}', [Std.string(e)]);
		}
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
			// Only release CPU copies once holding them actually costs something.
			if (liveBytes() >= sweepAboveBytes)
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
			if (isReadBackGraphic(key)) continue;
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
			total += graphic.bitmap.storedBytes;
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
