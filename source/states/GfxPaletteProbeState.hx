package states;

import backend.gfx.GfxPalette;
import flixel.FlxG;
import flixel.FlxSprite;
import flixel.graphics.FlxGraphic;
import flixel.graphics.frames.FlxAtlasFrames;
import flixel.graphics.tile.FlxDrawBaseItem;
import flixel.util.FlxColor;
import mohong.TraceManager;
import Paths;

/**
 * Test-only state for L1b acceptance runs. It loads one real atlas (or one real
 * plain image) through Paths, shows it at 1:1, and optionally creates N sprites
 * to measure batching. It never runs unless FNF_GFX_PALETTE_TEST is set.
 */
class GfxPaletteProbeState extends MusicBeatState
{
	var key:String;
	var spriteCount:Int = 1;
	var framesSeen:Int = 0;
	var elapsedSum:Float = 0;
	var logged:Bool = false;

	public function new(key:String)
	{
		super();
		this.key = key;
	}

	override public function create():Void
	{
		super.create();
		FlxG.camera.bgColor = FlxColor.BLACK;
		#if sys
		var countText:String = Sys.getEnv('FNF_GFX_PALETTE_SPRITES');
		if (countText != null && countText.length > 0)
		{
			var parsed:Null<Int> = Std.parseInt(countText);
			if (parsed != null && parsed > 0) spriteCount = parsed;
		}
		#end

		#if sys
		// Resolve the probe key inside a real mod folder, e.g. FNF_GFX_PALETTE_TEST_MOD=10m.
		var modDir:String = Sys.getEnv('FNF_GFX_PALETTE_TEST_MOD');
		if (modDir != null && modDir.length > 0) Paths.currentModDirectory = modDir;
		#end

		var frames:FlxAtlasFrames = Paths.getSparrowAtlas(key);
		var graphic:FlxGraphic = null;
		var frameIndex:Int = 0;
		if (frames != null && frames.frames != null && frames.frames.length > 0)
		{
			graphic = frames.parent;
		}
		else
		{
			graphic = Paths.image(key);
			if (graphic == null)
			{
				TraceManager.error('trace.gfx.paletteProbeState', 'GfxPaletteProbe cannot load {}', [key]);
				return;
			}
		}

		// For plain images the preDraw queue would do this; call it now so the
		// probe logs and the screenshot share the same frame.
		GfxPalette.apply(graphic);

		#if sys
		if (Sys.getEnv('FNF_GFX_PALETTE_READ') == '1' && graphic.bitmap.paletteApplied)
		{
			// CPU read path: drop the RGBA image, then read a pixel. The restore
			// callback must bring back identical bytes and the palette must survive.
			var bmp = graphic.bitmap;
			var tx:Int = Std.int(bmp.width / 2);
			var ty:Int = Std.int(bmp.height / 2);
			var probePoints:Array<Array<Int>> = [[tx, ty], [tx + 32, ty], [tx, ty + 32], [tx - 32, ty], [tx, ty - 32]];
			for (point in probePoints)
			{
				if (point[0] >= 0 && point[1] >= 0 && point[0] < bmp.width && point[1] < bmp.height
					&& bmp.getPixel32(point[0], point[1]) != 0)
				{
					tx = point[0];
					ty = point[1];
					break;
				}
			}
			var before:Int = bmp.getPixel32(tx, ty);
			var ctx = FlxG.stage.context3D;
			bmp.getTexture(ctx);
			var dropped:Bool = bmp.dropCPU();
			var after:Int = bmp.getPixel32(tx, ty);
			var line:String = 'cpu_read x=' + Std.string(tx) + ' y=' + Std.string(ty)
				+ ' dropped=' + Std.string(dropped)
				+ ' before=0x' + StringTools.hex(before, 8)
				+ ' after=0x' + StringTools.hex(after, 8)
				+ ' equal=' + Std.string(before == after)
				+ ' palette=' + Std.string(bmp.paletteApplied);
			Sys.println('[GfxPalette] ' + line);
		}
		#end

		for (i in 0...spriteCount)
		{
			var sprite:FlxSprite = new FlxSprite();
			if (frames != null && frames.frames != null && frames.frames.length > 0)
			{
				sprite.frames = frames;
				sprite.frame = frames.frames[i % frames.frames.length];
				frameIndex = i % frames.frames.length;
			}
			else
			{
				sprite.loadGraphic(graphic);
			}
			sprite.antialiasing = false;
			if (spriteCount == 1)
			{
				sprite.setPosition(0, 0);
			}
			else
			{
				// 10 columns; overlap is fine, this run measures batching only.
				sprite.setPosition((i % 10) * 64, Std.int(i / 10) * 64);
				sprite.scale.set(0.25, 0.25);
				sprite.updateHitbox();
			}
			add(sprite);
		}

		TraceManager.info('trace.gfx.paletteProbeState',
			'GfxPaletteProbe key={} sprites={} frame={} bitmap={}x{}',
			[key, Std.string(spriteCount), Std.string(frameIndex), Std.string(graphic.bitmap.width), Std.string(graphic.bitmap.height)]);
		#if sys
		Sys.println('[GfxPaletteProbe] key=' + key + ' sprites=' + Std.string(spriteCount)
			+ ' frame=' + Std.string(frameIndex)
			+ ' bitmap=' + Std.string(graphic.bitmap.width) + 'x' + Std.string(graphic.bitmap.height)
			+ ' palette=' + Std.string(graphic.bitmap.paletteApplied));
		#end
	}

	override public function update(elapsed:Float):Void
	{
		super.update(elapsed);
		framesSeen++;
		elapsedSum += elapsed;
		if (!logged && framesSeen >= 120)
		{
			logged = true;
			var avgMs:Float = elapsedSum / framesSeen * 1000;
			var line:String = 'frames=' + Std.string(framesSeen)
				+ ' avgFrameMs=' + Std.string(Math.round(avgMs * 100) / 100)
				+ ' fps=' + Std.string(Math.round(1000 / avgMs * 10) / 10)
				+ ' drawCalls=' + Std.string(FlxDrawBaseItem.drawCalls);
			TraceManager.info('trace.gfx.paletteProbeState', 'GfxPaletteProbe ' + line);
			#if sys
			Sys.println('[GfxPaletteProbe] ' + line);
			#end
		}
	}

	override public function destroy():Void
	{
		super.destroy();
	}
}
