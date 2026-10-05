package backend;

#if sys
import sys.FileSystem;
import sys.io.File;
#end

/**
 * 脚本诊断日志 / Script diagnostics log
 *
 * 为什么需要它: 模组脚本出问题时, 引擎原本只把错误写进内存里的环状缓冲 (TraceManager)
 * 或屏幕上的调试文本 —— 关掉游戏就什么都没了。而"模组没生效"这类问题(脚本根本没被
 * 加载? 加载了但 onCreate 报错? 回调没被调用?) 光看画面无法区分。
 *
 * 本类把三件事写进 `logs/script_log.txt`:
 *   1. 每个被加载的 Lua / HScript 文件 (绝对路径), 以及加载失败的原因;
 *   2. 每个在模组脚本目录里被扫描到的文件夹 (含是否存在 / 找到几个脚本),
 *      用来证明 `data/<歌曲>/` 到底有没有被扫描;
 *   3. 每次脚本报错 (回调名 + 脚本名 + 原始错误), 以及 onCreate / onCreatePost
 *      到底分发给了哪些脚本。
 *
 * 只写文本, 单次运行最多 `maxLines` 行 (默认 2 万), 超过后静默停止, 不会因为
 * 报错风暴把磁盘写爆。文件在每次启动时重建。
 *
 * English: Persistent, bounded script diagnostics log. Records every loaded
 * script (and load failures), every scanned script folder, every script error
 * with its callback name, and which scripts received onCreate / onCreatePost.
 * Truncated at startup and capped per session so an error storm cannot fill the disk.
 */
class ScriptLog
{
	public static final DIR:String = 'logs';
	public static final FILE_PATH:String = 'logs/script_log.txt';

	/** 设为 false 可完全关闭 (不创建文件)。 */
	public static var enabled:Bool = true;

	/** 单次运行最多写入的行数。 */
	public static var maxLines:Int = 20000;

	/**
	 * 会被记录进 `[cb]` 的**生命周期**回调白名单。
	 *
	 * 只记这几个, 不记 onEvent / onNoteHit / onKeyPress 之类高频回调 —— 每次 write 都是一次
	 * 打开+写入+关闭文件, 高频回调下会变成肉眼可见的掉帧。诊断"某个脚本有没有收到创建/结束
	 * 回调"只需要这些。
	 * English: only lifecycle callbacks are traced; per-note / per-key callbacks are not,
	 * because every write opens and closes the file.
	 */
	static final LIFECYCLE:Map<String, Bool> = [
		'onCreate' => true,
		'onCreatePost' => true,
		'onDestroy' => true,
		'onStartCountdown' => true,
		'onCountdownStarted' => true,
		'onSongStart' => true,
		'onEndSong' => true,
		'onGameOver' => true,
		'onGameOverStart' => true,
		'onPause' => true,
		'onResume' => true
	];

	/** 该回调名是否属于需要记录的创建/生命周期回调。 */
	public static function isLifecycle(callback:String):Bool
	{
		return callback != null && LIFECYCLE.exists(callback);
	}

	static var written:Int = 0;
	static var started:Bool = false;
	static var broken:Bool = false;

	/**
	 * 常驻输出句柄 / Resident output handle.
	 *
	 * 旧实现每写一行就 `File.append(...)` + `close()` (打开 / 写入 / 关闭三次系统调用)。诊断生命周期回调时
	 * 这无所谓, 但**报错路径**不一样: `registerError()` 对 onKeyPress / onEvent / goodNoteHit 这类一次性回调
	 * 永远返回 false (见 FunkinLua.registerError), 而 FunkinLua.callInner 的 catch 分支无条件写日志 ——
	 * 一个在 onKeyPress 里报错的模组, 玩家**每次按键**都会触发一次打开+写入+关闭, 这正是"按键掉帧"的直接来源。
	 * 现在文件在第一次写入时打开一次, 之后每行只做 write + flush: 仍然逐行落盘 (进程被强杀也不丢日志),
	 * 但每次写入从 3 次系统调用降到 1 次 write。
	 * English: one long-lived handle instead of open+write+close per line. Error paths are not covered by the
	 * lifecycle whitelist, so a mod that throws inside a per-key callback used to hit the disk on every press.
	 */
	#if sys
	static var handle:sys.io.FileOutput = null;
	#end

	/** 关闭常驻句柄 (begin() 重建日志前, 或写入失败后)。 */
	public static function closeHandle():Void
	{
		#if sys
		if (handle != null)
		{
			try { handle.close(); } catch (e:Dynamic) {}
			handle = null;
		}
		#end
	}

	/** 新建本次运行的日志文件。启动时调用一次即可; 未调用会在首次 write 时自动补上。 */
	public static function begin(?session:String):Void
	{
		#if sys
		if (broken) return;
		started = true;
		written = 0;
		closeHandle(); // rebuild the file only after releasing the previous resident handle
		if (!enabled) return;
		try
		{
			if (!FileSystem.exists(DIR)) FileSystem.createDirectory(DIR);
			var header:String = '=== SeiunEngine script log ===\n';
			header += 'session: ' + (session == null ? Std.string(Date.now()) : session) + '\n';
			header += '\n';
			File.saveContent(FILE_PATH, header);
		}
		catch (e:Dynamic)
		{
			broken = true;
		}
		#end
	}

	/**
	 * 追加一行。tag 用来说明来源, 例如 'load' / 'folder' / 'error' / 'callback'。
	 * 任何 IO 失败都只是停写, 绝不影响游戏。
	 */
	public static function write(tag:String, message:String):Void
	{
		#if sys
		if (broken) return;
		if (!enabled) return;
		if (!started) begin();
		if (broken) return;
		if (written >= maxLines) return;
		try
		{
			// 常驻句柄: 见 handle 的说明。第一次写到文件时打开, 之后每行只 write + flush。
			// sys.io.File.append 的第二个参数是 binary:Bool, 所以必须拿 Output 再写字符串。
			if (handle == null)
				handle = File.append(FILE_PATH);
			handle.writeString('[' + tag + '] ' + (message == null ? 'null' : message) + '\n');
			handle.flush();
			written++;
		}
		catch (e:Dynamic)
		{
			closeHandle();
			broken = true;
		}
		#end
	}

	/** 已写入的行数 (调试用)。 */
	public static function lineCount():Int return written;
}
