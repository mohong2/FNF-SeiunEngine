package online.states;

import flixel.FlxObject;
import flixel.util.FlxSpriteUtil;
import online.GameClient.ServerProbe;
import online.Protocol;
import online.network.Auth;
import online.gui.LoadingScreen;
import online.states.OnlineOptionsState.InputOption;
// Module-level typedef: the package wildcard in import.hx exposes the class, not this.
import online.util.LanDiscovery.LanServer;
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

	/** UP/DOWN hold-to-repeat, shared with the on-screen pad. */
	var nav = new NavRepeat();

	/** Hovered row, or null. Hover only lights the row up; it never selects it. */
	var hoveredOption:InputOption = null;

	var tip:FlxText;
	var tipBg:FlxSprite;

	/** Set from the /api/config probe when the selected server pins its own credential lifetime. */
	var serverTtlNote:String = '';

	/**
	 * Probe outcome per server id: 'checking' before it answers, then one of the reasons that matter
	 * to a LAN player -- 'reachable', 'timeout' (nothing listened) or 'wrongProtocol' (an HTTP server
	 * answered, but it is not SeiunEngine). The row text says which one, so "it does not work" turns
	 * into an actionable message.
	 */
	var probeStates:Map<String, String> = new Map();

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

		// On-screen controls: UP/DOWN move the selection, A accepts, B backs out. Mounted by every
		// online screen; a pad tap is ignored by the pointer hit tests below.
		addVirtualPad(UP_DOWN, A_B);
		// Online pad layout: shrunk buttons tucked into the corners, clear of the UI.
		OnlineNav.layoutColumn(virtualPad);
		addPadCamera();

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

		// Whatever the last search heard, listed for the player to choose from. Nothing is saved
		// here: the rows are pickers, and only "Add Selected Servers" writes into the server list.
		if (lanFound.length > 0) {
			y = addSection(OnlineLang.L('options.serverScan.section', 'Found on This Network'), y);

			for (server in lanFound) {
				var address:String = server.address;
				var label:String = server.name != '' ? server.name : address;

				if (hasAddress(address)) {
					y = addNoteRow(label, address + '  ' + OnlineLang.L('options.serverScan.found.already', 'Already in the list.'), i++, y);
				}
				else {
					// Copy per iteration: the closure must not capture the loop variable.
					var pickedAddress:String = address;
					y = addToggleRow(label, address, lanPicked.get(pickedAddress) == true, i++, y,
						(value) -> lanPicked.set(pickedAddress, value));
				}
			}

			y = addActionRow(OnlineLang.L('options.serverScan.add', 'Add Selected Servers'),
				OnlineLang.L('options.serverScan.add.desc', 'Adds every ticked server above to your server list.'), i++, y, () -> addPickedLanServers());

			y = addActionRow(OnlineLang.L('options.serverScan.clear', 'Clear These Results'),
				OnlineLang.L('options.serverScan.clear.desc', 'Hides the servers found by the last search.'), i++, y, () -> clearLanResults());
		}

		// Saved-server rows start here; refreshDescriptions() writes their latency / status line and
		// must not touch the pickers above.
		serverRowStart = items.length;

		for (entry in ServerList.all()) {
			var row:InputOption;
			var id:String = entry.id;
			var label = (ServerList.selectedId() == id ? '> ' : '  ') + (entry.name != '' ? entry.name : entry.address);
			items.add(row = new InputOption(label, entryDesc(entry), null, () -> connectTo(id)));
			row.y = y;
			row.screenCenter(X);
			row.ID = i++;
			y = row.y + row.height + 30;
		}

		y = addSection(OnlineLang.L('options.serverManage', 'Manage'), y);

		// Listen for the announcements a running host broadcasts (see online.util.LanDiscovery)
		// instead of asking the player for an IP. The results are only *listed*; see lanFound.
		y = addActionRow(OnlineLang.L('options.serverScan', 'Search for Servers on This Network'),
			OnlineLang.L('options.serverScan.desc', 'Listens for servers that announce themselves on this local network, then lists them for you to pick from.'),
			i++, y, () -> startLanScan());

		y = addActionRow(OnlineLang.L('options.serverAdd', 'Add Server'),
			OnlineLang.L('options.serverAdd.desc', 'Creates a new entry with the default address and selects it.'), i++, y, () -> {
				var created = ServerList.create(OnlineLang.L('options.serverNewName', 'New Server'), ServerList.DEFAULT_ADDRESS);
				ServerList.select(created.id);
				GameClient.applySelectedServer();
				FlxG.resetState();
			});

		// The "Use This PC (LAN)" rows that used to sit here are gone: they listed *every* IPv4 of
		// the machine (Ethernet, Wi-Fi, WSL/Hyper-V virtual adapters, ...) as its own clickable row,
		// and clicking one overwrote the address of whichever server was selected -- three rows of
		// clutter for an action that hijacked the entry being edited. The LAN address a host has to
		// hand out is shown, with click-to-copy, on the LAN Host screen instead.

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
			i++, y, (text) -> connectTo(targetId, text));

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
		// Centred along the bottom: that band is the free one, between the pad's left column and
		// its action buttons. Sitting "above the pad" pushed the hint into the middle of the screen.
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

	function entryDesc(entry:ServerEntry):String {
		var desc = entry.address;
		if (entry.networkAddress != '' && entry.networkAddress != entry.address)
			desc += ' | ' + OnlineLang.L('options.networkShort', 'net') + ': ' + entry.networkAddress;

		var state = probeStates.get(entry.id);
		if (state == 'reachable')
			desc += ' | ' + OnlineLang.L('options.serverProbeOk', 'reachable');
		else if (state == 'timeout')
			desc += ' | ' + OnlineLang.L('options.serverProbeTimeout', 'timeout');
		else if (state == 'wrongProtocol')
			desc += ' | ' + OnlineLang.L('options.serverProbeBadProtocol', 'not a SeiunEngine server');
		else if (state == 'checking')
			desc += ' | ' + OnlineLang.L('options.serverProbeChecking', 'checking...');

		return desc + ' | ' + OnlineLang.L('room.ping', 'Ping: ') + (entry.lastPingMs >= 0 ? Std.string(entry.lastPingMs) + 'ms' : '?');
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

	/** Read-only row that carries its own description (addInfoRow hardcodes one of its own). */
	function addNoteRow(title:String, desc:String, id:Int, y:Float):Float {
		var row:InputOption;
		items.add(row = new InputOption(title, desc, null, null));
		row.y = y;
		row.screenCenter(X);
		row.ID = id;
		return row.y + row.height + 30;
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
		probeStates.set(id, 'checking');
		GameClient.probeServer(address, (result) -> {
			if (result != null && result.ok)
				ServerList.markResult(id, result.pingMs, true);
			probeStates.set(id, probeOutcome(result));
			if (!self.exists)
				return;
			if (id == ServerList.selectedId())
				self.serverTtlNote = pinnedTtlNote(result != null ? result.config : null);
			self.refreshDescriptions();
		});
	}

	/**
	 * Why a probe is or is not usable. A socket that never answered is a timeout; an HTTP server
	 * that answered but did not greet with engine=seiunengine-online (Protocol.MAGIC) is a
	 * protocol mismatch -- the two look identical to a player watching a spinner, and the fixes
	 * differ (firewall / address vs. wrong server).
	 */
	static function probeOutcome(result:ServerProbe):String {
		if (result == null || !result.reachable)
			return 'timeout';

		var config:Dynamic = result.config;
		var engine:Dynamic = (config != null && Reflect.hasField(config, 'engine')) ? config.engine : null;
		if (engine == null || Std.string(engine) != Protocol.MAGIC)
			return 'wrongProtocol';

		return 'reachable';
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
			if (serverRowStart + i >= items.length)
				break;
			var row = items.members[serverRowStart + i];
			if (row != null && row.descText != null)
				row.descText.text = entryDesc(entry);
			i++;
		}
	}

	// ------------------------------------------------------------------
	// Interaction
	// ------------------------------------------------------------------

	/** True while a connect check is in flight, so a second click cannot start a second probe. */
	var connecting:Bool = false;

	/**
	 * Switch to a server -- but ask it first.
	 *
	 * This used to select + applySelectedServer() + FlxG.resetState() in one go, so a typo, a host
	 * that is not running yet or a machine on another network produced a one-frame black flash and
	 * then the same screen again, with nothing to explain what had happened.
	 *
	 * Now the address is probed first (the same check the latency column uses):
	 *   - an answer switches immediately, so the common case stays one click;
	 *   - silence, or something that is not a SeiunEngine server, says so in a dialog and asks
	 *     whether to switch anyway -- refusing outright would make a server that is simply down
	 *     impossible to select, and its address impossible to fix.
	 *
	 * @param newAddress the text typed into the Server Address field. `null` means "use
	 *                   the entry as it is", which is what clicking a row in the list above does.
	 */
	function connectTo(id:String, ?newAddress:String = null):Void {
		if (connecting)
			return;

		if (newAddress != null && newAddress.trim() == '') {
			Alert.alert(OnlineLang.L('options.connectEmpty', 'No address typed'),
				OnlineLang.L('options.connectEmpty.desc', 'Type the address of the server, for example ws://192.168.1.50:2567.'));
			return;
		}

		var entry = ServerList.find(id);
		var address:String = newAddress != null
			? ServerList.normalizeAddress(newAddress)
			: (entry != null ? entry.address : ServerList.DEFAULT_ADDRESS);
		var writeAddress:Null<String> = newAddress != null ? address : null;

		connecting = true;
		LoadingScreen.toggle(true);
		// probeServer runs on a worker thread and hands the result back through Waiter, so this
		// callback is already on the render thread and may touch flixel objects.
		GameClient.probeServer(address, (result) -> {
			LoadingScreen.toggle(false);
			connecting = false;
			if (!exists)
				return;

			var outcome:String = probeOutcome(result);
			if (outcome == 'reachable') {
				applyServer(id, writeAddress);
				return;
			}

			RequestSubstate.request(
				outcome == 'wrongProtocol'
					? OnlineLang.L('options.connectBad.title', 'Not a SeiunEngine server')
					: OnlineLang.L('options.connectFail.title', 'The server did not answer'),
				(outcome == 'wrongProtocol'
					? OnlineLang.L('options.connectBad.desc', 'Something answered, but it did not identify itself as a SeiunEngine online server. Check the address and the port (the default is 2567).')
					: OnlineLang.L('options.connectFail.desc', 'Nothing answered in time. Check that the server is running, and that the address and port are correct.'))
					+ '\n\n' + address + '\n\n' + OnlineLang.L('options.connectAnyway', 'Connect anyway?'),
				(_) -> applyServer(id, writeAddress),
				null,
				true);
		});
	}

	/** True from the moment the scan row is used until its results have been shown. */
	var scanningLan:Bool = false;

	/**
	 * Servers heard by the last search, and which of them the player ticked. Static so they survive
	 * the FlxG.resetState() that redraws this screen; cleared once they have been acted on.
	 */
	static var lanFound:Array<LanServer> = [];
	static var lanPicked:Map<String, Bool> = new Map();

	/** Index of the first saved-server row inside items; refreshDescriptions() maps onto these. */
	var serverRowStart:Int = 0;

	/** Starts a LAN scan; update() shows the result once the listener publishes it. */
	function startLanScan():Void {
		if (scanningLan)
			return;

		scanningLan = true;
		LanDiscovery.startScan();
		LoadingScreen.toggle(true);
	}

	/**
	 * Hands the scan results to the screen and redraws it.
	 *
	 * They are deliberately NOT saved: they become a "Found on This Network" section whose rows are
	 * tick boxes, and only the Add Selected Servers row writes anything into the server list.
	 */
	function finishLanScan():Void {
		var heard = LanDiscovery.found;
		if (heard.length == 0) {
			Alert.alert(OnlineLang.L('options.serverScan.none.title', 'No server found'),
				OnlineLang.L('options.serverScan.none.desc', 'Nothing announced itself on this network. The host has to be running the game\'s built-in LAN Host, or a dedicated server built from this version; check that both machines are on the same Wi-Fi / LAN.'));
			return;
		}

		lanFound = heard;
		lanPicked = new Map();
		curSelected = 0;
		FlxG.resetState();
	}

	/** Adds the servers the player ticked. The only place a search result is ever saved. */
	function addPickedLanServers():Void {
		var added:Array<String> = [];
		for (server in lanFound) {
			if (lanPicked.get(server.address) != true || hasAddress(server.address))
				continue;

			ServerList.create(server.name != '' ? server.name : server.address, server.address);
			added.push(server.address);
		}

		if (added.length == 0) {
			Alert.alert(OnlineLang.L('options.serverScan.add.none.title', 'Nothing ticked'),
				OnlineLang.L('options.serverScan.add.none.desc', 'Tick at least one server in the list first.'));
			return;
		}

		lanFound = [];
		lanPicked = new Map();
		Alert.alert(OnlineLang.L('options.serverScan.add.done.title', 'Servers added'),
			OnlineLang.L('options.serverScan.add.done.desc', 'Added to your list:') + '\n' + added.join('\n'),
			() -> FlxG.resetState());
	}

	/** Drops the search results without adding anything. */
	function clearLanResults():Void {
		lanFound = [];
		lanPicked = new Map();
		FlxG.resetState();
	}

	function hasAddress(address:String):Bool {
		for (entry in ServerList.all())
			if (entry != null && entry.address == address)
				return true;
		return false;
	}

	/** Writes the new address into the entry (when one was typed), selects it and reboots the screen. */
	function applyServer(id:String, ?newAddress:String = null):Void {
		if (newAddress != null) {
			var entry = ServerList.find(id);
			ServerList.setAddresses(id, newAddress, entry != null ? entry.networkAddress : '');
		}
		ServerList.select(id);
		GameClient.applySelectedServer();
		FlxG.resetState();
	}

	override function update(elapsed:Float) {
		// The LAN listener runs on a worker thread and publishes its scanning flag when it is done;
		// this is the hand-off point back to the render thread. Checked before the dialog guard so
		// the result is not delayed by whatever happens to be on top.
		if (scanningLan && !LanDiscovery.scanning) {
			scanningLan = false;
			LoadingScreen.toggle(false);
			finishLanScan();
		}

		// A confirmation dialog on top owns the pointer and the keys; without this the click that
		// closes it would also land on whatever row sits underneath.
		if (subState != null) {
			super.update(elapsed);
			return;
		}

		if (curOption != null)
			camFollow.setPosition(curOption.getMidpoint().x, curOption.getMidpoint().y);

		// A tap that lands on the on-screen pad belongs to the pad, never to a row or button behind it.
		var padTap = OnlineNav.padBlocks(virtualPad);
		var pointerClick = FlxG.mouse.justPressed && !padTap;

		// Buttons own the click when the pointer is over one; rows keep their own hitboxes.
		var buttonHit = false;
		if (pointerClick) {
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

			// Wheel (1 = up) plus the pad/keyboard, with hold-to-repeat. The pointer no longer
			// drags the selection along as it moves: a click is what selects a row.
			var steps = nav.poll(controls.UI_UP, controls.UI_DOWN, elapsed) - FlxG.mouse.wheel;
			while (steps != 0) {
				var dir = steps > 0 ? 1 : -1;
				changeSelection(dir);
				steps -= dir;
			}

			var pointerRow = padTap ? -1 : optionIndexUnderPointer();
			if (pointerClick && pointerRow >= 0)
				changeSelection(pointerRow - curSelected);

			// Hover is recomputed every frame so the highlight matches what a click would hit.
			var newHover:InputOption = pointerRow >= 0 ? items.members[pointerRow] : null;
			if (newHover != hoveredOption) {
				hoveredOption = newHover;
				updateOptions();
			}
		}
		else if (hoveredOption != null) {
			hoveredOption = null;
			updateOptions();
		}

		super.update(elapsed);

		// Clicking a field's input box moves focus there (same rule as the options screen).
		if (pointerClick && curOption != null && curOption.isInput) {
			var target:Int = -1;
			for (i => input in curOption.inputs)
				if (mouseOverInputBg(curOption.inputBgs[i]))
					target = i;
			setInputFocus(curOption, target);
		}

		if (!inputWait && !buttonHit) {
			if ((controls.ACCEPT || pointerClick) && curOption != null) {
				if (curOption.isInput) {
					if (!pointerClick)
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

	/**
	 * Index of the row under the pointer, or -1. Uses the row group's own world box, so it stays
	 * correct while the camera follows the selection.
	 */
	function optionIndexUnderPointer():Int {
		var index = 0;
		for (item in items) {
			if (item != null && OnlineNav.pointerOver(item, camera))
				return index;
			index++;
		}
		return -1;
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
			// Only the selected row gets the border and full opacity; the hovered row is brightened
			// just enough to show what a click would hit.
			item.borderline.visible = item == curOption;
			item.alpha = inputWait ? 0.5 : (item == curOption ? 1 : (item == hoveredOption ? 0.9 : 0.6));
			if (item.isInput)
				for (input in item.inputs)
					input.alpha = 0.5;
		}
		if (curOption != null) {
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
