package backend.ui;

import flixel.math.FlxMath;

/**
 * Numeric input with +/- buttons (a {@link PsychUIInputText} that filters and clamps its value).
 *
 * The buttons animate a small press pop, and every accessor is guarded so a stepper that is
 * still being constructed (min/max are read from the constructor) or already destroyed cannot
 * touch a null label.
 */
class PsychUINumericStepper extends PsychUIInputText
{
	public static final CHANGE_EVENT = "numericstepper_change";

	public var step:Float = 0;
	public var min(default, set):Float = 0;
	public var max(default, set):Float = 0;
	public var decimals(default, set):Int = 0;
	public var isPercent(default, set):Bool = false;
	public var buttonPlus:FlxSprite;
	public var buttonMinus:FlxSprite;

	public var onValueChange:Void->Void;
	public var value(default, set):Float;

	/** Press animation state of the two buttons (smoothed). */
	var _plusT:Float = 0;
	var _minusT:Float = 0;
	var _pressedPlus:Bool = false;
	var _pressedMinus:Bool = false;

	public function new(x:Float = 0, y:Float = 0, step:Float = 1, defValue:Float = 0, min:Float = -999, max:Float = 999, decimals:Int = 0, ?wid:Int = 60, ?isPercent:Bool = false)
	{
		super(x, y, wid, '');
		fieldWidth = Std.int(behindText.width + 2);
		@:bypassAccessor this.decimals = decimals;
		@:bypassAccessor this.isPercent = isPercent;
		@:bypassAccessor this.min = min;
		@:bypassAccessor this.max = max;
		this.step = step;
		_updateFilter();

		buttonPlus = new FlxSprite(fieldWidth).loadGraphic(Paths.image('psych-ui/stepper_plus', 'embed'), true, 16, 16);
		buttonPlus.animation.add('normal', [0], false);
		buttonPlus.animation.add('pressed', [1], false);
		buttonPlus.animation.play('normal');
		add(buttonPlus);

		buttonMinus = new FlxSprite(fieldWidth + buttonPlus.width).loadGraphic(Paths.image('psych-ui/stepper_minus', 'embed'), true, 16, 16);
		buttonMinus.animation.add('normal', [0], false);
		buttonMinus.animation.add('pressed', [1], false);
		buttonMinus.animation.play('normal');
		add(buttonMinus);

		unfocus = function()
		{
			_updateValue();
			_internalOnChange();
		};
		value = defValue;
	}

	override function update(elapsed:Float)
	{
		super.update(elapsed);

		if (!exists || !visible || !active) return;
		if (buttonPlus == null || buttonMinus == null) return;

		var overPlus:Bool = PsychUIEventHandler.overlaps(buttonPlus, camera);
		var overMinus:Bool = PsychUIEventHandler.overlaps(buttonMinus, camera);

		if (FlxG.mouse.justPressed)
		{
			if (overPlus)
			{
				_pressedPlus = true;
				buttonPlus.animation.play('pressed');
				value += step;
				_internalOnChange();
			}
			else if (overMinus)
			{
				_pressedMinus = true;
				buttonMinus.animation.play('pressed');
				value -= step;
				_internalOnChange();
			}
		}
		else if (!FlxG.mouse.pressed)
		{
			if (_pressedPlus)
			{
				_pressedPlus = false;
				_plusT = 0.16;
			}
			if (_pressedMinus)
			{
				_pressedMinus = false;
				_minusT = 0.16;
			}
			if (buttonPlus.animation.curAnim != null && buttonPlus.animation.curAnim.name != 'normal')
				buttonPlus.animation.play('normal');
			if (buttonMinus.animation.curAnim != null && buttonMinus.animation.curAnim.name != 'normal')
				buttonMinus.animation.play('normal');
		}

		// Press pop: shrink while held, spring back afterwards.
		var plusTarget:Float = overPlus ? 0.86 : 1.0;
		var minusTarget:Float = overMinus ? 0.86 : 1.0;
		if (!FlxG.mouse.pressed)
		{
			plusTarget = 1.0;
			minusTarget = 1.0;
		}
		buttonPlus.scale.set(PsychUIHelper.approach(buttonPlus.scale.x, plusTarget, elapsed, 26),
			PsychUIHelper.approach(buttonPlus.scale.y, plusTarget, elapsed, 26));
		buttonMinus.scale.set(PsychUIHelper.approach(buttonMinus.scale.x, minusTarget, elapsed, 26),
			PsychUIHelper.approach(buttonMinus.scale.y, minusTarget, elapsed, 26));
	}

	function set_value(v:Float)
	{
		var clamped:Float = Math.max(min, Math.min(max, v));
		if (min > max) clamped = min;
		value = clamped;
		text = Std.string(isPercent ? (value * 100) : value);
		_updateValue();
		return value;
	}

	function set_min(v:Float)
	{
		min = v;
		@:bypassAccessor if (min > max) max = min;
		_updateFilter();
		_updateValue();
		return min;
	}

	function set_max(v:Float)
	{
		max = v;
		@:bypassAccessor if (max < min) min = max;
		_updateFilter();
		_updateValue();
		return max;
	}

	function set_decimals(v:Int)
	{
		decimals = v;
		_updateFilter();
		return decimals;
	}

	function set_isPercent(v:Bool)
	{
		var changed:Bool = (isPercent != v);
		isPercent = v;
		_updateFilter();

		if (changed)
		{
			text = Std.string(value * 100);
			_updateValue();
		}
		return isPercent;
	}

	function _updateValue()
	{
		var raw:String = (text != null) ? text : '';
		var txt:String = raw.replace('%', '');
		if (txt.indexOf('-') > 0)
			txt = txt.replace('-', '');

		while (txt.indexOf('.') > -1 && txt.indexOf('.') != txt.lastIndexOf('.'))
		{
			var lastId = txt.lastIndexOf('.');
			txt = txt.substr(0, lastId) + txt.substring(lastId + 1);
		}

		var val:Float = Std.parseFloat(txt);
		if (Math.isNaN(val)) val = 0;

		if (isPercent) val /= 100;

		if (val < min) val = min;
		else if (val > max) val = max;
		val = FlxMath.roundDecimal(val, decimals);
		@:bypassAccessor value = val;

		if (isPercent)
		{
			text = Std.string(val * 100);
			text += '%';
		}
		else text = Std.string(val);

		if (caretIndex > text.length) caretIndex = text.length;
		if (selectIndex > text.length) selectIndex = text.length;
	}

	function _updateFilter()
	{
		customFilterPattern = numericFilter(min < 0, decimals > 0, isPercent);
	}

	public static function numericFilter(allowNegative:Bool, allowDot:Bool, percent:Bool):EReg
	{
		var allowed:String = '0-9';
		if (allowDot) allowed += '\\.';
		if (allowNegative) allowed += '\\-';
		if (percent) allowed += '%';
		return new EReg('[^' + allowed + ']*', 'g');
	}

	public var broadcastStepperEvent:Bool = true;
	function _internalOnChange()
	{
		if (onValueChange != null) onValueChange();
		if (broadcastStepperEvent) PsychUIEventHandler.event(CHANGE_EVENT, this);
	}

	override function setGraphicSize(width:Float = 0, height:Float = 0)
	{
		// The base class bakes the field at the requested size; scaling behindText here would
		// shift the white area away from its own frame (and away from the click area).
		super.setGraphicSize(width, height);
	}
}
