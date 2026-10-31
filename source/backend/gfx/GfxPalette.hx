package backend.gfx;

import flixel.FlxG;
import flixel.graphics.FlxGraphic;
import haxe.Timer;
import haxe.io.Bytes;
import lime.graphics.opengl.GL;
import mohong.TraceManager;
import openfl.display.BitmapData;
import openfl.display.ShaderInput;
import openfl.display3D.Context3D;
import openfl.display3D.Context3DTextureFilter;
import openfl.display3D.Context3DWrapMode;
import openfl.utils._internal.UInt8Array;
#if FLX_DRAW_QUADS
import backend.gfx.GfxPaletteShader;
#end

/**
 * Persistent L1b plan. Palette bytes are the exact premultiplied BGRA bytes that
 * the RGBA texture would have sampled; index bytes are the exact index texture.
 * A restore can rebuild the index deterministically from these bytes and the
 * palette order never changes.
 */
typedef GfxPalettePlan = {
	var width:Int;
	var height:Int;
	var colors:Int;
	var format:Int;
	var usesAlpha:Bool;
	var premultiplied:Bool;
	var palette:Bytes;
	var index:Bytes;
	var hash:String;
};

private typedef PaletteBuild = {
	var colors:Int;
	var palette:Bytes;
	var index:Bytes;
};

/**
 * L1b lossless palette textures.
 *
 * An image whose final canvas (after L2a crop and L2b repack) has at most 256
 * distinct RGBA byte values is stored on the GPU as a one-byte index texture
 * plus a 256x1 RGBA palette. The shader expands indices with NEAREST sampling,
 * so every visible pixel resolves to the exact same premultiplied BGRA value as
 * the RGBA texture path.
 *
 * This class never mutates source assets and never scales or quantises. Any
 * unsupported case (too many colours, no CPU pixels, no index texture format,
 * shader compile/link failure, pixel mismatch) keeps the original RGBA bitmap
 * and the original FlxShader.
 *
 * Opt out:      FNF_GFX_PALETTE=0
 * Full verify:  FNF_GFX_PALETTE_VERIFY=1
 * Force path:   FNF_GFX_PALETTE_FORCE=1 (bypasses the size floor for tests)
 */
class GfxPalette
{
	public static var enabled:Bool = true;

	/** Do not pay a scan for tiny images; atlases are applied directly even
	 *  below GfxMemory's CPU-drop floor (titleEnter is ~256k px after L2a). */
	public static var minPixels:Int = 128 * 128;

	public static var maxColors:Int = 256;

	public static var appliedCount:Int = 0;
	public static var appliedBytesBefore:Float = 0;
	public static var appliedBytesAfter:Float = 0;

	static var checked:Bool = false;
	static var enabledOn:Bool = true;
	static var verify:Bool = false;
	static var force:Bool = false;
	static var traceEnabled:Bool = false;
	static var lastError:String = '';

	static var formatChecked:Bool = false;
	static var indexFormat:Int = 0;
	static var formatName:String = '';
	static var formatUsesAlpha:Bool = false;
	static var formatMs:Float = 0;

	static var queue:Map<FlxGraphic, Bool> = new Map();
	static var maxAppliesPerFrame:Int = 4;

	/** Read the environment switches once. */
	public static function init():Void
	{
		isEnabled();
	}

	static function isEnabled():Bool
	{
		if (!checked)
		{
			checked = true;
			#if sys
			enabledOn = Sys.getEnv('FNF_GFX_PALETTE') != '0';
			verify = Sys.getEnv('FNF_GFX_PALETTE_VERIFY') == '1';
			force = Sys.getEnv('FNF_GFX_PALETTE_FORCE') == '1';
			traceEnabled = Sys.getEnv('FNF_GFX_PALETTE_TRACE') == '1' || Sys.getEnv('FNF_GFX_TRACE') == '1';
			#end
		}
		return enabled && enabledOn;
	}

	public static function queueGraphic(graphic:FlxGraphic):Void
	{
		if (!isEnabled() || graphic == null || graphic.bitmap == null) return;
		if (graphic.gfxPalettePlan != null) return;
		queue.set(graphic, true);
	}

	public static function unqueueGraphic(graphic:FlxGraphic):Void
	{
		if (graphic != null) queue.remove(graphic);
	}

	public static function clearQueue():Void
	{
		queue = new Map();
	}

	/**
	 * Apply every queued graphic now, ignoring the per-frame budget.
	 *
	 * Load-time commits call this before forcing the texture: a palette decision
	 * can only be made while the bitmap still has CPU pixels and no texture, so
	 * once the load phase ends there is no second chance for the images the
	 * per-frame queue never reached. Returns how many graphics were converted.
	 */
	public static function flushQueue():Int
	{
		if (!isEnabled() || !queue.keys().hasNext()) return 0;
		var context:Context3D = FlxG.stage != null ? FlxG.stage.context3D : null;
		if (context == null) return 0;

		var applied:Int = 0;
		var pendingList:Array<FlxGraphic> = [];
		for (graphic in queue.keys()) pendingList.push(graphic);
		for (graphic in pendingList)
		{
			if (graphic == null) continue;
			if (graphic.bitmap == null || graphic.gfxPalettePlan != null)
			{
				queue.remove(graphic);
				continue;
			}
			lastError = '';
			try
			{
				if (apply(graphic) != null) applied++;
			}
			catch (e:Dynamic)
			{
				lastError = 'exception';
				fail(graphic, Std.string(e));
			}
			// Only a missing context is retryable; every other outcome is final for
			// this bitmap (texture already exists, too many colours, driver reject).
			if (lastError != 'no_context') queue.remove(graphic);
		}
		return applied;
	}

	/**
	 * Apply pending plain-image graphics before the draw that would upload them.
	 * Atlases are applied synchronously from Paths.finishAtlas(), so this queue
	 * only carries normal images and late loads.
	 */
	public static function onPreDraw():Void
	{
		if (!isEnabled() || !queue.keys().hasNext()) return;
		var context:Context3D = FlxG.stage != null ? FlxG.stage.context3D : null;
		if (context == null) return;

		var remove:Array<FlxGraphic> = [];
		var pendingList:Array<FlxGraphic> = [];
		for (graphic in queue.keys()) pendingList.push(graphic);
		var budget:Int = maxAppliesPerFrame;
		for (graphic in pendingList)
		{
			if (budget <= 0) break;
			if (graphic == null || graphic.bitmap == null || graphic.gfxPalettePlan != null)
			{
				remove.push(graphic);
				continue;
			}
			lastError = '';
			apply(graphic);
			if (lastError != 'no_context') remove.push(graphic);
			budget--;
		}
		for (graphic in remove) queue.remove(graphic);
	}

	/**
	 * Try to replace the GPU representation of this graphic with an index+palette
	 * pair. Returns the plan on success, or null and leaves the graphic exactly
	 * as it was.
	 */
	public static function apply(graphic:FlxGraphic):GfxPalettePlan
	{
		unqueueGraphic(graphic);
		if (!isEnabled() || graphic == null || graphic.bitmap == null) return null;
		if (graphic.gfxPalettePlan != null) return cast graphic.gfxPalettePlan;

		var bmp:BitmapData = graphic.bitmap;
		if (bmp.paletteApplied) return null;
		if (bmp.width <= 0 || bmp.height <= 0) return null;
		if (!force && bmp.width * bmp.height < minPixels)
		{
			lastError = 'below_min_pixels';
			return null;
		}
		if (!bmp.hasCPU || bmp.image == null || bmp.image.buffer == null || bmp.image.buffer.data == null)
		{
			lastError = 'no_cpu_buffer';
			return null;
		}
		// Do not gate on useCount: the bitmap object is unchanged, the shader is
		// per-graphic, and the texture cannot exist yet (checked below). Sprites may
		// already reference this graphic from create(), which is the normal case.
		var context:Context3D = FlxG.stage != null ? FlxG.stage.context3D : null;
		if (context == null)
		{
			lastError = 'no_context';
			return null;
		}
		if (bmp.hasTexture(context))
		{
			// The RGBA texture is already published; replacing it now could break
			// canvases recorded before this point. Keep RGBA for this graphic.
			lastError = 'texture_already_uploaded';
			skip(graphic, lastError);
			return null;
		}
		if (!ensureIndexFormat(context))
		{
			lastError = 'no_index_texture_format';
			skip(graphic, lastError);
			return null;
		}

		var started:Float = Timer.stamp();
		var width:Int = bmp.width;
		var height:Int = bmp.height;

		// A palette texture is still a single GL texture. Some mod atlases are
		// wider than GL_MAX_TEXTURE_SIZE (one real mod has a 36630-wide atlas);
		// never publish an index texture the driver cannot represent.
		var maxTextureSize:Int = 0;
		var gl = @:privateAccess context.gl;
		try maxTextureSize = cast gl.getParameter(GL.MAX_TEXTURE_SIZE) catch (e:Dynamic) {}
		if (maxTextureSize > 0 && (width > maxTextureSize || height > maxTextureSize))
		{
			lastError = 'above_gl_max_texture';
			skip(graphic, lastError + ':' + Std.string(width) + 'x' + Std.string(height) + ' max=' + Std.string(maxTextureSize));
			return null;
		}

		var source:UInt8Array = bmp.image.buffer.data;
		var built:PaletteBuild = buildPalette(source, width, height);
		if (built == null)
		{
			lastError = 'too_many_colors';
			return null;
		}

		var paletteBitmap:BitmapData = makePaletteBitmap(built.palette);
		if (paletteBitmap == null)
		{
			lastError = 'palette_alloc_failed';
			return null;
		}

		var oldShader = graphic.shader;
		var shader:GfxPaletteShader = null;
		#if FLX_DRAW_QUADS
		shader = new GfxPaletteShader();
		if (!shader.gfxTryCompile(context))
		{
			paletteBitmap.dispose();
			lastError = 'shader_compile_failed';
			skip(graphic, lastError);
			return null;
		}

		var paletteInput:ShaderInput<BitmapData> = shader.data.palette;
		if (paletteInput == null)
		{
			paletteBitmap.dispose();
			lastError = 'palette_input_missing';
			skip(graphic, lastError);
			return null;
		}
		paletteInput.input = paletteBitmap;
		paletteInput.filter = Context3DTextureFilter.NEAREST;
		paletteInput.wrap = Context3DWrapMode.CLAMP;
		shader.data.paletteUseAlpha.value = [formatUsesAlpha];
		#else
		paletteBitmap.dispose();
		lastError = 'no_draw_quads';
		return null;
		#end

		var indexBytes:UInt8Array = UInt8Array.fromBytes(built.index);
		if (!bmp.setPaletteIndex(indexBytes, indexFormat, built.colors))
		{
			paletteBitmap.dispose();
			lastError = 'set_palette_failed';
			return null;
		}

		graphic.setGfxShader(shader);
		graphic.gfxPaletteBitmap = paletteBitmap;

		var plan:GfxPalettePlan = {
			width: width,
			height: height,
			colors: built.colors,
			format: indexFormat,
			usesAlpha: formatUsesAlpha,
			premultiplied: true,
			palette: built.palette,
			index: built.index,
			hash: hashBytes(built.index)
		};

		bmp.palettePlan = plan;
		var sampledOk:Bool = validateBytes(bmp, plan, false);
		var fullOk:Bool = !verify || validateBytes(bmp, plan, true);
		if (!sampledOk || !fullOk)
		{
			rollback(graphic, bmp, paletteBitmap, oldShader);
			lastError = 'pixel_mismatch';
			fail(graphic, lastError);
			return null;
		}

		graphic.gfxPalettePlan = plan;
		appliedCount++;
		var before:Float = width * height * 4;
		var after:Float = width * height + 256 * 4;
		appliedBytesBefore += before;
		appliedBytesAfter += after;

		var ms:Float = (Timer.stamp() - started) * 1000;
		var keyName:String = graphic.assetsKey != null ? graphic.assetsKey
			: (graphic.key != null ? graphic.key : '(null)');
		var line:String = 'key=' + keyName
			+ ' colors=' + Std.string(built.colors)
			+ ' before=' + Std.string(width) + 'x' + Std.string(height)
			+ ' gpuBeforeMB=' + mb(before)
			+ ' gpuAfterMB=' + mb(after)
			+ ' savedPct=' + Std.string(Math.round((1 - after / before) * 10000) / 100)
			+ ' texture=INDEX8/' + formatName
			+ ' shader=palette_v1'
			+ ' premultiplied=true'
			+ ' validate=' + (verify ? 'OK_FULL' : 'OK')
			+ ' ms=' + Std.string(Math.round(ms * 10) / 10);
		TraceManager.info('trace.gfx.palette', 'GfxPalette ' + line);
		#if sys
		if (traceEnabled) Sys.println('[GfxPalette] ' + line);
		#end
		return plan;
	}

	static function rollback(graphic:FlxGraphic, bmp:BitmapData, paletteBitmap:BitmapData, oldShader:flixel.system.FlxAssets.FlxShader):Void
	{
		bmp.clearPalette();
		graphic.gfxPaletteBitmap = null;
		#if FLX_DRAW_QUADS
		graphic.setGfxShader(oldShader);
		#end
		paletteBitmap.dispose();
	}

	/**
	 * Build the deterministic palette. Palette entry 0 is forced to transparent
	 * black whenever the image actually contains a fully transparent pixel; the
	 * mapping table is updated so the index pass still resolves every pixel to
	 * the same bytes. Returns null when the image has more than 256 colours.
	 */
	static function buildPalette(source:UInt8Array, width:Int, height:Int):PaletteBuild
	{
		var count:Int = width * height;
		if (source == null || source.length != count * 4) return null;

		// UInt8Array indexing goes through ArrayBufferIO (a native call per byte).
		// The same buffer as haxe.io.Bytes is an inline array access on cpp, and
		// getInt32 reads the four BGRA bytes this hash needs in one expression.
		// Pixel-for-pixel identical, several times faster on multi-megapixel sheets.
		var data:Bytes = source.toBytes();
		if (data == null || data.length != count * 4) return null;

		var mask:Int = 2047;
		var keys:Array<Int> = [];
		var values:Array<Int> = [];
		for (i in 0...2048)
		{
			keys.push(0);
			values.push(-1);
		}

		var palette:Bytes = Bytes.alloc(256 * 4);
		var indices:Bytes = Bytes.alloc(count);
		var colors:Int = 0;
		var i:Int = 0;
		while (i < count)
		{
			var base:Int = i * 4;
			// Little-endian BGRA bytes -> the same 32-bit key the byte form built.
			var key:Int = data.getInt32(base);
			var slot:Int = ((key * 0x9E3779B1) >>> 13) & mask;
			var value:Int = -1;
			while (true)
			{
				var found:Int = values[slot];
				if (found < 0)
				{
					if (colors >= maxColors) return null;
					value = colors;
					values[slot] = colors;
					keys[slot] = key;
					var p:Int = colors * 4;
					palette.set(p, data.get(base));
					palette.set(p + 1, data.get(base + 1));
					palette.set(p + 2, data.get(base + 2));
					palette.set(p + 3, data.get(base + 3));
					colors++;
					break;
				}
				if (keys[slot] == key)
				{
					value = found;
					break;
				}
				slot = (slot + 1) & mask;
			}
			indices.set(i, value);
			i++;
		}

		// Reserve entry 0 for fully transparent pixels when they exist. The
		// single pass above already wrote first-occurrence indices, so only the
		// 1-byte index buffer needs a remap here; RGBA is never read again.
		var zeroSlot:Int = ((0 * 0x9E3779B1) >>> 13) & mask;
		var zeroIndex:Int = -1;
		while (true)
		{
			var found:Int = values[zeroSlot];
			if (found < 0) break;
			if (keys[zeroSlot] == 0)
			{
				zeroIndex = found;
				break;
			}
			zeroSlot = (zeroSlot + 1) & mask;
		}
		if (zeroIndex > 0)
		{
			for (k in 0...4)
			{
				var a:Int = palette.get(k);
				palette.set(k, palette.get(zeroIndex * 4 + k));
				palette.set(zeroIndex * 4 + k, a);
			}
			for (i in 0...count)
			{
				var value:Int = indices.get(i);
				if (value == 0) indices.set(i, zeroIndex);
				else if (value == zeroIndex) indices.set(i, 0);
			}
		}

		return {colors: colors, palette: palette, index: indices};
	}

	static function makePaletteBitmap(palette:Bytes):BitmapData
	{
		var bmp:BitmapData = new BitmapData(256, 1, true, 0);
		if (bmp.image == null || bmp.image.buffer == null || bmp.image.buffer.data == null) return null;
		var data = bmp.image.buffer.data;
		for (i in 0...1024)
			data[i] = palette.get(i);
		bmp.image.version++;
		bmp.image.dirty = true;
		return bmp;
	}

	/** Sample (or fully) expand the index texture and compare every byte. */
	public static function validateBytes(bmp:BitmapData, plan:GfxPalettePlan, full:Bool):Bool
	{
		if (bmp == null || bmp.image == null || bmp.image.buffer == null || bmp.image.buffer.data == null) return false;
		var data = bmp.image.buffer.data;
		var count:Int = plan.width * plan.height;
		if (data.length != count * 4 || plan.index.length != count) return false;
		var step:Int = full ? 1 : Std.int(Math.max(1, count / 4096));
		var i:Int = 0;
		while (i < count)
		{
			var index:Int = plan.index.get(i);
			if (index < 0 || index >= plan.colors) return false;
			var di:Int = i * 4;
			var pi:Int = index * 4;
			if (data[di] != plan.palette.get(pi) || data[di + 1] != plan.palette.get(pi + 1)
				|| data[di + 2] != plan.palette.get(pi + 2) || data[di + 3] != plan.palette.get(pi + 3))
				return false;
			i += step;
		}
		return true;
	}

	/**
	 * Rebuild the index buffer from a freshly decoded RGBA canvas using the
	 * fixed plan palette. Returns null if any pixel is not one of the planned
	 * colours, so a changed source can never silently produce a wrong image.
	 */
	public static function rebuildIndex(source:BitmapData, plan:GfxPalettePlan):Bytes
	{
		if (source == null || source.image == null || source.image.buffer == null || source.image.buffer.data == null) return null;
		if (source.width != plan.width || source.height != plan.height) return null;
		var data = source.image.buffer.data;
		var lookup:Map<Int, Int> = new Map();
		for (i in 0...plan.colors)
		{
			var p:Int = i * 4;
			var key:Int = plan.palette.get(p) | (plan.palette.get(p + 1) << 8) | (plan.palette.get(p + 2) << 16) | (plan.palette.get(p + 3) << 24);
			lookup.set(key, i);
		}
		var count:Int = plan.width * plan.height;
		var out:Bytes = Bytes.alloc(count);
		for (i in 0...count)
		{
			var b:Int = i * 4;
			var key:Int = data[b] | (data[b + 1] << 8) | (data[b + 2] << 16) | (data[b + 3] << 24);
			var index:Null<Int> = lookup.get(key);
			if (index == null) return null;
			out.set(i, index);
		}
		return out;
	}

	/**
	 * Validate a restored CPU canvas against the immutable plan. Used by the
	 * self-test after dropCPU()/restoreCPU(); never allocates a second RGBA copy.
	 */
	public static function validateRestore(source:BitmapData, plan:GfxPalettePlan):Bool
	{
		var rebuilt:Bytes = rebuildIndex(source, plan);
		if (rebuilt == null) return false;
		if (rebuilt.length != plan.index.length) return false;
		for (i in 0...rebuilt.length)
			if (rebuilt.get(i) != plan.index.get(i)) return false;
		return true;
	}

	static function ensureIndexFormat(context:Context3D):Bool
	{
		if (formatChecked) return indexFormat != 0;
		formatChecked = true;
		var started:Float = Timer.stamp();
		var candidates:Array<{format:Int, name:String, alpha:Bool}> = [
			{format: GL.ALPHA, name: 'ALPHA', alpha: true},
			{format: GL.LUMINANCE, name: 'LUMINANCE', alpha: false},
			{format: GL.R8, name: 'R8', alpha: false}
		];

		for (candidate in candidates)
		{
			if (candidate.format <= 0) continue;
			var texture:openfl.display3D.textures.RectangleTexture = null;
			try
			{
				texture = context.createIndexRectangleTexture(1, 1, candidate.format);
				if (texture == null) continue;
				var probe:UInt8Array = new UInt8Array(1);
				probe[0] = 0;
				if (texture.uploadIndexData(probe, 1, 1))
				{
					indexFormat = candidate.format;
					formatName = candidate.name;
					formatUsesAlpha = candidate.alpha;
					formatMs = (Timer.stamp() - started) * 1000;
					var line:String = 'probe texture=INDEX8/' + formatName
						+ ' format=0x' + StringTools.hex(candidate.format, 4)
						+ ' usesAlpha=' + Std.string(candidate.alpha)
						+ ' ms=' + Std.string(Math.round(formatMs * 10) / 10)
						+ ' validate=OK';
					TraceManager.info('trace.gfx.paletteProbe', 'GfxPalette ' + line);
					#if sys
					if (traceEnabled) Sys.println('[GfxPalette] ' + line);
					#end
					texture.dispose();
					return true;
				}
			}
			catch (e:Dynamic)
			{
				// try the next format
			}
			if (texture != null) texture.dispose();
		}

		TraceManager.warn('trace.gfx.paletteProbe', 'GfxPalette no 8-bit index texture format; palette disabled');
		#if sys
		Sys.println('[GfxPalette] probe failed: no 8-bit index texture format; fallback=RGBA');
		#end
		return false;
	}

	static function hashBytes(bytes:Bytes):String
	{
		var h1:Int = 0x811C9DC5;
		var h2:Int = 0x01000193;
		for (i in 0...bytes.length)
		{
			var b:Int = bytes.get(i);
			h1 = (h1 ^ b) * 16777619;
			h2 = ((h2 + b) ^ (h2 << 5)) * 31;
		}
		return StringTools.hex(h1, 8) + StringTools.hex(h2, 8);
	}

	static function skip(graphic:FlxGraphic, reason:String):Void
	{
		if (!traceEnabled) return;
		var keyName:String = graphic != null && graphic.assetsKey != null ? graphic.assetsKey
			: (graphic != null ? graphic.key : '(null)');
		TraceManager.info('trace.gfx.paletteSkip', 'GfxPalette key=' + (keyName == null ? '(null)' : keyName) + ' reason=' + reason);
		#if sys
		Sys.println('[GfxPalette] key=' + (keyName == null ? '(null)' : keyName) + ' reason=' + reason + ' validate=ROLLBACK');
		#end
	}

	static function fail(graphic:FlxGraphic, reason:String):Void
	{
		var keyName:String = graphic != null && graphic.assetsKey != null ? graphic.assetsKey
			: (graphic != null ? graphic.key : '(null)');
		TraceManager.warn('trace.gfx.paletteFail', 'GfxPalette key=' + (keyName == null ? '(null)' : keyName) + ' reason=' + reason + ' validate=ROLLBACK');
		#if sys
		Sys.println('[GfxPalette] key=' + (keyName == null ? '(null)' : keyName) + ' reason=' + reason + ' validate=ROLLBACK');
		#end
	}

	static inline function mb(bytes:Float):String
	{
		return Std.string(Math.round(bytes / 1048576 * 10) / 10);
	}
}

