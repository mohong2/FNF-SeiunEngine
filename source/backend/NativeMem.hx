package backend;

import lime.system.System as LimeSystem;

#if windows
// Same reasoning as mohong/Windows.hx: a header-level windows.h would leak its
// macros (OUT, TRANSPARENT, WAIT_FAILED, COLOR_*) into every translation unit that
// includes this class' header through __boot__.cpp. The declarations are only
// needed by this class' own .cpp.
@:cppFileCode('
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <psapi.h>
#undef ERROR
#undef FALSE
#undef TRUE
#undef NO_ERROR
#undef DELETE
#undef OUT
#undef IN
#undef TRANSPARENT
#undef WAIT_FAILED
#undef COLOR_HIGHLIGHT
')
#end


class NativeMem
{
	public static var rssBytes(default, null):Float = -1;
	public static var peakRSSBytes(default, null):Float = -1;
	public static var totalPhysBytes(default, null):Float = -1;

	public static var supported(get, never):Bool;

	static inline var TTL:Float = 300;
	static var lastRead:Float = -1000000;

	public static function update():Void
	{
		#if (windows || android || linux)
		var now = LimeSystem.getTimer();
		if (now - lastRead < TTL) return;
		lastRead = now;
		#if windows
		var r = readRSSNative();
		if (r >= 0) rssBytes = r;
		var p = readPeakNative();
		if (p >= 0) peakRSSBytes = p;
		if (totalPhysBytes < 0) totalPhysBytes = readTotalNative();
		#else
		readProcFiles();
		#end
		#end
	}

	static function get_supported():Bool
	{
		#if (windows || android || linux)
		return true;
		#else
		return false;
		#end
	}

	#if (android || linux)
	static function readProcFiles():Void
	{
		try
		{
			var status:String = sys.io.File.getContent('/proc/self/status');
			var rss:Float = parseProcKb(status, 'VmRSS:');
			var hwm:Float = parseProcKb(status, 'VmHWM:');
			if (rss >= 0) rssBytes = rss * 1024;
			if (hwm >= 0) peakRSSBytes = hwm * 1024;
		}
		catch (e:Dynamic) {}

		if (totalPhysBytes < 0)
		{
			try
			{
				var meminfo:String = sys.io.File.getContent('/proc/meminfo');
				var total:Float = parseProcKb(meminfo, 'MemTotal:');
				if (total >= 0) totalPhysBytes = total * 1024;
			}
			catch (e:Dynamic) {}
		}
	}

	static function parseProcKb(content:String, key:String):Float
	{
		var idx = content.indexOf(key);
		if (idx < 0) return -1;
		var end = content.indexOf('\n', idx);
		var line = (end < 0) ? content.substr(idx) : content.substr(idx, end - idx);
		var digits = '';
		for (i in 0...line.length)
		{
			var c = line.charCodeAt(i);
			if (c >= '0'.code && c <= '9'.code) digits += line.charAt(i);
			else if (digits.length > 0) break;
		}
		if (digits.length == 0) return -1;
		return Std.parseFloat(digits);
	}
	#end

	#if windows
	@:functionCode('
		PROCESS_MEMORY_COUNTERS pmc;
		memset(&pmc, 0, sizeof(pmc));
		pmc.cb = sizeof(pmc);
		if (K32GetProcessMemoryInfo(GetCurrentProcess(), &pmc, sizeof(pmc)))
			return (double)pmc.WorkingSetSize;
		return -1;
	')
	static function readRSSNative():Float { return -1; }

	@:functionCode('
		PROCESS_MEMORY_COUNTERS pmc;
		memset(&pmc, 0, sizeof(pmc));
		pmc.cb = sizeof(pmc);
		if (K32GetProcessMemoryInfo(GetCurrentProcess(), &pmc, sizeof(pmc)))
			return (double)pmc.PeakWorkingSetSize;
		return -1;
	')
	static function readPeakNative():Float { return -1; }

	@:functionCode('
		MEMORYSTATUSEX ms;
		memset(&ms, 0, sizeof(ms));
		ms.dwLength = sizeof(ms);
		if (GlobalMemoryStatusEx(&ms))
			return (double)ms.ullTotalPhys;
		return -1;
	')
	static function readTotalNative():Float { return -1; }
	#end
}
