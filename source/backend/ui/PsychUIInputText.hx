package backend.ui;

import flixel.FlxG;
import flixel.FlxCamera;
import flixel.FlxObject;
import flixel.input.keyboard.FlxKey;
#if FLX_TOUCH
import flixel.input.touch.FlxTouch;
#end
import flixel.util.FlxDestroyUtil;
import flash.events.KeyboardEvent;
import lime.math.Rectangle;
import lime.system.Clipboard;
import openfl.events.Event;

enum abstract AccentCode(Int) from Int from UInt to Int to UInt
{
	var NONE = -1;
	var GRAVE = 0;
	var ACUTE = 1;
	var CIRCUMFLEX = 2;
	var TILDE = 3;
}

enum abstract FilterMode(Int) from Int from UInt to Int to UInt
{
	var NO_FILTER:Int = 0;
	var ONLY_ALPHA:Int = 1;
	var ONLY_NUMERIC:Int = 2;
	var ONLY_ALPHANUMERIC:Int = 3;
	var ONLY_HEXADECIMAL:Int = 4;
	var CUSTOM_FILTER:Int = 5;
}

enum abstract CaseMode(Int) from Int from UInt to Int to UInt
{
	var ALL_CASES:Int = 0;
	var UPPER_CASE:Int = 1;
	var LOWER_CASE:Int = 2;
}

class PsychUIInputText extends FlxSpriteGroup
{
	public static final CHANGE_EVENT = "inputtext_change";

	static final KEY_TILDE = 126;
	static final KEY_ACUTE = 180;

	public static var focusOn(default, set):PsychUIInputText = null;

	/** Releases keyboard / IME focus from whatever field currently owns it. */
	public static function clearFocus():Void
	{
		if (focusOn != null) focusOn = null;
	}

	public var name:String;
	public var bg:FlxSprite;
	public var behindText:FlxSprite;
	public var selection:FlxSprite;
	public var textObj:FlxText;
	public var caret:FlxSprite;
	public var onChange:String->String->Void;

	public var fieldWidth(default, set):Int = 0;
	public var maxLength(default, set):Int = 0;
	public var passwordMask(default, set):Bool = false;
	public var text(default, set):String = null;
	
	public var forceCase(default, set):CaseMode = ALL_CASES;
	public var filterMode(default, set):FilterMode = NO_FILTER;
	public var customFilterPattern(default, set):EReg;

	public var selectedFormat:FlxTextFormat = new FlxTextFormat(FlxColor.WHITE);

	/** Corner radius for the input background. */
	public var borderRadius:Int = 6;

	
	public var textOffsetX:Float = 1;
	public var textOffsetY:Float = 1;

	public function new(x:Float = 0, y:Float = 0, wid:Int = 100, ?text:String = '', size:Int = 8, ?font:String)
	{
		super(x, y);
		_fontSize = size;
		_fieldH = Std.int(Math.max(size + 4, 16));
		var totalW:Int = wid + 2;
		var totalH:Int = _fieldH;

		// Outer frame (black, rounded). Every sprite here owns its own bitmap - nothing is
		// shared with another widget, so destroying a field can never black out another one.
		this.bg = new FlxSprite();
		add(this.bg);
		this.bg.color = FlxColor.BLACK;

		// Inner white area.
		this.behindText = new FlxSprite();
		add(this.behindText);

		this.selection = new FlxSprite().makeGraphic(1, 1, FlxColor.WHITE, true);
		this.textObj = new FlxText(1, 1, Math.max(1, wid - 2), '', size);
		if(font == null) textObj.font = 'assets/fonts/editors.ttf';
		else textObj.font = Paths.font(font);
		this.caret = new FlxSprite().makeGraphic(1, 1, FlxColor.WHITE, true);
		add(this.selection);
		add(this.textObj);
		add(this.caret);

		this.textObj.color = FlxColor.BLACK;
		this.textObj.textField.selectable = false;
		this.textObj.textField.wordWrap = false;
		this.textObj.textField.multiline = false;
		this.selection.color = FlxColor.BLUE;

		@:bypassAccessor fieldWidth = wid;
		applyGeometry(totalW, totalH);
		this.text = text;

		if (FlxG.stage != null) FlxG.stage.addEventListener(KeyboardEvent.KEY_DOWN, onKeyDown);

		_skipTextInput = false;
	}
	
	public var selectIndex:Int = -1;
	public var caretIndex(default, set):Int = -1;
	var _caretTime:Float = 0;

	var _nextAccent:AccentCode = NONE;
	public var inInsertMode:Bool = false;
	function onKeyDown(e:KeyboardEvent)
	{
		if(focusOn != this) return;

		var keyCode:Int = e.keyCode;
		var charCode:Int = e.charCode;
		var flxKey:FlxKey = cast keyCode;

		// Fix missing cedilla
		switch(keyCode)
		{
			case 231: //ç and Ç
				charCode = e.shiftKey ? 0xC7 : 0xE7;
		}

		// Control key actions
		if(e.controlKey)
		{
			switch(flxKey)
			{
				case A: //select all text
					selectIndex = Std.int(Math.min(0, text.length - 1));
					caretIndex = text.length;

				case X, C: //cut/copy selected text to clipboard
					if(caretIndex >= 0 && selectIndex != 0 && caretIndex != selectIndex)
					{
						Clipboard.text = text.substring(caretIndex, selectIndex);
						if(flxKey == X)
							deleteSelection();
					}

				case V: //paste from clipboard
					if(Clipboard.text == null) return;

					if(selectIndex > -1 && selectIndex != caretIndex)
						deleteSelection();

					var lastText = text;
					text = text.substring(0, caretIndex) + Clipboard.text + text.substring(caretIndex);
					caretIndex += Clipboard.text.length;
					if(onChange != null) onChange(lastText, text);
					if(broadcastInputTextEvent) PsychUIEventHandler.event(CHANGE_EVENT, this);
					_skipTextInput = true;

				case BACKSPACE:
					if(selectIndex < 0 || selectIndex == caretIndex)
					{
						var lastText = text;
						var deletedText:String = text.substr(0, Std.int(Math.max(0, caretIndex-1)));
						var space:Int = deletedText.lastIndexOf(' ');
						if(space > -1 && space != caretIndex-1)
						{
							var start:String = deletedText.substring(0, space+1);
							var end:String = text.substring(caretIndex);
							caretIndex -= Std.int(Math.max(0, text.length - (start.length + end.length)));
							text = start + end;
						}
						else
						{
							text = text.substring(caretIndex);
							caretIndex = 0;
						}
						selectIndex = -1;
						if(onChange != null) onChange(lastText, text);
						if(broadcastInputTextEvent) PsychUIEventHandler.event(CHANGE_EVENT, this);
					}
					else deleteSelection();

				case DELETE:
					if(selectIndex < 0 || selectIndex == caretIndex)
					{
						// This is| a test
						// This is test
						var deletedText:String = text.substring(caretIndex);
						var spc:Int = 0;
						var space:Int = deletedText.indexOf(' ');
						while(deletedText.substr(spc, 1) == ' ')
						{
							spc++;
							space = deletedText.substr(spc).indexOf(' ');
						}

						var lastText = text;
						if(space > -1)
						{
							text = text.substr(0, caretIndex) + text.substring(caretIndex + space + spc);
						}
						else text = text.substr(0, caretIndex);
						if(onChange != null) onChange(lastText, text);
						if(broadcastInputTextEvent) PsychUIEventHandler.event(CHANGE_EVENT, this);
					}
					else deleteSelection();

				case LEFT:
					if(caretIndex > 0)
					{
						do
						{
							caretIndex--;
							var a:String = text.substr(caretIndex-1, 1);
							var b:String = text.substr(caretIndex, 1);
							//trace(a, b);
							if(a == ' ' && b != ' ') break;
						}
						while(caretIndex > 0);
					}

				case RIGHT:
					if(caretIndex < text.length)
					{
						do
						{
							caretIndex++;
							var a:String = text.substr(caretIndex-1, 1);
							var b:String = text.substr(caretIndex, 1);
							//trace(a, b);
							if(a != ' ' && b == ' ') break;
						}
						while(caretIndex < text.length);
					}

				default:
			}
			updateCaret();
			return;
		}

		final ignored:Array<FlxKey> = [SHIFT, CONTROL, ESCAPE];
		if(ignored.contains(flxKey)) return;

		// When the hidden TextField is active, ALL character input is handled by it.
		// Only allow Enter (confirm) and Escape (cancel) to be processed here.
		if(_textInputActive)
		{
			switch(flxKey)
			{
				case ENTER:
					onPressEnter(e);
					updateCaret();
				case ESCAPE:
					focusOn = null;
				default:
			}
			return;
		}

		var lastAccent = _nextAccent;
		switch(keyCode)
		{
			case KEY_TILDE:
				_nextAccent = !e.shiftKey ? TILDE : CIRCUMFLEX;
				if(lastAccent == NONE) return;
			case KEY_ACUTE:
				_nextAccent = !e.shiftKey ? ACUTE : GRAVE;
				if(lastAccent == NONE) return;
			default:
				lastAccent = NONE;
		}

		//trace(keyCode, charCode, flxKey);
		switch(flxKey)
		{
			case LEFT: //move caret to left
				if(!FlxG.keys.pressed.SHIFT) selectIndex = -1;
				else if(selectIndex == -1) selectIndex = caretIndex;
				caretIndex = Std.int(Math.max(0, caretIndex - 1));

			case RIGHT: //move caret to right
				if(!FlxG.keys.pressed.SHIFT) selectIndex = -1;
				else if(selectIndex == -1) selectIndex = caretIndex;
				caretIndex = Std.int(Math.min(text.length, caretIndex + 1));

			case HOME: //move caret to the begin
				if(!FlxG.keys.pressed.SHIFT) selectIndex = -1;
				else if(selectIndex == -1) selectIndex = caretIndex;
				caretIndex = 0;

			case END: //move caret to the end
				if(!FlxG.keys.pressed.SHIFT) selectIndex = -1;
				else if(selectIndex == -1) selectIndex = caretIndex;
				caretIndex = text.length;

			case INSERT: //change to insert mode
				inInsertMode = !inInsertMode;

			case BACKSPACE: //Delete letter to the left of caret
				if(caretIndex <= 0) return;

				if(selectIndex > -1 && selectIndex != caretIndex)
					deleteSelection();
				else
				{
					var lastText = text;
					text = text.substring(0, caretIndex-1) + text.substring(caretIndex);
					caretIndex--;
					if(onChange != null) onChange(lastText, text);
					if(broadcastInputTextEvent) PsychUIEventHandler.event(CHANGE_EVENT, this);
				}
				_nextAccent = NONE;

			case DELETE: //Delete letter to the right of caret
				if(selectIndex > -1 && selectIndex != caretIndex)
				{
					deleteSelection();
					updateCaret();
					return;
				}

				if(caretIndex >= text.length) return;

				var lastText = text;
				if(caretIndex < 1)
					text = text.substr(1);
				else
					text = text.substring(0, caretIndex) + text.substring(caretIndex+1);

				if(caretIndex >= text.length) caretIndex = text.length;
				
				if(onChange != null) onChange(lastText, text);
				if(broadcastInputTextEvent) PsychUIEventHandler.event(CHANGE_EVENT, this);
			
			case SPACE: //space or last accent pressed
				if(_nextAccent != NONE) _typeLetter(getAccentCharCode(_nextAccent));
				else _typeLetter(charCode);
				_nextAccent = NONE;

			case A, O: //these support all accents
				var grave:Int = 0x0;
				var capital:Int = 0x0;
				switch(flxKey)
				{
					case A:
						grave = 0xC0;
						capital = 0x41;
					case O:
						grave = 0xD2;
						capital = 0x4f;
					default:
				}
				if(_nextAccent != NONE)
					charCode += grave - capital + _nextAccent;

				_typeLetter(charCode);
				_nextAccent = NONE;

			case E, I, U: //these support grave, acute and circumflex
				var grave:Int = 0x0;
				var capital:Int = 0x0;
				switch(flxKey)
				{
					case E:
						grave = 0xC8;
						capital = 0x45;
					case I:
						grave = 0xCC;
						capital = 0x49;
					case U:
						grave = 0xD9;
						capital = 0x55;
					default:
				}
				if(_nextAccent == GRAVE || _nextAccent == ACUTE || _nextAccent == CIRCUMFLEX) //Supported accents
					charCode += grave - capital + _nextAccent;
				else if(_nextAccent == TILDE) //Unsupported accent
					_typeLetter(getAccentCharCode(_nextAccent));

				_typeLetter(charCode);
				_nextAccent = NONE;

			case N: //it only supports tilde
				if(_nextAccent == TILDE)
					charCode += 0xD1 - 0x4E;
				else
					_typeLetter(getAccentCharCode(_nextAccent));

				_typeLetter(charCode);
				_nextAccent = NONE;

			case ESCAPE:
				focusOn = null;

			case ENTER:
				onPressEnter(e);

			default:
				if(charCode < 1)
					if((charCode = getAccentCharCode(_nextAccent)) < 1)
						return;

				if(lastAccent != NONE) _typeLetter(getAccentCharCode(lastAccent));
				else if(_nextAccent != NONE) _typeLetter(getAccentCharCode(_nextAccent));
				_typeLetter(charCode);
				_nextAccent = NONE;
		}
		updateCaret();
	}

	public dynamic function onPressEnter(e:KeyboardEvent)
		focusOn = null;

	public var unfocus:Void->Void;
	public static function set_focusOn(v:PsychUIInputText)
	{
		// A destroyed / half-built input must never become the focus target.
		if (v != null && (!v.exists || v.textObj == null)) v = null;
		if(focusOn != null && focusOn != v && focusOn.exists)
		{
			if(focusOn.unfocus != null) focusOn.unfocus();
			focusOn.resetCaret();
		}
		focusOn = v;
		updateIME();
		return v;
	}

	static function updateIME()
	{
		// The focused input may have been removed/destroyed while it was focused.
		if (focusOn != null && (!focusOn.exists || focusOn.behindText == null || !focusOn.behindText.exists))
			focusOn = null;

		if (FlxG.stage == null)
		{
			_textInputActive = false;
			return;
		}

		if(focusOn != null)
		{
			if(!_hiddenTFReady)
				createHiddenTextField();

			_textInputActive = true;

			// Position the hidden TextField at the input field's screen location
			// (used by IME for candidate window positioning and by Android for keyboard)
			var screenPos = focusOn.behindText.getScreenPosition();
			_hiddenTF.x = screenPos.x;
			_hiddenTF.y = screenPos.y;
			_hiddenTF.width = focusOn.behindText.width;
			_hiddenTF.height = focusOn.behindText.height;
			setHiddenText(focusOn.text);

			// Add to stage and set focus to trigger native IME/keyboard
			if(_hiddenTF.stage == null)
				FlxG.stage.addChild(_hiddenTF);
			if(FlxG.stage.focus != _hiddenTF)
				FlxG.stage.focus = _hiddenTF;

			// Directly enable text input on the window as a fallback for mobile platforms
			// This ensures the native soft keyboard appears on Android
			#if mobile
			if(FlxG.stage.window != null && !FlxG.stage.window.textInputEnabled)
			{
				var bounds = focusOn.behindText.getScreenPosition();
				var limeRect = new Rectangle(bounds.x, bounds.y, focusOn.behindText.width, focusOn.behindText.height);
				FlxG.stage.window.setTextInputRect(limeRect);
				FlxG.stage.window.textInputEnabled = true;
			}
			#end
		}
		else
		{
			_textInputActive = false;

			// Directly disable text input on mobile when losing focus
			#if mobile
			if(FlxG.stage.window != null)
				FlxG.stage.window.textInputEnabled = false;
			#end

			if(_hiddenTFReady)
			{
				if(_hiddenTF.stage != null)
				{
					if(FlxG.stage.focus == _hiddenTF)
						FlxG.stage.focus = null;
					FlxG.stage.removeChild(_hiddenTF);
				}
			}
		}
	}

	static function createHiddenTextField()
	{
		if(_hiddenTFReady) return;

		_hiddenTF = new openfl.text.TextField();
		_hiddenTF.type = INPUT;
		_hiddenTF.selectable = true;
		_hiddenTF.background = false;
		_hiddenTF.border = false;
		_hiddenTF.alpha = 0.01;
		_hiddenTF.width = 1;
		_hiddenTF.height = 1;

		// Prime the TextField with a valid format range to prevent TextEngine warnings.
		// Use replaceText instead of direct assignment to keep format ranges intact.
		var fmt = new openfl.text.TextFormat("_sans", 12, 0);
		_hiddenTF.defaultTextFormat = fmt;
		_hiddenTF.text = " ";
		_hiddenTF.setTextFormat(fmt);
		_hiddenTF.replaceText(0, 1, "");

		_hiddenTF.addEventListener(Event.CHANGE, onHiddenTextChange);
		_hiddenTF.addEventListener(openfl.events.FocusEvent.FOCUS_OUT, onHiddenFocusOut);

		_hiddenTFReady = true;
	}

	static function setHiddenText(value:String)
	{
		if(_hiddenTF == null) return;
		if(value == null) value = '';
		// Use replaceText to preserve format ranges (unlike direct text= assignment)
		var oldLen = _hiddenTF.text.length;
		if(oldLen == 0)
			_hiddenTF.replaceText(0, 0, value);
		else
			_hiddenTF.replaceText(0, oldLen, value);
	}

	static function destroyHiddenTextField()
	{
		if(!_hiddenTFReady) return;

		if(_hiddenTF.stage != null)
		{
			if(FlxG.stage.focus == _hiddenTF)
				FlxG.stage.focus = null;
			FlxG.stage.removeChild(_hiddenTF);
		}
		_hiddenTF.removeEventListener(Event.CHANGE, onHiddenTextChange);
		_hiddenTF.removeEventListener(openfl.events.FocusEvent.FOCUS_OUT, onHiddenFocusOut);
		_hiddenTF = null;
		_hiddenTFReady = false;
	}

	static function onHiddenTextChange(e:Event)
	{
		var input = focusOn;
		if(input == null || !input.exists) return;
		if(_hiddenTF == null) return;

		var newText = _hiddenTF.text;

		// Filter & apply maxLength
		newText = input.filter(newText);
		if(input.maxLength > 0 && newText.length > input.maxLength)
			newText = newText.substr(0, input.maxLength);

		if(newText == input.text) return;

		var lastText = input.text;
		input.text = newText;
		input.caretIndex = _hiddenTF.selectionBeginIndex;
		if(input.caretIndex < 0 || input.caretIndex > input.text.length)
			input.caretIndex = input.text.length;
		if(input.onChange != null) input.onChange(lastText, input.text);
		if(input.broadcastInputTextEvent) PsychUIEventHandler.event(CHANGE_EVENT, input);
		input.updateCaret();
	}

	static function onHiddenFocusOut(e:openfl.events.FocusEvent)
	{
		// If the hidden TextField loses focus (e.g., user clicked elsewhere),
		// sync our input and release focus
		if(focusOn != null && focusOn.exists)
			focusOn = null;
	}

	override function update(elapsed:Float)
	{
		super.update(elapsed);

		// Handle mouse click to gain focus
		if(FlxG.mouse.justPressed)
		{
			if(PsychUIEventHandler.overlaps(behindText, camera))
				setFocusOnThis(FlxG.mouse.getScreenPosition(camera).x);
			else if(focusOn == this)
				focusOn = null;
		}

		// Handle touch input for mobile (Android/iOS) - trigger native soft keyboard
		#if FLX_TOUCH
		for (touch in FlxG.touches.list)
		{
			if(touch.justPressed)
			{
				if(overlapsTouch(touch, camera))
					setFocusOnThis(touch.getScreenPosition(camera).x);
				else if(focusOn == this)
					focusOn = null;
			}
		}
		#end

		if(focusOn == this)
		{
			_caretTime = (_caretTime + elapsed) % 1;
			if(textObj != null && textObj.exists)
			{
				var drewSelection:Bool = false;
				if(selection != null && selection.exists)
				{
					if(selectIndex != -1 && selectIndex != caretIndex)
					{
						selection.visible = true;
						drewSelection = true;
					}
					else selection.visible = false;
				}
	
				if(caret != null && caret.exists)
				{
					if(!drewSelection && _caretTime < 0.5 && caret.x >= textObj.x)
					{
						caret.visible = true;
						caret.color = textObj.color;
					}
					else caret.visible = false;
				}
			}
		}
		else
		{
			_caretTime = 0;
			inInsertMode = false;
			if(selection != null && selection.exists) selection.visible = false;
			if(caret != null && caret.exists) caret.visible = false;
		}
	}

	function setFocusOnThis(screenX:Float)
	{
		if(!FlxG.keys.pressed.SHIFT) selectIndex = -1;
		else if(selectIndex == -1) selectIndex = caretIndex;
		focusOn = this;
		caretIndex = 0;
		var lastBound:Float = 0;
		var textObjX:Float = textObj.getScreenPosition(camera).x;
		var txtX:Float = textObjX - textObj.textField.scrollH;

		for (i => bound in _boundaries)
		{
			if(screenX >= txtX + (bound - lastBound)/2)
			{
				caretIndex = i+1;
				txtX += bound - lastBound;
				lastBound = bound;
			}
			else break;
		}
		updateCaret();
	}

	#if FLX_TOUCH
	function overlapsTouch(touch:FlxTouch, camera:FlxCamera):Bool
	{
		if(behindText == null) return false;
		final cam = (camera != null) ? camera : FlxG.camera;
		final screenPos = behindText.getScreenPosition(null, cam);
		final touchPos = touch.getScreenPosition(cam);
		return touchPos.x >= screenPos.x
			&& touchPos.x <= screenPos.x + behindText.width
			&& touchPos.y >= screenPos.y
			&& touchPos.y <= screenPos.y + behindText.height;
	}
	#end

	public function resetCaret()
	{
		selectIndex = -1;
		caretIndex = 0;
		updateCaret();
	}
	public function alignText():Void
	{
		if (textObj != null && textObj.exists)
		{
			textObj.x = x + textOffsetX;
			textObj.y = y + textOffsetY;
			updateCaret();
		}
	}

	override function set_x(Value:Float):Float
	{
		var result:Float = super.set_x(Value);
		if (textObj != null && textObj.exists)
		{
			textObj.x = x + textOffsetX;
			textObj.y = y + textOffsetY;
		}
		return result;
	}

	override function set_y(Value:Float):Float
	{
		var result:Float = super.set_y(Value);
		if (textObj != null && textObj.exists)
		{
			textObj.x = x + textOffsetX;
			textObj.y = y + textOffsetY;
		}
		return result;
	}

	public function updateCaret()
	{
		if(textObj == null || !textObj.exists) return;

		var textField = textObj.textField;
		textField.setSelection(caretIndex, caretIndex);
		_caretTime = 0;
		if(caret != null && caret.exists)
		{
			caret.y = textObj.y + 2;
			caret.x = textObj.x + 1 - textObj.textField.scrollH;
			if(caretIndex > 0)
				caret.x += _boundaries[Std.int(Math.max(0, Math.min(_boundaries.length-1, caretIndex-1)))];
		}
		
		if(selection != null && selection.exists)
		{
			selection.y = textObj.y + 2;
			selection.x = textObj.x + 1 - textObj.textField.scrollH;
			if(selectIndex > 0)
				selection.x += _boundaries[Std.int(Math.max(0, Math.min(_boundaries.length-1, selectIndex-1)))];

			selection.scale.y = textField.textHeight;
			selection.scale.x = caret.x - selection.x;
			if(selection.scale.x < 0)
			{
				selection.scale.x = Math.abs(selection.scale.x);
				selection.x -= selection.scale.x;
			}

			if(selection.x < textObj.x)
			{
				var diff:Float = textObj.x - selection.x;
				selection.x += diff;
				selection.scale.x -= diff;
			}
			if(selection.x + selection.scale.x > textObj.x + textObj.width)
				selection.scale.x += (textObj.x + textObj.width - selection.x - selection.scale.x);

			selection.updateHitbox();

			if(text.length > 0)
			{
				textObj.removeFormat(selectedFormat);
				if(selectIndex != -1 && selectIndex != caretIndex)
				{
					textObj.addFormat(selectedFormat, caretIndex < selectIndex ? caretIndex : selectIndex, caretIndex < selectIndex ? selectIndex : caretIndex);
				}
			}
		}
		else if(text.length > 0) textObj.removeFormat(selectedFormat);
	}

	function deleteSelection()
	{
		var lastText:String = text;
		if(selectIndex > caretIndex)
		{
			text = text.substring(0, caretIndex) + text.substring(selectIndex);
		}
		else
		{
			text = text.substring(0, selectIndex) + text.substring(caretIndex);
			caretIndex = selectIndex;
		}
		selectIndex = -1;
		if(onChange != null) onChange(lastText, text);
		if(broadcastInputTextEvent) PsychUIEventHandler.event(CHANGE_EVENT, this);
	}

	override public function destroy()
	{
		_boundaries = null;
		if(focusOn == this) focusOn = null;
		if (FlxG.stage != null) FlxG.stage.removeEventListener(KeyboardEvent.KEY_DOWN, onKeyDown);
		destroyHiddenTextField();
		super.destroy();
	}

	function set_caretIndex(v:Int)
	{
		caretIndex = v;
		updateCaret();
		return v;
	}

	var _fontSize:Int = 8;
	var _fieldH:Int = 16;
	var _wid:Int = 100;

	/**
	 * Resizes the field. The FlxSpriteGroup variants are deliberately not used here: a group
	 * has no frame, so FlxSpriteGroup.setGraphicSize() computes scale = w / 0 and then copies
	 * that infinite scale (and a bogus offset) onto every child - which is exactly how an input
	 * field ends up drawn at a different place than its own hit box.
	 */
	override public function setGraphicSize(width:Float = 0, height:Float = 0)
	{
		var w:Int = (width > 0) ? Std.int(width) : (_wid + 2);
		var h:Int = (height > 0) ? Std.int(height) : _fieldH;
		applyGeometry(w, h);
	}

	override public function updateHitbox()
	{
		// Geometry is owned by applyGeometry(); see the comment above setGraphicSize().
	}

	/** Lays the frame, the white area, the text, the caret and the selection out at w x h. */
	public function applyGeometry(totalW:Int, totalH:Int)
	{
		_wid = Std.int(Math.max(2, totalW - 2));
		_fieldH = Std.int(Math.max(_fontSize + 4, totalH));

		if (bg != null)
		{
			PsychUIHelper.bakeRounded(bg, _wid + 2, _fieldH, borderRadius);
			bg.color = FlxColor.BLACK;
			bg.x = x;
			bg.y = y;
		}

		if (behindText != null)
		{
			behindText.makeGraphic(_wid, Std.int(Math.max(1, _fieldH - 2)), FlxColor.WHITE, true);
			behindText.x = x + 1;
			behindText.y = y + 1;
		}

		if (textObj != null)
		{
			textObj.x = x + textOffsetX;
			textObj.y = y + textOffsetY;
			textObj.fieldWidth = Math.max(1, _wid - 2);
			textObj.scale.set(1, 1);
			if (caret != null)
			{
				caret.setGraphicSize(1, Std.int(textObj.height) - 4);
				caret.updateHitbox();
			}
		}

		if (selection != null) selection.scale.set(1, 1);
	}

	function set_fieldWidth(v:Int)
	{
		_wid = Std.int(Math.max(2, v));
		textObj.fieldWidth = Math.max(1, v - 2);
		textObj.textField.selectable = false;
		textObj.textField.wordWrap = false;
		textObj.textField.multiline = false;
		return (fieldWidth = v);
	}

	function set_maxLength(v:Int)
	{
		var lastText = text;
		v = Std.int(Math.max(0, v));
		if(v > 0 && text.length > v) text = text.substr(0, v);
		if(onChange != null) onChange(lastText, text);
		if(broadcastInputTextEvent) PsychUIEventHandler.event(CHANGE_EVENT, this);
		return (maxLength = v);
	}

	function set_passwordMask(v:Bool)
	{
		passwordMask = v;
		text = text;
		return passwordMask;
	}

	var _boundaries:Array<Float> = [];
	function set_text(v:String)
	{
		if (_boundaries == null) _boundaries = [];
		for (i in 0..._boundaries.length) _boundaries.pop();
		if (textObj == null || !textObj.exists) return (text = v);
		v = filter(v);

		textObj.text = '';
		if(v != null && v.length > 0)
		{
			if(v.length > 1)
			{
				for (i in 0...v.length)
				{
					var toPrint:String = v.substr(i, 1);
					if(toPrint == '\n') toPrint = ' ';
					textObj.textField.appendText(!passwordMask ? toPrint : '*');
					_boundaries.push(textObj.textField.textWidth);
				}
			}
			else
			{
				textObj.text = !passwordMask ? v : '*';
				_boundaries.push(textObj.textField.textWidth);
			}
		}
		text = v;
		updateCaret();
		return v;
	}

	public static function getAccentCharCode(accent:AccentCode)
	{
		switch(accent)
		{
			case TILDE:
				return 0x7E;
			case CIRCUMFLEX:
				return 0x5E;
			case ACUTE:
				return 0xB4;
			case GRAVE:
				return 0x60;
			default:
				return 0x0;
		}
	}

	public var broadcastInputTextEvent:Bool = true;
	var _skipTextInput:Bool = false;
	static var _textInputActive:Bool = false;
	static var _hiddenTF:openfl.text.TextField = null;
	static var _hiddenTFReady:Bool = false;
	function _typeLetter(charCode:Int)
	{
		if(charCode < 1) return;
		
		if(selectIndex > -1 && selectIndex != caretIndex)
			deleteSelection();

		var letter:String = String.fromCharCode(charCode);
		letter = filter(letter);
		if(letter.length > 0 && (maxLength == 0 || (text.length + letter.length) <= maxLength))
		{
			var lastText = text;
			//trace('Drawing character: $letter');
			if(!inInsertMode)
				text = text.substring(0, caretIndex) + letter + text.substring(caretIndex);
			else
				text = text.substring(0, caretIndex) + letter + text.substring(caretIndex+1);

			caretIndex += letter.length;
			if(onChange != null) onChange(lastText, text);
			if(broadcastInputTextEvent) PsychUIEventHandler.event(CHANGE_EVENT, this);
		}
		_caretTime = 0;
	}

	// from FlxInputText
	function set_forceCase(v:CaseMode)
	{
		forceCase = v;
		text = filter(text);
		return forceCase;
	}

	function set_filterMode(v:FilterMode)
	{
		filterMode = v;
		text = filter(text);
		return filterMode;
	}

	function set_customFilterPattern(cfp:EReg)
	{
		customFilterPattern = cfp;
		filterMode = CUSTOM_FILTER;
		return customFilterPattern;
	}
	
	private function filter(text:String):String
	{
		switch(forceCase)
		{
			case UPPER_CASE:
				text = text.toUpperCase();
			case LOWER_CASE:
				text = text.toLowerCase();
			default:
		}
		if (forceCase == UPPER_CASE)
			text = text.toUpperCase();
		else if (forceCase == LOWER_CASE)
			text = text.toLowerCase();

		if (filterMode != NO_FILTER)
		{
			var pattern:EReg;
			switch (filterMode)
			{
				case ONLY_ALPHA:
					pattern = ~/[^a-zA-Z]*/g;
				case ONLY_NUMERIC:
					pattern = ~/[^0-9]*/g;
				case ONLY_ALPHANUMERIC:
					pattern = ~/[^a-zA-Z0-9]*/g;
				case ONLY_HEXADECIMAL:
					pattern = ~/[^a-fA-F0-9]*/g;
				case CUSTOM_FILTER:
					pattern = customFilterPattern;
				default:
					throw new flash.errors.Error("FlxInputText: Unknown filterMode (" + filterMode + ")");
			}
			// A null custom pattern used to crash every keystroke of a filtered input.
			if (pattern != null) text = pattern.replace(text, "");
		}
		return text;
	}
}