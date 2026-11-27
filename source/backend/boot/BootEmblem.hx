package backend.boot;

import flash.display.BitmapData;
import flixel.FlxSprite;
import flixel.group.FlxGroup.FlxTypedGroup;
import flixel.math.FlxMath;
import flixel.util.FlxColor;

/**
 * The SEIUN mark: a hexagonal core inside two counter-rotating arcs, ringed by a
 * segmented progress gauge.
 *
 * The engine has no icon artwork yet, so the boot mark is built from geometry instead of
 * borrowing someone else's logo (the old splash flew in HaxeFlixel's own artwork, which
 * said "flixel", not "Seiun"). The shape reads as three things at once, which is why it
 * works small and large: a seal, a star (the name means nebula) and an instrument dial.
 *
 * Everything is a still bitmap; the animation is pure transforms driven by pose(). No
 * tweens and no per-frame allocations, so the marking can never desync from the jingle and
 * a decode hitch cannot leave a half-built logo on screen — the caller passes the clock,
 * and the same clock always produces the same frame.
 *
 * The gauge doubles as a loading readout: ticks light up as real work completes, so the
 * mark itself reports progress before the bar at the bottom is even legible.
 */
class BootEmblem extends FlxTypedGroup<FlxSprite>
{
	public static inline var TICKS:Int = 56;

	/** Radii and sizes, in stage units. */
	static inline var CANVAS:Int = 300;
	static inline var GAUGE_R:Float = 128;
	static inline var ARC_R:Float = 104;
	static inline var DASH_R:Float = 86;
	static inline var HEX_R:Float = 56;
	static inline var SPARK_R:Float = 26;
	// Small and close-set: the gauge should read as a fine dial, not as a sunburst. The
	// ticks are 2 x 7 px at the reference layout, roughly a quarter of the ring gap.
	static inline var TICK_W:Float = 1.6;
	static inline var TICK_H:Float = 6.0;

	var unit:Float;

	var glow:FlxSprite;
	var coreGlow:FlxSprite;
	var arcA:FlxSprite;
	var arcB:FlxSprite;
	var dashA:FlxSprite;
	var dashB:FlxSprite;
	var dashC:FlxSprite;
	var hex:FlxSprite;
	var hexInner:FlxSprite;
	var sparkHalo:FlxSprite;
	var spark:FlxSprite;
	var cometHead:FlxSprite;
	var cometTrailA:FlxSprite;
	var cometTrailB:FlxSprite;
	var shock:FlxSprite;
	var burst:FlxSprite;
	var gaugeHead:FlxSprite;

	var ticks:Array<FlxSprite> = [];
	var litColour:Array<FlxColor> = [];

	public function new(unitScale:Float)
	{
		super();
		unit = unitScale;

		var canvas:Int = Std.int(CANVAS * unit);

		glow = build(BootArt.radialGlow(Std.int(360 * unit), BootArt.ACCENT_LEFT, 0.26, 2.3));
		coreGlow = build(BootArt.radialGlow(Std.int(200 * unit), BootArt.ACCENT_RIGHT, 0.30, 2.0));

		// One arc bitmap, used twice at opposite angles: a closed ring reads as decoration,
		// an open one as a dial. The pair rotates together, so the gaps travel.
		var arcBitmap = BootArt.arcRing(canvas, ARC_R * unit, 1.7 * unit, 14, 129,
			BootArt.ACCENT_LEFT, BootArt.ACCENT_RIGHT, 0.10, 0.95);
		arcA = build(arcBitmap);
		arcB = build(arcBitmap);

		// Three dashes on the inner ring, sharing one bitmap at 120 degree steps.
		var dashBitmap = BootArt.arcRing(canvas, DASH_R * unit, 2.3 * unit, 100, 142,
			BootArt.ACCENT_RIGHT, BootArt.ACCENT_LEFT, 0.90, 0.30);
		dashA = build(dashBitmap);
		dashB = build(dashBitmap);
		dashC = build(dashBitmap);

		hex = build(BootArt.hexFrame(canvas, HEX_R * unit, 2.3 * unit, BootArt.ACCENT_LEFT, BootArt.ACCENT_RIGHT, 0.95));
		hexInner = build(BootArt.hexFrame(canvas, (HEX_R - 11) * unit, 1.0 * unit, BootArt.ACCENT_RIGHT, BootArt.ACCENT_LEFT, 0.24));

		// A plain bloom behind the core, not a second star: two star shapes read as a
		// double image at boot size.
		sparkHalo = build(BootArt.radialGlow(Std.int(SPARK_R * 3.6 * unit), 0xC6DCFF, 0.30, 2.0));
		spark = build(BootArt.sparkle(canvas, SPARK_R * 1.15 * unit, 0xECF6FF, 0.98, 0.11));

		// Comet riding the arc ring: one bright head and two fading tail dots.
		cometHead = build(BootArt.dot(Std.int(34 * unit), BootArt.ACCENT_RIGHT, 0.70));
		cometTrailA = build(BootArt.dot(Std.int(22 * unit), BootArt.ACCENT_RIGHT, 0.34));
		cometTrailB = build(BootArt.dot(Std.int(16 * unit), BootArt.ACCENT_RIGHT, 0.14));

		// The glowing head of the gauge: where the mark says "this far, no further".
		gaugeHead = build(BootArt.dot(Std.int(26 * unit), 0xD8F2FF, 0.65));

		// Impact ring and core burst: one moment each, when the splash lands.
		shock = build(BootArt.ring(canvas, ARC_R * unit, 1.4 * unit, 0xE8F2FF, 0.9));
		burst = build(BootArt.radialGlow(Std.int(320 * unit), 0xDCE6FF, 0.55, 1.5));

		buildTicks();
	}

	function build(bitmap:BitmapData):FlxSprite
	{
		var sprite = new FlxSprite(0, 0, bitmap);
		sprite.antialiasing = false;
		sprite.visible = false;
		add(sprite);
		return sprite;
	}

	/**
	 * Lays out the gauge. The ticks are plain sprites sharing one white bitmap and tinted
	 * individually, so the whole ring is a single texture and a single draw batch.
	 */
	function buildTicks():Void
	{
		var tickBitmap = BootArt.tickMark(Std.int(TICK_W * unit), Std.int(TICK_H * unit), FlxColor.WHITE, 1.0);
		for (i in 0...TICKS)
		{
			var sprite = new FlxSprite(0, 0, tickBitmap);
			sprite.antialiasing = false;
			sprite.visible = false;
			add(sprite);
			ticks.push(sprite);
			litColour.push(FlxColor.interpolate(BootArt.ACCENT_LEFT, BootArt.ACCENT_RIGHT, i / (TICKS - 1)));
		}
	}

	// ═══════════════════════════════════════════════════════════════════════
	//  Pose
	// ═══════════════════════════════════════════════════════════════════════

	/**
	 * Places and animates the whole mark for one frame.
	 *
	 * @param cx        centre, in stage units
	 * @param cy        centre, in stage units
	 * @param t         animation clock, in seconds
	 * @param presence  0..1 overall fade
	 * @param scale     uniform scale (the splash punch and the settle both feed it)
	 * @param progress  0..1 gauge fill
	 * @param flash     0..1 impact energy; drives the shock ring and the core burst
	 */
	public function pose(cx:Float, cy:Float, t:Float, presence:Float, scale:Float, progress:Float, flash:Float):Void
	{
		var p:Float = presence < 0 ? 0 : (presence > 1 ? 1 : presence);
		if (p <= 0.001)
		{
			for (part in members)
				part.visible = false;
			return;
		}

		var breathe:Float = Math.sin(t * 1.7);

		place(glow, cx, cy, scale * (1 + 0.02 * breathe));
		glow.alpha = (0.55 + 0.06 * breathe) * p;

		place(coreGlow, cx, cy, scale * (1 + 0.05 * breathe));
		coreGlow.alpha = (0.85 + 0.10 * breathe) * p;

		// Arcs and dashes counter-rotate: the outer pair advances, the inner trio retreats.
		var spinOuter:Float = t * 5.5;
		place(arcA, cx, cy, scale);
		place(arcB, cx, cy, scale);
		arcA.angle = spinOuter;
		arcB.angle = spinOuter + 180;
		arcA.alpha = 0.95 * p;
		arcB.alpha = 0.95 * p;

		var spinInner:Float = -t * 9.0;
		place(dashA, cx, cy, scale);
		place(dashB, cx, cy, scale);
		place(dashC, cx, cy, scale);
		dashA.angle = spinInner;
		dashB.angle = spinInner + 120;
		dashC.angle = spinInner + 240;
		dashA.alpha = 0.90 * p;
		dashB.alpha = 0.90 * p;
		dashC.alpha = 0.90 * p;

		place(hex, cx, cy, scale * (1 + 0.04 * flash));
		hex.alpha = p;
		place(hexInner, cx, cy, scale);
		hexInner.alpha = 0.9 * p;

		place(sparkHalo, cx, cy, scale * (1 + 0.15 * flash));
		sparkHalo.alpha = (0.75 + 0.25 * flash) * p * (0.85 + 0.15 * breathe);
		place(spark, cx, cy, scale * (1 + 0.10 * flash));
		spark.angle = t * 3.0;
		spark.alpha = p;

		// Comet: head on the arc ring, two dots trailing behind it in the direction of travel.
		var headAngle:Float = -90 + t * 42;
		var ringRadius:Float = ARC_R * unit * scale;
		var rad:Float = headAngle * Math.PI / 180;
		placeAt(cometHead, cx + Math.cos(rad) * ringRadius, cy + Math.sin(rad) * ringRadius, scale);
		cometHead.alpha = 0.9 * p;
		traceAt(cometTrailA, cx, cy, ringRadius, scale, headAngle - 6, 0.40 * p);
		traceAt(cometTrailB, cx, cy, ringRadius, scale, headAngle - 13, 0.16 * p);

		// Impact.
		if (flash > 0.002)
		{
			place(shock, cx, cy, scale * FlxMath.lerp(0.55, 1.45, 1 - flash));
			shock.alpha = flash * 0.55;
			place(burst, cx, cy, scale * FlxMath.lerp(0.60, 1.60, 1 - flash));
			burst.alpha = flash * 0.40;
		}
		else
		{
			shock.visible = false;
			burst.visible = false;
		}

		updateGauge(cx, cy, scale, progress, p);
	}

	/** Places one comet tail dot at a given angle. */
	static function traceAt(sprite:FlxSprite, cx:Float, cy:Float, radius:Float, scale:Float, deg:Float, alpha:Float):Void
	{
		var rad:Float = deg * Math.PI / 180;
		placeAt(sprite, cx + Math.cos(rad) * radius, cy + Math.sin(rad) * radius, scale);
		sprite.alpha = alpha;
	}

	/**
	 * Lights the gauge ticks.
	 *
	 * The tick at the current edge fades in with the fraction of its step that is already
	 * done, which turns a ring of discrete marks into a continuous readout.
	 */
	function updateGauge(cx:Float, cy:Float, scale:Float, progress:Float, presence:Float):Void
	{
		var pr:Float = progress < 0 ? 0 : (progress > 1 ? 1 : progress);
		var litExact:Float = pr * TICKS;
		var lit:Int = Std.int(litExact);
		var r:Float = GAUGE_R * unit * scale;

		for (i in 0...TICKS)
		{
			var tick = ticks[i];
			var deg:Float = -90 + i * 360 / TICKS;
			var rad:Float = deg * Math.PI / 180;

			tick.visible = true;
			tick.angle = deg - 90;
			tick.origin.set(tick.width / 2, tick.height / 2);
			tick.scale.set(scale, scale);
			tick.x = cx + Math.cos(rad) * r - tick.width / 2;
			tick.y = cy + Math.sin(rad) * r - tick.height / 2;

			if (i < lit)
			{
				tick.color = litColour[i];
				// Deliberately below full strength: the gauge is a background instrument,
				// and a ring of saturated marks overpowers the mark it surrounds.
				tick.alpha = 0.50 * presence;
			}
			else if (i == lit && pr > 0 && pr < 1)
			{
				var frac:Float = litExact - lit;
				tick.color = litColour[i];
				tick.alpha = (0.16 + 0.34 * frac) * presence;
			}
			else
			{
				// The unlit ring stays readable as a dial instead of disappearing, so the
				// gauge always looks finished rather than "half drawn".
				tick.color = BootArt.MUTED;
				tick.alpha = 0.14 * presence;
			}
		}

		// Head glow: the eye finds "now" without reading the bar. Tinted with the gauge's
		// own colour at this point of the sweep, so it belongs to the scale rather than
		// sitting on top of it as a grey dot.
		var headRad:Float = (-90 + pr * 360) * Math.PI / 180;
		gaugeHead.color = FlxColor.interpolate(BootArt.ACCENT_LEFT, BootArt.ACCENT_RIGHT, pr);
		placeAt(gaugeHead, cx + Math.cos(headRad) * r, cy + Math.sin(headRad) * r, scale);
		gaugeHead.alpha = (pr > 0.001 ? 0.65 : 0) * presence;
	}

	// ═══════════════════════════════════════════════════════════════════════
	//  Placement helpers (scale and rotate about the sprite centre)
	// ═══════════════════════════════════════════════════════════════════════

	static inline function place(sprite:FlxSprite, cx:Float, cy:Float, scale:Float):Void
	{
		sprite.visible = true;
		sprite.origin.set(sprite.width / 2, sprite.height / 2);
		sprite.scale.set(scale, scale);
		sprite.x = cx - sprite.width / 2;
		sprite.y = cy - sprite.height / 2;
	}

	static inline function placeAt(sprite:FlxSprite, x:Float, y:Float, scale:Float):Void
	{
		sprite.visible = true;
		sprite.origin.set(sprite.width / 2, sprite.height / 2);
		sprite.scale.set(scale, scale);
		sprite.x = x - sprite.width / 2;
		sprite.y = y - sprite.height / 2;
	}
}
