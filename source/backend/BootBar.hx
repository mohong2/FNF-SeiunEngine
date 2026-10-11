package backend;

import flash.display.BitmapData;
import flash.display.GradientType;
import flash.display.Shape;
import flash.geom.Matrix;
import flixel.FlxG;
import flixel.FlxBasic;
import flixel.FlxSprite;
import flixel.group.FlxGroup.FlxTypedGroup;
import flixel.math.FlxRect;
import flixel.text.FlxText;
import flixel.util.FlxAxes;
import flixel.util.FlxColor;

/**
 * The boot screen's bottom loading bar: rounded track, violet→cyan gradient fill clipped
 * to the real progress, a highlight sweeping the filled portion, a task label and a
 * percentage readout.
 *
 * Purely presentational — the boot flow owns the truth and feeds it through setProgress();
 * the rendered value chases that target every frame so bursts of finished work read as one
 * smooth motion. The whole group fades in as one unit via appear() while the logo splash
 * settles.
 */
class BootBar extends FlxTypedGroup<FlxBasic>
{
	public static inline var BAR_HEIGHT:Int = 8;
	public static inline var ACCENT_LEFT:FlxColor = 0xFF8A7CFF;
	public static inline var ACCENT_RIGHT:FlxColor = 0xFF5AD7FA;

	public var track(default, null):FlxSprite;
	public var fill(default, null):FlxSprite;
	public var shimmer(default, null):FlxSprite;
	public var taskText(default, null):FlxText;
	public var pctText(default, null):FlxText;

	/** Real progress the boot flow has actually reached (0..1). */
	public var target:Float = 0;
	/** The value the visuals chase. */
	public var displayed:Float = 0;

	public var barWidth(default, null):Float;
	public var barX(default, null):Float;
	public var barY(default, null):Float;

	/** Group-wide fade used by appear(); every member multiplies into it. */
	var presence:Float = 0;
	var shimmerClock:Float = 0;
	var lastFillWidth:Float = -1;

	public function new(barWidth:Float)
	{
		super();
		this.barWidth = barWidth;
		barX = Math.round((FlxG.width - barWidth) / 2);
		barY = FlxG.height - 64;

		track = new FlxSprite(0, 0, roundedRect(Std.int(barWidth), BAR_HEIGHT, 4, 0x16FFFFFF));
		track.setPosition(barX, barY);
		add(track);

		fill = new FlxSprite(0, 0, gradientRoundedRect(Std.int(barWidth), BAR_HEIGHT, 4, ACCENT_LEFT, ACCENT_RIGHT));
		fill.setPosition(barX, barY);
		fill.clipRect = FlxRect.get(0, 0, 0, BAR_HEIGHT);
		add(fill);

		shimmer = new FlxSprite(0, 0, roundedRect(64, BAR_HEIGHT - 2, 3, 0x40FFFFFF));
		shimmer.setPosition(barX, barY + 1);
		shimmer.visible = false;
		add(shimmer);

		taskText = new FlxText(barX, barY - 30, barWidth * 0.7, '', 15);
		taskText.setFormat(Paths.languageFont(), 15, 0xFF9EA0B5, LEFT);
		add(taskText);

		pctText = new FlxText(barX, barY - 29, barWidth, '', 15);
		pctText.setFormat(Paths.font('montserrat.ttf'), 15, 0xFFE8E8F2, RIGHT);
		add(pctText);
	}

	/** Feed the real progress (0..1). */
	public function setProgress(value:Float):Void
	{
		target = value < 0 ? 0 : (value > 1 ? 1 : value);
	}

	public function setTask(label:String):Void
	{
		taskText.text = label;
	}

	/** 0 = fully hidden, 1 = fully visible; called with the splash's settle progress. */
	public function appear(value:Float):Void
	{
		presence = value < 0 ? 0 : (value > 1 ? 1 : value);
	}

	override public function update(elapsed:Float):Void
	{
		shimmerClock += elapsed;

		displayed += (target - displayed) * Math.min(1, elapsed * 5.0);
		if (Math.abs(target - displayed) < 0.0008)
			displayed = target;

		var fillWidth:Float = displayed * barWidth;
		if (fillWidth != lastFillWidth)
		{
			fill.clipRect = FlxRect.get(0, 0, fillWidth, BAR_HEIGHT);
			lastFillWidth = fillWidth;
		}

		// The highlight only sweeps once there is a filled stretch to sweep across.
		if (presence > 0 && fillWidth > 90)
		{
			var sweep:Float = 0.5 + 0.5 * Math.sin(shimmerClock * 2.2);
			var span:Float = fillWidth - shimmer.width - 8;
			shimmer.visible = true;
			shimmer.x = barX + 4 + Math.max(0, span) * sweep;
			shimmer.alpha = presence * 0.30 * Math.min(1, (fillWidth - 90) / 80);
		}
		else
		{
			shimmer.visible = false;
		}

		pctText.text = Std.string(Math.round(displayed * 100)) + '%';

		track.alpha = fill.alpha = taskText.alpha = pctText.alpha = presence;
		track.visible = fill.visible = taskText.visible = pctText.visible = presence > 0;

		super.update(elapsed);
	}

	static function roundedRect(width:Int, height:Int, radius:Int, color:FlxColor):BitmapData
	{
		var shape = new Shape();
		shape.graphics.beginFill(color, color.alphaFloat);
		shape.graphics.drawRoundRect(0, 0, width, height, radius * 2, radius * 2);
		shape.graphics.endFill();
		var bd = new BitmapData(width, height, true, 0x00000000);
		bd.draw(shape);
		return bd;
	}

	static function gradientRoundedRect(width:Int, height:Int, radius:Int, left:FlxColor, right:FlxColor):BitmapData
	{
		var shape = new Shape();
		var matrix = new Matrix();
		matrix.createGradientBox(width, height, 0, 0, 0);
		shape.graphics.beginGradientFill(GradientType.LINEAR, [left, right], [1, 1], [0, 255], matrix);
		shape.graphics.drawRoundRect(0, 0, width, height, radius * 2, radius * 2);
		shape.graphics.endFill();
		var bd = new BitmapData(width, height, true, 0x00000000);
		bd.draw(shape);
		return bd;
	}
}
