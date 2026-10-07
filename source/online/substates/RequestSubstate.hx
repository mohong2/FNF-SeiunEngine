package online.substates;

import openfl.filters.BlurFilter;
import flixel.util.FlxSpriteUtil;
import online.substates.RoomSettingsSubstate.Option;
import online.util.OnlineLang;

class RequestSubstate extends MusicBeatSubstate {
	public var prompt:String;
	public var url:String;
	public var yesCallback:(nowTrusting:Null<Bool>) -> Void;
	public var noCallback:Void->Void;
	public var trust:Option;
	public var onCreate:RequestSubstate->Void;
	
	var disableTrusting:Bool = false;

	public var promptText:FlxText;
	public var urlText:FlxText;
	public var yes:FlxText;
	public var no:FlxText;
	public var yesBg:FlxSprite;
	public var noBg:FlxSprite;

	var curSelected:Int = -1;
	var hovered:Int = -1;
	var nav = new NavRepeat();

	var blurFilter:BlurFilter;
	var coolCam:FlxCamera;

	public static function requestURL(url:String, ?prompt:String = null, ?disableTrusting:Bool = false) {
		request(prompt, url, nowTrusting -> {
			if (nowTrusting != null) {
				var splitURL = url.split("//");
				if (nowTrusting)
					ClientPrefs.data.trustedSources.push(splitURL[0] + "//" + splitURL[1].split("/")[0]);
				else
					ClientPrefs.data.trustedSources.remove(splitURL[0] + "//" + splitURL[1].split("/")[0]);
				ClientPrefs.saveSettings();
			}

			FlxG.openURL(url);
		}, null, disableTrusting);
	}

	public static function requestDownload(url:String, ?prompt:String = null, ?onDownloadFinished:String->Void, ?disableTrusting:Bool = false, ?yesCallback:Void->Void) {
		request(prompt, url, nowTrusting -> {
			if (nowTrusting != null) {
				var splitURL = url.split("//");
				if (nowTrusting)
					ClientPrefs.data.trustedSources.push(splitURL[0] + "//" + splitURL[1].split("/")[0]);
				else
					ClientPrefs.data.trustedSources.remove(splitURL[0] + "//" + splitURL[1].split("/")[0]);
				ClientPrefs.saveSettings();
				if (yesCallback != null)
					yesCallback();
			}

			OnlineMods.startDownloadMod(url, url, null, onDownloadFinished);
		}, null, disableTrusting);
	}

	public static function request(prompt:String, url:String, yesCallback:(nowTrusting:Null<Bool>)->Void, noCallback:Void->Void, ?disableTrusting:Bool = false, ?onCreate:RequestSubstate->Void) {
		if (FlxG.state.subState != null)
			FlxG.state.subState.close();

		if (!disableTrusting) {
			for (source in ClientPrefs.data.trustedSources) {
				if (StringTools.startsWith(url, source)) {
					yesCallback(null);
					return;
				}
			}
		}

		FlxG.state.openSubState(new RequestSubstate(prompt, url, yesCallback, noCallback, disableTrusting, onCreate));
    }

	var _tempShowMouse:Bool = false;

	private function new(prompt:String, url:String, yesCallback:(nowTrusting:Null<Bool>) -> Void, noCallback:Void->Void, disableTrusting:Bool, onCreate:RequestSubstate->Void) {
        super();

		this.prompt = prompt;
		this.url = url;
		this.yesCallback = yesCallback;
		this.noCallback = noCallback;
		this.disableTrusting = disableTrusting;
		this.onCreate = onCreate;
    }

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

		if (!FlxG.mouse.visible) {
			FlxG.mouse.visible = true;
			_tempShowMouse = true;
		}

		var preBg = new FlxSprite();
		preBg.makeGraphic(FlxG.width, FlxG.height, FlxColor.BLACK);
		preBg.alpha = 0.4;
		preBg.scrollFactor.set(0, 0);
		add(preBg);

		var bg = new FlxSprite();
		bg.makeGraphic(Std.int(FlxG.width / 2), FlxG.height, FlxColor.BLACK);
		bg.alpha = 0.7;
		bg.scrollFactor.set(0, 0);
		bg.screenCenter(X);
		add(bg);

		var promptLabel = prompt != null ? prompt : OnlineLang.L('request.openLink', 'Do you want to open this link');
		// Only add the trailing colon when the prompt does not already end with punctuation
		// (a question mark kept getting a stray ':' glued on).
		if (promptLabel.length > 0
			&& !promptLabel.endsWith(':') && !promptLabel.endsWith('：')
			&& !promptLabel.endsWith('?') && !promptLabel.endsWith('？')
			&& !promptLabel.endsWith('!') && !promptLabel.endsWith('！')
			&& !promptLabel.endsWith('.') && !promptLabel.endsWith('。')
			&& !promptLabel.endsWith(')') && !promptLabel.endsWith('）'))
			promptLabel += ':';
		promptText = new FlxText(bg.x, 200, bg.width - 50, promptLabel);
		promptText.setFormat(OnlineLang.font(), 25, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		promptText.scrollFactor.set(0, 0);
		promptText.screenCenter(X);
		add(promptText);
		// Measure now: the buttons are placed below the message, so both heights have to be the
		// real ones instead of the 0 a freshly built FlxText reports before it regenerates.
		promptText.updateHitbox();

		urlText = new FlxText(bg.x, promptText.y + promptText.height + 20, bg.width - 50, url);
		urlText.setFormat(OnlineLang.font(), 20, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		urlText.scrollFactor.set(0, 0);
		urlText.screenCenter(X);
		urlText.alpha = 0.8;
		add(urlText);
		urlText.updateHitbox();

		yes = new FlxText(0, 0, 0, OnlineLang.L('request.yes', 'Yes'));
		yes.setFormat(OnlineLang.font(), 30, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		yes.x = FlxG.width / 2 - yes.width / 2 - 150;
		// Below whichever is lower. A message that wraps to three or four lines used to be drawn
		// straight through the two buttons, which sat at a fixed offset under the prompt.
		yes.y = Math.max(promptText.y + 200, urlText.y + urlText.height + 40);
		yes.scrollFactor.set(0, 0);
		yesBg = makeButtonBg(yes);
		add(yesBg);
		add(yes);

		no = new FlxText(0, 0, 0, OnlineLang.L('request.no', 'No'));
		no.setFormat(OnlineLang.font(), 30, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		no.x = FlxG.width / 2 - no.width / 2 + 150;
		no.y = yes.y;
		no.scrollFactor.set(0, 0);
		noBg = makeButtonBg(no);
		add(noBg);
		add(no);

		if (!disableTrusting) {
			add(trust = new Option(OnlineLang.L('request.trust', 'Trust this source'), OnlineLang.L('request.trust.desc', 'If checked, you will no longer be asked\nto accept links from this domain.'), () -> {
				trust.checked = !trust.checked;
			}, null, 0, 500, isURLTrusted(url)));
			// Created at y = 500, i.e. under the buttons; if a long message pushed them below that,
			// the trust row follows instead of being covered by them.
			trust.y = Math.max(500, yes.y + 90);
			trust.scrollFactor.set(0, 0);
			trust.screenCenter(X);
			trust.alpha = 0.6;
		}

		yes.alpha = 0.6;
		no.alpha = 0.6;

		items = !disableTrusting ? 2 : 1;

		if (onCreate != null)
			onCreate(this);

		// On-screen controls (Android always, desktop when "touch controls" is on): LEFT/RIGHT walk
		// this popup's buttons, A confirms and B is wired to BACK, taking the same cancel path.
		// LEFT_RIGHT (not UP_DOWN) is what actually binds the pad to UI_LEFT/UI_RIGHT here.
		addVirtualPad(LEFT_RIGHT, A_B);
		// Online pad layout: shrunk buttons tucked into the corners, clear of the UI.
		OnlineNav.layoutRow(virtualPad);
		addPadCamera();
	}

	override function destroy() {
		super.destroy();

		for (cam in FlxG.cameras.list) {
			if (cam != null && cam.filters != null)
				cam.filters.remove(blurFilter);
		}
		FlxG.cameras.remove(coolCam);
	}

	override public function close() {
		super.close();

		if (_tempShowMouse) {
			_tempShowMouse = false;
			FlxG.mouse.visible = false;
		}
	}

	var items:Int = 2;
	override function update(elapsed) {
		super.update(elapsed);

		// LEFT steps back and RIGHT steps forward, with hold-to-repeat so either pad arrow can be
		// held down. (Both directions used to advance, which made the two arrows identical.)
		var steps = nav.poll(controls.UI_LEFT, controls.UI_RIGHT, elapsed);
		while (steps != 0) {
			var dir = steps > 0 ? 1 : -1;
			curSelected += dir;

			if (curSelected > items) {
				curSelected = 0;
			}
			else if (curSelected < 0) {
				curSelected = items;
			}

			steps -= dir;
		}

		// A tap that lands on the on-screen pad belongs to the pad (d-pad/A/B), never to the
		// button drawn behind it.
		var padTap = OnlineNav.padBlocks(virtualPad);
		var pointerClick = FlxG.mouse.justPressed && !padTap;

		// The pointer only lights the button it sits on up, and never moves curSelected. This runs
		// every frame so the highlight always matches the click target.
		hovered = -1;
		if (!padTap) {
			if (OnlineNav.pointerOver(yesBg, coolCam))
				hovered = 0;
			else if (OnlineNav.pointerOver(noBg, coolCam))
				hovered = 1;
			else if (!disableTrusting && trust != null && OnlineNav.pointerOver(trust, coolCam))
				hovered = 2;
		}

		var active = hovered >= 0 ? hovered : curSelected;

		yes.alpha = 0.6;
		no.alpha = 0.6;
		if (!disableTrusting && trust != null)
			trust.alpha = 0.6;

		switch active {
			case 0:
				yes.alpha = 1;
			case 1:
				no.alpha = 1;
			case 2:
				if (!disableTrusting && trust != null)
					trust.alpha = 1;
		}

		// A follows the highlight the pointer/keys produce; with nothing highlighted yet it
		// confirms the first action instead of being a dead button.
		if (pointerClick && hovered >= 0)
			activate(hovered);
		else if (controls.ACCEPT)
			activate(hovered >= 0 ? hovered : (curSelected >= 0 ? curSelected : 0));

		// BACK is what the pad's B button drives; it takes the same cancel path ESCAPE used to.
		if (controls.BACK) {
			if (noCallback != null)
				noCallback();
			close();
		}
	}

	/**
	 * A button background drawn at its real size. The old 1x1 sprite scaled by the label size
	 * produced a hitbox that did not line up with what was on screen: FlxPointer.overlaps()
	 * compares against the object's x/y/width/height and ignores FlxSprite.offset, which
	 * updateHitbox() had set to a negative value -- so clicks landed outside the drawn button.
	 */
	function makeButtonBg(label:FlxText):FlxSprite {
		var w:Int = Std.int(Math.max(200, label.width + 60));
		var h:Int = Std.int(Math.max(64, label.height + 24));

		var bg = new FlxSprite(label.x + label.width / 2 - w / 2, label.y + label.height / 2 - h / 2);
		bg.makeGraphic(w, h, 0x5D000000);
		FlxSpriteUtil.drawRect(bg, 0, 0, w, h, FlxColor.TRANSPARENT, {thickness: 4, color: 0x64FFFFFF});
		bg.scrollFactor.set(0, 0);
		return bg;
	}

	function activate(index:Int):Void {
		switch index {
			case 0:
				// Haxe 4.2.5 has no safe-navigation (`?.`); expand to an explicit null check.
				var trustChecked:Null<Bool> = null;
				if (trust != null)
					trustChecked = trust.checked;
				yesCallback(trustChecked);
				close();
			case 1:
				if (noCallback != null)
					noCallback();
				close();
			case 2:
				if (!disableTrusting && trust != null)
					trust.onClick();
		}
	}

	function isURLTrusted(url:String) {
		for (source in ClientPrefs.data.trustedSources) {
			if (StringTools.startsWith(url, source)) {
				return true;
			}
		}
		return false;
	}
}
