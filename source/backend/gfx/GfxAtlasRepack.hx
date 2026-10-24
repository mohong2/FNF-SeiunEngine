package backend.gfx;

import flixel.graphics.FlxGraphic;
import flixel.graphics.frames.FlxAtlasFrames;
import flixel.graphics.frames.FlxFrame;
import flixel.graphics.frames.FlxFrame.FlxFrameAngle;
import flixel.graphics.frames.FlxFrame.FlxFrameType;
import flixel.math.FlxRect;
import haxe.Timer;
import haxe.io.Bytes;
import mohong.TraceManager;
import openfl.display.BitmapData;
import openfl.geom.Rectangle;

/** One unique trimmed cell. Coordinates are relative to the source bitmap. */
typedef GfxRepackCell = {
	var sx:Int;
	var sy:Int;
	var sw:Int;
	var sh:Int;
	var px:Int;
	var py:Int;
	var hash:String;
};

/** Per-frame metadata captured before the swap; used for rollback and restore checks. */
typedef GfxRepackFrame = {
	var name:String;
	var cell:Int;
	var trimX:Int;
	var trimY:Int;
	var offsetX:Float;
	var offsetY:Float;
	var sourceW:Float;
	var sourceH:Float;
	var rectX:Float;
	var rectY:Float;
	var rectW:Float;
	var rectH:Float;
};

/**
 * Persistent plan for a repacked atlas. The cells and their packed positions are
 * fixed. A CPU restore decodes the original file, applies the recorded crop (if
 * L2a ran), and copies these exact cells into these exact positions; it never
 * re-runs packing or deduplication.
 */
typedef GfxRepackPlan = {
	var sourceW:Int;
	var sourceH:Int;
	var hasCrop:Bool;
	var cropX:Int;
	var cropY:Int;
	var cropW:Int;
	var cropH:Int;
	var canvasW:Int;
	var canvasH:Int;
	var padding:Int;
	var cells:Array<GfxRepackCell>;
	var frames:Array<GfxRepackFrame>;
};

/**
 * L2b lossless atlas repack: per-frame alpha trim, content deduplication and
 * shelf packing. Frame names, order, count, offsets and sourceSize are preserved
 * semantically; only frame rects and UVs move. No scaling and no lossy codec is
 * used here.
 *
 * Every candidate is checked before the bitmap swap, and every frame is checked
 * again afterwards. Any error keeps the old bitmap and all old frame metadata.
 * Opt out with FNF_GFX_ATLAS_REPACK=0.
 */
class GfxAtlasRepack
{
	public static var enabled:Bool = true;
	public static var minSavedRatio:Float = 0.05;
	public static var padding:Int = 2;
	public static var maxDim:Int = 16384;
	static var checked:Bool = false;
	static var verifyRebuild:Bool = false;
	static var lastError:String = '';

	public static function apply(graphic:FlxGraphic, frames:FlxAtlasFrames, ?source:String):GfxRepackPlan
	{
		if (!isEnabled() || graphic == null || frames == null) return null;
		if (graphic.gfxRepackPlan != null) return cast graphic.gfxRepackPlan;

		lastError = '';
		var bmp:BitmapData = graphic.bitmap;
		if (bmp == null || !bmp.hasCPU || graphic.useCount > 0) return null;
		if (bmp.image == null || bmp.image.buffer == null || bmp.image.buffer.data == null) return skip(graphic, 'no_cpu_buffer');
		if (frames.frames == null || frames.frames.length == 0) return null;
		if (bmp.width <= 0 || bmp.height <= 0) return null;

		var oldBmp:BitmapData = bmp;
		var beforeW:Int = bmp.width;
		var beforeH:Int = bmp.height;
		var canvas:BitmapData = null;
		var swapped:Bool = false;
		var oldX:Array<Float> = [];
		var oldY:Array<Float> = [];
		var oldW:Array<Float> = [];
		var oldH:Array<Float> = [];
		var oldOffsetX:Array<Float> = [];
		var oldOffsetY:Array<Float> = [];
		var oldSourceW:Array<Float> = [];
		var oldSourceH:Array<Float> = [];
		var planFrames:Array<GfxRepackFrame> = [];
		var cells:Array<GfxRepackCell> = [];
		var hashByRect:Map<String, String> = new Map();
		var cellByRect:Map<String, Int> = new Map();
		var cellByHash:Map<String, Int> = new Map();

		var started:Float = Timer.stamp();
		try
		{
			var bytes:Bytes = bytesOf(bmp);
			if (bytes == null) return fail(graphic, 'no_cpu_bytes');

			for (i in 0...frames.frames.length)
			{
				var frame = frames.frames[i];
				if (frame == null || frame.type == FlxFrameType.EMPTY || frame.frame == null)
					return fail(graphic, 'empty_frame:' + i);
				if (frame.angle != FlxFrameAngle.ANGLE_0 || frame.flipX || frame.flipY)
					return fail(graphic, 'rotated_or_flipped:' + i);
				var r = frame.frame;
				if (!isInteger(r.x) || !isInteger(r.y) || !isInteger(r.width) || !isInteger(r.height))
					return fail(graphic, 'non_integer:' + i);
				var fx:Int = Std.int(Math.round(r.x));
				var fy:Int = Std.int(Math.round(r.y));
				var fw:Int = Std.int(Math.round(r.width));
				var fh:Int = Std.int(Math.round(r.height));
				if (fw <= 0 || fh <= 0) return fail(graphic, 'empty_frame:' + i);
				if (fx < 0 || fy < 0 || fx + fw > bmp.width || fy + fh > bmp.height)
					return fail(graphic, 'frame_out_of_bounds:' + i);

				var bounds = alphaBounds(bytes, bmp.width, fx, fy, fw, fh);
				if (bounds == null) return fail(graphic, 'empty_alpha:' + i);
				var trimX:Int = bounds.x - fx;
				var trimY:Int = bounds.y - fy;
				var tw:Int = bounds.w;
				var th:Int = bounds.h;
				if (tw <= 0 || th <= 0 || tw > fw || th > fh) return fail(graphic, 'bad_trim:' + i);

				var rectKey:String = bounds.x + ',' + bounds.y + ',' + tw + ',' + th;
				var cellIndex:Int = -1;
				if (cellByRect.exists(rectKey))
				{
					// Same bitmap region: no byte compare or hash needed.
					cellIndex = cellByRect.get(rectKey);
				}
				else
				{
					var hash:String = hashByRect.get(rectKey);
					if (hash == null)
					{
						hash = hashRegion(bytes, bmp.width, bounds.x, bounds.y, tw, th);
						hashByRect.set(rectKey, hash);
					}
					if (cellByHash.exists(hash))
					{
						cellIndex = cellByHash.get(hash);
						var existing = cells[cellIndex];
						if (existing.sw != tw || existing.sh != th
							|| !regionEqual(oldBmp, existing.sx, existing.sy, oldBmp, bounds.x, bounds.y, tw, th))
							return fail(graphic, 'hash_collision:' + i);
					}
					else
					{
						cellIndex = cells.length;
						cells.push({sx: bounds.x, sy: bounds.y, sw: tw, sh: th, px: 0, py: 0, hash: hash});
						cellByHash.set(hash, cellIndex);
					}
					cellByRect.set(rectKey, cellIndex);
				}

				oldX.push(r.x);
				oldY.push(r.y);
				oldW.push(r.width);
				oldH.push(r.height);
				oldOffsetX.push(frame.offset.x);
				oldOffsetY.push(frame.offset.y);
				oldSourceW.push(frame.sourceSize.x);
				oldSourceH.push(frame.sourceSize.y);
				planFrames.push({
					name: frame.name,
					cell: cellIndex,
					trimX: trimX,
					trimY: trimY,
					offsetX: frame.offset.x,
					offsetY: frame.offset.y,
					sourceW: frame.sourceSize.x,
					sourceH: frame.sourceSize.y,
					rectX: r.x,
					rectY: r.y,
					rectW: r.width,
					rectH: r.height
				});
			}

			if (cells.length == 0) return fail(graphic, 'no_cells');

			var layout = chooseLayout(cells, bmp.width, bmp.height);
			if (layout == null) return fail(graphic, 'pack_failed');

			var savedRatio:Float = 1.0 - (layout.w * layout.h) / (bmp.width * bmp.height);
			if (savedRatio < minSavedRatio) return skip(graphic, 'saved_below_min');

			var crop:Rectangle = graphic.gfxCropRect;
			var plan:GfxRepackPlan = {
				sourceW: bmp.width,
				sourceH: bmp.height,
				hasCrop: crop != null,
				cropX: crop != null ? Std.int(crop.x) : 0,
				cropY: crop != null ? Std.int(crop.y) : 0,
				cropW: crop != null ? Std.int(crop.width) : 0,
				cropH: crop != null ? Std.int(crop.height) : 0,
				canvasW: layout.w,
				canvasH: layout.h,
				padding: padding,
				cells: cells,
				frames: planFrames
			};

			canvas = buildCanvas(oldBmp, plan);
			if (canvas == null) return fail(graphic, 'canvas_build_failed');

			for (cell in cells)
			{
				if (!regionEqual(oldBmp, cell.sx, cell.sy, canvas, cell.px, cell.py, cell.sw, cell.sh))
				{
					canvas.dispose();
					return fail(graphic, 'cell_pixel_mismatch:' + cell.sx + ',' + cell.sy);
				}
			}

			if (verifyRebuild)
			{
				var rebuilt:BitmapData = buildCanvas(oldBmp, plan);
				if (rebuilt == null || !bitmapEqual(canvas, rebuilt))
				{
					if (rebuilt != null) rebuilt.dispose();
					canvas.dispose();
					return fail(graphic, 'rebuild_mismatch');
				}
				rebuilt.dispose();
			}

			swapped = true;
			graphic.bitmap = canvas;
			for (i in 0...frames.frames.length)
			{
				var frame = frames.frames[i];
				var r = frame.frame;
				var cell = cells[planFrames[i].cell];
				r.x = cell.px;
				r.y = cell.py;
				r.width = cell.sw;
				r.height = cell.sh;
				frame.frame = r;
				frame.offset.set(oldOffsetX[i] + planFrames[i].trimX, oldOffsetY[i] + planFrames[i].trimY);
				@:privateAccess frame.cacheFrameMatrix();
			}

			if (!validateAfter(graphic, frames, plan, oldBmp, canvas, oldOffsetX, oldOffsetY, oldSourceW, oldSourceH))
			{
				rollback(graphic, oldBmp, canvas, frames, oldX, oldY, oldW, oldH, oldOffsetX, oldOffsetY);
				swapped = false;
				return fail(graphic, 'validation_failed:' + lastError);
			}

			graphic.gfxRepackPlan = plan;
			if (graphic.gfxCropSource == null)
				graphic.gfxCropSource = source != null && source.length > 0 ? source : graphic.assetsKey;
			oldBmp.dispose();
			swapped = false;

			var ms:Float = (Timer.stamp() - started) * 1000;
			var keyName:String = source != null && source.length > 0 ? source : graphic.key;
			var line:String = 'key=' + (keyName == null ? '(null)' : keyName)
				+ ' before=' + Std.string(beforeW) + 'x' + Std.string(beforeH)
				+ ' after=' + Std.string(layout.w) + 'x' + Std.string(layout.h)
				+ ' frames=' + Std.string(frames.frames.length)
				+ ' unique=' + Std.string(cells.length)
				+ ' dup=' + Std.string(frames.frames.length - cells.length)
				+ ' padding=' + Std.string(padding)
				+ ' savedPct=' + Std.string(Math.round(savedRatio * 10000) / 100)
				+ ' ms=' + Std.string(Math.round(ms * 10) / 10)
				+ ' validate=OK';
			TraceManager.info('trace.gfx.atlasRepack', 'GfxAtlasRepack ' + line);
			#if sys
			if (Sys.getEnv('FNF_GFX_TRACE') == '1') Sys.println('[GfxAtlasRepack] ' + line);
			#end
			return plan;
		}
		catch (e:Dynamic)
		{
			if (swapped)
			{
				rollback(graphic, oldBmp, canvas, frames, oldX, oldY, oldW, oldH, oldOffsetX, oldOffsetY);
				swapped = false;
			}
			else if (canvas != null)
			{
				canvas.dispose();
			}
			return fail(graphic, Std.string(e));
		}
	}

	/**
	 * Rebuild the exact repacked bitmap from a freshly decoded source. This is
	 * called by GfxMemory after the CPU buffer was dropped; it never re-packs.
	 */
	public static function restore(sourceKey:String, plan:GfxRepackPlan):BitmapData
	{
		if (plan == null || plan.cells == null) return null;
		var fresh:BitmapData = GfxSource.load(sourceKey);
		if (fresh == null) return null;

		var base:BitmapData = fresh;
		if (plan.hasCrop)
		{
			base = GfxAtlasCrop.cropRaw(fresh, new Rectangle(plan.cropX, plan.cropY, plan.cropW, plan.cropH));
			if (base == null)
			{
				fresh.dispose();
				return null;
			}
			if (base != fresh) fresh.dispose();
		}
		if (base.width != plan.sourceW || base.height != plan.sourceH)
		{
			base.dispose();
			return null;
		}

		var canvas:BitmapData = buildCanvas(base, plan);
		if (canvas != base) base.dispose();
		return canvas;
	}

	static function chooseLayout(cells:Array<GfxRepackCell>, sourceW:Int, sourceH:Int):{w:Int, h:Int}
	{
		var order:Array<Int> = [];
		for (i in 0...cells.length) order.push(i);
		order.sort(function(a:Int, b:Int):Int
		{
			var ca = cells[a];
			var cb = cells[b];
			if (ca.sh != cb.sh) return ca.sh > cb.sh ? -1 : 1;
			if (ca.sw != cb.sw) return ca.sw > cb.sw ? -1 : 1;
			if (ca.hash < cb.hash) return -1;
			if (ca.hash > cb.hash) return 1;
			if (ca.sx != cb.sx) return ca.sx < cb.sx ? -1 : 1;
			if (ca.sy != cb.sy) return ca.sy < cb.sy ? -1 : 1;
			return 0;
		});

		var widest:Int = 0;
		var total:Int = 0;
		for (cell in cells)
		{
			if (cell.sw > widest) widest = cell.sw;
			total += (cell.sw + padding) * (cell.sh + padding);
		}
		var minWidth:Int = widest + padding * 2;
		if (minWidth > maxDim) return null;

		var widths:Array<Int> = [];
		addWidth(widths, minWidth, minWidth);
		for (columns in 1...(imin(12, cells.length) + 1))
			addWidth(widths, columns * (widest + padding) + padding, minWidth);
		addWidth(widths, Std.int(Math.ceil(Math.sqrt(total))), minWidth);
		addWidth(widths, sourceW, minWidth);
		addWidth(widths, sourceH, minWidth);
		addWidth(widths, maxDim, minWidth);

		// A coarse width sweep costs only a few thousand shelf passes and finds
		// layouts that the column/area guesses miss (e.g. a two-column page that
		// is much shorter than the single-column minimum width).
		var sweepLimit:Int = imin(maxDim, imax(sourceW, sourceH) * 2);
		var sweep:Int = minWidth;
		while (sweep <= sweepLimit)
		{
			addWidth(widths, sweep, minWidth);
			sweep += 16;
		}

		var bestWidth:Int = -1;
		var bestHeight:Int = -1;
		var bestArea:Int = 0;
		var bestMax:Int = 0;
		for (width in widths)
		{
			var height:Int = packShelf(order, cells, width, false);
			if (height <= 0 || height > maxDim) continue;
			var area:Int = width * height;
			var longest:Int = imax(width, height);
			if (bestWidth < 0 || area < bestArea || (area == bestArea && (longest < bestMax
				|| (longest == bestMax && height < bestHeight))))
			{
				bestWidth = width;
				bestHeight = height;
				bestArea = area;
				bestMax = longest;
			}
		}
		if (bestWidth < 0) return null;
		if (packShelf(order, cells, bestWidth, true) != bestHeight) return null;
		return {w: bestWidth, h: bestHeight};
	}

	static function addWidth(list:Array<Int>, value:Int, minWidth:Int):Void
	{
		if (value < minWidth) value = minWidth;
		if (value > maxDim) value = maxDim;
		if (value >= minWidth && value <= maxDim && list.indexOf(value) < 0) list.push(value);
	}

	static function packShelf(order:Array<Int>, cells:Array<GfxRepackCell>, width:Int, write:Bool):Int
	{
		var x:Int = padding;
		var y:Int = padding;
		var rowH:Int = 0;
		for (index in order)
		{
			var cell = cells[index];
			if (x + cell.sw + padding > width)
			{
				x = padding;
				y += rowH + padding;
				rowH = 0;
			}
			if (x + cell.sw + padding > width) return -1;
			if (write)
			{
				cell.px = x;
				cell.py = y;
			}
			x += cell.sw + padding;
			if (cell.sh > rowH) rowH = cell.sh;
		}
		return y + rowH + padding;
	}

	static function buildCanvas(base:BitmapData, plan:GfxRepackPlan):BitmapData
	{
		if (base == null || plan == null || plan.cells == null) return null;
		if (plan.canvasW <= 0 || plan.canvasH <= 0) return null;
		if (base.width != plan.sourceW || base.height != plan.sourceH) return null;
		if (validateCells(plan.cells, plan.canvasW, plan.canvasH, plan.padding) != null) return null;

		var src:Bytes = bytesOf(base);
		if (src == null) return null;

		var canvas = new BitmapData(plan.canvasW, plan.canvasH, true, 0);
		var dst:Bytes = bytesOf(canvas);
		if (dst == null)
		{
			canvas.dispose();
			return null;
		}

		for (cell in plan.cells)
		{
			if (cell.sx < 0 || cell.sy < 0 || cell.sx + cell.sw > base.width || cell.sy + cell.sh > base.height)
			{
				canvas.dispose();
				return null;
			}
			if (!copyRegion(src, base.width, cell.sx, cell.sy, dst, plan.canvasW, cell.px, cell.py, cell.sw, cell.sh))
			{
				canvas.dispose();
				return null;
			}
		}
		return canvas;
	}

	static function validateAfter(graphic:FlxGraphic, frames:FlxAtlasFrames, plan:GfxRepackPlan,
		oldBmp:BitmapData, canvas:BitmapData, oldOffsetX:Array<Float>, oldOffsetY:Array<Float>,
		oldSourceW:Array<Float>, oldSourceH:Array<Float>):Bool
	{
		if (graphic.bitmap != canvas || graphic.width != plan.canvasW || graphic.height != plan.canvasH)
		{
			lastError = 'canvas_link';
			return false;
		}
		if (frames.frames.length != plan.frames.length)
		{
			lastError = 'frame_count';
			return false;
		}
		var reason:String = validateCells(plan.cells, plan.canvasW, plan.canvasH, plan.padding);
		if (reason != null)
		{
			lastError = reason;
			return false;
		}

		for (i in 0...frames.frames.length)
		{
			var frame = frames.frames[i];
			var expected = plan.frames[i];
			var cell = plan.cells[expected.cell];
			if (frame == null || frame.frame == null)
			{
				lastError = 'null_frame:' + i;
				return false;
			}
			if (frame.parent != graphic)
			{
				lastError = 'parent:' + i;
				return false;
			}
			if (frame.name != expected.name)
			{
				lastError = 'name:' + i;
				return false;
			}
			if (frame.angle != FlxFrameAngle.ANGLE_0 || frame.flipX || frame.flipY)
			{
				lastError = 'orientation:' + i;
				return false;
			}
			var r = frame.frame;
			if (r.x != cell.px || r.y != cell.py || r.width != cell.sw || r.height != cell.sh)
			{
				lastError = 'rect:' + i;
				return false;
			}
			if (r.x < 0 || r.y < 0 || r.right > plan.canvasW + 0.001 || r.bottom > plan.canvasH + 0.001)
			{
				lastError = 'bounds:' + i;
				return false;
			}
			if (Math.abs(frame.offset.x - (oldOffsetX[i] + expected.trimX)) > 0.0001
				|| Math.abs(frame.offset.y - (oldOffsetY[i] + expected.trimY)) > 0.0001
				|| Math.abs(frame.sourceSize.x - oldSourceW[i]) > 0.0001
				|| Math.abs(frame.sourceSize.y - oldSourceH[i]) > 0.0001)
			{
				lastError = 'metadata:' + i;
				return false;
			}

			var ex:Float = r.x / plan.canvasW;
			var ey:Float = r.y / plan.canvasH;
			var er:Float = r.right / plan.canvasW;
			var eb:Float = r.bottom / plan.canvasH;
			if (Math.abs(frame.uv.x - ex) > 0.00001 || Math.abs(frame.uv.y - ey) > 0.00001
				|| Math.abs(frame.uv.width - er) > 0.00001 || Math.abs(frame.uv.height - eb) > 0.00001)
			{
				lastError = 'uv:' + i;
				return false;
			}

			if (!sampleEqual(oldBmp, canvas, expected.rectX + expected.trimX, expected.rectY + expected.trimY, r))
			{
				lastError = 'pixel:' + i;
				return false;
			}
		}
		return true;
	}

	static function rollback(graphic:FlxGraphic, oldBmp:BitmapData, canvas:BitmapData, frames:FlxAtlasFrames,
		oldX:Array<Float>, oldY:Array<Float>, oldW:Array<Float>, oldH:Array<Float>,
		oldOffsetX:Array<Float>, oldOffsetY:Array<Float>):Void
	{
		if (graphic.bitmap != oldBmp) graphic.bitmap = oldBmp;
		var count:Int = Std.int(Math.min(oldX.length, frames.frames.length));
		for (i in 0...count)
		{
			var frame = frames.frames[i];
			if (frame == null || frame.frame == null) continue;
			var r = frame.frame;
			r.x = oldX[i];
			r.y = oldY[i];
			r.width = oldW[i];
			r.height = oldH[i];
			frame.frame = r;
			frame.offset.set(oldOffsetX[i], oldOffsetY[i]);
			@:privateAccess frame.cacheFrameMatrix();
		}
		if (canvas != null) canvas.dispose();
	}

	static function validateCells(cells:Array<GfxRepackCell>, cw:Int, ch:Int, pad:Int):String
	{
		if (cw <= 0 || ch <= 0) return 'canvas_empty';
		if (cells == null || cells.length == 0) return 'no_cells';
		if (pad < 0) return 'bad_padding';
		for (i in 0...cells.length)
		{
			var a = cells[i];
			if (a.sw <= 0 || a.sh <= 0) return 'cell_empty:' + i;
			if (a.px < 0 || a.py < 0 || a.px + a.sw + pad > cw || a.py + a.sh + pad > ch)
				return 'cell_bounds:' + i;
			for (j in (i + 1)...cells.length)
			{
				var b = cells[j];
				var separated:Bool = a.px + a.sw + pad <= b.px || b.px + b.sw + pad <= a.px
					|| a.py + a.sh + pad <= b.py || b.py + b.sh + pad <= a.py;
				if (!separated) return 'cell_overlap:' + i + ':' + j;
			}
		}
		return null;
	}

	static function sampleEqual(oldBmp:BitmapData, canvas:BitmapData, oldX:Float, oldY:Float, rect:FlxRect):Bool
	{
		var w:Int = Std.int(rect.width);
		var h:Int = Std.int(rect.height);
		if (w <= 0 || h <= 0) return true;
		var px:Array<Int> = [0, w - 1, 0, w - 1, Std.int(w / 2)];
		var py:Array<Int> = [0, 0, h - 1, h - 1, Std.int(h / 2)];
		for (i in 0...px.length)
		{
			var sx:Int = Std.int(oldX) + px[i];
			var sy:Int = Std.int(oldY) + py[i];
			var nx:Int = Std.int(rect.x) + px[i];
			var ny:Int = Std.int(rect.y) + py[i];
			if (oldBmp.getPixel32(sx, sy) != canvas.getPixel32(nx, ny)) return false;
		}
		return true;
	}

	/**
	 * Fast 64-bit-ish content digest. It is only a candidate selector: an equal
	 * digest is always followed by a byte-exact compare, and a digest match with
	 * different bytes is treated as a collision and rolls the whole atlas back.
	 */
	static function hashRegion(bytes:Bytes, stride:Int, x:Int, y:Int, w:Int, h:Int):String
	{
		var h1:Int = 0x811c9dc5;
		var h2:Int = 0x9e3779b9;
		for (row in 0...h)
		{
			var base:Int = ((y + row) * stride + x) * 4;
			for (i in 0...w)
			{
				var v:Int = bytes.getInt32(base + i * 4);
				h1 = (h1 ^ v) * 16777619;
				h2 = (h2 + v) * 1103515245;
				h2 = h2 ^ (h2 >>> 13);
			}
		}
		return StringTools.hex(h1, 8) + StringTools.hex(h2, 8) + ':' + w + 'x' + h;
	}

	static function alphaBounds(bytes:Bytes, stride:Int, x:Int, y:Int, w:Int, h:Int):{x:Int, y:Int, w:Int, h:Int}
	{
		var minX:Int = w;
		var minY:Int = h;
		var maxX:Int = -1;
		var maxY:Int = -1;
		for (row in 0...h)
		{
			var base:Int = ((y + row) * stride + x) * 4;
			for (col in 0...w)
			{
				if (bytes.get(base + col * 4 + 3) != 0)
				{
					if (col < minX) minX = col;
					if (col > maxX) maxX = col;
					if (row < minY) minY = row;
					if (row > maxY) maxY = row;
				}
			}
		}
		if (maxX < 0 || maxY < 0) return null;
		return {x: x + minX, y: y + minY, w: maxX - minX + 1, h: maxY - minY + 1};
	}

	static function bytesOf(bmp:BitmapData):Bytes
	{
		if (bmp == null || bmp.image == null || bmp.image.buffer == null || bmp.image.buffer.data == null) return null;
		return bmp.image.buffer.data.toBytes();
	}

	static function regionEqual(a:BitmapData, ax:Int, ay:Int, b:BitmapData, bx:Int, by:Int, w:Int, h:Int):Bool
	{
		var ab:Bytes = bytesOf(a);
		var bb:Bytes = bytesOf(b);
		if (ab == null || bb == null) return false;
		var rowBytes:Int = w * 4;
		for (row in 0...h)
		{
			var ao:Int = ((ay + row) * a.width + ax) * 4;
			var bo:Int = ((by + row) * b.width + bx) * 4;
			for (i in 0...rowBytes)
			{
				if (ab.get(ao + i) != bb.get(bo + i)) return false;
			}
		}
		return true;
	}

	static function bitmapEqual(a:BitmapData, b:BitmapData):Bool
	{
		if (a == null || b == null || a.width != b.width || a.height != b.height) return false;
		var ab:Bytes = bytesOf(a);
		var bb:Bytes = bytesOf(b);
		if (ab == null || bb == null || ab.length != bb.length) return false;
		for (i in 0...ab.length)
		{
			if (ab.get(i) != bb.get(i)) return false;
		}
		return true;
	}

	static function copyRegion(src:Bytes, srcStride:Int, sx:Int, sy:Int, dst:Bytes, dstStride:Int, dx:Int, dy:Int, w:Int, h:Int):Bool
	{
		var rowBytes:Int = w * 4;
		for (row in 0...h)
		{
			var srcOffset:Int = ((sy + row) * srcStride + sx) * 4;
			var dstOffset:Int = ((dy + row) * dstStride + dx) * 4;
			if (srcOffset < 0 || dstOffset < 0 || srcOffset + rowBytes > src.length || dstOffset + rowBytes > dst.length) return false;
			dst.blit(dstOffset, src, srcOffset, rowBytes);
		}
		return true;
	}

	static inline function isInteger(value:Float):Bool
	{
		return Math.abs(value - Math.round(value)) <= 0.0001;
	}

	static inline function imin(a:Int, b:Int):Int return a < b ? a : b;
	static inline function imax(a:Int, b:Int):Int return a > b ? a : b;

	static function skip(graphic:FlxGraphic, reason:String):GfxRepackPlan
	{
		#if sys
		if (Sys.getEnv('FNF_GFX_TRACE') == '1')
			Sys.println('[GfxAtlasRepack] skip key=' + (graphic.key == null ? '(null)' : graphic.key) + ' reason=' + reason);
		#end
		return null;
	}

	static function fail(graphic:FlxGraphic, reason:String):GfxRepackPlan
	{
		lastError = reason;
		var line:String = 'key=' + (graphic == null || graphic.key == null ? '(null)' : graphic.key) + ' reason=' + reason + ' validate=ROLLBACK';
		TraceManager.warn('trace.gfx.atlasRepackFail', 'GfxAtlasRepack ' + line);
		#if sys
		if (Sys.getEnv('FNF_GFX_TRACE') == '1') Sys.println('[GfxAtlasRepack] ' + line);
		#end
		return null;
	}

	static function isEnabled():Bool
	{
		if (!checked)
		{
			checked = true;
			#if sys
			enabled = Sys.getEnv('FNF_GFX_ATLAS_REPACK') != '0';
			padding = envInt('FNF_GFX_ATLAS_REPACK_PADDING', padding, 0);
			maxDim = envInt('FNF_GFX_ATLAS_REPACK_MAX_DIM', maxDim, 1);
			verifyRebuild = Sys.getEnv('FNF_GFX_ATLAS_REPACK_VERIFY') == '1';
			#end
		}
		return enabled;
	}

	static function envInt(name:String, fallback:Int, minimum:Int):Int
	{
		#if sys
		var raw:String = Sys.getEnv(name);
		if (raw != null && raw.length > 0)
		{
			var parsed:Null<Int> = Std.parseInt(raw);
			if (parsed != null && parsed >= minimum) return parsed;
		}
		#end
		return fallback;
	}
}