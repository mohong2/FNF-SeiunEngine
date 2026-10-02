package backend;

import flixel.FlxG;
import flixel.graphics.FlxGraphic;
import openfl.display.BitmapData;
import openfl.utils.Assets as OpenFlAssets;
import openfl.utils.AssetType;
import openfl.utils.ByteArray;
import mohong.TraceManager;

import haxe.atomic.AtomicInt;

#if sys
import sys.FileSystem;
import sys.io.File;
import sys.thread.Thread;
import sys.thread.Mutex;
import sys.thread.Semaphore;
#end

// ============================================================================
// Invariant: worker threads never call TraceManager, directly or indirectly.
//
// TraceManager is not safe to call off the main thread:
//   - log() resolves the translated text through Language.get() before it takes any
//     lock, and the language table is loaded lazily without synchronization;
//   - addEntry() serializes only the ring-buffer write behind bufferMutex. The direct
//     console write and the listener dispatch run after that lock is released, and the
//     listener list itself is mutated without holding it.
// A worker calling any log method therefore races the main thread's lazy language
// load, its listener dispatch and its console output.
//
// A worker thread may only do three things: read file bytes (File.getBytes), store the
// exception pointer it saw into its already-published result slot, and touch atomic
// counters. Every log line is emitted by the main thread from drain().
// ============================================================================

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
	failed:Bool,
	/**
	 * Exception the worker saw for this job: either the read failed or the worker loop
	 * itself threw. The worker only stores the pointer while holding the mutex and never
	 * formats a message; drain() reads it on the main thread.
	 */
	err:Dynamic,
	/** True when the failure came from the worker loop itself rather than from the read; selects the log key in drain(). */
	panic:Bool
}

class AsyncGfxLoader
{
	public static inline var WORKERS:Int = 2;

	public static inline var MAX_PER_DRAIN:Int = 1;

	public static inline var ASYNC_TIMEOUT_MS:Float = 45000;

	// Session/batch counters. haxe.atomic.AtomicInt maps to the lock-free _hx_atomic_*
	// intrinsics on cpp and allocates no hxcpp object. They stay exposed as read-only Int
	// properties because GfxPolicy and GfxLru read these names as Int (including "> 0"
	// tests and string interpolation).
	static var _decodedOffThreadTotal:AtomicInt = new AtomicInt(0);
	static var _failedOffThreadTotal:AtomicInt = new AtomicInt(0);
	/** 解码耗时累计: cpp 只提供 AtomicInt/AtomicObject, Float 没有原子实现, 仍只在主线程累加。 */
	public static var decodeMsTotal:Float = 0;
	static var _lastBatchEnqueued:AtomicInt = new AtomicInt(0);
	static var _lastBatchOffThread:AtomicInt = new AtomicInt(0);
	static var _lastBatchCached:AtomicInt = new AtomicInt(0);

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
	// Callback table: one key can carry several onDone callbacks (the same key may be
	// enqueued more than once) and every registered callback runs exactly once.
	// A list per key beats chaining closures: registration is O(1), nothing can end up
	// referencing itself, and drain() detaches the whole list in one step.
	static var callbacks:Map<String, Array<Void->Void>> = [];
	static var workersStarted:Bool = false;
	static var generation:Int = 0;
	/** 强制 GC 期间: worker 不再开始新任务。 */
	static var quiesced:Bool = false;
	/** Number of workers currently reading a file or publishing a result; lock-free, so the main thread can read it outside the mutex. */
	static var workersBusy:AtomicInt = new AtomicInt(0);
	/** worker 收工信号: quiesce() 用它阻塞等最后一个 worker 离开任务(sys.thread.Semaphore)。 */
	static var idleWorkers:Semaphore = new Semaphore(0);
	/** Exceptions a worker threw before it obtained a job, so they cannot be tied to a result slot; drain() flushes them into log lines on the main thread. */
	static var pendingWorkerErrors:Array<Dynamic> = [];
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
		// ready hit: the bitmap is already decoded and waiting for takeDecoded(), so the
		// resource is available. Fire the callback immediately.
		// It must NOT be registered here: that job was already completed by drain() and its
		// callbacks already ran, so a callback left in the table would never be invoked.
		if (ready.exists(cacheKey))
		{
			mutex.release();
			if (onDone != null) onDone();
			return;
		}
		// inflight hit: the same key is already being read/decoded. Append the callback to
		// the existing list so drain() fires all of them when the job settles.
		if (inflight.exists(cacheKey))
		{
			if (onDone != null) addCallback(cacheKey, onDone);
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

		var slot:GfxWorkerResult = {bytes: null, filePath: filePath, gen: generation, done: false, failed: false, err: null, panic: false};
		pendingResults.set(cacheKey, slot);
		queue.push({cacheKey: cacheKey, filePath: filePath, enqueuedAt: haxe.Timer.stamp(), gen: generation, slot: slot});
		inflight.set(cacheKey, true);
		if (onDone != null) addCallback(cacheKey, onDone);
		_lastBatchEnqueued.add(1);
		startWorkersOnce();
		mutex.release();
	}

	/**
	 * Append onDone to the callback list for a key. Must be called while holding the mutex.
	 *
	 * Invariant: every successfully registered onDone runs exactly once. There are only two
	 * invocation sites and both are outside the lock: drain() detaches the whole list and
	 * calls it once the job settles or times out, or the ready-hit branch of enqueue() calls
	 * it immediately.
	 */
	static function addCallback(cacheKey:String, onDone:Void->Void):Void
	{
		var list = callbacks.get(cacheKey);
		if (list == null)
		{
			list = [];
			callbacks.set(cacheKey, list);
		}
		list.push(onDone);
	}

	public static function drain():Void
	{
		var fired:Array<Void->Void> = [];
		var doneKeys:Array<String> = [];
		var doneRes:Array<GfxWorkerResult> = [];
		var panics:Array<Dynamic> = null;
		var timeouts:Array<String> = null;

		mutex.acquire();

		// Exceptions from workers that never obtained a job: detach them here and log them
		// outside the lock.
		if (pendingWorkerErrors.length > 0)
		{
			panics = pendingWorkerErrors;
			pendingWorkerErrors = [];
		}

		var now = haxe.Timer.stamp();
		var keep:Array<GfxJob> = [];
		for (job in queue)
		{
			if ((now - job.enqueuedAt) * 1000 > ASYNC_TIMEOUT_MS)
			{
				inflight.remove(job.cacheKey);
				pendingResults.remove(job.cacheKey);
				_failedOffThreadTotal.add(1);
				var cbs = callbacks.get(job.cacheKey);
				callbacks.remove(job.cacheKey);
				if (cbs != null) for (cb in cbs) fired.push(cb);
				// Do not call TraceManager while holding this mutex: it lazily loads language
				// strings and dispatches to listeners, which would keep workers out of the job
				// queue for that whole time. Collect the keys and log after the lock is released.
				if (timeouts == null) timeouts = [];
				timeouts.push(job.cacheKey);
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

		// No worker thread ever calls TraceManager; every worker-side exception is logged
		// here, on the main thread.
		if (panics != null)
			for (e in panics)
				TraceManager.warn('trace.asyncGfx.workerFail',
					'AsyncGfxLoader worker error: {}', [Std.string(e)]);

		if (timeouts != null)
			for (k in timeouts)
				TraceManager.warn('trace.asyncGfx.timeout',
					'AsyncGfxLoader timeout for {}', [k]);

		for (i in 0...doneKeys.length)
		{
			var key = doneKeys[i];
			var res = doneRes[i];
			var bmp:BitmapData = null;

			// The worker only wrote the exception pointer plus the failed/panic flags into
			// the slot; the log line is emitted here, on the main thread.
			if (res != null && res.failed)
			{
				var errText:String = res.err != null ? Std.string(res.err) : 'null';
				if (res.panic)
					TraceManager.warn('trace.asyncGfx.workerFail',
						'AsyncGfxLoader worker error for {}: {}', [res.filePath, errText]);
				else
					TraceManager.warn('trace.asyncGfx.readFail',
						'AsyncGfxLoader read failed for {}: {}', [res.filePath, errText]);
			}

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
				// Decoding is synchronous, so the PNG bytes are dead the moment the bitmap
				// exists. Drop the reference now: the heavier GfxRepack pass below then does not
				// keep the largest buffer alive and the GC can reclaim it earlier.
				res.bytes = null;
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
			// Detach the whole callback list under the lock and run it outside it:
			// every registered onDone runs exactly once.
			var cbs = callbacks.get(key);
			callbacks.remove(key);
			mutex.release();
			if (cbs != null) for (cb in cbs) fired.push(cb);
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

		// workersBusy is lock-free, so the wait can block outside the mutex. The condition is
		// re-checked on every wake-up, so a spurious wake-up cannot change the result: a worker
		// releases idleWorkers only when it brings the count to 0 while quiesced is set, and
		// the main thread blocks until the count reaches 0 or the deadline passes.
		// The mutex must be released before blocking: workers need it to take or finish jobs,
		// so waiting while holding it would deadlock.
		mutex.release();
		while (workersBusy.load() > 0)
		{
			var remain = deadline - haxe.Timer.stamp();
			if (remain <= 0) break;
			idleWorkers.tryAcquire(remain);
		}
		return workersBusy.load() == 0;
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
	 * Worker finished: decrement workersBusy.
	 *
	 * AtomicInt.sub returns the previous value, so a previous value of exactly 1 means this
	 * call brought the count to 0. When that happens while quiesced is set, release
	 * idleWorkers so a blocked tryAcquire in quiesce() returns immediately: that is the
	 * handshake that lets the main thread stop polling every 2 ms.
	 *
	 * Must be called while holding the mutex: the read of quiesced and the writes done by
	 * enqueue/job pickup are ordered by that same lock.
	 */
	static function workerFinished():Void
	{
		// AtomicInt.sub returns the previous value; 1 means this call reached 0.
		if (workersBusy.sub(1) == 1 && quiesced)
			idleWorkers.release();
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
					// job is declared outside the try: the outer catch needs it to tie an
					// exception to the result slot it belongs to.
					var job:GfxJob = null;
					// Single source of truth for "this thread holds the mutex": set immediately
					// after every successful acquire, cleared before every release.
					// It has to exist because an exception can be thrown inside a locked region
					// (queue.shift, workersBusy.add, the slot writes, workerFinished) and Mutex is
					// not recursive: the outer catch must not acquire it again, or the worker
					// deadlocks itself and workersBusy never returns to 0.
					var locked:Bool = false;
					try
					{
						mutex.acquire();
						locked = true;
						// quiesce() 期间不许再开始新任务(强制 GC 要求没有第二个线程在分配)。
						if (quiesced)
						{
							locked = false;
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
						locked = false;
						mutex.release();

						if (job == null)
						{
							Sys.sleep(0.004);
							continue;
						}

						var bytes:haxe.io.Bytes = null;
						// Read failure: the worker only carries the exception pointer out of
						// here; it does not build strings or log (see the TraceManager invariant
						// at the top of this file).
						var readErr:Dynamic = null;
						try
						{
							bytes = File.getBytes(job.filePath);
						}
						catch (e:Dynamic)
						{
							readErr = e;
							bytes = null;
						}

						// The locked region only does non-throwing work: field writes plus the
						// atomic decrement (and a semaphore release).
						mutex.acquire();
						locked = true;
						// 只在同一个加载世代里填; 记录本身是主线程分配并已经挂在表上的。
						if (job.gen == generation && job.slot != null)
						{
							job.slot.bytes = bytes;
							job.slot.err = readErr;
							job.slot.failed = (bytes == null);
							job.slot.done = true;
						}
						// Clear tookJob before workerFinished(): its first statement is the
						// non-throwing AtomicInt.sub and only the semaphore release after it can
						// throw, so clearing first keeps the catch below from decrementing twice.
						tookJob = false;
						workerFinished();
						locked = false;
						mutex.release();
					}
					catch (e:Dynamic)
					{
						// The worker loop itself failed (not a read failure). TraceManager is
						// still off limits here: if the exception belongs to a result slot, finish
						// that job with the exception attached; if it was thrown before a job was
						// obtained, queue it for drain() to log on the main thread.
						//
						// The whole catch is wrapped again so that nothing escapes the worker loop
						// (an escaping exception kills the process).
						//
						// Lock handling follows `locked` only:
						//   locked == true  -> the exception was thrown inside a locked region, so
						//                      reuse that lock and do not acquire;
						//   locked == false -> acquire here and give it back at the end.
						// `locked` is cleared before every release, so the fallback below cannot
						// release twice even if release itself throws.
						//
						// Order: publish the error / queue it first, call workerFinished() last.
						// quiesce() treats workersBusy == 0 as "all workers stopped", so that must
						// only become observable after the worker has stopped allocating.
						try
						{
							if (!locked)
							{
								mutex.acquire();
								locked = true;
							}
							var attributed:Bool = false;
							if (job != null && job.slot != null && job.gen == generation && !job.slot.done)
							{
								job.slot.err = e;
								job.slot.failed = true;
								job.slot.panic = true;
								job.slot.done = true;
								attributed = true;
							}
							if (!attributed) pendingWorkerErrors.push(e);
							if (tookJob && workersBusy.load() > 0) workerFinished();
							locked = false;
							mutex.release();
						}
						catch (_:Dynamic)
						{
							if (locked)
							{
								locked = false;
								try mutex.release() catch (_:Dynamic) {}
							}
						}
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

