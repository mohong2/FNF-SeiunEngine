package states;

import flixel.FlxG;
import flixel.FlxState;
import openfl.display.BitmapData;
import flixel.text.FlxText;
import flixel.text.FlxTextProf;
import flixel.text.FlxTextStamp;
import flixel.util.FlxColor;
import openfl._internal.RenderProf;

/**
 * Text-pipeline regression bench. `SEIUN_TEXT_BENCH=1` boots straight into it instead of the
 * title screen; it drives the same texts the HUD uses, reports percentiles and exits.
 *
 * The cases are built exactly like their `PlayState` counterparts (fonts, sizes, border sizes,
 * field widths, alignments), so a change to `FlxText` can be compared against the numbers
 * recorded in `docs/text-pipeline.md` instead of by feel.
 *
 * Every case frame rebuilds its text *synchronously* (`calcFrame(true)`), so the stage timers in
 * `FlxTextProf` describe one rebuild exactly; the frame's `submitMs` / `uploadMs` columns are read
 * on the next frame, where they belong to this one (the upload happens while the frame renders).
 *
 * Env:
 *   SEIUN_TEXT_BENCH_FRAMES=<n>   samples per case (default 100)
 *   SEIUN_TEXT_BENCH_TAG=<label>  header tag
 *   SEIUN_TEXT_BENCH_DETAIL=1     per-draw timers on (upload column only; inflates the rest)
 */
class TextBenchState extends FlxState
{
	/** Samples the bench keeps per case; warmup frames run first so allocator/GC noise settles. */
	static var SAMPLES:Int = 100;
	static var WARMUP:Int = 30;

	static function envInt(name:String, def:Int):Int
	{
		#if sys
		try
		{
			var raw:String = Sys.getEnv(name);
			if (raw != null && raw.length > 0)
			{
				var v:Null<Int> = Std.parseInt(raw);
				if (v != null && v > 0) return v;
			}
		}
		catch (e:Dynamic) {}
		#end
		return def;
	}

	static function envStr(name:String, def:String):String
	{
		#if sys
		try
		{
			var raw:String = Sys.getEnv(name);
			if (raw != null && raw.length > 0) return raw;
		}
		catch (e:Dynamic) {}
		#end
		return def;
	}

	public static function shouldRun():Bool
	{
		#if sys
		try return Sys.getEnv('SEIUN_TEXT_BENCH') == '1' catch (e:Dynamic) {}
		#end
		return false;
	}

	// -- cases ---------------------------------------------------------------

	static inline var CASE_SCORE:Int = 0;
	static inline var CASE_SCORE_PLAIN:Int = 1;
	static inline var CASE_AUTO:Int = 2;
	static inline var CASE_COUNTERS:Int = 3;
	static inline var CASE_TIMER:Int = 4;
	static inline var CASE_COUNT:Int = 5;

	static var CASE_NAMES:Array<String> = ['score', 'scoreNoBorder', 'autoWidth', 'counters', 'timer'];

	/** The HUD texts of one case; one update rebuilds all of them, like PlayState does per frame. */
	var texts:Array<Array<FlxText>> = [];

	var scores:Array<Int> = [0, 0, 0];
	var misses:Array<Int> = [0, 0, 0];
	var accs:Array<Float> = [98.76, 98.5, 99.1];
	var timeSec:Int = 133;

	/** Per case: [submitMs, uploadMs, total, layout, clear, render, alloc, rebuilds]. */
	var samples:Array<Array<Array<Float>>> = [];

	var frame:Int = 0;
	/** Case whose rebuild is waiting for the frame it renders in. */
	var pending:Int = -1;

	/**
	 * `SEIUN_TEXT_BENCH_VERIFY=1`: instead of timing, every case frame renders its text twice -
	 * once through the normal repaint and once through a forced full-bitmap rebuild - and counts
	 * differing pixels. Any non-zero total means the repaint rectangle lost a pixel.
	 */
	static var VERIFY:Bool = false;

	/** Pixels that differed between the repaint and the full rebuild across the whole run. */
	var verifyDiff:Int = 0;
	var verifyFrames:Int = 0;
	var verifyWorst:Int = 0;
	/** Per case: differing pixels, and the x range they covered (to tell a seam from a shift). */
	var verifyByCase:Array<Int> = [];
	var verifyMinX:Array<Float> = [];
	var verifyMaxX:Array<Float> = [];
	var lastDiffMinX:Int = 0;
	var lastDiffMaxX:Int = 0;
	var done:Bool = false;

	override public function create():Void
	{
		super.create();

		SAMPLES = envInt('SEIUN_TEXT_BENCH_FRAMES', SAMPLES);
		VERIFY = envInt('SEIUN_TEXT_BENCH_VERIFY', 0) == 1;

		FlxG.cameras.bgColor = 0xFF101010;

		// The upload is only visible through the profiler; recording keeps its per-frame columns
		// honest (they are reset per frame only while recording) and drops textbench.csv next to
		// the exe for anyone who wants the raw rows.
		RenderProf.enabled = true;
		RenderProf.detail = envInt('SEIUN_TEXT_BENCH_DETAIL', 0) == 1;
		RenderProf.recording = true;
		RenderProf.tag = 'bench';
		RenderProf.basePath = 'textbench';

		FlxTextProf.reset();
		FlxTextProf.on = true;

		for (i in 0...CASE_COUNT)
		{
			texts.push([]);
			samples.push([]);
			verifyByCase.push(0);
			verifyMinX.push(0);
			verifyMaxX.push(0);
		}

		var langFont:String = Paths.languageFont();
		var vcrFont:String = Paths.font('vcr.ttf');

		// The real HUD line: full field width, centred, outlined, language font.
		texts[CASE_SCORE].push(makeText(0, 40, FlxG.width, langFont, 20, FlxTextAlign.CENTER, FlxTextBorderStyle.OUTLINE, 2));
		// The same line without a border: what the border pass costs per update.
		texts[CASE_SCORE_PLAIN].push(makeText(0, 90, FlxG.width, langFont, 20, FlxTextAlign.CENTER, FlxTextBorderStyle.NONE, 0));
		// Auto-sized: fieldWidth 0, so a width change reallocates the bitmap and its graphic.
		texts[CASE_AUTO].push(makeText(0, 140, 0, langFont, 28, FlxTextAlign.LEFT, FlxTextBorderStyle.OUTLINE, 2));
		// The three side counters: three texts rebuild in the same frame, like a hit does.
		texts[CASE_COUNTERS].push(makeText(0, 200, 400, vcrFont, 18, FlxTextAlign.RIGHT, FlxTextBorderStyle.OUTLINE, 1.25));
		texts[CASE_COUNTERS].push(makeText(0, 230, 400, vcrFont, 18, FlxTextAlign.LEFT, FlxTextBorderStyle.OUTLINE, 1.25));
		texts[CASE_COUNTERS].push(makeText(0, 260, 400, vcrFont, 18, FlxTextAlign.CENTER, FlxTextBorderStyle.OUTLINE, 1.25));
		// The timer: updated every frame in real play, short, centred, outlined.
		texts[CASE_TIMER].push(makeText(0, 320, 400, vcrFont, 20, FlxTextAlign.CENTER, FlxTextBorderStyle.OUTLINE, 2));

		for (caseTexts in texts)
			for (t in caseTexts)
				add(t);

		for (i in 0...CASE_COUNT)
			applyCase(i);

		#if sys
		Sys.println('[textbench] start samples=' + SAMPLES + ' cases=' + CASE_COUNT
			+ ' stamp=' + FlxTextStamp.available + ' detail=' + RenderProf.detail
			+ ' tag=' + envStr('SEIUN_TEXT_BENCH_TAG', '?'));
		#end
	}

	function makeText(x:Float, y:Float, w:Float, font:String, size:Int, align:FlxTextAlign, border:FlxTextBorderStyle, borderSize:Float):FlxText
	{
		var t:FlxText = new FlxText(x, y, w, '', size);
		t.setFormat(font, size, FlxColor.WHITE, align, border, FlxColor.BLACK);
		t.borderSize = borderSize;
		t.scrollFactor.set();
		return t;
	}

	/** Advance the text of one case to its next state. */
	function applyCase(role:Int):Void
	{
		switch (role)
		{
			case CASE_SCORE | CASE_SCORE_PLAIN:
				var i:Int = (role == CASE_SCORE) ? 0 : 1;
				scores[i] += 250;
				if (scores[i] % 2000 == 0) misses[i]++;
				accs[i] = 90 + (scores[i] % 999) / 100.0;
				texts[role][0].text = 'Score: ' + scores[i] + ' | Combo Breaks: ' + misses[i] + ' | Accuracy: '
					+ Std.string(Math.round(accs[i] * 100) / 100) + '% | (' + (misses[i] > 2 ? 'Good' : 'Sick!') + ')';
			case CASE_AUTO:
				// The digit count changes, which is the case that reallocates the bitmap.
				scores[2] += 1;
				var v:Int = 100000 + (scores[2] * 7919) % 900000;
				texts[role][0].text = (scores[2] % 3 == 0) ? '(v:' + v + ')' : Std.string(v);
			case CASE_COUNTERS:
				var n:Int = scores[2] * 3;
				texts[role][0].text = 'Notes: ' + n + '/' + (n + 17);
				texts[role][1].text = 'Max Combo: ' + (n + 5);
				texts[role][2].text = 'Misses: ' + (n % 7);
			case CASE_TIMER:
				timeSec--;
				if (timeSec < 0) timeSec = 133;
				var m:Int = Std.int(timeSec / 60);
				var s2:Int = timeSec % 60;
				texts[role][0].text = m + ':' + (s2 < 10 ? '0' : '') + s2;
		}
	}

	/** Rebuild one case's texts now, and keep what the rebuild cost. */
	function rebuild(role:Int):Void
	{
		var before:Array<Float> = allProf();
		for (t in texts[role])
			@:privateAccess t.calcFrame(true);
		var after:Array<Float> = allProf();

		#if sys
		if (envInt('SEIUN_TEXT_BENCH_DEBUG', 0) == 1 && samples[role].length < 2)
		{
			var t:FlxText = texts[role][0];
			@:privateAccess Sys.println('[rect] role=' + role + ' bmp=' + t.graphic.bitmap.width + 'x' + t.graphic.bitmap.height
				+ ' tw=' + rnd(t.textField.textWidth) + ' th=' + rnd(t.textField.textHeight)
				+ ' run=' + rnd(t._dirtyRect.x) + ' ' + rnd(t._dirtyRect.width)
				+ ' wrap=' + t.textField.wordWrap);
		}
		#end

		var rows:Array<Float> = [0, 0]; // submit, upload are filled in on the next frame
		for (i in 0...after.length)
			rows.push(after[i] - before[i]);
		samples[role].push(rows);
	}

	/** Renders one case through the normal path and compares it against a forced full rebuild. */
	function verify(role:Int):Void
	{
		for (t in texts[role])
		{
			forceRebuild(t); // the normal, incremental rebuild
			var fast:BitmapData = t.graphic.bitmap.clone();

			// and the reference: the same content, but without a dirty-rect shortcut, so the
			// whole line is cleared and rasterized from scratch
			@:privateAccess t._rasterText = null;
			forceRebuild(t);

			var d:Int = pixelDiff(fast, t.graphic.bitmap);
			fast.dispose();
			if (d > 0)
			{
				verifyWorst = Std.int(Math.max(verifyWorst, d));
				verifyByCase[role] = verifyByCase[role] + d;
				if (verifyMinX[role] == 0 || lastDiffMinX < verifyMinX[role]) verifyMinX[role] = lastDiffMinX;
				if (lastDiffMaxX > verifyMaxX[role]) verifyMaxX[role] = lastDiffMaxX;
			}
			verifyDiff += d;
		}
		verifyFrames++;
	}

	inline function forceRebuild(t:FlxText):Void
	{
		@:privateAccess
		{
			t._regen = true;
			t._rasterSig = null;
			t.calcFrame(true);
		}
	}

	/** Number of pixels that differ, -1 when the sizes do (which must never happen). */
	function pixelDiff(a:BitmapData, b:BitmapData):Int
	{
		if (a.width != b.width || a.height != b.height)
			return -1;
		var diff:BitmapData = a.compare(b);
		if (diff == null)
			return 0;
		var n:Int = 0;
		var minX:Int = 1000000;
		var maxX:Int = -1;
		for (y in 0...diff.height)
			for (x in 0...diff.width)
				if (diff.getPixel32(x, y) != 0)
				{
					n++;
					if (x < minX) minX = x;
					if (x > maxX) maxX = x;
				}
		if (n > 0)
		{
			lastDiffMinX = minX;
			lastDiffMaxX = maxX;
		}
		diff.dispose();
		return n;
	}

	function allProf():Array<Float>
	{
		return [
			FlxTextProf.total, FlxTextProf.layout, FlxTextProf.clear, FlxTextProf.render, FlxTextProf.alloc, FlxTextProf.rebuilds,
			FlxTextProf.raster, FlxTextProf.stamp
		];
	}

	override public function update(elapsed:Float):Void
	{
		super.update(elapsed);

		// The frame that just closed rendered the rebuild started on the previous frame; its
		// submit/upload columns belong to that case.
		if (pending >= 0 && samples[pending].length > 0)
		{
			var rows:Array<Float> = samples[pending][samples[pending].length - 1];
			rows[0] = RenderProf.row[RenderProf.C_SUBMIT];
			rows[1] = RenderProf.row[RenderProf.C_UPLOAD];
			pending = -1;
		}
		if (done) return;

		var cycle:Int = CASE_COUNT * 2;
		var pos:Int = frame % cycle;
		var role:Int = (pos % 2 == 1) ? Std.int((pos - 1) / 2) : -1;

		if (role >= 0)
		{
			applyCase(role);
			if (VERIFY)
			{
				verify(role);
				pending = -1;
			}
			else
			{
				rebuild(role);
				pending = role;
			}
		}

		frame++;

		if (frame > WARMUP)
		{
			var full:Bool = true;
			if (VERIFY)
			{
				full = (verifyFrames >= SAMPLES * CASE_COUNT);
			}
			else
			{
				for (i in 0...CASE_COUNT)
					if (samples[i].length < SAMPLES) full = false;
			}
			if (full)
			{
				done = true;
				report();
			}
		}
	}

	function report():Void
	{
		#if sys
		Sys.println('[textbench] --- ' + envStr('SEIUN_TEXT_BENCH_TAG', '?'));
		var names:Array<String> = ['total', 'layout', 'clear', 'render', 'raster', 'stamp', 'alloc', 'upload', 'submit'];
		// samples: [submit, upload, total, layout, clear, render, alloc, rebuilds, raster, stamp]
		var idx:Array<Int> = [2, 3, 4, 5, 8, 9, 6, 1, 0];
		for (i in 0...CASE_COUNT)
		{
			var rows:Array<Array<Float>> = samples[i];
			if (rows.length == 0 || VERIFY) continue;
			var parts:Array<String> = [];
			for (k in 0...names.length)
			{
				var col:Array<Float> = [];
				for (r in rows)
					col.push(r[idx[k]] / (r[7] > 0 ? r[7] : 1));
				parts.push(names[k] + '=' + fmtPct(col));
			}
			var rebuilds:Float = 0;
			for (r in rows)
				rebuilds += r[7];
			parts.push('rebuilds=' + Math.round(rebuilds / rows.length * 100) / 100);
			parts.push('n=' + rows.length);
			Sys.println('[textbench] ' + CASE_NAMES[i] + ' ' + parts.join(' '));
		}
		if (VERIFY)
		{
			Sys.println('[textbench] verify frames=' + verifyFrames + ' diffPixels=' + verifyDiff + ' worstFrame=' + verifyWorst);
			for (i in 0...CASE_COUNT)
				Sys.println('[textbench] verify ' + CASE_NAMES[i] + ' diff=' + verifyByCase[i]
					+ ' x=' + verifyMinX[i] + '..' + verifyMaxX[i] + ' bmp=' + texts[i][0].graphic.bitmap.width);
		}
		Sys.println('[textbench] done');
		RenderProf.flush(true);
		Sys.exit(VERIFY && verifyDiff != 0 ? 3 : 0);
		#end
	}

	/** "p50/p90 ms". */
	function fmtPct(values:Array<Float>):String
	{
		if (values.length == 0) return '0/0';
		values.sort(function(a, b) return a < b ? -1 : (a > b ? 1 : 0));
		var p50:Float = values[Std.int((values.length - 1) * 0.5)];
		var p90:Float = values[Std.int((values.length - 1) * 0.9)];
		return rnd(p50) + '/' + rnd(p90);
	}

	static inline function rnd(v:Float):String
	{
		return Std.string(Math.round(v * 1000) / 1000);
	}
}
