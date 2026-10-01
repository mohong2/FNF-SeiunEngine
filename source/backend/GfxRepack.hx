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

	public static var triedTotal:Int = 0;
	public static var okTotal:Int = 0;
	public static var fallbackTotal:Int = 0;
	static var lastBoundsSkips:Int = 0;
	public static var oldBytesTotal:Float = 0;
	public static var newBytesTotal:Float = 0;
	public static var msTotal:Float = 0;

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
			return r.bmp;
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
			var cands:Array<Int> = [];
			addWidth(cands, Std.int(src.width / 2));
			addWidth(cands, src.width);
			addWidth(cands, src.width * 2);
			addWidth(cands, src.width * 4);
			cands.sort(function(a:Int, b:Int):Int return a - b);

			// Compare areas in bytes on both sides.
			var canvasW = 0;
			var canvasH = 0;
			var bestArea:Float = 0;
			for (w in cands)
			{
				var hNeed = tryPack(order, w);
				if (hNeed <= 0) continue;
				var area:Float = (w * hNeed) * 4;
				if (area >= oldB) continue;
				if (canvasW == 0 || area < bestArea)
				{
					canvasW = w;
					canvasH = hNeed;
					bestArea = area;
				}
			}
			if (canvasW == 0)
				abort('no-area-win (src ${src.width}x${src.height}, ${parsed.frames.length} entries/${order.length} unique, ${cands.length} widths tried)');
			tryPack(order, canvasW); // replay winning width to restore placements

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
	static inline function blit(packed:BitmapData, src:BitmapData, sx:Int, sy:Int, sw:Int, sh:Int,
		dx:Int, dy:Int, canvasW:Int, canvasH:Int):Void
	{
		if (sw <= 0 || sh <= 0) return;
		// 源图必须还带着 CPU 像素: gfxCpuRelease 会把大图的 CPU 副本释放掉,
		// 对着一张只剩显存纹理的位图 copyPixels 就是读已经释放的内存。
		if (src == null || !src.readable) { boundsSkips++; return; }
		if (dx < 0 || dy < 0 || dx + sw > canvasW || dy + sh > canvasH) { boundsSkips++; return; }
		if (sx < 0 || sy < 0 || sx + sw > src.width || sy + sh > src.height) { boundsSkips++; return; }
		packed.copyPixels(src, new Rectangle(sx, sy, sw, sh), new Point(dx, dy));
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

	static function tryPack(order:Array<RepackFrame>, width:Int):Int
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
