package backend;

import backend.boot.BootArt;
import flixel.FlxG;
import flixel.FlxBasic;
import flixel.FlxSprite;
import flixel.group.FlxGroup.FlxTypedGroup;
import flixel.math.FlxMath;
import flixel.math.FlxRect;
import flixel.text.FlxText;
import flixel.text.FlxText.FlxTextAlign;
import flixel.util.FlxColor;

/**
 * The boot screen's loading bar.
 *
 * A rounded track with quarter ticks, a violet to cyan gradient fill clipped to the real
 * progress, a glowing head that marks exactly how far the work got, a highlight sweeping
 * the filled stretch, the localised task line, the percentage and a technical detail line
 * under the bar (the key that is being loaded right now).
 *
 * Purely presentational — the boot flow owns the truth and feeds it through setProgress();
 * the rendered value chases that target every frame so a burst of finished work reads as
 * one smooth motion instead of the bar teleporting. Nothing here is a tween: every frame is
 * a function of the values it was given, which is what lets the boot be skipped or
 * interrupted at any moment without leaving a half-faded sprite behind.
 *
 * The whole group fades and rises as one unit through appear(), which the splash calls with
 * its settle progress.
 */
class BootBar extends FlxTypedGroup<FlxBasic>
{
	public static inline var BAR_HEIGHT:Int = 10;
	public static inline var ACCENT_LEFT:FlxColor = BootArt.ACCENT_LEFT;
	public static inline var ACCENT_RIGHT:FlxColor = BootArt.ACCENT_RIGHT;

	/** Distance from the bar to the task line above and the detail line below. */
	static inline var TASK_OFFSET:Float = 36;
	static inline var DETAIL_OFFSET:Float = 24;
	static inline var RISE:Float = 10;

	public var track(default, null):FlxSprite;
	public var ticks(default, null):FlxSprite;
	public var fill(default, null):FlxSprite;
	public var shimmer(default, null):FlxSprite;
	public var headGlow(default, null):FlxSprite;
	public var headDot(default, null):FlxSprite;
	public var taskText(default, null):FlxText;
	public var pctText(default, null):FlxText;
	public var detailText(default, null):FlxText;

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
	/** 1 right after pulse(), decays to 0: lights the head for the hand-over. */
	var pulseEnergy:Float = 0;
	/** 1 right after a task change, decays to 0: the label dips and returns. */
	var labelEnergy:Float = 0;
	/** Seconds since the last displayed value changed, used for the head breathing. */
	var idleClock:Float = 0;

	public function new(barWidth:Float, ?barY:Float = -1)
	{
		super();
		this.barWidth = barWidth;
		barX = Math.round((FlxG.width - barWidth) / 2);
		this.barY = (barY < 0) ? FlxG.height - 132 : barY;

		var w:Int = Std.int(barWidth);

		// Track: dark glass, a hairline border and the quarter ticks baked in, so the ticks
		// exist even at 0% and the whole thing is one texture.
		track = new FlxSprite(barX, this.barY, BootArt.roundedRect(w, BAR_HEIGHT, BAR_HEIGHT / 2, BootArt.TRACK, 0.92));
		add(track);

		// The quarter marks sit above the fill: they are a scale, not part of the trough.
		var tickBitmap = new openfl.display.BitmapData(w, BAR_HEIGHT, true, 0x00000000);
		for (i in 1...4)
		{
			var x:Int = Std.int(w * i / 4);
			tickBitmap.fillRect(new openfl.geom.Rectangle(x, 1, 1, BAR_HEIGHT - 2), 0x48FFFFFF);
		}
		ticks = new FlxSprite(barX, this.barY, tickBitmap);
		add(ticks);

		fill = new FlxSprite(barX, this.barY, BootArt.gradientRoundedRect(w, BAR_HEIGHT, BAR_HEIGHT / 2, ACCENT_LEFT, ACCENT_RIGHT));
		fill.clipRect = FlxRect.get(0, 0, 0, BAR_HEIGHT);
		add(fill);

		shimmer = new FlxSprite(barX, this.barY + 1, BootArt.roundedRect(64, BAR_HEIGHT - 2, (BAR_HEIGHT - 2) / 2, FlxColor.WHITE,
			0.32));
		shimmer.visible = false;
		add(shimmer);

		headGlow = new FlxSprite(0, 0, BootArt.dot(56, 0xC8EEFF, 0.85));
		headGlow.blend = openfl.display.BlendMode.SCREEN;
		add(headGlow);
		headDot = new FlxSprite(0, 0, BootArt.dot(10, 0xF2FCFF, 1.0));
		add(headDot);

		taskText = new FlxText(barX, this.barY - TASK_OFFSET, barWidth * 0.74, '', 15);
		taskText.setFormat(Paths.languageFont(), 15, 0xFF9EA0B5, FlxTextAlign.LEFT);
		add(taskText);

		pctText = new FlxText(barX, this.barY - TASK_OFFSET - 2, barWidth, '', 15);
		pctText.setFormat(Paths.font('montserrat.ttf'), 15, 0xFFE8E8F2, FlxTextAlign.RIGHT);
		add(pctText);

		detailText = new FlxText(barX, this.barY + DETAIL_OFFSET, barWidth, '', 12);
		detailText.setFormat(Paths.font('vcr.ttf'), 12, 0xFF6B7391, FlxTextAlign.LEFT);
		add(detailText);
	}

	/** Feed the real progress (0..1). */
	public function setProgress(value:Float):Void
	{
		target = value < 0 ? 0 : (value > 1 ? 1 : value);
	}

	public function setTask(label:String):Void
	{
		if (taskText.text == label) return;
		taskText.text = label;
		// A short dip instead of an instant swap: the line changes often during the boot
		// and a hard cut draws the eye away from the mark.
		labelEnergy = 1;
	}

	/** The asset key being loaded right now, shown under the bar in mono type. */
	public function setDetail(label:String):Void
	{
		if (detailText.text == label) return;
		detailText.text = label;
	}

	/** 0 = fully hidden, 1 = fully visible; called with the splash's settle progress. */
	public function appear(value:Float):Void
	{
		presence = value < 0 ? 0 : (value > 1 ? 1 : value);
	}

	/** One-off flourish for the hand-over: the head flares and the bar settles. */
	public function pulse():Void
	{
		pulseEnergy = 1;
	}

	override public function update(elapsed:Float):Void
	{
		idleClock += elapsed;
		shimmerClock += elapsed;

		// Chase the target with an exponential lerp: honest progress, smooth motion.
		displayed += (target - displayed) * Math.min(1, elapsed * 5.0);
		if (Math.abs(target - displayed) < 0.0008)
			displayed = target;

		if (pulseEnergy > 0)
			pulseEnergy = Math.max(0, pulseEnergy - elapsed * 1.6);
		if (labelEnergy > 0)
			labelEnergy = Math.max(0, labelEnergy - elapsed * 2.6);

		var rise:Float = (1 - presence) * RISE;
		var fillWidth:Float = displayed * barWidth;

		if (fillWidth != lastFillWidth)
		{
			fill.clipRect = FlxRect.get(0, 0, fillWidth, BAR_HEIGHT);
			lastFillWidth = fillWidth;
		}

		// Highlight sweeping the filled stretch. Only runs once there is something to
		// sweep across, and it never leaves the filled part, so it cannot lie about progress.
		if (presence > 0 && fillWidth > 90)
		{
			var sweep:Float = 0.5 + 0.5 * Math.sin(shimmerClock * 1.5);
			var span:Float = fillWidth - shimmer.width - 8;
			shimmer.visible = true;
			shimmer.x = barX + 4 + Math.max(0, span) * sweep;
			shimmer.y = barY + 1 + rise;
			shimmer.alpha = presence * 0.22 * Math.min(1, (fillWidth - 90) / 80);
		}
		else
		{
			shimmer.visible = false;
		}

		// Head: the exact end of the filled stretch, breathing while the boot is idle.
		var headX:Float = barX + fillWidth;
		var breathe:Float = 0.5 + 0.5 * Math.sin(idleClock * 2.4);
		var headAlpha:Float = presence * (0.45 + 0.25 * breathe + 0.30 * pulseEnergy);
		var headScale:Float = 1 + 0.35 * pulseEnergy;

		headGlow.visible = presence > 0 && displayed > 0.002;
		headGlow.x = headX - headGlow.width / 2;
		headGlow.y = barY + BAR_HEIGHT / 2 + rise - headGlow.height / 2;
		headGlow.alpha = headAlpha;
		headGlow.scale.set(headScale, headScale);
		headGlow.updateHitbox();

		headDot.visible = headGlow.visible;
		headDot.x = headX - headDot.width / 2;
		headDot.y = barY + BAR_HEIGHT / 2 + rise - headDot.height / 2;
		headDot.alpha = presence * (0.85 + 0.15 * pulseEnergy);

		pctText.text = Std.string(Math.round(displayed * 100)) + '%';

		// Everything except the head shares one fade and one rise.
		track.alpha = fill.alpha = ticks.alpha = presence;
		taskText.alpha = presence * (1 - 0.45 * labelEnergy);
		pctText.alpha = presence;
		detailText.alpha = presence * 0.9;

		track.y = barY + rise;
		ticks.y = barY + rise;
		fill.y = barY + rise;
		taskText.y = barY - TASK_OFFSET + rise + labelEnergy * 3;
		pctText.y = barY - TASK_OFFSET - 2 + rise;
		detailText.y = barY + DETAIL_OFFSET + rise;

		track.visible = fill.visible = ticks.visible = taskText.visible = pctText.visible = detailText.visible = presence > 0;

		super.update(elapsed);
	}
}
