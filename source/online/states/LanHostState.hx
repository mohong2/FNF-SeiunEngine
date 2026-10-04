package online.states;

#if ONLINE_ALLOWED
import flixel.FlxObject;
import lime.system.Clipboard;
import online.lan.LanHost;
import online.lan.LanHost.LanHostConfig;
import online.states.OnlineOptionsState.InputOption;

/**
 * LAN host settings / status panel (OnlineState -> "LAN HOST").
 *
 * The rows are the SAME widget the online options screen uses (InputOption, declared in
 * OnlineOptionsState.hx) on the same background, with the same keyboard / wheel / mouse
 * navigation, so this screen looks and behaves like the rest of the online UI.
 *
 * It covers the user's two asks in one place: one action starts hosting, and the panel exposes
 * the host preferences (port, max players, same-PC players, public listing) plus live status
 * (LAN address, room code, connected clients, firewall note) that a LAN host needs to read out
 * loud. All work happens in online.lan.LanHost on worker threads; this screen only polls
 * LanHost.status from the render thread and never blocks on a socket.
 */
class LanHostState extends MusicBeatState {
	var items:FlxTypedGroup<InputOption> = new FlxTypedGroup<InputOption>();
	var camFollow:FlxObject;
	static var curSelected:Int = 0;
	var curOption:InputOption;

	var tip:FlxText;
	var tipBg:FlxSprite;

	// Rows whose text or description changes with the host state.
	var hostRow:InputOption;
	var stateRow:InputOption;
	var addressRow:InputOption;
	var codeRow:InputOption;
	var clientsRow:InputOption;

	/** Section headers and rows in draw order; relayout() re-stacks them from measured heights. */
	var layout:Array<LanLayoutEntry> = [];

	/** Reads every field that must not be lost when BACK leaves the screen. */
	var commits:Array<Void->Void> = [];

	var refreshTimer:Float = 0;
	var lastErrorId:Int = 0;

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
		DiscordClient.changePresence("In the Menus", "LAN Host");
		#end

		var bg:FlxSprite = new FlxSprite().loadGraphic(Paths.image('menuDesat'));
		bg.color = 0xff2b2b2b;
		bg.updateHitbox();
		bg.screenCenter();
		bg.antialiasing = ClientPrefs.data.globalAntialiasing;
		bg.scrollFactor.set(0, 0);
		add(bg);

		var i = 0;
		var y:Float = 70;

		y = addSection(OnlineLang.L('lan.section', 'LAN Host'), y);

		hostRow = addActionRow(OnlineLang.L('lan.start', 'Host on LAN'),
			OnlineLang.L('lan.start.desc', 'Starts the server on this PC and joins its room, so friends on your network can play.'),
			i++, y, onHostAction);
		y = hostRow.y + hostRow.height + 30;

		var portRow = addFieldRow(OnlineLang.L('lan.port', 'Port'),
			OnlineLang.L('lan.port.desc', 'Port of the local server. If it is busy the next free pair is used and shown below.'),
			OnlineLang.L('lan.port.placeholder', '2567'), Std.string(ClientPrefs.data.lanHostPort),
			i++, y, (text, _) -> onPortCommit(text, false));
		y = portRow.y + portRow.height + 30;
		commits.push(() -> onPortCommit(portRow.inputs[0].text, true));

		var maxRow = addFieldRow(OnlineLang.L('lan.maxPlayers', 'Max Players'),
			OnlineLang.L('lan.maxPlayers.desc', 'How many players may be in the room at once (1-64).'),
			OnlineLang.L('lan.maxPlayers.placeholder', '6'), Std.string(ClientPrefs.data.lanHostMaxClients),
			i++, y, (text, _) -> onMaxCommit(text, false));
		y = maxRow.y + maxRow.height + 30;
		commits.push(() -> onMaxCommit(maxRow.inputs[0].text, true));

		var samePcRow = addToggleRow(OnlineLang.L('lan.allowSamePc', 'Allow Players From This PC'),
			OnlineLang.L('lan.allowSamePc.desc', 'Lets several sessions from one IP join, so you can test with a second client on this PC.'),
			ClientPrefs.data.lanHostAllowSamePc, i++, y, (value) -> {
				ClientPrefs.data.lanHostAllowSamePc = value;
				ClientPrefs.saveSettings();
			});
		y = samePcRow.y + samePcRow.height + 30;

		var publicRow = addToggleRow(OnlineLang.L('lan.publicRoom', 'Public Room'),
			OnlineLang.L('lan.publicRoom.desc', 'List the room on this server so other LAN players can find it in FIND. Off = room code only.'),
			ClientPrefs.data.lanHostPublic, i++, y, (value) -> {
				ClientPrefs.data.lanHostPublic = value;
				ClientPrefs.saveSettings();
			});
		y = publicRow.y + publicRow.height + 30;

		y = addSection(OnlineLang.L('lan.status', 'Status'), y);

		stateRow = addInfoRow(OnlineLang.L('lan.state', 'State'), OnlineLang.L('lan.state.stopped', 'Not hosting'), i++, y);
		y = stateRow.y + stateRow.height + 30;

		addressRow = addInfoRow(OnlineLang.L('lan.address', 'LAN Address'), OnlineLang.L('lan.address.none', 'Not hosting.'), i++, y);
		addressRow.onClick = () -> copyToClipboard(LanHost.status.shareAddress);
		y = addressRow.y + addressRow.height + 30;

		codeRow = addInfoRow(OnlineLang.L('lan.roomCode', 'Room Code'), OnlineLang.L('lan.roomCode.none', 'No room yet.'), i++, y);
		codeRow.onClick = () -> copyToClipboard(currentRoomSecret());
		y = codeRow.y + codeRow.height + 30;

		clientsRow = addInfoRow(OnlineLang.L('lan.clients', 'Players'), '0', i++, y);
		y = clientsRow.y + clientsRow.height + 30;

		var firewallRow = addInfoRow(OnlineLang.L('lan.firewall', 'Firewall'),
			firewallText(), i++, y);
		y = firewallRow.y + firewallRow.height + 30;

		var consoleRow = addActionRow(OnlineLang.L('lan.webConsole', 'Open Local Web Console'),
			OnlineLang.L('lan.webConsole.desc', 'Opens the hosted server console in your browser (this PC only).'),
			i++, y, onConsoleAction);
		y = consoleRow.y + consoleRow.height + 30;

		var backRow = addActionRow(OnlineLang.L('lan.back', 'Back'),
			OnlineLang.L('lan.back.desc', 'Return to the online menu. Hosting keeps running until you stop it.'),
			i++, y, leaveState);
		y = backRow.y + backRow.height + 30;

		// VALUE rows (state / LAN address / room code / players) were built with a short placeholder,
		// so InputOption froze their description column at that placeholder width; give them an
		// explicit one (see fixDescWidth). Action rows, hostRow included, keep their own column.
		for (row in [stateRow, addressRow, codeRow, clientsRow])
			fixDescWidth(row);

		add(items);

		tip = new FlxText(0, 0, 0, OnlineLang.L('lan.tip', 'ENTER: select - UP/DOWN: move - BACK: return'));
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
		refreshRows();

		// A window resize changes FlxG.width and every text wrap, so the stack is measured again.
		FlxG.signals.gameResized.add(onGameResized);

		// LanHost delivers this on the render thread through Waiter, so it is safe to refresh
		// Flixel objects from it.
		LanHost.setChangeListener(function() {
			if (FlxG.state == this)
				refreshRows();
		});
	}

	override function destroy() {
		LanHost.setChangeListener(null);
		FlxG.signals.gameResized.remove(onGameResized);
		super.destroy();
	}

	// ------------------------------------------------------------------
	// Layout helpers (same shape as OnlineOptionsState rows)
	// ------------------------------------------------------------------

	function addSection(title:String, y:Float):Float {
		var text = new FlxText(0, y, FlxG.width, title);
		text.setFormat(OnlineLang.font(), 25, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		add(text);
		layout.push(new LanLayoutEntry(text));
		return text.y + text.height + 40;
	}

	function addInfoRow(title:String, desc:String, id:Int, y:Float):InputOption {
		var row:InputOption;
		items.add(row = new InputOption(title, desc, null, null));
		layout.push(new LanLayoutEntry(null, row));
		row.y = y;
		row.screenCenter(X);
		row.ID = id;
		return row;
	}

	function addActionRow(title:String, desc:String, id:Int, y:Float, action:Void->Void):InputOption {
		var row:InputOption;
		items.add(row = new InputOption(title, desc, null, action));
		layout.push(new LanLayoutEntry(null, row));
		row.y = y;
		row.screenCenter(X);
		row.ID = id;
		return row;
	}

	function addToggleRow(title:String, desc:String, checked:Bool, id:Int, y:Float, onChange:Bool->Void):InputOption {
		var row:InputOption;
		items.add(row = new InputOption(title, desc, checked));
		layout.push(new LanLayoutEntry(null, row));
		row.onClick = () -> {
			row.checked = !row.checked;
			onChange(row.checked);
		};
		row.y = y;
		row.screenCenter(X);
		row.ID = id;
		return row;
	}

	function addFieldRow(title:String, desc:String, placeholder:String, value:String, id:Int, y:Float, onEnter:(text:String, input:Int)->Void):InputOption {
		var row:InputOption;
		items.add(row = new InputOption(title, desc, [placeholder], null, onEnter, null));
		layout.push(new LanLayoutEntry(null, row));
		row.inputs[0].text = value;
		row.y = y;
		row.screenCenter(X);
		row.ID = id;
		return row;
	}

	/**
	 * Explicit field width for the VALUE rows that refreshRows() rewrites: state, LAN address, room
	 * code and player count.
	 *
	 * InputOption freezes its description column at Math.min(700, natural width of the text it was
	 * CONSTRUCTED with), so a row built with a short placeholder (Not hosting. / No room yet. / 0)
	 * wrapped its real value in a column about 90 px wide: the state line broke into three lines and
	 * the LAN address broke mid-IP. 560 px holds the longest value this panel shows at font 18
	 * (address plus the click-to-copy suffix) on one line at normal window sizes. If a narrow window
	 * wraps it anyway, relayout() grows the row box and pushes the rows below it down.
	 *
	 * ACTION rows (hostRow) are deliberately not widened: their constructor text is already long, so
	 * InputOption froze a generous column for them and their runtime start/stop text fits it. Forcing
	 * 560 px there could only add a wrapped line to the resting panel, i.e. change the look.
	 */
	static inline var STATUS_DESC_WIDTH:Float = 560;

	static function fixDescWidth(row:InputOption):InputOption {
		if (row != null)
			row.descText.fieldWidth = STATUS_DESC_WIDTH;
		return row;
	}

	/**
	 * Re-stacks every section header and row from the heights measured right now, and re-fits each
	 * row box and border to its current text (InputOption.refreshLayout).
	 *
	 * create() places the rows once, from the height each row had with its placeholder text, so a
	 * description that grew to two or three lines used to overlap the row below it and to spill out
	 * of its highlight box. The same 40 px section gap and 30 px row gap are reused here, so the
	 * panel still looks like the options screen; only heights and y positions change.
	 */
	function relayout():Void {
		var y:Float = 70;

		for (entry in layout) {
			if (entry.header != null) {
				// Section titles are centered on the window, so a resize also has to re-widen their
				// field or the text would stay centered on the old width.
				entry.header.fieldWidth = FlxG.width;
				entry.header.y = y;
				y += entry.header.height + 40;
				continue;
			}

			if (entry.row == null)
				continue;

			var row = entry.row;
			row.refreshLayout();
			row.y = y;
			row.screenCenter(X);
			y += row.height + 30;
		}
	}

	/** A window resize changes FlxG.width and every text wrap, so the stack is measured again. */
	function onGameResized(_width:Int, _height:Int):Void {
		relayout();
	}

	// ------------------------------------------------------------------
	// Actions
	// ------------------------------------------------------------------

	function onHostAction():Void {
		var status = LanHost.status;
		if (status.stopping)
			return;
		if (status.running || status.starting) {
			LanHost.stop();
			refreshRows();
			return;
		}

		LanHost.start({
			port: ClientPrefs.data.lanHostPort,
			maxClients: ClientPrefs.data.lanHostMaxClients,
			publicRoom: ClientPrefs.data.lanHostPublic,
			allowSamePc: ClientPrefs.data.lanHostAllowSamePc,
			dataDir: ClientPrefs.data.lanHostDataDir
		});
		refreshRows();
	}

	function onPortCommit(text:String, quiet:Bool):Void {
		var parsed = Std.parseInt(text == null ? null : text.trim());
		if (parsed == null || parsed < 1024 || parsed > 65534) {
			if (!quiet) {
				Alert.alert(OnlineLang.L('lan.port.invalid', 'Invalid port'),
					OnlineLang.L('lan.port.invalid.desc', 'Use a port between 1024 and 65534, for example 2567.'));
			}
			return;
		}

		if (parsed != ClientPrefs.data.lanHostPort) {
			ClientPrefs.data.lanHostPort = parsed;
			ClientPrefs.saveSettings();
		}

		if (!quiet && (LanHost.status.running || LanHost.status.starting))
			Alert.alert(OnlineLang.L('lan.pref.restart', 'Restart hosting to apply'),
				OnlineLang.L('lan.pref.restart.desc', 'Stop hosting and start again to use the new port.'));
	}

	function onMaxCommit(text:String, quiet:Bool):Void {
		var parsed = Std.parseInt(text == null ? null : text.trim());
		if (parsed == null)
			parsed = ClientPrefs.data.lanHostMaxClients;

		// Same clamp ServerConfig applies to max_clients (server ServerConfig.hx:174).
		if (parsed < 1) parsed = 1;
		if (parsed > 64) parsed = 64;

		if (parsed != ClientPrefs.data.lanHostMaxClients) {
			ClientPrefs.data.lanHostMaxClients = parsed;
			ClientPrefs.saveSettings();
		}

		if (!quiet && (LanHost.status.running || LanHost.status.starting))
			Alert.alert(OnlineLang.L('lan.pref.restart', 'Restart hosting to apply'),
				OnlineLang.L('lan.pref.restart.desc', 'Stop hosting and start again to use the new port.'));
	}

	function onConsoleAction():Void {
		var status = LanHost.status;
		// The console is served by the embedded server on loopback; it exists only while hosting.
		if (!status.running || status.httpPort <= 0) {
			Alert.alert(OnlineLang.L('lan.webConsole.closed', 'Not hosting'),
				OnlineLang.L('lan.webConsole.closed.desc', 'Start hosting first; the console listens on this PC only.'));
			return;
		}

		FlxG.openURL('http://127.0.0.1:' + status.httpPort + '/console');
	}

	function copyToClipboard(value:String):Void {
		if (value == null || value == '')
			return;

		// Same clipboard path RoomState uses for the room code (RoomState.hx:932).
		Clipboard.text = value;
		Alert.alert(OnlineLang.L('lan.copied', 'Copied to clipboard!'), value);
	}

	/** The room code a friend can paste into JOIN (RoomID;ws://lan-ip:port while hosting). */
	function currentRoomSecret():String {
		if (!GameClient.isConnected() || GameClient.room == null)
			return null;
		return GameClient.getRoomSecret(true);
	}

	function leaveState():Void {
		commitInputsOnExit();
		FlxG.sound.music.volume = 1;
		FlxG.switchState(new OnlineState());
		FlxG.sound.play(Paths.sound('cancelMenu'));
	}

	function commitInputsOnExit():Void {
		for (commit in commits)
			commit();
	}

	/** Native platform note appended to the firewall row (Android cannot keep a background host). */
	function firewallText():String {
		var text = OnlineLang.L('lan.firewall.text',
			'Windows may ask to allow the game on your network: allow it for Private networks, or friends cannot connect.');
		#if android
		text += '\n' + OnlineLang.L('lan.android.foreground',
			'Keep the game in the foreground while hosting; Android may freeze it in the background and drop the room.');
		#end
		return text;
	}

	// ------------------------------------------------------------------
	// Live status
	// ------------------------------------------------------------------

	function refreshRows():Void {
		var status = LanHost.status;
		// "stopping" still owns the ports, so the row stays on the Stop side until it is done.
		var hosting = status.running || status.starting || status.stopping;

		hostRow.text.text = hosting
			? OnlineLang.L('lan.stop', 'Stop Hosting')
			: OnlineLang.L('lan.start', 'Host on LAN');
		hostRow.descText.text = hosting
			? OnlineLang.L('lan.stop.desc', 'Stops the server on this PC and leaves the local room.')
			: OnlineLang.L('lan.start.desc', 'Starts the server on this PC and joins its room, so friends on your network can play.');

		var stateText:String;
		if (status.starting)
			stateText = OnlineLang.L('lan.state.starting', 'Starting...');
		else if (status.stopping)
			stateText = OnlineLang.L('lan.state.stopping', 'Stopping...');
		else if (status.running)
			stateText = OnlineLang.L('lan.state.running', 'Hosting') + ' (' + OnlineLang.L('lan.ports', 'ports: ')
				+ status.httpPort + ' / ' + status.wsPort + ')';
		else
			stateText = OnlineLang.L('lan.state.stopped', 'Not hosting');
		stateRow.descText.text = stateText;

		if (status.shareAddress != null && status.shareAddress != '')
			addressRow.descText.text = status.shareAddress + '  ' + OnlineLang.L('lan.clickToCopy', '(Click to copy)');
		else if (status.running)
			addressRow.descText.text = OnlineLang.L('lan.address.noneRunning',
				'No LAN address was detected. Read this PC IPv4 from the system settings and type it for your friends.');
		else
			addressRow.descText.text = OnlineLang.L('lan.address.none', 'Not hosting.');

		var secret = currentRoomSecret();
		codeRow.descText.text = (secret != null && secret != '')
			? secret + '  ' + OnlineLang.L('lan.clickToCopy', '(Click to copy)')
			: OnlineLang.L('lan.roomCode.none', 'No room yet.');

		clientsRow.descText.text = Std.string(status.clients);

		if (status.error != null && status.errorId != lastErrorId) {
			lastErrorId = status.errorId;
			Alert.alert(OnlineLang.L('lan.error.title', 'LAN hosting failed'), status.error);
		}

		// The text above may have changed the row heights; re-stack the panel and re-fit the boxes.
		relayout();
	}

	// ------------------------------------------------------------------
	// Interaction (mirrors OnlineOptionsState / ServerListState)
	// ------------------------------------------------------------------

	override function update(elapsed:Float) {
		// A dialog on top owns the pointer and the keys.
		if (subState != null) {
			super.update(elapsed);
			return;
		}

		refreshTimer -= elapsed;
		if (refreshTimer <= 0) {
			refreshTimer = 0.25;
			refreshRows();
			// Off-thread /api/health read for the client count; throttled inside LanHost too.
			LanHost.refreshStatus();
		}

		if (curOption != null)
			camFollow.setPosition(curOption.getMidpoint().x, curOption.getMidpoint().y);

		if (!inputWait) {
			if (controls.BACK #if android || FlxG.android.justReleased.BACK #end) {
				leaveState();
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

/**
 * One entry of the LAN panel vertical stack: a section header or an option row. Keeping the order
 * here lets relayout() rebuild the stack from measured heights after any text change.
 */
class LanLayoutEntry {
	public var header:FlxText;
	public var row:InputOption;

	public function new(?header:FlxText, ?row:InputOption) {
		this.header = header;
		this.row = row;
	}
}
#end
