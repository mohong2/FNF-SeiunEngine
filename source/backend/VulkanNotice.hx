package backend;

import sys.FileSystem;
import sys.io.File;

/**
 * Tells the player that this build has no Vulkan backend.
 *
 * It lives in the engine rather than in the renderer because the renderer's
 * sources are only added to the build when `-D seiun_vulkan` is set: this notice
 * is for exactly those builds, where none of the renderer's classes exist.
**/
class VulkanNotice
{
	static inline var TAG = "[vulkan]";

	/**
	 * True once the experimental Vulkan backend has actually taken over this session.
	 *
	 * Set by `Main.installVulkan()` after the runtime reports success, and read by the
	 * Renderer row in the settings menu so it can say what the game is really drawing
	 * through. Stays false in builds compiled without `-D seiun_vulkan`, because the
	 * renderer never starts there.
	 */
	public static var active:Bool = false;

	/** Returns true when --vulkan (or SEIUN_VULKAN) asked for a backend this build lacks. */
	public static function report(show:String->Void):Bool
	{
		if (!requested ()) return false;

		var reason = "这个构建没有编译 Vulkan 后端（缺少编译宏 -D seiun_vulkan），"
			+ "本次继续使用 OpenGL。\n\n"
			+ "This build was compiled without the Vulkan backend (missing -D seiun_vulkan);"
			+ " this session stays on OpenGL.";

		Sys.println (TAG + " requested, but this build has no Vulkan backend compiled in");

		writeStatusRecord (reason);

		if (show != null)
		{
			try show (reason) catch (error:Dynamic) {}
		}

		return true;
	}

	/** Same rules the renderer uses, so both builds answer --vulkan the same way. */
	static function requested():Bool
	{
		for (arg in Sys.args ())
		{
			if (arg == "--no-vulkan") return false;
			if (arg == "--vulkan") return true;
		}

		var env:String = Sys.getEnv ("SEIUN_VULKAN");

		return env != null && env != "" && env != "0";
	}

	static function writeStatusRecord(reason:String):Void
	{
		try
		{
			if (!FileSystem.exists ("logs")) FileSystem.createDirectory ("logs");

			// Line endings and layout match the renderer's record, so the two builds
			// describe themselves to the same tooling.
			File.saveContent ("logs/vulkan-status.txt", Date.now ().toString ()
				+ "\nrenderer: opengl (not compiled into this build)\n" + reason + "\n");
		}
		catch (error:Dynamic) {}
	}
}
