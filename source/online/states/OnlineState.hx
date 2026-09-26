package online.states;

// The whole state is an online-port addition and nothing outside #if ONLINE_ALLOWED ever
// instantiates it (MainMenuState.hx:500, PlayState.hx, online/*), so the file itself lives behind
// the guard: with the macro off this class does not exist, exactly like the rest of source/online.
#if ONLINE_ALLOWED
import WeekData;
import Highscore;
import Song;
import haxe.io.Path;
import shaders.WarpShader;
import online.network.FunkinNetwork;
import states.FreeplayState;
import lime.system.Clipboard;
import haxe.Json;
import states.MainMenuState;
import openfl.events.KeyboardEvent;
import flixel.addons.text.FlxTextField;

#if lumod
@:build(lumod.LuaScriptClass.build())
#end
class OnlineState extends MusicBeatState {
	var items:FlxTypedSpriteGroup<FlxText>;

	// Display names come from OnlineLang.menuName(); these strings stay English because the
	// switches below match on them. New entries go at the end so existing indices keep meaning.
	var itms:Array<String> = [
        "JOIN",
        "HOST",
        "FIND",
		"OPTIONS",
		"LEADERBOARD",
		"MOD DOWNLOADER"
    ];

	var presenceInfo:FlxText;
	// var networkBg:FlxSprite;
	var itemDesc:FlxText;
	var playersOnline:FlxText;
	var itemHeight:Float = 40;
	static inline var MENU_ROW_GAP:Float = 4;

	static var curSelected = 0;

	var inputWait = false;
	var inputString(get, set):String;
	function get_inputString():String {
		switch (curSelected) {
			case 0:
				return daCoomCode;
		}
		return null;
	}
	function set_inputString(v) {
		switch (curSelected) {
			case 0:
				return daCoomCode = v;
		}
		return null;
	}

	public static var inviteRoomID:String;

	var daCoomCode:String = "";
	var disableInput = false;


	var selectLine:FlxSprite;
	var descBox:FlxSprite;
	
	var github:FlxSprite;

    function onRoomJoin(err:Dynamic) {
		trace(err);
		if (err != null) {
			disableInput = false;
			return;
		}

		Waiter.putPersist(() -> {
			FlxG.switchState(new RoomState());
		});
    }

	function getItemName(item:String) {
		if (curSelected == 0 && item == "JOIN" && inputWait)
		{
			return OnlineLang.L('menu.joinCode', 'JOIN CODE: ') + inputString;
		}
		return OnlineLang.menuName(item);
	}


    override function create() {
        super.create();

		if (FlxG.sound.music == null || !FlxG.sound.music.playing)
			states.TitleState.playFreakyMusic();

		if (online.GameClient.isConnected()) {
			disableInput = true;
			FlxG.switchState(new online.states.RoomState());
			return;
		}

		if (inviteRoomID != null) {
			disableInput = true;
			function onJoin(err:Dynamic) {
				Waiter.putPersist(() -> {
					FlxG.switchState(new OnlineState());
				});
			}
			GameClient.joinRoom(inviteRoomID, onJoin);
			inviteRoomID = null;
			return;
		}

		OnlineMods.checkMods();

		#if DISCORD_ALLOWED
		DiscordClient.resetClientID();
		DiscordClient.changePresence("In the Menus", "Online Menu");
		#end

        var bg:FlxSprite = new FlxSprite().loadGraphic(Paths.image('menuDesat'));
		bg.color = 0xff2b2b2b;
        bg.updateHitbox();
        bg.screenCenter();
        bg.antialiasing = ClientPrefs.data.globalAntialiasing;
        add(bg);
		
		var warp:FlxSprite = new FlxSprite();
		warp.makeGraphic(FlxG.width, FlxG.height, FlxColor.TRANSPARENT);
		warp.updateHitbox();
		warp.screenCenter();
		if (!ClientPrefs.data.lowQuality && ClientPrefs.data.shaders)
			add(new WarpEffect(warp));
		warp.antialiasing = ClientPrefs.data.globalAntialiasing;
		add(warp);

		var lines:FlxSprite = new FlxSprite().loadGraphic(Paths.image('coolLines'));
		lines.updateHitbox();
		lines.screenCenter();
		lines.antialiasing = ClientPrefs.data.globalAntialiasing;
		add(lines);

		selectLine = new FlxSprite();
		selectLine.makeGraphic(1, 1, FlxColor.BLACK);
		selectLine.alpha = 0.3;
		add(selectLine);

		descBox = new FlxSprite(0, FlxG.height - 125);
		descBox.makeGraphic(1, 1, FlxColor.BLACK);
		descBox.alpha = 0.4;
		// makeGraphic puts the origin at the centre, so scaling expands both ways; move it to
		// the top-left so x/y + scale describe the box [x, x+w] × [y, y+h] around the text.
		descBox.origin.set(0, 0);
		add(descBox);

        items = new FlxTypedSpriteGroup<FlxText>();
        var i = 0;
        for (itm in itms) {
			var text = new FlxText(0, 0, 0, getItemName(itm));
            text.ID = i;
			text.alpha = inputWait ? 0.5 : 0.8;
			if (text.ID == curSelected) {
				text.text = "> " + text.text + " <";
				text.alpha = 1;
			}
			items.add(text);
			i++;
        }
		layoutMenuItems();
        add(items);

		github = new FlxSprite();
		github.antialiasing = ClientPrefs.data.globalAntialiasing;
		github.frames = Paths.getSparrowAtlas('online_github');
		github.animation.addByPrefix('idle', "idle", 24);
		github.animation.addByPrefix('active', "active", 24);
		github.animation.play('idle');
		github.updateHitbox();
		github.x = 30;
		github.y = FlxG.height - github.height - 28;
		github.alpha = 0.8;
		// Previously inside an unofficial-build gate that hid every bottom-left icon on real
		// builds; the gate is gone and the icon is always added.
		add(github);

		itemDesc = new FlxText(0, FlxG.height - 170);
		itemDesc.setFormat(OnlineLang.font(), 25, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		itemDesc.screenCenter(X);
		add(itemDesc);

		playersOnline = new FlxText(0, 100);
		playersOnline.setFormat(OnlineLang.font(), 20, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		playersOnline.alpha = 0.7;
		playersOnline.text = OnlineLang.L('players.fetching', 'Fetching...');
		playersOnline.screenCenter(X);
		add(playersOnline);

		var availableRooms = new FlxText(0, 130);
		availableRooms.setFormat(OnlineLang.font(), 16, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		availableRooms.alpha = 0.6;
		availableRooms.screenCenter(X);
		add(availableRooms);

		var credit = new FlxText(0, 0, 0, 'SeiunEngine Online by mo_hong\nUI reference: Funkin-Psych-Online (Snirozu)');
		credit.setFormat(OnlineLang.font(), 16, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		credit.alpha = 0.3;
		credit.screenCenter(X);
		credit.y = FlxG.height - credit.height - 5;
		add(credit);

		// networkBg = new FlxSprite(20, 20);
		// networkBg.makeGraphic(1, 1, FlxColor.BLACK);
		// networkBg.alpha = 0.6;
		// add(networkBg);

		if (!FunkinNetwork.loggedIn) {
			presenceInfo = new FlxText(0, 30);
			presenceInfo.setFormat(OnlineLang.font(), 16, FlxColor.WHITE, RIGHT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
			presenceInfo.alpha = 0.1;
			presenceInfo.text = OnlineLang.L('presence.notLoggedIn', 'Not logged in!\n\nCheck OPTIONS to login!');
			presenceInfo.x = FlxG.width - presenceInfo.width - 30;
			add(presenceInfo);
			FlxTween.tween(presenceInfo, {alpha: 0.7}, 1, {ease: FlxEase.quadInOut, type: PINGPONG});
		}

		// networkBg.scale.set(networkPlayer.width + 20, networkPlayer.height + 20);
		// networkBg.updateHitbox();

		// // slide to the right
		// networkBg.x = FlxG.width - networkBg.width - 20;
		// networkPlayer.x = networkBg.x + 10;

		var frontMessage = new FlxText(0, 0, 500);
		frontMessage.setFormat(OnlineLang.font(), 16, FlxColor.WHITE, RIGHT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		frontMessage.alpha = 0.5;
		frontMessage.x = FlxG.width - frontMessage.fieldWidth - 50;
		add(frontMessage);

		final theus = this;
		Thread.run(() -> {
			FunkinNetwork.ping();

			if (FunkinNetwork.loggedIn)
				Waiter.put(() -> {
					if (FlxG.state != theus)
						return;

					var profileBox = new ProfileBox(FunkinNetwork.nickname, true);
					profileBox.setPosition(FlxG.width - profileBox.width - 20, 20);
					add(profileBox);
				});
		});

		Thread.run(() -> {
			var data = FunkinNetwork.fetchFront();
			Waiter.put(() -> {
				if (FlxG.state != theus)
					return;

				if (data == null) {
					playersOnline.text = OnlineLang.L('players.offline', 'NETWORK OFFLINE');
					presenceInfo.visible = false;
					// networkBg.visible = false;
				}
				else {
					playersOnline.text = OnlineLang.L('players.online', 'Players Online: ') + data.online;
					availableRooms.text = OnlineLang.L('rooms.available', 'Available Rooms: ') + data.rooms;
					frontMessage.text = data.sez;
					frontMessage.y = FlxG.height - frontMessage.height - 20;
				}

				playersOnline.screenCenter(X);
				availableRooms.screenCenter(X);
			});
		});

		changeSelection(0);

		FlxG.stage.addEventListener(KeyboardEvent.KEY_DOWN, onKeyDown);

		FlxG.mouse.visible = true;
		#if (TOUCH_CONTROLS || desktop)
		addVirtualPad(UP_DOWN, A_B);
		addPadCamera();
		#end
    }

	override function destroy() {
		super.destroy();

		FlxG.stage.removeEventListener(KeyboardEvent.KEY_DOWN, onKeyDown);
	}

    override function update(elapsed) {
        super.update(elapsed);

        if (disableInput) return;

		for (item in items) {
			item.text = getItemName(itms[item.ID]);
			item.alpha = inputWait ? 0.5 : 0.8;
			if (item.ID == curSelected) {
				item.text = "> " + item.text + " <";
				item.alpha = 1;
			}
			item.screenCenter(X);
		}

		var mouseInItems = FlxG.mouse.y > items.y && FlxG.mouse.y < items.y + items.members.length * itemHeight;

		if (FlxG.mouse.justPressed && inputWait) {
			if (!FlxG.mouse.overlaps(items.members[curSelected])) {
				inputWait = false;
				return;
			}
			enterInput();
			return;
		}

		if (FlxG.mouse.justPressedRight && inputWait && Clipboard.text != null) {
			inputString += Clipboard.text;
		}

		if (FlxG.mouse.justMoved && !inputWait && mouseInItems) {
			curSelected = Std.int((FlxG.mouse.y - (items.y)) / itemHeight);
			changeSelection(0);
		}

		if (!inputWait) {
			if (controls.UI_UP_P)
				changeSelection(-1);
			else if (controls.UI_DOWN_P)
				changeSelection(1);

			if (controls.ACCEPT || (FlxG.mouse.justPressed && mouseInItems)) {
				switch (itms[curSelected].toLowerCase()) {
					case "join":
						inputWait = true;
					case "find":
						disableInput = true;
						// FlxG.openURL(GameClient.serverAddress + "/rooms");
						FlxG.switchState(new FindRoomState());
					case "host":
						disableInput = true;
						GameClient.createRoom(GameClient.serverAddress, onRoomJoin);
					case "options":
						disableInput = true;
						FlxG.switchState(new OnlineOptionsState());
					case "leaderboard":
						openSubState(new TopPlayerSubstate());
					case "mod downloader":
						disableInput = true;
						FlxG.switchState(new DownloaderState());
				}
			}

			if (controls.BACK) {
				disableInput = true;

				FlxG.stage.removeEventListener(KeyboardEvent.KEY_DOWN, onKeyDown);
				FlxG.mouse.visible = false;

				FlxG.sound.play(Paths.sound('cancelMenu'));
				FlxG.switchState(new MainMenuState());
			}
			
			if (FlxG.keys.pressed.CONTROL && FlxG.keys.justPressed.V) {
				disableInput = true;
				GameClient.joinRoom(Clipboard.text, onRoomJoin);
			}

			if (FlxG.mouse.justPressed || FlxG.mouse.justMoved) {
				if (FlxG.mouse.overlaps(github)) {
					github.alpha = 1;
					github.animation.play("active");

					itemDesc.text = OnlineLang.L('desc.docs', 'Documentation, FAQ and the Source Code!');
					itemDesc.screenCenter(X);

					if (FlxG.mouse.justPressed) {
						RequestSubstate.requestURL('https://github.com/mohong2/FNF-SeiunEngine', true);
					}
				}
				else {
					github.alpha = 0.8;
					github.animation.play("idle");
				}

			}
		}
    }
	

	/**
	 * Places the menu rows inside the free block, shrinking the font until they fit.
	 *
	 * The old code offset row i by `prevText.height * i` and let screenCenter(Y) place the rest, so
	 * nothing tied the list to the block: with a ten-entry menu the last rows ran underneath the
	 * description box. Heights are only known after setFormat, hence the measure-then-extrapolate
	 * loop on the first row.
	 */
	function layoutMenuItems() {
		if (items.members.length == 0)
			return;

		var top = 155; // below the online-count / available-rooms lines
		var bottom = FlxG.height - 200; // above the description box
		var available = bottom - top;
		if (available < 1)
			available = 1;

		// The font has to shrink until the block fits; heights are only known after setFormat, so
		// measure the first row and extrapolate.
		var size = 40;
		var measured = 0.0;
		while (size > 18) {
			items.members[0].setFormat(OnlineLang.font(), size, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
			measured = items.members[0].height;
			if ((measured + MENU_ROW_GAP) * items.members.length <= available)
				break;
			size -= 2;
		}

		var fit = ListLayout.fitListRows(items.members.length, top, bottom, measured, MENU_ROW_GAP);
		itemHeight = fit.lineHeight;

		var y = 0.0;
		for (text in items.members) {
			text.setFormat(OnlineLang.font(), size, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
			text.alpha = text.ID == curSelected ? 1 : (inputWait ? 0.5 : 0.8);
			text.y = y;
			y += fit.lineHeight;
			text.screenCenter(X);
		}

		items.y = fit.firstY;
	}



	function changeSelection(diffe:Int) {
		curSelected += diffe;

		if (curSelected >= items.length) {
			curSelected = 0;
		}
		else if (curSelected < 0) {
			curSelected = items.length - 1;
		}

		switch (curSelected) {
			case 0:
				itemDesc.text = OnlineLang.L('desc.join', 'Join a room using a room code');
			case 1:
				itemDesc.text = OnlineLang.L('desc.host', 'Creates a room');
			case 2:
				itemDesc.text = OnlineLang.L('desc.find', 'Opens a list of all available public rooms');
			case 3:
				itemDesc.text = OnlineLang.L('desc.options', 'SeiunEngine Online options, configure stuff here!');
			case 4:
				itemDesc.text = OnlineLang.L('desc.leaderboard', 'The Funkin Points Leaderboard!');
			case 5:
				itemDesc.text = OnlineLang.L('desc.downloader', 'Download mods from Gamebanana here!');
		}
		itemDesc.screenCenter(X);

		// Use FlxText's actual height: font line heights differ, so the old "(lines + 2) * size"
		// estimate drifted. origin is (0,0) from create(), so x/y is the top-left; screenCenter(X)
		// is avoided because it centres the unscaled 1px width and shifts once scaled.
		descBox.scale.set(FlxG.width - 500, itemDesc.height + 20);
		descBox.x = (FlxG.width - descBox.scale.x) / 2;
		descBox.y = itemDesc.y - 10;
		
		selectLine.y = (items.y + itemHeight / 2) + (curSelected) * itemHeight;
		selectLine.scale.set(FlxG.width, itemHeight);
		selectLine.screenCenter(X);

		for (item in items) {
			item.text = getItemName(itms[item.ID]);
			item.alpha = inputWait ? 0.5 : 0.8;
			if (item.ID == curSelected) {
				item.text = "> " + item.text + " <";
				item.alpha = 1;
			}
			item.screenCenter(X);
		}
	}

    // some code from FlxInputText
	function onKeyDown(e:KeyboardEvent) {
		if (!inputWait) return;

		var key = e.keyCode;

		if (e.charCode == 0) { // non-printable characters crash String.fromCharCode
			return;
		}

		if (key == 46) { //delete
            return;
        }

		if (key == 8) { //bckspc
			inputString = inputString.substring(0, inputString.length - 1);
            return;
        }
		else if (key == 13) { //enter
			enterInput();
            return;
        }
		else if (key == 27) { //esc
			inputWait = false;
			tempDisableInput();
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
			inputString += newText;
		}
    }

	function enterInput() {
		inputWait = false;

		if (inputString.length >= 0) {
			switch (itms[curSelected].toLowerCase()) {
				case "join":
					disableInput = true;
					if (daCoomCode.toLowerCase() == "adachi") {
						FlxG.sound.playMusic(Paths.sound('cabbage'));
						var image = new FlxSprite().loadGraphic(Paths.image('unnamed_file_from_google'));
						image.setGraphicSize(FlxG.width, FlxG.height);
						image.updateHitbox();
						FreeplayState.destroyFreeplayVocals();
						add(image);
						return;
					}
					#if VIDEOS_ALLOWED
					else if (daCoomCode.toLowerCase() == "reddit") {
						FreeplayState.destroyFreeplayVocals();
						FlxG.sound.music.stop();

						var ass = new FlxSprite();
						ass.makeGraphic(FlxG.width, FlxG.height, FlxColor.BLACK);
						add(ass);
						
						var video = new hxcodec.flixel.FlxVideo();
						// `video.play(path)` is not available: this engine's FlxVideo extends hxvlc's
						// FlxInternalVideo, whose `play():Bool` takes no arguments. hxCodec 3.x's
						// `play(location, shouldLoop)` is installed only at runtime via Reflect.setField
						// (source/hxcodec/flixel/FlxVideo.hx:36), so use playMP4(...) at compile time.
						video.playMP4(Paths.video('enables'));
						video.onEndReached.add(function() {
							video.dispose();

							PlayState.redditMod = true;
							online.mods.OnlineMods.installMod(Path.join([Sys.getCwd(), "/assets/images/reddit.zip"]));

							WeekData.reloadWeekFiles(false);
							Mods.currentModDirectory = "reddit";
							Difficulty.list = ['Normal'];
							PlayState.storyDifficulty = 0;

							var songLowercase:String = Paths.formatToSongPath("Gold");
							PlayState.loadSong(Highscore.formatSong(songLowercase, PlayState.storyDifficulty), songLowercase);
							PlayState.isStoryMode = false;

							LoadingState.loadAndSwitchState(new PlayState());

							#if (MODS_ALLOWED && DISCORD_ALLOWED)
							DiscordClient.loadModRPC();
							#end
						}, true);
						return;
					}
					#end
					else if (daCoomCode.toLowerCase() == "tomar") {
						FlxG.sound.playMusic(Paths.sound('tomar'));
						var image = new FlxSprite().loadGraphic(Paths.image('tomar'));
						image.setGraphicSize(FlxG.width, FlxG.height);
						image.updateHitbox();
						FreeplayState.destroyFreeplayVocals();
						add(image);
						FlxG.sound.music.onComplete = () -> {
							remove(image);
							image.destroy();
							disableInput = false;
							states.TitleState.playFreakyMusic();
						};
						return;
					}
					else if (daCoomCode.toLowerCase() == "jackass" || daCoomCode.toLowerCase() == "mrbeansex") {
						FlxG.sound.play(Paths.sound('jackass')).pitch = FlxG.random.float(0.8, 1.4);
						disableInput = false;
						FlxG.sound.music.stop();
						FreeplayState.destroyFreeplayVocals();
						return;
					}
					// 3D easter-egg branch (not present):
					//   else if (daCoomCode.toLowerCase() == "3d") {
					//       FlxG.switchState(() -> new online.s3d.ScriptedState3D());
					//       return;
					//   }
					// The 3D branch is removed because `online/s3d/**` does not exist.
					GameClient.joinRoom(daCoomCode, onRoomJoin);
			}
		}

		tempDisableInput();
	}

    function tempDisableInput() {
		disableInput = true;
        new FlxTimer().start(0.1, (t) -> disableInput = false);
    }
}
#end