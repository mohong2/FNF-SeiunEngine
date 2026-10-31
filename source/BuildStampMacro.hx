package;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;
#end

/**
 * Compile-time revision stamp for SeiunEngine.
 *
 * The old pipeline was a <prebuild> that rewrote three literals in source/BuildInfo.hx.
 * That made the checked-in file a generated artifact: it was stale whenever someone
 * built without the lime hook, every build dirtied the tree, and the only way to know
 * the real revision was to trust that a script had run. This macro removes the middle
 * man - Haxe asks git the same question while it is compiling, and inlines the answer.
 *
 * Consequences:
 *   * a plain `lime build` (or any IDE/Haxe invocation) stamps itself, no hook;
 *   * no source file is modified, so the tree stays clean and the stamp can never be
 *     one revision behind because a prebuild was skipped;
 *   * a source archive without .git still gets the Project.xml version, and CI can
 *     supply the rest with -D seiun_build_commit / _version / _dirty / _branch.
 *
 * The values are read once per compilation and cached, so the six public macro calls
 * below cost one `git status` (the expensive one), not six.
 *
 * BuildInfo is the only consumer. tools/SymbolsAfterBuild.hx reads the same facts from
 * git after linking; this class deliberately lives under source/ so the game build can
 * use it without adding tools/ to the Haxe classpath.
 */
#if macro
typedef BuildStamp = {
	var commit:String;
	var version:String;
	var dirty:Bool;
	var branch:String;
	var date:String;
	var built:String;
}
#end

class BuildStampMacro
{
	/** Short hash of HEAD, or "unknown" when git is unavailable. */
	public static macro function commit():Expr
	{
		return macro $v{read().commit};
	}

	/** <app version="..."> from Project.xml at compile time. */
	public static macro function version():Expr
	{
		return macro $v{read().version};
	}

	/** True when tracked files differ from HEAD. */
	public static macro function dirty():Expr
	{
		return macro $v{read().dirty};
	}

	/** Current branch ("HEAD" when detached), or "unknown". */
	public static macro function branch():Expr
	{
		return macro $v{read().branch};
	}

	/** Committer date of HEAD (ISO 8601), or "" when git is unavailable. */
	public static macro function commitDate():Expr
	{
		return macro $v{read().date};
	}

	/** Local wall-clock time at which this compilation started. */
	public static macro function buildDate():Expr
	{
		return macro $v{read().built};
	}

	#if macro
	static var cached:BuildStamp = null;

	static function read():BuildStamp
	{
		if (cached != null) return cached;

		var root:String = findRoot(Sys.getCwd());
		var commit:String = defined("seiun_build_commit");
		if (commit == "")
		{
			commit = git(root, ["rev-parse", "--short", "HEAD"]);
			if (commit == "") commit = "unknown";
		}

		var version:String = defined("seiun_build_version");
		if (version == "") version = projectVersion(root);
		if (version == "") version = "unknown";

		var branch:String = defined("seiun_build_branch");
		if (branch == "")
		{
			branch = git(root, ["rev-parse", "--abbrev-ref", "HEAD"]);
			if (branch == "") branch = "unknown";
		}

		var dirty:Bool;
		var dirtyDefine:String = defined("seiun_build_dirty").toLowerCase();
		if (dirtyDefine == "1" || dirtyDefine == "true" || dirtyDefine == "yes")
			dirty = true;
		else if (dirtyDefine == "0" || dirtyDefine == "false" || dirtyDefine == "no")
			dirty = false;
		else
			// --untracked-files=no: untracked scratch files are not part of the build
			// identity, and "git describe --dirty" ignores them too. Tracked edits are.
			dirty = git(root, ["status", "--porcelain", "--untracked-files=no"]).length > 0;

		var date:String = git(root, ["log", "-1", "--format=%cI"]);

		cached = {
			commit: commit,
			version: version,
			dirty: dirty,
			branch: branch,
			date: date,
			built: Date.now().toString()
		};
		return cached;
	}

	/** -D overrides let CI stamp a release built from an archive without .git. */
	static function defined(name:String):String
	{
		var value:String = Context.definedValue(name);
		return value == null ? "" : StringTools.trim(value);
	}

	/** Walk up from the compile directory until Project.xml is found. */
	static function findRoot(start:String):String
	{
		var dir:String = start;
		for (_ in 0...10)
		{
			if (FileSystem.exists(dir + "/Project.xml")) return dir;
			var parent:String = haxe.io.Path.directory(dir);
			if (parent == null || parent == "" || parent == dir) break;
			dir = parent;
		}
		return start;
	}

	/** <app ... version="..."> out of Project.xml, or "" when it cannot be read. */
	static function projectVersion(root:String):String
	{
		try
		{
			var xml:String = File.getContent(root + "/Project.xml");
			var re:EReg = ~/<app\b[^>]*\bversion="([^"]*)"/;
			if (re.match(xml)) return re.matched(1);
		}
		catch (e:Dynamic) {}
		return "";
	}

	/** stdout of a git subcommand, or "" when git is missing or the command fails. */
	static function git(root:String, args:Array<String>):String
	{
		try
		{
			var process:Process = new Process("git", ["-C", root].concat(args));
			var out:String = process.stdout.readAll().toString();
			// Drain stderr too: a full pipe would block git on Windows.
			process.stderr.readAll();
			var code:Int = process.exitCode();
			process.close();
			if (code != 0) return "";
			return StringTools.trim(out.split("\r").join(""));
		}
		catch (e:Dynamic) return "";
	}
	#end
}
