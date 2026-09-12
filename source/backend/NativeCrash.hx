package backend;

import StringTools;
import haxe.io.Bytes;
import openfl.Assets;
import mohong.TraceManager;

#if sys
import sys.FileSystem;
import sys.io.File;
import sys.io.FileSeek;
#end

/**
 * NativeCrash - C++-level crash hooks (implementation in native_crash.inc).
 *
 * Haxe's try/catch and UncaughtErrorEvent only see Haxe exceptions; driver
 * faults, access violations and LuaJIT aborts kill the process silently.
 * These hooks log, show a best-effort OS popup, and then let the process crash
 * as before; the marker left behind lets the next launch roll into the
 * existing crash-catcher recovery screen:
 *   - Windows SEH: exception code, faulting instruction pointer, access
 *     target pointer, faulting module, registers, dbghelp backtrace
 *     -> crash/native_crash_*.txt
 *   - POSIX (Linux/macOS/Android): SIGSEGV/SIGABRT/SIGBUS/SIGFPE/SIGILL ->
 *     signal, si_addr, full register dump, backtrace annotated with dladdr +
 *     the precomputed crash linemap (exact cpp file:line), /proc/self/maps
 *     snapshot, device properties (Android), logcat mirror (Android)
 *
 * The C++ handler cannot safely call back into Haxe, so the Haxe layer feeds
 * it context while the engine is still healthy:
 *   setCrashDir()      - absolute crash/ dir (Android has no usable cwd)
 *   setAppInfo()       - engine version string
 *   setRuntimeContext()- current state/song, refreshed periodically
 *   setRecentLogs()    - TraceManager tail, refreshed periodically
 *   setLinemap()       - address->file:line table (see tools/gen_linemap.py)
 */
#if cpp
@:cppInclude('./native_crash.inc')
#end
class NativeCrash
{
	static var installed:Bool = false;

	/** Keeps the linemap bytes alive so the raw pointer stored C-side stays valid. */
	static var linemapBytes:haxe.io.Bytes;

	/** Install native crash hooks first thing in Main.main() so even early startup faults are captured. */
	public static function install():Void
	{
		#if cpp
		if (installed) return;
		installed = true;

		try
		{
			untyped __cpp__("::seiun_install_native_crash_hooks()");

			// pre-create the crash dir (the C++ handler also creates it as a fallback)
			if (!FileSystem.exists('./crash/'))
				FileSystem.createDirectory('./crash/');
		}
		catch (e:Dynamic) {}
		#end
	}

	/**
	 * Absolute crash directory (with trailing slash), e.g. "<storage>crash/".
	 * On Android the process cwd is not usable for early crashes, so every
	 * native log/marker path is anchored here instead of "crash/".
	 */
	public static function setCrashDir(dir:String):Void
	{
		#if cpp
		if (dir == null || dir.length == 0) return;
		try { untyped __cpp__('::seiun_set_crash_dir({0}.__CStr())', dir); } catch (e:Dynamic) {}
		#end
	}

	/** One-line app identity, written into every native crash report. */
	public static function setAppInfo(info:String):Void
	{
		#if cpp
		if (info == null || info.length == 0) return;
		try { untyped __cpp__('::seiun_set_app_info({0}.__CStr())', info); } catch (e:Dynamic) {}
		#end
	}

	/**
	 * Build fingerprint, written into every native crash report.
	 *
	 * A report is only resolvable if it can be tied to the exe/PDB pair that
	 * produced it: the "Fault offset" values only mean something relative to one
	 * specific link. Reports used to carry no build identity, so a log could
	 * silently outlive several relinks and end up symbolized against the wrong
	 * PDB (which yields plausible-looking but completely wrong function names).
	 *
	 * Records exe and PDB size + mtime, plus a cheap content hash so two builds
	 * that differ only in a rebuild timestamp are still distinguishable.
	 */
	public static function setBuildInfo():Void
	{
		#if (cpp && sys)
		try
		{
			var parts:Array<String> = [];

			for (name in ['SeiunEngine.exe', 'ApplicationMain.exe', 'MohongEngine.exe'])
			{
				if (!FileSystem.exists(name)) continue;
				var st = FileSystem.stat(name);
				parts.push(name + '=' + st.size + 'B@' + Std.string(Std.int(st.mtime.getTime() / 1000)) + 's#' + fnv1aFile(name));
				break;
			}

			for (name in ['SeiunEngine.pdb', 'ApplicationMain.pdb', 'ApplicationMain.map'])
			{
				if (!FileSystem.exists(name)) continue;
				var st = FileSystem.stat(name);
				parts.push(name + '=' + st.size + 'B@' + Std.string(Std.int(st.mtime.getTime() / 1000)) + 's');
			}

			if (parts.length == 0) return;
			untyped __cpp__('::seiun_set_build_info({0}.__CStr())', parts.join(' | '));
		}
		catch (e:Dynamic) {}
		#end
	}

	/** FNV-1a over the first/last 64KB of a file: cheap, stable build discriminator. */
	static function fnv1aFile(path:String):String
	{
		try
		{
			var input = sys.io.File.read(path, true);
			var h:Int = 0x811C9DC5;
			var chunk:Int = 65536;
			for (round in 0...2)
			{
				if (round == 1)
				{
					var size = FileSystem.stat(path).size;
					if (size <= chunk * 2) break;
					input.seek(size - chunk, SeekBegin);
				}
				var bytes = input.read(chunk);
				for (i in 0...bytes.length)
				{
					h ^= bytes.get(i);
					h = (h * 0x01000193) & 0xFFFFFFFF;
				}
			}
			input.close();
			return StringTools.hex(h, 8);
		}
		catch (e:Dynamic)
		{
			return '?';
		}
	}

	/**
	 * Current engine situation (state / song / GL errors). Refreshed every few
	 * seconds by SystemDiag so a native crash report shows the exact gameplay
	 * context even though the process died below the Haxe layer.
	 */
	public static function setRuntimeContext(context:String):Void
	{
		#if cpp
		if (context == null || context.length == 0) return;
		try { untyped __cpp__('::seiun_set_runtime_context({0}.__CStr())', context); } catch (e:Dynamic) {}
		#end
	}

	/** Recent TraceManager log tail; embedded into native crash reports. */
	public static function setRecentLogs(logs:String):Void
	{
		#if cpp
		if (logs == null || logs.length == 0) return;
		try { untyped __cpp__('::seiun_set_recent_logs({0}.__CStr())', logs); } catch (e:Dynamic) {}
		#end
	}

	/**
	 * Load the crash linemap for this build's ABI (exact cpp file:line at
	 * crash time). Sources, in priority order:
	 *   1. <storage>/linemap/<abi>.bin      (adb push, no APK changes)
	 *   2. embedded asset assets/linemap/<abi>.bin (needs -DCRASH_LINEMAP)
	 * Generated from the unstripped .so by tools/gen_linemap.py.
	 */
	public static function loadLinemap(storageDir:String, libName:String = 'libApplicationMain'):Void
	{
		#if (cpp && sys)
		if (linemapBytes != null) return; // already loaded
		var abi:String = getCpuAbi();
		if (abi == null || abi == 'unknown') return;

		// 1) file pushed next to the game storage (dev workflow)
		#if android
		try
		{
			var diskPath:String = storageDir + 'linemap/' + abi + '.bin';
			if (sys.FileSystem.exists(diskPath))
			{
				var bytes:Bytes = File.getBytes(diskPath);
				applyLinemap(bytes, libName);
				TraceManager.info('trace.crash.linemapDisk', 'Crash linemap loaded from disk ({0} KB).', [Std.int(bytes.length / 1024)]);
				return;
			}
		}
		catch (e:Dynamic) {}
		#end

		// 2) embedded asset (opt-in via -DCRASH_LINEMAP in Project.xml)
		try
		{
			var assetPath:String = 'assets/linemap/' + abi + '.bin';
			if (Assets.exists(assetPath))
			{
				var bytes:Bytes = Assets.getBytes(assetPath);
				applyLinemap(bytes, libName);
				TraceManager.info('trace.crash.linemapAsset', 'Crash linemap loaded from embedded assets ({0} KB).', [Std.int(bytes.length / 1024)]);
			}
		}
		catch (e:Dynamic) {}
		#end
	}

	static function applyLinemap(bytes:Bytes, libName:String):Void
	{
		#if cpp
		if (bytes == null || bytes.length < 20) return;
		linemapBytes = bytes; // keep alive: the C side stores the raw pointer
		try
		{
			// {0} = bytes.getData() -> ::Array<unsigned char> handle;
			// operator-> reaches Array_obj::Pointer() for the raw uchar storage.
			untyped __cpp__('::seiun_set_linemap((const void*){0}->Pointer(), (unsigned int){1}, {2}.__CStr())',
				bytes.getData(), bytes.length, libName);
		}
		catch (e:Dynamic)
		{
			linemapBytes = null;
		}
		#end
	}

	/** ABI of the running build ("arm64-v8a" / "armeabi-v7a" / ...), or "unknown". */
	public static function getCpuAbi():String
	{
		#if cpp
		try { return untyped __cpp__('::seiun_get_cpu_abi()'); }
		catch (e:Dynamic) {}
		#end
		return 'unknown';
	}

	/**
	 * Install a LuaJIT panic handler on a lua_State (llua.State).
	 *
	 * Unprotected errors inside the Lua VM (no pcall boundary) make LuaJIT print
	 * "PANIC: unprotected error..." and kill the process without leaving any
	 * engine-side log. With this hook the panic writes crash/native_crash_*.txt
	 * (Lua error message + backtrace) before the process aborts.
	 */
	public static function installLuaPanic(luaState:llua.State):Void
	{
		#if cpp
		if (luaState == null) return;
		try
		{
			// Haxe's generated C++ lives in `namespace backend`, so the call must
			// be explicitly global-qualified; otherwise the linker looks for
			// `backend::seiun_install_lua_panic` and fails on Linux/macOS/iOS.
			untyped __cpp__('::seiun_install_lua_panic((void*){0});', luaState);
		}
		catch (e:Dynamic) {}
		#end
	}

	/**
	 * Consume a native crash marker written by native_crash.inc.
	 *
	 * If the previous process ended via a native crash (SEH, fatal signal or
	 * LuaJIT panic), the C++ layer leaves crash/native_crash.pending next to
	 * the log file. This returns the latest log path/content and removes the
	 * marker, so the game can show the crash-catcher recovery screen exactly
	 * once. Native log files themselves are kept for future reports.
	 */
	public static function consumePendingNativeCrash():Null<{path:String, content:String}>
	{
		#if sys
		try
		{
			var markerPath:String = './crash/native_crash.pending';
			if (!FileSystem.exists(markerPath)) return null;

			var logPath:String = StringTools.trim(File.getContent(markerPath));
			if (logPath == '' || !FileSystem.exists(logPath))
			{
				try { FileSystem.deleteFile(markerPath); } catch (e:Dynamic) {}
				return null;
			}

			var content:String = File.getContent(logPath);
			try { FileSystem.deleteFile(markerPath); } catch (e:Dynamic) {}
			return {path: logPath, content: content};
		}
		catch (e:Dynamic)
		{
			return null;
		}
		#else
		return null;
		#end
	}
}
