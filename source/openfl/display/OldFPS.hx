package openfl.display;

import flixel.math.FlxMath;
import openfl.events.Event;
import openfl.system.System;
import openfl.text.TextField;
import openfl.text.TextFormat;
#if gl_stats
import openfl.display._internal.stats.Context3DStats;
import openfl.display._internal.stats.DrawCallContext;
#end
#if flash
import openfl.Lib;
#end

/**
	OldFPS -- minimal on-screen FPS display.
	Built on TextField; every property is directly readable and writable from hscript.
*/
#if !openfl_debug
@:fileXml('tags="haxe,release"')
@:noDebug
#end
class OldFPS extends TextField
{
	/** Current frames per second -- directly readable from hscript. **/
	public var currentFPS(default, null):Int;

	/** Whether memory usage is shown. **/
	public var showMemory:Bool = true;
	/** Whether DrawCalls are shown. **/
	public var showDrawCalls:Bool = true;
	/** Memory warning threshold in MB; the text changes colour above it. **/
	public var warningMemory:Float = 3000;
	/** Normal text colour. **/
	public var colorNormal:Int = 0xFFFFFFFF;
	/** Warning text colour. **/
	public var colorWarning:Int = 0xFFFF0000;
	/** Font size. **/
	public var fontSize:Int = 14;
	/** Font name. **/
	public var fontName:String = "_sans";
	/** X position. **/
	public var displayX:Float;
	/** Y position. **/
	public var displayY:Float;

	/** Whether FPS smoothing is used (same as the old display). **/
	public var smoothFPS:Bool = true;
	/** Text alpha. **/
	public var textAlpha:Float = 1.0;

	/** Forced text; when not null it replaces the normal FPS readout (hscript-controlled). **/
	public var forceText:Null<String> = null;
	/** Forced text colour; when not null it replaces the normal colour. **/
	public var forceColor:Null<Int> = null;

	@:noCompletion private var cacheCount:Int;
	@:noCompletion private var currentTime:Float;
	@:noCompletion private var times:Array<Float>;

	public function new(x:Float = 10, y:Float = 10, color:Int = 0xFFFFFF)
	{
		super();

		this.x = x;
		this.y = y;
		displayX = x;
		displayY = y;

		currentFPS = 0;
		selectable = false;
		mouseEnabled = false;
		defaultTextFormat = new TextFormat(fontName, fontSize, color);
		autoSize = LEFT;
		multiline = true;
		text = "FPS: ";

		cacheCount = 0;
		currentTime = 0;
		times = [];

		#if flash
		addEventListener(Event.ENTER_FRAME, function(e)
		{
			var time = Lib.getTimer();
			__enterFrame(time - currentTime);
		});
		#end
	}

	/** Forces the next frame to refresh the readout. **/
	public function forceRefresh():Void
	{
		cacheCount = -1;
	}

	/** Moves the readout to displayX/displayY. **/
	public function syncPosition():Void
	{
		x = displayX;
		y = displayY;
	}

	@:noCompletion
	private #if !flash override #end function __enterFrame(deltaTime:Float):Void
	{
		currentTime += deltaTime;
		times.push(currentTime);

		while (times[0] < currentTime - 1000)
		{
			times.shift();
		}

		var currentCount = times.length;
		if (smoothFPS)
			currentFPS = Math.round((currentCount + cacheCount) / 2);
		else
			currentFPS = currentCount;

		if (currentFPS > ClientPrefs.data.framerate) currentFPS = ClientPrefs.data.framerate;

		if (currentCount != cacheCount)
		{
			// When hscript sets forceText, show that text instead of the real FPS
			if (forceText != null)
			{
				text = forceText;
				textColor = (forceColor != null) ? forceColor : colorNormal;
			}
			else
			{
				text = "FPS: " + currentFPS;

				#if openfl
				var memoryMegas:Float = Math.abs(FlxMath.roundDecimal(System.totalMemory / 1000000, 1));
				if (showMemory)
				{
					text += "\nMemory: " + memoryMegas + " MB";
				}
				#end

				textColor = (forceColor != null) ? forceColor : colorNormal;
				#if openfl
				if (forceColor == null && (memoryMegas > warningMemory || currentFPS <= ClientPrefs.data.framerate / 2))
				{
					textColor = colorWarning;
				}
				#end

				#if (gl_stats && !disable_cffi && (!html5 || !canvas))
				if (showDrawCalls)
				{
					text += "\ntotalDC: " + Context3DStats.totalDrawCalls();
					text += "\nstageDC: " + Context3DStats.contextDrawCalls(DrawCallContext.STAGE);
					text += "\nstage3DDC: " + Context3DStats.contextDrawCalls(DrawCallContext.STAGE3D);
				}
				#end

				text += "\n";
			}
		}

		cacheCount = currentCount;
	}
}
