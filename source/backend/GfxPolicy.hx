package backend;

import flixel.FlxG;
import flixel.graphics.FlxGraphic;
import openfl.display.BitmapData;
import openfl.utils.Assets as OpenFlAssets;
import mohong.TraceManager;

#if sys
import sys.FileSystem;
import sys.io.File;
#end


class GfxPolicy
{
	public static var enabled:Bool = true;

	public static var minDimension:Int = 2048;

	public static var initialSweepDelayMs:Float = 600;

	public static var sweepIntervalMs:Float = 5000;

	public static var releasedCountTotal:Int = 0;

	public static var releasedBytesTotal:Float = 0;

	public static var releasedBytesLive:Float = 0;

	public static var restoredCountTotal:Int = 0;

	public static var lastSweepCostMs:Float = 0;

	public static var lastSweepReleased:Int = 0;

	public static var sweepCountTotal:Int = 0;

	static var excludedKeys:Map<String, Bool> = [];

	static var cpuReleased:Map<String, {assetId:String, realPath:String, bytes:Float}> = [];

	static var playAccumMs:Float = 0;
	static var nextSweepAtMs:Float = Math.POSITIVE_INFINITY;

	static var songTag:String = '';
	static var ledgerWrittenForThisSong:Bool = false;
	static var songStartSnapshot:{count:Int, bytes:Float} = {count: 0, bytes: 0.0};
	static var songSweeps:Int = 0;

	public static function exclude(key:String):Void
	{
		if (key != null) excludedKeys.set(key, true);
	}

	public static function unexclude(key:String):Void
	{
		if (key != null) excludedKeys.remove(key);
	}

	public static function onPlayStateCreate(songName:String):Void
	{
		playAccumMs = 0;
		songTag = songName == null ? 'unknown' : songName;
		ledgerWrittenForThisSong = false;
		songStartSnapshot.count = releasedCountTotal;
		songStartSnapshot.bytes = releasedBytesTotal;
		songSweeps = 0;
		nextSweepAtMs = enabled ? initialSweepDelayMs : Math.POSITIVE_INFINITY;
	}


	public static function onPlayUpdate(elapsed:Float):Void
	{
		if (!enabled) return;
		playAccumMs += elapsed * 1000;
		if (playAccumMs >= nextSweepAtMs)
		{
			nextSweepAtMs = playAccumMs + sweepIntervalMs;
			var freed = sweepCpuReleases();
			if (freed > 0)
			{
				TraceManager.info('trace.gfx.sweep',
					'GfxPolicy sweep #{}: released {} big graphics (~{} MB cpu)',
					[sweepCountTotal, freed, fl(releasedBytesLive / 1048576)]);
			}
		}
	}

	public static function onSongEnd():Void
	{
		if (!enabled) return;
		sweepCpuReleases();
		writeLedger(false);
	}

	public static function onPlayStateDestroy():Void
	{
		nextSweepAtMs = Math.POSITIVE_INFINITY;
		if (!ledgerWrittenForThisSong) writeLedger(true);
	}

	public static function sweepCpuReleases():Int
	{
		if (!enabled) return 0;
		if (!ClientPrefs.data.gfxCpuRelease) return 0;
		var t0 = haxe.Timer.stamp();

		if (FlxG.stage == null || FlxG.stage.context3D == null)
			return 0;

		lastSweepReleased = 0;

		for (key => g in Paths.currentTrackedAssets)
			if (tryRelease(key, g))
				lastSweepReleased++;

		@:privateAccess
		for (key => g in FlxG.bitmap._cache)
			if (tryRelease(key, g))
				lastSweepReleased++;

		lastSweepCostMs = (haxe.Timer.stamp() - t0) * 1000;
		sweepCountTotal++;
		songSweeps++;
		return lastSweepReleased;
	}

	/**
	 * Preload-phase GPU commit: force-upload every big texture now and drop its
	 * CPU copy immediately, so nothing commits to VRAM mid-song (no hitches).
	 * Call once at the end of PlayState.create.
	 */
	public static function preloadWarm():Void
	{
		if (!enabled || !ClientPrefs.data.gfxCpuRelease) return;
		var ctx = FlxG.stage != null ? FlxG.stage.context3D : null;
		if (ctx == null) return;

		var t0 = haxe.Timer.stamp();
		var uploaded:Int = 0;

		for (key => g in Paths.currentTrackedAssets)
			uploaded += warmOne(key, g, ctx);
		@:privateAccess
		for (key => g in FlxG.bitmap._cache)
			uploaded += warmOne(key, g, ctx);

		var freed = sweepCpuReleases();
		TraceManager.info('trace.gfx.preloadWarm',
			'preload warm: {} textures uploaded, {} cpu copies released in {} ms',
			[uploaded, freed, fl((haxe.Timer.stamp() - t0) * 1000)]);
	}

	static function warmOne(key:String, g:FlxGraphic, ctx:Dynamic):Int
	{
		if (key == null || g == null || g.bitmap == null || !g.bitmap.readable) return 0;
		if (excludedKeys.exists(key)) return 0;
		if (g.bitmap.width < minDimension && g.bitmap.height < minDimension) return 0;
		if (hasLiveTexture(g.bitmap)) return 0;
		try { g.bitmap.getTexture(ctx, true); } catch (e:Dynamic) { return 0; }
		return 1;
	}

	/**
	 * Immediate CPU-release for one graphic: upload it to GPU (if not already)
	 * and drop the readable CPU copy right away. Used on Android to keep the
	 * loading-time Native Heap peak low; rendering remains identical because the
	 * hardware texture stays attached to the BitmapData.
	 */
	public static function releaseNow(key:String, g:FlxGraphic):Void
	{
		if (!enabled || !ClientPrefs.data.gfxCpuRelease) return;
		// Opt-in: bulk-uploading large textures early caused black screen on Android.
		if (Sys.getEnv("FNF_EARLY_CPU_RELEASE") != "1") return;
		if (key == null || key.length == 0 || g == null || g.bitmap == null || !g.bitmap.readable) return;
		if (excludedKeys.exists(key)) return;
		if (g.bitmap.width < minDimension && g.bitmap.height < minDimension) return;
		if (hasLiveTexture(g.bitmap))
		{
			tryRelease(key, g);
			return;
		}
		var ctx = FlxG.stage != null ? FlxG.stage.context3D : null;
		if (ctx == null) return;
		try { g.bitmap.getTexture(ctx, true); } catch (e:Dynamic) { return; }
		tryRelease(key, g);
	}

	public static function onContextRestored():Int
	{
		if (Lambda.count(cpuReleased) == 0) return 0;
		var restored:Int = 0;
		var consumedKeys:Array<String> = [];

		for (key => entry in cpuReleased)
		{
			var g = findGraphicByKey(key);
			if (g == null)
			{
				// The graphic is gone. Unless it is parked in the LRU (that case is finished by
				// GfxLru.onContextRestored in the same callback, which drops the CPU-release
				// record through forgetReleased), this registration is dangling: subtract its
				// bytes and drop it here, exactly as pruneRegistry() would, so that
				// releasedBytesLive cannot stay inflated forever.
				if (!GfxLru.isParked(key))
				{
					releasedBytesLive -= entry.bytes;
					consumedKeys.push(key);
				}
				continue;
			}
			if (g.bitmap != null && g.bitmap.readable)
			{
				// The CPU copy is back (something re-decoded the graphic), so this registration
				// is meaningless. Subtract its bytes like pruneRegistry() does: removing the
				// record without subtracting would leave releasedBytesLive permanently inflated.
				releasedBytesLive -= entry.bytes;
				consumedKeys.push(key);
				continue;
			}

			var fresh:BitmapData = null;
			try { fresh = OpenFlAssets.getBitmapData(entry.assetId); } catch (e:Dynamic) {}
			#if sys
			if (fresh == null && entry.realPath != null && entry.realPath != entry.assetId
				&& FileSystem.exists(entry.realPath))
			{
				try { fresh = BitmapData.fromFile(entry.realPath); } catch (e:Dynamic) {}
			}
			#end

			if (fresh == null)
			{
				TraceManager.warn('trace.gfx.restoreFail',
					'GfxPolicy restore failed for {} (source gone)', [key]);
				releasedBytesLive -= entry.bytes;
				consumedKeys.push(key);
				continue;
			}

			fresh = GfxRepack.repackForRestore(key, fresh);

			g.bitmap = fresh; 
			releasedBytesLive -= entry.bytes;
			consumedKeys.push(key);
			restored++;
		}

		for (k in consumedKeys)
			cpuReleased.remove(k);

		if (releasedBytesLive < 0) releasedBytesLive = 0;
		restoredCountTotal += restored;
		if (restored > 0)
		{
			TraceManager.info('trace.gfx.restored',
				'GfxPolicy context-restored: reloaded {} graphics', [restored]);
		}
		return restored;
	}

	public static function onContextLost():Void
	{
		TraceManager.warn('trace.gfx.contextLost',
			'GfxPolicy: render context lost, {} graphics awaiting restore',
			[Lambda.count(cpuReleased)]);
	}

	public static function forgetReleased(key:String):Void
	{
		if (key == null) return;
		var entry = cpuReleased.get(key);
		if (entry != null)
		{
			releasedBytesLive -= entry.bytes;
			cpuReleased.remove(key);
			if (releasedBytesLive < 0) releasedBytesLive = 0;
		}
	}

	public static function pruneRegistry():Void
	{
		if (Lambda.count(cpuReleased) == 0) return;
		var dead:Array<String> = [];
		for (key => entry in cpuReleased)
		{
			var stale = false;
			var g = findGraphicByKey(key);
			if (g == null)
			{
				if (!GfxLru.isParked(key))
					stale = true; 
			}
			else if (g.bitmap != null && g.bitmap.readable)
				stale = true; 

			if (stale)
			{
				releasedBytesLive -= entry.bytes;
				dead.push(key);
			}
		}
		for (k in dead)
			cpuReleased.remove(k);
		if (releasedBytesLive < 0) releasedBytesLive = 0;
	}

	
	public static function registerPrefetchRelease(graphic:FlxGraphic):Void
	{
		var bmp = graphic.bitmap;
		if (graphic.key == null || cpuReleased.exists(graphic.key)) return;
		var bytes:Float = bmp != null ? (bmp.width * bmp.height * 4) : 0;
		cpuReleased.set(graphic.key, {assetId: graphic.key, realPath: resolveSource(graphic.key), bytes: bytes});
		releasedCountTotal++;
		releasedBytesTotal += bytes;
		releasedBytesLive += bytes;
	}

	public static function tryRelease(key:String, g:FlxGraphic):Bool
	{
		if (key == null || key.length == 0 || g == null) return false;
		// Prefer the graphic's canonical key so alias spellings (shared:... vs
		// assets/...) do not create duplicate/unfindable CPU-release records.
		var regKey:String = g.key != null && g.key.length > 0 ? g.key : key;
		if (excludedKeys.exists(key) || excludedKeys.exists(regKey)) return false;
		if (cpuReleased.exists(regKey)) return false;

		var bmp = g.bitmap;
		if (bmp == null || !bmp.readable) return false; 

		if (bmp.width < minDimension && bmp.height < minDimension) return false;

		if (!hasLiveTexture(bmp)) return false;

		var resolved = resolveSource(regKey);
		if (resolved == null) return false;

		var bytes:Float = bmp.width * bmp.height * 4;
		// 释放失败就不要记账(否则 cpuReleased 会认为这张图已经释放, 之后不再补回来)。
		try { bmp.disposeImage(); } catch (e:Dynamic) { return false; }
		// 把"释放了哪张图的 CPU 副本"也写进引擎日志: 原生崩溃报告会带上最后 150 条,
		// 这样"崩溃前最后动过的大图"是可查的。
		TraceManager.info('trace.gfx.cpuReleased', 'GfxPolicy released CPU copy of {} ({}x{}, {} MB)',
			[regKey, Std.string(bmp.width), Std.string(bmp.height), Std.string(Math.round(bytes / 1048576 * 10) / 10)]);

		cpuReleased.set(regKey, {assetId: regKey, realPath: resolved, bytes: bytes});
		releasedCountTotal++;
		releasedBytesTotal += bytes;
		releasedBytesLive += bytes;
		return true;
	}

	static function resolveSource(key:String):String
	{
		#if sys
		if (FileSystem.exists(key)) return key;
		var ci = key.indexOf(':');
		if (ci > 0)
		{
			var stripped = key.substr(ci + 1);
			if (stripped.length > 0 && FileSystem.exists(stripped)) return stripped;
		}
		#end

		try
		{
			if (OpenFlAssets.exists(key))
				return key;
		}
		catch (e:Dynamic) {}

		return null;
	}

	public static function hasLiveTexture(bmp:BitmapData):Bool
	{
		return @:privateAccess (bmp.__isValid && bmp.__texture != null);
	}

	static function findGraphicByKey(key:String):FlxGraphic
	{
		var g = Paths.currentTrackedAssets.get(key);
		if (g != null) return g;
		g = @:privateAccess FlxG.bitmap._cache.get(key);
		if (g != null) return g;

		// Alias fallback: the registry may use the graphic's canonical key while
		// the live cache is currently keyed by the other spelling.
		for (candidate in Paths.currentTrackedAssets)
			if (candidate != null && candidate.key == key) return candidate;
		@:privateAccess
		for (candidate in FlxG.bitmap._cache)
			if (candidate != null && candidate.key == key) return candidate;
		return null;
	}


	public static function writeLedger(aborted:Bool):Void
	{
		ledgerWrittenForThisSong = true;

		// Release build: file logging disabled.
		/*#if sys
		try
		{
			if (!FileSystem.exists('logs')) FileSystem.createDirectory('logs');

			var dSongBytes = releasedBytesTotal - songStartSnapshot.bytes;
			var dSongCount = releasedCountTotal - songStartSnapshot.count;
			var now = Date.now().toString();
			var ledgerPath = 'logs/gfx-ledger.txt';
			var lruD = GfxLru.takeLedgerDelta();

			var line = '\n[${now}] ${aborted ? 'aborted' : 'song-end'} song=${songTag}\n'
				+ '  released_this_song=${dSongCount} (~${fl(dSongBytes / 1048576)} MB cpu)\n'
				+ '  live_released=${fl(releasedBytesLive / 1048576)} MB\n'
				+ '  session_total=${releasedCountTotal} (~${fl(releasedBytesTotal / 1048576)} MB)\n'
				+ '  sweeps_this_song=${songSweeps} last_sweep_cost=${fl(lastSweepCostMs)} ms\n'
				+ '  context_loss_restores=${restoredCountTotal}\n'
				+ '  lru: parked=${lruD.parked} (~${fl(lruD.bytes / 1048576)} MB vram)'
				+ ' hit=${lruD.hits} saved≈${fl(lruD.saved)} ms (since last ledger)\n'
				+ '  lru_live: entries=${GfxLru.liveEntries()} hot=${GfxLru.liveHotCount()} pinned=${GfxLru.livePinnedCount()}'
				+ ' ~${fl(GfxLru.liveBytes() / 1048576)}/${fl(GfxLru.budgetMb())} MB'
				+ ' evicted_total=${GfxLru.evictTotal}\n'
				+ '  ' + GfxRepack.ledgerDeltaLine() + '\n';

			File.saveContent(ledgerPath,
				FileSystem.exists(ledgerPath)
					? File.getContent(ledgerPath) + line
					: '# SeiunEngine GfxPolicy ledger (P0+P2)\n' + line);
		}
		catch (e:Dynamic)
		{
			TraceManager.warn('trace.gfx.ledgerFail', 'GfxPolicy ledger write failed: {}', [e]);
		}
		#end*/
	}

	static inline function fl(v:Float):String
	{
		return Std.string(Math.round(v * 10) / 10);
	}
}
