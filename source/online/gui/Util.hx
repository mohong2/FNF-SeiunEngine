package online.gui;

import openfl.text.TextFormat;
import openfl.text.TextField;
import openfl.display.DisplayObject;
import online.gui.sidebar.SideUI;
import online.util.OnlineLang;

@:publicFields
class Util {
	static function checkKey(key:Int, keyID:String):Bool {
		for (k in ClientPrefs.keyBinds.get(keyID)) {
			if (key == k)
				return true;
		}
		return false;
	}

	static function overlapsMouse(obj:DisplayObject) {
		return obj != null && obj.visible && obj.alpha > 0 && obj.mouseX > 0 && obj.mouseX < obj.width && obj.mouseY > 0 && obj.mouseY < obj.height;
		//return obj.mouseX >= obj.x && obj.mouseX <= obj.x + obj.width && obj.mouseY >= obj.y && obj.mouseY <= obj.y + obj.height;
	}

	static function createText(?parent:DisplayObject, x:Float, y:Float, size:Int = 18, ?color:Int = 0xFFFFFFFF) {
		var obj = new TextField();
		obj.x = x;
		obj.y = y;
		obj.selectable = false;
		obj.multiline = true;
		obj.defaultTextFormat = new TextFormat(Assets.getFont(Paths.languageFont()).fontName, size, color, false);
		obj.embedFonts = true;
		return obj;
	}

	static function setText(obj:TextField, text:String, ?maxWidth:Null<Float>, ?color:Null<Int>) {
		obj.scaleX = 1;
		obj.scaleY = 1;
		if (color != null) {
			var format = obj.defaultTextFormat;
			format.color = color;
			obj.defaultTextFormat = format;
		}
		obj.autoSize = LEFT;
		obj.text = text;
		// Clamp to the current tab's width (falling back to SideUI.DEFAULT_TAB_WIDTH, 400); an
		// explicit maxWidth still wins. Guarded on the tab array because setText() is also used
		// by the Alert / LoadingScreen overlays, which run before the sidebar exists.
		var availWidth:Float;
		if (maxWidth != null)
			availWidth = maxWidth;
		else {
			var tabWidth:Float = SideUI.DEFAULT_TAB_WIDTH;
			if (SideUI.instance != null && SideUI.instance.tabs != null && SideUI.instance.tabs.length > 0)
				tabWidth = SideUI.instance.curTab.tabWidth;
			availWidth = tabWidth - obj.x - 20;
		}
		obj.scaleX = Math.min(1, availWidth / obj.width);
		obj.scaleY = obj.scaleX;
	}

	static function getTextWidth(obj:TextField) {
		return obj.textWidth;
	}
	static function getTextHeight(obj:TextField):Float {
		return obj.textHeight;
	}

	static function inviteToPlay(daUsername:String) {
		if (GameClient.isConnected()) {
			if (NetworkClient.room == null)
				NetworkClient.connect();

			while (NetworkClient.connecting) {}

			if (NetworkClient.room != null) {
				NetworkClient.room.send('inviteplayertoroom', daUsername);
			}
			else
				Alert.alert(OnlineLang.L('net.connectFailedExcl', 'Failed to connect to the Network!'));
		}
		else {
			Alert.alert(OnlineLang.L('net.notInRoom', "You're not in a room!"));
		}
	}

	static function getRealHeight(?parent:DisplayObject) {
		var maxHeight:Float = 0;
		for (child in @:privateAccess parent.__children) {
			if (child.visible)
				maxHeight = Math.max(maxHeight, child.y + child.height - parent.y);
		}
		return maxHeight;
	}

	static function wrapText(text:String, ?everyCharacters:Int = 45, ?stopAtLine:Int = 10, ?trimLines:Bool = true) {
		var output = '';
		var i = -1;
		var score = 0;
		var lineScore = 0;
		var char = '';

		while (++i < text.length) {
			if (char == '\n' && char == text.charAt(i)) {
				//skip double newlines
				continue;
			}
			char = text.charAt(i);
			score++;

			if (score >= everyCharacters) {
				score = 0;
				lineScore++;

				if (lineScore >= stopAtLine) {
					break;
				}

				if (trimLines) {
					output += '[...]\n';
					while (++i < text.length) {
						if (text.charAt(i) == ' ' || text.charAt(i) == '\n') {
							break;
						}
					}
					continue;
				}
				else {
					output += '\n';
				}
			}
			else if (score >= everyCharacters - 10 && char == ' ') {
				score = 0;
				output += '\n';
				lineScore++;
				if (lineScore >= stopAtLine) {
					break;
				}
				continue;
			}

			if (char == '\n') {
				score = 0;
				lineScore++;
				if (lineScore >= stopAtLine) {
					break;
				}
			}

			output += char;
		}

		if (lineScore >= stopAtLine) {
			output += '\n...';
		}

		return output;
	}
}