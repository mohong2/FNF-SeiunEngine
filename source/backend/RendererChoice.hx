package backend;

#if sys
import sys.FileSystem;
import sys.io.File;
#end

/**
 * The renderer preference and the fallback bookkeeping that goes with it.
 *
 * Windows and Android are the only targets that carry a Vulkan backend (macOS/iOS have
 * no Vulkan driver, Linux is not offered yet), so this class owns every question the
 * settings menu asks about it:
 *
 *   - can this build/platform draw through Vulkan at all (available()),
 *   - may the settings menu offer it here (offered()),
 *   - which backend is this *session* really drawing through (active),
 *   - should the next launch try Vulkan (shouldStart()), and
 *   - did the last launch die while trying (recover()).
 *
 * "Can" and "may" are two questions on purpose. Android *can*: the backend is compiled
 * in, it takes the ANativeWindow over and it is fast. It may not *yet*: every mod and
 * OpenFL shader has to be translated from GLSL to SPIR-V at runtime, and that
 * translation has no implementation on device today, so anything that expects a custom
 * shader silently falls back to the built-in pipeline. That is a hole in the renderer,
 * not a choice to put in front of a player, so the picker stays hidden on Android
 * until it is fixed (target: the 0.2.2 release). Nobody who gets there anyway is
 * blocked - a saved preference, --vulkan, SEIUN_VULKAN or -D seiun_vulkan_force still
 * start the backend - and such a session keeps the picker, so there is a way back to
 * OpenGL from inside the game instead of a dead end.
 *
 * The fallback has two halves, and both have to exist or a broken driver becomes a
 * boot loop:
 *
 *   1. a *soft* failure - the runtime reports it and keeps OpenGL. Main.installVulkan()
 *      calls fellBack(), which writes 'OpenGL' into the saved preference so the next
 *      launch does not walk into the same wall.
 *   2. a *hard* failure - the process dies before it can report anything (a driver
 *      fault, an ANativeWindow that went away, an out-of-memory kill). No Haxe code
 *      runs in that case, so the only witness is a marker file: beginAttempt() writes
 *      it before the first Vulkan call and commitAttempt() deletes it once the renderer
 *      has proven it survives a few seconds of real frames. A marker that is still
 *      there on the next boot means "the last launch never got that far", and recover()
 *      puts the player back on OpenGL.
 *
 * The marker is deliberately a plain file under 'logs/' : it has to be readable before
 * the save file is bound, and it must not share a failure mode with the settings store.
**/
class RendererChoice
{
	static inline var TAG = '[renderer]';

	public static inline var OPENGL:String = 'OpenGL';
	public static inline var VULKAN:String = 'Vulkan';

	/** Written before the first Vulkan call, deleted once the backend proves itself. */
	static inline var ATTEMPT_MARKER:String = 'logs/vulkan-attempt.txt';

	/**
	 * Frames the backend has to present before an attempt counts as good.
	 *
	 * 300 frames is ~5 seconds at 60 FPS: long enough that a driver which faults while
	 * building its first swapchain, compiling pipelines or uploading the boot textures
	 * still lands in the "do not try that again" bucket, short enough that a slow phone
	 * does not spend a whole song marked as unproven.
	 */
	static inline var COMMIT_FRAMES:Int = 300;

	/** True when this session could not start Vulkan and stayed on OpenGL. */
	public static var fellBackThisBoot(default, null):Bool = false;

	/** True once Vulkan really took the session over (read by the settings menu). */
	public static var active(default, null):Bool = false;

	/** True when this launch *asked* for Vulkan (flag, environment or saved preference). */
	public static var attempted(default, null):Bool = false;

	/** Human-readable reason for the last fallback this process knows about. */
	public static var failureReason(default, null):String = null;

	/** True when the previous launch died while Vulkan was starting. */
	public static var recoveredFromCrash(default, null):Bool = false;

	/** True while this process has an uncommitted Vulkan attempt in flight. */
	public static var attemptPending(get, never):Bool;

	static inline function get_attemptPending():Bool
	{
		return attemptOpen;
	}

	/** Frames presented since the attempt started; commitAttempt() runs at COMMIT_FRAMES. */
	static var framesSinceAttempt:Int = 0;

	/** True while a marker written by this process is still on disk. */
	static var attemptOpen:Bool = false;

	// ======================================================================
	//  What this build and this platform can do
	// ======================================================================

	/**
	 * The targets that have a Vulkan backend wired up.
	 *
	 * This is about the backend, not about the menu: offered() is what the settings page
	 * reads, and it can say no on a target where this says yes. Every other target keeps
	 * the choice out of the menu instead of showing a card that can never be picked.
	**/
	public static var platformSupported(get, never):Bool;

	static inline function get_platformSupported():Bool
	{
		#if (windows || android)
		return true;
		#else
		return false;
		#end
	}

	/** True when the renderer was compiled into this build (-D seiun_vulkan). */
	public static var compiled(get, never):Bool;

	static inline function get_compiled():Bool
	{
		#if seiun_vulkan
		return true;
		#else
		return false;
		#end
	}

	/** True when this build on this platform can draw through Vulkan. */
	public static inline function available():Bool
	{
		return platformSupported && compiled;
	}

	/**
	 * Android can run Vulkan but does not offer it yet (see the class comment).
	 *
	 * The single switch between "hidden" and "offered" on Android: turn this on once the
	 * runtime GLSL -> SPIR-V conversion works on device. Nothing else has to change.
	 */
	static inline var ANDROID_OFFERED:Bool = false;

	/**
	 * True when the settings menu may show the renderer picker.
	 *
	 * False where the backend does not exist, and false on Android while it is not ready
	 * for players. A session that is already on Vulkan - the saved preference says so, or
	 * this launch was forced into it - still gets the row even there: it is the only way
	 * back to OpenGL from inside the game, and without it a forced Android session is a
	 * dead end.
	 */
	public static function offered():Bool
	{
		if (!available()) return false;

		#if android
		if (!ANDROID_OFFERED) return active || savedAsVulkan();
		#end

		return true;
	}

	/** True when the saved preference already asks for Vulkan. */
	static inline function savedAsVulkan():Bool
	{
		return ClientPrefs.data != null && ClientPrefs.data.renderer == VULKAN;
	}

	/**
	 * Whether a stored value may be kept.
	 *
	 * 'OpenGL' is always fine. 'Vulkan' is only kept on a build and platform that can
	 * actually honour it; anything else (a save written by a preview build, a mod going
	 * through Reflect) is clamped back to OpenGL by ClientPrefs.
	 */
	public static function accepts(value:String):Bool
	{
		if (value == null) return false;
		if (value == OPENGL) return true;
		return value == VULKAN && available();
	}

	// ======================================================================
	//  Should this launch try Vulkan?
	// ======================================================================

	/**
	 * True when the command line or the environment asks for a backend.
	 *
	 * --vulkan / --no-vulkan and SEIUN_VULKAN always win over the saved preference:
	 * they are the escape hatch for a machine whose save file is the thing that will
	 * not start.
	 */
	public static function forced():Null<Bool>
	{
		#if sys
		for (arg in Sys.args())
		{
			if (arg == '--no-vulkan') return false;
			if (arg == '--vulkan') return true;
		}

		var env:String = Sys.getEnv('SEIUN_VULKAN');
		if (env != null && env.length > 0)
		{
			var lower:String = env.toLowerCase();
			return env != '0' && lower != 'false' && lower != 'off';
		}
		#end
		return null;
	}

	/** True when Vulkan is what this launch should end up on. */
	public static function wanted():Bool
	{
		var forcedChoice:Null<Bool> = forced();
		if (forcedChoice != null) return forcedChoice;

		#if seiun_vulkan_force
		// Diagnostic build only (lime build ... -D seiun_vulkan_force): try the backend
		// regardless of the saved choice, so a device can be tested without scripting the
		// menu. Never set in a shipped build.
		return true;
		#else
		return ClientPrefs.data != null && ClientPrefs.data.renderer == VULKAN;
		#end
	}

	/** True when Main may start the backend now. */
	public static function shouldStart():Bool
	{
		if (!available()) return false;
		if (recoveredFromCrash) return false;
		if (active) return false;
		return wanted();
	}

	// ======================================================================
	//  The attempt marker
	// ======================================================================

	/**
	 * Records that this launch is about to hand the window to Vulkan.
	 *
	 * Must run before the first native call: from that point on the process can die
	 * without another Haxe line executing.
	 */
	public static function beginAttempt():Void
	{
		attempted = true;
		framesSinceAttempt = 0;
		attemptOpen = true;
		fellBackThisBoot = false;

		writeMarker('starting');
	}

	/**
	 * Counts a presented frame and retires the marker once the backend has survived long
	 * enough to be called working. Cheap enough to call every frame.
	 */
	public static function tick():Void
	{
		if (!attemptOpen) return;

		framesSinceAttempt++;
		if (framesSinceAttempt >= COMMIT_FRAMES) commitAttempt();
	}

	/** The backend works: the next launch is free to try it again. */
	public static function commitAttempt():Void
	{
		if (!attemptOpen) return;
		attemptOpen = false;
		deleteMarker();
		log('renderer survived ' + framesSinceAttempt + ' frames; attempt committed');
	}

	/** Marks the session as really drawing through Vulkan. */
	public static function markActive():Void
	{
		active = true;
		fellBackThisBoot = false;
	}

	/**
	 * The backend failed and OpenGL has the session back.
	 *
	 * @param reason  what the runtime reported, shown in the dialog and written to the log
	 * @param persist true when the failure happened before the attempt was committed, so
	 *                the saved preference must stop asking for Vulkan
	 */
	public static function fellBack(reason:String, persist:Bool):Void
	{
		active = false;
		fellBackThisBoot = true;
		failureReason = reason;

		log('falling back to OpenGL' + (persist ? ' (saved preference reset)' : '') + ': ' + reason);

		if (attemptOpen)
		{
			attemptOpen = false;
			deleteMarker();
		}

		if (persist && ClientPrefs.data != null && ClientPrefs.data.renderer != OPENGL)
		{
			ClientPrefs.data.renderer = OPENGL;
			if (ClientPrefs.prefsLoaded) ClientPrefs.saveSettings();
		}
	}

	/**
	 * Boot-time check for a launch that died while Vulkan was starting.
	 *
	 * Runs after the preferences are in memory and before anything decides to start the
	 * backend. A leftover marker means the previous launch never reached commitAttempt(),
	 * so this one starts on OpenGL no matter what the save file says - and the save file
	 * is corrected to match, which is what stops a driver fault from becoming a boot loop.
	 */
	public static function recover():Void
	{
		#if sys
		var markerExists:Bool = false;
		try markerExists = FileSystem.exists(ATTEMPT_MARKER) catch (error:Dynamic) {}

		if (!markerExists) return;

		var record:String = '';
		try record = File.getContent(ATTEMPT_MARKER) catch (error:Dynamic) {}

		deleteMarker();

		recoveredFromCrash = true;
		fellBackThisBoot = true;
		failureReason = 'the previous launch stopped while Vulkan was starting';

		log('previous launch left ' + ATTEMPT_MARKER + ' behind; this launch stays on OpenGL');

		if (record.length > 0) writeFailureRecord(record);

		if (ClientPrefs.data != null && ClientPrefs.data.renderer != OPENGL)
		{
			ClientPrefs.data.renderer = OPENGL;
			if (ClientPrefs.prefsLoaded) ClientPrefs.saveSettings();
		}
		#end
	}

	// ======================================================================
	//  Persistence helpers
	// ======================================================================

	static function writeMarker(state:String):Void
	{
		#if sys
		try
		{
			if (!FileSystem.exists('logs')) FileSystem.createDirectory('logs');

			File.saveContent(ATTEMPT_MARKER, Date.now().toString() + '\nstate: ' + state + '\n'
				+ 'platform: ' + platformName() + '\n');
		}
		catch (error:Dynamic)
		{
			log('could not write ' + ATTEMPT_MARKER + ': ' + Std.string(error));
		}
		#end
	}

	static function deleteMarker():Void
	{
		#if sys
		try
		{
			if (FileSystem.exists(ATTEMPT_MARKER)) FileSystem.deleteFile(ATTEMPT_MARKER);
		}
		catch (error:Dynamic) {}
		#end
	}

	/** Keeps the record of a crashed launch next to the other renderer logs. */
	static function writeFailureRecord(record:String):Void
	{
		#if sys
		try
		{
			if (!FileSystem.exists('logs')) FileSystem.createDirectory('logs');

			File.saveContent('logs/vulkan-last-failure.txt',
				Date.now().toString() + '\nA launch with Vulkan did not get past startup.\n\n' + record);
		}
		catch (error:Dynamic) {}
		#end
	}

	/**
	 * Records this launch's renderer decision in logs/renderer.txt.
	 *
	 * The runtime only writes a status record when it actually *starts*, so a session that
	 * stays on OpenGL (because nobody picked Vulkan, or because this build/platform cannot
	 * offer it) leaves nothing behind - and "why is it not on Vulkan?" then has no answer on
	 * disk. This is one line, written once per launch, before anything starts.
	 */
	public static function writeDecisionRecord():Void
	{
		#if sys
		try
		{
			if (!FileSystem.exists('logs')) FileSystem.createDirectory('logs');

			File.saveContent('logs/renderer.txt', Date.now().toString() + '\n' + describe()
				+ '\nwanted=' + wanted() + ' available=' + available() + ' offered=' + offered()
				+ ' willTryVulkan=' + shouldStart() + '\n');
		}
		catch (error:Dynamic) {}
		#end
	}

	/** One line for the crash report / diagnostic dump. */
	public static function describe():String
	{
		var mode:String = active ? 'vulkan' : 'opengl';
		var saved:String = (ClientPrefs.data == null) ? '?' : Std.string(ClientPrefs.data.renderer);

		var text:String = 'renderer=' + mode + ' saved=' + saved + ' platform=' + platformName();
		if (!compiled) text += ' (not compiled into this build)';
		else if (!offered()) text += ' (not offered on this platform)';
		if (recoveredFromCrash) text += ' (previous Vulkan launch failed)';
		if (fellBackThisBoot && failureReason != null) text += ' (fallback: ' + failureReason + ')';

		return text;
	}

	static function platformName():String
	{
		#if windows
		return 'windows';
		#elseif android
		return 'android';
		#elseif mac
		return 'mac';
		#elseif linux
		return 'linux';
		#elseif ios
		return 'ios';
		#else
		return 'other';
		#end
	}

	static function log(message:String):Void
	{
		#if sys
		try Sys.println(TAG + ' ' + message) catch (error:Dynamic) {}
		#end
	}
}
