package mohong;

#if sys
import sys.io.File;
#end
#if cpp
import sys.thread.Mutex;
#end
import haxe.PosInfos;
import Language;

import mohong.TraceLevel;
import mohong.TraceEntry;

/**
 * Trace listener callback.
 */
typedef TraceListener = TraceEntry -> Void;

/**
 * Central logger for the whole project (~300 call sites).
 * Hooks haxe.Log.trace; output goes per-platform:
 *   windows -> WriteConsoleW, sys -> Sys.println, js -> browser console.
 * Only translates messages that actually look like language keys.
 */
class TraceManager
{
	/** Ring buffer cap; oldest entries get overwritten past this. */
	public static var MAX_ENTRIES:Int = 5000;

	/** Intercept + record; off = forward to haxe.Log.trace. */
	public static var enabled:Bool = true;

	/** Also write to console. Off by default; enabled via Trace Console option. */
	public static var consoleOutput:Bool = false;

	/** Min level printed to console. */
	public static var consoleLevel:TraceLevel = DEBUG;

	/** Console rate limit: max lines actually written per `consoleRateWindow` seconds.
	 *  Excess lines are still recorded in the ring buffer, just not flushed to the console. */
	public static var consoleRateLimit:Int = 200;
	public static var consoleRateWindow:Float = 0.1;

	/** Saved haxe.Log.trace. */
	private static var originalTrace:Dynamic = null;

	/** Ring buffer storage. */
	private static var entries:Array<TraceEntry> = [];

	/** Ring write head. */
	private static var bufferHead:Int = 0;

	/** Live entry count. */
	private static var bufferCount:Int = 0;

	/** Listeners (TraceConsole etc). */
	private static var listeners:Array<TraceListener> = [];

	/** Monotonic entry id. */
	private static var entryId:Int = 0;

	/** Guards the ring on cpp (other threads log too). */
	#if cpp
	private static var bufferMutex:Mutex = new Mutex();
	#end

	/** Whether a real console/terminal output target is currently attached. */
	private static var consoleAvailable:Bool = false;
	private static var consoleAvailabilityKnown:Bool = false;

	/** Console burst limiter state. */
	private static var consoleRateStart:Float = 0;
	private static var consoleRateCount:Int = 0;

	/** Init flag. */
	private static var initialized:Bool = false;

	/** Re-entrancy guard for the sync console write. */
	private static var consoleBusy:Bool = false;

	/** level -> name. */
	private static var levelNames:Map<TraceLevel, String> = [
		DEBUG => "DEBUG",
		INFO  => "INFO",
		WARN  => "WARN",
		ERROR => "ERROR"
	];

	/** level -> ANSI color. */
	private static var levelColors:Map<TraceLevel, String> = [
		DEBUG => "\x1b[90m",
		INFO  => "\x1b[37m",
		WARN  => "\x1b[33m",
		ERROR => "\x1b[31m"
	];

	private static var RESET_COLOR:String = "\x1b[0m";

	/**
	 * Init: hook haxe.Log.trace, enable ANSI on Windows.
	 * Does not open a console (OptionsState's job).
	 */
	public static function init():Void
	{
		if (initialized) return;
		initialized = true;

		#if (windows && cpp && !android)
		try {
			Windows.enableAnsiColors();
		} catch (e:Dynamic) {
			// colors are best-effort
		}
		#end

		// Windows: Trace Console is opt-in (prevents silent console flooding when
		// the game is started from a terminal). Other desktop sys targets keep
		// the historic stdout logging behaviour.
		#if (desktop && !windows && !android)
		consoleOutput = true;
		#end

		originalTrace = haxe.Log.trace;
		haxe.Log.trace = captureTrace;
	}

	/**
	 * Update the cached console availability. TraceConsole calls this when a
	 * console is allocated/freed so TraceManager can skip formatting when
	 * there is no output target.
	 */
	public static function setConsoleAvailable(available:Bool):Void
	{
		consoleAvailable = available;
		consoleAvailabilityKnown = true;
	}

	private static function isConsoleAvailable():Bool
	{
		if (!consoleAvailabilityKnown)
			refreshConsoleAvailability();
		return consoleAvailable;
	}

	private static function refreshConsoleAvailability():Void
	{
		#if (cpp && windows && !android)
		try {
			consoleAvailable = Windows.hasConsole();
		} catch (e:Dynamic) {
			consoleAvailable = false;
		}
		#elseif (sys && !android)
		consoleAvailable = true;
		#elseif js
		consoleAvailable = true;
		#else
		consoleAvailable = false;
		#end
		consoleAvailabilityKnown = true;
	}

	/**
	 * Sync from ClientPrefs (desktop only).
	 */
	public static function syncWithPrefs():Void
	{
		#if desktop
		var wantConsole:Bool = (ClientPrefs.data.traceConsoleEnabled == true);
		consoleOutput = wantConsole;
		if (wantConsole)
		{
			var level:String = ClientPrefs.data.traceConsoleLevel;
			if (level != null) applyConsoleLevel(level);
			TraceConsole.start();
		}
		else
		{
			TraceConsole.stop();
		}
		#end
	}

	/**
	 * Toggle console output.
	 */
	public static function enableConsoleOutput(on:Bool):Void
	{
		consoleOutput = on;
		if (on)
			info('trace.consoleEnabled', 'Trace console output enabled.');
		else
			info('trace.consoleDisabled', 'Trace console output disabled.');
	}

	/**
	 * Set console level by name (case-insensitive).
	 */
	public static function applyConsoleLevel(levelName:String):Void
	{
		if (levelName == null || levelName.length == 0) return;
		consoleLevel = switch (levelName.toUpperCase())
		{
			case 'DEBUG': DEBUG;
			case 'INFO':  INFO;
			case 'WARN', 'WARNING': WARN;
			case 'ERROR': ERROR;
			default: DEBUG;
		}
	}

	/**
	 * Handler for raw trace() calls.
	 * Translate only when the message looks like a lang key.
	 * Freeform logs skip the lookup.
	 */
	private static function captureTrace(v:Dynamic, ?infos:haxe.PosInfos):Void
	{
		if (!enabled)
		{
			if (originalTrace != null) originalTrace(v, infos);
			return;
		}

		var rawMsg:String = Std.string(v);
		var fileName:String = (infos != null && infos.fileName != null) ? infos.fileName : 'unknown';
		var lineNumber:Int = (infos != null) ? infos.lineNumber : 0;

		var displayMsg:String = rawMsg;
		if (!isLanguageSelfTrace(fileName) && isLangKeyLike(rawMsg) && Language.has(rawMsg))
			displayMsg = Language.get(rawMsg, rawMsg);

		addEntry({
			timestamp: haxe.Timer.stamp(),
			level: INFO,
			message: displayMsg,
			rawMessage: rawMsg,
			fileName: fileName,
			lineNumber: lineNumber,
			moduleName: extractModuleName(fileName)
		});
	}

	/** Lang-key shaped? dots, no spaces/odd chars. */
	private static function isLangKeyLike(msg:String):Bool
	{
		if (msg == null || msg.length == 0 || msg.indexOf('.') < 0) return false;
		for (i in 0...msg.length)
		{
			var c:Int = msg.charCodeAt(i);
			var ok:Bool = (c >= 97 && c <= 122)   // a-z
				|| (c >= 65 && c <= 90)           // A-Z
				|| (c >= 48 && c <= 57)           // 0-9
				|| c == 46 || c == 95 || c == 45; // . _ -
			if (!ok) return false;
		}
		return true;
	}

	/** Skip translation for Language's own traces. */
	private static function isLanguageSelfTrace(fileName:String):Bool
	{
		if (fileName == null) return false;
		var lower:String = fileName.toLowerCase();
		return lower.indexOf("language") >= 0
			&& (lower.endsWith(".hx") || lower.indexOf("language.hx") >= 0);
	}

	// -------- info/warn/error/debug (signatures unchanged) --------

	public static function info(key:String, defaultText:String, ?args:Array<Dynamic>, ?pos:haxe.PosInfos):TraceEntry
	{
		return log(INFO, key, defaultText, args, pos);
	}

	public static function warn(key:String, defaultText:String, ?args:Array<Dynamic>, ?pos:haxe.PosInfos):TraceEntry
	{
		return log(WARN, key, defaultText, args, pos);
	}

	public static function error(key:String, defaultText:String, ?args:Array<Dynamic>, ?pos:haxe.PosInfos):TraceEntry
	{
		return log(ERROR, key, defaultText, args, pos);
	}

	public static function debug(key:String, defaultText:String, ?args:Array<Dynamic>, ?pos:haxe.PosInfos):TraceEntry
	{
		return log(DEBUG, key, defaultText, args, pos);
	}

	/**
	 * Translate -> interpolate {} -> ring -> console -> listeners.
	 */
	private static function log(level:TraceLevel, key:String, defaultText:String, ?args:Array<Dynamic>, ?pos:haxe.PosInfos):TraceEntry
	{
		var translated:String = Language.get(key, defaultText);

		if (args != null && args.length > 0)
		{
			for (i in 0...args.length)
			{
				var idx:Int = translated.indexOf('{}');
				if (idx < 0) break;
				translated = translated.substr(0, idx) + Std.string(args[i]) + translated.substr(idx + 2);
			}
		}

		var fileName:String = (pos != null && pos.fileName != null) ? pos.fileName : 'unknown';
		var lineNumber:Int = (pos != null) ? pos.lineNumber : 0;

		var entry:TraceEntry = {
			timestamp: haxe.Timer.stamp(),
			level: level,
			message: translated,
			rawMessage: defaultText,
			fileName: fileName,
			lineNumber: lineNumber,
			moduleName: extractModuleName(fileName)
		};

		addEntry(entry);
		return entry;
	}

	/**
	 * O(1) ring write; lock only on cpp.
	 * Console + listeners run outside the lock.
	 */
	private static function addEntry(entry:TraceEntry):Void
	{
		#if cpp
		bufferMutex.acquire();
		#end

		entryId++;
		if (bufferCount < MAX_ENTRIES)
		{
			entries.push(entry);
			bufferCount++;
		}
		else
		{
			entries[bufferHead] = entry;
			bufferHead = (bufferHead + 1) % MAX_ENTRIES;
		}

		#if cpp
		bufferMutex.release();
		#end

		// Console is written directly only when there is no live TraceConsole
		// listener: TraceConsole already handles output and can apply its own
		// rate limiting. This prevents duplicate writes and keeps the hot path
		// free of synchronous console I/O for the common no-console case.
		if (listeners.length == 0 && shouldEmitConsole(entry.level))
		{
			consoleBusy = true;
			writeToConsole(entry);
			consoleBusy = false;
		}

		if (listeners.length > 0)
			notifyListeners(entry);
	}

	/**
	 * Combined console gate: master switch + minimum level + attached console +
	 * burst limiter. Used by both TraceManager's direct path and TraceConsole
	 * so a rapid burst cannot stall the game on synchronous console writes.
	 */
	public static function shouldEmitConsole(level:TraceLevel):Bool
	{
		if (!consoleOutput || !shouldOutput(level) || !isConsoleAvailable())
			return false;

		var now:Float = haxe.Timer.stamp();
		if (now - consoleRateStart >= consoleRateWindow || consoleRateStart <= 0)
		{
			consoleRateStart = now;
			consoleRateCount = 0;
		}

		consoleRateCount++;
		return consoleRateCount <= consoleRateLimit;
	}

	private static function shouldOutput(level:TraceLevel):Bool
	{
		return getLevelOrder(level) >= getLevelOrder(consoleLevel);
	}

	private static function getLevelOrder(level:TraceLevel):Int
	{
		return switch (level) {
			case DEBUG: 0;
			case INFO:  1;
			case WARN:  2;
			case ERROR: 3;
		}
	}

	/**
	 * Format + write, per platform.
	 * Format: [HH:MM:SS.ms][LEVEL] module:line > message
	 */
	private static function writeToConsole(entry:TraceEntry):Void
	{
		var timeStr:String = formatTimestamp(entry.timestamp);
		var levelStr:String = levelNames[entry.level];
		var moduleInfo:String = (entry.moduleName != 'unknown')
			? '${entry.moduleName}:${entry.lineNumber}'
			: '';

		#if (cpp && windows && !android)
		// windows: WriteConsoleW (UTF-8 safe, no stdout deadlock)
		var levelColor:String = levelColors[entry.level];
		var line:String = '\x1b[90m$timeStr$RESET_COLOR $levelColor[$levelStr]$RESET_COLOR '
			+ (moduleInfo != '' ? '\x1b[36m$moduleInfo$RESET_COLOR ' : '')
			+ '\x1b[90m\u25B8$RESET_COLOR ${entry.message}';
		try {
			Windows.writeConsole(line + '\n');
		} catch (e:Dynamic) {}
		#elseif sys
		var levelColor:String = levelColors[entry.level];
		var line:String = '\x1b[90m$timeStr$RESET_COLOR $levelColor[$levelStr]$RESET_COLOR '
			+ (moduleInfo != '' ? '\x1b[36m$moduleInfo$RESET_COLOR ' : '')
			+ '\x1b[90m\u25B8$RESET_COLOR ${entry.message}';
		try {
			Sys.println(line);
		} catch (e:Dynamic) {}
		#elseif js
		// html5: browser console, level-mapped
		var line:String = '$timeStr [$levelStr]'
			+ (moduleInfo != '' ? ' $moduleInfo' : '')
			+ ' ${entry.message}';
		try {
			switch (entry.level) {
				case DEBUG: js.Browser.console.debug(line);
				case INFO:  js.Browser.console.info(line);
				case WARN:  js.Browser.console.warn(line);
				case ERROR: js.Browser.console.error(line);
			}
		} catch (e:Dynamic) {}
		#end
	}

	private static function formatTimestamp(timestamp:Float):String
	{
		var date:Date = Date.fromTime(timestamp * 1000);
		var hours:String = zeroPad(date.getHours(), 2);
		var minutes:String = zeroPad(date.getMinutes(), 2);
		var seconds:String = zeroPad(date.getSeconds(), 2);
		var ms:String = zeroPad(Math.floor((timestamp - Math.floor(timestamp)) * 1000), 3);
		return '$hours:$minutes:$seconds.$ms';
	}

	private static function zeroPad(num:Int, digits:Int):String
	{
		var str:String = Std.string(num);
		while (str.length < digits) str = '0$str';
		return str;
	}

	private static function extractModuleName(fileName:String):String
	{
		if (fileName == null || fileName == 'unknown') return 'unknown';
		var parts:Array<String> = fileName.split('/');
		var last:String = parts[parts.length - 1];
		if (last.endsWith('.hx')) last = last.substr(0, last.length - 3);
		return last;
	}

	// -------- listeners --------

	public static function addListener(listener:TraceListener):Void
	{
		if (!listeners.contains(listener))
			listeners.push(listener);
	}

	public static function removeListener(listener:TraceListener):Void
	{
		listeners.remove(listener);
	}

	private static function notifyListeners(entry:TraceEntry):Void
	{
		for (listener in listeners)
		{
			try {
				listener(entry);
			} catch (e:Dynamic) {
				// listener crash must not break logging
			}
		}
	}

	// -------- query / export --------

	/** Snapshot of all entries in order. */
	public static function getAll():Array<TraceEntry>
	{
		#if cpp
		bufferMutex.acquire();
		#end

		var result:Array<TraceEntry> = [];
		for (i in 0...bufferCount)
		{
			var idx:Int = (bufferCount < MAX_ENTRIES) ? i : (bufferHead + i) % MAX_ENTRIES;
			result.push(entries[idx]);
		}

		#if cpp
		bufferMutex.release();
		#end
		return result;
	}

	/** Entry count. */
	public static function getCount():Int
	{
		return bufferCount;
	}

	/**
	 * Plain-text tail of the ring buffer for the native crash handler.
	 * The C side keeps it in a fixed buffer, so it is capped on both entry
	 * count and total characters.
	 */
	public static function getRecentCrashText(?maxEntries:Int = 150, ?maxChars:Int = 28000):String
	{
		var all:Array<TraceEntry> = getAll();
		var start:Int = all.length - maxEntries;
		if (start < 0) start = 0;

		var lines:Array<String> = [];
		for (i in start...all.length)
		{
			var e:TraceEntry = all[i];
			var msg:String = e.message != null ? e.message : '';
			if (msg.length > 200) msg = msg.substr(0, 200) + '...';
			var file:String = e.fileName != null ? e.fileName : '?';
			lines.push(levelNames[e.level] + ' | ' + file + ':' + e.lineNumber + ' | ' + msg);
		}
		var text:String = lines.join('\n');
		if (text.length > maxChars) text = '... ' + text.substr(text.length - maxChars);
		return text;
	}

	/**
	 * Filter by level/module/text; limit 0 = all.
	 */
	public static function getFiltered(?levels:Array<TraceLevel>, ?moduleName:String, ?search:String, ?limit:Int = 0):Array<TraceEntry>
	{
		#if cpp
		bufferMutex.acquire();
		#end

		var result:Array<TraceEntry> = [];
		for (j in 0...bufferCount)
		{
			var idx:Int = (bufferCount < MAX_ENTRIES) ? j : (bufferHead + j) % MAX_ENTRIES;
			var e:TraceEntry = entries[idx];

			if (levels != null && levels.length > 0 && !levels.contains(e.level))
				continue;

			if (moduleName != null && moduleName != '' && e.moduleName != moduleName)
				continue;

			if (search != null && search != '')
			{
				var lowerSearch:String = search.toLowerCase();
				if (e.message.toLowerCase().indexOf(lowerSearch) < 0
					&& e.rawMessage.toLowerCase().indexOf(lowerSearch) < 0
					&& e.moduleName.toLowerCase().indexOf(lowerSearch) < 0)
					continue;
			}

			result.push(e);

			if (limit > 0 && result.length >= limit)
				break;
		}

		#if cpp
		bufferMutex.release();
		#end
		return result;
	}

	/** Per-level counts. */
	public static function getStats():Map<TraceLevel, Int>
	{
		#if cpp
		bufferMutex.acquire();
		#end

		var stats:Map<TraceLevel, Int> = [
			DEBUG => 0,
			INFO  => 0,
			WARN  => 0,
			ERROR => 0
		];

		for (j in 0...bufferCount)
		{
			var idx:Int = (bufferCount < MAX_ENTRIES) ? j : (bufferHead + j) % MAX_ENTRIES;
			var e:TraceEntry = entries[idx];
			stats[e.level] = stats[e.level] + 1;
		}

		#if cpp
		bufferMutex.release();
		#end
		return stats;
	}

	/** Clear the buffer. */
	public static function clear():Void
	{
		#if cpp
		bufferMutex.acquire();
		#end

		entries = [];
		bufferHead = 0;
		bufferCount = 0;
		entryId = 0;

		#if cpp
		bufferMutex.release();
		#end
	}

	/** Export as JSON. */
	public static function exportToJson(?levels:Array<TraceLevel>, ?limit:Int = 100):String
	{
		var data:Array<Dynamic> = [];
		var filtered:Array<TraceEntry> = getFiltered(levels, null, null, limit);

		for (entry in filtered)
		{
			data.push({
				timestamp: entry.timestamp,
				level: levelNames[entry.level],
				message: entry.message,
				file: entry.fileName,
				line: entry.lineNumber,
				module: entry.moduleName
			});
		}

		return haxe.Json.stringify(data, '  ');
	}

	/** Save to file (sys only). */
	public static function saveToFile(path:String, ?levels:Array<TraceLevel>):Void
	{
		#if sys
		var json:String = exportToJson(levels, 0);
		File.saveContent(path, json);
		info('trace.exportSaved', 'Trace data saved to: {}', [path]);
		#end
	}
}
