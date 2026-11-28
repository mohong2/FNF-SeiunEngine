package android.flixel;

import flixel.input.keyboard.FlxKey;
import EKData.Keybinds;
import states.PlayState;
import flixel.util.FlxDestroyUtil;
import android.flixel.FlxButton;
import flixel.FlxSprite;
import openfl.display.BitmapData;
import openfl.display.Shape;
import openfl.events.KeyboardEvent;
import Replay;

/**
 * A zone with 4 hint's (A hitbox).
 * It's really easy to customize the layout.
 *
 * @author Mihai Alexandru (M.A. Jigsaw)
 */
class FlxHitbox extends FlxSpriteGroup
{
	final offsetFir:Int = (ClientPrefs.data.hitboxPos ? Std.int(FlxG.height / 4) * 3 : 0);
	final offsetSec:Int = (ClientPrefs.data.hitboxPos ? 0 : Std.int(FlxG.height / 4));
	final bottomHeight:Int = 120; // 底部区域高度

	public var hints(default, null):Array<FlxButton>;

	/**
	 * Create the zone.
	 * 
	 * @param ammo The ammount of hints you want to create.
	 * @param perHintWidth The width that the hints will use.
	 * @param perHintHeight The height that the hints will use.
	 * @param colors The color per hint.
	 */
	public function new(ammo:UInt, perHintWidth:Int, perHintHeight:Int, colors:Array<FlxColor>):Void
	{
		super();

		hints = new Array<FlxButton>();

		if (colors == null || (colors != null && colors.length < ammo))
			colors = [0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF];

		// 多k: 强制 Hitbox 时只保留轨道色块, SPACE/SHIFT 附加块和移动额外键块一律不参与,
		// 也不为它们预留上/下空带 (否则多k 会在顶部或底部留下一整条空白)。
		var isMultiK:Bool = (PlayState.SONG != null && PlayState.SONG.mania != null && PlayState.SONG.mania != Note.defaultMania);
		var canShowExtras:Bool = !isMultiK && ammo <= 4;
		var showExtra:Bool = ClientPrefs.data.hitboxExtraToggle && canShowExtras;

		var topHeight = perHintHeight - bottomHeight;
		var halfWidth = Std.int(FlxG.width / 2);

		var mainY:Int;
		var mainH:Int;
		var extraY:Int = 0;

		if (showExtra)
		{
			if (ClientPrefs.data.hitboxExtraPos == "Top")
			{
				extraY = 0;
				if (ClientPrefs.data.mobileCEx)
				{
					mainY = offsetSec + bottomHeight;
					mainH = Std.int(FlxG.height / ammo) * 3 - bottomHeight;
				}
				else
				{
					mainY = bottomHeight;
					mainH = topHeight;
				}
			}
			else
			{
				if (ClientPrefs.data.mobileCEx)
				{
					mainY = offsetSec;
					mainH = Std.int(FlxG.height / ammo) * 3;
				}
				else
				{
					mainY = 0;
					mainH = topHeight;
				}
				extraY = mainY + mainH;
			}
		}
		else if (ClientPrefs.data.mobileCEx && canShowExtras)
		{
			mainY = offsetSec;
			mainH = Std.int(FlxG.height / ammo) * 3;
		}
		else
		{
			mainY = 0;
			mainH = perHintHeight;
		}

		for (i in 0...ammo)
		{
			add(hints[i] = createHint(i * perHintWidth, mainY, perHintWidth, mainH, colors[i], i));
			addHintBorder(i * perHintWidth, mainY, perHintWidth, mainH, colors[i]);
		}

		if (showExtra)
		{
			add(hints[4] = createHint(0, extraY, halfWidth, bottomHeight, 0xFFFF00));
			add(hints[5] = createHint(halfWidth, extraY, halfWidth, bottomHeight, 0x00FFFF));
			addHintBorder(0, extraY, halfWidth, bottomHeight, 0xFFFF00);
			addHintBorder(halfWidth, extraY, halfWidth, bottomHeight, 0x00FFFF);
		}

		if (ClientPrefs.data.mobileCEx && canShowExtras)
		{
			add(hints[6] = createHint(0, offsetFir, FlxG.width, Std.int(FlxG.height / 4), 0xFF0066FF));
			addHintBorder(0, offsetFir, FlxG.width, Std.int(FlxG.height / 4), 0xFF0066FF);
		}

		scrollFactor.set();
	}

	/**
	 * Clean up memory.
	 */
	override public function destroy():Void
	{
		super.destroy();

		for (i in 0...hints.length)
			hints[i] = FlxDestroyUtil.destroy(hints[i]);

		hints.splice(0, hints.length);
	}


	private function createHint(X:Float, Y:Float, Width:Int, Height:Int, Color:Int = 0xFFFFFF, ?hintIndex:Int = -1):FlxButton
	{
		// 未按下时完全透明, 按下后才显示色块 (透明度由 hitboxPressAlpha 控制)。
		final idleAlpha:Float = 0.00001;
		var hint:FlxButton = new FlxButton(X, Y);
		hint.loadGraphic(createHintGraphic(Width, Height, Color));
		hint.solid = false;
		hint.multiTouch = true;
		hint.immovable = true;
		hint.moves = false;
		hint.antialiasing = ClientPrefs.data.globalAntialiasing;
		hint.scrollFactor.set();
		hint.alpha = idleAlpha;

		var notifyKeyName:String = null;
		var simKey:FlxKey = FlxKey.NONE;
		var isMultiK:Bool = (PlayState.SONG != null && PlayState.SONG.mania != null && PlayState.SONG.mania != Note.defaultMania);
		if (isMultiK)
		{
			// 多k: 所有轨道直接按多k键位 (0-3 也读多k键位)
			var mania:Int = (PlayState.SONG != null && PlayState.SONG.mania != null) ? PlayState.SONG.mania : Note.defaultMania;
			var binds:Array<Array<Dynamic>> = Keybinds.fill();
			if (mania >= 0 && mania < binds.length && hintIndex >= 0 && hintIndex < binds[mania].length)
			{
				var laneKeys:Array<FlxKey> = binds[mania][hintIndex];
				if (laneKeys != null && laneKeys.length > 0)
					notifyKeyName = Std.string(laneKeys[0]);
			}
		}
		else if (hintIndex >= 0 && hintIndex < 4)
		{
			var bindName:String = switch(hintIndex) {
				case 0: 'note_left';
				case 1: 'note_down';
				case 2: 'note_up';
				case 3: 'note_right';
				default: null;
			}
			if (bindName != null)
			{
				var noteKeys:Array<FlxKey> = ClientPrefs.keyBinds.get(bindName);
				if (noteKeys != null && noteKeys.length > 0)
					notifyKeyName = Std.string(noteKeys[0]);
			}
		}
		else if (Color == 0xFFFF00)
			simKey = FlxKey.SPACE;
		else if (Color == 0x00FFFF)
			simKey = FlxKey.SHIFT;

		// 多k: 4K 以上轨道 (或整个多k Hitbox) → 直接驱动 PlayState 按键
		if (hintIndex >= 4 || isMultiK)
		{
			if (notifyKeyName == null)
				notifyKeyName = Std.string(FlxKey.NONE);
		}

		if (simKey != FlxKey.NONE)
		{
			var keyCode:Int = simKey;
			var charCode:Int = (simKey == FlxKey.SPACE) ? 32 : 0;
			var isDown:Bool = false;
			var pressSim:Void->Void = function()
			{
				if (isDown) return;
				isDown = true;
				FlxG.stage.dispatchEvent(new KeyboardEvent(KeyboardEvent.KEY_DOWN, true, false, charCode, keyCode));
			};
			var releaseSim:Void->Void = function()
			{
				if (!isDown) return; 
				isDown = false;
				FlxG.stage.dispatchEvent(new KeyboardEvent(KeyboardEvent.KEY_UP, true, false, charCode, keyCode));
			};
			hint.onDown.callback = pressSim;
			hint.onUp.callback = releaseSim;
			hint.onOut.callback = releaseSim;
		}
		else if (notifyKeyName != null)
		{
			hint.onDown.callback = function() { Replay.notifyPress(notifyKeyName); };
			hint.onUp.callback = function() { Replay.notifyRelease(notifyKeyName); };
			hint.onOut.callback = function() { Replay.notifyRelease(notifyKeyName); };
		}

		// 多k: 直接驱动按键 (同时保留 Replay 录制)
		if (hintIndex >= 4 || isMultiK)
		{
			var oldDown = hint.onDown.callback;
			var oldUp = hint.onUp.callback;
			var oldOut = hint.onOut.callback;
			hint.onDown.callback = function()
			{
				if (oldDown != null) oldDown();
				// 异步判定: 把这一下的触摸时刻一起送进去 (没有时间戳就是 0, 判定走原路径)。
				if (PlayState.instance != null) PlayState.instance.mobileKeyPressed(hintIndex, hint.pressTimestampNs);
			};
			hint.onUp.callback = function()
			{
				if (oldUp != null) oldUp();
				if (PlayState.instance != null) PlayState.instance.mobileKeyReleased(hintIndex);
			};
			hint.onOut.callback = function()
			{
				if (oldOut != null) oldOut();
				if (PlayState.instance != null) PlayState.instance.mobileKeyReleased(hintIndex);
			};
		}

		// 异步判定: 4K 色块不经过 mobileKeyPressed (那条路只给 4 键以上/多k), 按下时刻单独送。
		if (!isMultiK && hintIndex >= 0 && hintIndex < 4)
		{
			var oldDown = hint.onDown.callback;
			hint.onDown.callback = function()
			{
				if (oldDown != null) oldDown();
				if (PlayState.instance != null) PlayState.instance.mobileNotePressed(hintIndex, hint.pressTimestampNs);
			};
		}

		// ---- 视觉反馈（仅在非隐藏模式下） ----
		if (ClientPrefs.data.hitboxType != "Hidden")
		{
			var oldDown = hint.onDown.callback;
			var oldUp = hint.onUp.callback;
			var oldOut = hint.onOut.callback;

			hint.onDown.callback = function()
			{
				if (oldDown != null) oldDown();
				var pressAlpha:Float = ClientPrefs.data.hitboxPressAlpha;
				if (hint.alpha != pressAlpha) hint.alpha = pressAlpha;
			}
			hint.onUp.callback = function()
			{
				if (oldUp != null) oldUp();
				if (hint.alpha != idleAlpha) hint.alpha = idleAlpha;
			}
			hint.onOut.callback = function()
			{
				if (oldOut != null) oldOut();
				if (hint.alpha != idleAlpha) hint.alpha = idleAlpha;
			}
		}
		#if FLX_DEBUG
		hint.ignoreDrawDebug = true;
		#end
		return hint;
}

	private function createHintGraphic(Width:Int, Height:Int, Color:Int = 0xFFFFFF):BitmapData
	{
		// 柔和色块: 中心实色、边缘渐隐, 比硬矩形更贴近原版 Hitbox 观感。
		// 可见性完全交给 hint.alpha 控制 (未按下≈0, 按下=hitboxPressAlpha)。
		var shape:Shape = new Shape();
		shape.graphics.beginGradientFill(RADIAL, [Color, FlxColor.TRANSPARENT], [1, 0], [0, 255], null, null, null, 0.5);
		shape.graphics.drawRect(0, 0, Width, Height);
		shape.graphics.endFill();
		var bitmap:BitmapData = new BitmapData(Width, Height, true, 0);
		bitmap.draw(shape, true);
		return bitmap;
	}

	/** 色块边框 (仅帮助定位触摸区域, 不参与触摸判定)。 */
	private function addHintBorder(X:Float, Y:Float, Width:Int, Height:Int, Color:Int):Void
	{
		if (!ClientPrefs.data.hitboxBorder)
			return;

		var border:FlxSprite = new FlxSprite(X, Y);
		border.loadGraphic(createBorderGraphic(Width, Height, Color));
		border.solid = false;
		border.moves = false;
		border.scrollFactor.set();
		border.alpha = 0.2;
		border.antialiasing = ClientPrefs.data.globalAntialiasing;
		#if FLX_DEBUG
		border.ignoreDrawDebug = true;
		#end
		add(border);
	}

	private function createBorderGraphic(Width:Int, Height:Int, Color:Int):BitmapData
	{
		final thickness:Int = 1;
		var shape:Shape = new Shape();
		// 边框与色块同色, 细且浅, 便于定位又不抢视觉。
		shape.graphics.lineStyle(thickness, Color, 1);
		shape.graphics.drawRect(thickness * 0.5, thickness * 0.5, Width - thickness, Height - thickness);
		var bitmap:BitmapData = new BitmapData(Width, Height, true, 0);
		bitmap.draw(shape, true);
		return bitmap;
	}
}
