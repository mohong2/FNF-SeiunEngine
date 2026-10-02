package online.states;

import flixel.FlxObject;
import flixel.util.FlxSpriteUtil;
import online.network.Auth;
import online.states.OnlineOptionsState.InputOption;
import online.util.RowLayout;
import online.util.ServerList;

/**
 * The server list on a screen of its own, so nickname / skin / mod settings are not
 * interleaved with server management. Rows reuse the options screen's InputOption widget
 * (keyboard, wheel, mouse hitboxes); each field has a clickable button beside it, and ENTER
 * inside a field still submits. /api/config is probed for the latency column.
 */
class ServerListState extends MusicBeatState {
	var items:FlxTypedGroup<InputOption> = new FlxTypedGroup<InputOption>();
	var buttons:Array<ServerButton> = [];
	/** Buttons live in their own layer added after `items`, so a row box can never cover one. */
	var buttonLayer:FlxTypedGroup<ServerButton> = new FlxTypedGroup<ServerButton>();

	var camFollow:FlxObject;
	static var curSelected:Int = 0;
	var curOption:InputOption;

	var tip:FlxText;
	var tipBg:FlxSprite;

	/** Set from the /api/config probe when the selected server pins its own credential lifetime. */
	var serverTtlNote:String = '';

	var inputWait(default, set):Bool = false;
	function set_inputWait(value:Bool) {
		if (inputWait == value) return inputWait;
		inputWait = value;
		updateOptions();
		return inputWait;
	}

	override function create() {
		super.create();

		camera.follow(camFollow = new FlxObject(), TOPDOWN_TIGHT, 0.1);

		#if DISCORD_ALLOWED
		DiscordClient.changePresence("In the Menus", "Servers");
		#end

		var bg:FlxSprite = new FlxSprite().loadGraphic(Paths.image('menuDesat'));
		bg.color = 0xff2b2b2b;
		bg.updateHitbox();
		bg.screenCenter();
		bg.antialiasing = ClientPrefs.data.globalAntialiasing;
		bg.scrollFactor.set(0, 0);
		add(bg);

		var y:Float = 70;

		y = addSection(OnlineLang.L('options.servers', 'Servers'), y);

		var current = ServerList.selected();
		var currentLabel = OnlineLang.L('options.serverCurrent', 'Current: ')
			+ (current.name != '' ? current.name : current.address);
		var currentText = new FlxText(0, y, FlxG.width, currentLabel);
		currentText.setFormat(OnlineLang.font(), 20, FlxColor.YELLOW, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		add(currentText);
		y = currentText.y + currentText.height + 30;

		var i = 0;
		for (entry in ServerList.all()) {
			var row:InputOption;
			var id:String = entry.id;
			var label = (ServerList.selectedId() == id ? '> ' : '  ') + (entry.name != '' ? entry.name : entry.address);
			items.add(row = new InputOption(label, entryDesc(entry.address, entry.networkAddress, entry.lastPingMs), null, () -> connectTo(id)));
			row.y = y;
			row.screenCenter(X);
			row.ID = i++;
			y = row.y + row.height + 30;
		}

		y = addSection(OnlineLang.L('options.serverManage', 'Manage'), y);

		y = addActionRow(OnlineLang.L('options.serverAdd', 'Add Server'),
			OnlineLang.L('options.serverAdd.desc', 'Creates a new entry with the default address and selects it.'), i++, y, () -> {
				var created = ServerList.create(OnlineLang.L('options.serverNewName', 'New Server'), ServerList.DEFAULT_ADDRESS);
				ServerList.select(created.id);
				GameClient.applySelectedServer();
				FlxG.resetState();
			});

		y = addActionRow(OnlineLang.L('options.serverDelete', 'Delete This Server'),
			OnlineLang.L('options.serverDelete.desc', 'Removes the selected server from the list.'), i++, y, () -> {
				var removing:String = ServerList.selectedId();
				RequestSubstate.request(OnlineLang.L('options.serverDeleteConfirm', 'Remove this server from the list?'), '', _ -> {
					Auth.clear(removing);
					ServerList.remove(removing);
					GameClient.applySelectedServer();
					FlxG.resetState();
				}, null, true);
			});

		y = addActionRow(OnlineLang.L('options.serverMoveUp', 'Move Up'),
			OnlineLang.L('options.serverMoveUp.desc', 'Moves the selected server one slot up.'), i++, y, () -> {
				ServerList.move(ServerList.selectedId(), -1);
				FlxG.resetState();
			});

		y = addActionRow(OnlineLang.L('options.serverMoveDown', 'Move Down'),
			OnlineLang.L('options.serverMoveDown.desc', 'Moves the selected server one slot down.'), i++, y, () -> {
				ServerList.move(ServerList.selectedId(), 1);
				FlxG.resetState();
			});

		y = addSection(OnlineLang.L('options.serverEdit', 'Edit This Server'), y);

		var targetId:String = ServerList.selectedId();

		y = addFieldRow(OnlineLang.L('options.serverName', 'Server Name'),
			OnlineLang.L('options.serverName.desc', 'Shown in the list above. Leave empty to show the address.'),
			OnlineLang.L('options.placeholder.name', 'Name'), ServerList.selected().name, OnlineLang.L('options.serverSave', 'Save'),
			i++, y, (text) -> {
				ServerList.rename(targetId, text.trim(), ServerList.selected().note);
				FlxG.resetState();
			});

		y = addFieldRow(OnlineLang.L('options.server', 'Server Address'),
			OnlineLang.L('options.server.desc', 'The server that hosts game rooms.'),
			GameClient.getDefaultServer(), ServerList.selected().address, OnlineLang.L('options.serverConnect', 'Connect'),
			i++, y, (text) -> {
				var prepared = ServerList.normalizeAddress(text);
				var entry = ServerList.find(targetId);
				ServerList.setAddresses(targetId, prepared, entry != null ? entry.networkAddress : '');
				ServerList.select(targetId);
				GameClient.applySelectedServer();
				FlxG.resetState();
			});

		y = addFieldRow(OnlineLang.L('options.networkServer', 'Network Server Address'),
			OnlineLang.L('options.networkServer.desc', 'Chat, friends and leaderboards use this address.'),
			GameClient.getDefaultServer(), ServerList.selected().networkAddress, OnlineLang.L('options.serverSave', 'Save'),
			i++, y, (text) -> {
				var prepared = ServerList.normalizeAddress(text);
				var entry = ServerList.find(targetId);
				ServerList.setAddresses(targetId, entry != null ? entry.address : ServerList.DEFAULT_ADDRESS, prepared);
				GameClient.applySelectedServer();
				FlxG.resetState();
			});

		y = addSection(OnlineLang.L('options.credentials', 'Credentials'), y);

		y = addInfoRow(credentialLabel(), i++, y);

		y = addToggleRow(OnlineLang.L('options.remember', 'Remember This Login'),
			OnlineLang.L('options.remember.desc', 'Keeps this server\'s credential on disk so it survives a restart.'),
			Auth.remember(), i++, y, (value) -> Auth.setRemember(value));

		y = addToggleRow(OnlineLang.L('options.autoLogin', 'Log In Automatically'),
			OnlineLang.L('options.autoLogin.desc', 'Refreshes the saved credential on launch instead of asking for a code again.'),
			Auth.autoLogin(), i++, y, (value) -> {
				Auth.setAutoLogin(value);
				if (!value)
					Alert.alert(OnlineLang.L('options.autoLoginOff', 'Automatic login turned off; the next launch will ask you to log in again.'));
			});

		y = addFieldRow(OnlineLang.L('options.credLifetime', 'Credential Lifetime (minutes)'),
			OnlineLang.L('options.credLifetime.desc', 'How long this server\'s credential stays valid; 0 asks the server for its default. A server can pin its own value.'),
			'0', Std.string(Auth.ttlMinutes()), OnlineLang.L('options.serverSave', 'Save'),
			i++, y, (text) -> {
				var minutes:Int = 0;
				var parsed = Std.parseInt(text.trim());
				if (parsed != null && parsed > 0) minutes = parsed > 525600 ? 525600 : parsed;
				Auth.setTtlMinutes(minutes);
				Alert.alert(OnlineLang.L('options.credLifetimeSaved', 'Credential lifetime saved'), Std.string(Auth.ttlMinutes()));
			});

		y = addActionRow(OnlineLang.L('options.credClear', 'Clear Credentials for This Server'),
			OnlineLang.L('options.credClear.desc', 'Deletes the credential stored on disk for the selected server.'), i++, y, () -> {
				RequestSubstate.request(OnlineLang.L('options.credClearConfirm', 'Delete the saved credential for this server?'), '', _ -> {
					Auth.clear();
					Alert.alert(OnlineLang.L('options.credCleared', 'Saved credential deleted.'));
					FlxG.resetState();
				}, null, true);
			});

		add(items);
		// After the rows: buttons must draw on top of the row boxes they sit next to.
		add(buttonLayer);

		tip = new FlxText(0, 0, 0, OnlineLang.L('options.serverList.tip', 'Click a row to switch servers; edit a field and click the button next to it.'));
		tip.setFormat(OnlineLang.font(), 18, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		tip.scrollFactor.set(0, 0);
		tip.screenCenter(X);
		tip.y = FlxG.height - tip.height - 40;
		tip.alpha = 0.6;

		tipBg = new FlxSprite(tip.x - 5, tip.y - 5);
		tipBg.makeGraphic(Std.int(tip.width) + 10, Std.int(tip.height) + 10, 0x81000000);
		tipBg.scrollFactor.set(0, 0);
		add(tipBg);
		add(tip);

		changeSelection(0);
		probeAll();
	}

	// ------------------------------------------------------------------
	// Layout helpers
	// ------------------------------------------------------------------

	function addSection(title:String, y:Float):Float {
		var text = new FlxText(0, y, FlxG.width, title);
		text.setFormat(OnlineLang.font(), 25, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		add(text);
		return text.y + text.height + 40;
	}

	function entryDesc(address:String, networkAddress:String, lastPingMs:Int):String {
		var desc = address;
		if (networkAddress != '' && networkAddress != address)
			desc += ' | ' + OnlineLang.L('options.networkShort', 'net') + ': ' + networkAddress;
		return desc + ' | ' + OnlineLang.L('room.ping', 'Ping: ') + (lastPingMs >= 0 ? Std.string(lastPingMs) + 'ms' : '?');
	}

	/** Read-only status line: the credential of the currently selected server. */
	function credentialLabel():String {
		var label:String;
		var entry = Auth.current();
		if (entry == null || entry.id == null) {
			label = OnlineLang.L('options.credState', 'Status: ') + OnlineLang.L('options.credLoggedOut', 'not logged in');
		}
		else {
			var state = Auth.expired()
				? OnlineLang.L('options.credExpired', 'expired')
				: OnlineLang.L('options.credLoggedIn', 'logged in');
			label = OnlineLang.L('options.credAccount', 'Account: ') + (entry.accountName != '' ? entry.accountName : entry.id);
			label += ' | ' + state;
			var expiry = Auth.expiryLabel();
			if (expiry != '')
				label += ' | ' + OnlineLang.L('options.credExpires', 'expires: ') + expiry;
		}

		if (serverTtlNote != '')
			label += ' | ' + serverTtlNote;
		return label;
	}

	function addInfoRow(title:String, id:Int, y:Float):Float {
		var row:InputOption;
		items.add(row = new InputOption(title, OnlineLang.L('options.credState.desc', 'Credentials are stored per server.'), null, null));
		row.y = y;
		row.screenCenter(X);
		row.ID = id;
		return row.y + row.height + 30;
	}

	function addToggleRow(title:String, desc:String, checked:Bool, id:Int, y:Float, onChange:Bool->Void):Float {
		var row:InputOption;
		items.add(row = new InputOption(title, desc, checked));
		row.onClick = () -> {
			row.checked = !row.checked;
			onChange(row.checked);
		};
		row.y = y;
		row.screenCenter(X);
		row.ID = id;
		return row.y + row.height + 30;
	}

	function addActionRow(title:String, desc:String, id:Int, y:Float, action:Void->Void):Float {
		var row:InputOption;
		items.add(row = new InputOption(title, desc, null, action));
		row.y = y;
		row.screenCenter(X);
		row.ID = id;
		return row.y + row.height + 30;
	}

	/**
	 * A labelled field, its input box, and a clickable button right of that box. ENTER inside the
	 * field and a click on the button run the same submit.
	 */
	function addFieldRow(title:String, desc:String, placeholder:String, value:String, buttonLabel:String, id:Int, y:Float, onButton:String->Void):Float {
		var row:InputOption;
		items.add(row = new InputOption(title, desc, [placeholder], null, (text, _) -> onButton(text), null));
		row.inputs[0].text = value;
		row.y = y;
		row.screenCenter(X);
		row.ID = id;

		var bg = row.inputBgs[0];
		var button = new ServerButton(buttonLabel, () -> onButton(row.inputs[0].text));
		// FlxSpriteGroup children hold absolute coordinates (add()/set_x push the group offset into
		// them), so bg.x/bg.y already contain row.x/row.y -- adding row.x here doubled the offset
		// and put the button past the right edge of the screen. RowLayout owns the clamp so the
		// layout probe can run it instead of restating it (tools/online_probe/LayoutProbe.hx).
		button.setPosition(RowLayout.buttonX(bg.x, bg.width, button.width, FlxG.width),
			RowLayout.buttonY(bg.y, bg.height, button.height));
		buttons.push(button);
		buttonLayer.add(button);

		return row.y + row.height + 40;
	}

	// ------------------------------------------------------------------
	// Latency probe
	// ------------------------------------------------------------------

	/** At most this many entries are probed per visit; a dead server costs a 5 s socket timeout. */
	static inline var PROBE_LIMIT:Int = 8;

	function probeAll():Void {
		var probed = 0;
		for (entry in ServerList.all()) {
			if (probed++ >= PROBE_LIMIT)
				break;
			probeEntry(entry.id, entry.address);
		}
	}

	function probeEntry(id:String, address:String):Void {
		var self = this;
		GameClient.probeServer(address, (result) -> {
			if (result != null && result.ok)
				ServerList.markResult(id, result.pingMs, true);
			if (!self.exists)
				return;
			if (id == ServerList.selectedId())
				self.serverTtlNote = pinnedTtlNote(result != null ? result.config : null);
			self.refreshDescriptions();
		});
	}

	/**
	 * A server can pin the credential lifetime (`auth.ttlLocked` in /api/config); say so next to
	 * the status line, because the lifetime field below is ignored in that case.
	 */
	function pinnedTtlNote(config:Dynamic):String {
		if (config == null || !Reflect.hasField(config, 'auth') || config.auth == null)
			return '';
		var auth:Dynamic = config.auth;
		if (!Reflect.hasField(auth, 'ttlLocked') || auth.ttlLocked != true)
			return '';
		var minutes = Reflect.hasField(auth, 'ttlMinutes') ? Std.string(auth.ttlMinutes) : '0';
		return OnlineLang.L('options.credServerPinned', 'Server pins the lifetime: ') + minutes + OnlineLang.L('options.credMinutes', ' min');
	}

	function refreshDescriptions():Void {
		var i = 0;
		for (entry in ServerList.all()) {
			if (i >= items.length)
				break;
			var row = items.members[i];
			if (row != null && row.descText != null)
				row.descText.text = entryDesc(entry.address, entry.networkAddress, entry.lastPingMs);
			i++;
		}
	}

	// ------------------------------------------------------------------
	// Interaction
	// ------------------------------------------------------------------

	function connectTo(id:String):Void {
		if (!ServerList.select(id))
			return;
		GameClient.applySelectedServer();
		FlxG.resetState();
	}

	override function update(elapsed:Float) {
		// A confirmation dialog on top owns the pointer and the keys; without this the click that
		// closes it would also land on whatever row sits underneath.
		if (subState != null) {
			super.update(elapsed);
			return;
		}

		if (curOption != null)
			camFollow.setPosition(curOption.getMidpoint().x, curOption.getMidpoint().y);

		// Buttons own the click when the pointer is over one; rows keep their own hitboxes.
		var buttonHit = false;
		if (FlxG.mouse.justPressed) {
			for (button in buttons) {
				if (mouseOverButton(button)) {
					button.action();
					buttonHit = true;
					break;
				}
			}
		}
		for (button in buttons)
			button.hovered = mouseOverButton(button);

		if (!inputWait && !buttonHit) {
			if (controls.BACK #if android || FlxG.android.justReleased.BACK #end) {
				FlxG.sound.music.volume = 1;
				FlxG.switchState(new OnlineOptionsState());
				FlxG.sound.play(Paths.sound('cancelMenu'));
				return;
			}

			if (controls.UI_UP_P || FlxG.mouse.wheel == 1)
				changeSelection(-1);
			else if (controls.UI_DOWN_P || FlxG.mouse.wheel == -1)
				changeSelection(1);
			else if ((FlxG.mouse.deltaX != 0 || FlxG.mouse.deltaY != 0) || FlxG.mouse.justPressed) {
				if (FlxG.mouse.justPressed)
					curSelected = -1;
				var index = 0;
				for (item in items) {
					if (FlxG.mouse.overlaps(item, camera))
						curSelected = index;
					index++;
				}
				updateOptions();
			}
		}

		super.update(elapsed);

		// Clicking a field's input box moves focus there (same rule as the options screen).
		if (FlxG.mouse.justPressed && curOption != null && curOption.isInput) {
			var target:Int = -1;
			for (i => input in curOption.inputs)
				if (mouseOverInputBg(curOption.inputBgs[i]))
					target = i;
			setInputFocus(curOption, target);
		}

		if (!inputWait && !buttonHit) {
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
		for (item in items) {
			// Haxe 4.2.5 has no safe-navigation; check item/inputs explicitly.
			if (item == null || item.inputs == null)
				continue;
			for (i in 0...item.inputs.length)
				if (item.inputs[i].hasFocus) {
					curSelected = item.ID;
					inputWait = true;
				}
		}
	}

	/** Same camera-space comparison as mouseOverInputBg: both sides in the state camera's world. */
	function mouseOverButton(button:ServerButton):Bool {
		if (button == null || camera == null)
			return false;

		var point = FlxG.mouse.getWorldPosition(camera);
		var hit:Bool = button.overlapsPoint(point, false);
		point.put();
		return hit;
	}

	function mouseOverInputBg(bg:FlxSprite):Bool {
		if (bg == null || camera == null)
			return false;

		var point = FlxG.mouse.getWorldPosition(camera);
		var hit:Bool = bg.overlapsPoint(point, false);
		point.put();
		return hit;
	}

	function setInputFocus(option:InputOption, index:Int):Void {
		if (option == null || option.inputs == null)
			return;

		// Order matters: unfocus everything first, then focus the target (see OnlineOptionsState).
		for (i in 0...option.inputs.length)
			if (i != index)
				option.inputs[i].hasFocus = false;

		if (index >= 0 && index < option.inputs.length)
			option.inputs[index].hasFocus = true;
	}

	function changeSelection(diff:Int):Void {
		curSelected += diff;

		if (curSelected >= items.length)
			curSelected = 0;
		else if (curSelected < 0)
			curSelected = items.length - 1;

		updateOptions();
	}

	function updateOptions():Void {
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
}

/** A clickable label + box, used for the actions that used to need ENTER inside a field. */
class ServerButton extends FlxSpriteGroup {
	public var action:Void->Void;
	public var hovered:Bool = false;

	var bg:FlxSprite;
	var label:FlxText;

	public function new(text:String, action:Void->Void, width:Int = RowLayout.BUTTON_WIDTH, height:Int = RowLayout.BUTTON_HEIGHT) {
		super();

		this.action = action;

		bg = new FlxSprite();
		bg.makeGraphic(width, height, 0x8C000000);
		FlxSpriteUtil.drawRect(bg, 0, 0, width, height, FlxColor.TRANSPARENT, {thickness: 3, color: 0x64FFFFFF});
		add(bg);

		label = new FlxText(0, 0, width, text);
		label.setFormat(OnlineLang.font(), 18, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		label.y = height / 2 - label.height / 2;
		add(label);
	}

	override function update(elapsed:Float) {
		super.update(elapsed);

		bg.alpha = hovered ? 1 : 0.7;
		label.alpha = hovered ? 1 : 0.85;
	}
}
