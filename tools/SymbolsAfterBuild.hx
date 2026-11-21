package tools;

import haxe.io.Bytes;
import sys.FileSystem;
import sys.io.File;
import sys.io.FileSeek;
import sys.io.Process;

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
 *   5. write build-info.txt + build.json there, plus the toolchain fingerprint
 *      tools/toolchain.py recorded for this machine (when it ran).
 *
 * That directory is what CI uploads as the target's *-symbols artifact, and
 * "python tools/crash.py package" folds every one of them into the single
 * SeiunEngine-symbols-<version>.zip a release ships.
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

	/** Revision the compile-time BuildStampMacro baked into the binary (re-read from git here). */
	static var STAMP = {commit: "unknown", version: "unknown", dirty: false};
	static var plat:String;
	static var mode:String;
	static var buildTime:Float = 0;
	static var info:Array<String> = [];
	static var argPlat:String = null;
	static var argMode:String = null;
	static var dryRun:Bool = false;

	/** Written by tools/toolchain.py before the compile; null when nothing described the compiler. */
	static var toolchainJson:String = null;
	static var toolchainLine:String = null;

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
		readStamp(root);
		readToolchain(root);

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
		writeManifest(rows);
	}

	// -------------------------------------------------------------- locating
	/**
	 * The same facts source/BuildStampMacro.hx bakes into the binary: HEAD, Project.xml's
	 * version, and whether tracked files differ. Read from git here instead of scraping
	 * BuildInfo.hx, because that file now contains macro calls rather than literals.
	 */
	static function readStamp(projectRoot:String):Void
	{
		var commit:String = git(projectRoot, ["rev-parse", "--short", "HEAD"]);
		STAMP.commit = commit == "" ? "unknown" : commit;

		var version:String = projectVersion(projectRoot);
		STAMP.version = version == "" ? "unknown" : version;

		// --untracked-files=no matches BuildStampMacro: scratch files are not build identity.
		STAMP.dirty = git(projectRoot, ["status", "--porcelain", "--untracked-files=no"]).length > 0;
	}

	/**
	 * The compiler, copied from what tools/toolchain.py left in the project root.
	 *
	 * The runner image is not in this repository, so a bundle that only says which
	 * commit it describes cannot answer "was this built by the same compiler as the
	 * release?" - and that difference is real: the CI image moved to MSVC 14.5x and
	 * lime's bundled openal stopped compiling, while the same tree kept building on
	 * a developer's machine with 14.4x. Absent on a build that never ran the script:
	 * the fields are then omitted, never guessed.
	 */
	static function readToolchain(projectRoot:String):Void
	{
		try
		{
			var j = projectRoot + "/toolchain.json";
			if (FileSystem.exists(j)) toolchainJson = File.getContent(j);
		}
		catch (e:Dynamic) {}

		try
		{
			var t = projectRoot + "/toolchain.txt";
			if (FileSystem.exists(t))
			{
				var line = StringTools.trim(File.getContent(t));
				if (line != "") toolchainLine = line;
			}
		}
		catch (e:Dynamic) {}
	}

	/** <app ... version="..."> out of Project.xml, or "" when it cannot be read. */
	static function projectVersion(projectRoot:String):String
	{
		try
		{
			var xml:String = File.getContent(projectRoot + "/Project.xml");
			var re:EReg = ~/<app\b[^>]*\bversion="([^"]*)"/;
			if (re.match(xml)) return re.matched(1);
		}
		catch (e:Dynamic) {}
		return "";
	}

	/** stdout of a git subcommand, or "" when git is missing or the call fails. */
	static function git(projectRoot:String, args:Array<String>):String
	{
		try
		{
			var process:Process = new Process("git", ["-C", projectRoot].concat(args));
			var out:String = process.stdout.readAll().toString();
			process.stderr.readAll();
			var code:Int = process.exitCode();
			process.close();
			if (code != 0) return "";
			return StringTools.trim(out.split("\r").join(""));
		}
		catch (e:Dynamic) return "";
	}

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

	/** True when the first four bytes are a Mach-O or fat Mach-O magic (0xCF.. / 0xCA..). */
	static function isMachO(path:String):Bool
	{
		var f = null;
		try
		{
			f = File.read(path, true);
			var b = f.read(4);
			if (b.length < 4) return false;
			var b0 = b.get(0), b1 = b.get(1), b2 = b.get(2), b3 = b.get(3);
			// Byte by byte on purpose: 0xCFFAEDFE as a single Int literal does not fit
			// a 32-bit Int, and a Haxe UTF-8 string cannot hold 0xCF at all.
			return (b0 == 0xCF && b1 == 0xFA && b2 == 0xED && b3 == 0xFE) // 64-bit, LE
				|| (b0 == 0xCE && b1 == 0xFA && b2 == 0xED && b3 == 0xFE) // 32-bit, LE
				|| (b0 == 0xFE && b1 == 0xED && b2 == 0xFA && b3 == 0xCF) // 64-bit, BE
				|| (b0 == 0xFE && b1 == 0xED && b2 == 0xFA && b3 == 0xCE) // 32-bit, BE
				|| (b0 == 0xCA && b1 == 0xFE && b2 == 0xBA && b3 == 0xBE) // fat, BE
				|| (b0 == 0xCA && b1 == 0xFE && b2 == 0xBA && b3 == 0xBF); // fat64, BE
		}
		catch (e:Dynamic) return false;
		if (f != null) try f.close() catch (e:Dynamic) {};
		return false;
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
		// Mach-O: the symbol table is in the file and tools/symtab.py reads it out.
		// Compared as bytes, not as a string literal: a Haxe UTF-8 string cannot hold
		// 0xCF, so string escapes for a binary magic are a coin flip per target.
		if (isMachO(path)) return { kind: "MACHO", detail: "Mach-O symbol table (tools/symtab.py turns it into .sym)", usable: true };
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
			// The address -> file:line table is optional and is NOT generated by a build:
			// Project.xml no longer embeds assets/linemap/*.bin, so a table only shows up
			// here when someone made one. Report it when it is stale - a table from another
			// link prints wrong file:line, which is worse than printing none.
			for (abi in ANDROID_ABIS)
			{
				var p = root + "/assets/linemap/" + abi + ".bin";
				addRow(rows, "linemap", p, fpWhole(p));
				if (isFile(p) && buildTime > 0 && mtime(p) < buildTime)
					note("assets/linemap/" + abi + ".bin predates the .so just linked - regenerate it "
						+ "with 'python tools\\crash.py linemap --android release --abi " + abi + "' and adb "
						+ "push it to <storage>/linemap/ before trusting any [file:line] in a report");
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
			var shipped = bin + "/" + app;
			buildTime = Math.max(mtime(obj + "/ApplicationMain"), mtime(shipped));
			addRow(rows, "binary", obj + "/ApplicationMain");
			// The link output IS the shipped binary here: linux-toolchain.xml only
			// sets HXCPP_STRIP for the cross toolchains, so a release link leaves
			// .symtab in place. That table is the only thing that can name a frame,
			// and build.json records this row so tools/symtab.py knows which file
			// to read without a second path hardcoded in CI.
			addRow(rows, "exe", shipped);
			note("a gcc release link writes no .map, and its stripper only removes debug sections "
				+ "('strip -d'), so the executable keeps its .symtab: 'python tools/symtab.py --platform linux "
				+ "--out export/symbols/linux-" + mode + "' turns it into SeiunEngine.sym (CI runs this on every build)");
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
		else if (plat == "macos")
		{
			// Same story as Linux: no .map, no dSYM, but the release stripper on
			// macOS is "strip -u -r -x" - "-x" drops local symbols only, so the
			// external ones stay in the .app executable's LC_SYMTAB. That is the
			// table a report's "pc <offset> <module>" resolves against.
			var exe = macExecutable(bin);
			buildTime = exe != null ? mtime(exe) : mtime(obj);
			if (exe != null)
			{
				addRow(rows, "app", exe);
				// The shipped .app is a poor symbol source: the build compiles with
				// -fvisibility=hidden and then strips local symbols, which leaves the
				// handful of explicitly exported names. The unstripped copy Project.xml
				// has hxcpp keep before stripping is the real table, and it holds the
				// exact same code - strip only removes sections, it never moves any.
				var full = obj + "/ApplicationMain.unstripped";
				if (isFile(full) && mtime(full) >= buildTime - FRESH_SLACK)
				{
					addRow(rows, "unstripped", full);
					note("tools/symtab.py reads " + rel(full) + " (the pre-strip link output) into "
						+ "SeiunEngine.sym: the shipped .app only keeps its exported symbols");
				}
				else
				{
					note("no fresh " + rel(full) + " - HXCPP_DEBUG_LINK_AND_STRIP/HAXE_FULL_UNSTRIPPED_NAME "
						+ "did not take effect, so a .sym made now could only name exported symbols");
				}
			}
			else
			{
				note("no executable under " + rel(bin) + "/*.app/Contents/MacOS - nothing to symbolize");
			}
		}
		else
		{
			note("no symbol artifact is produced by lime for " + plat
				+ " (a dSYM would need the Xcode archive step this pipeline does not run)");
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

	/** The Mach-O inside export/<mode>/macos/bin/<app>.app - the file that ships. */
	static function macExecutable(bin:String):String
	{
		var apps = [];
		try
		{
			for (name in FileSystem.readDirectory(bin))
			{
				var p = bin + "/" + name;
				if (StringTools.endsWith(name.toLowerCase(), ".app") && FileSystem.isDirectory(p)) apps.push(p);
			}
		}
		catch (e:Dynamic) {}
		for (appDir in apps)
		{
			var macos = appDir + "/Contents/MacOS";
			if (!FileSystem.exists(macos) || !FileSystem.isDirectory(macos)) continue;
			var found = files(macos);
			if (found.length > 0) return found[0];
		}
		return null;
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
			// A rename can be refused for a moment after the linker wrote the file: on
			// Windows an indexer, an antivirus scanner or the compiler's own telemetry
			// process (vctip.exe) can still hold a handle. That is what happened to a
			// 91 MB ApplicationMain.map once, and the fallback below then refused to copy
			// anything over 64 MB - so the map stayed in obj/ and the CI step that
			// publishes the bundle died with "ApplicationMain.map is missing".
			for (_ in 0...3)
			{
				try
				{
					FileSystem.rename(from, to);
					return true;
				}
				catch (e:Dynamic)
				{
					Sys.sleep(0.7);
					if (isFile(to) || FileSystem.exists(to)) FileSystem.deleteFile(to);
				}
			}
			// Copy instead of giving up: it is the same volume either way, and a copy
			// that works beats a rename that has to be explained in a CI log. There is
			// no size cap any more - an unstripped Android .so is several hundred MB and
			// a slow copy is still better than a symbol bundle that silently misses it.
			File.copy(from, to);
			try FileSystem.deleteFile(from)
			catch (e:Dynamic) note("left " + rel(from) + " in place (still locked) - the bundle has a copy");
			return true;
		}
		catch (e:Dynamic)
		{
			note("could not move " + rel(from) + " into the bundle (" + Std.string(e) + ")");
			return false;
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
		if (plat == "android") Sys.println(TAG + "   resolve: ndk-stack -sym export/symbols/android-" + mode + " -dump <report.txt>");
		Sys.println(TAG + "   build  : " + STAMP.commit + (STAMP.dirty ? " (dirty tree)" : "") + "  " + STAMP.version);
		if (plat == "linux" || plat == "macos")
			Sys.println(TAG + "   resolve: python tools/crash.py sym export/symbols/" + plat + "-" + mode + " 0x<offset>");
		if (toolchainLine != null) Sys.println(TAG + "   toolchain: " + toolchainLine);
		if (plat == "windows") Sys.println(TAG + "   check  : python tools\\crash.py status");
		if (plat == "windows") Sys.println(TAG + "   resolve: python tools\\crash.py report <report.txt>");
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
		b.add("# build   : " + STAMP.commit + (STAMP.dirty ? " (dirty tree)" : "") + "  " + STAMP.version + "\n");
		if (toolchainLine != null) b.add("# toolchain: " + toolchainLine + "\n");
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

	/**
	 * Machine-readable twin of build-info.txt.
	 *
	 * tools/crash.py reads this to answer "are these symbols from THIS binary?"
	 * without guessing from modification times: the PE TimeDateStamp + file size
	 * recorded here are the same two values a crash report prints
	 * (Build: <size>B@<stamp>s), so the comparison is exact.
	 */
	static function writeManifest(rows:Array<Row>):Void
	{
		var dir = symbolDir();
		if (!FileSystem.exists(dir)) FileSystem.createDirectory(dir);

		var exe:Row = null;
		for (r in rows)
		{
			if (r.role != "exe" && r.role != "app" && r.role != "apk") continue;
			var shipped = r.path.indexOf("/bin/") >= 0 || StringTools.endsWith(r.path.toLowerCase(), ".apk");
			if (exe == null || (shipped && exe.path.indexOf("/bin/") < 0)) exe = r;
		}

		var exeSize:Float = exe != null ? size(exe.path) : 0;
		var stamp:Float = (exe != null && plat == "windows") ? peStamp(exe.path) : -1;

		var b = new StringBuf();
		b.add("{\n");
		b.add("  \"schema\": 1,\n");
		b.add("  \"platform\": " + jstr(plat) + ",\n");
		b.add("  \"mode\": " + jstr(mode) + ",\n");
		b.add("  \"builtAt\": " + jstr(Date.now().toString()) + ",\n");
		b.add("  \"git\": {\"commit\": " + jstr(STAMP.commit) + ", \"dirty\": "
			+ (STAMP.dirty ? "true" : "false") + ", \"version\": " + jstr(STAMP.version) + "},\n");
		var toolchain:String = toolchainObject();
		if (toolchain != null) b.add("  \"toolchain\": " + toolchain + ",\n");
		if (exe == null)
		{
			b.add("  \"exe\": null,\n");
		}
		else
		{
			b.add("  \"exe\": {\n");
			b.add("    \"path\": " + jstr(rel(exe.path)) + ",\n");
			b.add("    \"size\": " + Std.int(exeSize) + ",\n");
			b.add("    \"peStamp\": " + (stamp < 0 ? "null" : Std.string(Std.int(stamp))) + ",\n");
			b.add("    \"peStampHex\": " + (stamp < 0 ? "null" : jstr("0x" + hex8(stamp))) + ",\n");
			b.add("    \"fp\": " + jstr(exe.fp) + "\n");
			b.add("  },\n");
		}
		b.add("  \"artifacts\": [");
		var first = true;
		for (r in rows)
		{
			if (!isFile(r.path)) continue;
			if (!first) b.add(",");
			first = false;
			b.add("\n    {\"role\": " + jstr(r.role) + ", \"path\": " + jstr(rel(r.path))
				+ ", \"size\": " + Std.int(size(r.path)) + ", \"fp\": " + jstr(r.fp) + "}");
		}
		b.add("\n  ],\n");
		b.add("  \"notes\": [");
		var nfirst = true;
		for (s in info)
		{
			if (!nfirst) b.add(", ");
			nfirst = false;
			b.add(jstr(s));
		}
		b.add("]\n}\n");
		var json = dir + "/build.json";
		File.saveContent(json, b.toString());
		Sys.println(TAG + " manifest: " + rel(json));
	}

	/** toolchain.json re-serialised onto one line, so it can sit inside the manifest. */
	static function toolchainObject():String
	{
		if (toolchainJson == null) return null;
		try
		{
			var parsed:Dynamic = haxe.Json.parse(toolchainJson);
			if (parsed == null) return null;
			return haxe.Json.stringify(parsed);
		}
		catch (e:Dynamic)
		{
			return null;
		}
	}

	static function jstr(s:String):String
	{
		return haxe.Json.stringify(s == null ? "" : s);
	}

	/** COFF TimeDateStamp of a PE image (the same value a report calls 'stamp'), or -1. */
	static function peStamp(path:String):Float
	{
		var f = null;
		try
		{
			f = File.read(path, true);
			var stamp:Float = -1;
			f.seek(0x3C, FileSeek.SeekBegin);
			var off = u32(f.read(4), 0);
			f.seek(Std.int(off), FileSeek.SeekBegin);
			var sig = f.read(4);
			if (sig.get(0) == 80 && sig.get(1) == 69)
			{
				f.seek(Std.int(off) + 8, FileSeek.SeekBegin);
				stamp = u32(f.read(4), 0);
			}
			f.close();
			return stamp;
		}
		catch (e:Dynamic)
		{
			if (f != null) try f.close() catch (_:Dynamic) {};
			return -1;
		}
	}
}
