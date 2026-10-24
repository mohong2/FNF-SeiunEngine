package backend.gfx;

import flixel.graphics.FlxGraphic;
import flixel.graphics.frames.FlxAtlasFrames;
import flixel.graphics.frames.FlxFrame.FlxFrameType;
import flixel.math.FlxRect;
import haxe.Timer;
import mohong.TraceManager;
import openfl.display.BitmapData;
import openfl.geom.Point;
import openfl.geom.Rectangle;

/**
 * L2a lossless atlas crop: translate the whole bitmap to the union bbox of all
 * frame rects. Frame sizes, offsets, sourceSize, names and order are untouched.
 * No repacking and no scaling live in this class.
 *
 * Every candidate is sampled against the old bitmap and every frame rect, UV
 * and parent link is re-checked after the swap. Any failure rolls back.
 * Opt out with FNF_GFX_ATLAS_CROP=0.
 */
class GfxAtlasCrop
{
	public static var enabled:Bool = true;
	public static var minSavedRatio:Float = 0.005;
	static var checked:Bool = false;
	static var lastError:String = '';

	public static function apply(graphic:FlxGraphic, frames:FlxAtlasFrames, ?source:String):Rectangle
	{
		if (!isEnabled() || graphic == null || frames == null) return null;
		lastError = '';
		if (graphic.gfxCropRect != null) return graphic.gfxCropRect;

		var bmp:BitmapData = graphic.bitmap;
		if (bmp == null || !bmp.hasCPU || graphic.useCount > 0) return null;
		if (frames.frames == null || frames.frames.length == 0) return null;
		if (bmp.width <= 0 || bmp.height <= 0) return null;

		var minX:Float = 1e20;
		var minY:Float = 1e20;
		var maxX:Float = -1e20;
		var maxY:Float = -1e20;
		var usable:Int = 0;

		for (frame in frames.frames)
		{
			if (frame == null || frame.type == FlxFrameType.EMPTY || frame.frame == null) continue;
			var r = frame.frame;
			if (r.width <= 0 || r.height <= 0) continue;
			if (r.x < 0 || r.y < 0 || r.right > bmp.width + 0.001 || r.bottom > bmp.height + 0.001)
				return skip(graphic, 'frame_out_of_bounds');
			minX = Math.min(minX, r.x);
			minY = Math.min(minY, r.y);
			maxX = Math.max(maxX, r.right);
			maxY = Math.max(maxY, r.bottom);
			usable++;
		}

		if (usable == 0) return null;
		var x:Int = Std.int(Math.floor(minX));
		var y:Int = Std.int(Math.floor(minY));
		var cw:Int = Std.int(Math.ceil(maxX)) - x;
		var ch:Int = Std.int(Math.ceil(maxY)) - y;
		if (cw <= 0 || ch <= 0) return skip(graphic, 'empty_bbox');
		if (cw >= bmp.width && ch >= bmp.height) return null;

		var savedRatio:Float = 1.0 - (cw * ch) / (bmp.width * bmp.height);
		if (savedRatio < minSavedRatio) return null;

		var started:Float = Timer.stamp();
		var oldBmp:BitmapData = bmp;
		var cropRect:Rectangle = new Rectangle(x, y, cw, ch);
		var cropped:BitmapData = null;
		var originalX:Array<Float> = [];
		var originalY:Array<Float> = [];
		var originalOffsetX:Array<Float> = [];
		var originalOffsetY:Array<Float> = [];
		var originalSourceW:Array<Float> = [];
		var originalSourceH:Array<Float> = [];

		try
		{
			cropped = cropRaw(oldBmp, cropRect);
			if (cropped == null) return fail(graphic, 'crop_alloc_failed');

			for (frame in frames.frames)
			{
				if (frame == null || frame.frame == null)
				{
					originalX.push(0);
					originalY.push(0);
					originalOffsetX.push(0);
					originalOffsetY.push(0);
					originalSourceW.push(0);
					originalSourceH.push(0);
					continue;
				}
				originalX.push(frame.frame.x);
				originalY.push(frame.frame.y);
				originalOffsetX.push(frame.offset.x);
				originalOffsetY.push(frame.offset.y);
				originalSourceW.push(frame.sourceSize.x);
				originalSourceH.push(frame.sourceSize.y);
			}

			graphic.bitmap = cropped;

			for (i in 0...frames.frames.length)
			{
				var frame = frames.frames[i];
				if (frame == null || frame.frame == null) continue;
				var r = frame.frame;
				r.x = originalX[i] - x;
				r.y = originalY[i] - y;
				frame.frame = r;
				@:privateAccess frame.cacheFrameMatrix();
			}

			if (!validate(graphic, frames, cropped, oldBmp, originalX, originalY,
				originalOffsetX, originalOffsetY, originalSourceW, originalSourceH))
			{
				rollback(graphic, oldBmp, cropped, frames, originalX, originalY);
				return fail(graphic, 'validation_failed:' + lastError);
			}

			graphic.bitmap = cropped;
			graphic.gfxCropRect = new Rectangle(x, y, cw, ch);
			graphic.gfxCropSource = source != null && source.length > 0 ? source : graphic.key;
			var beforeW:Int = oldBmp.width;
			var beforeH:Int = oldBmp.height;
			oldBmp.dispose();

			var ms:Float = (Timer.stamp() - started) * 1000;
			var keyName:String = source != null && source.length > 0 ? source : graphic.key;
			var line:String = 'key=' + (keyName == null ? '(null)' : keyName)
				+ ' crop=' + Std.string(x) + ',' + Std.string(y) + ',' + Std.string(cw) + 'x' + Std.string(ch)
				+ ' before=' + Std.string(beforeW) + 'x' + Std.string(beforeH)
				+ ' after=' + Std.string(cw) + 'x' + Std.string(ch)
				+ ' savedPct=' + Std.string(Math.round(savedRatio * 10000) / 100)
				+ ' frames=' + Std.string(frames.frames.length)
				+ ' ms=' + Std.string(Math.round(ms * 10) / 10)
				+ ' validate=OK';
			TraceManager.info('trace.gfx.atlasCrop', 'GfxAtlasCrop ' + line);
			#if sys
			if (Sys.getEnv('FNF_GFX_TRACE') == '1') Sys.println('[GfxAtlasCrop] ' + line);
			#end
			return graphic.gfxCropRect;
		}
		catch (e:Dynamic)
		{
			if (cropped != null) rollback(graphic, oldBmp, cropped, frames, originalX, originalY);
			return fail(graphic, Std.string(e));
		}
	}

	/**
	 * Byte-exact crop in the engine's BGRA buffer. copyPixels() round-trips the
	 * premultiplied alpha representation and can change RGB bytes of translucent
	 * pixels; this row memcpy cannot.
	 */
	public static function cropRaw(source:BitmapData, region:Rectangle):BitmapData
	{
		var w:Int = Std.int(region.width);
		var h:Int = Std.int(region.height);
		if (w <= 0 || h <= 0) return null;
		if (source.width == w && source.height == h && region.x == 0 && region.y == 0) return source;

		var transparent:Bool = source.image != null ? source.image.transparent : source.transparent;
		var out = new BitmapData(w, h, transparent, 0);
		var srcData = source.image != null ? source.image.buffer.data : null;
		var dstData = out.image != null ? out.image.buffer.data : null;
		if (srcData == null || dstData == null)
		{
			out.copyPixels(source, region, new Point(0, 0));
			return out;
		}

		var srcBytes = srcData.toBytes();
		var dstBytes = dstData.toBytes();
		var srcWidth:Int = source.width;
		var rx:Int = Std.int(region.x);
		var ry:Int = Std.int(region.y);
		var rowBytes:Int = w * 4;
		for (y in 0...h)
		{
			var srcOffset:Int = ((y + ry) * srcWidth + rx) * 4;
			var dstOffset:Int = y * rowBytes;
			// Bytes.blit(pos, src, srcpos, len) writes into the receiver.
			dstBytes.blit(dstOffset, srcBytes, srcOffset, rowBytes);
		}
		return out;
	}

	static function validate(graphic:FlxGraphic, frames:FlxAtlasFrames, cropped:BitmapData, oldBmp:BitmapData,
		originalX:Array<Float>, originalY:Array<Float>, originalOffsetX:Array<Float>, originalOffsetY:Array<Float>,
		originalSourceW:Array<Float>, originalSourceH:Array<Float>):Bool
	{
		var cw:Int = graphic.width;
		var ch:Int = graphic.height;
		for (i in 0...frames.frames.length)
		{
			var frame = frames.frames[i];
			if (frame == null || frame.frame == null) continue;
			var r = frame.frame;
			if (frame.parent != graphic) { lastError = 'parent:' + i; return false; }
			if (r.x < 0 || r.y < 0 || r.right > cw + 0.001 || r.bottom > ch + 0.001)
			{
				lastError = 'bounds:' + i + ':' + r.x + ',' + r.y + ',' + r.right + 'x' + r.bottom + ' canvas=' + cw + 'x' + ch;
				return false;
			}
			if (frame.type == FlxFrameType.EMPTY) continue;
			if (Math.abs(frame.offset.x - originalOffsetX[i]) > 0.0001 || Math.abs(frame.offset.y - originalOffsetY[i]) > 0.0001
				|| Math.abs(frame.sourceSize.x - originalSourceW[i]) > 0.0001 || Math.abs(frame.sourceSize.y - originalSourceH[i]) > 0.0001)
			{
				lastError = 'metadata:' + i;
				return false;
			}

			var ex:Float = r.x / cw;
			var ey:Float = r.y / ch;
			var er:Float = r.right / cw;
			var eb:Float = r.bottom / ch;
			if (Math.abs(frame.uv.x - ex) > 0.00001 || Math.abs(frame.uv.y - ey) > 0.00001
				|| Math.abs(frame.uv.width - er) > 0.00001 || Math.abs(frame.uv.height - eb) > 0.00001)
			{
				lastError = 'uv:' + i + ' got=' + frame.uv.x + ',' + frame.uv.y + ',' + frame.uv.width + 'x' + frame.uv.height
					+ ' exp=' + ex + ',' + ey + ',' + er + 'x' + eb;
				return false;
			}

			if (!sampleEqual(oldBmp, cropped, r, originalX[i], originalY[i]))
			{
				lastError = 'pixel:' + i + ' old=' + (originalX[i] - r.x) + ',' + (originalY[i] - r.y) + ' new=' + r.x + ',' + r.y;
				return false;
			}
		}
		return true;
	}

	static function sampleEqual(oldBmp:BitmapData, cropped:BitmapData, newRect:FlxRect, oldX:Float, oldY:Float):Bool
	{
		var w:Int = Std.int(newRect.width);
		var h:Int = Std.int(newRect.height);
		if (w <= 0 || h <= 0) return true;

		var px:Array<Int> = [0, w - 1, 0, w - 1, Std.int(w / 2)];
		var py:Array<Int> = [0, 0, h - 1, h - 1, Std.int(h / 2)];
		for (i in 0...px.length)
		{
			var sx:Int = Std.int(oldX) + px[i];
			var sy:Int = Std.int(oldY) + py[i];
			var nx:Int = Std.int(newRect.x) + px[i];
			var ny:Int = Std.int(newRect.y) + py[i];
			if (oldBmp.getPixel32(sx, sy) != cropped.getPixel32(nx, ny)) return false;
		}
		return true;
	}

	static function rollback(graphic:FlxGraphic, oldBmp:BitmapData, cropped:BitmapData, frames:FlxAtlasFrames,
		originalX:Array<Float>, originalY:Array<Float>):Void
	{
		if (graphic.bitmap != oldBmp) graphic.bitmap = oldBmp;
		var count:Int = Std.int(Math.min(originalX.length, frames.frames.length));
		for (i in 0...count)
		{
			var frame = frames.frames[i];
			if (frame == null || frame.frame == null) continue;
			var r = frame.frame;
			r.x = originalX[i];
			r.y = originalY[i];
			frame.frame = r;
			@:privateAccess frame.cacheFrameMatrix();
		}
		if (cropped != null) cropped.dispose();
	}

	static function skip(graphic:FlxGraphic, reason:String):Rectangle
	{
		#if sys
		if (Sys.getEnv('FNF_GFX_TRACE') == '1')
			Sys.println('[GfxAtlasCrop] skip key=' + (graphic.key == null ? '(null)' : graphic.key) + ' reason=' + reason);
		#end
		return null;
	}

	static function fail(graphic:FlxGraphic, reason:String):Rectangle
	{
		var line:String = 'key=' + (graphic == null || graphic.key == null ? '(null)' : graphic.key) + ' reason=' + reason + ' validate=ROLLBACK';
		TraceManager.warn('trace.gfx.atlasCropFail', 'GfxAtlasCrop ' + line);
		#if sys
		if (Sys.getEnv('FNF_GFX_TRACE') == '1') Sys.println('[GfxAtlasCrop] ' + line);
		#end
		return null;
	}

	static function isEnabled():Bool
	{
		if (!checked)
		{
			checked = true;
			#if sys
			enabled = Sys.getEnv('FNF_GFX_ATLAS_CROP') != '0';
			#end
		}
		return enabled;
	}
}
