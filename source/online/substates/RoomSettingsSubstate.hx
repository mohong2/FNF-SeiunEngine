package online.substates;

import openfl.filters.BlurFilter;
import substates.GameplayChangersSubstate;
import options.OptionsState;
import flixel.util.FlxSpriteUtil;
import states.ModsMenuState;
import online.util.OnlineLang;

class RoomSettingsSubstate extends MusicBeatSubstate {
    var bg:FlxSprite;
	var prevMouseVisibility:Bool = false;
	var items:FlxTypedSpriteGroup<Option>;
	var curSelectedID:Int = 0;
	var nav = new NavRepeat();
	/** Hovered row, or -1. Hover only lights the row up; it never selects it. */
	var hoverIndex:Int = -1;

	var blurFilter:BlurFilter;
	var coolCam:FlxCamera;

    //options
	var hideGF:Option;
	var disableSkins:Option;
	var winCondition:Option;
	var modifers:Option;
	// var mods:Option;
	var skinSelect:Option;
	var gameOptions:Option;
	var stageSelect:Option;
	var publicRoom:Option;
	var networkOnlyRoom:Option;
	var anarchyMode:Option;
	var allPlayersChoose:Option;
	var swapSides:Option;
	var teamMode:Option;
	var royalMode:Option;
	var royalModeDadSide:Option;
	var pausePolicy:Option;

	override function create() {
		super.create();

		// On-screen controls (Android always, desktop when "touch controls" is on): UP/DOWN pick a
		// row and A accepts. B is wired to BACK, which closes this substate.
		//
		// Mounted before the rows are built, because the list has to start to the right of the
		// pad's direction column instead of underneath it. The camera is added at the end, once
		// coolCam exists, so the pad still draws on top.
		addVirtualPad(UP_DOWN, A_B);
		// Online pad layout: shrunk buttons tucked into the corners, clear of the UI.
		OnlineNav.layoutColumn(virtualPad);

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

		prevMouseVisibility = FlxG.mouse.visible;

		FlxG.mouse.visible = true;

		bg = new FlxSprite();
		bg.makeGraphic(FlxG.width, FlxG.height, FlxColor.BLACK);
		bg.alpha = 0.7;
		bg.scrollFactor.set(0, 0);
		add(bg);

		// The pad's UP/DOWN column covers x 0..128, so on touch builds the rows (checkbox, title
		// and description) start to the right of it. Without a pad the list keeps its old x.
		items = new FlxTypedSpriteGroup<Option>(virtualPad != null ? 120 : 40, 40);

		items.add(publicRoom = new Option(OnlineLang.L('settings.publicRoom', 'Public Room'), OnlineLang.L('settings.publicRoom.desc', 'If enabled, this room will be publicly listed in the FIND tab.'), () -> {
			GameClient.send("togglePrivate");
		}, (elapsed) -> {
			publicRoom.alpha = GameClient.hasPerms() ? 1 : 0.8;

			publicRoom.checked = !GameClient.room.state.isPrivate;
		}, 0, 0, !GameClient.room.state.isPrivate));

		items.add(networkOnlyRoom = new Option(OnlineLang.L('settings.networkOnly', 'Only Network Players'), OnlineLang.L('settings.networkOnly.desc', 'If enabled, only registered players to the network can join.'), () -> {
			GameClient.send("toggleNetworkOnly");
		}, (elapsed) -> {
			networkOnlyRoom.alpha = GameClient.hasPerms() ? 1 : 0.8;

			networkOnlyRoom.checked = GameClient.room.state.networkOnly;
		}, 0, 0, GameClient.room.state.networkOnly));

		items.add(anarchyMode = new Option(OnlineLang.L('settings.anarchy', 'Anarchy Mode'), OnlineLang.L('settings.anarchy.desc', 'This option gives other players host permissions.'), () -> {
			GameClient.send("anarchyMode");
		}, (elapsed) -> {
			anarchyMode.alpha = GameClient.hasPerms() ? 1 : 0.8;

			anarchyMode.checked = GameClient.room.state.anarchyMode;
		}, 0, 0, GameClient.room.state.anarchyMode));

		items.add(allPlayersChoose = new Option(OnlineLang.L('settings.playersChoose', 'Let Players Choose'), OnlineLang.L('settings.playersChoose.desc', 'This option gives other players permission to pick a song and stage.'), () -> {
			GameClient.send("togglePlayersCanChoose");
		}, (elapsed) -> {
			allPlayersChoose.alpha = GameClient.hasPerms() ? 1 : 0.8;

			allPlayersChoose.checked = GameClient.room.state.allPlayersChoose;
			
		}, 0, 0, GameClient.room.state.allPlayersChoose));
		items.add(swapSides = new Option(OnlineLang.L('settings.bfSide', 'Boyfriend Side'), OnlineLang.L('settings.bfSide.desc', "Play on Boyfriend's side."), () -> {
			GameClient.send("swapSides");
		}, (elapsed) -> {
			swapSides.alpha = GameClient.hasPerms() ? 1 : 0.8;

			swapSides.checked = GameClient.getPlayerSelf().bfSide;
		}, 0, 0, GameClient.getPlayerSelf().bfSide));

		items.add(teamMode = new Option(OnlineLang.L('settings.teamMode', 'Team Mode'), OnlineLang.L('settings.teamMode.desc', 'Compete in Teams rather than individually! Your performance will be averaged with your teammate.'), () -> {
			GameClient.send("teamMode");
		}, (elapsed) -> {
			teamMode.alpha = GameClient.hasPerms() ? 1 : 0.8;

			teamMode.checked = GameClient.room.state.teamMode;
		}, 0, 0, GameClient.room.state.teamMode));

		items.add(royalMode = new Option(OnlineLang.L('settings.oneLane', 'One Lane Mode'), OnlineLang.L('settings.oneLane.desc', 'Everybody plays on the same side!'), () -> {
			GameClient.send("royalMode");
		}, (elapsed) -> {
			royalMode.alpha = GameClient.hasPerms() ? 1 : 0.8;

			royalMode.checked = GameClient.room.state.royalMode;

			updateItems();
		}, 0, 0, GameClient.room.state.royalMode));
		
		items.add(royalModeDadSide = new Option(OnlineLang.L('settings.oneLaneOpp', 'One Lane Mode Opponent Side'), OnlineLang.L('settings.oneLaneOpp.desc', 'Everybody plays on opponent side when enabled.'), () -> {
			GameClient.send("royalModeDadSide");
		}, (elapsed) -> {
			royalModeDadSide.alpha = GameClient.hasPerms() ? 1 : 0.8;

			royalModeDadSide.checked = GameClient.room.state.royalModeDadSide;
		}, 0, 0, GameClient.room.state.royalModeDadSide));
		
		items.add(hideGF = new Option(OnlineLang.L('settings.hideGF', 'Hide Girlfriend'), OnlineLang.L('settings.hideGF.desc', 'Hides GF from the stage.'), () -> {
			GameClient.send("toggleGF");
		}, (elapsed) -> {
			hideGF.alpha = GameClient.hasPerms() ? 1 : 0.8;

			hideGF.checked = GameClient.room.state.hideGF;
		}, 0, 0, GameClient.room.state.hideGF));

		items.add(disableSkins = new Option(OnlineLang.L('settings.disableSkins', 'Disable Skins'), OnlineLang.L('settings.disableSkins.desc', 'Forbids players from using skins.'), () -> {
			GameClient.send("toggleSkins");
		}, (elapsed) -> {
			disableSkins.alpha = GameClient.hasPerms() ? 1 : 0.8;

			disableSkins.checked = GameClient.room.state.disableSkins;
		}, 0, 0, GameClient.room.state.disableSkins));

		var prevCond:Int = -1;
		items.add(winCondition = new Option(OnlineLang.L('settings.winCondition', 'Win Condition'), '...', () -> {
			GameClient.send("nextWinCondition");
		}, (elapsed) -> {
			if (GameClient.room.state.winCondition != prevCond) {
				switch (GameClient.room.state.winCondition) {
					case 0:
						winCondition.descText.text = OnlineLang.L('settings.win.accuracy', 'Side with the highest Accuracy wins!');
					case 1:
						winCondition.descText.text = OnlineLang.L('settings.win.score', 'Side with the highest Score wins!');
					case 2:
						winCondition.descText.text = OnlineLang.L('settings.win.misses', 'Side with the least Misses wins!');
					case 3:
						winCondition.descText.text = OnlineLang.L('settings.win.fp', 'Side with the most FP wins!');
					case 4:
						winCondition.descText.text = OnlineLang.L('settings.win.combo', 'Side with the highest Combo wins!');
				}
				winCondition.descText.text += OnlineLang.L('settings.win.clickToChange', ' (Click to Change)');
				winCondition.box.makeGraphic(Std.int(winCondition.descText.x - winCondition.x + winCondition.descText.width) + 10, Std.int(winCondition.height), 0x81000000);
			}

			prevCond = GameClient.room.state.winCondition;
		}, 0, 0, false, true));

		var prevPausePolicy:Int = -1;
		items.add(pausePolicy = new Option(OnlineLang.L('settings.pausePolicy', 'Pause Policy'), '...', () -> {
			GameClient.send("nextPauseMode");
		}, (elapsed) -> {
			pausePolicy.alpha = GameClient.hasPerms() ? 1 : 0.8;

			var policy:Int = Std.int(GameClient.room.state.pauseMode);
			if (policy != prevPausePolicy) {
				switch (policy) {
					case 0:
						pausePolicy.descText.text = OnlineLang.L('settings.pause.hostOnly', 'Only the host can pause; everyone else is paused too.');
					case 1:
						pausePolicy.descText.text = OnlineLang.L('settings.pause.everyone', 'When anyone pauses, everyone is paused.');
					case 2:
						pausePolicy.descText.text = OnlineLang.L('settings.pause.legacy', 'Pauses stay local to each player (old behaviour).');
					default:
						pausePolicy.descText.text = '...';
				}
				pausePolicy.descText.text += OnlineLang.L('settings.pause.clickToChange', ' (Click to Change)');
				pausePolicy.box.makeGraphic(Std.int(pausePolicy.descText.x - pausePolicy.x + pausePolicy.descText.width) + 10, Std.int(pausePolicy.height), 0x81000000);
			}

			prevPausePolicy = policy;
		}, 0, 0, false, true));

		items.add(modifers = new Option(OnlineLang.L('settings.modifiers', 'Game Modifiers'), OnlineLang.L('settings.modifiers.desc', 'Set your Gameplay Modifiers here!'), () -> {
			close();
			FlxG.state.openSubState(new GameplayChangersSubstate());
		}, null, 0, 0, false, true));

		items.add(stageSelect = new Option(OnlineLang.L('settings.selectStage', 'Select Stage'), OnlineLang.L('settings.selectStage.current', 'Currently Selected: ') + (GameClient.room.state.stageName == "" ? OnlineLang.L('settings.stage.default', '(default)') : GameClient.room.state.stageName), () -> {
			if (GameClient.hasPerms()) {
				close();
				FlxG.state.openSubState(new SelectStageSubstate());
			}
		}, (elapsed) -> {
			stageSelect.alpha = GameClient.hasPerms() ? 1 : 0.8;
		}, 0, 0, false, true));

		items.add(skinSelect = new Option(OnlineLang.L('settings.selectSkin', 'Select Skin'), OnlineLang.L('settings.selectSkin.desc', 'Select your Skin here!'), () -> {
			if (!GameClient.room.state.disableSkins) {
				LoadingState.loadAndSwitchState(new SkinsState());
			}
			else {
				Alert.alert(OnlineLang.L('settings.skinsDisabled', 'Skins are disabled!'));
			}
		}, null, 0, 0, false, true));

		items.add(gameOptions = new Option(OnlineLang.L('settings.gameOptions', 'Game Options'), OnlineLang.L('settings.gameOptions.desc', 'Open your Game Options here!'), () -> {
			LoadingState.loadAndSwitchState(new OptionsState());
			OptionsState.onPlayState = false;
			OptionsState.onOnlineRoom = true;
		}, null, 0, 0, false, true));

		// items.add(mods = new Option("Mods", "Check your installed Mods here!", () -> {
		// 	LoadingState.loadAndSwitchState(new ModsMenuState());
		// 	ModsMenuState.onOnlineRoom = true;
		// }, null, 0, 0, false, true));

		updateItems();

		add(items);

		// Added last: the pad camera must be registered after coolCam so it draws over the list.
		addPadCamera();

		GameClient.send("status", "In the Room Settings");
	}

	function updateItems() {
		var i = 0;

		function nextItem(item:Option) {
			item.y = items.y + 80 * i;
			item.ID = i++;
		}

		nextItem(publicRoom);
		nextItem(networkOnlyRoom);
		nextItem(anarchyMode);
		nextItem(allPlayersChoose);
		nextItem(swapSides);
		nextItem(teamMode);
		nextItem(royalMode);
		royalModeDadSide.visible = GameClient.room.state.royalMode;
		if (royalModeDadSide.visible) {
			nextItem(royalModeDadSide);
		}
		nextItem(hideGF);
		nextItem(disableSkins);
		nextItem(winCondition);
		nextItem(pausePolicy);
		nextItem(modifers);
		nextItem(stageSelect);
		nextItem(skinSelect);
		nextItem(gameOptions);
		// nextItem(mods);
		
		var lastItem = items.members[items.length - 1];
		var lastItemBound = lastItem.y + lastItem.height + 40 > FlxG.height ? lastItem.y + lastItem.height + 40 : FlxG.height;
		coolCam.setScrollBounds(FlxG.width, FlxG.width, 0, lastItemBound);
	}

	override function closeSubState() {
		super.closeSubState();

		GameClient.send("status", "In the Room Settings");
	}

	override function destroy() {
		super.destroy();

		for (cam in FlxG.cameras.list) {
			if (cam != null && cam.filters != null)
				cam.filters.remove(blurFilter);
		}
		FlxG.cameras.remove(coolCam);
	}

	/**
	 * Index of the row under the pointer, or -1. The list scrolls with coolCam.follow(), so the hit
	 * test runs in coolCam's world; OnlineNav handles groups and the camera scroll.
	 */
	function optionIndexUnderPointer():Int {
		for (option in items) {
			if (option != null && option.visible && OnlineNav.pointerOver(option, coolCam))
				return option.ID;
		}
		return -1;
	}
	override function update(elapsed) {
        if (controls.BACK #if android || FlxG.android.justReleased.BACK #end) {
            close();
			FlxG.mouse.visible = prevMouseVisibility;
        }

		if (!GameClient.isConnected()) {
			return;
		}

		super.update(elapsed);

		// UP/DOWN and the wheel move the selection with hold-to-repeat, so the pad/keyboard can be
		// held down instead of tapped once per row.
		var steps = nav.poll(controls.UI_UP, controls.UI_DOWN, elapsed) - FlxG.mouse.wheel;
		while (steps != 0) {
			var dir = steps > 0 ? 1 : -1;
			changeSelection(dir);
			steps -= dir;
		}

		// A tap that lands on the on-screen pad belongs to the pad (UP/DOWN/A/B), never to the row
		// drawn behind it.
		var padTap = OnlineNav.padBlocks(virtualPad);
		var pointerClick = FlxG.mouse.justPressed && !padTap;

		// Hover is recomputed every frame so the highlight matches what a click would hit; moving
		// the pointer never changes curSelectedID (that was the touch-hostile part).
		hoverIndex = padTap ? -1 : optionIndexUnderPointer();

		items.forEach((option) -> {
			if (GameClient.room == null || !option.visible)
				return;

			var isSelected = option.ID == curSelectedID;

			if (isSelected) {
				coolCam.follow(option, TOPDOWN, 0.1);
				option.text.alpha = 1;
			}
			else {
				// A hovered row is brightened just enough to show what a click would hit; only the
				// selected row keeps full opacity, so the two states stay tellable apart.
				option.text.alpha = option.ID == hoverIndex ? 0.9 : 0.7;
			}

			if (pointerClick && option.ID == hoverIndex) {
				// A click first moves the selection onto the row it hit, then runs it.
				changeSelection(option.ID - curSelectedID);
				option.onClick();
			}
			else if (isSelected && controls.ACCEPT) {
				option.onClick();
			}
		});
    }

	function changeSelection(diff:Int) {
		var count = items.length;
		if (count <= 0)
			return;

		// A modulo keeps the original wrap-around for the +/-1 keyboard steps and also lands on the
		// right row when a click jumps several entries at once.
		curSelectedID = (curSelectedID + diff % count + count) % count;
	}
}

class Option extends FlxSpriteGroup {
	public var box:FlxSprite;
	public var checkbox:FlxSprite;
	var check:FlxSprite;
	public var text:FlxText;
	public var descText:FlxText;
	public var onClick:Void->Void;
	var onUpdate:Float->Void;
	
	public var checked(default, set):Bool;
	function set_checked(value:Bool):Bool {
		if (value == checked)
			return value;

		if (value && check != null) {
			check.angle = 0;
			check.alpha = 1;
			check.scale.set(1.2, 1.2);
		}
		return checked = value;
	}

	var noCheckbox:Bool = false;

	public function new(title:String, description:String, onClick:Void->Void, onUpdate:Float->Void, x:Int, y:Int, isChecked:Bool, ?noCheckbox:Bool = false) {
        super(x, y);

		this.onClick = onClick;
		this.onUpdate = onUpdate;
		this.noCheckbox = noCheckbox;

		box = new FlxSprite();
        box.setPosition(-5, -5);
        add(box);

		if (!noCheckbox) {
			checkbox = new FlxSprite();
			checkbox.makeGraphic(50, 50, 0x50000000);
			FlxSpriteUtil.drawRect(checkbox, 0, 0, checkbox.width, checkbox.height, FlxColor.TRANSPARENT, {thickness: 5, color: FlxColor.WHITE});
			checkbox.updateHitbox();
			add(checkbox);

			check = new FlxSprite();
			check.loadGraphic(Paths.image('check'));
			check.alpha = isChecked ? 1 : 0;
			add(check);

			checked = isChecked;
			if (checked) {
				check.scale.set(1, 1);
			}
			else {
				check.alpha = 0;
				check.scale.set(0.01, 0.01);
			}
		}

		text = new FlxText(0, 0, 0, title);
		text.setFormat(OnlineLang.font(), 22, FlxColor.WHITE);
		text.x = checkbox != null ? checkbox.width + 10 : 10;
        //text.y = checkbox.height / 2 - text.height / 2;
        add(text);

		descText = new FlxText(0, 0, 0, description);
		descText.setFormat(OnlineLang.font(), 18, FlxColor.WHITE);
		descText.x = text.x;
		descText.y = text.height + 2;
		add(descText);

		box.makeGraphic(Std.int(width) + 10, Std.int(height) + 10, 0x81000000);
    }

    override function update(elapsed) {
        super.update(elapsed);

		if (!noCheckbox) {
			if (checked) {
				if (check.scale.x != 1 || check.scale.y != 1)
					check.scale.set(FlxMath.lerp(check.scale.x, 1, elapsed * 10), FlxMath.lerp(check.scale.y, 1, elapsed * 10));
			}
			else {
				if (check.alpha != 0) {
					check.alpha = FlxMath.lerp(check.alpha, 0, elapsed * 15);
					check.angle += elapsed * 800;
				}
				if (check.scale.x != 0.01 || check.scale.y != 0.01)
					check.scale.set(FlxMath.lerp(check.scale.x, 0.01, elapsed * 15), FlxMath.lerp(check.scale.y, 0.01, elapsed * 15));
			}
		}

		if (onUpdate != null)
			onUpdate(elapsed);

		descText.alpha = text.alpha;
		if (!noCheckbox)
			checkbox.alpha = text.alpha;
    }
}
