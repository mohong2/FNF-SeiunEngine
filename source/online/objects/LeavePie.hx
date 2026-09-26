package online.objects;

import flixel.addons.display.FlxPieDial;
import online.util.OnlineLang;

class LeavePie extends FlxTypedSpriteGroup<FlxSprite> {
	public var pieDial:FlxPieDial;
	var exitTip:FlxText;
	var theFog:FlxSprite;
	var finished:Bool = false;
    
    public function new() {
        super();

		theFog = new FlxSprite();
		theFog.makeGraphic(FlxG.width, FlxG.height, FlxColor.BLACK);
		theFog.alpha = 0;
		add(theFog);

		pieDial = new FlxPieDial(10, 10, 25, FlxColor.WHITE, 36, FlxPieDialShape.CIRCLE, true, 12);
		pieDial.amount = 0.0;
		replaceDialColor(pieDial, FlxColor.BLACK, FlxColor.TRANSPARENT);
		pieDial.antialiasing = ClientPrefs.data.globalAntialiasing;
		add(pieDial);

		exitTip = new FlxText(pieDial.x + 80, pieDial.y + 5, 0, OnlineLang.L('room.holdBack', 'Hold BACK to leave!'));
		exitTip.setFormat(OnlineLang.font(), 18, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		exitTip.alpha = 0;
		add(exitTip);

		pieDial.x = FlxG.width - pieDial.width - 10;
		exitTip.x = pieDial.x - exitTip.width - 10;
    }

    override function update(elapsed) {
        super.update(elapsed);

		// `ChatBox.instance` must be null-checked: on cpp a null field access is a native crash
		// rather than a Haxe exception.
		var chatFocused:Bool = ChatBox.instance != null && ChatBox.instance.focused;

		// `RoomState.controls` is `PlayerSettings.player1.controls`, not an engine-wide
		// `Controls.instance`, so `controls.pressed('back')` alone is not trustworthy: global key
		// state is read as well, making a held ESC or BACKSPACE equivalent to a held BACK.
		var backHeld:Bool = getState().controls.pressed('back')
			#if android || FlxG.android.pressed.BACK #end
			|| FlxG.keys.pressed.ESCAPE
			|| FlxG.keys.pressed.BACKSPACE;

		if (backHeld && !chatFocused) {
			exitTip.alpha = 1;
			pieDial.amount += elapsed * 2;
			pieDial.visible = true;
			if (!finished && pieDial.amount >= 1.0) {
				finished = true;
				GameClient.leaveTrace('LeavePie trigger amount=' + pieDial.amount + ' inPlay=' + (FlxG.state is PlayState));

				if (FlxG.state is PlayState)
					if (FlxG.keys.pressed.F1)
						GameClient.leaveRoom(null, true);
					else
						GameClient.send("requestEndSong");
				else
					GameClient.leaveRoom(null, true);
			}
		}
		else {
			// `finished` must be reset after a release. If the first long press does not really
			// leave the room (e.g. the client is already disconnected and `GameClient.leaveRoom`
			// returns silently), the player is stuck on the room screen forever: the tip still
			// shows but no press ever triggers again. Releasing the key allows a retry here.
			finished = false;
			pieDial.amount -= elapsed * 6;
			exitTip.alpha -= elapsed;
		}

		if (pieDial.amount <= 0.03) {
			pieDial.visible = false;
		}
		theFog.alpha = pieDial.amount;
	}

    function getState():MusicBeatState {
        return cast FlxG.state;
    }

	/**
	 * Flixel-addons 2.11.0 (`flixel/addons/display/FlxPieDial.hx` exposes only `amount` / `draw`)
	 * has no `replaceColor` and cannot be upgraded offline, so the black background is replaced
	 * on the dial's bitmap directly, matching what `replaceColor(BLACK, TRANSPARENT)`
	 * would have done.
	 *
	 * Why BLACK is present in the dial at all: 2.11.0's generator paints the un-swept part with
	 * `back = Clockwise ? FlxColor.BLACK : FlxColor.WHITE` (`FlxPieDial.hx:67`) and this dial is
	 * built with `Clockwise = true`, so its background really is BLACK.
	 */
	static function replaceDialColor(dial:FlxPieDial, from:FlxColor, to:FlxColor):Void
	{
		var bmp = dial.pixels;
		if (bmp == null)
			return;

		var fromInt:Int = cast from;
		var toInt:Int = cast to;

		var w = bmp.width;
		var h = bmp.height;
		for (y in 0...h)
		{
			for (x in 0...w)
			{
				if (bmp.getPixel32(x, y) == fromInt)
					bmp.setPixel32(x, y, toInt);
			}
		}
	}
}
