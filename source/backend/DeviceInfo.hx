package backend;

#if sys
import sys.io.File;
import sys.io.Process;
#end

/**
 * Cross-platform device / OS info for the FPS counter and crash reports.
 *
 * Windows: PROCESSOR_IDENTIFIER + PROCESSOR_ARCHITECTURE env vars.
 * macOS:   sysctl machdep.cpu.brand_string (+ uname for arch).
 * Linux:   /proc/cpuinfo "model name" + uname -m.
 * Android: android.os.Build (MODEL / HARDWARE / SUPPORTED_ABIS).
 * iOS:     lime.system.System.deviceModel / deviceVendor.
 */
class DeviceInfo
{
	static var _osName:String = null;
	static var _arch:String = null;
	static var _cpu:String = null;
	static var _model:String = null;
	static var _summary:String = null;

	/** Short OS label, e.g. "Windows 11", "macOS", "Android 15". */
	public static function osName():String
	{
		if (_osName != null) return _osName;
		#if windows
		var ver = Sys.getEnv('OS');
		_osName = (ver != null && ver.length > 0) ? ver : 'Windows';
		#elseif mac
		_osName = 'macOS';
		#elseif linux
		_osName = 'Linux';
		#elseif android
		_osName = 'Android ' + android.os.Build.VERSION.RELEASE;
		#elseif ios
		var ver:String = '';
		try { ver = lime.system.System.platformVersion; } catch (e:Dynamic) {}
		_osName = (ver != null && ver.length > 0) ? 'iOS ' + ver : 'iOS';
		#elseif js
		_osName = 'Web Browser';
		#else
		_osName = Sys.systemName();
		#end
		return _osName;
	}

	/** CPU architecture, e.g. "x64", "ARM64". */
	public static function architecture():String
	{
		if (_arch != null) return _arch;
		#if windows
		var arch = Sys.getEnv('PROCESSOR_ARCHITECTURE');
		_arch = (arch != null && arch.length > 0) ? arch : 'x64';
		#elseif js
		_arch = 'Web';
		#elseif ios
		// No process to spawn on the sandboxed phone targets (`sys.io.Process` is
		// unavailable), which is why iOS used to report "unknown".
		_arch = #if HXCPP_ARM64 "ARM64" #elseif HXCPP_ARM7 "ARMv7" #else "x64" #end;
		#else
		var m = '';
		try { m = runCapture('uname', ['-m']); } catch (e:Dynamic) {}
		_arch = (m != null && m.length > 0) ? m : 'unknown';
		#end
		return _arch;
	}

	/** CPU brand string, e.g. "AMD Ryzen 7 5800X". */
	public static function cpuName():String
	{
		if (_cpu != null) return _cpu;
		#if windows
		var cpu = Sys.getEnv('PROCESSOR_IDENTIFIER');
		_cpu = (cpu != null && cpu.length > 0) ? cpu : 'Unknown CPU';
		#elseif mac
		try { _cpu = runCapture('sysctl', ['-n', 'machdep.cpu.brand_string']); } catch (e:Dynamic) {}
		if (_cpu == null || _cpu.length == 0) _cpu = 'Apple Silicon';
		#elseif linux
		try
		{
			var info = File.getContent('/proc/cpuinfo');
			for (line in info.split('\n'))
			{
				if (line.startsWith('model name'))
				{
					var idx = line.indexOf(':');
					if (idx >= 0) { _cpu = line.substr(idx + 1).trim(); break; }
				}
			}
		}
		catch (e:Dynamic) {}
		if (_cpu == null || _cpu.length == 0) _cpu = 'Linux CPU';
		#elseif android
		_cpu = android.os.Build.HARDWARE;
		#elseif ios
		_cpu = 'Apple ' + lime.system.System.deviceModel;
		#else
		_cpu = 'Unknown CPU';
		#end
		return _cpu;
	}

	/** Device model (mostly meaningful on phones/tablets). */
	public static function deviceModel():String
	{
		if (_model != null) return _model;
		#if android
		_model = android.os.Build.MODEL;
		#elseif ios
		_model = lime.system.System.deviceModel;
		#else
		_model = '';
		#end
		return _model;
	}

	/** One-line summary, e.g. "Windows 11 x64 | AMD Ryzen 7 5800X". */
	public static function summary():String
	{
		if (_summary != null) return _summary;
		var parts:Array<String> = [];
		var os = osName();
		var arch = architecture();
		if (os.length > 0 && arch.length > 0)
			parts.push('$os $arch');
		else if (os.length > 0)
			parts.push(os);

		var model = deviceModel();
		if (model != null && model.length > 0)
			parts.push(model);

		var cpu = cpuName();
		if (cpu != null && cpu.length > 0)
			parts.push(cpu);

		_summary = parts.join(' | ');
		return _summary;
	}

	/**
	 * Compact one-line summary for the FPS overlay: truncates the CPU brand
	 * so the line never overflows the on-screen panel.
	 */
	public static function shortSummary(?maxLen:Int = 44):String
	{
		var s = summary();
		if (s.length <= maxLen) return s;
		return s.substr(0, maxLen - 1) + '…';
	}

	static function runCapture(cmd:String, args:Array<String>):String
	{
		#if sys
		var p = new Process(cmd, args);
		var out = p.stdout.readAll().toString();
		p.exitCode();
		p.close();
		return StringTools.trim(out);
		#else
		return '';
		#end
	}
}
