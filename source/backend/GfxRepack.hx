package backend;

import openfl.display.BitmapData;
import openfl.geom.Rectangle;
import openfl.geom.Point;
import lime.utils.UInt8Array;
import mohong.TraceManager;

#if sys
import sys.FileSystem;
import sys.io.File;
#end

typedef RepackFrame =
{
	var idx:Int;
	var name:String;
	var sx:Int;
	var sy:Int;
	var sw:Int;
	var sh:Int;
	// How far the region extends past the sheet bounds (right/bottom).
	var oobR:Int;
	var oobB:Int;
	var hasTrim:Bool; // true when the node has a frameX attribute
	var fx:Int;
	var fy:Int;
	var fw:Int;
	var fh:Int;
	// Opaque bounding box inside the region.
	var dx:Int;
	var dy:Int;
	var dw:Int;
	var dh:Int;
	// Fully transparent frame: rendered as nothing in the original too.
	var empty:Bool;
	var px:Int;
	var py:Int;
}

typedef RepackResult =
{
	var bmp:BitmapData;
	var xml:String;
	var oldBytes:Float;
	var newBytes:Float;
	var ms:Float;
}

class GfxRepack
{
	public static inline var GAP:Int = 2;
	public static inline var MAX_TEX_DIM:Int = 16384;

	// Placement strategies tried by selectLayout(). STRAT_SHELF_H is the original
	// packer; the other two are extra candidates whose layouts are adopted only when
	// their area is *strictly* smaller than the incumbent's.
	static inline var STRAT_SHELF_H:Int = 0; // shelf, tallest-first (the original)
	static inline var STRAT_SHELF_W:Int = 1; // shelf, widest-first
	static inline var STRAT_SKYLINE:Int = 2; // skyline bottom-left

	// Bounds on the extra-candidate phase. The chooser deliberately reads no clock: a
	// time-based cut-off would make the chosen layout depend on machine speed and frame
	// load, so a context-loss rebuild (repackForRestore) could pick a different layout
	// than the original load and leave the packed bitmap paired with another layout's
	// XML. Integer counters behave identically on every platform and every run.
	static inline var MAX_EXTRA_COMBOS:Int = 24;      // candidate layouts evaluated
	static inline var MAX_EXTRA_VISITS:Int = 600000;  // rect visits charged to the phase
	static inline var SKYLINE_VISIT_ESTIMATE:Int = 8; // skyline steps charged per rect
	// Per-candidate cap inside the skyline packer. Its cost is O(rects x skyline
	// segments); a candidate that burns this many inner steps reports "does not fit"
	// (-1), which keeps the incumbent layout and can never make the result worse.
	static inline var SKYLINE_WORK_LIMIT:Int = 500000;
	// The extra phase is skipped above this many unique rects. Its preparation cost (one
	// O(n log n) re-order plus O(rects x skyline segments) scans) grows with the sheet:
	// a 19k-rect sheet measured ~41 ms on hxcpp for candidates that could not improve
	// anything. Above the cap only the historical four-width shelf search runs. The
	// largest atlas shipped with this project has 185 unique rects.
	static inline var EXTRA_MAX_RECTS:Int = 4096;
	// Comparison cap for the post-selection geometry check. A layout with every cell in
	// one column makes the candidate-pair count O(n^2); reaching the cap rejects the new
	// layout and returns the historical shelf layout instead, so a layout is never
	// accepted unchecked.
	static inline var LAYOUT_CHECK_BUDGET:Int = 8000000;

	public static var triedTotal:Int = 0;
	public static var okTotal:Int = 0;
	public static var fallbackTotal:Int = 0;
	static var lastBoundsSkips:Int = 0;
	public static var oldBytesTotal:Float = 0;
	public static var newBytesTotal:Float = 0;
	public static var msTotal:Float = 0;
	// Enhanced-search telemetry: candidates evaluated, how many of them won, how often a
	// cap stopped the search, and how many rect visits the phase charged.
	public static var extraCombosTotal:Int = 0;
	public static var extraWinsTotal:Int = 0;
	public static var extraCapHitsTotal:Int = 0;
	public static var extraVisitsTotal:Int = 0;
	// Post-selection geometry checks: how many ran (new-strategy layout wins only) and how
	// many rejected their layout and returned the historical shelf result instead.
	public static var layoutChecksTotal:Int = 0;
	public static var layoutCheckFailsTotal:Int = 0;

	// Exact cache key -> packed pair. Never normalized: alias keys can hold
	// different objects, pairing must follow the object's creation key.
	static var packedXmls:Map<String, {xml:String, filePath:String, cw:Int, ch:Int}> = [];

	static var wmTried:Int = 0;
	static var wmOk:Int = 0;
	static var wmOld:Float = 0;
	static var wmNew:Float = 0;

	/** Register the rewritten XML for a materialized key (before caching it). */
	public static function registerPackedXml(cacheKey:String, xml:String, filePath:String, canvasW:Int, canvasH:Int):Void
	{
		if (cacheKey == null || xml == null) return;
		packedXmls.set(cacheKey, {xml: xml, filePath: filePath, cw: canvasW, ch: canvasH});
	}

	/** True while a packed bitmap for this exact key is alive. */
	public static function isPacked(cacheKey:String):Bool
	{
		return cacheKey != null && packedXmls.exists(cacheKey);
	}

	/** Drop the pair when its packed bitmap goes away (LRU eviction). */
	public static function forgetPair(cacheKey:String):Void
	{
		if (cacheKey != null) packedXmls.remove(cacheKey);
	}

	/**
	 * Serve the paired XML for a packed graphic. Not gated by the option:
	 * a packed bitmap must always be paired with its packed XML.
	 * Dimension mismatch means the packed bitmap was replaced -> drop the
	 * stale pair and serve the original XML instead.
	 */
	public static function applyPackedXml(originalXml:String, graphic:flixel.graphics.FlxGraphic):String
	{
		if (graphic == null || graphic.key == null) return originalXml;
		var entry = packedXmls.get(graphic.key);
		if (entry == null) return originalXml;
		if (graphic.width != entry.cw || graphic.height != entry.ch)
		{
			packedXmls.remove(graphic.key);
			TraceManager.warn('trace.gfx.repairPair',
				'GfxRepack pair dims mismatch for {} ({}x{} != {}x{}) — dropped, serving original',
				[graphic.key, graphic.width, graphic.height, entry.cw, entry.ch]);
			return originalXml;
		}
		return entry.xml;
	}

	/** Rebuild the same packed layout after a context-loss reload from disk. */
	public static function repackForRestore(requestedKey:String, fresh:BitmapData):BitmapData
	{
		if (fresh == null || requestedKey == null) return fresh;
		var entry = packedXmls.get(requestedKey);
		if (entry == null) return fresh;
		var r = coreProcess(entry.filePath, fresh);
		if (r != null)
		{
			// The pair is rebuilt from this call's own outputs, so the cached bitmap and XML
			// always describe the same layout even if a layout decision ever becomes
			// non-deterministic.
			packedXmls.set(requestedKey, {xml: r.xml, filePath: entry.filePath, cw: r.bmp.width, ch: r.bmp.height});
			return r.bmp;
		}
		TraceManager.warn('trace.gfx.repackRestoreFail',
			'GfxRepack restore rebuild failed for {} — frames may mismatch', [requestedKey]);
		return fresh;
	}

	/** Ledger line since the last write (same watermark scheme as GfxLru). */
	public static function ledgerDeltaLine():String
	{
		var dTried = triedTotal - wmTried;
		var dOk = okTotal - wmOk;
		var dOld = oldBytesTotal - wmOld;
		var dNew = newBytesTotal - wmNew;
		wmTried = triedTotal;
		wmOk = okTotal;
		wmOld = oldBytesTotal;
		wmNew = newBytesTotal;

		var pct = dOld > 0 ? Std.string(Math.round((1 - dNew / dOld) * 1000) / 10) : '0';
		return 'repack: batch=${dOk}/${dTried}tried'
			+ ' ${fl(dOld / 1048576)}→${fl(dNew / 1048576)} MB (-${pct}%)'
			+ ' session_ok=${okTotal} fallback=${fallbackTotal}'
			+ ' avg_ms=${fl(okTotal > 0 ? msTotal / okTotal : 0)}';
	}

	/** Worker entry point. Returns null to fall back to the original path. */
	public static function process(cacheKey:String, filePath:String, src:BitmapData):Null<RepackResult>
	{
		#if sys
		if (!ClientPrefs.data.gfxRuntimeRepack) return null;
		return coreProcess(filePath, src);
		#else
		return null;
		#end
	}

	// Deterministic aborts throw a reason string; the single catch below counts
	// one fallback and logs one warning per attempt (ledger stays consistent).
	static function coreProcess(filePath:String, src:BitmapData):Null<RepackResult>
	{
		#if sys
		var t0 = haxe.Timer.stamp();
		try
		{
			if (filePath == null || src == null || !src.readable)
				return null;

			if (src.width < GfxPolicy.minDimension && src.height < GfxPolicy.minDimension)
				return null;

			// No sibling XML means a whole image rather than an atlas. Cropping its transparent
			// border would shift every visible pixel (flixel positions the graphic by its
			// origin), i.e. a real visual change, so it is deliberately not attempted: without
			// an XML there is no repack, and the image itself is never modified.
			var xmlPath = swapExt(filePath, '.xml');
			if (xmlPath == null || !FileSystem.exists(xmlPath)) return null;
			var xmlContent = File.getContent(xmlPath);

			triedTotal++;

			// Strip UTF-8 BOM (mod tools emit it; Xml.parse rejects it).
			if (xmlContent != null && xmlContent.length > 0 && StringTools.fastCodeAt(xmlContent, 0) == 0xFEFF)
				xmlContent = xmlContent.substr(1);

			var parsed = parseAtlas(xmlContent, src.width, src.height);

			// Only sheets where EVERY entry carries trim metadata get cropped;
			// others are moved verbatim (dedup only) — zero semantic drift.
			var trimEligible = true;
			for (f in parsed.frames)
			{
				if (!f.hasTrim)
				{
					trimEligible = false;
					break;
				}
			}

			if (trimEligible)
			{
				// Decoded buffers are premultiplied BGRA on sys; alpha is byte 3.
				if (src.image == null || src.image.buffer == null)
					abort('pixel-buffer-unavailable');
				var imgData = src.image.buffer.data;
				if (imgData == null || imgData.length < src.width * src.height * 4)
					abort('pixel-buffer-too-small');
				for (f in parsed.frames)
				{
					scanBBox(f, imgData, src.width, src.height);
					if (f.dw <= 0 || f.dh <= 0)
					{
						// Fully transparent frame: keep a tiny empty slot.
						f.empty = true;
						f.dx = 0;
						f.dy = 0;
						f.dw = GAP;
						f.dh = GAP;
					}
				}

				// Grow boxes past the sheet edge so packed cells reproduce the
				// edge-stretch look of GL CLAMP_TO_EDGE sampling.
				for (f in parsed.frames)
				{
					if (f.empty) continue;
					if (f.oobR > 0 && f.sx + f.dx + f.dw >= src.width)
					{
						var slack = f.sw - (f.dx + f.dw);
						f.dw += f.oobR < slack ? f.oobR : slack;
					}
					if (f.oobB > 0 && f.sy + f.dy + f.dh >= src.height)
					{
						var slackB = f.sh - (f.dy + f.dh);
						f.dh += f.oobB < slackB ? f.oobB : slackB;
					}
				}
			}
			else
			{
				for (f in parsed.frames)
				{
					if (f.oobR > 0 || f.oobB > 0)
						abort('oob-without-trim-metadata "' + f.name + '"');
					f.dx = 0;
					f.dy = 0;
					f.dw = f.sw;
					f.dh = f.sh;
				}
			}

			// Dedup: FNF animations reuse the same source rect many times.
			var canonByKey:Map<String, RepackFrame> = [];
			var order:Array<RepackFrame> = [];
			for (f in parsed.frames)
			{
				var key = rectKey(f);
				if (!canonByKey.exists(key))
				{
					canonByKey.set(key, f);
					order.push(f);
				}
			}

			order.sort(function(a:RepackFrame, b:RepackFrame):Int
			{
				if (a.dh != b.dh) return b.dh - a.dh;
				if (a.dw != b.dw) return b.dw - a.dw;
				return a.idx - b.idx;
			});

			var oldB:Float = src.width * src.height * 4;
			var sel = selectLayout(order, oldB, src.width);

			// Geometry gate (overlap and out-of-bounds). Only layouts from the extra strategies
			// need it; the historical shelf layout comes from the original code path. The XML
			// read-back check further down validates semantics only and cannot see two cells
			// covering each other or a cell placed outside the canvas, either of which would
			// make a mod animation render a neighbouring frame's pixels. A layout that fails
			// the check is replaced by the historical shelf result, so it is never returned.
			var gate = gateLayout(sel.w, sel.h, sel.order, sel.strat, sel.baseW, sel.baseH, order);
			if (gate.violation != null)
			{
				TraceManager.warn('trace.gfx.repackLayout',
					'GfxRepack rejected {} layout for {} ({}x{}): {} -- falling back to the historical shelf layout',
					[stratName(sel.strat), filePath, sel.w, sel.h, gate.violation]);
			}
			var canvasW = gate.w;
			var canvasH = gate.h;
			if (canvasW == 0)
				abort(gate.violation != null
					? ('layout-check-failed-and-baseline-had-no-win: ' + gate.violation)
					: ('no-area-win (src ${src.width}x${src.height}, ${parsed.frames.length} entries/${order.length} unique, ${sel.baseWidths} base widths + ${sel.combos} extra combos)'));
			// selectLayout() returns with the winning layout already written to the frames, so the
			// gate above inspected the real rectangles. This replay stays because the fallback
			// path substitutes the historical shelf baseline and because it keeps the write loop
			// independent of that behaviour; on an accepted layout it re-writes the same values.
			tryPack(gate.order, canvasW, gate.strat);

			for (f in parsed.frames)
			{
				var c = canonByKey.get(rectKey(f));
				f.px = c.px;
				f.py = c.py;
			}

			// 源图没有可读像素时, 逐块跳过只会得到一张全透明的图集 —— 那比不打包更糟。
			// 整块放弃, 调用方保留原图。
			if (src == null || !src.readable)
				abort('source-not-readable');

			var packed = new BitmapData(canvasW, canvasH, true, 0);
			// 加固: 打包画布是这一整套里唯一的大块写入目标。如果分配被平台钳制
			// (尺寸超过 GPU/驱动上限时 lime 可能给一个更小的位图), 后面每一次 copyPixels
			// 都会写到真正的缓冲区外面 —— 那是直接踩坏堆、随后在 GC 标记阶段炸成
			// ACCESS_VIOLATION (read at 0xFFFFFFFFFFFFFFFF) 的典型路径。
			// 宁可放弃重打包(调用方保留原图)也绝不越界写。
			if (packed == null || packed.width != canvasW || packed.height != canvasH)
			{
				abort('canvas-clamped ' + (packed == null ? 'null' : (packed.width + 'x' + packed.height))
					+ ' requested ' + canvasW + 'x' + canvasH);
			}
			for (f in order)
			{
				if (f.empty) continue;
				var sxp = f.sx + f.dx;
				var syp = f.sy + f.dy;
				var validW = src.width - sxp;
				if (validW > f.dw) validW = f.dw;
				if (validW < 0) validW = 0;
				var validH = src.height - syp;
				if (validH > f.dh) validH = f.dh;
				if (validH < 0) validH = 0;

				if (validW > 0 && validH > 0)
					blit(packed, src, sxp, syp, validW, validH, f.px, f.py, canvasW, canvasH);

				// Out-of-bounds bands: replicate the last real row/column,
				// matching what CLAMP_TO_EDGE sampling shows in the original.
				var extR = f.dw - validW;
				if (extR > 0 && validH > 0)
				{
					var colX = sxp + validW - 1;
					for (cx in 0...extR)
						blit(packed, src, colX, syp, 1, validH, f.px + validW + cx, f.py, canvasW, canvasH);
				}
				var extB = f.dh - validH;
				if (extB > 0 && validW > 0)
				{
					var rowY = syp + validH - 1;
					for (cy in 0...extB)
						blit(packed, src, sxp, rowY, validW, 1, f.px, f.py + validH + cy, canvasW, canvasH);
				}
				if (extR > 0 && extB > 0)
				{
					var cX = sxp + validW - 1;
					var cY = syp + validH - 1;
					for (cy in 0...extB)
						for (cx in 0...extR)
							blit(packed, src, cX, cY, 1, 1, f.px + validW + cx, f.py + validH + cy, canvasW, canvasH);
				}
			}

			// Rewrite the XML: geometry changes, everything else preserved.
			var rootName:String = parsed.rootName;
			var rootAttrs:String = parsed.rootAttrs;
			var out = '<?xml version="1.0" encoding="utf-8"?>\n<$rootName$rootAttrs>\n';
			for (f in parsed.frames)
			{
				out += buildSubTexture(parsed.nodes[f.idx], f, trimEligible);
			}
			out += '</$rootName>\n';

			// Self-check: parse the emitted XML back and assert per-frame
			// sourceSize/content placement match the original semantics.
			var selfCheckFail:Null<String> = null;
			try
			{
				var chk = Xml.parse(out).firstElement();
				var i = 0;
				for (node in chk.elements())
				{
					if (node.nodeName != 'SubTexture') continue;
					if (i >= parsed.frames.length) break;
					var f = parsed.frames[i];
					var nfx:Float = node.exists('frameX') ? Std.parseFloat(node.get('frameX')) : 0;
					var nfy:Float = node.exists('frameY') ? Std.parseFloat(node.get('frameY')) : 0;
					var nfw:Float = node.exists('frameWidth') ? Std.parseFloat(node.get('frameWidth')) : (trimEligible ? 0 : f.dw);
					var nfh:Float = node.exists('frameHeight') ? Std.parseFloat(node.get('frameHeight')) : (trimEligible ? 0 : f.dh);
					var ofx:Float = f.hasTrim ? -f.fx : 0;
					var ofy:Float = f.hasTrim ? -f.fy : 0;
					var ssw:Float = f.hasTrim ? f.fw : f.sw;
					var ssh:Float = f.hasTrim ? f.fh : f.sh;
					if (!(ofx + f.dx == -nfx && ofy + f.dy == -nfy))
						selfCheckFail = 'selfcheck content-TL frame #' + i + ' "' + f.name + '"';
					else if (!(nfw == ssw && nfh == ssh))
						selfCheckFail = 'selfcheck sourceSize frame #' + i + ' "' + f.name + '"';
					if (selfCheckFail != null) break;
					i++;
				}
			}
			catch (e:Dynamic)
			{
				selfCheckFail = 'selfcheck-parse $e';
			}
			if (selfCheckFail != null)
				abort(selfCheckFail);

			if (boundsSkips != lastBoundsSkips)
			{
				TraceManager.warn('trace.gfx.repackBounds',
					'GfxRepack skipped {} out-of-bounds blit(s) for {} -- packed canvas kept clean',
					[Std.string(boundsSkips - lastBoundsSkips), filePath]);
				lastBoundsSkips = boundsSkips;
			}
			msTotal += (haxe.Timer.stamp() - t0) * 1000;
			okTotal++;
			oldBytesTotal += oldB;
			newBytesTotal += canvasW * canvasH * 4;

			return {
				bmp: packed,
				xml: out,
				oldBytes: oldB,
				newBytes: canvasW * canvasH * 4,
				ms: (haxe.Timer.stamp() - t0) * 1000
			};
		}
		catch (e:Dynamic)
		{
			fallbackTotal++;
			TraceManager.warn('trace.gfx.repackSkip',
				'GfxRepack skip {} : {}', [filePath, Std.string(e)]);
			return null;
		}
		#end
		return null;
	}

	/** 画布/源矩形越界次数: 正常输入下永远是 0, 一旦不为 0 就是打包算法出问题了。 */
	public static var boundsSkips:Int = 0;

	/**
	 * 唯一允许写入打包画布的入口。
	 * 目标矩形必须完整落在画布里、源矩形必须完整落在原图里, 否则跳过并计数 ——
	 * 绝不把像素写到缓冲区外面(那是堆破坏, 之后会在 GC 里以 ACCESS_VIOLATION 呈现)。
	 * 合法输入下与原来直接 copyPixels 完全等价。
	 */
	// Reusable scratch for blit(). blit() runs once per packed cell plus once per
	// replicated out-of-bounds column or row -- a 5k-entry atlas reaches tens of
	// thousands of calls, and allocating a Rectangle and a Point per call was pure
	// garbage. openfl's BitmapData.copyPixels only reads these two objects synchronously
	// (Image.copyPixels copies the values into its own cached lime Rectangle/Vector2
	// before the pixel run), so one reused pair is safe: both are rewritten before every
	// call and blit() never re-enters itself. process() only runs on the main thread, and
	// the GfxPolicy/GfxLru byte ledgers plus packedXmls/boundsSkips above rely on the
	// same single-threaded execution.
	static var blitSrcRect:Rectangle = new Rectangle(0, 0, 0, 0);
	static var blitDstPoint:Point = new Point(0, 0);

	static inline function blit(packed:BitmapData, src:BitmapData, sx:Int, sy:Int, sw:Int, sh:Int,
		dx:Int, dy:Int, canvasW:Int, canvasH:Int):Void
	{
		if (sw <= 0 || sh <= 0) return;
		// 源图必须还带着 CPU 像素: gfxCpuRelease 会把大图的 CPU 副本释放掉,
		// 对着一张只剩显存纹理的位图 copyPixels 就是读已经释放的内存。
		if (src == null || !src.readable) { boundsSkips++; return; }
		if (dx < 0 || dy < 0 || dx + sw > canvasW || dy + sh > canvasH) { boundsSkips++; return; }
		if (sx < 0 || sy < 0 || sx + sw > src.width || sy + sh > src.height) { boundsSkips++; return; }
		blitSrcRect.setTo(sx, sy, sw, sh);
		blitDstPoint.setTo(dx, dy);
		packed.copyPixels(src, blitSrcRect, blitDstPoint);
	}

	static function abort(reason:String):Void
	{
		throw reason;
	}

	static function rectKey(f:RepackFrame):String
	{
		if (f.empty) return 'empty';
		return (f.sx + f.dx) + ',' + (f.sy + f.dy) + ',' + f.dw + ',' + f.dh;
	}

	static function addWidth(cands:Array<Int>, w:Int):Void
	{
		if (w >= GAP * 4 && w <= MAX_TEX_DIM && cands.indexOf(w) < 0)
			cands.push(w);
	}

	static function parseAtlas(xmlContent:String, imgW:Int, imgH:Int):{frames:Array<RepackFrame>, nodes:Array<Xml>, rootName:String, rootAttrs:String}
	{
		var doc;
		try
		{
			doc = Xml.parse(xmlContent);
		}
		catch (e:Dynamic)
		{
			abort('parse: xml-parse-error $e');
			return null;
		}

		var root = doc.firstElement();
		if (root == null)
			abort('parse: no-root-element');

		var nodes:Array<Xml> = [];
		for (el in root.elements())
		{
			if (el.nodeType == Xml.Element && el.nodeName == 'SubTexture')
				nodes.push(el);
		}
		if (nodes.length == 0)
			abort('parse: zero-subtextures (root=' + root.nodeName + ')');

		var rootName = root.nodeName;
		var rootAttrs = '';
		for (a in root.attributes())
			rootAttrs += ' $a="${esc(root.get(a))}"';

		var frames:Array<RepackFrame> = [];
		var idx = 0;
		for (node in nodes)
		{
			var fname = node.exists('name') ? node.get('name') : ('#$idx');

			if ((node.exists('rotated') && node.get('rotated') == 'true')
				|| (node.exists('flipX') && node.get('flipX') == 'true')
				|| (node.exists('flipY') && node.get('flipY') == 'true'))
				abort('parse: rotated/flipped frame "$fname"');

			var rx = attrInt(node, 'x');
			var ry = attrInt(node, 'y');
			var rw = attrInt(node, 'width');
			var rh = attrInt(node, 'height');
			if (rx < 0 || ry < 0 || rw <= 0 || rh <= 0)
				abort('parse: bad/missing x/y/w/h on "$fname"');

			var oobR = rx + rw > imgW ? rx + rw - imgW : 0;
			var oobB = ry + rh > imgH ? ry + rh - imgH : 0;

			var hasTrim = node.exists('frameX');
			var fx = attrInt(node, 'frameX');
			var fy = attrInt(node, 'frameY');
			var fw = attrInt(node, 'frameWidth');
			var fh = attrInt(node, 'frameHeight');

			frames.push({
				idx: idx,
				name: fname,
				sx: rx, sy: ry, sw: rw, sh: rh,
				oobR: oobR, oobB: oobB,
				hasTrim: hasTrim,
				fx: fx, fy: fy, fw: fw, fh: fh,
				dx: 0, dy: 0, dw: 0, dh: 0,
				empty: false,
				px: 0, py: 0
			});
			idx++;
		}
		return {frames: frames, nodes: nodes, rootName: rootName, rootAttrs: rootAttrs};
	}

	static function scanBBox(f:RepackFrame, data:UInt8Array, imgW:Int, imgH:Int):Void
	{
		var rows = f.sh;
		var limH = imgH - f.sy;
		if (rows > limH) rows = limH;
		var cols = f.sw;
		var limW = imgW - f.sx;
		if (cols > limW) cols = limW;

		var minX = -1;
		var maxX = -1;
		var minY = -1;
		var maxY = -1;
		for (ry in 0...rows)
		{
			var p = ((f.sy + ry) * imgW + f.sx) * 4 + 3;
			var rowMin = -1;
			var rowMax = -1;
			for (rx in 0...cols)
			{
				if (data[p] != 0)
				{
					if (rowMin < 0) rowMin = rx;
					rowMax = rx;
				}
				p += 4;
			}
			if (rowMin >= 0)
			{
				if (minY < 0) minY = ry;
				maxY = ry;
				if (minX < 0 || rowMin < minX) minX = rowMin;
				if (rowMax > maxX) maxX = rowMax;
			}
		}
		if (minX < 0 || minY < 0)
		{
			f.dx = 0; f.dy = 0; f.dw = 0; f.dh = 0;
			return;
		}
		f.dx = minX;
		f.dy = minY;
		f.dw = maxX - minX + 1;
		f.dh = maxY - minY + 1;
	}

	// Skyline scratch, reused across candidates and atlases so no candidate allocates.
	// Single-threaded like packedXmls/boundsSkips above: process() runs only on the main
	// thread.
	static var skX:Array<Int> = [];
	static var skY:Array<Int> = [];
	static var skW:Array<Int> = [];
	static var skOutX:Array<Int> = [];
	static var skOutY:Array<Int> = [];
	static var skOutW:Array<Int> = [];
	static var skCount:Int = 0;

	static function ensureSkyline(cap:Int):Void
	{
		while (skX.length < cap)
		{
			skX.push(0);
			skY.push(0);
			skW.push(0);
			skOutX.push(0);
			skOutY.push(0);
			skOutW.push(0);
		}
	}

	static function tryPack(order:Array<RepackFrame>, width:Int, strategy:Int):Int
	{
		if (strategy == STRAT_SKYLINE) return tryPackSkyline(order, width);
		return tryPackShelf(order, width);
	}

	/** Shelf placement: the original packer's algorithm, unchanged. */
	static function tryPackShelf(order:Array<RepackFrame>, width:Int):Int
	{
		var x = GAP;
		var y = GAP;
		var rowH = 0;
		for (f in order)
		{
			if (f.dw > width - GAP) return -1;
			if (x + f.dw > width)
			{
				x = GAP;
				y += rowH + GAP;
				rowH = 0;
			}
			if (y + f.dh > MAX_TEX_DIM) return -1;
			f.px = x;
			f.py = y;
			x += f.dw + GAP;
			if (f.dh > rowH) rowH = f.dh;
		}
		return y + rowH + GAP;
	}

	/**
	 * Skyline bottom-left placement. Writes f.px/f.py and returns the canvas height, or -1
	 * when the sheet cannot fit, exactly as the shelf packer does. Cells are reserved as
	 * (dw+GAP) x (dh+GAP) inside the usable rectangle [0, width-GAP) and every cell is
	 * then offset by +GAP, so each packed cell keeps at least a GAP-wide transparent margin
	 * on all four sides. The shelf packer guarantees that for the top, left and bottom
	 * edges and may let a cell touch the right edge, so this is never a weaker spacing
	 * guarantee: it can only shrink the canvas, never change which pixels a frame samples.
	 */
	static function tryPackSkyline(order:Array<RepackFrame>, width:Int):Int
	{
		var uw = width - GAP;
		if (uw <= 0) return -1;
		ensureSkyline(order.length + 2);

		// Per-candidate work cap, no clock involved. A candidate that burns the budget
		// reports "does not fit", so the incumbent layout is kept.
		var work = SKYLINE_WORK_LIMIT;
		skX[0] = 0;
		skY[0] = 0;
		skW[0] = uw;
		skCount = 1;

		for (f in order)
		{
			var rw = f.dw + GAP;
			var rh = f.dh + GAP;
			if (rw > uw) return -1;

			// Lowest skyline slot wins; ties keep the leftmost one.
			var bestX = -1;
			var bestY = 0;
			var i = 0;
			while (i < skCount)
			{
				if (--work < 0) return -1;
				var cx = skX[i];
				if (cx + rw > uw) break; // segments are sorted by x
				var y = 0;
				var left = rw;
				var k = i;
				while (left > 0 && k < skCount)
				{
					if (--work < 0) return -1;
					if (skY[k] > y) y = skY[k];
					left -= skW[k];
					k++;
				}
				if (left > 0) break; // unreachable: segments tile [0, uw)
				if (bestX < 0 || y < bestY)
				{
					bestX = cx;
					bestY = y;
				}
				i++;
			}
			if (bestX < 0) return -1;
			if (bestY + rh + 2 * GAP > MAX_TEX_DIM) return -1; // keeps the returned height <= MAX_TEX_DIM

			f.px = bestX + GAP;
			f.py = bestY + GAP;

			// Raise the skyline over [bestX, bestX+rw) to bestY+rh.
			var nx = bestX;
			var nr = bestX + rw;
			var ny = bestY + rh;
			var outN = 0;
			var inserted = false;
			var j = 0;
			while (j < skCount)
			{
				if (--work < 0) return -1;
				var sx = skX[j];
				var sy = skY[j];
				var sw = skW[j];
				j++;
				if (sx >= nx && sx + sw <= nr) continue; // fully covered
				if (sx < nr && sx + sw > nr) // right part survives
				{
					var trim = nr - sx;
					sx += trim;
					sw -= trim;
				}
				else if (sx < nx && sx + sw > nx) // left part survives
				{
					sw = nx - sx;
				}
				if (!inserted && sx > nx)
				{
					skOutX[outN] = nx;
					skOutY[outN] = ny;
					skOutW[outN] = rw;
					outN++;
					inserted = true;
				}
				skOutX[outN] = sx;
				skOutY[outN] = sy;
				skOutW[outN] = sw;
				outN++;
			}
			if (!inserted)
			{
				skOutX[outN] = nx;
				skOutY[outN] = ny;
				skOutW[outN] = rw;
				outN++;
			}
			for (k in 0...outN)
			{
				skX[k] = skOutX[k];
				skY[k] = skOutY[k];
				skW[k] = skOutW[k];
			}
			skCount = outN;
		}

		// The skyline tiles the whole usable width, so its highest level is the
		// bottom of the deepest reserved cell; add the two GAP margins.
		var deepest = 0;
		for (k in 0...skCount)
			if (skY[k] > deepest) deepest = skY[k];
		return deepest + 2 * GAP;
	}

	/** Same frames, ordered widest-first, for the alternative shelf candidate. */
	static function buildWidthOrder(order:Array<RepackFrame>):Array<RepackFrame>
	{
		var o = order.copy();
		o.sort(function(a:RepackFrame, b:RepackFrame):Int
		{
			if (a.dw != b.dw) return b.dw - a.dw;
			if (a.dh != b.dh) return b.dh - a.dh;
			return a.idx - b.idx;
		});
		return o;
	}

	/**
	 * Widths beyond the historical {w/2, w, 2w, 4w}: cheap multiples plus
	 * content-driven widths around sqrt(reserved area), which is where both
	 * packers waste the least space. addWidth() de-dupes and clamps them.
	 */
	static function buildExtraWidths(srcW:Int, order:Array<RepackFrame>):Array<Int>
	{
		var cands:Array<Int> = [];
		addWidth(cands, Std.int(srcW * 3 / 2));
		addWidth(cands, srcW * 3);
		addWidth(cands, srcW * 6);
		addWidth(cands, srcW * 8);

		var total:Float = 0;
		for (f in order)
			total += (f.dw + GAP) * (f.dh + GAP);
		if (total > 0)
		{
			var side = Std.int(Math.sqrt(total));
			addWidth(cands, Std.int(side * 3 / 4));
			addWidth(cands, side);
			addWidth(cands, Std.int(side * 4 / 3));
			addWidth(cands, side * 2);
			addWidth(cands, side * 3);
		}
		cands.sort(function(a:Int, b:Int):Int return a - b);
		return cands;
	}

	/**
	 * Layout chooser. Phase 1 is the historical search -- {w/2, w, 2w, 4w} widths with the
	 * tallest-first shelf placement -- and always runs; it is the incumbent. Phase 2 tries
	 * extra widths with {skyline bottom-left, widest-first shelf} and adopts a layout only
	 * when its area is *strictly* smaller than the incumbent's, within the deterministic
	 * caps above. No clock is read here, so the same input always picks the same layout.
	 *
	 * Properties this ordering guarantees:
	 *   - the historical best layout is always evaluated, so the result can never be worse
	 *     than the original packer's;
	 *   - on atlases the extra candidates cannot improve, the placements are the historical
	 *     ones and the emitted XML and bitmap are unchanged;
	 *   - the extra work is bounded by MAX_EXTRA_COMBOS, MAX_EXTRA_VISITS and
	 *     SKYLINE_WORK_LIMIT. The only work outside those counters is one O(n log n)
	 *     re-order for the widest-first shelf and one O(n) width scan, the same order as
	 *     the sort coreProcess already performs on this array.
	 *
	 * w == 0 means no candidate beat the source area; the caller aborts and keeps the
	 * original graphic.
	 *
	 * On return with w != 0 the frames hold the WINNING layout's placements. Candidate
	 * evaluation writes f.px/f.py in place, so without the closing replay the frames would
	 * hold the last candidate tried, and a caller inspecting them (the geometry gate in
	 * coreProcess) would compare the wrong rectangles against the winning canvas.
	 */
	static function selectLayout(order:Array<RepackFrame>, oldB:Float, srcW:Int):{w:Int, h:Int, order:Array<RepackFrame>, strat:Int, combos:Int, baseWidths:Int, baseW:Int, baseH:Int}
	{
		var baseCands:Array<Int> = [];
		addWidth(baseCands, Std.int(srcW / 2));
		addWidth(baseCands, srcW);
		addWidth(baseCands, srcW * 2);
		addWidth(baseCands, srcW * 4);
		baseCands.sort(function(a:Int, b:Int):Int return a - b);

		// Compare areas in bytes on both sides.
		var canvasW = 0;
		var canvasH = 0;
		var bestArea:Float = 0;
		var bestStrat = STRAT_SHELF_H;
		var bestOrder = order;
		for (w in baseCands)
		{
			var hNeed = tryPackShelf(order, w);
			if (hNeed <= 0) continue;
			var area:Float = (w * hNeed) * 4;
			if (area >= oldB) continue;
			if (canvasW == 0 || area < bestArea)
			{
				canvasW = w;
				canvasH = hNeed;
				bestArea = area;
				bestStrat = STRAT_SHELF_H;
				bestOrder = order;
			}
		}

		// Retained so the caller can return the baseline when the gate rejects an extra-strategy layout.
		var baseW = canvasW;
		var baseH = canvasH;

		var combos = 0;
		var visits = 0;
		var extraW = buildExtraWidths(srcW, order);
		if (extraW.length > 0 && order.length <= EXTRA_MAX_RECTS)
		{
			var strats:Array<Int> = [STRAT_SKYLINE, STRAT_SHELF_W];
			var orderW:Array<RepackFrame> = null;
			var stop = false;
			for (si in 0...strats.length)
			{
				if (stop) break;
				var st = strats[si];
				var cost = st == STRAT_SKYLINE ? order.length * SKYLINE_VISIT_ESTIMATE : order.length;
				var ord = order;
				if (st == STRAT_SHELF_W)
				{
					if (orderW == null) orderW = buildWidthOrder(order);
					ord = orderW;
				}
				for (w in extraW)
				{
					// Caps are pure counters, never a clock: the same input always yields
					// the same layout, so a context-loss rebuild keeps the packed bitmap
					// matched with the XML of that same layout.
					if (combos >= MAX_EXTRA_COMBOS || visits + cost > MAX_EXTRA_VISITS)
					{
						extraCapHitsTotal++;
						stop = true;
						break;
					}
					combos++;
					visits += cost;
					var hNeed = tryPack(ord, w, st);
					if (hNeed <= 0) continue;
					var area:Float = (w * hNeed) * 4;
					if (area >= oldB) continue;
					// Strict improvement only: an equal-area candidate keeps the historical
					// layout, so atlases that cannot improve emit identical placements.
					if (canvasW != 0 && area >= bestArea) continue;
					canvasW = w;
					canvasH = hNeed;
					bestArea = area;
					bestStrat = st;
					bestOrder = ord;
				}
			}
			if (canvasW != 0 && bestStrat != STRAT_SHELF_H) extraWinsTotal++;
		}
		// The frames must hold the WINNING layout when this function returns. Candidate
		// evaluation writes f.px/f.py in place, so without this replay they would hold the
		// last candidate tried while the caller compares them against the winning canvas
		// (the geometry gate in coreProcess) and rejects a valid layout. w == 0 means no
		// candidate won; the caller then aborts and nothing is replayed.
		if (canvasW != 0)
			tryPack(bestOrder, canvasW, bestStrat);

		extraCombosTotal += combos;
		extraVisitsTotal += visits;
		return {w: canvasW, h: canvasH, order: bestOrder, strat: bestStrat, combos: combos,
			baseWidths: baseCands.length, baseW: baseW, baseH: baseH};
	}

	/**
	 * Decision part of the geometry gate, pure and silent. A layout that did not come from
	 * the historical shelf strategy is checked with layoutViolation(); when the check fails
	 * this returns the historical shelf baseline (baseW/baseH/baseOrder, the original
	 * packer's result) together with the reason for the caller to log. baseW == 0 means the
	 * historical search had no usable layout either, and the caller takes the no-area-win
	 * abort path. Kept as a pure function so a bad layout can be fed to it directly and the
	 * fallback branch exercised without a graphics context.
	 */
	static function gateLayout(w:Int, h:Int, order:Array<RepackFrame>, strat:Int,
		baseW:Int, baseH:Int, baseOrder:Array<RepackFrame>):{w:Int, h:Int, order:Array<RepackFrame>, strat:Int, violation:Null<String>}
	{
		if (w == 0 || strat == STRAT_SHELF_H)
			return {w: w, h: h, order: order, strat: strat, violation: null};
		layoutChecksTotal++;
		var why = layoutViolation(order, w, h);
		if (why == null)
			return {w: w, h: h, order: order, strat: strat, violation: null};
		layoutCheckFailsTotal++;
		return {w: baseW, h: baseH, order: baseOrder, strat: STRAT_SHELF_H, violation: why};
	}

	static function stratName(strat:Int):String
	{
		if (strat == STRAT_SKYLINE) return 'skyline bottom-left';
		if (strat == STRAT_SHELF_W) return 'widest-first shelf';
		return 'tallest-first shelf';
	}

	/**
	 * Packed-geometry invariant check: the only check that can catch two cells covering each
	 * other or a cell placed outside the canvas. The XML read-back check in coreProcess
	 * validates frameX/sourceSize semantics and cannot see pixel overlap; an overlapping cell
	 * makes a mod animation render a neighbouring frame's pixels.
	 *
	 * Treat each cell as the rectangle (px, py, dw+GAP, dh+GAP). Those rectangles being
	 * pairwise disjoint is equivalent to any two cells being at least GAP apart in x or in y,
	 * which is the property that keeps a frame from sampling its neighbour's pixels.
	 * Implementation: sort by px and sweep an active set, so only pairs whose x intervals
	 * overlap are compared -- O(n log n + k).
	 *
	 * Only layouts from the extra strategies are checked; the historical shelf layout comes
	 * from the original code path. Returns null when the layout is sound, otherwise a
	 * description of the first violation, which makes the caller return the historical shelf
	 * layout instead.
	 */
	static function layoutViolation(order:Array<RepackFrame>, w:Int, h:Int):Null<String>
	{
		var sorted = order.copy();
		sorted.sort(function(a:RepackFrame, b:RepackFrame):Int
		{
			if (a.px != b.px) return a.px - b.px;
			return a.py - b.py;
		});
		var budget = LAYOUT_CHECK_BUDGET;
		for (i in 0...sorted.length)
		{
			var a = sorted[i];
			if (a.px < GAP || a.py < GAP)
				return 'cell $i outside the top/left GAP (px=${a.px}, py=${a.py})';
			if (a.px + a.dw > w || a.py + a.dh > h)
				return 'cell $i outside the canvas (px=${a.px}, py=${a.py}, ${a.dw}x${a.dh}, canvas ${w}x${h})';
			var xEnd = a.px + a.dw;
			var j = i + 1;
			while (j < sorted.length && sorted[j].px < xEnd + GAP)
			{
				budget--;
				if (budget < 0) return 'check budget exhausted (${sorted.length} cells) -- layout not trusted';
				var b = sorted[j];
				var xGap = b.px - xEnd;
				var yGap = b.py > a.py ? b.py - (a.py + a.dh) : a.py - (b.py + b.dh);
				if (xGap < GAP && yGap < GAP)
					return 'cells $i and $j too close (xGap=$xGap, yGap=$yGap)';
				j++;
			}
		}
		return null;
	}

	/**
	 * Emit one SubTexture node.
	 * synthQuads=true: cropped mode, adjust trim fields by frameX' = frameX - dx
	 * (flixel offset = -frameX, sourceSize = frameWidth/frameHeight).
	 * synthQuads=false: verbatim move mode, only x/y change.
	 */
	static function buildSubTexture(node:Xml, f:RepackFrame, synthQuads:Bool):String
	{
		var buf = '\t<SubTexture';
		if (!synthQuads)
		{
			for (a in node.attributes())
			{
				switch (a)
				{
					case 'x':        buf += ' x="${f.px}"';
					case 'y':        buf += ' y="${f.py}"';
					default:         buf += ' $a="${esc(node.get(a))}"';
				}
			}
			buf += ' />\n';
			return buf;
		}
		var nfx:Int;
		var nfy:Int;
		var nfw:Int;
		var nfh:Int;
		if (f.hasTrim)
		{
			nfx = f.fx - f.dx;
			nfy = f.fy - f.dy;
			nfw = f.fw;
			nfh = f.fh;
		}
		else
		{
			nfx = -f.dx;
			nfy = -f.dy;
			nfw = f.sw;
			nfh = f.sh;
		}
		for (a in node.attributes())
		{
			switch (a)
			{
				case 'x':        buf += ' x="${f.px}"';
				case 'y':        buf += ' y="${f.py}"';
				case 'width':    buf += ' width="${f.dw}"';
				case 'height':   buf += ' height="${f.dh}"';
				// Trim quad is re-emitted once below (duplicate attrs would throw).
				case 'frameX', 'frameY', 'frameWidth', 'frameHeight':
				default:         buf += ' $a="${esc(node.get(a))}"';
			}
		}
		buf += ' frameX="$nfx" frameY="$nfy" frameWidth="$nfw" frameHeight="$nfh"';
		buf += ' />\n';
		return buf;
	}

	static function attrInt(node:Xml, name:String):Int
	{
		if (!node.exists(name))
		{
			if (name == 'frameX' || name == 'frameY' || name == 'frameWidth' || name == 'frameHeight')
				return 0;
			return -1;
		}
		var v = Std.parseFloat(node.get(name));
		if (!Math.isFinite(v)) return -1;
		var r = Math.round(v);
		if (Math.abs(v - r) > 0.001) return -1;
		return r;
	}

	static function esc(s:String):String
	{
		return s.split('&').join('&amp;').split('<').join('&lt;')
			.split('>').join('&gt;').split('"').join('&quot;');
	}

	static function swapExt(path:String, ext:String):Null<String>
	{
		if (path == null) return null;
		var dot = path.lastIndexOf('.');
		var slash = path.lastIndexOf('/');
		var backSlash = path.lastIndexOf('\\');
		if (dot < 0 || dot < slash || dot < backSlash) return path + ext;
		return path.substr(0, dot) + ext;
	}

	static inline function fl(v:Float):String
	{
		return Std.string(Math.round(v * 10) / 10);
	}
}
