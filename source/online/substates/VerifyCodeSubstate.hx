package online.substates;

import openfl.filters.BlurFilter;
import online.util.OnlineLang;

class VerifyCodeSubstate extends MusicBeatSubstate {
    public function new(onEnter:String->Void) {
        super();

        this.onEnter = onEnter;
    }

    var onEnter:String->Void;
	var blurFilter:BlurFilter;
	var coolCam:FlxCamera;

    override function create() {
        super.create();

		blurFilter = new BlurFilter();
		for (cam in FlxG.cameras.list) {
			if (cam.filters == null)
				cam.filters = [];
			cam.filters.push(blurFilter);
		}

		coolCam = new FlxCamera();
		coolCam.bgColor.alpha = 0;
		FlxG.cameras.add(coolCam, false);

		cameras = [coolCam];

		var bg = new FlxSprite();
		bg.makeGraphic(FlxG.width, FlxG.height, FlxColor.BLACK);
		bg.alpha = 0.7;
		bg.scrollFactor.set(0, 0);
		add(bg);

		var title = new FlxText(0, 0, FlxG.width, 
			OnlineLang.L('verifyCode.title', 'A Verification Code may have been sent to this email!\nPlease note, that the server will not tell you if this email is registered!\nIf you can\'t find it, check your spam inbox.\nEnter it here, if you receive it!')
		);
		title.setFormat(OnlineLang.font(), 24, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		title.y = FlxG.height / 2 - title.height / 2 - 200;
		title.scrollFactor.set();
		add(title);

		input = new InputText(0, 0, FlxG.width, text -> submit(text));
		input.setFormat(OnlineLang.font(), 30, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		input.y = FlxG.height / 2 - input.height / 2;
		input.scrollFactor.set();
		add(input);

		// On-screen controls: A confirms the code, B cancels. There is no list to navigate, so the
		// D-pad is omitted.
		addVirtualPad(NONE, A_B);
		// Online pad layout: shrunk buttons tucked into the corners, clear of the UI.
		OnlineNav.layoutActions(virtualPad);
		addPadCamera();
    }

	/** Submits the current code; ENTER and the on-screen A button both go through here. */
	function submit(text:String):Void {
		onEnter(text.trim().toUpperCase());
		close();
	}

	override function destroy() {
		super.destroy();

		for (cam in FlxG.cameras.list) {
			if (cam != null && cam.filters != null)
				cam.filters.remove(blurFilter);
		}
		FlxG.cameras.remove(coolCam);
	}

	var input:InputText;

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
}
