package backend.gfx;

import backend.gfx.GfxAtlasRepack.GfxRepackPlan;
import backend.gfx.GfxPalette.GfxPalettePlan;
import flixel.FlxG;
import flixel.FlxState;
import flixel.graphics.FlxGraphic;
import haxe.Timer;
import lime.graphics.opengl.GL;
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
 *  - no forced GC during play; a single deferred collection may run a couple
 *    of frames after a load commit to reclaim the buffers that commit released;
 *  - lazy work happens after a draw; load-time commits happen only at explicit
 *    load boundaries (a boot preload item / the end of a state create), never
 *    from inside a Paths loader where the bitmap may still be post-processed.
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

private typedef CommitStats = {
	var uploaded:Int;
	var dropped:Int;
	var failed:Int;
	var skipped:Int;
	var bytes:Float;
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

	/**
	 * Eager commit at load boundaries.
	 *
	 * Loading already pays the decode cost behind a loading bar / transition; the
	 * GPU upload and CPU release belong there too. Leaving them to the lazy
	 * after-draw queue means the first gameplay frames visibly drain hundreds of
	 * megabytes (and hitch while they do it). A commit is only run where the
	 * loader has finished post-processing a graphic, so it cannot race the atlas
	 * crop/repack/palette stages.
	 *
	 * FNF_GFX_COMMIT=0 turns it off (bisecting / comparison runs).
	 */
	public static var commitEnabled(default, null):Bool = true;

	/** Bytes uploaded and CPU copies released by load-time commits. */
	public static var committedCountTotal:Int = 0;
	public static var committedBytesTotal:Float = 0;
	public static var commitMsTotal:Float = 0;

	static var commitChecked:Bool = false;
	/** Draw frame at which a load commit's freed buffers are collected; -1 = none. */
	static var collectAtFrame:Int = -1;
	static var maxTextureSize:Int = -1;
	static var timelineChecked:Bool = false;
	static var timelineEnabled:Bool = false;
	static var timelineFrames:Int = 0;

	static inline var COMMIT_DONE:Int = 0;
	static inline var COMMIT_RETRY:Int = 1;

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

	static function commitOn():Bool
	{
		if (!commitChecked)
		{
			commitChecked = true;
			#if sys
			var raw:String = Sys.getEnv('FNF_GFX_COMMIT');
			if (raw == '0') commitEnabled = false;
			#end
		}
		return commitEnabled;
	}

	/** Largest rectangle texture the driver accepts, 0 when it cannot be queried. */
	static function gpuMaxTextureSize(ctx:Context3D):Int
	{
		if (maxTextureSize >= 0) return maxTextureSize;
		maxTextureSize = 0;
		try
		{
			if (ctx != null)
			{
				var gl = @:privateAccess ctx.gl;
				if (gl != null) maxTextureSize = cast gl.getParameter(GL.MAX_TEXTURE_SIZE);
			}
		}
		catch (e:Dynamic) {}
		return maxTextureSize;
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

	/**
	 * Commit every loaded graphic now: apply the palette decision, upload the
	 * texture and release the CPU pixels. Called at load boundaries (after a
	 * boot preload item, after a state's create) where the loader has already
	 * finished crop/repack/palette, so it can never race those stages.
	 *
	 * Returns false when there is no GL context (the lazy queue then keeps the
	 * graphics for the normal after-draw path).
	 */
	public static function commitAll(reason:String = 'load'):Bool
	{
		if (!enabled || !commitOn()) return false;
		var ctx:Context3D = FlxG.stage != null ? FlxG.stage.context3D : null;
		if (ctx == null) return false;

		var started:Float = Timer.stamp();
		var paletted:Int = 0;
		try paletted = GfxPalette.flushQueue() catch (e:Dynamic)
		{
			TraceManager.warn('trace.gfx.commitPalette', 'GfxPalette flush failed: {}', [Std.string(e)]);
		}

		var stats:CommitStats = {uploaded: 0, dropped: 0, failed: 0, skipped: 0, bytes: 0};
		var seen:Map<FlxGraphic, Bool> = new Map();
		@:privateAccess
		for (key in FlxG.bitmap._cache.keys())
			commitGraphic(key, FlxG.bitmap._cache.get(key), ctx, seen, stats);
		for (key in Paths.currentTrackedAssets.keys())
			commitGraphic(key, Paths.currentTrackedAssets.get(key), ctx, seen, stats);

		// Keep only the keys whose upload failed: everything else was either
		// committed or is not eligible, and keeping those would only make
		// processPending revisit them every frame.
		var retry:Map<String, Int> = new Map();
		for (key in pending.keys())
		{
			var graphic:FlxGraphic = FlxG.bitmap.get(key);
			if (graphic == null) graphic = Paths.currentTrackedAssets.get(key);
			if (graphic == null || graphic.bitmap == null) continue;
			var bmp:BitmapData = graphic.bitmap;
			if (!bmp.cpuReleased && bmp.hasCPU && bmp.restorable && eligible(bmp) && !bmp.hasTexture(ctx))
				retry.set(key, 0);
		}
		pending = retry;

		var elapsed:Float = (Timer.stamp() - started) * 1000;
		commitMsTotal += elapsed;
		committedCountTotal += stats.dropped;
		committedBytesTotal += stats.bytes;
		if (stats.dropped > 0 && collectAtFrame < 0)
		{
			#if cpp
			// Collect a couple of draw frames after the load boundary: the first
			// draw still holds decoded staging references, and by then the
			// transition covers the frame while the FPS overlay (100 ms sampling)
			// has not seen the pre-commit heap value. Scheduling it here also covers
			// the boot finish, which does not go through a state switch.
			collectAtFrame = frameCounter + gcDelayFrames();
			#end
		}
		var line:String = 'reason=' + reason
			+ ' palette=' + Std.string(paletted)
			+ ' uploads=' + Std.string(stats.uploaded)
			+ ' drops=' + Std.string(stats.dropped)
			+ ' freedMB=' + mb(stats.bytes)
			+ ' failed=' + Std.string(stats.failed)
			+ ' skipped=' + Std.string(stats.skipped)
			+ ' ms=' + round1(elapsed)
			+ ' cpuResidentMB=' + mb(residentBytes());
		if (paletted > 0 || stats.uploaded > 0 || stats.dropped > 0 || stats.failed > 0)
		{
			TraceManager.info('trace.gfx.commit', 'GfxCommit ' + line);
			#if sys
			if (traceTimelineEnabled()) Sys.println('[GfxCommit] ' + line);
			#end
		}
		return true;
	}

	/**
	 * Commit only the images queued since the last call. Used by the boot
	 * preloader, which loads one asset per frame: each item is uploaded and its
	 * CPU copy released before the next item starts, so the loading bar shows
	 * real progress instead of a two-second drain after it.
	 */
	public static function commitPending(reason:String = 'load'):Void
	{
		if (!enabled || !commitOn() || !pending.keys().hasNext()) return;
		var ctx:Context3D = FlxG.stage != null ? FlxG.stage.context3D : null;
		if (ctx == null) return;

		var started:Float = Timer.stamp();
		try GfxPalette.flushQueue() catch (e:Dynamic) {}
		var stats:CommitStats = {uploaded: 0, dropped: 0, failed: 0, skipped: 0, bytes: 0};
		var seen:Map<FlxGraphic, Bool> = new Map();
		var remove:Array<String> = [];
		for (key in pending.keys())
		{
			var graphic:FlxGraphic = FlxG.bitmap.get(key);
			if (graphic == null) graphic = Paths.currentTrackedAssets.get(key);
			if (graphic == null)
			{
				remove.push(key);
				continue;
			}
			if (commitGraphic(key, graphic, ctx, seen, stats) == COMMIT_DONE) remove.push(key);
		}
		for (key in remove) pending.remove(key);

		var elapsed:Float = (Timer.stamp() - started) * 1000;
		if (stats.dropped > 0 || stats.failed > 0)
		{
			commitMsTotal += elapsed;
			committedCountTotal += stats.dropped;
			committedBytesTotal += stats.bytes;
			var line:String = 'reason=' + reason
				+ ' uploads=' + Std.string(stats.uploaded)
				+ ' drops=' + Std.string(stats.dropped)
				+ ' freedMB=' + mb(stats.bytes)
				+ ' failed=' + Std.string(stats.failed)
				+ ' ms=' + round1(elapsed)
				+ ' cpuResidentMB=' + mb(residentBytes());
			TraceManager.info('trace.gfx.commit', 'GfxCommit ' + line);
			#if sys
			if (traceTimelineEnabled()) Sys.println('[GfxCommit] ' + line);
			#end
		}
	}

	static function commitGraphic(key:String, graphic:FlxGraphic, ctx:Context3D, seen:Map<FlxGraphic, Bool>, stats:CommitStats):Int
	{
		if (graphic == null || graphic.bitmap == null) return COMMIT_DONE;
		if (seen.exists(graphic)) return COMMIT_DONE;
		seen.set(graphic, true);

		var bmp:BitmapData = graphic.bitmap;
		if (bmp.cpuReleased) return COMMIT_DONE;
		if (!bmp.hasCPU || !bmp.restorable || !eligible(bmp)) return COMMIT_DONE;

		var limit:Int = gpuMaxTextureSize(ctx);
		if (limit > 0 && (bmp.width > limit || bmp.height > limit))
		{
			stats.skipped++;
			return COMMIT_DONE;
		}

		if (!bmp.hasTexture(ctx))
		{
			try bmp.getTexture(ctx, false) catch (e:Dynamic)
			{
				stats.failed++;
				return COMMIT_RETRY;
			}
			if (bmp.hasTexture(ctx)) stats.uploaded++;
		}

		if (!bmp.hasTexture(ctx))
		{
			stats.failed++;
			return COMMIT_RETRY;
		}

		if (drop(bmp))
		{
			stats.dropped++;
			stats.bytes += bmp.paletteApplied ? bmp.width * bmp.height * 3 : bmp.width * bmp.height * 4;
		}
		else
		{
			stats.failed++;
		}
		return COMMIT_DONE;
	}

	/** RGBA bytes still held by readable CPU copies across the bitmap cache. */
	static function residentBytes():Float
	{
		var total:Float = 0;
		var seen:Map<FlxGraphic, Bool> = new Map();
		@:privateAccess
		for (key in FlxG.bitmap._cache.keys())
		{
			var graphic = FlxG.bitmap._cache.get(key);
			if (graphic == null || graphic.bitmap == null || seen.exists(graphic)) continue;
			seen.set(graphic, true);
			if (graphic.bitmap.hasCPU) total += graphic.bitmap.width * graphic.bitmap.height * 4;
		}
		return total;
	}

	/** Frames after a load commit before the reclaiming collection (FNF_GFX_GC_DELAY). */
	static function gcDelayFrames():Int
	{
		#if sys
		var raw:String = Sys.getEnv('FNF_GFX_GC_DELAY');
		if (raw != null && raw.length > 0)
		{
			var parsed:Null<Int> = Std.parseInt(raw);
			if (parsed != null && parsed >= 0) return parsed;
		}
		#end
		return 2;
	}

	static function traceTimelineEnabled():Bool
	{
		if (!timelineChecked)
		{
			timelineChecked = true;
			#if sys
			timelineEnabled = Sys.getEnv('FNF_GFX_TRACE') == '1';
			#end
		}
		return timelineEnabled;
	}

	/** One diagnostic line every 60 draw frames; only with FNF_GFX_TRACE=1. */
	static function traceTimeline():Void
	{
		if (!traceTimelineEnabled()) return;
		if ((++timelineFrames % 60) != 0) return;

		var ctx:Context3D = FlxG.stage != null ? FlxG.stage.context3D : null;
		var dropped:Float = 0;
		var droppedCount:Int = 0;
		var textured:Int = 0;
		var seen:Map<FlxGraphic, Bool> = new Map();
		@:privateAccess
		for (key in FlxG.bitmap._cache.keys())
		{
			var graphic = FlxG.bitmap._cache.get(key);
			if (graphic == null || graphic.bitmap == null || seen.exists(graphic)) continue;
			seen.set(graphic, true);
			if (graphic.bitmap.cpuReleased)
			{
				dropped += graphic.bitmap.storedBytes;
				droppedCount++;
			}
			if (ctx != null && graphic.bitmap.hasTexture(ctx)) textured++;
		}
		Sys.println('[GfxTimeline] f=' + Std.string(frameCounter)
			+ ' residentMB=' + mb(residentBytes())
			+ ' releasedMB=' + mb(dropped)
			+ ' released=' + Std.string(droppedCount)
			+ ' textured=' + Std.string(textured)
			+ ' pending=' + Std.string(pendingCount())
			+ ' heapMB=' + mb(openfl.system.System.totalMemory));
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
		// Every state's create() runs before its first draw. Committing here means
		// the palette decision, texture upload and CPU release all happen while the
		// transition/loading screen still owns the frame, so gameplay starts at its
		// steady-state memory instead of draining it visibly for the first seconds.
		if (commitOn() && isCommitState(stateName))
		{
			try commitAll('state:' + stateName) catch (e:Dynamic)
			{
				TraceManager.warn('trace.gfx.commitState', 'GfxCommit {} failed: {}', [stateName, Std.string(e)]);
			}
		}
		emitState('load', 0);
	}

	/** Crash recovery must not allocate textures or walk every graphic. */
	static function isCommitState(name:String):Bool
	{
		if (name == null) return true;
		return name.indexOf('CrashCatcherState') < 0 && name.indexOf('GfxPaletteProbeState') < 0;
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
			// liveBytes() counts *released* bytes, which is not the policy input;
			// residentBytes() is the RGBA still held by readable copies.
			if (residentBytes() >= sweepAboveBytes)
				try sweepCache() catch (e:Dynamic) {}
		}

		#if cpp
		if (collectAtFrame >= 0 && frameCounter >= collectAtFrame)
		{
			collectAtFrame = -1;
			var traceGc:Bool = traceTimelineEnabled();
			if (traceGc) Sys.println('[GfxGC] deferred f=' + Std.string(frameCounter) + ' before heapMB=' + mb(openfl.system.System.totalMemory));
			var gcStarted:Float = Timer.stamp();
			try backend.GcState.collect() catch (e:Dynamic) {}
			if (traceGc) Sys.println('[GfxGC] deferred f=' + Std.string(frameCounter) + ' after heapMB=' + mb(openfl.system.System.totalMemory)
				+ ' ms=' + round1((Timer.stamp() - gcStarted) * 1000));
		}
		#end

		try traceTimeline() catch (e:Dynamic) {}
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
			+ ' (~' + mb(liveBytes()) + ' MB RAM->VRAM), resident=' + mb(residentBytes())
			+ ' MB, committed=' + Std.string(committedCountTotal) + ' (~' + mb(committedBytesTotal) + ' MB in ' + round1(commitMsTotal) + ' ms)'
			+ ', released=' + Std.string(releasedCountTotal)
			+ ' (~' + mb(releasedBytesTotal) + ' MB total), restored=' + Std.string(restoredCountTotal)
			+ ', restoreFail=' + Std.string(restoreFailTotal) + ', pending=' + Std.string(pendingCount());
	}

	static inline function mb(bytes:Float):String
	{
		return Std.string(Math.round(bytes / 1048576 * 10) / 10);
	}
}
