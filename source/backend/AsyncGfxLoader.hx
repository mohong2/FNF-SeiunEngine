package backend;

import flixel.FlxG;
import flixel.graphics.FlxGraphic;
import openfl.display.BitmapData;
import openfl.utils.Assets as OpenFlAssets;
import openfl.utils.AssetType;
import openfl.utils.ByteArray;
import mohong.TraceManager;

#if sys
import sys.FileSystem;
import sys.io.File;
import sys.thread.Thread;
import sys.thread.Mutex;
#end


typedef GfxJob =
{
	cacheKey:String,   
	filePath:String,  
	enqueuedAt:Float,
	gen:Int           
}

typedef GfxWorkerResult =
{
	bytes:Null<haxe.io.Bytes>, 
	filePath:String,
	gen:Int              
}

class AsyncGfxLoader
{
	public static inline var WORKERS:Int = 2;

	public static inline var MAX_PER_DRAIN:Int = 1;

	public static inline var ASYNC_TIMEOUT_MS:Float = 45000;

	public static var decodedOffThreadTotal:Int = 0;
	public static var failedOffThreadTotal:Int = 0;
	public static var decodeMsTotal:Float = 0;
	public static var lastBatchEnqueued:Int = 0;
	public static var lastBatchOffThread:Int = 0;
	public static var lastBatchCached:Int = 0;

	#if sys
	static var mutex:Mutex = new Mutex();
	static var queue:Array<GfxJob> = [];
	static var inflight:Map<String, Bool> = [];     
	static var ready:Map<String, BitmapData> = [];    
	static var callbacks:Map<String, Void->Void> = [];
	static var workersStarted:Bool = false;
	static var generation:Int = 0;
	#end

	public static function available():Bool
	{
		#if sys
		return ClientPrefs.data.asyncImageLoading;
		#else
		return false;
		#end
	}

	#if sys
	public static function enqueue(cacheKey:String, filePath:String, onDone:Void->Void):Void
	{
		if (cacheKey == null || filePath == null)
			return;

		mutex.acquire();
		if (inflight.exists(cacheKey) || ready.exists(cacheKey))
		{
			if (onDone != null && !callbacks.exists(cacheKey))
				callbacks.set(cacheKey, onDone);
			mutex.release();
			return;
		}
		if (isCached(cacheKey))
		{
			mutex.release();
			lastBatchCached++;
			if (onDone != null) onDone();
			return;
		}

		queue.push({cacheKey: cacheKey, filePath: filePath, enqueuedAt: haxe.Timer.stamp(), gen: generation});
		inflight.set(cacheKey, true);
		callbacks.set(cacheKey, onDone);
		lastBatchEnqueued++;
		startWorkersOnce();
		mutex.release();
	}

	public static function drain():Void
	{
		var fired:Array<Void->Void> = [];
		var doneKeys:Array<String> = [];
		var doneRes:Array<GfxWorkerResult> = [];

		mutex.acquire();

		var now = haxe.Timer.stamp();
		var keep:Array<GfxJob> = [];
		for (job in queue)
		{
			if ((now - job.enqueuedAt) * 1000 > ASYNC_TIMEOUT_MS)
			{
				inflight.remove(job.cacheKey);
				failedOffThreadTotal++;
				var cb = callbacks.get(job.cacheKey);
				callbacks.remove(job.cacheKey);
				if (cb != null) fired.push(cb);
				TraceManager.warn('trace.asyncGfx.timeout',
					'AsyncGfxLoader timeout for {}', [job.cacheKey]);
			}
			else keep.push(job);
		}
		queue = keep;

		// Workers only read raw bytes. Decoding + repacking must happen on the
		// main thread (OpenFL/Lime BitmapData is not safe to create off-thread).
		// Process a small batch each frame so the loading screen stays responsive.
		var allKeys:Array<String> = [];
		for (k in pendingResults.keys())
			allKeys.push(k);
		var taken:Int = 0;
		for (k in allKeys)
		{
			var res = pendingResults.get(k);
			// Drop results from a previous loading session (reset() bumped gen).
			if (res == null || res.gen != generation)
			{
				pendingResults.remove(k);
				continue;
			}
			if (taken >= MAX_PER_DRAIN) break;
			doneKeys.push(k);
			doneRes.push(res);
			pendingResults.remove(k);
			taken++;
		}

		mutex.release();

		for (i in 0...doneKeys.length)
		{
			var key = doneKeys[i];
			var res = doneRes[i];
			var bmp:BitmapData = null;

			if (res != null && res.bytes != null && res.bytes.length > 0)
			{
				var t0 = haxe.Timer.stamp();
				try
				{
					bmp = BitmapData.fromBytes(ByteArray.fromBytes(res.bytes));
				}
				catch (e:Dynamic)
				{
					TraceManager.warn('trace.asyncGfx.decodeFail',
						'AsyncGfxLoader decode failed for {}: {}', [res.filePath, e]);
					bmp = null;
				}
				decodeMsTotal += (haxe.Timer.stamp() - t0) * 1000;
			}

			var packedXml:Null<String> = null;
			if (bmp != null)
			{
				var rep = GfxRepack.process(key, res.filePath, bmp);
				if (rep != null)
				{
					if (bmp != rep.bmp) bmp.dispose();
					bmp = rep.bmp;
					packedXml = rep.xml;
					TraceManager.info('trace.gfx.repack',
						'GfxRepack {} : {} -> {} MB (-{}%) in {} ms',
						[key,
						 Std.string(Math.round(rep.oldBytes / 1048576 * 10) / 10),
						 Std.string(Math.round(rep.newBytes / 1048576 * 10) / 10),
						 Std.string(Math.round((1 - rep.newBytes / rep.oldBytes) * 1000) / 10),
						 Std.string(Math.round(rep.ms))]);
				}
			}

			if (res != null && packedXml != null && bmp != null)
				GfxRepack.registerPackedXml(key, packedXml, res.filePath, bmp.width, bmp.height);

			if (bmp != null && !isCached(key))
			{
				if (!materialize(key, bmp))
				{
					mutex.acquire();
					ready.set(key, bmp);
					mutex.release();
				}
				decodedOffThreadTotal++;
				lastBatchOffThread++;
			}
			else if (bmp == null)
			{
				failedOffThreadTotal++;
			}

			mutex.acquire();
			inflight.remove(key);
			var cb = callbacks.get(key);
			callbacks.remove(key);
			mutex.release();
			if (cb != null) fired.push(cb);
		}

		for (cb in fired) cb();
	}

	public static function takeDecoded(cacheKey:String):Null<BitmapData>
	{
		#if sys
		mutex.acquire();
		var bmp = ready.get(cacheKey);
		if (bmp != null) ready.remove(cacheKey);
		mutex.release();
		return bmp;
		#else
		return null;
		#end
	}

	public static function beginBatch():Void
	{
		lastBatchEnqueued = 0;
		lastBatchOffThread = 0;
		lastBatchCached = 0;
	}


	public static function reset():Void
	{
		#if sys
		mutex.acquire();
		generation++;
		queue.resize(0);
		pendingResults.clear();
		ready.clear();
		inflight.clear();
		callbacks.clear();
		mutex.release();
		#end
	}

	static var pendingResults:Map<String, GfxWorkerResult> = [];

	static function startWorkersOnce():Void
	{
		if (workersStarted) return;
		workersStarted = true;
		for (i in 0...WORKERS)
		{
			Thread.create(function() {
				while (true)
				{
					// Any exception thrown by the user closure passed to `sys.thread.Thread.create` is
					// **rethrown** by `sys.thread.HaxeThread`'s framework closure into `hxThreadFunc`;
					// haxe/hxcpp has no global uncaught handler, so the process dies (crash report Exception
					// code 0xE06D7363, a C++ throw with hxThreadFunc at the stack bottom). This catch keeps the
					// worker running after a dropped job instead of taking the whole game down.
					try
					{
						var job:GfxJob = null;
						mutex.acquire();
						if (queue.length > 0)
							job = queue.shift();
						mutex.release();

						if (job == null)
						{
							Sys.sleep(0.004);
							continue;
						}

						var bytes:haxe.io.Bytes = null;
						try
						{
							bytes = File.getBytes(job.filePath);
						}
						catch (e:Dynamic)
						{
							try TraceManager.warn('trace.asyncGfx.readFail',
								'AsyncGfxLoader read failed for {}: {}', [job.filePath, e]) catch (_:Dynamic) {}
							bytes = null;
						}

						mutex.acquire();
						if (job.gen == generation)
							pendingResults.set(job.cacheKey, {bytes: bytes, filePath: job.filePath, gen: job.gen});
						mutex.release();
					}
					catch (e:Dynamic)
					{
						try TraceManager.warn('trace.asyncGfx.workerFail',
							'AsyncGfxLoader worker error: {}', [Std.string(e)]) catch (_:Dynamic) {}
					}
				}
			});
		}
	}

	static function isCached(cacheKey:String):Bool
	{
		if (Paths.currentTrackedAssets.exists(cacheKey)) return true;
		if (GfxLru.has(cacheKey)) return true;
		return @:privateAccess FlxG.bitmap._cache.exists(cacheKey);
	}

	static function materialize(cacheKey:String, bmp:BitmapData):Bool
	{
		try
		{
			var graphic:FlxGraphic = FlxGraphic.fromBitmapData(bmp, false, cacheKey);
			graphic.persist = true;
			Paths.currentTrackedAssets.set(cacheKey, graphic);
			Paths.trackLocalAsset(cacheKey);

			#if sys
			if (ClientPrefs.data.gfxCpuRelease)
			{
				var ctx = FlxG.stage != null ? FlxG.stage.context3D : null;
				if (ctx != null && graphic.bitmap != null && graphic.bitmap.readable)
				{
					graphic.bitmap.getTexture(ctx, true);
					bmp.disposeImage();
					GfxPolicy.registerPrefetchRelease(graphic);
				}
			}
			#end
			return true;
		}
		catch (e:Dynamic)
		{
			TraceManager.warn('trace.asyncGfx.materialize',
				'materialize failed for {}: {}', [cacheKey, e]);
			return false;
		}
	}

	public static function collectSongImages(song:Dynamic):Array<{cacheKey:String, filePath:String}>
	{
		var out:Array<{cacheKey:String, filePath:String}> = [];
		#if sys
		if (song == null) return out;

		var names:Array<String> = [];
		for (raw in [song.player2, song.player1, song.gfVersion])
		{
			var n:String = raw;
			if (n != null && n.length > 0 && names.indexOf(n) < 0)
				names.push(n);
		}

		var seenImages:Map<String, Bool> = [];
		for (name in names)
		{
			var img = charImageKey(name);
			if (img == null || seenImages.exists(img)) continue;
			seenImages.set(img, true);

			#if MODS_ALLOWED
			var modKey = Paths.modsImages(img);
			if (FileSystem.exists(modKey))
			{
				out.push({cacheKey: modKey, filePath: modKey});
				continue;
			}
			#end

			var assetId = Paths.getPath('images/' + img + '.png', IMAGE);
			var exists = false;
			try { exists = OpenFlAssets.exists(assetId); } catch (e:Dynamic) {}

			var fsPath = assetId;
			var ci = fsPath.indexOf(':');
			if (ci > 0) fsPath = fsPath.substr(ci + 1);

			#if sys
			if (!FileSystem.exists(fsPath)) exists = false;
			#end
			if (exists)
				out.push({cacheKey: assetId, filePath: fsPath});
		}
		#end
		return out;
	}

	static function charImageKey(charName:String):Null<String>
	{
		var characterPath:String = 'characters/' + charName + '.json';
		#if MODS_ALLOWED
		var path:String = Paths.modFolders(characterPath);
		if (!FileSystem.exists(path))
			path = Paths.getPreloadPath(characterPath);
		if (!FileSystem.exists(path))
			return null;
		var rawJson:String;
		try { rawJson = File.getContent(path); } catch (e:Dynamic) return null;
		#else
		var path:String = Paths.getPreloadPath(characterPath);
		var rawJson:String;
		try { rawJson = Assets.getText(path); } catch (e:Dynamic) return null;
		#end

		try
		{
			var json:{ image:Null<String> } = haxe.Json.parse(rawJson);
			if (json.image == null || json.image.length == 0) return null;
			return json.image;
		}
		catch (e:Dynamic)
		{
			return null;
		}
	}
	#end
}
