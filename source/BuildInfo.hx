package;

/**
 * Build identity shared by the cold-start notice, the on-screen watermark and anything
 * else that has to name the revision that is actually running.
 *
 * None of the values below are maintained by hand. BuildStampMacro asks git and
 * Project.xml at compile time and inlines the answers, so every compile - from lime, an
 * IDE, or a bare haxe command - stamps itself. There is no generated file to forget to
 * regenerate, and compiling no longer dirties the working tree.
 *
 * If the source has no .git (release archive, CI checkout without history) the version
 * still comes from Project.xml and the commit degrades to "unknown"; CI can override the
 * lot with -D seiun_build_commit / _version / _dirty / _branch.
 *
 * The runtime binary fingerprint (NativeCrash's fnv1a over the first/last 64 KB) is
 * deliberately NOT used as a fallback here: it does not change for every source change
 * (see ONLINE_PORT_HANDOFF 127.11), so it cannot identify a build.
 *
 * isTestBuild() is the single place the "is this a test build?" question is answered, so
 * the notice, the watermark and anything later stay in sync without a new lime define
 * (Project.xml's defines are frozen).
 */
class BuildInfo
{
	/** Short git hash of the commit this binary was compiled from. */
	public static inline var COMMIT:String = BuildStampMacro.commit();
	/** Version read from Project.xml at compile time (runtime metadata still wins). */
	public static inline var VERSION:String = BuildStampMacro.version();
	/** True when tracked files differed from HEAD at compile time. */
	public static inline var DIRTY:Bool = BuildStampMacro.dirty();
	/** Branch the build came from ("HEAD" when detached, "unknown" without git). */
	public static inline var BRANCH:String = BuildStampMacro.branch();
	/** Committer date of that commit, ISO 8601, or "" without git. */
	public static inline var COMMIT_DATE:String = BuildStampMacro.commitDate();
	/** Local time at which the compiler asked for the stamp. */
	public static inline var BUILD_DATE:String = BuildStampMacro.buildDate();

	/** Version of the running build: application metadata first, generated constant as fallback. */
	public static function appVersion():String
	{
		try
		{
			var app = lime.app.Application.current;
			var meta = app != null ? app.meta : null;
			if (meta != null)
			{
				var value:Dynamic = meta.get('version');
				if (value != null && Std.string(value).length > 0)
					return Std.string(value);
			}
		}
		catch (e:Dynamic) {}

		return (VERSION != null && VERSION.length > 0 && VERSION != 'unknown') ? VERSION : 'unknown';
	}

	/** Short build identifier shown next to the version; '+' marks a dirty tree. */
	public static function buildId():String
	{
		if (COMMIT == null || COMMIT.length == 0 || COMMIT == 'unknown')
			return 'unknown';
		return DIRTY ? COMMIT + '+' : COMMIT;
	}

	/** Branch name, or "" when there is nothing useful to show (detached/unknown/main line). */
	public static function branchLabel():String
	{
		if (BRANCH == null || BRANCH.length == 0) return '';
		if (BRANCH == 'unknown' || BRANCH == 'HEAD') return '';
		if (BRANCH == 'main' || BRANCH == 'master') return '';
		// The watermark is drawn with a fallback font that has no CJK glyphs, so a branch
		// name that is not plain ASCII is worse than no branch at all.
		if (!~/^[A-Za-z0-9._\/-]+$/.match(BRANCH)) return '';
		return BRANCH;
	}

	/**
	 * True for development builds: the version string carries "pre" or "beta".
	 * Current version (0.2.2preonline3) hits this, so the test-build paragraph shows.
	 */
	public static function isTestBuild():Bool
	{
		var v:String = appVersion().toLowerCase();
		return v.indexOf('pre') >= 0 || v.indexOf('beta') >= 0;
	}

	/** One-line identity for the watermark: ASCII only, e.g. "v0.2.2preonline3 | e618301+". */
	public static function watermarkText():String
	{
		var id:String = buildId();
		var branch:String = branchLabel();
		if (branch.length > 0) id += ' @ ' + branch;
		return 'v' + appVersion() + ' | ' + id;
	}

	/**
	 * Full identity for diagnostics: version, commit, branch and both dates.
	 * Used by SystemDiag so a support report names the exact source state.
	 */
	public static function describe():String
	{
		var parts:Array<String> = ['v' + appVersion(), buildId()];
		var branch:String = branchLabel();
		if (branch.length > 0) parts.push('branch ' + branch);
		if (COMMIT_DATE != null && COMMIT_DATE.length > 0) parts.push('commit ' + COMMIT_DATE);
		if (BUILD_DATE != null && BUILD_DATE.length > 0) parts.push('built ' + BUILD_DATE);
		return parts.join(' | ');
	}
}
