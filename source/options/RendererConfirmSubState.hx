package options;

import backend.MusicBeatSubstate;
import FlxTextMenuItem;
import Language;
import Paths;
import flixel.FlxG;
import flixel.FlxSprite;
import flixel.text.FlxText;
import flixel.text.FlxText.FlxTextAlign;
import flixel.text.FlxText.FlxTextBorderStyle;
import flixel.util.FlxColor;

/**
 * The confirmation the Renderer row has to pass through.
 *
 * Switching the graphics API is the one setting that can leave a player with a window
 * that never comes back, so it never happens on the key press that moves the highlight:
 * the row asks here first, and only a confirmed answer reaches
 * OptionsState.applyRendererChoice(index), the single place that writes the preference.
 *
 * Input follows the engine's other yes/no substates (substates.ResetScoreSubState):
 * Left/Right toggles, ACCEPT takes the highlighted answer, BACK means "cancel", a tap on
 * either answer does what clicking it does, and the Android pad gets L/R + A/B.
 *
 * The highlight starts on SWITCH: reaching this panel already took a deliberate ACCEPT (or
 * a tap on the other card), so the panel's own ACCEPT is the confirmation the row promises.
 * It used to start on CANCEL, and a player who pressed ACCEPT expecting the switch simply
 * cancelled it. BACK cancels, and CANCEL is one Left/Right press away. The first update is
 * still skipped, exactly like OptionPopupSubState, so the key press that opened the panel
 * cannot answer it.
 *
 * 0.2.2 does not build this panel: backend.RendererChoice.IN_GAME_PICKER is false, so
 * the Renderer row that opens it is never added. It stays in the tree for the version
 * that reopens the picker.
**/
class RendererConfirmSubState extends MusicBeatSubstate
{
	/** Dim behind the panel, faded in so the settings page stays readable. */
	static final DIM_ALPHA:Float = 0.72;

	/** Vertical rhythm, all relative to the middle of the screen. */
	static final TITLE_Y:Float = -200;
	static final TARGET_Y:Float = -128;
	static final BODY_Y:Float = -46;
	static final ANSWER_Y:Float = 148;
	static final ANSWER_W:Int = 340;
	static final ANSWER_GAP:Float = 190;

	var onConfirm:Void->Void;
	var onCancel:Void->Void;

	var dimmer:FlxSprite;
	var yesItem:FlxTextMenuItem;
	var noItem:FlxTextMenuItem;

	/** True while the "switch" answer is highlighted; false is "cancel". */
	var confirming:Bool = true;

	/** The update that opens the panel is the parent's key press: skip that one. */
	var firstUpdate:Bool = true;

	var closing:Bool = false;

	public function new(title:String, target:String, message:String, onConfirm:Void->Void, onCancel:Void->Void)
	{
		super();

		this.onConfirm = onConfirm;
		this.onCancel = onCancel;

		dimmer = new FlxSprite().makeGraphic(FlxG.width, FlxG.height, FlxColor.BLACK);
		dimmer.alpha = 0;
		dimmer.scrollFactor.set();
		add(dimmer);

		var titleText = makeText(title, 46, TITLE_Y, FlxColor.WHITE);
		titleText.borderSize = 3;
		add(titleText);

		// The pair being switched between is the point of the panel, so it gets its own
		// line, in the amber the Renderer picker uses for "this is the important part".
		var targetText = makeText(target, 38, TARGET_Y, 0xFFFFC45A);
		targetText.borderSize = 3;
		add(targetText);

		var bodyText = makeText(message, 26, BODY_Y, FlxColor.WHITE);
		bodyText.borderSize = 2.2;
		add(bodyText);

		var centerX:Float = FlxG.width * 0.5;

		yesItem = makeAnswer(centerX - ANSWER_GAP - ANSWER_W * 0.5,
			Language.get('renderer.confirm.yes', 'Switch'), 40);
		add(yesItem);

		noItem = makeAnswer(centerX + ANSWER_GAP - ANSWER_W * 0.5,
			Language.get('renderer.confirm.no', 'Cancel'), 40);
		add(noItem);

		updateHighlight();

		#if (TOUCH_CONTROLS || desktop)
		addVirtualPad(LEFT_RIGHT, A_B);
		addPadCamera();
		#end
	}

	/** One centred line of body copy in the language font (so CJK renders correctly). */
	function makeText(text:String, size:Int, offsetY:Float, color:Int):FlxText
	{
		// Width and x both come from the constructor: FlxText only learns its real size
		// when it rasterizes, so centring it by hand before that lands on a stale width.
		var margin:Float = FlxG.width * 0.07;
		var field = new FlxText(margin, FlxG.height * 0.5 + offsetY, FlxG.width - margin * 2, text, size);
		field.setFormat(Paths.languageFont(), size, color, FlxTextAlign.CENTER, FlxTextBorderStyle.OUTLINE_FAST,
			FlxColor.BLACK);
		field.wordWrap = true;
		field.scrollFactor.set();
		return field;
	}

	/** One answer button, as a language-font item so the highlight can scale it. */
	function makeAnswer(x:Float, label:String, size:Int):FlxTextMenuItem
	{
		var item = new FlxTextMenuItem(x, FlxG.height * 0.5 + ANSWER_Y, '[' + label + ']', size);
		item.isMenuItem = false;
		item.fieldWidth = ANSWER_W;
		item.alignment = FlxTextAlign.CENTER;
		item.scrollFactor.set();
		return item;
	}

	function updateHighlight():Void
	{
		var scales:Array<Float> = [0.82, 1.0];
		var alphas:Array<Float> = [0.45, 1.0];
		var picked:Int = confirming ? 1 : 0;

		yesItem.alpha = alphas[picked];
		yesItem.scale.set(scales[picked], scales[picked]);
		noItem.alpha = alphas[1 - picked];
		noItem.scale.set(scales[1 - picked], scales[1 - picked]);
	}

	/** Runs the answer once, then drops the panel. */
	function finish(accepted:Bool):Void
	{
		if (closing) return;
		closing = true;

		FlxG.sound.play(Paths.sound(accepted ? 'confirmMenu' : 'cancelMenu'), 1);

		// The answer runs before close(): closing the substate calls the parent's
		// closeSubState() synchronously, and that is where the settings page redraws
		// itself. Touching the picker afterwards would be touching torn-down sprites.
		var callback:Void->Void = accepted ? onConfirm : onCancel;
		if (callback != null) callback();

		close();
	}

	/** Mouse/touch answer selection; identical to pressing Left/Right onto it. */
	public function setHover(accept:Bool):Void
	{
		if (confirming == accept) return;
		confirming = accept;
		FlxG.sound.play(Paths.sound('scrollMenu'), 1);
		updateHighlight();
	}

	override function update(elapsed:Float):Void
	{
		super.update(elapsed);

		if (dimmer != null && dimmer.alpha < DIM_ALPHA)
			dimmer.alpha = Math.min(DIM_ALPHA, dimmer.alpha + elapsed * 4);

		if (closing) return;

		// Opened on the same frame as the parent's Enter/click: that press must not answer
		// the question it just asked.
		if (firstUpdate)
		{
			firstUpdate = false;
			return;
		}

		if (controls.UI_LEFT_P || controls.UI_RIGHT_P)
		{
			setHover(!confirming);
			return;
		}

		if (controls.BACK)
		{
			finish(false);
			return;
		}

		if (controls.ACCEPT)
		{
			finish(confirming);
			return;
		}

		if (FlxG.mouse.justPressed && !(virtualPad != null && virtualPad.isMouseOverAnyButton()))
		{
			// Only the answer the pointer already sits on can be taken: a click landing on
			// the other one highlights it instead, so a tap cannot pick "switch" by accident
			// when the panel opens under the finger.
			if (FlxG.mouse.overlaps(yesItem))
			{
				if (confirming) finish(true);
				else setHover(true);
			}
			else if (FlxG.mouse.overlaps(noItem))
			{
				if (!confirming) finish(false);
				else setHover(false);
			}
		}
	}
}
