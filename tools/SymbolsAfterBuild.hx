package tools;

import haxe.io.Bytes;
import sys.FileSystem;
import sys.io.File;
import sys.io.FileSeek;

/** One reported artifact. */
typedef Row =
{
	var role:String;
	var path:String;
	var kind:String;
	var detail:String;
	var fp:String;
}

/**
 * Post-build symbol collector for SeiunEngine.
 *
 * Wired into Project.xml as
 *
 *     <postbuild haxe="tools.SymbolsAfterBuild" />
 *
 * so the plain command
 *
 *     haxelib run lime build <target>
 *
 * ends with a [symbols] block naming every artifact that can turn a crash
 * report's "module + offset" back into a symbol or a source line.
 *
 * Haxe only, no Python: the hook runs "haxe -main tools.SymbolsAfterBuild
 * --interp", and haxe is guaranteed to exist because lime itself runs on it.
 *
 * In order:
 *   1. find the export/<mode>/<platform> tree this build just wrote,
 *   2. classify every candidate artifact (ELF section census, map, linemap, ...),
 *   3. MOVE the pure link byproducts (Windows .map/.pdb, Android's unstripped
 *      .so) into export/symbols/<platform>-<mode>/ instead of copying them, so
 *      the symbols of the last build of each target sit in one known place,
 *   4. move anything OLDER than the build that just finished into
 *      export/symbols/<platform>-<mode>/_stale/ - a leftover from an earlier
 *      build resolves offsets to plausible but wrong symbols,
 *   5. write export/symbols/<platform>-<mode>/build-info.txt.
 *
 * It never fails a build: lime ignores the postbuild exit code, and main()
 * traps everything.
 */
class SymbolsAfterBuild
{
	static inline var TAG = "[symbols]";
	static inline var HOUR = 3600000.0;
	static inline var FRESH_SLACK = 900000.0; // 15 min: mtime granularity, asset copies, clock skew

	static var PLATFORMS = ["windows", "android", "linux", "macos", "ios", "tvos", "html5", "neko", "switch"];
	static var MODES = ["release", "debug"];
	static var ANDROID_ABIS = ["arm64-v8a", "armeabi-v7a", "x86_64", "x86", "riscv64"];

	static var root:String;
	static var plat:String;
	static var mode:String;
	static var buildTime:Float = 0;
	static var info:Array<String> = [];
	static var argPlat:String = null;
	static var argMode:String = null;
	static var dryRun:Bool = false;

	static function main()
	{
		try
		{
			run();
		}
		catch (e:Dynamic)
		{
			Sys.println(TAG + " skipped (" + Std.string(e) + ")");
			Sys.exit(0);
		}
	}

	/**
	 * Manual overrides. Environment variables, not command-line switches: haxe's
	 * own argument parser rejects unknown --options before --interp ever runs.
	 */
	static function parseArgs():Void
	{
		argPlat = Sys.getEnv("SEIUN_SYMBOLS_PLATFORM");
		argMode = Sys.getEnv("SEIUN_SYMBOLS_MODE");
		dryRun = Sys.getEnv("SEIUN_SYMBOLS_DRY_RUN") != null;
	}

	static function run():Void
	{
		parseArgs();
		root = findRoot(Sys.getCwd());
		if (root == null)
		{
			Sys.println(TAG + " no Project.xml above " + Sys.getCwd() + " - skipping");
			return;
		}

		var d = detect();
		plat = argPlat != null ? argPlat : d.plat;
		mode = argMode != null ? argMode : d.mode;
		if (plat == null || mode == null)
		{
			Sys.println(TAG + " could not tell which platform was just built - skipping");
			return;
		}

		var outDir = root + "/export/" + mode + "/" + plat;
		if (!FileSystem.exists(outDir))
		{
			Sys.println(TAG + " " + plat + " " + mode + ": export/" + mode + "/" + plat + " does not exist - skipping");
			return;
		}

		var rows = collect(outDir);
		emit(rows);
		writeInfo(rows);
	}

	// -------------------------------------------------------------- locating
	static function findRoot(start:String):String
	{
		var d = start;
		for (_ in 0...7)
		{
			if (FileSystem.exists(d + "/Project.xml") && !FileSystem.isDirectory(d + "/Project.xml")) return d;
			var parent = parentOf(d);
			if (parent == d || parent == null) break;
			d = parent;
		}
		return null;
	}

	static function parentOf(p:String):String
	{
		var q = p.split("\\").join("/");
		while (q.length > 1 && StringTools.endsWith(q, "/")) q = q.substr(0, q.length - 1);
		var i = q.lastIndexOf("/");
		if (i <= 0) return q.substr(0, 1);
		return q.substr(0, i);
	}

	static function detect():{plat:String, mode:String}
	{
		var exportDir = root + "/export";
		var bestT = -1.0;
		var bestP:String = null;
		var bestM:String = null;
		for (m in MODES)
		{
			for (p in PLATFORMS)
			{
				var dir = exportDir + "/" + m + "/" + p;
				if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir)) continue;
				// Only obj/: bin/ is polluted by the game's own logs and saves, so its
				// mtimes say more about the last play session than about the last build.
				var o = dir + "/obj";
				var t = (FileSystem.exists(o) && FileSystem.isDirectory(o)) ? newest(o) : newest(dir);
				if (t > bestT)
				{
					bestT = t;
					bestP = p;
					bestM = m;
				}
			}
		}
		return { plat: bestP, mode: bestM };
	}

	static function newest(dir:String):Float
	{
		var t = mtime(dir);
		var names:Array<String>;
		try names = FileSystem.readDirectory(dir) catch (e:Dynamic) return t;
		var n = 0;
		for (name in names)
		{
			if (n++ > 400) break;
			t = Math.max(t, mtime(dir + "/" + name));
		}
		return t;
	}

	static function mtime(p:String):Float
	{
		try return FileSystem.stat(p).mtime.getTime() catch (e:Dynamic) return 0.0;
	}

	static function size(p:String):Float
	{
		try return FileSystem.stat(p).size catch (e:Dynamic) return 0.0;
	}

	static function isFile(p:String):Bool
	{
		try return FileSystem.exists(p) && !FileSystem.isDirectory(p) catch (e:Dynamic) return false;
	}

	static function files(dir:String):Array<String>
	{
		if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir)) return [];
		var out = [];
		try
		{
			for (name in FileSystem.readDirectory(dir))
			{
				var p = dir + "/" + name;
				if (isFile(p)) out.push(p);
			}
		}
		catch (e:Dynamic) {}
		out.sort(function(a, b) return a < b ? -1 : (a > b ? 1 : 0));
		return out;
	}

	static function glob(dir:String, suffix:String):Array<String>
	{
		var out = [];
		for (p in files(dir)) if (StringTools.endsWith(p.toLowerCase(), suffix)) out.push(p);
		return out;
	}

	static function rel(p:String):String
	{
		return StringTools.startsWith(p, root + "/") ? p.substr(root.length + 1) : p;
	}

	// ---------------------------------------------------------------- census
	static function seekTo(f:sys.io.FileInput, p:Float):Void
	{
		f.seek(Std.int(p), FileSeek.SeekBegin);
	}

	/** e_shentsize / e_shnum / e_shstrndx are 16-bit; reading 4 bytes there runs
	    past the end of the 64-byte header and silently picks up the next field. */
	static function u16(b:Bytes, p:Int):Float
	{
		return b.get(p) + b.get(p + 1) * 256.0;
	}

	static function u32(b:Bytes, p:Int):Float
	{
		return b.get(p) + b.get(p + 1) * 256.0 + b.get(p + 2) * 65536.0 + b.get(p + 3) * 16777216.0;
	}

	static function u64(b:Bytes, p:Int):Float
	{
		return u32(b, p) + u32(b, p + 4) * 4294967296.0;
	}

	static function hex8(v:Float):String
	{
		var s = "";
		var x = v;
		for (_ in 0...8)
		{
			var d = Std.int(x % 16);
			s = "0123456789abcdef".charAt(d) + s;
			x = Math.ffloor(x / 16);
		}
		return s;
	}

	static function fnvStep(h:Float, byte:Int):Float
	{
		// xor only touches the low byte
		var lo = h % 256.0;
		h = (h - lo) + ((Std.int(lo) ^ byte) & 0xFF);
		// h * 16777619 mod 2^32, in 16-bit halves: a straight Float multiply
		// would exceed 2^53 and silently lose bits.
		var hi = Math.ffloor(h / 65536.0);
		var low = h - hi * 65536.0;
		var a = (low * 16777619.0) % 4294967296.0;
		var b = ((hi * 16777619.0) % 65536.0) * 65536.0;
		return (a + b) % 4294967296.0;
	}

	static function fnvBytes(b:Bytes, h:Float):Float
	{
		for (i in 0...b.length) h = fnvStep(h, b.get(i));
		return h;
	}

	static function headTail(path:String):Bytes
	{
		var total = Std.int(size(path));
		var f = File.read(path, true);
		var out:Bytes;
		try
		{
			var head = f.read(Std.int(Math.min(total, 65536)));
			if (total > 131072)
			{
				seekTo(f, total - 65536);
				var tail = f.read(65536);
				var all = Bytes.alloc(head.length + tail.length);
				all.blit(0, head, 0, head.length);
				all.blit(head.length, tail, 0, tail.length);
				out = all;
			}
			else
			{
				out = head;
			}
		}
		catch (e:Dynamic)
		{
			out = Bytes.alloc(0);
		}
		f.close();
		return out;
	}

	static function fpFile(path:String):String
	{
		try
		{
			var h = fnvBytes(headTail(path), 2166136261.0);
			return Std.int(size(path)) + "B#" + hex8(h);
		}
		catch (e:Dynamic) return "";
	}

	static function fpWhole(path:String):String
	{
		try
		{
			var s = size(path);
			if (s > 4194304) return "";
			var f = File.read(path, true);
			var b = f.read(Std.int(s));
			f.close();
			return Std.int(s) + "B#" + hex8(fnvBytes(b, 2166136261.0));
		}
		catch (e:Dynamic) return "";
	}

	/** (hasDwarf, hasSymtab, textSize) for an ELF, or null. */
	static function elfInfo(path:String):{dbg:Float, sym:Float, text:Float}
	{
		var f = null;
		var result:{dbg:Float, sym:Float, text:Float} = null;
		try
		{
			f = File.read(path, true);
			var hdr = f.read(64);
			if (hdr.length < 64) throw "short header";
			if (hdr.get(0) != 0x7F || hdr.get(1) != 0x45 || hdr.get(2) != 0x4C
				|| hdr.get(3) != 0x46) return null;
			var is64 = hdr.get(4) == 2;
			var shoff = is64 ? u64(hdr, 0x28) : u32(hdr, 0x20);
			var shent = is64 ? u16(hdr, 0x3A) : u16(hdr, 0x2E);
			var shnum = is64 ? u16(hdr, 0x3C) : u16(hdr, 0x30);
			var shstr = is64 ? u16(hdr, 0x3E) : u16(hdr, 0x32);
			if (shoff == 0 || shnum == 0 || shent < 40 || shstr >= shnum)
			{
				result = { dbg: 0, sym: 0, text: 0 };
				throw "no section table";
			}

			seekTo(f, Std.int(shoff + shstr * shent));
			var sh = f.read(Std.int(shent));
			var stroff = is64 ? u64(sh, 0x18) : u32(sh, 0x10);
			var strsize = is64 ? u64(sh, 0x20) : u32(sh, 0x14);
			seekTo(f, Std.int(stroff));
			var strtab = f.read(Std.int(Math.min(strsize, 1048576)));

			var dbg = 0.0, sym = 0.0, text = 0.0;
			for (i in 0...Std.int(shnum))
			{
				seekTo(f, Std.int(shoff + i * shent));
				var s = f.read(Std.int(shent));
				if (s.length < shent) break;
				var n = Std.int(u32(s, 0));
				var sz = is64 ? u64(s, 0x20) : u32(s, 0x14);
				var name = "";
				if (n >= 0 && n < strtab.length)
				{
					var end = n;
					while (end < strtab.length && strtab.get(end) != 0) end++;
					name = strtab.getString(n, end - n);
				}
				if (StringTools.startsWith(name, ".debug")) dbg += sz;
				else if (name == ".symtab") sym = sz;
				else if (name == ".text") text = sz;
			}
			result = { dbg: dbg, sym: sym, text: text };
		}
		catch (e:Dynamic)
		{
			// unreadable table: report it as unknown rather than guessing
			result = { dbg: 0, sym: 0, text: -1 };
		}
		if (f != null) try f.close() catch (e:Dynamic) {};
		return result;
	}

	static function human(n:Float):String
	{
		if (n >= 1073741824.0) return Math.round(n / 10737418.24) / 100 + " GB";
		if (n >= 1048576.0) return Math.round(n / 10485.76) / 100 + " MB";
		if (n >= 1024.0) return Math.round(n / 10.24) / 100 + " KB";
		return Std.int(n) + " B";
	}

	/** role, kind, detail, usable (true / "partial" / false). */
	static function describe(path:String):{kind:String, detail:String, usable:Dynamic}
	{
		var lower = path.toLowerCase();
		var magic = openMagic(path);
		if (magic == "\x7fELF")
		{
			var e = elfInfo(path);
			if (e == null) return { kind: "ELF", detail: "header unreadable", usable: false };
			if (e.text < 0) return { kind: "ELF", detail: "section table unreadable", usable: false };
			if (e.dbg > 0) return { kind: "ELF", detail: "DWARF " + human(e.dbg) + " -> addr2line/ndk-stack give file:line", usable: true };
			if (e.sym > 0) return { kind: "ELF", detail: "symtab " + human(e.sym) + ", no DWARF -> function names only", usable: "partial" };
			return { kind: "ELF", detail: "STRIPPED (no .symtab, no .debug_*)", usable: false };
		}
		if (StringTools.endsWith(lower, ".js.map")) return { kind: "JSMAP", detail: "JS source map", usable: true };
		if (StringTools.endsWith(lower, ".map")) return { kind: "MAP", detail: "MSVC map (symbol -> RVA)", usable: true };
		if (StringTools.endsWith(lower, ".pdb")) return { kind: "PDB", detail: "MSVC debug info (no line table)", usable: "partial" };
		if (StringTools.endsWith(lower, ".bin"))
		{
			return { kind: "LINEMAP", detail: "SELM address -> file:line table", usable: true };
		}
		if (StringTools.endsWith(lower, ".apk")) return { kind: "APK", detail: "shipped package", usable: false };
		if (StringTools.endsWith(lower, ".exe")) return { kind: "PE", detail: "shipped executable", usable: false };
		return { kind: "FILE", detail: "", usable: null };
	}

	static function openMagic(path:String):String
	{
		var f = null;
		var s = "";
		try
		{
			f = File.read(path, true);
			var b = f.read(4);
			for (i in 0...b.length) s += String.fromCharCode(b.get(i));
		}
		catch (e:Dynamic) {}
		if (f != null) try f.close() catch (e:Dynamic) {};
		return s;
	}

	// ------------------------------------------------------------- collecting
	static function addRow(rows:Array<Row>, role:String, path:String, fp:String = null):Void
	{
		if (!isFile(path)) return;
		var d = describe(path);
		var f = fp;
		if (f == null && d.usable != false && !StringTools.endsWith(path.toLowerCase(), ".apk"))
			f = fpFile(path);
		rows.push({ role: role, path: path, kind: d.kind, detail: d.detail, fp: f == null ? "" : f });
	}

	static function collect(outDir:String):Array<Row>
	{
		var rows:Array<Row> = [];
		var obj = outDir + "/obj";
		var bin = outDir + "/bin";
		var app = appName();

		if (plat == "windows")
		{
			buildTime = Math.max(mtime(obj + "/ApplicationMain.exe"), mtime(bin + "/" + app + ".exe"));
			var maps = glob(obj, ".map");
			for (p in maps) take(rows, "map", p, true);
			if (maps.length == 0)
			{
				// hxcpp skipped the link, so no new map: the bundle still holds the one
				// that belongs to the exe that is still sitting in bin/.
				var prev = symbolDir() + "/ApplicationMain.map";
				if (isFile(prev)) addRow(rows, "map", prev);
			}
			for (p in glob(obj, ".pdb")) addRow(rows, "pdb", p);
			addRow(rows, "exe", obj + "/ApplicationMain.exe");
			addRow(rows, "exe", bin + "/" + app + ".exe");
		}
		else if (plat == "android")
		{
			var shipped = [];
			for (p in glob(obj, ".so"))
			{
				if (lastSegment(p) == "libApplicationMain.so") continue;
				shipped.push(p);
				buildTime = Math.max(buildTime, mtime(p));
			}
			// debug builds never strip, so the deployment .so can itself be the symbol
			// source; call it "symbols" whenever it actually carries DWARF.
			// Fingerprint every shipped .so: that size#hash IS the "so=" field of a crash
			// report's Build: line, so without it a report cannot be tied to a build at all
			// (obj\libApplicationMain-*.so is lime's copy, the APK carries Gradle's re-strip).
			for (p in shipped) addRow(rows, describe(p).usable == true ? "symbols" : "shipped", p, fpFile(p));
			// hxcpp's unstripped copy (HXCPP_DEBUG_LINK_AND_STRIP) is a pure byproduct.
			take(rows, "symbols", obj + "/libApplicationMain.so", true);
			// leftovers from an older hxcpp layout: obj/obj/<target>/libApplicationMain.so
			var oldDir = obj + "/obj";
			if (FileSystem.exists(oldDir) && FileSystem.isDirectory(oldDir))
			{
				var subs = [];
				try subs = FileSystem.readDirectory(oldDir) catch (e:Dynamic) {};
				for (s in subs) take(rows, "symbols", oldDir + "/" + s + "/libApplicationMain.so", true);
			}
			for (abi in ANDROID_ABIS)
			{
				var p = root + "/assets/linemap/" + abi + ".bin";
				addRow(rows, "linemap", p, fpWhole(p));
				// A bare "lime build" can only embed the PREVIOUS table: Project.xml's asset list
				// is read before this build's .so exists. Say so rather than shipping blind.
				if (isFile(p) && buildTime > 0 && mtime(p) < buildTime)
					note("embedded linemap " + abi + " predates the .so just linked (expected for a bare "
						+ "lime build). NativeCrash reads <storage>/linemap/" + abi + ".bin FIRST and "
						+ "tools\\refresh_linemap.ps1 keeps that copy in sync; run "
						+ "tools\\build_android_symbols.ps1 to embed a matching table in the APK itself.");
			}
			
			// Keep the DISK copy - which NativeCrash.loadLinemap() reads BEFORE the embedded
			// asset - in sync with the binary just linked, so one plain "haxelib run lime build
			// android" already yields reports that resolve to file:line, with no second build.
			// Best effort: the hook traps its own errors and can never fail a build.
			if (Sys.getEnv("SEIUN_LINEMAP_PIPELINE") == null)
			{
				try
				{
					var refresh = root + "/tools/refresh_linemap.ps1";
					if (isFile(refresh)) Sys.command("pwsh", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", refresh, mode]);
				}
				catch (e:Dynamic) {}
			}
			var apkDir = bin + "/app/build/outputs/apk";
			for (p in apkCandidates(apkDir)) addRow(rows, "apk", p);
			if (!hasRole(rows, "symbols"))
			{
				note("this build left NO symbol-bearing artifact: a gcc release link strips the "
					+ "shipped .so and hxcpp writes no .map outside MSVC");
				note("fix: <haxedef name=\"HXCPP_DEBUG_LINK_AND_STRIP\" if=\"android\" unless=\"debug\"/> "
					+ "makes hxcpp save obj/libApplicationMain.so before stripping the shipped one");
			}
			else if (hasRole(rows, "shipped"))
			{
				note("hxcpp names the unstripped copy after the target, not the ABI, so a multi-ABI "
					+ "build keeps symbols for the last ABI linked; build one ABI (-arm64 / -v7) when "
					+ "you need to resolve a release report");
			}
		}
		else if (plat == "linux")
		{
			buildTime = mtime(obj + "/ApplicationMain");
			addRow(rows, "binary", obj + "/ApplicationMain");
			addRow(rows, "binary", bin + "/" + app);
		}
		else if (plat == "html5")
		{
			buildTime = mtime(bin + "/" + app + ".js");
			for (p in glob(bin, ".js.map")) addRow(rows, "js.map", p);
			addRow(rows, "js", bin + "/" + app + ".js");
		}
		else if (plat == "neko")
		{
			for (p in glob(bin, ".n")) addRow(rows, "neko", p);
		}
		else
		{
			note("no symbol artifact is produced by lime for " + plat
				+ "; Apple targets put theirs in the dSYM the Xcode archive step writes");
		}

		return rows;
	}

	/**
	 * Move (never copy) a link byproduct into the symbol directory. Anything older
	 * than this build goes to _stale/ instead: it describes different code.
	 */
	static function take(rows:Array<Row>, role:String, path:String, movable:Bool):Void
	{
		if (!isFile(path)) return;
		var fresh = buildTime == 0 || mtime(path) >= buildTime - FRESH_SLACK;
		var d = describe(path);

		if (!fresh)
		{
			// Leave it exactly where it is. A restored compile cache or an incremental
			// build can make an older file the only copy a downstream tool has, and the
			// bundle must never accept a file that describes different code.
			note("stale: " + rel(path) + " is older than the binary just linked - a symbol "
				+ "file from another build resolves offsets to plausible, wrong symbols");
			rows.push({
				role: "stale",
				path: path,
				kind: d.kind,
				detail: d.detail,
				fp: (d.usable != false) ? fpFile(path) : ""
			});
			return;
		}

		var dest = symbolDir() + "/" + destName(path);
		var moved = movable && !dryRun ? moveFile(path, dest) : false;
		rows.push({
			role: role,
			path: moved ? dest : path,
			kind: d.kind,
			detail: d.detail,
			fp: (d.usable != false) ? fpFile(moved ? dest : path) : ""
		});
	}

	static function hasRole(rows:Array<Row>, role:String):Bool
	{
		for (r in rows) if (r.role == role) return true;
		return false;
	}

	static function note(s:String):Void
	{
		info.push(s);
	}

	/**
	 * hxcpp names every unstripped copy "libApplicationMain.so" whether it lands in
	 * obj/ or in a per-target dir, so two ABIs would collide in one bundle. Keep the
	 * ABI in the name when the source directory knows it (obj/obj/android-64/...).
	 */
	static function destName(path:String):String
	{
		var base = lastSegment(path);
		var q = path.split("\\").join("/");
		var i = q.lastIndexOf("/obj/obj/");
		if (i < 0) return base;
		var rest = q.substr(i + 9);
		var seg = rest.substr(0, rest.indexOf("/"));
		var abi = StringTools.contains(seg, "v7") ? "armeabi-v7a" : (StringTools.contains(seg, "64") ? "arm64-v8a" : seg);
		if (StringTools.endsWith(base, ".so")) return base.substr(0, base.length - 3) + "-" + abi + ".so";
		return base + "-" + abi;
	}

	static function lastSegment(p:String):String
	{
		var q = p.split("\\").join("/");
		return q.substr(q.lastIndexOf("/") + 1);
	}

	static function apkCandidates(dir:String):Array<String>
	{
		var out = [];
		if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir)) return out;
		for (d1 in FileSystem.readDirectory(dir))
		{
			var p1 = dir + "/" + d1;
			if (!FileSystem.isDirectory(p1)) continue;
			for (d2 in files(p1)) if (StringTools.endsWith(d2.toLowerCase(), ".apk")) out.push(d2);
			for (d2 in FileSystem.readDirectory(p1))
			{
				var p2 = p1 + "/" + d2;
				if (!FileSystem.isDirectory(p2)) continue;
				for (f in files(p2)) if (StringTools.endsWith(f.toLowerCase(), ".apk")) out.push(f);
			}
		}
		return out;
	}

	static function symbolDir():String
	{
		return root + "/export/symbols/" + plat + "-" + mode;
	}

	static function appName():String
	{
		try
		{
			var xml = File.getContent(root + "/Project.xml");
			var i = xml.indexOf("<app");
			if (i < 0) return "SeiunEngine";
			var end = xml.indexOf(">", i);
			var head = xml.substring(i, end < 0 ? xml.length : end);
			var k = head.indexOf("file=\"");
			if (k < 0) return "SeiunEngine";
			var rest = head.substr(k + 6);
			var e = rest.indexOf("\"");
			return e < 0 ? "SeiunEngine" : rest.substr(0, e);
		}
		catch (e:Dynamic) return "SeiunEngine";
	}

	static function moveFile(from:String, to:String):Bool
	{
		try
		{
			var dir = parentOf(to);
			if (!FileSystem.exists(dir)) FileSystem.createDirectory(dir);
			if (isFile(to) || FileSystem.exists(to)) FileSystem.deleteFile(to);
			FileSystem.rename(from, to);
			return true;
		}
		catch (e:Dynamic)
		{
			// Same volume is the normal case; a copy fallback is only sane for small files.
			if (size(from) > 67108864.0) return false;
			try
			{
				File.saveBytes(to, File.getBytes(from));
				FileSystem.deleteFile(from);
				return true;
			}
			catch (e2:Dynamic) return false;
		}
	}

	// ---------------------------------------------------------------- output
	static function emit(rows:Array<Row>):Void
	{
		Sys.println(TAG + " " + dashes());
		Sys.println(TAG + " " + plat + " " + mode + " - symbols for exactly this build");
		if (rows.length == 0) Sys.println(TAG + "   (nothing found under export/" + mode + "/" + plat + ")");
		for (r in rows)
		{
			Sys.println(TAG + "   " + pad(r.role, 9) + rel(r.path));
			var tail = [r.kind, r.detail, r.fp].filter(function(s) return s != null && s != "").join(" ");
			if (tail != "") Sys.println(TAG + "   " + pad("", 9) + "  " + tail);
		}
		for (s in info) Sys.println(TAG + "   note: " + s);
		if (plat == "android") Sys.println(TAG + "   resolve: ndk-stack -sym export/" + mode + "/android/obj -dump <report.txt>");
		if (plat == "windows") Sys.println(TAG + "   resolve: python tools/crash_triage.py --crash <report.txt>");
		Sys.println(TAG + " " + dashes());
	}

	static function dashes():String
	{
		var s = "";
		for (_ in 0...68) s += "-";
		return s;
	}

	static function pad(s:String, n:Int):String
	{
		var out = s;
		while (out.length < n) out += " ";
		return out;
	}

	static function writeInfo(rows:Array<Row>):Void
	{
		var dir = symbolDir();
		if (!FileSystem.exists(dir)) FileSystem.createDirectory(dir);
		var b = new StringBuf();
		b.add("# SeiunEngine symbol bundle - " + plat + " " + mode + "\n");
		b.add("# Written by tools/SymbolsAfterBuild.hx on every lime build.\n");
		b.add("# Match a crash report's 'Build:' line against the fingerprints below.\n");
		b.add("# size and #hash are stable; @mtime is the install time on the\n");
		b.add("# reporting device and WILL differ.\n\n");
		for (r in rows)
		{
			b.add(pad(r.role, 9) + r.path + "\n");
			var tail = [r.kind, r.detail, r.fp].filter(function(s) return s != null && s != "").join(" ");
			if (tail != "") b.add("            " + tail + "\n");
		}
		for (s in info) b.add("note: " + s + "\n");
		var p = dir + "/build-info.txt";
		File.saveContent(p, b.toString());
		Sys.println(TAG + "   info: " + rel(p));
	}
}
