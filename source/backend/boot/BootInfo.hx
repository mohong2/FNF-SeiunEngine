package backend.boot;

import backend.DeviceInfo;
import backend.RendererChoice;
import flixel.graphics.FlxGraphic;

using StringTools;

/**
 * Everything the boot screen can honestly say about itself.
 *
 * One place, so the corner labels never invent a number: the version comes from BuildInfo
 * (git + Project.xml, stamped at compile time), the platform from the compile target and
 * the renderer from backend.RendererChoice.
 *
 * All of it is defensive. The boot runs before assets are unpacked, before the first frame
 * has been presented and — on a first Android launch — before any file exists on disk, so
 * every getter answers with an empty string or null rather than throwing. A chip that
 * cannot get its value simply does not draw it.
 *
 * The GL version is deliberately not reported: this engine draws through lime directly,
 * so there is no Stage3D context to ask, and a raw GL query without a current context
 * returns nothing at all. The renderer's own wordmark is the honest answer.
 */
class BootInfo
{
	/** Version + build, e.g. "v0.2.2  |  e618301+". */
	public static function versionLine():String
	{
		var version:String = safeBuild(function() return BuildInfo.appVersion(), 'unknown');
		var build:String = safeBuild(function() return BuildInfo.buildId(), 'unknown');
		var text:String = 'v' + version;
		if (build.length > 0 && build != 'unknown' && build != version)
			text += '  |  ' + build;
		return text;
	}

	/** Platform and word size, e.g. "WINDOWS  x64". */
	public static function platformLine():String
	{
		return platformName() + '  ' + architectureName();
	}

	public static function platformName():String
	{
		#if windows
		return 'WINDOWS';
		#elseif mac
		return 'MACOS';
		#elseif linux
		return 'LINUX';
		#elseif android
		return 'ANDROID';
		#elseif ios
		return 'IOS';
		#elseif js
		return 'WEB';
		#else
		return 'OTHER';
		#end
	}

	public static function architectureName():String
	{
		var raw:String = '';
		try raw = DeviceInfo.architecture() catch (e:Dynamic) {}
		if (raw == null) raw = '';
		var lower:String = raw.toLowerCase();
		if (lower == 'amd64' || lower == 'x86_64' || lower == 'x64') return 'x64';
		if (lower == 'arm64' || lower == 'aarch64') return 'arm64';
		if (lower == 'x86' || lower == 'i386' || lower == 'i686') return 'x86';
		if (lower == 'armv7' || lower == 'arm') return 'armv7';
		if (lower == 'web') return 'wasm';
		return raw.length > 0 ? raw : 'unknown';
	}

	/**
	 * Which backend is drawing this frame, right now.
	 *
	 * RendererChoice.active only turns true once the Vulkan runtime has taken the window
	 * over, which happens after the first presented frame — so the boot screen starts on
	 * OpenGL even in a Vulkan session and this value flips mid-boot. That is the honest
	 * answer, and the boot screen re-reads it a few times a second.
	 */
	public static function rendererName():String
	{
		#if seiun_vulkan
		try
		{
			if (RendererChoice.active) return 'VULKAN';
		}
		catch (e:Dynamic) {}
		#end
		return 'OPENGL';
	}

	/** The renderer's own wordmark, or null when the assets are not unpacked yet. */
	public static function rendererMark():FlxGraphic
	{
		var key:String = (rendererName() == 'VULKAN') ? 'options/renderers/vulkan' : 'options/renderers/opengl';
		try
		{
			return Paths.image(key);
		}
		catch (e:Dynamic)
		{
			return null;
		}
	}

	/** Brand tint for the renderer mark. */
	public static function rendererColor():Int
	{
		return (rendererName() == 'VULKAN') ? 0xFFE8455C : 0xFF6FB6E8;
	}

	inline static function safeBuild(read:Void->String, fallback:String):String
	{
		try
		{
			var value:String = read();
			return (value == null || value.length == 0) ? fallback : value;
		}
		catch (e:Dynamic)
		{
			return fallback;
		}
	}
}
