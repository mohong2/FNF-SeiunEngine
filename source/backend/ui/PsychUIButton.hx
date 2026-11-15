package backend.ui;

import backend.ui.PsychUIBox.UIStyleData;
import flixel.math.FlxMath;

/**
 * Rounded, clickable button with a smoothly blended hover / press state.
 *
 * The background is always baked at the exact requested size (never scaled), the label is a
 * plain child sprite and the hit test is an explicit rectangle, so a button cannot end up
 * responding somewhere else than where it is drawn.
 *
 * The appearance is re-applied whenever the *resulting* colour changes (not only when the
 * hover/press factors change): editors assign 'normalStyle.bgColor' right after creating a
 * button, and the old factor cache made those colours show up only after the button had been
 * hovered once.
 */
class PsychUIButton extends FlxSpriteGroup
{
	public static final CLICK_EVENT = 'button_click';


	public var name:String;
	public var label(default, set):String;
	public var bg:FlxSprite;
	public var text:FlxText;

	public var onChangeState:String->Void;
	public var onClick:Void->Void;

	public var clickStyle:UIStyleData = {
		bgColor: FlxColor.BLACK,
		textColor: FlxColor.WHITE,
		bgAlpha: 1
	};
	public var hoverStyle:UIStyleData = {
		bgColor: FlxColor.WHITE,
		textColor: FlxColor.BLACK,
		bgAlpha: 1
	};
	public var normalStyle:UIStyleData = {
		bgColor: 0xFFAAAAAA,
		textColor: FlxColor.BLACK,
		bgAlpha: 1
	};

	/** Corner radius of the background. 0 = sharp corners. */
	public var borderRadius(default, set):Int = -1;

	/** If false, hover/press changes snap instantly (no blending, no pop). */
	public var smoothAnimations(default, set):Bool = true;

	public var isClicked:Bool = false;
	public var forceCheckNext:Bool = false;
	public var broadcastButtonEvent:Bool = true;

	// == smoothing ==============================================================
	var _hoverT:Float = 0;
	var _pressT:Float = 0;
	var _hovered:Bool = false;

	/** Last appearance written to the sprites, so idle buttons do not repaint every frame. */
	var _lastBg:FlxColor = 0;
	var _lastTextColor:FlxColor = 0;
	var _lastAlpha:Float = -1;

	/** Small spring-driven scale pop (grow on hover, squash on press, bounce back). */
	var _pop:Float = 1;
	var _popVel:Float = 0;

	/** Size the background was baked for. */
	var _bakedW:Int = 0;
	var _bakedH:Int = 0;

	public function new(x:Float = 0, y:Float = 0, label:String = '', ?onClick:Void->Void = null, ?wid:Int = 80, ?hei:Int = 20, ?font:String, ?size:Int = 9, ?textX:Float = 0, ?textY:Float = 0)
	{
		super(x, y);

		bg = new FlxSprite();
		add(bg);

		text = new FlxText(textX, textY, 1, '');
		text.size = size;
		if (font == null) text.font = 'assets/fonts/editors.ttf';
		else text.font = Paths.font(font);
		text.alignment = CENTER;
		text.borderSize = 2;
		text.antialiasing = false;
		text.textField.sharpness = 400;
		add(text);

		this.onClick = onClick;
		resize(wid, hei);

		this.label = label;
		if (label != null && label.length > 0 && Language.has(label))
			text.text = Language.get(label);

		applyVisualStyle();
		forceCheckNext = true;
	}

	override function update(elapsed:Float)
	{
		super.update(elapsed);

		if (!exists || !visible || !active || bg == null || !bg.exists) return;

		if (isClicked && !FlxG.mouse.pressed)
		{
			isClicked = false;
			forceCheckNext = true;
		}

		var overlapped:Bool = _over();

		var hoverTarget:Float = overlapped ? 1 : 0;
		var pressTarget:Float = (isClicked && overlapped) ? 1 : 0;
		if (!smoothAnimations)
		{
			_hoverT = hoverTarget;
			_pressT = pressTarget;
		}
		else
		{
			_hoverT = PsychUIHelper.approach(_hoverT, hoverTarget, elapsed, 22);
			_pressT = PsychUIHelper.approach(_pressT, pressTarget, elapsed, 30);
		}
		applyVisualStyle();
		_tickPop(elapsed);

		if (!(forceCheckNext || FlxG.mouse.justMoved || FlxG.mouse.justPressed || FlxG.mouse.justReleased)) return;
		forceCheckNext = false;

		if (overlapped != _hovered)
		{
			_hovered = overlapped;
			if (onChangeState != null) onChangeState(overlapped ? 'hover' : 'normal');
		}

		if (overlapped && FlxG.mouse.justPressed)
		{
			isClicked = true;
			_pressT = 1;
			_popVel -= 2.2;
			applyVisualStyle();

			if (onClick != null) onClick();
			if (broadcastButtonEvent) PsychUIEventHandler.event(CLICK_EVENT, this);
		}
	}

	function _over():Bool
	{
		if (_bakedW <= 0 || _bakedH <= 0) return false;
		return PsychUIHelper.overlapsRect(this, 0, 0, _bakedW, _bakedH, camera);
	}

	/**
	 * Writes normal -> hover -> click (blended by the two smoothed factors) onto the sprites.
	 *
	 * Applied from scratch and only when the resulting values differ, so a style object that
	 * was changed after construction is picked up on the very next frame.
	 */
	function applyVisualStyle():Void
	{
		if (bg == null || !bg.exists) return;

		var style:UIStyleData = PsychUIHelper.blendStyleData(normalStyle, hoverStyle, _hoverT);
		if (_pressT > 0.001) style = PsychUIHelper.blendStyleData(style, clickStyle, _pressT);

		// A panel that is fading its page in lowers this group's alpha; keep that factor,
		// otherwise the button pops back to full opacity in the middle of the fade.
		var targetAlpha:Float = style.bgAlpha * FlxMath.bound(alpha, 0, 1);
		if (_lastAlpha == targetAlpha && _lastBg == style.bgColor && _lastTextColor == style.textColor) return;

		_lastAlpha = targetAlpha;
		_lastBg = style.bgColor;
		_lastTextColor = style.textColor;

		bg.color = style.bgColor;
		bg.alpha = targetAlpha;
		if (text != null && text.exists) text.color = style.textColor;
	}

	/** Spring pop: grows a little on hover, squashes on press and springs back with a bounce. */
	function _tickPop(elapsed:Float):Void
	{
		if (bg == null || !bg.exists) return;

		var target:Float = 1;
		if (smoothAnimations)
			target = isClicked ? 0.955 : (1 + 0.035 * FlxMath.bound(_hoverT, 0, 1));

		if (!smoothAnimations)
		{
			_pop = target;
			_popVel = 0;
		}
		else
		{
			var dt:Float = Math.min(elapsed, 1 / 40);
			_popVel += (target - _pop) * 900 * dt;
			_popVel *= 1 / (1 + 26 * dt);
			_pop += _popVel * dt;

			if (Math.abs(_pop - target) < 0.0005 && Math.abs(_popVel) < 0.005)
			{
				_pop = target;
				_popVel = 0;
			}
		}
		bg.scale.set(_pop, _pop);
	}

	/** Re-bakes the background for the given size (no scaling, so corners stay exact). */
	public function resize(width:Int, height:Int)
	{
		var w:Int = Std.int(Math.max(1, width));
		var h:Int = Std.int(Math.max(1, height));

		if (w != _bakedW || h != _bakedH)
		{
			_bakedW = w;
			_bakedH = h;
			PsychUIHelper.bakeRounded(bg, w, h, borderRadius);
			bg.x = x;
			bg.y = y;
		}

		if (bg != null && bg.exists) bg.scale.set(_pop, _pop);

		if (text != null && text.exists)
		{
			text.fieldWidth = w;
			text.x = x;
			text.y = y + (h / 2) - (text.height / 2);
		}

		_lastAlpha = -1;
		applyVisualStyle();
	}

	function set_label(v:String)
	{
		if (text != null && text.exists) text.text = (v != null) ? v : '';
		return (label = v);
	}

	function set_smoothAnimations(v:Bool):Bool
	{
		smoothAnimations = v;
		if (!v)
		{
			_hoverT = 0;
			_pressT = 0;
			_pop = 1;
			_popVel = 0;
			if (bg != null && bg.exists) bg.scale.set(1, 1);
			_lastAlpha = -1;
			applyVisualStyle();
		}
		return v;
	}

	function set_borderRadius(v:Int):Int
	{
		borderRadius = v;
		_bakedW = 0;
		_bakedH = 0;
		if (bg != null && bg.exists)
			resize(Std.int(Math.max(1, bg.width)), Std.int(Math.max(1, bg.height)));
		return v;
	}

	override function destroy()
	{
		bg = null;
		text = null;
		super.destroy();
	}
}
