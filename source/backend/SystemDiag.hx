package backend;

import flixel.FlxG;
import lime.graphics.opengl.GL;
import lime.system.System as LimeSystem;
import openfl.display._internal.stats.Context3DStats;
import openfl.system.System as OpenFlSystem;
import mohong.TraceEntry;
import mohong.TraceManager;
import states.MainMenuState;
import states.PlayState;

#if sys
import sys.io.File;
import sys.FileSystem;
#end

/**
 * SystemDiag - builds the full diagnostic report embedded in every crash dump:
 * engine/OS/window info, Lime+OpenGL renderer & GPU details, runtime state,
 * recent TraceManager logs, and any native crash logs (memory pointers).
 * Every collector is individually sandboxed so a dead renderer can never
 * crash the reporter itself.
 */
class SystemDiag
{
	public static var LOG_TAIL:Int = 400;
	public static var EXTENSIONS_CAP:Int = 1500;
	/** How many earlier crash files the index lists (they are never reproduced). */
	public static var NATIVE_LOG_INDEX:Int = 8;

	static var nextHeartbeatAt:Float = 0;
	static var lastHeartbeatContent:String = '';

	// GL strings are stable for a process lifetime: capture once, reuse.
	static var glCaptureTried:Bool = false;
	static var glVendor:String = '';
	static var glRenderer:String = '';
	static var glVersion:String = '';
	static var glSl:String = '';
	static var glExtTotal:Int = 0;
	static var glExtShown:String = '';
	static var glExtTruncated:Bool = false;

	// ============================================================
	// Entry points
	// ============================================================

	public static function buildReport():String
	{
		var out:Array<String> = [];
		out.push('=== System Report ===');
		out.push('Date: ' + safeDate());

		out.push('');
		out.push('--- Engine ---');
		engineLines(out);

		out.push('');
		out.push('--- OS / Device ---');
		deviceLines(out);

		out.push('');
		out.push('--- Window / Display ---');
		windowLines(out);

		out.push('');
		out.push('--- Renderer / GPU (Lime/OpenFL) ---');
		rendererLines(out);

		out.push('');
		out.push('--- Runtime ---');
		runtimeLines(out);

		out.push('');
		out.push('--- Latest GL error ---');
		out.push(GlErrorWatchdog.snapshot());

		out.push('');
		out.push('--- Other crash files ---');
		nativeCrashLines(out);

		out.push('');
		out.push('--- Recent Game Log (last ' + LOG_TAIL + ' of ' + TraceManager.getCount() + ' entries) ---');
		traceLogLines(out, LOG_TAIL);

		return out.join('\n');
	}

	/** Full crash dump: error + stack + system report + logs. Shared by Main and CrashCatcherState. */
	public static function buildCrashDump(errorMsg:String, stackText:String, crashCount:Int = 0):String
	{
		var out:Array<String> = [];
		out.push('=== SeiunEngine Crash Report ===');
		out.push('Kind: Haxe uncaught exception');
		out.push('Date: ' + safeDate());
		out.push('Crash Count: ' + crashCount);
		out.push('');
		out.push('Error:');
		out.push(errorMsg == null ? '(null)' : errorMsg);
		out.push('');
		out.push('Stack Trace:');
		var stack = stackText == null ? '' : StringTools.trim(stackText);
		if (stack == '')
		{
			// Release builds deliberately run without HXCPP_STACK_TRACE (it costs
			// time on every generated call and keeps large string tables alive), so
			// this section is expected to be empty. Saying so beats a blank line
			// that reads like a bug in the crash handler.
			out.push('(empty - Haxe stacks are not recorded in this build)');
			out.push('Use the engine log tail below (every entry carries source/File.hx:line)');
			out.push('and the linemap annotations on any native backtrace.');
		}
		else
		{
			out.push(stack);
		}
		out.push('');
		out.push(buildReport());
		return out.join('\n');
	}

	// ============================================================
	// Sections
	// ============================================================

	static function engineLines(out:Array<String>):Void
	{
		out.push('Engine: SeiunEngine v' + safeString(() -> MainMenuState.seiunengineVersion, '?'));
		out.push('Psych Engine Base: ' + MainMenuState.psychEngineVersion);
		out.push('FNF Game Version: ' + MainMenuState.fnfGameVersion);
		out.push('HaxeFlixel: ' + safeString(() -> Std.string(FlxG.VERSION), '?'));

		#if sys
		try
		{
			if (FileSystem.exists('gitVersion.txt'))
				out.push('gitVersion: ' + File.getContent('gitVersion.txt').trim());
		}
		catch (e:Dynamic) {}
		#end

		// Dev builds: read real library versions from the local haxelib dir.
		#if sys
		out.push('libs (dev haxelib): ' + safeString(() -> {
			var parts:Array<String> = [];
			for (lib in ['lime', 'openfl', 'flixel'])
			{
				var cur = '.haxelib/' + lib + '/.current';
				if (FileSystem.exists(cur))
					parts.push(lib + '=' + File.getContent(cur).trim());
			}
			return parts.length > 0 ? parts.join(', ') : 'n/a';
		}, 'n/a'));
		#end

		var feat:Array<String> = [];
		#if CRASH_HANDLER feat.push('CRASH_HANDLER'); #end
		#if MODS_ALLOWED feat.push('MODS_ALLOWED'); #end
		#if LUA_ALLOWED feat.push('LUA_ALLOWED'); #end
		#if HSCRIPT_ALLOWED feat.push('HSCRIPT_ALLOWED'); #end
		#if VIDEOS_ALLOWED feat.push('VIDEOS_ALLOWED'); #end
		#if ACHIEVEMENTS_ALLOWED feat.push('ACHIEVEMENTS_ALLOWED'); #end
		#if separateUpdateDraw feat.push('separateUpdateDraw'); #end
		#if mobile feat.push('mobile'); #end
		#if html5 feat.push('html5'); #end
		out.push('Build features: ' + (feat.length > 0 ? feat.join(' ') : 'none'));
	}

	static function deviceLines(out:Array<String>):Void
	{
		out.push('Device: ' + DeviceInfo.summary());
		out.push('Platform: ' + safeString(() -> LimeSystem.platformName, '?')
			+ ' ' + safeString(() -> LimeSystem.platformLabel, '?')
			+ ' (' + safeString(() -> LimeSystem.platformVersion, '?') + ')');
		out.push('Displays: ' + safeString(() -> Std.string(LimeSystem.numDisplays), '?'));

		out.push('Logical CPUs: ' + safeString(() -> {
			var s = Sys.getEnv('NUMBER_OF_PROCESSORS');
			var n = s == null ? 0 : Std.parseInt(s);
			return n > 0 ? Std.string(n) : '?';
		}, '?'));

		out.push('Process Memory: ' + safeMemory(OpenFlSystem.totalMemory));
	}

	static function windowLines(out:Array<String>):Void
	{
		safeLines(() -> {
			var window = FlxG.stage.window;
			if (window == null) return '(no window)';
			var pos = Std.string(window.x) + ',' + Std.string(window.y);
			var mode = '?';
			try
			{
				var dm = window.displayMode;
				if (dm != null)
					mode = Std.string(dm.width) + 'x' + Std.string(dm.height) + ' @' + Std.string(dm.refreshRate) + 'Hz';
			}
			catch (e:Dynamic) {}
			var scale:Float = 1;
			try { scale = window.scale; } catch (e:Dynamic) {}
			return 'Window: ' + Std.string(window.width) + 'x' + Std.string(window.height)
				+ ' pos=' + pos
				+ ' scale=' + Std.string(scale)
				+ ' fullscreen=' + Std.string(window.fullscreen)
				+ ' borderless=' + Std.string(window.borderless)
				+ '\nDisplayMode: ' + mode;
		}, out, '(no window)');

		safeLines(() -> {
			var stage = FlxG.stage;
			return 'Stage: ' + Std.string(stage.stageWidth) + 'x' + Std.string(stage.stageHeight)
				+ ' scaleMode=' + Std.string(stage.scaleMode);
		}, out, '(no stage)');
	}

	static function rendererLines(out:Array<String>):Void
	{
		// Lime RenderContext: type + version + creation attributes (live query).
		safeLines(() -> {
			var ctx = FlxG.stage.window.context;
			if (ctx == null) return '(no render context)';
			var attr = ctx.attributes;
			var attrs = '';
			if (attr != null)
			{
				attrs = 'hardware=' + Std.string(attr.hardware)
					+ ' vsync=' + Std.string(attr.vsync)
					+ ' depth=' + Std.string(attr.depth)
					+ ' stencil=' + Std.string(attr.stencil)
					+ ' antialias=' + Std.string(attr.antialiasing)
					+ ' colorDepth=' + Std.string(attr.colorDepth);
			}
			return 'RenderContext: type=' + Std.string(ctx.type)
				+ ' version=' + Std.string(ctx.version)
				+ (attrs.length > 0 ? '\nContext Attributes: ' + attrs : '');
		}, out, '(no render context)');

		// OpenFL Context3D driverInfo: Vendor / Version / Renderer / GLSL.
		safeLines(() -> {
			var c3d = FlxG.stage.context3D;
			if (c3d == null) return 'Context3D: (null - no GL context yet)';
			return 'Context3D driverInfo: ' + c3d.driverInfo
				+ '\nContext3D maxBackBuffer: ' + Std.string(c3d.maxBackBufferWidth) + 'x' + Std.string(c3d.maxBackBufferHeight);
		}, out, '(null)');

		// Raw GL strings + extensions (queried once per session, see captureGlInfo).
		captureGlInfo();
		if (glVendor == '' && glRenderer == '')
		{
			out.push('GL strings: (not available)');
		}
		else
		{
			out.push('GL Vendor: ' + glVendor);
			out.push('GL Renderer: ' + glRenderer);
			out.push('GL Version: ' + glVersion);
			if (glSl != '') out.push('GLSL: ' + glSl);
			if (glExtTotal > 0 || glExtShown != '')
				out.push('GL extensions (' + glExtTotal + '): ' + glExtShown + (glExtTruncated ? ' ...' : ''));
			else
				out.push('GL extensions: (none)');
		}

		// GPU memory (only drives exposing NVX_gpu_memory_info report it).
		safeLines(() -> {
			var c3d = FlxG.stage.context3D;
			if (c3d == null) return 'GPU memory: (null)';
			var mem:Int = 0;
			try { mem = c3d.totalGPUMemory; } catch (e:Dynamic) { mem = 0; }
			return mem > 0 ? 'GPU memory in use (approx): ' + Std.string(mem) + ' bytes (' + fmtMb(mem) + ' MB)' : 'GPU memory: not supported by driver';
		}, out, '(GPU memory unavailable)');
	}

	static function runtimeLines(out:Array<String>):Void
	{
		out.push('Process Memory: ' + safeMemory(OpenFlSystem.totalMemory));

		safeLines(() -> {
			return 'Draw calls (frame): ' + Std.string(Context3DStats.totalDrawCalls());
		}, out, '(draw calls unavailable)');

		safeLines(() -> {
			var fps:Int = 0;
			if (Main.fpsVar != null) { try { fps = Main.fpsVar.currentFPS; } catch (e:Dynamic) {} }
			return 'FPS (last frame): ' + Std.string(fps);
		}, out, '(fps unavailable)');

		safeLines(() -> {
			var count:Int = 0;
			@:privateAccess
			for (g in FlxG.bitmap._cache) count++;
			var tracked:Int = 0;
			try { tracked = Lambda.count(Paths.currentTrackedAssets); } catch (e:Dynamic) {}
			var mod = '';
			try
			{
				var md = Paths.currentModDirectory;
				if (md != null && md.length > 0) mod = ' | activeMod=' + md;
			}
			catch (e:Dynamic) {}
			return 'Graphics cached: ' + Std.string(count) + ' | tracked: ' + Std.string(tracked) + mod;
		}, out, '(graphics cache unavailable)');

		safeLines(() -> {
			return 'GfxPolicy: released(live)=' + Std.string(GfxPolicy.releasedBytesLive)
				+ ' bytes, released(total)=' + Std.string(GfxPolicy.releasedCountTotal)
				+ ' count, restores=' + Std.string(GfxPolicy.restoredCountTotal)
				+ ', LRU live=' + Std.string(GfxLru.liveEntries()) + ' entries';
		}, out, '(gfx policy unavailable)');

		// Which screen / song the crash happened on.
		safeLines(() -> {
			var stateName = 'null';
			try { if (FlxG.state != null) stateName = Type.getClassName(Type.getClass(FlxG.state)); } catch (e:Dynamic) {}
			var song = 'null';
			try { if (PlayState.SONG != null) song = Std.string(PlayState.SONG.song); } catch (e:Dynamic) {}
			return 'FlxG.state: ' + stateName + ' | current song: ' + song;
		}, out, '(state unavailable)');
	}

	// ============================================================
	// Native crash logs & heartbeat
	// ============================================================

	/**
	 * One readable line identifying a crash file: its Error/Exception/kind, which
	 * is all a reader needs to tell two reports apart.
	 */
	static function crashHeadline(content:String):String
	{
		var lines = content.split('\n');
		var kind = '';
		var err = '';
		for (i in 0...lines.length)
		{
			var t = StringTools.trim(lines[i]);
			if (t == '') continue;
			if (kind == '')
			{
				if (StringTools.startsWith(t, 'Kind:')) kind = StringTools.trim(t.substr(5));
				else if (StringTools.startsWith(t, 'Exception code:')) kind = t;
			}
			if (err == '' && StringTools.startsWith(t, 'Error:'))
			{
				var rest = StringTools.trim(t.substr(6));
				if (rest == '' && i + 1 < lines.length) rest = StringTools.trim(lines[i + 1]);
				err = rest;
			}
			if (kind != '' && err != '') break;
		}
		var head = err != '' ? err : kind;
		if (head == '') head = StringTools.trim(lines[0]);
		if (head == '') head = '(no summary line)';
		if (head.length > 110) head = head.substr(0, 107) + '...';
		return head;
	}

	/**
	 * Index of the other crash files already in crash/ - name, size, headline.
	 *
	 * This used to paste the newest five files verbatim (up to 3000 characters
	 * each), so every new report carried a copy of the previous ones: 20+ KB of
	 * nested reports that were genuinely painful to read, and crash_triage.py
	 * could trip over an embedded old report and misclassify the file it sat in.
	 * This report already describes THIS crash completely; the older files are
	 * listed, not reproduced.
	 */
	static function nativeCrashLines(out:Array<String>):Void
	{
		#if sys
		try
		{
			if (!FileSystem.exists('./crash/'))
			{
				out.push('(no crash/ directory)');
				return;
			}
			var files:Array<String> = [];
			// Native dumps plus the Haxe-layer ones; the two legacy prefixes are kept so old
			// files already sitting in crash/ still show up.
			for (f in FileSystem.readDirectory('./crash/'))
				if (f.endsWith('.txt') && (f.indexOf('native_crash_') == 0 || f.indexOf('SeiunEngine_') == 0
					|| f.indexOf('CrashReport_') == 0 || f.indexOf('MohonghEngine_') == 0))
					files.push(f);
			files.sort(Reflect.compare);

			if (files.length == 0)
			{
				out.push('(none)');
				return;
			}

			out.push('(name - size - headline; the files themselves are NOT reproduced here)');
			var shown = files.slice(-NATIVE_LOG_INDEX);
			for (f in shown)
			{
				var size = '? KB';
				var head = '(unreadable)';
				try
				{
					size = Std.string(Std.int(FileSystem.stat('./crash/' + f).size / 1024)) + ' KB';
				}
				catch (e:Dynamic) {}
				try
				{
					head = crashHeadline(File.getContent('./crash/' + f));
				}
				catch (e:Dynamic) {}
				out.push(StringTools.rpad(f, ' ', 44) + ' ' + StringTools.lpad(size, ' ', 7) + '  ' + head);
			}
			if (files.length > shown.length)
				out.push('(+' + (files.length - shown.length) + ' older file(s) not listed)');
		}
		catch (e:Dynamic)
		{
			out.push('(failed to list native crash logs: ' + Std.string(e) + ')');
		}
		#else
		out.push('(native crash logs only supported on sys targets)');
		#end
	}

	/**
	 * Heartbeat: appends the current state to crash/heartbeat.txt every ~5s.
	 * If the process is killed below the Haxe layer (driver reset etc.), the
	 * last heartbeat still pinpoints where it happened. The file is written
	 * only when something meaningful changed (state / fps bucket / memory
	 * bucket / GL error), to keep the 5s tick nearly free.
	 */
	public static function setupHeartbeat():Void
	{
		try
		{
			FlxG.signals.preUpdate.add(function() {
				var now = haxe.Timer.stamp();
				if (now < nextHeartbeatAt) return;
				nextHeartbeatAt = now + 5;
				writeHeartbeat();
				feedNativeCrash();
			});
		}
		catch (e:Dynamic) {}
	}

	/**
	 * Push the current engine situation + recent log tail into the native
	 * crash handler (fixed-size C buffers, refreshed every ~5s while healthy).
	 * A crash below the Haxe layer then still reports the current state/song,
	 * GL errors and the last log lines, instead of a bare signal number.
	 */
	static function feedNativeCrash():Void
	{
		#if sys
		try
		{
			var stateName:String = 'null';
			try { if (FlxG.state != null) stateName = Type.getClassName(Type.getClass(FlxG.state)); } catch (e:Dynamic) {}
			var song:String = 'null';
			try { if (PlayState.SONG != null) song = Std.string(PlayState.SONG.song); } catch (e:Dynamic) {}

			var gfxFlags:String = '';
			try {
				gfxFlags = ' | cpuRelease=' + Std.string(ClientPrefs.data.gfxCpuRelease)
					+ ' lowQuality=' + Std.string(ClientPrefs.data.lowQuality);
			} catch (e:Dynamic) {}
			NativeCrash.setRuntimeContext('state=' + stateName + ' | song=' + song + ' | glErr=' + GlErrorWatchdog.snapshot() + gfxFlags);
			NativeCrash.setRecentLogs(TraceManager.getRecentCrashText());
		}
		catch (e:Dynamic) {}
		#end
	}

	public static function writeHeartbeat():Void
	{
		#if sys
		try
		{
			var stateName = 'null';
			try { if (FlxG.state != null) stateName = Type.getClassName(Type.getClass(FlxG.state)); } catch (e:Dynamic) {}
			var fps:Int = 0;
			try { if (Main.fpsVar != null) fps = Main.fpsVar.currentFPS; } catch (e:Dynamic) {}
			var mem:Int = 0;
			try { mem = Std.int(OpenFlSystem.totalMemory / 1048576); } catch (e:Dynamic) {}

			// Bucket the volatile values so the file is rewritten only on real change.
			var content = 'state=' + stateName
				+ ' | fps=' + Std.string(Std.int(fps / 5) * 5)
				+ ' | mem=' + Std.string(Std.int(mem / 10) * 10) + 'MB'
				+ ' | glErr=' + GlErrorWatchdog.snapshot();
			if (content == lastHeartbeatContent) return;
			lastHeartbeatContent = content;

			if (!FileSystem.exists('./crash/'))
				FileSystem.createDirectory('./crash/');
			File.saveContent('./crash/heartbeat.txt', Date.now().toString() + ' | ' + content + '\n');
		}
		catch (e:Dynamic) {}
		#end
	}

	// ============================================================
	// TraceManager log tail
	// ============================================================

	static function traceLogLines(out:Array<String>, tail:Int):Void
	{
		var all:Array<TraceEntry> = [];
		try { all = TraceManager.getAll(); } catch (e:Dynamic) { all = []; }

		if (all.length == 0)
		{
			out.push('(no log entries)');
			return;
		}

		var start:Int = all.length > tail ? all.length - tail : 0;
		for (i in start...all.length)
		{
			var e:TraceEntry = all[i];
			var levelStr:String = switch (e.level)
			{
				case DEBUG: 'DEBUG';
				case INFO: 'INFO';
				case WARN: 'WARN';
				case ERROR: 'ERROR';
				default: '???';
			}
			var moduleInfo:String = (e.moduleName != null && e.moduleName != 'unknown')
				? e.moduleName + ':' + Std.string(e.lineNumber) + ' '
				: '';
			out.push('[' + formatStamp(e.timestamp) + '][' + levelStr + '] ' + moduleInfo + '> ' + e.message);
		}
	}

	static function formatStamp(timestamp:Float):String
	{
		if (timestamp <= 0) return '00:00:00.000';
		var date:Date = Date.fromTime(timestamp * 1000);
		var h:String = pad(Std.string(date.getHours()), 2);
		var m:String = pad(Std.string(date.getMinutes()), 2);
		var s:String = pad(Std.string(date.getSeconds()), 2);
		var ms:String = pad(Std.string(Math.floor((timestamp - Math.floor(timestamp)) * 1000)), 3);
		return h + ':' + m + ':' + s + '.' + ms;
	}

	static function pad(s:String, len:Int):String
	{
		while (s.length < len) s = '0' + s;
		return s;
	}

	// ============================================================
	// Helpers
	// ============================================================

	/** Query the four GL identity strings + extension list once (session-stable). */
	static function captureGlInfo():Void
	{
		if (glCaptureTried) return;
		glCaptureTried = true;
		try
		{
			if (GL.context == null)
			{
				glCaptureTried = false; // context not ready yet: retry next report
				return;
			}
			glVendor = glStr(GL.VENDOR);
			glRenderer = glStr(GL.RENDERER);
			glVersion = glStr(GL.VERSION);
			glSl = glStr(GL.SHADING_LANGUAGE_VERSION);

			var exts:String = glStr(GL.EXTENSIONS);
			if (exts != null && exts.length > 0)
			{
				var list:Array<String> = exts.split(' ');
				glExtTotal = list.length;
				for (e in list)
				{
					if (e.length == 0) continue;
					if (glExtShown.length + e.length + 1 > EXTENSIONS_CAP)
					{
						glExtTruncated = true;
						break;
					}
					glExtShown += (glExtShown.length > 0 ? ' ' : '') + e;
				}
			}
			else glExtTotal = 0;
		}
		catch (e:Dynamic)
		{
			glCaptureTried = false;
			glVendor = '';
			glRenderer = '';
			glExtTotal = 0;
			glExtShown = '';
		}
	}

	static function glStr(which:Int):String
	{
		try
		{
			if (GL.context == null) return '';
			var s:String = GL.getString(which);
			return s == null ? '' : s;
		}
		catch (e:Dynamic) return '';
	}

	static function safe(fn:Void->String):String
	{
		try return fn() catch (e:Dynamic) return null;
	}

	static function safeString(fn:Void->String, fallback:String):String
	{
		var v = safe(fn);
		return (v == null || v.length == 0) ? fallback : v;
	}

	static function safeLines(fn:Void->String, out:Array<String>, fallback:String):Void
	{
		var v = safe(fn);
		out.push(v == null || v.length == 0 ? fallback : v);
	}

	static function safeMemory(bytes:Int):String
	{
		if (bytes <= 0) return '0 B';
		return Std.string(bytes) + ' bytes (' + fmtMb(bytes) + ' MB)';
	}

	static function fmtMb(bytes:Float):String
	{
		var mb = bytes / 1048576;
		return Std.string(Math.round(mb * 10) / 10);
	}

	static function safeDate():String
	{
		try return Date.now().toString() catch (e:Dynamic) return 'unknown';
	}
}
