package mohong;

import mohong.TraceLevel;
import mohong.TraceEntry;

/**
 * Live trace output panel. Listens to TraceManager; skips per-line
 * formatting when there's no console to write to.
 */
class TraceConsole
{
	private static var running:Bool = false;
	private static var watchMode:Bool = false;

	/** Set when a real output target exists. */
	private static var consoleAvailable:Bool = false;

	private static var RESET:String = "\x1b[0m";
	private static var GRAY:String = "\x1b[90m";
	private static var BLUE:String = "\x1b[34m";

	/**
	 * Start (idempotent); checks a real output target exists.
	 */
	public static function start():Void
	{
		if (running) return;
		running = true;
		watchMode = true;
		consoleAvailable = detectConsole();
		TraceManager.setConsoleAvailable(consoleAvailable);
		TraceManager.addListener(onTrace);
		if (consoleAvailable)
			printLine(GRAY + "[TraceConsole] Monitoring started." + RESET);
	}

	/**
	 * Stop (idempotent).
	 *
	 * Availability is re-derived instead of being forced to `false`: stopping the
	 * listener must not pretend the terminal behind it disappeared. A desktop build
	 * launched from a shell keeps stdout logging (TraceManager's direct path) alive
	 * after the option is switched off.
	 */
	public static function stop():Void
	{
		if (!running) return;
		running = false;
		watchMode = false;
		consoleAvailable = false;
		TraceManager.refreshConsoleAvailability();
		TraceManager.removeListener(onTrace);
	}

	/**
	 * Detect output: windows console, /dev/stdout, logcat, browser console.
	 *
	 * Android has no console window, but the SDL backend mirrors this process'
	 * stdout into logcat (`adb logcat`), which is the platform's terminal. Treating
	 * it as unavailable is what made the Trace Console option do nothing at all on
	 * mobile, so it counts as an output target here.
	 */
	private static function detectConsole():Bool
	{
		#if (cpp && windows && !android)
		try {
			return Windows.hasConsole();
		} catch (e:Dynamic) {
			return false;
		}
		#elseif (sys && !android)
		return true;
		#elseif android
		return true;
		#elseif js
		return true;
		#else
		return false;
		#end
	}

	/**
	 * Listener callback; skips formatting when no target.
	 */
	private static function onTrace(entry:TraceEntry):Void
	{
		if (!watchMode || !consoleAvailable) return;
		if (!TraceManager.shouldEmitConsole(entry.level)) return;

		var lvlColor:String = switch (entry.level) {
			case DEBUG: "\x1b[90m";
			case INFO:  "\x1b[37m";
			case WARN:  "\x1b[33m";
			case ERROR: "\x1b[31m";
		}
		var lvlName:String = switch (entry.level) {
			case DEBUG: "DEBUG";  case INFO:  "INFO";
			case WARN:  "WARN";   case ERROR: "ERROR";
		}

		var timeStr:String = GRAY + "[" + formatTime(entry.timestamp) + "]" + RESET;
		var modStr:String = BLUE + entry.moduleName + ":" + entry.lineNumber + RESET;

		printLine('$timeStr $lvlColor[$lvlName]$RESET $modStr ${entry.message}');
	}

	/**
	 * Print a line, same platform split as TraceManager.
	 */
	private static function printLine(text:String):Void
	{
		#if (cpp && windows && !android)
		try {
			Windows.writeConsole(text + '\n');
		} catch (e:Dynamic) {
			try { Sys.println(text); } catch (e2:Dynamic) {}
		}
		#elseif sys
		try { Sys.println(text); } catch (e:Dynamic) {}
		#elseif js
		try { js.Browser.console.log(text); } catch (e:Dynamic) {}
		#end
	}

	private static function formatTime(timestamp:Float):String
	{
		var date:Date = Date.fromTime(Std.int(timestamp * 1000));
		return  zeroPad(date.getHours(), 2) + ":"
		      + zeroPad(date.getMinutes(), 2) + ":"
		      + zeroPad(date.getSeconds(), 2);
	}

	private static function zeroPad(num:Int, digits:Int):String
	{
		var str:String = Std.string(num);
		while (str.length < digits) str = '0$str';
		return str;
	}
}
