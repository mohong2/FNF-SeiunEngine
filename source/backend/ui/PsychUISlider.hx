package backend.ui;

/**
 * Horizontal slider with a draggable handle, min/max/value labels and an optional caption.
 *
 * The knob position is smoothed towards the value, so a jump (a chart loaded, a value reset)
 * glides instead of teleporting, while dragging stays 1:1 with the pointer.
 */
class PsychUISlider extends FlxSpriteGroup
{
	public static final CHANGE_EVENT = "slider_change";

	public var bar:FlxSprite;
	public var minText:FlxText;
	public var maxText:FlxText;
	public var valueText:FlxText;
	public var handle:FlxSprite;
	public var label(get, set):String;
	public var labelText:FlxText;

	public var value(default, set):Float = 0;
	public var onChange:Float->Void;
	public var min(default, set):Float = -999;
	public var max(default, set):Float = 999;
	public var decimals(default, set):Int = 2;

	/** Corner radius for slider bar and handle. */
	public var borderRadius:Int = 4;

	public var movingHandle:Bool = false;
	public var forceNextUpdate:Bool = false;
	public var broadcastSliderEvent:Bool = true;

	/** Smoothed handle position (glides towards the value when it changes from code). */
	var _handleX:Float = 0;
	var _hoverT:Float = 0;

	// Base colours so the hover flash does not drift over time.
	var _barColor:FlxColor = FlxColor.WHITE;
	var _handleColor:FlxColor = 0xFFAAAAAA;

	public function new(x:Float = 0, y:Float = 0, callback:Float->Void, def:Float = 0, min:Float = -999, max:Float = 999, wid:Float = 200, mainColor:FlxColor = FlxColor.WHITE, handleColor:FlxColor = 0xFFAAAAAA)
	{
		super(x, y);
		this.onChange = callback;
		_barColor = mainColor;
		_handleColor = handleColor;

		bar = PsychUIHelper.createRoundedRectSprite(Std.int(Math.max(8, wid)), 5, borderRadius);
		bar.color = mainColor;
		add(bar);

		minText = new FlxText(0, 0, 80, '', 8);
		minText.alignment = CENTER;
		minText.color = mainColor;
		add(minText);
		maxText = new FlxText(0, 0, 80, '', 8);
		maxText.alignment = CENTER;
		maxText.color = mainColor;
		add(maxText);
		valueText = new FlxText(0, 0, 80, '', 8);
		valueText.alignment = CENTER;
		valueText.color = handleColor;
		add(valueText);
		labelText = new FlxText(0, 0, wid, '', 8);
		labelText.alignment = CENTER;
		add(labelText);

		handle = PsychUIHelper.createRoundedRectSprite(5, 15, borderRadius);
		handle.color = handleColor;
		add(handle);

		this.min = min;
		this.max = max;
		this.value = def;
		_updatePositions();
		_handleX = handle.x;
		forceNextUpdate = true;
	}

	override function update(elapsed:Float)
	{
		super.update(elapsed);

		if (!exists || !visible || !active) return;
		if (bar == null || !bar.exists || handle == null || !handle.exists) return;

		if (FlxG.mouse.justMoved || FlxG.mouse.justPressed || FlxG.mouse.justReleased || forceNextUpdate)
		{
			forceNextUpdate = false;
			if (FlxG.mouse.justPressed && !movingHandle
				&& (PsychUIEventHandler.overlaps(bar, camera) || PsychUIEventHandler.overlaps(handle, camera)))
				movingHandle = true;

			if (movingHandle && FlxG.mouse.pressed)
			{
				var mouseX:Float = FlxG.mouse.getPositionInCameraView(camera).x;
				var lastValue:Float = FlxMath.roundDecimal(value, decimals);
				value = Math.max(min, Math.min(max, FlxMath.remapToRange(mouseX, bar.x, bar.x + bar.width, min, max)));
				_handleX = handle.x; // dragging is 1:1, never smoothed
				if (this.onChange != null && lastValue != value)
				{
					this.onChange(FlxMath.roundDecimal(value, decimals));
					if (broadcastSliderEvent) PsychUIEventHandler.event(CHANGE_EVENT, this);
				}
			}
		}

		if (!FlxG.mouse.pressed) movingHandle = false;

		// Glide the knob to its target (programmatic changes).
		if (!movingHandle) _handleX = PsychUIHelper.approach(_handleX, _targetHandleX(), elapsed, 20);
		handle.x = _handleX;

		// Soft highlight while the pointer is over the bar.
		var over:Bool = movingHandle || PsychUIEventHandler.overlaps(bar, camera) || PsychUIEventHandler.overlaps(handle, camera);
		_hoverT = PsychUIHelper.approach(_hoverT, over ? 1 : 0, elapsed, 16);
		if (bar.exists)
		{
			var c:FlxColor = PsychUIHelper.lerpColor(_barColor, 0xFFFFFFFF, _hoverT * 0.35);
			bar.color = c;
			if (minText != null && minText.exists) minText.color = c;
			if (maxText != null && maxText.exists) maxText.color = c;
		}
	}

	function _targetHandleX():Float
	{
		if (bar == null) return handle.x;
		return bar.x - handle.width/2 + FlxMath.remapToRange(FlxMath.roundDecimal(value, decimals), min, max, 0, bar.width);
	}

	function _updatePositions()
	{
		if (bar == null || handle == null) return;

		minText.x = bar.x - minText.width/2;
		maxText.x = bar.x + bar.width - maxText.width/2;
		valueText.x = bar.x + bar.width/2 - valueText.width/2;

		labelText.x = bar.x + bar.width/2 - labelText.width/2;
		if (labelText.text != null && labelText.text.length > 0) bar.y = labelText.y + 24;

		minText.y = maxText.y = valueText.y = bar.y + 12;

		handle.x = _targetHandleX();
		handle.y = bar.y + bar.height/2 - handle.height/2;
	}

	function set_decimals(v:Int)
	{
		decimals = v;
		if (minText != null && minText.exists)
		{
			minText.text = Std.string(FlxMath.roundDecimal(min, decimals));
			maxText.text = Std.string(FlxMath.roundDecimal(max, decimals));
			valueText.text = Std.string(FlxMath.roundDecimal(value, decimals));
		}
		if (this.onChange != null) this.onChange(FlxMath.roundDecimal(value, decimals));
		_updatePositions();
		return decimals;
	}

	function set_min(v:Float)
	{
		if (v > max) max = v;
		min = v;
		if (minText != null && minText.exists) minText.text = Std.string(FlxMath.roundDecimal(min, decimals));
		if (handle != null && bar != null) _updatePositions();
		return min;
	}

	function set_max(v:Float)
	{
		if (v < min) min = v;
		max = v;
		if (maxText != null && maxText.exists) maxText.text = Std.string(FlxMath.roundDecimal(max, decimals));
		if (handle != null && bar != null) _updatePositions();
		return max;
	}

	function set_value(v:Float)
	{
		var clamped:Float = Math.max(min, Math.min(max, v));
		if (min > max) clamped = min;
		value = clamped;
		if (valueText != null && valueText.exists) valueText.text = Std.string(FlxMath.roundDecimal(value, decimals));
		if (handle != null && bar != null && !movingHandle)
			handle.x = _targetHandleX();
		return value;
	}

	function set_label(v:String)
	{
		labelText.text = (v != null) ? v : '';
		_updatePositions();
		return labelText.text;
	}

	function get_label()
	{
		return (labelText != null) ? labelText.text : null;
	}

	override function destroy()
	{
		bar = null;
		handle = null;
		super.destroy();
	}
}
