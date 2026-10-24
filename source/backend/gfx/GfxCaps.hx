package backend.gfx;

import flixel.FlxG;
import lime.graphics.opengl.GL;
import mohong.TraceManager;
import openfl.display3D.Context3D;

/**
 * One-shot GPU capability report used by the D2 block-compression feasibility
 * study. It is diagnostic only: it never changes a texture path and never
 * claims a format is usable just because the string is present.
 *
 * Enable with FNF_GFX_CAPS=1.
 */
class GfxCaps
{
	static var logged:Bool = false;

	static var COMPRESSED:Map<Int, String> = [
		0x83F0 => 'DXT1',
		0x83F1 => 'DXT1_ALPHA',
		0x83F2 => 'DXT3',
		0x83F3 => 'DXT5',
		0x8D64 => 'ETC1',
		0x9274 => 'ETC2_RGB8',
		0x9278 => 'ETC2_RGBA8',
		0x8E8C => 'BC7',
		0x8E8D => 'BC6H',
		0x93B0 => 'ASTC_4x4',
		0x93B1 => 'ASTC_5x4',
		0x93B2 => 'ASTC_5x5',
		0x93B3 => 'ASTC_6x5',
		0x93B4 => 'ASTC_6x6',
		0x93B7 => 'ASTC_8x8',
		0x93BB => 'ASTC_12x12'
	];

	public static function logOnce():Void
	{
		if (logged) return;
		logged = true;

		var context:Context3D = FlxG.stage != null ? FlxG.stage.context3D : null;
		if (context == null)
		{
			#if sys
			Sys.println('[GfxCaps] no Context3D yet');
			#end
			return;
		}

		try
		{
			var gl = @:privateAccess context.gl;
			var extensions:Array<String> = gl.getSupportedExtensions();
			if (extensions == null) extensions = [];
			var relevant:Array<String> = [];
			for (name in extensions)
			{
				var lower: String = name.toLowerCase();
				if (lower.indexOf('texture_compression') >= 0 || lower.indexOf('compressed_texture') >= 0
					|| lower.indexOf('astc') >= 0 || lower.indexOf('bptc') >= 0
					|| lower.indexOf('etc') >= 0 || lower.indexOf('s3tc') >= 0 || lower.indexOf('bgra') >= 0)
					relevant.push(name);
			}
			relevant.sort(Reflect.compare);

			var formatCount:Int = gl.getParameter(GL.NUM_COMPRESSED_TEXTURE_FORMATS);
			var formats:Array<String> = [];
			if (formatCount > 0)
			{
				var values:Dynamic = gl.getParameter(GL.COMPRESSED_TEXTURE_FORMATS);
				if (values != null)
				{
					var count:Int = Std.int(values.length);
					for (i in 0...count)
					{
						var value:Int = untyped values[i];
						var name:String = COMPRESSED.get(value);
						formats.push(name != null ? name : '0x' + StringTools.hex(value, 4));
					}
				}
			}

			var line:String = 'vendor=' + Std.string(gl.getParameter(GL.VENDOR))
				+ ' renderer=' + Std.string(gl.getParameter(GL.RENDERER))
				+ ' version=' + Std.string(gl.getParameter(GL.VERSION))
				+ ' glsl=' + Std.string(gl.getParameter(GL.SHADING_LANGUAGE_VERSION))
				+ ' maxTextureSize=' + Std.string(gl.getParameter(GL.MAX_TEXTURE_SIZE))
				+ ' maxTextureUnits=' + Std.string(gl.getParameter(GL.MAX_TEXTURE_IMAGE_UNITS))
				+ ' compressedFormatCount=' + Std.string(formatCount)
				+ ' compressedFormats=[' + formats.join(',') + ']'
				+ ' extensions=[' + relevant.join(',') + ']';

			TraceManager.info('trace.gfx.caps', 'GfxCaps ' + line);
			#if sys
			Sys.println('[GfxCaps] ' + line);
			#end
		}
		catch (e:Dynamic)
		{
			#if sys
			Sys.println('[GfxCaps] probe failed: ' + Std.string(e));
			#end
		}
	}
}
