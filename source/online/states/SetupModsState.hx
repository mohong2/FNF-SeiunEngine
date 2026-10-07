package online.states;

import lime.system.Clipboard;
import openfl.events.KeyboardEvent;
import online.util.OnlineLang;

#if lumod
@:build(lumod.LuaScriptClass.build())
#end
class SetupModsState extends MusicBeatState {
	var items:FlxTypedSpriteGroup<FlxText>;

    public function new(mods:Array<String>, fromOptions:Bool) {
        super();

        swagMods = mods;
		this.fromOptions = fromOptions;
    }

	var swagMods:Array<String> = [];

	var curSelected = 0;
	var inInput = false;
    var modsInput:Array<String> = [];

	var selectLine:FlxSprite;
	
	var fromOptions:Bool = false;

	/** UP/DOWN hold-to-repeat, shared with the on-screen pad. */
	var nav = new NavRepeat();

	/** Row under the pointer, or -1. Hover only lights it up; a click is what selects it. */
	var hoverIndex:Int = -1;

    override function create() {
        super.create();

		// On-screen controls: UP/DOWN pick a row, A accepts, B backs out. Mounted by every online
		// screen; a pad tap is ignored by the row hit tests below.
		addVirtualPad(UP_DOWN, A_B);
		// Online pad layout: shrunk buttons tucked into the corners, clear of the UI.
		OnlineNav.layoutColumn(virtualPad);
		addPadCamera();

		#if DISCORD_ALLOWED
		DiscordClient.changePresence("In the Menus", "Mods URL Setup");
		#end

		var bg:FlxSprite = new FlxSprite().loadGraphic(Paths.image('menuDesat'));
		bg.color = 0xff5a1f46;
		bg.updateHitbox();
		bg.screenCenter();
		bg.antialiasing = ClientPrefs.data.globalAntialiasing;
		bg.scrollFactor.set(0, 0);
		add(bg);

		var lines:FlxSprite = new FlxSprite().loadGraphic(Paths.image('coolLines'));
		lines.updateHitbox();
		lines.screenCenter();
		lines.antialiasing = ClientPrefs.data.globalAntialiasing;
		lines.scrollFactor.set(0, 0);
		add(lines);

		selectLine = new FlxSprite();
		selectLine.makeGraphic(1, 1, FlxColor.BLACK);
		selectLine.alpha = 0.3;
		selectLine.scale.set(FlxG.width, 30);
		selectLine.screenCenter(XY);
		selectLine.y -= 7;
		selectLine.scrollFactor.set(0, 0);
		add(selectLine);

		items = new FlxTypedSpriteGroup<FlxText>();
		var prevText:FlxText = null;
		var i = 0;
		for (itm in swagMods) {
			var text = new FlxText(0, 0, 0, itm);
			if (prevText != null) {
				text.y += prevText.height * i;
			}
			text.ID = i;
			text.setFormat(OnlineLang.font(), 25, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
			items.add(prevText = text);
			modsInput.push(OnlineMods.getModURL(itm));
			i++;
		}
		items.screenCenter(Y);
		add(items);

		var title = new FlxText(0, 0, FlxG.width, 
        OnlineLang.L('setupMods.title', "Before you play, it is recommended to set links for your mods!\nSelect mods with ACCEPT, Paste links with CTRL + V, Leave with BACK\nHold SHIFT while exiting to discard all changes")
        );
		title.setFormat(OnlineLang.font(), 22, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		title.y = 50;
		title.scrollFactor.set(0, 0);

		var titleBg = new FlxSprite();
		titleBg.makeGraphic(1, 1, 0x8C000000);
		titleBg.updateHitbox();
		titleBg.y = title.y;
		titleBg.x = title.x;
		titleBg.scale.set(title.width, title.height);
		titleBg.updateHitbox();
		titleBg.scrollFactor.set(0, 0);
		add(titleBg);
		add(title);

		FlxG.stage.addEventListener(KeyboardEvent.KEY_DOWN, onKeyDown);

		changeSelection(0);
    }

    override function update(elapsed:Float) {
        super.update(elapsed);

        if (disableInput) return;

		// A tap that lands on the on-screen pad belongs to the pad, never to a row behind it.
		var padTap = OnlineNav.padBlocks(virtualPad);
		var pointerClick = FlxG.mouse.justPressed && !padTap;

		// Hover is recomputed every frame: it only lights a row up, it never selects one.
		var newHover = padTap ? -1 : rowUnderPointer();
		if (newHover != hoverIndex) {
			hoverIndex = newHover;
			changeSelection(0);
		}

		if (!inInput) {
			// A click selects the row it hit and starts editing it; ACCEPT edits the current one.
			if (controls.ACCEPT || (pointerClick && hoverIndex >= 0)) {
				if (pointerClick)
					changeSelection(hoverIndex - curSelected);
				inInput = true;
				changeSelection(0);
			}

			// Wheel (1 = up) plus the pad/keyboard, with hold-to-repeat. The pointer no longer
			// moves the selection on its own.
			var steps = nav.poll(controls.UI_UP, controls.UI_DOWN, elapsed) - FlxG.mouse.wheel;
			while (steps != 0) {
				var dir = steps > 0 ? 1 : -1;
				changeSelection(dir);
				steps -= dir;
			}

			if (controls.BACK #if android || FlxG.android.justReleased.BACK #end || (FlxG.mouse.justPressedRight && !padTap)) {
				if (!FlxG.keys.pressed.SHIFT) {
					var i = 0;
					for (mod in swagMods) {
						OnlineMods.saveModURL(mod, modsInput[i]);
						i++;
					}
				}

				// The source passes a lambda to `FlxG.switchState`; this engine's signature takes a
				// `FlxState` directly.
				FlxG.switchState(fromOptions ? new OnlineOptionsState() : new OnlineState());
				FlxG.sound.play(Paths.sound('cancelMenu'));
				states.TitleState.playFreakyMusic();
			}
        }
		else {
			// While a link is being edited, BACK (the pad's B, ESC, or the Android back gesture)
			// leaves the edit exactly like a right click does. It used to be ignored here, so B
			// did nothing at all until the edit was closed with the mouse.
			if (controls.BACK #if android || FlxG.android.justReleased.BACK #end || (FlxG.mouse.justPressedRight && !padTap)) {
				tempDisableInput();
				inInput = false;
				changeSelection(0);
			}
		}
    }

	/** Row under the pointer, or -1. The list scrolls with the camera, hence the camera-aware test. */
	function rowUnderPointer():Int {
		for (item in items) {
			if (item != null && OnlineNav.pointerOver(item, camera))
				return item.ID;
		}
		return -1;
	}

    function changeSelection(difference:Int) {
		curSelected += difference;

		if (curSelected >= swagMods.length) {
			curSelected = 0;
		}
		else if (curSelected < 0) {
			curSelected = swagMods.length - 1;
		}

		// how the fuck can this be null
		if (items == null)
			return;

		for (item in items) {
			item.text = getItemName(item.ID);
			var selected = item.ID == curSelected;
			// Hover lights the row up; only the selected row gets the "> <" markers.
			item.alpha = selected ? 1 : (inInput ? 0.5 : (item.ID == hoverIndex ? 0.85 : 0.7));
			if (selected) {
				FlxG.camera.follow(item);
				item.text = "> " + item.text + " <";
			}

			if (OnlineMods.checkInvalidURL(modsInput[item.ID]))
				item.color = FlxColor.RED;
			else
				item.color = FlxColor.LIME;
			item.screenCenter(X);
		}
    }

	function getItemName(item:Int) {
		if (item == curSelected && inInput)
			return modsInput[item] != null ? modsInput[item] : "";
		return swagMods[item] != null ? swagMods[item] : "";
	}

	function onKeyDown(e:KeyboardEvent) {
		if (!inInput)
			return;

		var key = e.keyCode;

		if (e.charCode == 0) { // non-printable characters crash String.fromCharCode
			return;
		}

		if (key == 46) { // delete
			return;
		}

		if (key == 8) { // bckspc
			modsInput[curSelected] = modsInput[curSelected].substring(0, modsInput[curSelected].length - 1);
			changeSelection(0);
			return;
		}
		else if (key == 13 || key == 27) { // enter or esc
			tempDisableInput();
			inInput = false;
			changeSelection(0);
			return;
		}

		var newText:String = String.fromCharCode(e.charCode);
		if ((curSelected == 0 && !e.shiftKey) || (curSelected != 0 && e.shiftKey)) {
			newText = newText.toUpperCase();
		}
		else {
			newText = newText.toLowerCase();
		}

		if (key == 86 && e.ctrlKey) {
			newText = Clipboard.text;
		}

		if (newText.length > 0) {
			modsInput[curSelected] += newText;
		}

		changeSelection(0);
	}

	var disableInput = false;
	function tempDisableInput() {
		disableInput = true;
		new FlxTimer().start(0.1, (t) -> disableInput = false);
	}
}
