package online.substates;

import online.util.OnlineLang;

class PostTextSubstate extends MusicBeatSubstate {
	var title:String;
	var onEnter:String->Void;

	public function new(title:String, onEnter:String->Void) {
        super();

		this.title = title;
		this.onEnter = onEnter;
    }

	var input:InputText;
	var coolCam:FlxCamera;

    override function create() {
        super.create();

		coolCam = new FlxCamera();
		coolCam.bgColor.alpha = 0;
		FlxG.cameras.add(coolCam, false);

		cameras = [coolCam];

		var bg = new FlxSprite();
		bg.makeGraphic(FlxG.width, FlxG.height, FlxColor.BLACK);
		bg.alpha = 0.7;
		bg.scrollFactor.set(0, 0);
		add(bg);

		var title = new FlxText(0, 0, FlxG.width, this.title + OnlineLang.L('postText.submitHint', "\n\n(Press ENTER to submit)"));
		title.setFormat(OnlineLang.font(), 24, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		title.y = FlxG.height / 2 - title.height / 2 - 150;
		title.scrollFactor.set();
		add(title);

		input = new InputText(0, 0, FlxG.width, text -> submit(text));
		input.setFormat(OnlineLang.font(), 24, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		input.y = FlxG.height / 2 - input.height / 2;
		input.scrollFactor.set();
		add(input);

		// On-screen controls: A confirms the text, B cancels. There is no list to navigate, so the
		// D-pad is omitted.
		addVirtualPad(NONE, A_B);
		// Online pad layout: shrunk buttons tucked into the corners, clear of the UI.
		OnlineNav.layoutActions(virtualPad);
		addPadCamera();
    }

    var confirmBack = false;
    override function update(elapsed) {
        super.update(elapsed);

		input.hasFocus = true;

        if (input.text.length <= 0 && controls.BACK #if android || FlxG.android.justReleased.BACK #end) {
            if (!confirmBack) {
				confirmBack = true;
                return;
            }
            close();
        }
		else if (input.text.length > 0) {
			confirmBack = false;
        }

		// The pad's A confirms. `controls.ACCEPT` is not used here because this engine also binds
		// it to SPACE, and a space is a character the player has to be able to type.
		if (virtualPad != null && virtualPad.buttonA != null && virtualPad.buttonA.justPressed)
			submit(input.text);
    }

	/** Submits the current text; ENTER and the on-screen A button both go through here. */
	function submit(text:String):Void {
		if (text.trim().length <= 0)
			return;

		onEnter(text);
		close();
	}

	override function destroy() {
		super.destroy();

		FlxG.cameras.remove(coolCam);
	}
}
