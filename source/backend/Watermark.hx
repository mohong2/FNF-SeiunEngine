package backend;

import flixel.FlxG;
import openfl.display.Stage;
import openfl.events.Event;
import openfl.text.TextField;
import openfl.text.TextFieldAutoSize;
import openfl.text.TextFormat;

/**
 * Bottom-right build watermark: version + build id, drawn on the openfl stage instead of
 * inside flixel.
 *
 * Why the stage: a flixel-side sprite would need one instance per state (and would still
 * miss the preloader and the crash screen), and it would be subject to cameras, zoom and
 * transitions. An openfl child of the stage sits above every state and substate, ignores
 * flixel cameras entirely, and cannot swallow input as long as mouseEnabled/selectable
 * stay false.
 *
 * Rules kept from the design agreed with the user:
 *   * never visible while playing a song (PlayState turns it off and back on),
 *   * tiny and translucent (alpha 0.3), bottom-right, 6px margin,
 *   * re-laid out only on stage resize, never per frame,
 *   * ASCII-only text, because the default font on Android has no CJK glyphs,
 *   * switchable through ClientPrefs.data.showWatermark.
 */
class Watermark
{
	static inline var MARGIN:Float = 6;
	static inline var MIN_SIZE:Int = 10;
	static inline var MAX_SIZE:Int = 18;
	static inline var ALPHA:Float = 0.3;

	static var field:TextField;
	static var shadow:TextField;
	static var installed:Bool = false;
	/** True while gameplay asked for the watermark to stay out of the way. */
	static var hiddenForGameplay:Bool = false;

	/** Attach the watermark to the stage. Call once, after the FlxGame child exists. */
	public static function install():Void
	{
		if (installed) return;

		var stage:Stage = FlxG.stage;
		if (stage == null) return;
		installed = true;

		shadow = buildField();
		field = buildField();

		// The dark copy sits one pixel below/right so the text stays readable on both
		// light and dark menus without a filter (filters are expensive on mobile).
		stage.addChild(shadow);
		stage.addChild(field);
		stage.addEventListener(Event.RESIZE, onResize);

		layout();
		apply();
	}

	/** Gameplay visibility switch (PlayState.create / destroy). */
	public static function setVisible(visible:Bool):Void
	{
		hiddenForGameplay = !visible;
		apply();
	}

	/** Re-read the settings toggle (called when the option changes). */
	public static function refresh():Void
	{
		apply();
	}

	static function buildField():TextField
	{
		var tf:TextField = new TextField();
		tf.mouseEnabled = false;
		tf.selectable = false;
		tf.multiline = false;
		tf.wordWrap = false;
		tf.autoSize = TextFieldAutoSize.LEFT;
		tf.alpha = ALPHA;
		return tf;
	}

	/** Only runs on install and on stage resize; never per frame. */
	static function layout():Void
	{
		if (field == null || shadow == null) return;

		var stage:Stage = FlxG.stage;
		if (stage == null) return;

		var size:Int = Std.int(stage.stageHeight / 80);
		if (size < MIN_SIZE) size = MIN_SIZE;
		if (size > MAX_SIZE) size = MAX_SIZE;

		var text:String = BuildInfo.watermarkText();

		// defaultTextFormat covers the text set below, setTextFormat re-applies it to the
		// whole range: without it the field would fall back to 12px black and vanish.
		var mainFormat:TextFormat = new TextFormat(null, size, 0xFFFFFF);
		field.defaultTextFormat = mainFormat;
		field.text = text;
		field.setTextFormat(mainFormat);
		installPosition(field, stage);

		var shadowFormat:TextFormat = new TextFormat(null, size, 0x000000);
		shadow.defaultTextFormat = shadowFormat;
		shadow.text = text;
		shadow.setTextFormat(shadowFormat);
		installPosition(shadow, stage);
		shadow.x += 1;
		shadow.y += 1;
	}

	static function installPosition(tf:TextField, stage:Stage):Void
	{
		tf.x = stage.stageWidth - tf.width - MARGIN;
		tf.y = stage.stageHeight - tf.height - MARGIN;
	}

	static function apply():Void
	{
		if (field == null) return;
		var visible:Bool = !hiddenForGameplay && ClientPrefs.data.showWatermark;
		field.visible = visible;
		shadow.visible = visible;
	}

	static function onResize(event:Event):Void
	{
		layout();
	}
}
