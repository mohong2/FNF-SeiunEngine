#if desktop
package backend;

import openfl.display.Stage;
import openfl.events.Event;
import openfl.text.TextField;
import openfl.text.TextFieldAutoSize;
import openfl.text.TextFormat;

/**
 *这是一大堆棍母
 */
class RenderIndicator
{
	static inline var MARGIN:Float = 8;
	static inline var SIZE:Int = 16;

	static var field:TextField;
	static var installed:Bool = false;
	static var visible:Bool = false;

	public static function install():Void
	{
		if (installed) return;

		var stage:Stage = flixel.FlxG.stage;
		if (stage == null) return;
		installed = true;

		field = new TextField();
		field.defaultTextFormat = new TextFormat("_sans", SIZE, 0xFFFFFF, true);
		field.autoSize = TextFieldAutoSize.LEFT;
		field.selectable = false;
		field.mouseEnabled = false;
		field.text = "REC";
		field.visible = false;

		stage.addChild(field);
		stage.addEventListener(Event.RESIZE, function(_) layout());
		layout();
	}

	static function layout():Void
	{
		if (field == null) return;
		var stage:Stage = flixel.FlxG.stage;
		if (stage == null) return;
		field.x = MARGIN;
		field.y = MARGIN;
	}

	/** Shows/hides the badge. Cheap to call every frame; it early-outs. */
	public static function setVisible(value:Bool):Void
	{
		if (!installed) install();
		if (field == null || visible == value) return;
		visible = value;
		field.visible = value;
	}

	/**
	 * Updates the badge text with live counters. Called at most a few times per
	 * second by the render owner, never per frame.
	 */
	public static function setText(text:String):Void
	{
		if (field == null) return;
		if (field.text != text)
		{
			field.text = text;
			layout();
		}
	}
}
#end