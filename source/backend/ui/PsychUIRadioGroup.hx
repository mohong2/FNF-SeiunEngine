package backend.ui;

import flixel.FlxObject;
import flixel.math.FlxMath;
import flixel.util.FlxDestroyUtil;

/**
 * Vertical (or horizontal) list of radio buttons, optionally paged with two scroll arrows.
 *
 * Rewritten to be pool based (the old 'recycle' path instantiated a radio whose constructor
 * needs a label, which is not something reflection can supply) and to compute its own hit box
 * from the items instead of trusting the group's derived bounds - the wheel used to scroll a
 * list only when the pointer happened to be inside a box that was 0 pixels wide.
 */
class PsychUIRadioGroup extends FlxSpriteGroup
{
	public static final CLICK_EVENT = 'radiogroup_click';

	public var labels(default, set):Array<String> = [];
	public var radios:Array<PsychUIRadioItem> = [];

	public var space(default, set):Float = 25;
	public var textWidth(default, set):Int = 100;
	public var maxItems(default, set):Int = 0;

	public var stackHorizontal(default, set):Bool = false;

	public var checked(default, set):Int = -1;
	public var checkedRadio(default, set):PsychUIRadioItem;

	public var arrowUp:FlxSprite;
	public var arrowDown:FlxSprite;

	public var onClick:Void->Void;
	public var broadcastRadioGroupEvent:Bool = true;

	public var curScroll(default, set):Int = 0;

	var _hitbox:FlxObject;
	var _pool:Array<PsychUIRadioItem> = [];
	var _arrowUpT:Float = 0;
	var _arrowDownT:Float = 0;

	public function new(x:Float, y:Float, labels:Array<String>, space:Float = 25, maxItems:Int = 0, ?isHorizontal:Bool = false, ?textWidth:Int = 100)
	{
		super(x, y);

		_hitbox = new FlxObject();

		arrowUp = new FlxSprite().loadGraphic(Paths.image('psych-ui/arrow_up', 'embed'), true, 24, 18);
		arrowUp.animation.add('normal', [0]);
		arrowUp.animation.add('press', [1]);
		arrowUp.animation.play('normal');
		arrowUp.visible = arrowUp.active = false;

		arrowDown = new FlxSprite().loadGraphic(Paths.image('psych-ui/arrow_down', 'embed'), true, 24, 18);
		arrowDown.animation.add('normal', [0]);
		arrowDown.animation.add('press', [1]);
		arrowDown.animation.play('normal');
		arrowDown.visible = arrowDown.active = false;

		this.space = space;
		this.textWidth = textWidth;
		@:bypassAccessor this.stackHorizontal = isHorizontal;
		if (labels != null) this.labels = labels;
		this.maxItems = maxItems;
	}

	override function update(elapsed:Float)
	{
		super.update(elapsed);

		if (!exists || !visible || !active) return;
		if (labels == null) return;

		refreshHitbox();

		if (maxItems > 0 && maxItems < labels.length && FlxG.mouse.wheel != 0 && PsychUIEventHandler.overlaps(_hitbox, camera))
			curScroll -= Std.int(FlxG.mouse.wheel);

		var baseY:Float = y + radios.length * space;
		if (stackHorizontal) baseY = y + 25;

		var hasArrowUp:Bool = (arrowUp != null && arrowUp.exists && arrowUp.visible);
		var hasArrowDown:Bool = (arrowDown != null && arrowDown.exists && arrowDown.visible);

		if (hasArrowDown)
		{
			arrowDown.x = x;
			arrowDown.y = baseY;
		}
		if (hasArrowUp)
		{
			arrowUp.x = x;
			arrowUp.y = baseY;
			if (hasArrowDown) arrowDown.x += arrowUp.width + 8;
		}

		// Smoothly fade the arrows instead of a hard alpha swap.
		if (hasArrowUp)
		{
			var enabledUp:Bool = maxItems > 0 && curScroll > 0;
			_arrowUpT = PsychUIHelper.approach(_arrowUpT, enabledUp ? 1 : 0.4, elapsed, 18);
			arrowUp.alpha = _arrowUpT;
		}
		if (hasArrowDown)
		{
			var enabledDown:Bool = maxItems > 0 && curScroll < (labels.length - maxItems);
			_arrowDownT = PsychUIHelper.approach(_arrowDownT, enabledDown ? 1 : 0.4, elapsed, 18);
			arrowDown.alpha = _arrowDownT;
		}

		if (FlxG.mouse.justPressed)
		{
			if (hasArrowUp && curScroll > 0 && PsychUIEventHandler.overlaps(arrowUp, camera))
			{
				curScroll--;
				arrowUp.animation.play('press');
			}
			else if (hasArrowDown && curScroll < (labels.length - maxItems) && PsychUIEventHandler.overlaps(arrowDown, camera))
			{
				curScroll++;
				arrowDown.animation.play('press');
			}
		}
		else if (!FlxG.mouse.pressed)
		{
			if (hasArrowUp && arrowUp.animation.curAnim != null && arrowUp.animation.curAnim.name != 'normal')
				arrowUp.animation.play('normal');
			if (hasArrowDown && arrowDown.animation.curAnim != null && arrowDown.animation.curAnim.name != 'normal')
				arrowDown.animation.play('normal');
		}
	}

	override function draw()
	{
		super.draw();

		if (arrowUp != null && arrowUp.exists && arrowUp.visible) arrowUp.draw();
		if (arrowDown != null && arrowDown.exists && arrowDown.visible) arrowDown.draw();
	}

	/** Hit box of the whole list (items + arrows), in world space. */
	function refreshHitbox()
	{
		var minX:Float = x;
		var minY:Float = y;
		var maxX:Float = x;
		var maxY:Float = y;

		for (radio in radios)
		{
			if (radio == null || !radio.visible) continue;
			minX = Math.min(minX, radio.x);
			minY = Math.min(minY, radio.y);
			maxX = Math.max(maxX, radio.x + radio.width);
			maxY = Math.max(maxY, radio.y + radio.height);
		}
		if (arrowUp != null && arrowUp.visible)
		{
			maxX = Math.max(maxX, arrowUp.x + arrowUp.width);
			maxY = Math.max(maxY, arrowUp.y + arrowUp.height);
		}
		if (arrowDown != null && arrowDown.visible)
		{
			maxX = Math.max(maxX, arrowDown.x + arrowDown.width);
			maxY = Math.max(maxY, arrowDown.y + arrowDown.height);
		}

		_hitbox.x = minX;
		_hitbox.y = minY;
		_hitbox.width = Math.max(1, maxX - minX);
		_hitbox.height = Math.max(1, maxY - minY);
	}

	override function destroy()
	{
		_hitbox = FlxDestroyUtil.destroy(_hitbox);
		arrowUp = FlxDestroyUtil.destroy(arrowUp);
		arrowDown = FlxDestroyUtil.destroy(arrowDown);
		_pool = [];
		radios = [];
		super.destroy();
	}

	function set_curScroll(v:Int)
	{
		var lastScroll:Int = curScroll;
		if (maxItems > 0 && labels != null && labels.length > maxItems)
		{
			curScroll = Std.int(FlxMath.bound(v, 0, labels.length - maxItems));
			if (arrowUp != null && arrowUp.exists) arrowUp.visible = arrowUp.active = true;
			if (arrowDown != null && arrowDown.exists) arrowDown.visible = arrowDown.active = true;
		}
		else
		{
			curScroll = 0;
			if (arrowUp != null && arrowUp.exists) arrowUp.visible = arrowUp.active = false;
			if (arrowDown != null && arrowDown.exists) arrowDown.visible = arrowDown.active = false;
		}
		if (curScroll != lastScroll)
		{
			checked += (lastScroll - curScroll);
			updateRadioItems();
		}
		return curScroll;
	}

	function set_stackHorizontal(v:Bool)
	{
		stackHorizontal = v;
		updateRadioItems();
		return stackHorizontal;
	}

	function set_checked(v:Int)
	{
		if (radios == null) return checked = -1;
		var maxIndex:Int = Std.int(Math.min((labels != null ? labels.length : 0) - 1, radios.length - 1));
		checked = Std.int(FlxMath.bound(v, -1, Math.max(-1, maxIndex)));
		@:bypassAccessor checkedRadio = null;
		for (num => radio in radios)
		{
			if (radio == null) continue;
			radio.checked = (num == checked);
			if (num == checked) @:bypassAccessor checkedRadio = radio;
		}
		return checked;
	}

	function set_labels(v:Array<String>)
	{
		labels = (v != null) ? v : [];
		updateRadioItems();
		set_checked(checked);
		set_curScroll(curScroll);
		return labels;
	}

	function set_checkedRadio(v:PsychUIRadioItem)
	{
		checkedRadio = null;
		@:bypassAccessor checked = -1;
		for (num => radio in radios)
		{
			if (radio == null) continue;
			radio.checked = (v == radio);
			if (v == radio)
			{
				checkedRadio = radio;
				@:bypassAccessor checked = num;
			}
		}
		return checkedRadio;
	}

	function set_space(v:Float)
	{
		space = v;
		for (num => radio in radios)
		{
			if (radio == null) continue;
			if (!stackHorizontal) radio.y = y + num * space;
			else radio.x = x + num * (textWidth + space);
		}
		return space;
	}

	function set_textWidth(v:Int)
	{
		textWidth = v;
		for (radio in radios)
			if (radio != null && radio.text != null) radio.text.fieldWidth = textWidth;
		return textWidth;
	}

	function set_maxItems(v:Int)
	{
		maxItems = v;
		set_curScroll(curScroll);
		updateRadioItems();
		return maxItems;
	}

	public function updateRadioItems()
	{
		if (labels == null) labels = [];

		var wanted:Int = (maxItems > 0) ? maxItems : labels.length;

		// Recycle the surplus radios instead of killing them (killing a sprite of a group that is
		// still drawn leaves it in the draw list as a dead member).
		while (radios.length > wanted)
		{
			var extra:PsychUIRadioItem = radios.pop();
			if (extra == null) continue;
			extra.visible = extra.active = false;
			remove(extra, true);
			_pool.push(extra);
		}
		while (radios.length < wanted)
			_addNewRadio();

		for (num => radio in radios)
		{
			if (radio == null) continue;
			var hasLabel:Bool = (num + curScroll) < labels.length;
			radio.visible = radio.active = hasLabel;
			var label:String = hasLabel ? labels[num + curScroll] : '';
			radio.label = (label != null) ? label : '';

			if (!stackHorizontal)
			{
				radio.x = x;
				radio.y = y + num * space;
			}
			else
			{
				radio.x = x + num * (textWidth + space);
				radio.y = y;
			}
		}
	}

	override function set_cameras(v:Array<FlxCamera>)
	{
		if (arrowUp != null && arrowUp.exists) arrowUp.cameras = v;
		if (arrowDown != null && arrowDown.exists) arrowDown.cameras = v;
		return super.set_cameras(v);
	}

	override function set_camera(v:FlxCamera)
	{
		if (arrowUp != null && arrowUp.exists) arrowUp.camera = v;
		if (arrowDown != null && arrowDown.exists) arrowDown.camera = v;
		return super.set_camera(v);
	}

	function _addNewRadio():PsychUIRadioItem
	{
		var radio:PsychUIRadioItem = _pool.pop();
		if (radio == null)
			radio = new PsychUIRadioItem(0, 0, '', textWidth);
		else
			radio.visible = radio.active = true;

		// EVERY radio has to join the group, not only a recycled one: a radio that is absent from
		// 'members' still lands in 'radios' (and in the hit box), but it is never updated or
		// drawn. Missing this add() made every freshly built radio list - the chart editor's
		// save-format prompt, the difficulty pickers, the chart converter - render empty.
		add(radio);
		radio.x = x;
		radio.y = y;

		radio.onClick = function()
		{
			checkedRadio = radio;
			if (onClick != null) onClick();
			if (broadcastRadioGroupEvent) PsychUIEventHandler.event(CLICK_EVENT, this);
		};
		radio.visible = radio.active = true;
		if (radio.text != null) radio.text.fieldWidth = textWidth;
		radios.push(radio);
		return radio;
	}
}

class PsychUIRadioItem extends PsychUICheckBox
{
	public function new(x:Float, y:Float, label:String, textWid:Int = 100)
	{
		super(x, y, label, textWid);
		broadcastCheckBoxEvent = false;
	}

	override function boxGraphic()
	{
		box.loadGraphic(Paths.image('psych-ui/radio', 'embed'), true, 16, 16);
		box.animation.add('false', [0]);
		box.animation.add('true', [1]);
		box.animation.play('false');
	}
}
