package backend;

import flixel.FlxG;
import openfl._internal.RenderProf;

/**
 * Lab probe: logs flixel step / canvas-record frames slower than a threshold, so a
 * multi-second hitch can be attributed to the update side or the draw-record side.
 * Enabled only by SEIUN_LAB_FRAME_LOG=1; never installed otherwise.
 *
 * Events also go to SEIUN_LAB_LOG when set, because a detached game process has no
 * useful stdout on this harness.
 */
class LabFrameLog
{
	static var stepT:Float = 0;
	static var drawT:Float = 0;
	static var logPath:String = null;

	/** True only while the frame log is installed; hot code paths check this before timing. */
	public static var active:Bool = false;

	/** Segment marks for one update() (see PlayState.update): 0=start .. 9=end. */
	public static var segT:Array<Float> = [for (i in 0...16) 0.0];

	public static function install():Void
	{
		active = true;
		#if sys
		try logPath = Sys.getEnv('SEIUN_LAB_LOG') catch (e:Dynamic) {}
		if (logPath != null && logPath.length == 0) logPath = null;
		#end
		FlxG.signals.preUpdate.add(function()
		{
			stepT = now();
			RenderProf.stepCount++;
		});
		FlxG.signals.postUpdate.add(function()
		{
			var ms:Float = now() - stepT;
			if (ms >= 8) event('slow-step', ms, 'stepCount=' + FlxG.game.stepCount);
		});
		FlxG.signals.preDraw.add(function() drawT = now());
		FlxG.signals.postDraw.add(function()
		{
			var ms:Float = now() - drawT;
			if (ms >= 8) event('slow-draw', ms, 'stepCount=' + FlxG.game.stepCount);
		});
	}

	public static function resetSeg():Void
	{
		for (i in 0...segT.length) segT[i] = 0;
	}

	public static function mark(i:Int):Void
	{
		#if sys
		segT[i] = Sys.time() * 1000.0;
		#end
	}

	/** Called at the end of update(): logs the per-segment split of a slow frame. */
	public static function logSeg(extra:String = ''):Void
	{
		if (!active) return;
		mark(9);
		var total:Float = segT[9] - segT[0];
		if (total < 7) return;
		var sb = new StringBuf();
		for (i in 1...16)
		{
			if (segT[i] > 0)
				sb.add(' ' + i + ':' + Math.round((segT[i] - segT[0]) * 10) / 10);
		}
		event('seg', total, 'total=' + Math.round(total * 10) / 10 + sb.toString() + (extra != '' ? ' ' + extra : ''));
	}

	public static function event(kind:String, ms:Float, extra:String = ''):Void
	{
		var line:String = '[' + kind + '] ' + Math.round(ms) + 'ms ' + extra;
		#if sys
		try Sys.println(line) catch (e:Dynamic) {}
		if (logPath != null)
		{
			try
			{
				var out = sys.io.File.append(logPath, false);
				out.writeString(line + '\n');
				out.close();
			}
			catch (e:Dynamic) {}
		}
		#end
	}

	inline static function now():Float
	{
		#if sys
		return Sys.time() * 1000.0;
		#else
		return 0;
		#end
	}
}
