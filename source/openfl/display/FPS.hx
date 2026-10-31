package openfl.display;

import flixel.FlxG;
import flixel.math.FlxMath;
import openfl.display.Shape;
import openfl.display.Sprite;
import openfl.events.Event;
import openfl.system.System;
import openfl.text.Font;
import openfl.text.TextField;
import openfl.text.TextFieldAutoSize;
import openfl.text.TextFormat;
import openfl.text.TextFormatAlign;
import openfl.geom.Matrix;
import states.MainMenuState;
import states.PlayState;
import backend.DeviceInfo;
import backend.GcState;
import backend.NativeMem;
#if cpp
import cpp.vm.Gc as CppGc;
#end
#if gl_stats
import openfl.display._internal.stats.Context3DStats;
import openfl.display._internal.stats.DrawCallContext;
#end
#if flash
import openfl.Lib;
#end

#if !openfl_debug
@:fileXml('tags="haxe,release"')
@:noDebug
#end

class FPS extends Sprite
{
	public var currentFPS(default, null):Int;

	public var minFPS(default, null):Int = 0;
	public var avgFPS(default, null):Int = 0;

	private var currentTime:Float;
	private var times:Array<Float>;
	private var sampleAccum:Float = 0;

	var fpsHistory:Array<Float>;
	var heapHistory:Array<Float>;
	var ramHistory:Array<Float>;
	var heapPeak:Float = 0; 
	var ramPeak:Float = 0;  
	var heapCeil:Float = 100;
	var ramCeil:Float = 100;

	var mode:Int = 0;
	var baseColor:Int;
	var dataFont:Font;

	static inline var P:Float = 8;
	static inline var CH_W:Float = 208;
	static inline var CH_H:Float = 34;
	static inline var INTERVALS:Int = 4;
	static inline var LABEL_W:Float = 32;
	static inline var SAMPLE_MS:Float = 100;
	static inline var HISTORY_MAX:Int = 240;

	static inline var BG_ALPHA:Float = 0.62;
	static inline var C_LBL:Int  = 0xA8B0B8;
	static inline var C_VAL:Int  = 0xFFFFFF; 
	static inline var C_META:Int = 0x9AA4AE; 
	static inline var C_SOFT:Int = 0xB8B8B8; 
	static inline var C_DIM:Int  = 0xA8A8A8; 
	static inline var C_FAINT:Int = 0x9E9E9E;

	var fpsNum:TextField;
	var fpsLbl:TextField;
	var fpsMinMax:TextField;
	var turboBadge:TextField;
	var noGcBadge:TextField;

	var heapPre:TextField;
	var heapNum:TextField;
	var heapPeakT:TextField;
	var heapResT:TextField;
	var ramPre:TextField;
	var ramNum:TextField;
	var ramPeakT:TextField;
	var ramTotalT:TextField;

	var verText:TextField;
	var dcText:TextField;
	var devText:TextField;

	var fpsChart:Shape;
	var heapChart:Shape;
	var ramChart:Shape;
	var div1:Shape;
	var div2:Shape;
	var fpsCVal:TextField;
	var heapCVal:TextField;
	var ramCVal:TextField;
	var fpsYLab:Array<TextField>;
	var heapYLab:Array<TextField>;
	var ramYLab:Array<TextField>;

	public function new(x:Float = 10, y:Float = 10, color:Int = 0xFFFFFF)
	{
		super();

		this.x = x;
		this.y = y;
		this.baseColor = color;

		dataFont = new Font("assets/fonts/vcrcn.ttf");

		currentFPS = 0;
		mouseEnabled = false;
		mouseChildren = false;

		currentTime = 0;
		times = [];
		fpsHistory = [];
		heapHistory = [];
		ramHistory = [];

		fpsNum     = mkField();
		fpsLbl     = mkField();
		fpsMinMax  = mkField();
		turboBadge = mkField();
		noGcBadge  = mkField();
		heapPre    = mkField();
		heapNum    = mkField();
		heapPeakT  = mkField();
		heapResT   = mkField();
		ramPre     = mkField();
		ramNum     = mkField();
		ramPeakT   = mkField();
		ramTotalT  = mkField();
		verText    = mkField();
		dcText     = mkField();
		devText    = mkField();

		fpsChart = new Shape();
		heapChart = new Shape();
		ramChart = new Shape();
		div1 = new Shape();
		div2 = new Shape();
		addChild(fpsChart);
		addChild(heapChart);
		addChild(ramChart);
		addChild(div1);
		addChild(div2);

		fpsCVal = mkField();
		heapCVal = mkField();
		ramCVal = mkField();

		fpsYLab = [for (i in 0...4) mkField()];
		heapYLab = [for (i in 0...4) mkField()];
		ramYLab = [for (i in 0...4) mkField()];

		#if flash
		addEventListener(Event.ENTER_FRAME, function(e) {
			var time = Lib.getTimer();
			__enterFrame(time - currentTime);
		});
		#end
	}

	function mkField():TextField
	{
		var tf = new TextField();
		tf.selectable = false;
		tf.mouseEnabled = false;
		tf.autoSize = TextFieldAutoSize.LEFT;
		addChild(tf);
		return tf;
	}

	private #if !flash override #end function __enterFrame(deltaTime:Float):Void
	{
		if (FlxG.keys.justPressed.F3)
		{
			mode = (mode + 1) % 3;
			if (mode == 2)
			{
				visible = false;
				ClientPrefs.data.showFPS = false;
			}
			else
			{
				visible = true;
				ClientPrefs.data.showFPS = true;
			}
		}

		currentTime += deltaTime;
		times.push(currentTime);
		while (times[0] < currentTime - 1000)
			times.shift();

		var nowFPS = times.length;
		if (nowFPS > ClientPrefs.data.framerate) nowFPS = ClientPrefs.data.framerate;
		currentFPS = nowFPS;

		var sampled = false;
		sampleAccum += deltaTime;
		if (sampleAccum >= SAMPLE_MS)
		{
			sampleAccum = 0;
			sampled = true;

			fpsHistory.push(currentFPS);
			if (fpsHistory.length > HISTORY_MAX) fpsHistory.shift();

			var heap = Math.abs(System.totalMemory / 1000000);
			if (heap > heapPeak) heapPeak = heap;
			heapHistory.push(heap);
			if (heapHistory.length > HISTORY_MAX) heapHistory.shift();

			NativeMem.update();
			if (NativeMem.rssBytes >= 0)
			{
				var ram = Math.abs(NativeMem.rssBytes / 1048576);
				if (ram > ramPeak) ramPeak = ram;
				ramHistory.push(ram);
				if (ramHistory.length > HISTORY_MAX) ramHistory.shift();
			}

			minFPS = 9999;
			var sum:Float = 0;
			for (v in fpsHistory)
			{
				if (v < minFPS) minFPS = Std.int(v);
				sum += v;
			}
			if (minFPS == 9999) minFPS = 0;
			avgFPS = fpsHistory.length > 0 ? Std.int(sum / fpsHistory.length) : 0;
		}

		if (visible) updateDisplay(sampled);
	}

	function updateDisplay(sampled:Bool):Void
	{
		var fn = fontName();
		var heap = Math.abs(System.totalMemory / 1000000);
		var ram:Float = NativeMem.rssBytes >= 0 ? Math.abs(NativeMem.rssBytes / 1048576) : -1;

		var c = baseColor;
		if (heap > 3000 || currentFPS <= ClientPrefs.data.framerate / 2)
			c = 0xFF5555;
		else if (heap > 2000 || currentFPS <= ClientPrefs.data.framerate / 1.5)
			c = 0xFFB347;

		if (mode == 0)
			compact(fn, c, heap, ram);
		else
			debug(fn, c, heap, ram, sampled);

		drawBg();
	}


	function compact(fn:String, c:Int, heap:Float, ram:Float):Void
	{
		hideDebug();

		var y0 = P;
		var x:Float = P;

		setFmt(fpsNum, fn, 14, c, 1.0, currentFPS + "", x, y0);
		x = fpsNum.x + fpsNum.width + 5;
		setFmt(fpsLbl, fn, 10, C_SOFT, 0, "FPS", x, y0 + 2);
		x = fpsLbl.x + fpsLbl.width + 8;

		setFmt(heapPre, fn, 10, C_LBL, 0, "HEAP", x, y0 + 2);
		x = heapPre.x + heapPre.width + 3;
		setFmt(heapNum, fn, 14, C_VAL, 1.0, formatCompactMem(heap), x, y0);
		x = heapNum.x + heapNum.width + 8;

		if (ram >= 0)
		{
			setFmt(ramPre, fn, 10, C_LBL, 0, "RAM", x, y0 + 2);
			x = ramPre.x + ramPre.width + 3;
			setFmt(ramNum, fn, 14, C_VAL, 1.0, formatCompactMem(ram), x, y0);
			x = ramNum.x + ramNum.width + 8;
		}
		else
			ramPre.visible = ramNum.visible = false;

		x = badge(turboBadge, turboActive(), "TURBO", 0xFFD24A, fn, x, y0 + 2);
		badge(noGcBadge, gcOff(), "NO GC", 0xFF6666, fn, x, y0 + 2);

		setFmt(verText, fn, 9, C_DIM, 0,
			"v" + MainMenuState.seiunengineVersion + " | " + DeviceInfo.osName() + " " + DeviceInfo.architecture(),
			P, y0 + fpsNum.height + 1);
	}


	/**
	 * Turbo as it is *actually* running: online play forces it off for the session while the
	 * preference stays on, and a badge that reads the preference would claim a mode the engine
	 * is not in (the reason the online note optimisations looked enabled while they were off).
	 */
	static function turboActive():Bool
	{
		var ps = PlayState.instance;
		if (ps != null)
			return ps.turboModeActive;
		return ClientPrefs.data.turboMode;
	}

	function debug(fn:String, c:Int, heap:Float, ram:Float, sampled:Bool):Void
	{
		var ver = MainMenuState.seiunengineVersion;

		var r1y = P;
		setFmt(fpsNum, fn, 20, c, 1.0, currentFPS + "", P, r1y);
		setFmt(fpsLbl, fn, 12, C_SOFT, 0, "FPS", fpsNum.x + fpsNum.width + 8, r1y + 3);

		var bx = fpsLbl.x + fpsLbl.width + 10;
		bx = badge(turboBadge, turboActive(), "TURBO", 0xFFD24A, fn, bx, r1y + 6);
		badge(noGcBadge, gcOff(), "NO GC", 0xFF6666, fn, bx, r1y + 6);

		setFmt(fpsMinMax, fn, 9, C_DIM, 0,
			"min " + minFPS + " avg " + avgFPS, P, r1y + fpsNum.height);

		var y = fpsMinMax.y + fpsMinMax.height + 4;

		setFmt(heapPre, fn, 10, C_LBL, 0, "HEAP", P, y + 2);
		setFmt(heapNum, fn, 13, C_VAL, 1.0, formatCompactMem(heap), heapPre.x + heapPre.width + 4, y);
		setFmt(heapPeakT, fn, 9, C_META, 0, "pk " + formatCompactMem(heapPeak), heapNum.x + heapNum.width + 6, y + 3);
		#if cpp
		setFmt(heapResT, fn, 9, C_META, 0,
			"rs " + formatCompactMem(CppGc.memInfo64(CppGc.MEM_INFO_RESERVED) / 1000000),
			heapPeakT.x + heapPeakT.width + 6, y + 3);
		#else
		heapResT.visible = false;
		#end
		y = heapNum.y + heapNum.height + 2;

		var ramKnown = ram >= 0;
		if (ramKnown)
		{
			setFmt(ramPre, fn, 10, C_LBL, 0, "RAM", P, y + 2);
			setFmt(ramNum, fn, 13, C_VAL, 1.0, formatCompactMem(ram), ramPre.x + ramPre.width + 4, y);
			setFmt(ramPeakT, fn, 9, C_META, 0, "pk " + formatCompactMem(ramPeak), ramNum.x + ramNum.width + 6, y + 3);
			if (NativeMem.totalPhysBytes > 0)
				setFmt(ramTotalT, fn, 9, C_META, 0, "/ " + formatCompactMem(NativeMem.totalPhysBytes / 1048576),
					ramPeakT.x + ramPeakT.width + 6, y + 3);
			else
				ramTotalT.visible = false;
			y = ramNum.y + ramNum.height + 2;
		}
		else
			ramPre.visible = ramNum.visible = ramPeakT.visible = ramTotalT.visible = false;

		drawDiv(div1, y + 3, CH_W + LABEL_W);

		var chartX = P + LABEL_W;
		var chY = y + 9;

		fpsChart.visible = true;
		fpsChart.x = chartX;
		fpsChart.y = chY;
		if (sampled) drawChart(fpsChart, fpsHistory, ClientPrefs.data.framerate, CH_W, CH_H, 0x55FF77, 0.9, true);
		layoutYLabels(fpsYLab, chY, ClientPrefs.data.framerate, fn);
		setFmt(fpsCVal, fn, 8, 0x77EE88, 0, currentFPS + " fps", chartX, chY + 2);
		fpsCVal.x = chartX + CH_W - fpsCVal.width - 3;
		chY += CH_H + 6;

		heapChart.visible = true;
		heapChart.x = chartX;
		heapChart.y = chY;
		heapCeil = computeCeil(heapHistory, heapCeil);
		if (sampled) drawChart(heapChart, heapHistory, heapCeil, CH_W, CH_H, 0xFFB347, 0.85);
		layoutYLabels(heapYLab, chY, heapCeil, fn);
		setFmt(heapCVal, fn, 8, 0xFFC46B, 0, formatCompactMem(heap), chartX, chY + 2);
		heapCVal.x = chartX + CH_W - heapCVal.width - 3;
		chY += CH_H + 6;

		if (ramKnown)
		{
			ramChart.visible = true;
			ramChart.x = chartX;
			ramChart.y = chY;
			ramCeil = computeCeil(ramHistory, ramCeil);
			if (sampled) drawChart(ramChart, ramHistory, ramCeil, CH_W, CH_H, 0x66BBFF, 0.85);
			layoutYLabels(ramYLab, chY, ramCeil, fn);
			setFmt(ramCVal, fn, 8, 0x88CCFF, 0, formatCompactMem(ram), chartX, chY + 2);
			ramCVal.x = chartX + CH_W - ramCVal.width - 3;
			chY += CH_H + 6;
		}
		else
		{
			ramChart.visible = false;
			ramCVal.visible = false;
			for (tf in ramYLab) tf.visible = false;
		}

		// ── 页脚 ──
		drawDiv(div2, chY + 1, CH_W + LABEL_W);
		var fy = chY + 6;

		#if (gl_stats && !disable_cffi && (!html5 || !canvas))
		var dc = "DC tot:" + Context3DStats.totalDrawCalls()
			+ " stg:" + Context3DStats.contextDrawCalls(DrawCallContext.STAGE)
			+ " 3D:" + Context3DStats.contextDrawCalls(DrawCallContext.STAGE3D);
		setFmt(dcText, fn, 9, C_FAINT, 0, dc, P, fy);
		fy += dcText.height + 3;
		dcText.visible = true;
		#else
		dcText.visible = false;
		#end

		setFmt(verText, fn, 10, C_DIM, 0,
			"SeiunEngine v" + ver + " | GC " + (gcOff() ? "OFF" : "ON"), P, fy);
		fy += verText.height + 2;
		setFmt(devText, fn, 9, C_FAINT, 0, DeviceInfo.shortSummary(48), P, fy);
		devText.visible = true;
	}

	function layoutYLabels(labels:Array<TextField>, chartY:Float, maxVal:Float, fn:String):Void
	{
		var fracs:Array<Float> = [1.0, 2.0/3.0, 1.0/3.0, 0.0];
		for (i in 0...labels.length)
		{
			var val:Float = maxVal * fracs[i];
			var labelText:String;
			if (maxVal >= 100)
				labelText = Std.string(Math.round(val));
			else if (maxVal >= 10)
				labelText = FlxMath.roundDecimal(val, 1) + "";
			else
				labelText = FlxMath.roundDecimal(val, 2) + "";

			var tf = labels[i];
			tf.visible = true;
			tf.text = labelText;
			var f = new TextFormat(fn, 7, C_META);
			f.align = TextFormatAlign.RIGHT;
			tf.setTextFormat(f);
			tf.x = P + LABEL_W - tf.width - 3;
			var frac:Float = fracs[i];
			tf.y = chartY + CH_H * (1 - frac) - tf.height / 2;
		}
	}

	function hideDebug():Void
	{
		fpsMinMax.visible = false;
		heapPre.visible = heapNum.visible = heapPeakT.visible = heapResT.visible = false;
		ramPre.visible = ramNum.visible = ramPeakT.visible = ramTotalT.visible = false;
		dcText.visible = devText.visible = false;
		fpsChart.visible = heapChart.visible = ramChart.visible = false;
		div1.visible = div2.visible = false;
		fpsCVal.visible = heapCVal.visible = ramCVal.visible = false;
		for (tf in fpsYLab) tf.visible = false;
		for (tf in heapYLab) tf.visible = false;
		for (tf in ramYLab) tf.visible = false;
	}

	
	function setFmt(tf:TextField, font:String, size:Int, color:Int,
			letter:Float, text:String, px:Float, py:Float):Void
	{
		if (tf.visible && tf.text == text && tf.x == px && tf.y == py)
		{
			var f = tf.getTextFormat();
			if (Std.int(f.size) == size && Std.int(f.color) == color
				&& (letter <= 0 || f.letterSpacing == letter))
				return;
		}
		tf.visible = true;
		tf.text = text;
		var f = new TextFormat(font, size, color);
		if (letter > 0) f.letterSpacing = letter;
		tf.setTextFormat(f);
		tf.x = px;
		tf.y = py;
	}

	function badge(tf:TextField, on:Bool, text:String, color:Int,
			fn:String, x:Float, y:Float):Float
	{
		if (!on)
		{
			tf.visible = false;
			return x;
		}
		setFmt(tf, fn, 10, color, 0.5, text, x, y);
		return tf.x + tf.width + 6;
	}

	function computeCeil(hist:Array<Float>, cur:Float):Float
	{
		if (hist.length == 0) return 100;
		var pk:Float = 0;
		var s = hist.length - 120; // 只看最近 12s
		if (s < 0) s = 0;
		for (i in s...hist.length)
			if (hist[i] > pk) pk = hist[i];
		var prop = Math.ceil(pk * 1.2 / 100) * 100;
		if (prop < 100) prop = 100;
		if (prop > cur) return prop;
		return FlxMath.lerp(cur, prop, 0.03);
	}

	function drawDiv(sh:Shape, y:Float, w:Float):Void
	{
		sh.visible = true;
		var g = sh.graphics;
		g.clear();
		g.lineStyle(1, 0xFFFFFF, 0.10);
		g.moveTo(P, y);
		g.lineTo(P + w, y);
	}

	function formatCompactMem(megas:Float):String
	{
		if (megas >= 1024) return FlxMath.roundDecimal(megas / 1024, 1) + "GB";
		return Math.round(megas) + "MB";
	}

	function drawBg():Void
	{
		graphics.clear();
		if (mode == 2) return;

		var w:Float, h:Float;

		if (mode == 1)
		{
			w = CH_W + LABEL_W + P * 2;
			var bot = P;
			var fields = [fpsNum, fpsLbl, fpsMinMax, turboBadge, noGcBadge,
				heapPre, heapNum, heapPeakT, heapResT,
				ramPre, ramNum, ramPeakT, ramTotalT,
				fpsCVal, heapCVal, ramCVal, dcText, verText, devText];
			for (k in fields)
			{
				if (k == null || !k.visible) continue;
				var right = k.x + k.width;
				if (right + P > w) w = right + P;
				if (k.y + k.height > bot) bot = k.y + k.height;
			}
			h = bot + P;
		}
		else
		{
			var right = P, bot = P;
			for (k in [fpsNum, fpsLbl, heapPre, heapNum, ramPre, ramNum,
				turboBadge, noGcBadge, verText])
			{
				if (!k.visible) continue;
				if (k.x + k.width > right) right = k.x + k.width;
				if (k.y + k.height > bot)   bot   = k.y + k.height;
			}
			w = right + P;
			h = bot + P;
		}

		graphics.beginFill(0x000000, BG_ALPHA);
		graphics.drawRoundRect(0, 0, w, h, 6, 6);
		graphics.endFill();
		graphics.lineStyle(1, 0xFFFFFF, 0.10);
		graphics.drawRoundRect(0, 0, w, h, 6, 6);
	}

	function fontName():String
	{
		return (dataFont != null && dataFont.fontName != null) ? dataFont.fontName : "_sans";
	}

	inline function gcOff():Bool
	{
		#if cpp
		return GcState.disabled;
		#else
		return false;
		#end
	}

	function getColorForFPS(fps:Float, maxFPS:Float):Int
	{
		var t = fps / maxFPS;
		if (t >= 0.9) return 0x66FF66;
		if (t >= 0.7) return 0xCCFF66;
		if (t >= 0.5) return 0xFFDD44;
		if (t >= 0.3) return 0xFF8844;
		return 0xFF4444;
	}

	function drawChart(sh:Shape, data:Array<Float>, maxV:Float,
			w:Float, h:Float, col:Int, alpha:Float, dynamicColor:Bool = false):Void
	{
		var gfx = sh.graphics;
		gfx.clear();
		var len = data.length;
		if (len < 2) return;
		var rng = maxV;
		if (rng <= 0) rng = 1;

		for (k in 0...(INTERVALS + 1))
		{
			var frac:Float = k / INTERVALS;
			var gy = h * (1 - frac);
			gfx.lineStyle(1, 0xFFFFFF, 0.05);
			gfx.moveTo(0, gy);
			gfx.lineTo(w, gy);
		}

		gfx.lineStyle(1, 0xFFFFFF, 0.10);
		gfx.drawRect(0, 0, w, h);

		var points:Array<{x:Float, y:Float}> = [];
		for (i in 0...len)
		{
			var x = (i / (len - 1)) * w;
			var y = h - (data[i] / rng) * h;
			if (y < 0.5) y = 0.5;
			if (y > h) y = h;
			points.push({x: x, y: y});
		}

		var fillCol = col;
		if (dynamicColor)
		{
			var latestFPS = data[len - 1];
			var maxFPS = ClientPrefs.data.framerate;
			fillCol = getColorForFPS(latestFPS, maxFPS);
		}

		var matrix = new Matrix();
		matrix.createGradientBox(w, h, Math.PI / 2, 0, 0);
		gfx.beginGradientFill(openfl.display.GradientType.LINEAR,
			[fillCol, fillCol], [0.45, 0.05], [0, 255], matrix);
		gfx.moveTo(points[0].x, points[0].y);
		for (i in 1...len)
			gfx.lineTo(points[i].x, points[i].y);
		gfx.lineTo(w, h);
		gfx.lineTo(0, h);
		gfx.endFill();

		if (dynamicColor)
		{
			var maxFPS:Float = ClientPrefs.data.framerate;
			for (i in 0...(len - 1))
			{
				var avg = (data[i] + data[i+1]) / 2;
				var lineCol = getColorForFPS(avg, maxFPS);
				gfx.lineStyle(2, lineCol, alpha);
				gfx.moveTo(points[i].x, points[i].y);
				gfx.lineTo(points[i+1].x, points[i+1].y);
			}
		}
		else
		{
			gfx.lineStyle(2, col, alpha);
			gfx.moveTo(points[0].x, points[0].y);
			for (i in 1...len)
				gfx.lineTo(points[i].x, points[i].y);
		}
	}
}
