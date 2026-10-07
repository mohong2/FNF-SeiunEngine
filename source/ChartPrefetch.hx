package;

import sys.thread.Thread;
import sys.thread.Lock;
#if (haxe_ver < 4.3)
import sys.thread.Mutex;
#end

/**
 * Bounded, asynchronous section prefetcher for streamed charts.
 *
 * Why: with a streamed chart (ChartStream) the per-section note parse is pure data work -- read a
 * byte range, parse it into ChartRawNote entries. It touches no Flixel, Lua or global state, so it
 * is the one part of a chart load that can run on another thread while the main thread builds the
 * PreloadedChartNote list from the sections it already has.
 *
 * The pipeline is what pays, not the thread count: one worker parses the next chunk while the
 * consumer consumes the previous one, which hides the parse behind the note-list build. Concurrent
 * parsing allocates hard against the collector, so more workers than that stall before they help
 * (see PlayState.PREFETCH_WORKERS); the count stays a parameter for that reason.
 *
 * Design constraints:
 *   - ChartSectionReader is explicitly single-threaded (one shared seek state), so every worker
 *     owns its own reader over the same paths/ranges and opens its own file handle. The only
 *     shared state is the immutable range table.
 *   - Memory is bounded by the chunk, not by the chart: a chunk stops at TARGET_NOTES_PER_CHUNK
 *     notes and MAX_SECTIONS_PER_CHUNK sections, so the resident raw-note set stays at a few
 *     hundred thousand entries whatever the chart size is. Only two chunks are ever in flight.
 *   - The next chunk is parsed while the caller consumes the current one, so the workers overlap
 *     with the caller's note generation.
 *   - A worker failure is rethrown by the consumer: a failed read must never be silently skipped
 *     (that is how a segmented chart silently loses whole parts).
 *
 * sys-only, like ChartStream itself (it already imports sys.io.File unconditionally).
 */
class ChartPrefetch
{
	/** Workers used unless the caller asks for a different count. One: see the class comment. */
	public static inline final DEFAULT_WORKERS:Int = 1;
	/**
	 * A chunk closes once its counted notes reach this many -- but never before every worker has at
	 * least MIN_SECTIONS_PER_WORKER sections, otherwise a chart with huge sections would hand each
	 * chunk a single section and no worker would ever run in parallel.
	 * Raise it for fewer, larger chunks (less overhead, more resident notes); lower it for less peak
	 * memory. Two chunks are resident at once (see nextChunk).
	 */
	public static inline final TARGET_NOTES_PER_CHUNK:Int = 600000;
	/** Sections each worker gets per chunk, at minimum, so the split is actually parallel. */
	public static inline final MIN_SECTIONS_PER_WORKER:Int = 2;
	/** Hard cap on sections per chunk, so a chart of tiny sections still overlaps. */
	public static inline final MAX_SECTIONS_PER_CHUNK:Int = 64;

	var paths:Array<String>;
	var ranges:Array<ChartStream.ChartSectionRange>;
	var workers:Int;
	var count:Int;

	var nextIndex:Int = 0;
	var pending:Chunk = null;
	#if (haxe_ver < 4.3)
	/** 4.2.5 没有 haxe.atomic: chunk.done 仍是 mutex 保护的普通 Int(见 runWorker)。 */
	var mutex:Mutex = new Mutex();
	#end

	public function new(paths:Array<String>, ranges:Array<ChartStream.ChartSectionRange>, ?workers:Int = 0)
	{
		if (paths == null || paths.length == 0) throw new haxe.Exception('ChartPrefetch: no chart file');
		if (ranges == null) throw new haxe.Exception('ChartPrefetch: no section ranges');
		this.paths = paths;
		this.ranges = ranges;
		this.count = ranges.length;
		this.workers = (workers > 0) ? workers : DEFAULT_WORKERS;
		if (this.workers < 1) this.workers = 1;
	}

	/**
	 * Parsed notes of the next chunk of sections, in chart order, blocking until every section of
	 * that chunk is parsed. The chunk after it is started before this one is returned, so the
	 * workers stay busy while the caller consumes. Returns an empty array once nothing is left.
	 */
	public function nextChunk():Array<Array<ChartStream.ChartRawNote>>
	{
		var ready:Chunk = pending;
		pending = startChunk(nextIndex);
		if (ready == null) return (pending == null) ? [] : nextChunk();
		return finish(ready);
	}

	/** Releases the prefetcher; in-flight chunks still finish on their own. */
	public function close():Void
	{
		pending = null;
	}

	/** Waits for a started chunk and rethrows the first worker failure. */
	function finish(chunk:Chunk):Array<Array<ChartStream.ChartRawNote>>
	{
		chunk.lock.wait();
		if (chunk.error != null) throw new haxe.Exception('ChartPrefetch: ' + chunk.error);
		return chunk.results;
	}

	/** Builds and launches the chunk starting at section index `from`; null when nothing is left. */
	function startChunk(from:Int):Chunk
	{
		if (from >= count) return null;

		var indices:Array<Int> = [];
		var notes:Int = 0;
		var i:Int = from;
		while (i < count && indices.length < MAX_SECTIONS_PER_CHUNK)
		{
			var r:ChartStream.ChartSectionRange = ranges[i];
			// ~13 bytes per note in a real chart file; only used to close a chunk early, never
			// for correctness (the parse is driven by the byte ranges, not by this estimate).
			if (r != null && r.len > 0) notes += Std.int(r.len / 13);
			indices.push(i);
			i++;
			var enoughSections:Bool = (indices.length >= workers * MIN_SECTIONS_PER_WORKER);
			if (enoughSections && notes >= TARGET_NOTES_PER_CHUNK) break;
		}
		nextIndex = i;

		// total is the number of WORKERS, not sections: every worker reports completion exactly once,
		// and the last one releases the chunk lock the consumer waits on.
		var spawn:Int = (workers < indices.length) ? workers : indices.length;
		if (spawn < 1) spawn = 1;
		var chunk:Chunk = new Chunk(indices.length, spawn);
		for (w in 0...spawn)
		{
			var slot:Int = w;
			Thread.create(function() runWorker(chunk, indices, slot, spawn));
		}
		return chunk;
	}

	/**
	 * One worker: parses every `slot`-th section of the chunk with its own reader. The last worker
	 * to finish releases the chunk lock, which is what finish() waits on.
	 */
	function runWorker(chunk:Chunk, indices:Array<Int>, slot:Int, stride:Int):Void
	{
		var reader:ChartStream.ChartSectionReader = null;
		try
		{
			reader = new ChartStream.ChartSectionReader(paths, ranges);
			var i:Int = slot;
			while (i < indices.length)
			{
				var index:Int = indices[i];
				var arr:Array<ChartStream.ChartRawNote> = reader.readNotes(index);
				if (arr == null)
				{
					chunk.error = 'cannot read section ' + index + ' of ' + reader.pathOf(index)
						+ ' (' + reader.lastError + ')';
					break;
				}
				chunk.results[i] = arr;
				i += stride;
			}
		}
		catch (e:Dynamic)
		{
			if (chunk.error == null) chunk.error = Std.string(e);
		}
		if (reader != null) reader.close();

		var last:Bool = false;
		#if (haxe_ver >= 4.3)
		// AtomicInt.add 返回旧值: 旧值 + 1 == total 表示本次是最后一个收工的 worker。
		// chunk.lock.release() 同时充当 chunk.results / chunk.error 的发布屏障 ——
		// finish() 里的 lock.wait() 与它配对, 所以这个纯计数器不再需要 mutex。
		last = (chunk.done.add(1) + 1 >= chunk.total);
		#else
		mutex.acquire();
		chunk.done++;
		last = (chunk.done >= chunk.total);
		mutex.release();
		#end
		if (last) chunk.lock.release();
	}
}

/** One in-flight chunk: a result slot per section entry, filled by the workers. */
private class Chunk
{
	/** One slot per section of the chunk, in section order. */
	public var results:Array<Array<ChartStream.ChartRawNote>>;
	/** Workers that reported completion. */
	#if (haxe_ver >= 4.3)
	public var done:Counter = new Counter(0);
	#else
	public var done:Int = 0;
	#end
	/** Workers the chunk was split across: the completion count, NOT the section count. */
	public var total:Int = 0;
	public var error:String = null;
	public var lock:Lock;

	public function new(sectionCount:Int, workerCount:Int)
	{
		this.total = workerCount;
		this.results = new Array<Array<ChartStream.ChartRawNote>>();
		this.results.resize(sectionCount);
		this.lock = new Lock();
	}
}

/**
 * T4 线程原语现代化的兼容层。
 *
 * 4.3.7 + 有原子操作的目标: Counter = haxe.atomic.AtomicInt, 完成计数无锁。
 * 4.2.5: haxe.atomic 在 4.2.5 的 std 里不存在, 退回普通 Int —— 该分支下 done 仍由
 * mutex 保护(见 runWorker), 语义与改动前一致, 守住 "4.2.5 类型检查 exit 0" 基线。
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