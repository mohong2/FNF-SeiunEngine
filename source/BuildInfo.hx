package;

/**
 * Build identity shared by the cold-start notice and the on-screen watermark.
 *
 * The version comes from the running application metadata (lime fills it from Project.xml
 * and the packaged manifest for every build). The commit hash is baked into COMMIT by
 * tools/gen_buildinfo.py right before a release build; the committed default keeps it at
 * "unknown" so a bare lime build still compiles and the watermark degrades to
 * "v<version> | unknown" instead of lying about which revision is running.
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
	/** Short git hash injected at build time by tools/gen_buildinfo.py. */
	public static inline var COMMIT:String = "unknown";
	/** Version read from Project.xml by tools/gen_buildinfo.py (runtime metadata wins). */
	public static inline var VERSION:String = "0.2.2preonline2";
	/** True when the tree had uncommitted changes at build time. */
	public static inline var DIRTY:Bool = false;

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

		return (VERSION != null && VERSION.length > 0) ? VERSION : 'unknown';
	}

	/** Short build identifier shown next to the version; '+' marks a dirty tree. */
	public static function buildId():String
	{
		if (COMMIT == null || COMMIT.length == 0 || COMMIT == 'unknown')
			return 'unknown';
		return DIRTY ? COMMIT + '+' : COMMIT;
	}

	/**
	 * True for development builds: the version string carries "pre" or "beta".
	 * Current version (0.2.2preonline2) hits this, so the test-build paragraph shows.
	 */
	public static function isTestBuild():Bool
	{
		var v:String = appVersion().toLowerCase();
		return v.indexOf('pre') >= 0 || v.indexOf('beta') >= 0;
	}

	/** One-line identity for the watermark: ASCII only, e.g. "v0.2.2preonline2 | 24182dc". */
	public static function watermarkText():String
	{
		return 'v' + appVersion() + ' | ' + buildId();
	}
}
