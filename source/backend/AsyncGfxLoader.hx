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
#if (haxe_ver >= 4.3)
import sys.thread.Semaphore;
#end
#end


typedef GfxJob =
{
	cacheKey:String,   
	filePath:String,  
	enqueuedAt:Float,
	gen:Int,          
	// 加固: 结果记录由主线程在这里预先分配并立刻挂进 pendingResults,
	// 工作线程只负责往里填字段 —— 跨线程传递的就只有解码出来的 Bytes,
	// 不再有"工作线程 new 一个容器、之后才挂到共享表上"的窗口。
	slot:GfxWorkerResult
}

typedef GfxWorkerResult =
{
	bytes:Null<haxe.io.Bytes>, 
	filePath:String,
	gen:Int,             
	/** 工作线程写完后置 true（在 mutex 里写，作为发布屏障）。 */
	done:Bool,
	failed:Bool
}

class AsyncGfxLoader
{
	public static inline var WORKERS:Int = 2;

	public static inline var MAX_PER_DRAIN:Int = 1;

	public static inline var ASYNC_TIMEOUT_MS:Float = 45000;

	// 会话/批次计数。存储换成原子计数器(4.3.7: haxe.atomic.AtomicInt, cpp 走无锁 _hx_atomic_*),
	// 对外仍是 Int 只读属性: GfxPolicy.hx:406-408 与 GfxLru.hx:222-223 按 Int 读这些名字
	// (含 "> 0" 与字符串插值), 保持属性形态就不必改动那两个文件。
	static var _decodedOffThreadTotal:Counter = new Counter(0);
	static var _failedOffThreadTotal:Counter = new Counter(0);
	/** 解码耗时累计: cpp 只提供 AtomicInt/AtomicObject, Float 没有原子实现, 仍只在主线程累加。 */
	public static var decodeMsTotal:Float = 0;
	static var _lastBatchEnqueued:Counter = new Counter(0);
	static var _lastBatchOffThread:Counter = new Counter(0);
	static var _lastBatchCached:Counter = new Counter(0);

	public static var decodedOffThreadTotal(get, never):Int;
	static inline function get_decodedOffThreadTotal():Int return _decodedOffThreadTotal.load();

	public static var failedOffThreadTotal(get, never):Int;
	static inline function get_failedOffThreadTotal():Int return _failedOffThreadTotal.load();

	public static var lastBatchEnqueued(get, never):Int;
	static inline function get_lastBatchEnqueued():Int return _lastBatchEnqueued.load();

	public static var lastBatchOffThread(get, never):Int;
	static inline function get_lastBatchOffThread():Int return _lastBatchOffThread.load();

	public static var lastBatchCached(get, never):Int;
	static inline function get_lastBatchCached():Int return _lastBatchCached.load();

	#if sys
	static var mutex:Mutex = new Mutex();
	static var queue:Array<GfxJob> = [];
	static var inflight:Map<String, Bool> = [];     
	static var ready:Map<String, BitmapData> = [];    
	static var callbacks:Map<String, Void->Void> = [];
	static var workersStarted:Bool = false;
	static var generation:Int = 0;
	/** 强制 GC 期间: worker 不再开始新任务。 */
	static var quiesced:Bool = false;
	/** 正在读文件/填结果的 worker 数。4.3.7: 无锁原子量, 主线程可在锁外观察。 */
	static var workersBusy:Counter = new Counter(0);
	#if (haxe_ver >= 4.3)
	/** worker 收工信号: quiesce() 用它阻塞等最后一个 worker 离开任务(sys.thread.Semaphore)。 */
	static var idleWorkers:Semaphore = new Semaphore(0);
	#end
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
			_lastBatchCached.add(1);
			if (onDone != null) onDone();
			return;
		}

		var slot:GfxWorkerResult = {bytes: null, filePath: filePath, gen: generation, done: false, failed: false};
		pendingResults.set(cacheKey, slot);
		queue.push({cacheKey: cacheKey, filePath: filePath, enqueuedAt: haxe.Timer.stamp(), gen: generation, slot: slot});
		inflight.set(cacheKey, true);
		callbacks.set(cacheKey, onDone);
		_lastBatchEnqueued.add(1);
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
				pendingResults.remove(job.cacheKey);
				_failedOffThreadTotal.add(1);
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
			// 记录在 enqueue 时就挂上了, done 由工作线程在 mutex 里置位。
			if (!res.done) continue;
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
				// 崩溃报告只留最后 N 条日志: 把这张图的解码结果也写进去,
				// 下一次 GC / 原生崩溃就能看到"最后成功解码的是哪张图、多大"。
				if (bmp != null)
					TraceManager.info('trace.asyncGfx.decoded', 'AsyncGfxLoader decoded {} ({}x{}, {} MB) in {} ms',
						[key, Std.string(bmp.width), Std.string(bmp.height),
						 Std.string(Math.round(bmp.width * bmp.height * 4 / 1048576 * 10) / 10),
						 Std.string(Math.round((haxe.Timer.stamp() - t0) * 1000))]);
				else
					TraceManager.warn('trace.asyncGfx.decodeNull', 'AsyncGfxLoader got no bitmap for {}', [key]);
			}

			var packedXml:Null<String> = null;
			if (bmp != null)
			{
				var rep = GfxRepack.process(key, res.filePath, bmp);
				if (rep != null)
				{
					// 释放失败(例如已经被释放过)不能让异常冒出 drain(), 否则整个加载界面会中断。
					if (bmp != rep.bmp) { try bmp.dispose() catch (e:Dynamic) {} }
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
				var storedInCache:Bool = materialize(key, bmp);
				if (!storedInCache)
				{
					mutex.acquire();
					ready.set(key, bmp);
					mutex.release();
				}
				_decodedOffThreadTotal.add(1);
				_lastBatchOffThread.add(1);
				TraceManager.info('trace.asyncGfx.settled', 'AsyncGfxLoader settled {} as {}',
					[key, storedInCache ? 'tracked-graphic' : 'ready-pending']);
			}
			else if (bmp != null)
			{
				TraceManager.info('trace.asyncGfx.alreadyCached', 'AsyncGfxLoader dropped {} (already cached)', [key]);
			}
			else
			{
				_failedOffThreadTotal.add(1);
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
		_lastBatchEnqueued.store(0);
		_lastBatchOffThread.store(0);
		_lastBatchCached.store(0);
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

	/**
	 * 让工作线程停在任务边界上, 不再开始新的解码/分配。
	 *
	 * 强制 GC (cpp.vm.Gc.run / compact) 之前调用: 收集期间不该有第二个线程正在
	 * new hxcpp 对象或往共享表里写指针。回收与"另一个线程持有/发布对象"重叠,
	 * 就是对象被回收后地址又被复用的来源。
	 *
	 * 返回 true = 已经没有 worker 在任务里; 超时返回 false, 调用方继续执行
	 * (不能因为等不到一个卡住的文件读取就卡住加载流程)。
	 */
	public static function quiesce(timeoutMs:Float = 3000):Bool
	{
		#if sys
		mutex.acquire();
		quiesced = true;
		var deadline = haxe.Timer.stamp() + timeoutMs / 1000;

		#if (haxe_ver >= 4.3)
		// 4.3.7: workersBusy 是无锁原子量, 可以在锁外真阻塞等"最后一个 worker 收工"。
		// 每次醒来都重新判定条件, 所以多余的一次唤醒不会让结果失真; worker 只在 1 -> 0 且
		// quiesced 为真时 release, 而主线程一直阻塞到计数归零或超时才返回。
		mutex.release();
		while (workersBusy.load() > 0)
		{
			var remain = deadline - haxe.Timer.stamp();
			if (remain <= 0) break;
			idleWorkers.tryAcquire(remain);
		}
		return workersBusy.load() == 0;
		#else
		// 4.2.5 没有 sys.thread.Semaphore: workersBusy 仍由 mutex 保护, 保留原来的轮询等待
		// (锁外不读 workersBusy, 旧编译器路径的锁纪律与改动前一致)。
		var clean = (workersBusy.load() == 0);
		while (!clean && haxe.Timer.stamp() < deadline)
		{
			mutex.release();
			Sys.sleep(0.002);
			mutex.acquire();
			clean = (workersBusy.load() == 0);
		}
		mutex.release();
		return clean;
		#end
		#else
		return true;
		#end
	}

	/** 恢复 worker 取任务(必须和 quiesce() 成对调用)。 */
	public static function resume():Void
	{
		#if sys
		mutex.acquire();
		quiesced = false;
		mutex.release();
		#end
	}

	/** 当前是否处于静默状态(诊断用)。 */
	public static function isQuiesced():Bool
	{
		#if sys
		return quiesced;
		#else
		return false;
		#end
	}

	/**
	 * worker 收工: workersBusy 减一。
	 *
	 * 4.3.7: AtomicInt.sub 返回旧值, 旧值 == 1 表示本次正好把计数降到 0; 若此刻处于 quiesce,
	 * 就 release 一次 idleWorkers, 让 quiesce() 里阻塞的 tryAcquire 立刻返回 —— 这就是
	 * "工作线程置位 / 主线程等待" 的发布屏障, 主线程不再 2ms 轮询。
	 * 4.2.5: workersBusy 是 mutex 保护的普通 Int, 那边没有等待者, 只做减法。
	 *
	 * 必须在持有 mutex 时调用: quiesced 的读与 enqueue/取任务的写由同一把锁排序。
	 */
	static function workerFinished():Void
	{
		#if (haxe_ver >= 4.3)
		if (workersBusy.sub(1) == 1 && quiesced)
			idleWorkers.release();
		#else
		workersBusy.sub(1);
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
					var tookJob:Bool = false;
					try
					{
						var job:GfxJob = null;
						mutex.acquire();
						// quiesce() 期间不许再开始新任务(强制 GC 要求没有第二个线程在分配)。
						if (quiesced)
						{
							mutex.release();
							Sys.sleep(0.002);
							continue;
						}
						if (queue.length > 0)
						{
							job = queue.shift();
							workersBusy.add(1);
							tookJob = true;
						}
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
						// 只在同一个加载世代里填; 记录本身是主线程分配并已经挂在表上的。
						if (job.gen == generation && job.slot != null)
						{
							job.slot.bytes = bytes;
							job.slot.failed = (bytes == null);
							job.slot.done = true;
						}
						workerFinished();
						tookJob = false;
						mutex.release();
					}
					catch (e:Dynamic)
					{
						if (tookJob)
						{
							mutex.acquire();
							if (workersBusy.load() > 0) workerFinished();
							mutex.release();
						}
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

/**
 * T4 线程原语现代化的兼容层。
 *
 * 4.3.7 + 有原子操作的目标: Counter 就是 haxe.atomic.AtomicInt —— cpp 走 _hx_atomic_add/sub/
 * load/store, 计数器无锁。add/sub 返回的是**旧值**, 调用点按旧值语义使用(见 workerFinished)。
 * 4.2.5 (以及没有 target.atomics 的目标): haxe.atomic 在 4.2.5 的 std 里不存在, 退回普通 Int。
 * 这些计数器的自增当前只发生在主线程, workersBusy 在 4.2.5 分支仍全程在 mutex 里读写,
 * 因此 4.2.5 语义与改动前一致, 用于守住 "4.2.5 类型检查 exit 0" 基线。
 * 丢弃 4.2.5 支持时删除 #else 分支, 只留 typedef。
 */
#if ((haxe_ver >= 4.3) && target.atomics)
private typedef Counter = haxe.atomic.AtomicInt;
#else
private abstract Counter(Int)
{
	public inline function new(value:Int) this = value;
	public inline function add(b:Int):Int { var old = this; this = old + b; return old; }
	public inline function sub(b:Int):Int { var old = this; this = old - b; return old; }
	public inline function load():Int return this;
	public inline function store(value:Int):Int { var old = this; this = value; return old; }
}
#end
