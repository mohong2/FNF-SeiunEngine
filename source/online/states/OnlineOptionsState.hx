package online.states;

import flixel.input.keyboard.FlxKey;
import InputFormatter; // declared in source/InputFormatter.hx
import online.network.Auth;
import lime.ui.FileDialog;
import flixel.util.FlxSpriteUtil;
import online.network.FunkinNetwork;
import flixel.FlxObject;
import lime.system.Clipboard;
import flixel.group.FlxGroup;
import openfl.events.KeyboardEvent;
import online.util.OnlineLang;
import online.util.ServerList;

class OnlineOptionsState extends MusicBeatState {
	var items:FlxTypedGroup<InputOption> = new FlxTypedGroup<InputOption>();
    static var curSelected:Int = 0;

	var camFollow:FlxObject;

	var scrollToRegister:Bool = false;
	
	public function new(?scrollToRegister:Bool = false) {
		super();

		this.scrollToRegister = scrollToRegister;
	}

    override function create() {
        super.create();

		camera.follow(camFollow = new FlxObject(), TOPDOWN_TIGHT, 0.1);

		#if DISCORD_ALLOWED
		DiscordClient.changePresence("In the Menus", "Online Options");
		#end

		var bg:FlxSprite = new FlxSprite().loadGraphic(Paths.image('menuDesat'));
		bg.color = 0xff2b2b2b;
		bg.updateHitbox();
		bg.screenCenter();
		bg.antialiasing = ClientPrefs.data.globalAntialiasing;
		bg.scrollFactor.set(0, 0);
		add(bg);

		var i = 0;

		var section = new FlxText(0, 0, FlxG.width, OnlineLang.L('options.general', 'General'));
		section.setFormat(OnlineLang.font(), 25, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		add(section);

		var nicknameOption:InputOption;
		items.add(nicknameOption = new InputOption(OnlineLang.L('options.nickname', 'Nickname'), OnlineLang.L('options.nickname.desc', 'Set your nickname here!'), ["Boyfriend"], (text, _) -> {
			curOption.inputs[0].text = curOption.inputs[0].text.trim().substr(0, 14);
			ClientPrefs.setNickname(curOption.inputs[0].text);
			ClientPrefs.saveSettings();
		}));
		nicknameOption.inputs[0].text = ClientPrefs.getNickname();
		nicknameOption.y = 70;
		nicknameOption.screenCenter(X);
		nicknameOption.ID = i++;

		// var titleOption:InputOption;
		// items.add(titleOption = new InputOption("Title", "This will be shown below your name! (Max 20 characters)", ClientPrefs.data.playerTitle, text -> {
		// 	curOption.input.text = curOption.input.text.trim().substr(0, 20);
		// 	ClientPrefs.data.playerTitle = curOption.input.text;
		// 	ClientPrefs.saveSettings();
		// }));
		// titleOption.input.text = ClientPrefs.data.playerTitle;
		// titleOption.y = serverOption.y + serverOption.height + 50;
		// titleOption.screenCenter(X);
		// titleOption.ID = i++;

		var skinsOption:InputOption;
		items.add(skinsOption = new InputOption(OnlineLang.L('options.skin', 'Skin'), OnlineLang.L('options.skin.desc', 'Choose your skin here!'), null, () -> {
			LoadingState.loadAndSwitchState(new SkinsState());
		}));
		skinsOption.y = nicknameOption.y + nicknameOption.height + 50;
		skinsOption.screenCenter(X);
		skinsOption.ID = i++;

		var modsOption:InputOption;
		items.add(modsOption = new InputOption(OnlineLang.L('options.setupMods', 'Setup Mods'), OnlineLang.L('options.setupMods.desc', "Set the URL's of your mods here!"), null, () -> {
			FlxG.switchState(new SetupModsState(Mods.getModDirectories(), true));
		}));
		modsOption.y = skinsOption.y + skinsOption.height + 50;
		modsOption.screenCenter(X);
		modsOption.ID = i++;

		// The server list lives on its own screen (ServerListState); this row only opens it, so
		// server management no longer sits between the skin / mod settings and the account.
		var serverListOption:InputOption;
		var currentServer = ServerList.selected();
		var currentServerLabel = currentServer.name != '' ? currentServer.name : currentServer.address;
		items.add(serverListOption = new InputOption(OnlineLang.L('options.servers', 'Servers'),
			OnlineLang.L('options.servers.desc', 'Pick, add or edit the servers you connect to.') + '\n'
				+ OnlineLang.L('options.serverCurrent', 'Current: ') + currentServerLabel,
			null, () -> FlxG.switchState(new ServerListState())));
		serverListOption.y = modsOption.y + modsOption.height + 50;
		serverListOption.screenCenter(X);
		serverListOption.ID = i++;

		var trustedOption:InputOption;
		items.add(trustedOption = new InputOption(OnlineLang.L('options.clearTrusted', 'Clear Trusted Domains'), OnlineLang.L('options.clearTrusted.desc', 'Clear the list of all trusted domains!'), null, () -> {
			ClientPrefs.data.trustedSources = ["https://gamebanana.com/"];
			ClientPrefs.saveSettings();
			Alert.alert(OnlineLang.L('options.trustedCleared', 'Cleared the trusted domains list!'), "");
		}));
		trustedOption.y = serverListOption.y + serverListOption.height + 50;
		trustedOption.screenCenter(X);
		trustedOption.ID = i++;

		var lastOption:InputOption;
		var recentOption:InputOption;
		items.add(recentOption = new InputOption(OnlineLang.L('options.sslVerify', 'Enable SSL Verification'), OnlineLang.L('options.sslVerify.desc', "If checked, the game will check for valid SSL Certifications, which can lead to safer connections with downloads or rooms.\n(But It's not recommended because of Haxe's flawed sockets implementation.)"), 
		ClientPrefs.data.verifySSL,
		() -> {
			recentOption.checked = !recentOption.checked;
			ClientPrefs.data.verifySSL = recentOption.checked;
			ClientPrefs.saveSettings();
			sys.ssl.Socket.DEFAULT_VERIFY_CERT = ClientPrefs.data.verifySSL;
		}));
		recentOption.y = trustedOption.y + trustedOption.height + 50;
		recentOption.screenCenter(X);
		recentOption.ID = i++;
		// Online score HUD form. Unchecked (default) keeps the compact one-liner; checked
		// restores the multi-line block.
		var scoreHudOption:InputOption;
		items.add(scoreHudOption = new InputOption(OnlineLang.L('options.scoreDetails', 'Detailed Score HUD'), OnlineLang.L('options.scoreDetails.desc', 'If checked, online score texts show every value on its own line.\nUnchecked keeps them on one compact line.'), ClientPrefs.data.onlineScoreDetails, () -> {
			scoreHudOption.checked = !scoreHudOption.checked;
			ClientPrefs.data.onlineScoreDetails = scoreHudOption.checked;
			ClientPrefs.saveSettings();
		}));
		scoreHudOption.y = recentOption.y + recentOption.height + 50;
		scoreHudOption.screenCenter(X);
		scoreHudOption.ID = i++;

		if (Auth.authID == null && Auth.authToken == null) {
			var section = new FlxText(0, scoreHudOption.y + scoreHudOption.height + 50, FlxG.width, OnlineLang.L('options.account', 'Account'));
			section.setFormat(OnlineLang.font(), 25, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
			add(section);

			var registerOption:InputOption;
			items.add(registerOption = new InputOption(OnlineLang.L('options.register', 'Register to the Network'),
			OnlineLang.L('options.register.desc', 'Join the SeiunEngine Online Network and submit your song replays\nto the leaderboards!'), [OnlineLang.L('options.placeholder.username', 'Username'), OnlineLang.L('options.placeholder.email', 'Email')], (text, input) -> {
				try {
					if (input == 0) {
						registerOption.inputs[0].hasFocus = false;
						registerOption.inputs[1].hasFocus = true;
						inputWait = true;
						return;
					}

					registerOption.inputs[0].text = registerOption.inputs[0].text.trim();
					registerOption.inputs[1].text = registerOption.inputs[1].text.trim();

					if (registerOption.inputs[0].text.length <= 0) {
						Alert.alert(OnlineLang.L('options.noUsername', 'No username set!'));
						return;
					}

					if (registerOption.inputs[1].text.length <= 0) {
						registerOption.inputs[0].hasFocus = false;
						registerOption.inputs[1].hasFocus = true;
						inputWait = true;
						return;
					}

					if (FunkinNetwork.requestRegister(registerOption.inputs[0].text, registerOption.inputs[1].text)) {
						openSubState(new VerifyCodeSubstate(code -> {
							if (FunkinNetwork.requestRegister(registerOption.inputs[0].text, registerOption.inputs[1].text, code)) {
								Alert.alert(OnlineLang.L('options.registered', 'Successfully registered!'), OnlineLang.L('options.registered.desc', 'New features have appeared in the sidebar!\nPress ') + InputFormatter.getKeyName(cast(ClientPrefs.keyBinds.get('sidebar')[0], FlxKey)) + " to open it!");
								FlxG.resetState();
							}
						}));
					}
				}
				catch (exc) {
					Alert.alert(OnlineLang.L('options.registerFailed', "Couldn't register!"), ShitUtil.prettyError(exc));
				}
			}));
			registerOption.y = section.y + 70;
			registerOption.screenCenter(X);
			registerOption.ID = i++;
			if (scrollToRegister) {
				curSelected = registerOption.ID;
			}

			var loginOption:InputOption;
			items.add(loginOption = new InputOption(OnlineLang.L('options.login', 'Login to the Network'),
			OnlineLang.L('options.login.desc', 'Input your email address here and wait for your One-Time Login Code!'), [OnlineLang.L('options.placeholder.mail', 'me@example.org')], (mail, _) -> {
				try {
					if (FunkinNetwork.requestLogin(mail)) {
						openSubState(new VerifyCodeSubstate(code -> {
							if (FunkinNetwork.requestLogin(mail, code)) {
								Alert.alert(OnlineLang.L('options.loggedIn', 'Successfully logged in!'), OnlineLang.L('options.registered.desc', 'New features have appeared in the sidebar!\nPress ') + InputFormatter.getKeyName(cast(ClientPrefs.keyBinds.get('sidebar')[0], FlxKey)) + " to open it!");
								FlxG.resetState();
							}
						}));
					}
				}
				catch (exc) {
					Alert.alert(OnlineLang.L('options.loginFailed', "Couldn't login!"), ShitUtil.prettyError(exc));
				}
			}));
			loginOption.y = registerOption.y + registerOption.height + 50;
			loginOption.screenCenter(X);
			loginOption.ID = i++;
		}
		else {
			lastOption = scoreHudOption;
			var recentOption:InputOption;
			items.add(recentOption = new InputOption(OnlineLang.L('options.chatNotify', 'Network Chat Notifications'), 
			OnlineLang.L('options.chatNotify.desc', 'If checked, all messages from the Network Chat will be notified to you.\nCan be toggled with "/notify" Network command.'), 
			ClientPrefs.data.notifyOnChatMsg,
			() -> {
				recentOption.checked = !recentOption.checked;
				ClientPrefs.data.notifyOnChatMsg = recentOption.checked;
				ClientPrefs.saveSettings();
			}));
			recentOption.y = lastOption.y + lastOption.height + 50;
			recentOption.screenCenter(X);
			recentOption.ID = i++;

			lastOption = recentOption;
			var recentOption:InputOption;
			items.add(recentOption = new InputOption(OnlineLang.L('options.mutePM', 'Mute PM Notifications'),
				OnlineLang.L('options.mutePM.desc', 'If checked, PM notifications are muted.\nCan be toggled with "/notify pm" Network command.'),
				ClientPrefs.data.disablePMs, () -> {
					recentOption.checked = !recentOption.checked;
					ClientPrefs.data.disablePMs = recentOption.checked;
					ClientPrefs.saveSettings();
				}));
			recentOption.y = lastOption.y + lastOption.height + 50;
			recentOption.screenCenter(X);
			recentOption.ID = i++;

			lastOption = recentOption;
			var recentOption:InputOption;
			items.add(recentOption = new InputOption(OnlineLang.L('options.muteInvites', 'Mute Room Invites'),
				OnlineLang.L('options.muteInvites.desc', 'If checked, room invites are muted.\nCan be toggled with "/notify roominvite" Network command.'),
				ClientPrefs.data.disableRoomInvites, () -> {
					recentOption.checked = !recentOption.checked;
					ClientPrefs.data.disableRoomInvites = recentOption.checked;
					ClientPrefs.saveSettings();
				}));
			recentOption.y = lastOption.y + lastOption.height + 50;
			recentOption.screenCenter(X);
			recentOption.ID = i++;

			lastOption = recentOption;
			var recentOption:InputOption;
			items.add(recentOption = new InputOption(OnlineLang.L('options.friendOnline', 'Notify when Friend is Online'),
				OnlineLang.L('options.friendOnline.desc', "If checked, you'll receive a notification when your friend goes online.\nCan be toggled with \"/notify friend\" Network command."),
				ClientPrefs.data.friendOnlineNotification, () -> {
					recentOption.checked = !recentOption.checked;
					ClientPrefs.data.friendOnlineNotification = recentOption.checked;
					ClientPrefs.saveSettings();
				}));
			recentOption.y = lastOption.y + lastOption.height + 50;
			recentOption.screenCenter(X);
			recentOption.ID = i++;

			var sezOption:InputOption;
			items.add(sezOption = new InputOption(OnlineLang.L('options.globalMessage', 'Leave a Global Message'), OnlineLang.L('options.globalMessage.desc', 'Leave a message for others to see in the Online Menu!\n(Please keep it English)'), [OnlineLang.L('options.placeholder.message', 'Message')],
				(message, _) -> {
					if (FunkinNetwork.postFrontMessage(message))
						FlxG.switchState(new OnlineState());
				}));
			sezOption.y = recentOption.y + recentOption.height + 50;
			sezOption.screenCenter(X);
			sezOption.ID = i++;

			// No "Open Sidebar" InputOption is added here: the sidebar subsystem is absent, so
			// the entry and its callback would be dead code. Layout still works because each
			// option's y derives from the previous option's y, not from a fixed index, so no
			// placeholder is needed.

			var section = new FlxText(0, sezOption.y + sezOption.height + 50, FlxG.width, OnlineLang.L('options.account', 'Account'));
			section.setFormat(OnlineLang.font(), 25, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
			add(section);

			var loginBrowserOption:InputOption;
			items.add(loginBrowserOption = new InputOption(OnlineLang.L('options.loginBrowser', 'Login to Browser'), OnlineLang.L('options.loginBrowser.desc', 'Authenticates you to the network in your default web browser'), null, () -> {
#if ONLINE_ALLOWED
				// The handler can be null when the network address cannot be resolved (offline box);
				// getURL() on null is a native null dereference on cpp.
				if (FunkinNetwork.client != null)
					FlxG.openURL(FunkinNetwork.client.getURL("/api/auth/cookie?id=" + Auth.authID + "&token=" + Auth.authToken));
#end
			}));
			loginBrowserOption.y = section.y + 70;
			loginBrowserOption.screenCenter(X);
			loginBrowserOption.ID = i++;

			var emailOption:InputOption;
			items.add(emailOption = new InputOption(OnlineLang.L('options.changeEmail', 'Change Email Address'),
				OnlineLang.L('options.changeEmail.desc', 'Use the following format:\n<new_mail> from <old_mail>'), [OnlineLang.L('options.placeholder.mailChange', 'new@example.org from old@example.org')], (mail, _) -> {
					if (FunkinNetwork.setEmail(mail)) {
						openSubState(new VerifyCodeSubstate(code -> {
							if (FunkinNetwork.setEmail(mail, code)) {
								Alert.alert(OnlineLang.L('options.emailChanged', 'Email Successfully Added!'));
							}
						}));
					}
				}));
			emailOption.y = loginBrowserOption.y + loginBrowserOption.height + 50;
			emailOption.screenCenter(X);
			emailOption.ID = i++;
			
			var deleteOption:InputOption;
			items.add(deleteOption = new InputOption(OnlineLang.L('options.deleteAccount', 'Delete Network Account'), OnlineLang.L('options.deleteAccount.desc', 'Bye!'), null, () -> {
				RequestSubstate.request(OnlineLang.L('options.deleteConfirm', 'Are you sure you want to delete your account?\n(This action is irreversible!)'), '', _ -> {
					if (FunkinNetwork.deleteAccount()) {
						openSubState(new VerifyCodeSubstate(code -> {
							if (FunkinNetwork.deleteAccount(code)) {
								Alert.alert(OnlineLang.L('options.accountDeleted', 'Account Deleted'));
							}
						}));
					}
				}, null, true);
			}));
			deleteOption.y = emailOption.y + emailOption.height + 50;
			deleteOption.screenCenter(X);
			deleteOption.ID = i++;

			var logoutOption:InputOption;
			items.add(logoutOption = new InputOption(OnlineLang.L('options.logout', 'Logout of the Network'), OnlineLang.L('options.logout.desc', 'Logout of the SeiunEngine Online Network'), null, () -> {
				RequestSubstate.request(OnlineLang.L('options.logoutConfirm', 'Are you sure you want to logout?'), '', _ -> {
					FunkinNetwork.logout();
					FlxG.resetState();
				}, null, true);
			}));
			logoutOption.y = deleteOption.y + deleteOption.height + 50;
			logoutOption.screenCenter(X);
			logoutOption.ID = i++;
			if (scrollToRegister) {
				curSelected = logoutOption.ID;
			}
		}

		add(items);

        changeSelection(0);
    }

	var mouseMoveTimeout = 0.0;

    override function update(elapsed:Float) {
		if (curOption != null) {
			camFollow.setPosition(curOption.getMidpoint().x, curOption.getMidpoint().y);
		}

		if (mouseMoveTimeout > 0)
			mouseMoveTimeout -= elapsed;

		if (!inputWait) {
			if (controls.BACK #if android || FlxG.android.justReleased.BACK #end) {
				// Commit any pending onBlur input when leaving the screen.
				commitInputsOnExit();
				FlxG.sound.music.volume = 1;
				FlxG.switchState(new OnlineState());
				FlxG.sound.play(Paths.sound('cancelMenu'));
			}

			if (controls.UI_UP_P || FlxG.mouse.wheel == 1) {
				mouseMoveTimeout = 0.6;
				changeSelection(-1);
			}
			else if (controls.UI_DOWN_P || FlxG.mouse.wheel == -1) {
				mouseMoveTimeout = 0.6;
				changeSelection(1);
			}
			else if ((mouseMoveTimeout <= 0 && (FlxG.mouse.deltaX != 0 || FlxG.mouse.deltaY != 0)) || FlxG.mouse.justPressed) {
				if (FlxG.mouse.justPressed)
                	curSelected = -1;
                var i = 0;
                 for (item in items) {
                    if (FlxG.mouse.overlaps(item, camera)) {
                        curSelected = i;
                        break;
                    }
                    i++;
                }
                updateOptions();
            }
        }

		super.update(elapsed);

		// Input-box clicks must hit-test their own inputBg (700x50), not FlxInputText's
		// `mouseOverlapping()`: that uses FlxText's own height, and an empty input is only 4px
		// (FlxText.VERTICAL_GUTTER), so the middle of the visible field never hits. With one input
		// focused the `!inputWait` block is skipped, so switching boxes relied on this broken test.
		if (FlxG.mouse.justPressed && curOption != null && curOption.isInput) {
			var targetIndex:Int = -1;
			for (i => input in curOption.inputs)
				if (mouseOverInputBg(curOption.inputBgs[i]))
					targetIndex = i;

			setInputFocus(curOption, targetIndex);
		}

		if (!inputWait) {
			if ((controls.ACCEPT || FlxG.mouse.justPressed) && curOption != null) {
				if (curOption.isInput) {
					if (!FlxG.mouse.justPressed)
						setInputFocus(curOption, 0);
				}
				else if (curOption.onClick != null) {
					curOption.onClick();
				}
			}
		}

		inputWait = false;
		var focusedKey:Int = -1;
		for (item in items) {
			// Haxe 4.2.5 has no safe-navigation; `item?.inputs` is expanded to null checks.
			if (item == null || item.inputs == null)
				continue;

			for (i in 0...item.inputs.length) {
				if (item.inputs[i].hasFocus) {
					curSelected = item.ID;
					inputWait = true;
					focusedKey = item.ID * 100 + i;
				}
			}
		}

		// Submitting only on ENTER_ACTION would drop an address typed then abandoned by mouse click
		// or BACK was dropped. Detect which input lost focus this frame and re-submit options that
		// registered onBlur (the submit function de-duplicates).
		if (focusedInputKey != focusedKey) {
			var previousKey = focusedInputKey;
			focusedInputKey = focusedKey;
			notifyBlur(previousKey);
		}
    }

    var curOption:InputOption;

	/** `item.ID * 100 + inputIndex` of the input that had focus last frame, or -1 for none. */
	var focusedInputKey:Int = -1;

	function notifyBlur(key:Int):Void {
		if (key < 0)
			return;

		var itemIndex = Std.int(key / 100);
		var inputIndex = key % 100;
		if (itemIndex < 0 || itemIndex >= items.length)
			return;

		var item = items.members[itemIndex];
		if (item == null || item.onBlur == null || item.inputs == null)
			return;
		if (inputIndex < 0 || inputIndex >= item.inputs.length)
			return;

		item.onBlur(item.inputs[inputIndex].text, inputIndex);
	}

	/** BACK out of this state: commit every option that registered an `onBlur` hook once. */
	function commitInputsOnExit():Void {
		for (item in items) {
			if (item == null || item.onBlur == null || item.inputs == null)
				continue;

			for (i in 0...item.inputs.length)
				item.onBlur(item.inputs[i].text, i);
		}
	}

	/**
	 * Set focus on input `index` of `option` (`index < 0` = blur all).
	 * Clear every non-target first, then set the target true: FlxInputText's static `_hiddenTF`
	 * makes `disableIME()` detach stage focus without checking `_focusedInput == this`
	 * (FlxInputText.hx:950-962), so a later false steals an earlier true's input channel.
	 */
	function setInputFocus(option:InputOption, index:Int):Void {
		if (option == null || option.inputs == null)
			return;

		for (i in 0...option.inputs.length)
			if (i != index)
				option.inputs[i].hasFocus = false;

		if (index >= 0 && index < option.inputs.length)
			option.inputs[index].hasFocus = true;
	}

	/**
	 * Hit-test with `inputBg`'s own world coords. `FlxG.mouse.overlaps(obj, camera)` only
	 * cancels itself out when `camera == FlxG.camera` in flixel 4.11; explicit world coords
	 * match RoomState.mouseOverlapsItem(). The box must be the inputBg (700x50), not FlxText:
	 * an empty input is only 4px tall (see update()).
	 */
	function mouseOverInputBg(bg:FlxSprite):Bool {
		if (bg == null || camera == null)
			return false;

		var point = FlxG.mouse.getWorldPosition(camera);
		var hit:Bool = bg.overlapsPoint(point, false);
		point.put();
		return hit;
	}

    function changeSelection(diffe:Int) {
		curSelected += diffe;

		if (curSelected >= items.length) {
			curSelected = 0;
		}
		else if (curSelected < 0) {
			curSelected = items.length - 1;
		}

        updateOptions();
    }

    function updateOptions() {
        if (curSelected < 0 || curSelected >= items.length)
            curOption = null;
        else
            curOption = items.members[curSelected];

        for (item in items) {
			item.borderline.visible = item == curOption;
			item.alpha = inputWait ? 0.5 : 0.6;
			if (item.isInput)
				for (input in item.inputs)
					input.alpha = 0.5;
        }
        if (curOption != null) {
			curOption.alpha = 1;
			if (curOption.isInput)
				for (input in curOption.inputs)
					input.alpha = inputWait ? 1 : 0.7;
		}
    }

    var inputWait(default, set):Bool = false;
	function set_inputWait(value:Bool) {
		if (inputWait == value) return inputWait;
		inputWait = value;
		updateOptions();
		return inputWait;
	}
}

class InputOption extends FlxSpriteGroup {
	var box:FlxSprite;
	var checkbox:FlxSprite;
	var check:FlxSprite;
	public var checked(default, set):Bool = false;
	function set_checked(value:Bool):Bool {
		if (value == checked)
			return value;

		if (value && check != null) {
			check.alpha = 1;
			check.angle = 0;
			check.scale.set(1.2, 1.2);
		}
		return checked = value;
	}
	public var borderline:FlxSprite;
	public var text:FlxText;
	public var descText:FlxText;

	public var inputBgs:Array<FlxSprite> = [];
	var inputPhs:Array<FlxText> = [];
	public var inputs:Array<InputText> = [];

	public var id:String;
	public var isInput:Bool;
	public var isCheck:Bool;
	public var onEnter:(text:String, input:Int) -> Void;
	public var onClick:Void -> Void;
	// Called when an input loses focus without ENTER (mouse click elsewhere / BACK); without
	// this hook a typed-in address would be silently dropped.
	public var onBlur:(text:String, input:Int) -> Void;

	public function new(title:String, description:String, input:Dynamic, ?onClick:Void->Void, ?onEnter:(text:String, input:Int)->Void, ?onBlur:(text:String, input:Int)->Void) {
        super();

		id = title.toLowerCase();
		this.isInput = input is Array;
		this.isCheck = input is Bool;
		checked = isCheck && input;
		this.onClick = onClick;
		this.onBlur = onBlur;

		box = new FlxSprite();
		box.setPosition(-5, -10);
		add(box);

		text = new FlxText(0, 0, 0, title);
		text.setFormat(OnlineLang.font(), 22, FlxColor.WHITE);
		text.x = 10;
		add(text);

		descText = new FlxText(0, 0, 0, description);
		descText.setFormat(OnlineLang.font(), 18, FlxColor.WHITE);
		descText.fieldWidth = Math.min(700, descText.fieldWidth);
		descText.x = text.x;
		descText.y = text.height + 5;
		add(descText);

		if (isInput) {
			for (i => placeholder in cast (input, Array<Dynamic>)) {
				var inputBg = new FlxSprite();
				inputBg.makeGraphic(700, 50, FlxColor.BLACK);
				inputBg.x = text.x;
				inputBg.y = descText.y + descText.textField.textHeight + 10;
				inputBg.alpha = 0.6;
				add(inputBg);

				var inputPlaceholder = new FlxText();
				inputPlaceholder.text = placeholder;
				inputPlaceholder.setFormat(OnlineLang.font(), 20, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
				inputPlaceholder.alpha = 0.5;
				inputPlaceholder.x = inputBg.x + 20;
				inputPlaceholder.y = inputBg.y + inputBg.height / 2 - inputPlaceholder.height / 2;
				add(inputPlaceholder);

				var input = new InputText(0, 0, inputBg.width - 20, (text) -> onEnter(text, i));
				input.setFormat(OnlineLang.font(), 20, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
				input.setPosition(inputPlaceholder.x, inputPlaceholder.y);
				add(input);

				inputBg.y += i * 50;
				inputPlaceholder.y += i * 50;
				input.y += i * 50;

				inputBgs.push(inputBg);
				inputPhs.push(inputPlaceholder);
				inputs.push(input);
			}
		}

		var width = Std.int(width) + 10;
		if (width < 600) {
			width = 600;
		}

		if (isCheck) {
			checkbox = new FlxSprite(0, 5);
			checkbox.makeGraphic(50, 50, 0x50000000);
			FlxSpriteUtil.drawRect(checkbox, 0, 0, checkbox.width, checkbox.height, FlxColor.TRANSPARENT, {thickness: 5, color: FlxColor.WHITE});
			checkbox.updateHitbox();
			checkbox.x = width - checkbox.width - 10;
			add(checkbox);

			check = new FlxSprite(checkbox.x, checkbox.y);
			check.loadGraphic(Paths.image('check'));
			check.alpha = checked ? 1 : 0;
			add(check);

			descText.fieldWidth = checkbox.x - 30;

			if (checked) {
				check.scale.set(1, 1);
			}
			else {
				check.alpha = 0;
				check.scale.set(0.01, 0.01);
			}
		}

		// try to reuse existing bitmaps
		box.makeGraphic(1, 1, 0x81000000);
		box.scale.set(Std.int(width) + 10, Std.int(height) + 20);
		box.updateHitbox();

		borderline = new FlxSprite(box.x, box.y);
		borderline.makeGraphic(Std.int(box.width), Std.int(box.height), FlxColor.TRANSPARENT);
		FlxSpriteUtil.drawRect(borderline, 0, 0, borderline.width, borderline.height, FlxColor.TRANSPARENT, {thickness: 6, color: 0x34FFFFFF});
		borderline.visible = false;
		add(borderline);
    }

	//var targetScale:Float = 1;
	override function update(elapsed) {
		super.update(elapsed);

		if (isInput)
			for (i => input in inputs)
				inputPhs[i].visible = input.text == "";

		if (check != null) {
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

		//targetScale = alpha == 1 ? 1.02 : 1;
		//scale.set(FlxMath.lerp(scale.x, targetScale, elapsed * 10), FlxMath.lerp(scale.y, targetScale, elapsed * 10));
	}
}