package backend.ui;

import flixel.util.FlxDestroyUtil;

/**
 * One tab header of a {@link PsychUIBox}.
 *
 * The tab owns its label and the page group ('menu') that holds the page content. The menu is
 * deliberately NOT a child of the box: the box updates/draws only the selected page, so a hidden
 * page can never read the mouse or steal a click.
 *
 * The header graphic is baked at its exact size. Scaling a 1x1 pixel (what this used to do)
 * leaves updateHitbox() fighting the origin, and the header, its label and its hit box end up at
 * three different places.
 */
class PsychUITab extends FlxSprite
{
	public var name(default, set):String;
	public var text:FlxText;
	public var menu:FlxSpriteGroup;

	var _bakedW:Int = 0;
	var _bakedH:Int = 0;

	public function new(name:String, ?font:String)
	{
		super();
		PsychUIHelper.bakeRounded(this, 1, 1, 0);
		color = FlxColor.BLACK;
		alpha = 0.6;

		menu = new FlxSpriteGroup();

		@:bypassAccessor this.name = name;
		var label:String = (name == null) ? '' : (Language.has(name) ? Language.get(name) : name);

		text = new FlxText(0, 0, 100, label);
		if (font == null) text.font = 'assets/fonts/editors.ttf';
		else text.font = Paths.font(font);
		text.size = 9;
		text.borderSize = 4;
		text.alignment = CENTER;
	}

	override function draw()
	{
		if (!exists || !visible) return;
		super.draw();

		if (text != null && text.exists)
		{
			text.visible = visible;
			text.x = x;
			text.y = y + (height - text.height) * 0.5;
			text.draw();
		}
	}

	override function destroy()
	{
		text = FlxDestroyUtil.destroy(text);
		menu = FlxDestroyUtil.destroy(menu);
		super.destroy();
	}

	/** Keeps the page group glued under the tab row. */
	public function updateMenu(parent:PsychUIBox, elapsed:Float)
	{
		if (menu == null || !menu.exists || !menu.active || parent == null) return;
		menu.scrollFactor.set(parent.scrollFactor.x, parent.scrollFactor.y);
		menu.x = parent.x;
		menu.y = parent.y + parent.tabHeight;
		menu.update(elapsed);
	}

	public function drawMenu(parent:PsychUIBox)
	{
		if (menu == null || !menu.exists || !menu.visible || parent == null) return;
		menu.x = parent.x;
		menu.y = parent.y + parent.tabHeight;
		menu.draw();
	}

	/** Gives the header a real w x h graphic (scale stays 1, offset stays 0). */
	public function resize(width:Int, height:Int)
	{
		var w:Int = Std.int(Math.max(1, width));
		var h:Int = Std.int(Math.max(1, height));

		if (w != _bakedW || h != _bakedH)
		{
			_bakedW = w;
			_bakedH = h;
			PsychUIHelper.bakeRounded(this, w, h, 0);
		}

		if (text != null) text.fieldWidth = w;
	}

	function set_name(v:String)
	{
		if (text != null)
		{
			var label:String = (v == null) ? '' : (Language.has(v) ? Language.get(v) : v);
			text.text = label;
		}
		return (name = v);
	}

	override function set_cameras(v:Array<FlxCamera>)
	{
		if (text != null) text.cameras = v;
		if (menu != null) menu.cameras = v;
		return super.set_cameras(v);
	}

	override function set_camera(v:FlxCamera)
	{
		if (text != null) text.camera = v;
		if (menu != null) menu.camera = v;
		return super.set_camera(v);
	}
}
