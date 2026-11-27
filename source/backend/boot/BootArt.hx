package backend.boot;

import flash.display.CapsStyle;
import flash.display.GradientType;
import flash.display.Graphics;
import flash.display.Shape;
import flash.display.SpreadMethod;
import flash.geom.Matrix;
import flixel.util.FlxColor;
import openfl.display.BitmapData;

/**
 * Procedural artwork for the boot screen.
 *
 * The boot runs before any asset has been unpacked — on a first Android launch the
 * extraction pass has not even started when the scene is built — so nothing here reads a
 * file. Every mark, glow, ring and streak is drawn into a `BitmapData` at runtime, which
 * is also why the engine can show a real logo on the splash while it still has no icon
 * artwork of its own.
 *
 * Two rules keep the result sharp instead of "generated looking":
 *
 *   - every shape is rasterised at 2x and downsampled with smoothing, so strokes and arcs
 *     come out anti-aliased (openfl's shape rasteriser is not, at 1x);
 *   - thicknesses and radii arrive in caller units and are multiplied by that same 2x
 *     inside the paint callback, so a "1.5 px" ring is 1.5 px in stage units no matter how
 *     the supersampling is done.
 *
 * Nothing is cached across calls: the boot state is created once per process and owns
 * every bitmap it asks for, so a later `FlxG.bitmap` purge can never leave a dangling
 * reference behind.
 */
class BootArt
{
	// ── Palette ──────────────────────────────────────────────────────────
	// Kept here rather than in the bar so the splash, the bar and the chips
	// cannot drift apart. ACCENT_LEFT/RIGHT are the engine's own two accents.
	public static inline var VOID:FlxColor = 0xFF06060D;
	public static inline var DEEP:FlxColor = 0xFF0D0B1C;
	public static inline var ACCENT_LEFT:FlxColor = 0xFF8A7CFF;
	public static inline var ACCENT_RIGHT:FlxColor = 0xFF5AD7FA;
	public static inline var INK:FlxColor = 0xFFF2F3FA;
	public static inline var INK_DIM:FlxColor = 0xFF9EA0B5;
	public static inline var INK_FAINT:FlxColor = 0xFF6B7391;
	public static inline var MUTED:FlxColor = 0xFF8B93B2;
	public static inline var HAIRLINE:FlxColor = 0xFF3C4262;
	public static inline var TRACK:FlxColor = 0xFF14162A;

	/** Supersampling factor for everything that is not a full-screen gradient. */
	static inline var SS:Int = 2;

	// ═══════════════════════════════════════════════════════════════════════
	//  Fills and backgrounds
	// ═══════════════════════════════════════════════════════════════════════

	/**
	 * Vertical two-stop gradient. Only 8 columns wide: every row is a single colour, so
	 * stretching it to any width cannot show a seam and costs almost no memory.
	 */
	public static function verticalGradient(width:Int, height:Int, top:FlxColor, bottom:FlxColor):BitmapData
	{
		var w:Int = 8;
		var bd = new BitmapData(w, height, true, 0xFF000000);
		for (y in 0...height)
		{
			var t:Float = height <= 1 ? 0 : y / (height - 1);
			bd.fillRect(new openfl.geom.Rectangle(0, y, w, 1), FlxColor.interpolate(top, bottom, t));
		}
		return bd;
	}

	/**
	 * Radial falloff used for every halo in the boot: the emblem bloom, the chip dots and
	 * the leading edge of the progress bar.
	 *
	 * Drawn at half resolution and meant to be scaled up — a glow has no detail worth
	 * paying full resolution for, and a soft edge is exactly what is wanted.
	 */
	public static function radialGlow(diameter:Int, color:FlxColor, alpha:Float, ?power:Float = 2.2):BitmapData
	{
		var out:Int = Std.int(diameter / 2) + 2;
		var bd = new BitmapData(out, out, true, 0x00000000);
		var shape = new Shape();
		var m = new Matrix();
		m.createGradientBox(out, out, 0, 0, 0);
		// Four stops approximate a smooth falloff; a true x^power curve would need one
		// stop per pixel, and the difference is invisible at this blur level.
		shape.graphics.beginGradientFill(GradientType.RADIAL, [color, color, color, color],
			[alpha, alpha * (1 - Math.pow(0.45, power)), 0, 0], [0, 110, 190, 255], m);
		shape.graphics.drawCircle(out / 2, out / 2, out / 2);
		shape.graphics.endFill();
		bd.draw(shape);
		return bd;
	}

	/**
	 * Full-screen vignette: transparent in the middle, dark at the corners.
	 *
	 * Generated at half size and stretched by the caller, for the same reason the glow is.
	 */
	public static function vignette(width:Int, height:Int, strength:Float):BitmapData
	{
		var w:Int = Std.int(width / 2);
		var h:Int = Std.int(height / 2);
		var bd = new BitmapData(w, h, true, 0x00000000);
		var shape = new Shape();
		var m = new Matrix();
		m.createGradientBox(w * 1.25, h * 1.45, 0, -w * 0.125, -h * 0.22);
		shape.graphics.beginGradientFill(GradientType.RADIAL, [0x000000, 0x000000, 0x000000, 0x000000],
			[0, 0, strength * 0.45, strength], [0, 110, 190, 255], m, SpreadMethod.PAD);
		shape.graphics.drawRect(0, 0, w, h);
		shape.graphics.endFill();
		bd.draw(shape);
		return bd;
	}

	/**
	 * One tile of the star field. Deterministic per seed, so the boot looks the same on
	 * every launch instead of shuffling — a background that changes between sessions reads
	 * as noise, not as a sky.
	 *
	 * Drawn at 1x: the stars are 1-2 px dots, which is exactly what they should be.
	 */
	public static function starTile(width:Int, height:Int, count:Int, seed:Int, brightness:Float):BitmapData
	{
		var bd = new BitmapData(width, height, true, 0x00000000);
		var state:Int = seed * 1103515245 + 12345;
		for (i in 0...count)
		{
			state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
			var x:Float = (state % (width * 16)) / 16;
			state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
			var y:Float = (state % (height * 16)) / 16;
			state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
			var r:Float = 0.5 + (state % 100) / 100 * 0.9;
			state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
			var a:Float = (0.18 + (state % 100) / 100 * 0.62) * brightness;

			bd.fillRect(new openfl.geom.Rectangle(x, y, r, r), FlxColor.fromRGBFloat(0.88, 0.92, 1.0, a));
		}
		return bd;
	}

	// ═══════════════════════════════════════════════════════════════════════
	//  Emblem parts
	// ═══════════════════════════════════════════════════════════════════════

	/**
	 * A solid ring stroke.
	 *
	 * @param canvas  square canvas size in stage units; the ring is centred in it
	 * @param radius  ring radius in the same units
	 */
	public static function ring(canvas:Int, radius:Float, thickness:Float, color:FlxColor, alpha:Float):BitmapData
	{
		return raster(canvas, canvas, function(g:Graphics, k:Float)
		{
			g.lineStyle(thickness * k, color, alpha);
			g.drawCircle(canvas / 2 * k, canvas / 2 * k, radius * k);
		});
	}

	/**
	 * An arc with an angular gradient — the trick openfl does not offer.
	 *
	 * The arc is cut into overlapping segments, each stroked with its own interpolated
	 * colour; because neighbouring segments overlap by half a step and use round caps, the
	 * seams are invisible and the result reads as one continuous sweep of colour.
	 *
	 * Angles are degrees, 0 = 3 o'clock, growing clockwise (screen space).
	 */
	public static function arcRing(canvas:Int, radius:Float, thickness:Float, startDeg:Float, endDeg:Float, from:FlxColor, to:FlxColor,
			fromAlpha:Float, toAlpha:Float):BitmapData
	{
		return raster(canvas, canvas, function(g:Graphics, k:Float)
		{
			var total:Float = endDeg - startDeg;
			if (total == 0) return;
			// ~1.5 degrees per segment: smooth at any radius the boot uses, cheap enough
			// to rebuild for every layer at create().
			var steps:Int = Std.int(Math.max(2, Math.abs(total) / 1.5));
			var cx:Float = canvas / 2 * k;
			var cy:Float = canvas / 2 * k;
			var r:Float = radius * k;
			for (i in 0...steps)
			{
				var t0:Float = i / steps;
				var t1:Float = (i + 1.7) / steps; // overlap by 0.7 of a step
				if (t1 > 1) t1 = 1;
				var a0:Float = (startDeg + total * t0) * Math.PI / 180;
				var a1:Float = (startDeg + total * t1) * Math.PI / 180;
				var color:Int = FlxColor.interpolate(from, to, (t0 + t1) * 0.5);
				g.lineStyle(thickness * k, color, fromAlpha + (toAlpha - fromAlpha) * (t0 + t1) * 0.5, false, null, CapsStyle.ROUND, null);
				g.moveTo(cx + Math.cos(a0) * r, cy + Math.sin(a0) * r);
				g.lineTo(cx + Math.cos(a1) * r, cy + Math.sin(a1) * r);
			}
		});
	}

	/** A hexagonal frame with a colour ramp around its six edges. */
	public static function hexFrame(canvas:Int, radius:Float, thickness:Float, from:FlxColor, to:FlxColor, alpha:Float):BitmapData
	{
		return raster(canvas, canvas, function(g:Graphics, k:Float)
		{
			var cx:Float = canvas / 2 * k;
			var cy:Float = canvas / 2 * k;
			var r:Float = radius * k;
			for (side in 0...6)
			{
				var a0:Float = (60 * side - 90) * Math.PI / 180;
				var a1:Float = (60 * (side + 1) - 90) * Math.PI / 180;
				g.lineStyle(thickness * k, FlxColor.interpolate(from, to, side / 6), alpha, false, null, CapsStyle.ROUND, null);
				g.moveTo(cx + Math.cos(a0) * r, cy + Math.sin(a0) * r);
				g.lineTo(cx + Math.cos(a1) * r, cy + Math.sin(a1) * r);
			}
		});
	}

	/**
	 * The four-point star at the centre of the emblem: two elongated diamonds crossed, so
	 * the tips taper instead of ending in a hard corner.
	 */
	public static function sparkle(canvas:Int, radius:Float, color:FlxColor, alpha:Float, ?thin:Float = 0.11):BitmapData
	{
		return raster(canvas, canvas, function(g:Graphics, k:Float)
		{
			var cx:Float = canvas / 2 * k;
			var cy:Float = canvas / 2 * k;
			var r:Float = radius * k;
			var t:Float = r * thin;
			// Control points sit close to the diagonal, which keeps the arms sharp to the
			// tip; pulling them outward would round the star into a flower.
			g.beginFill(color, alpha);
			g.moveTo(cx, cy - r);
			g.curveTo(cx + t * 0.22, cy - t * 0.22, cx + r, cy);
			g.curveTo(cx + t * 0.22, cy + t * 0.22, cx, cy + r);
			g.curveTo(cx - t * 0.22, cy + t * 0.22, cx - r, cy);
			g.curveTo(cx - t * 0.22, cy - t * 0.22, cx, cy - r);
			g.endFill();
		});
	}

	/** Small rounded bar used for the segmented progress gauge. */
	public static function tickMark(width:Int, height:Int, color:FlxColor, alpha:Float):BitmapData
	{
		return raster(width, height, function(g:Graphics, k:Float)
		{
			g.beginFill(color, alpha);
			g.drawRoundRect(0, 0, width * k, height * k, width * k, width * k);
			g.endFill();
		});
	}

	/** A thin soft dot, for comet trails and status LEDs. */
	public static function dot(diameter:Int, color:FlxColor, alpha:Float):BitmapData
	{
		return radialGlow(diameter, color, alpha, 1.4);
	}

	// ═══════════════════════════════════════════════════════════════════════
	//  Panels, pills and bars
	// ═══════════════════════════════════════════════════════════════════════

	public static function roundedRect(width:Int, height:Int, radius:Float, color:FlxColor, alpha:Float):BitmapData
	{
		return raster(width, height, function(g:Graphics, k:Float)
		{
			g.beginFill(color, alpha);
			g.drawRoundRect(0, 0, width * k, height * k, radius * 2 * k, radius * 2 * k);
			g.endFill();
		});
	}

	public static function gradientRoundedRect(width:Int, height:Int, radius:Float, left:FlxColor, right:FlxColor, ?alpha:Float = 1.0):BitmapData
	{
		return raster(width, height, function(g:Graphics, k:Float)
		{
			var m = new Matrix();
			m.createGradientBox(width * k, height * k, 0, 0, 0);
			g.beginGradientFill(GradientType.LINEAR, [left, right], [alpha, alpha], [0, 255], m);
			g.drawRoundRect(0, 0, width * k, height * k, radius * 2 * k, radius * 2 * k);
			g.endFill();
		});
	}

	/**
	 * A hairline that fades out at both ends, so the divider under the wordmark looks
	 * grown rather than cut.
	 */
	public static function fadingLine(width:Int, height:Int, from:FlxColor, to:FlxColor, alpha:Float):BitmapData
	{
		return raster(width, height, function(g:Graphics, k:Float)
		{
			// Two halves, each with its own alpha ramp: violet in and out on the left,
			// cyan in and out on the right, meeting in the middle.
			var seg:Int = Std.int(width / 2);
			for (i in 0...2)
			{
				var m = new Matrix();
				m.createGradientBox(seg * k, height * k, 0, i * seg * k, 0);
				var c0:Int = FlxColor.interpolate(from, to, i * 0.5);
				var c1:Int = FlxColor.interpolate(from, to, 0.5 + i * 0.5);
				var a0:Float = alpha * (i == 0 ? 0.0 : 1.0);
				var a1:Float = alpha * (i == 0 ? 1.0 : 0.0);
				g.beginGradientFill(GradientType.LINEAR, [c0, c1], [a0, a1], [0, 255], m);
				g.drawRect(i * seg * k, 0, seg * k, height * k);
				g.endFill();
			}
		});
	}

	// ═══════════════════════════════════════════════════════════════════════
	//  Splash pieces
	// ═══════════════════════════════════════════════════════════════════════

	/**
	 * One incoming light streak: a bright head that tapers into a fading tail. The splash
	 * flies four of these in from the corners and they converge on the emblem.
	 *
	 * The streak points along +X; the caller rotates the sprite.
	 */
	public static function shard(width:Int, height:Int, color:FlxColor, alpha:Float):BitmapData
	{
		return raster(width, height, function(g:Graphics, k:Float)
		{
			// An elongated ellipse rather than a bar: a rectangle would show hard top and
			// bottom edges, and the streak has to read as light, not as a stick.
			var m = new Matrix();
			m.createGradientBox(width * k, height * k, 0, 0, 0);
			g.beginGradientFill(GradientType.LINEAR, [color, color, color, color], [0, alpha * 0.18, alpha * 0.62, alpha],
				[0, 110, 210, 255], m);
			g.drawEllipse(0, 0, width * k, height * k);
			g.endFill();
		});
	}

	// ═══════════════════════════════════════════════════════════════════════
	//  Rasteriser
	// ═══════════════════════════════════════════════════════════════════════

	/**
	 * Draws paint() into a 2x canvas and downsamples it, which is what gives every stroke
	 * here its anti-aliased edge.
	 *
	 * paint() receives the scale factor and must multiply its own coordinates and widths
	 * by it — doing it this way (instead of scaling the Shape) keeps lineStyle widths
	 * honest, because openfl does not scale a stroke width with the object transform.
	 */
	static function raster(width:Int, height:Int, paint:Graphics->Float->Void):BitmapData
	{
		var w:Int = Std.int(width);
		var h:Int = Std.int(height);
		var out = new BitmapData(w, h, true, 0x00000000);

		var big = new BitmapData(w * SS, h * SS, true, 0x00000000);
		var shape = new Shape();
		paint(shape.graphics, SS);
		big.draw(shape);

		var m = new Matrix();
		m.scale(1 / SS, 1 / SS);
		out.draw(big, m, null, null, null, true);
		big.dispose();
		return out;
	}
}