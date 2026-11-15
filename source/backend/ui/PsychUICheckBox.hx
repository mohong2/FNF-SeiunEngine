package backend.ui;

import flixel.math.FlxMath;

/**
 * Checkbox (and, through {@link PsychUIRadioItem}, a radio button): a 16x16 toggle plus a label.
 *
 * The hit area is an explicit rectangle that covers the box and the label, so the thing that is
 * clickable can never drift away from the thing that is drawn. Hover feedback is a colour tint
 * plus the 0.6.3-style spring pop of the box itself (never a setGraphicSize call: the hit box is
 * fixed, only the sprite's scale changes).
 */
class PsychUICheckBox extends FlxSpriteGroup
{
	public static final CLICK_EVENT = 'checkbox_click';

	public var name:String;
	public var box:FlxSprite;
	public var text:FlxText;
	public var label(get, set):String;

	public var checked(default, set):Bool = false;
	public var onClick:Void->Void = null;

	/** If true, hover/click animate the box instead of snapping. */
	public var smoothAnimations:Bool = true;
	public var broadcastCheckBoxEvent:Bool = true;

	var _hitW:Float = 0;
	var _hitH:Float = 0;
	var _hoverT:Float = 0;
	var _hovered:Bool = false;

	var _pop:Float = 1;
	var _popVel:Float = 0;

	public function new(x:Float, y:Float, label:String, ?textWid:Int = 100, ?callback:Void->Void, ?font:String, ?size:Int = 10)
	{
		super(x, y);

		box = new FlxSprite();
		boxGraphic();
		add(box);

		text = new FlxText(box.width + 4, 0, textWid, (label != null) ? label : '');
		if (font == null) text.font = 'assets/fonts/editors.ttf';
		else text.font = Paths.font(font);
		text.borderSize = 2;
		text.size = size;
		add(text);

		_hitW = box.width + 4 + textWid;
		_hitH = Math.max(box.height, text.height);

		this.onClick = callback;
	}

	public function boxGraphic()
	{
		box.loadGraphic(Paths.image('psych-ui/checkbox', 'embed'), true, 16, 16);
		box.animation.add('false', [0]);
		box.animation.add('true', [1]);
		box.animation.play('false');
	}

	override function update(elapsed:Float)
	{
		super.update(elapsed);

		if (!exists || !visible || !active || box == null || !box.exists || text == null) return;

		var over:Bool = PsychUIHelper.overlapsRect(this, 0, 0, _hitW, _hitH, camera);
		_hovered = over;

		if (smoothAnimations)
			_hoverT = PsychUIHelper.approach(_hoverT, over ? 1 : 0, elapsed, 20);
		else
			_hoverT = over ? 1 : 0;

		box.color = PsychUIHelper.lerpColor(FlxColor.WHITE, 0xFFB8D8FF, _hoverT);

		_tickPop(elapsed, over);

		if (FlxG.mouse.justPressed && over)
		{
			checked = !checked;
			_popVel -= 3.2;
			if (onClick != null) onClick();
			if (broadcastCheckBoxEvent) PsychUIEventHandler.event(CLICK_EVENT, this);
		}
	}

	/** Spring pop of the 16x16 box: 1 -> 1.13 on hover, squash on click, bounce back. */
	function _tickPop(elapsed:Float, over:Bool):Void
	{
		var target:Float = 1;
		if (smoothAnimations) target = 1 + 0.13 * _hoverT;

		if (!smoothAnimations)
		{
			_pop = target;
			_popVel = 0;
		}
		else
		{
			var dt:Float = Math.min(elapsed, 1 / 40);
			_popVel += (target - _pop) * 700 * dt;
			_popVel *= 1 / (1 + 24 * dt);
			_pop += _popVel * dt;

			if (Math.abs(_pop - target) < 0.0006 && Math.abs(_popVel) < 0.006)
			{
				_pop = target;
				_popVel = 0;
			}
		}
		if (box != null && box.exists) box.scale.set(_pop, _pop);
	}

	function set_checked(v:Bool):Bool
	{
		if (box != null && box.animation != null) box.animation.play(Std.string(v));
		return (checked = v);
	}

	function get_label():String
	{
		return (text != null) ? text.text : null;
	}

	function set_label(v:String):String
	{
		if (text != null && text.exists) text.text = (v != null) ? v : '';
		return v;
	}

	override function destroy()
	{
		box = null;
		text = null;
		super.destroy();
	}
}
