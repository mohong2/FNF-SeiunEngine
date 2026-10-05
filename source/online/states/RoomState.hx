package online.states;

// `states.stages.objects.PhillyTrain`, `states.stages.Spooky` and
// `states.stages.Philly` do not exist here: `source/states/stages/` holds
// `PhillyStage`/`SpookyStage` (StageBackdrop subclasses owning PlayState.phillyWindow/phillyTrain).
// `Spooky`/`Philly` were import-only and `PhillyTrain` is dropped (see LobbyStage).
import StageData; // declared in source/StageData.hx
import flixel.util.FlxStringUtil;
import flixel.util.FlxAxes;
import flixel.addons.display.FlxPieDial;
import sys.FileSystem;
import flixel.FlxSubState;
import flixel.group.FlxGroup;
import flixel.math.FlxPoint;
import flixel.FlxObject;
import flixel.util.FlxSpriteUtil;
import Character; // declared in source/Character.hx
import lime.system.Clipboard;
import online.backend.schema.Player;
import Conductor.Rating; // declared in source/Conductor.hx:189
import WeekData; // declared in source/WeekData.hx
import Song; // declared in source/Song.hx
import haxe.crypto.Md5;
import states.FreeplayState; // declared in package states
import states.ModsMenuState;
import online.util.OnlineLang;
import openfl.utils.Assets as OpenFlAssets;
import openfl.Lib;

#if lumod
@:build(lumod.LuaScriptClass.build())
#end
@:publicFields
/*#if interpret @:nullSafety(Off) #end*/
class RoomState extends MusicBeatState /*#if interpret implements interpret.Interpretable #end */ {
	var verifyMod:FlxText;
	var verifyModBg:FlxSprite;
	var roomCodeBg:FlxSprite;
	var roomCode:FlxText;
	var songName:FlxText;
	var songNameBg:FlxSprite;
	var playIcon:FlxSprite;
	var playIconBg:FlxSprite;
	var chatBox:ChatBox;

	var characters:Map<String, LobbyCharacter> = new Map();
	var charactersLayer:FlxTypedGroup<LobbyCharacter> = new FlxTypedGroup<LobbyCharacter>();

	var curSelected:Int = -1;
	var items:FlxTypedGroup<FlxSprite>;
	var settingsIconBg:FlxSprite;
	var settingsIcon:FlxSprite;
	var chatIconBg:FlxSprite;
	var chatIcon:FlxSprite;

	/** UP/DOWN/LEFT/RIGHT hold-to-repeat, shared with the on-screen pad. */
	var nav = new NavRepeat();

	/** Icon under the pointer, or -1. Hover only lights it up; a click is what selects it. */
	var hoverIndex:Int = -1;

	var itemTip:FlxText;
	var itemTipBg:FlxSprite;

	// This is typed `LobbyStage` rather than a stage-base class: there is no `BaseStage`
	// equivalent that registers itself in MusicBeatState.stages (see the LobbyStage comment),
	// so LobbyStage is self-contained and only seen as a group here.
	var stage:LobbyStage;

	var cum:FlxCamera = new FlxCamera();
	var camHUD:FlxCamera = new FlxCamera();
	var groupHUD:FlxGroup;

	var leavePie:LeavePie;

	/** Fallback timer and trace throttle for the long-press leave path. */
	var leaveHold:Float = 0;
	var leaveTraceTimer:Float = 0;
	var leaveFallbackFired:Bool = false;

	var revealTimer:FlxTimer;
	var playerHold(default, set):Bool = false;

	var funnyMode(default, set):Int = 1;
	function set_funnyMode(v) {
		funnyMode = v;
		switch (funnyMode) {
			case 0:
				targetCamZoom = 0.65;
				targetCamX = 200;
				targetCamY = 120;
			case 1:
				targetCamZoom = 0.57;
				targetCamX = 150;
				targetCamY = 120;
			case 2:
				targetCamZoom = 0.45;
				targetCamX = 50;
				targetCamY = 180;
			case 3:
				targetCamZoom = 0.34;
				targetCamX = 50;
				targetCamY = 250;
		}
		startCamTween();
		return funnyMode;
	}

	var targetCamTween:FlxTween;
	var targetCamScrollTween:FlxTween;
	var targetCamZoom:Float = 0.65;
	var targetCamX:Float = 200;
	var targetCamY:Float = 120;

	function startCamTween() {
		if (targetCamTween != null)
			targetCamTween.cancel();
		targetCamTween = FlxTween.tween(cum, {zoom: targetCamZoom}, 1, {ease: FlxEase.quadOut});

		if (targetCamScrollTween != null)
			targetCamScrollTween.cancel();
		targetCamScrollTween = FlxTween.tween(cum.scroll, {x: targetCamX, y: targetCamY}, 1, {ease: FlxEase.quadOut});
	}

	// A download callback reads `RoomState.instance`, and Haxe 4.2.5 treats
	// the field as module-private, so it is declared public here.
	public static var instance:RoomState = null;

	function set_playerHold(v) {
		if (playerHold != v) {
			playerHold = v;
			GameClient.send("noteHold", v);
		}
		return v;
	}

	public function new() {
		super();

		instance = this;
	}

	function registerMessages() {
		if (GameClient.getPlayerSelf() == null) {
			GameClient.leaveRoom('Self not in the room (registerMessages).');
			return;
		}

		GameClient.initStateListeners(this, this.registerMessages);

		if (!GameClient.isConnected())
			return;

		playMusic(GameClient.getPlayerSelf().hasSong);
		GameClient.registerStateDisposer(this, GameClient.callbacks.listen(GameClient.getPlayerSelf(), "hasSong", (value:Bool, prev) -> {
			Waiter.putPersist(() -> {
				if (destroyed)
					return;
				playMusic(value);
			});
		}));

		// State-level: overrides the room-level handler (the one clearOnMessage registers);
		// on disposal registerStateMessage restores it, leaving no hole in onMessageHandlers.
		GameClient.registerStateMessage(this, "checkChart", function(message) {
			Waiter.put(() -> {
				if (destroyed)
					return;
				verifyDownloadMod(false, true);
			});
		});

		GameClient.registerStateMessage(this, "checkStage", function(message) {
			Waiter.put(() -> {
				if (destroyed)
					return;
				checkStage();
			});
		});

		function listenUpdateTextOnField(player:Player, field:String) {
			GameClient.registerStateDisposer(this, GameClient.callbacks.listen(player, field, (value, prev) -> {
				if (value == prev)
					return;
				Waiter.put(() -> {
					if (destroyed)
						return;
					updateTexts();
				});
			}));
		}
		function listenUpdate(sid:String, player:Player) {
			listenUpdateTextOnField(player, 'ping');
			listenUpdateTextOnField(player, 'status');
			listenUpdateTextOnField(player, 'name');
			GameClient.registerStateDisposer(this, GameClient.callbacks.listen(player, "skin", (value, prev) -> {
				if (value == prev)
					return;
				Waiter.put(() -> {
					if (destroyed)
						return;
					final lobbyChar = characters.get(sid);
					if (lobbyChar == null)
						return;
					lobbyChar.loadCharacter();
					updateCharacters();
				});
			}));
			GameClient.registerStateDisposer(this, GameClient.callbacks.listen(player, "isReady", (value, prev) -> {
				Waiter.put(() -> {
					if (destroyed)
						return;
					if (value) {
						var sond = FlxG.sound.play(Paths.sound('confirmMenu'), 0.5);
						sond.pitch = 1.5;

						final lobbyChar = characters.get(sid);
						if (lobbyChar == null)
							return;
						lobbyChar.character.playAnim('ready', true);
					}
					else if (GameClient.room != null && !GameClient.room.state.isStarted) {
						var sond = FlxG.sound.play(Paths.sound('cancelMenu'));
						sond.pitch = 1.5;
					}
				});
			}));
			GameClient.registerStateDisposer(this, GameClient.callbacks.listen(player, "noteSkin", (value, prev) -> {
				if (value == prev)
					return;
				Waiter.put(() -> {
					if (destroyed)
						return;
					checkNoteSkin(player);
				});
			}));
			GameClient.registerStateDisposer(this, GameClient.callbacks.listen(player, "bfSide", (value, prev) -> {
				if (value == prev)
					return;

				Waiter.put(() -> {
					if (destroyed)
						return;
					updateCharacters();
				});
			}));
			GameClient.registerStateDisposer(this, GameClient.callbacks.listen(player, "ox", (value, prev) -> {
				if (value == prev)
					return;

				Waiter.put(() -> {
					if (destroyed)
						return;
					updateCharacters();
				});
			}));
		}

		function initPlayer(sid:String, player:Player) {
			if (destroyed || player == null)
				return;

			if (!characters.exists(sid)) {
				var char = new LobbyCharacter(player);
				characters.set(sid, char);
				// charactersLayer is not rebuilt: a `members == null` patch handled stale
				// callbacks from a destroyed state, but the rebuilt group was never re-added in
				// create(), so new characters landed in a detached group (host did not see players
				// until an update). State handlers now have a lifecycle, so they cannot go stale.
				charactersLayer.add(char);
				listenUpdate(sid, player);
			}
			else {
				// Already present: just re-attach the latest schema reference.
				var existing = characters.get(sid);
				if (existing != null)
					existing.player = player;
			}

			checkNoteSkin(player);
			updateCharacters();
		}

		//cool colyseus
		// for (sid => player in GameClient.room.state.players) {
		// 	trace('for: ' + sid + " " + player);
		// 	initPlayer(sid, player);
		// }
		// State-level: a new player must appear on the host's screen immediately. onAdd's
		// `immediate` defaults to true, so registering fires once per existing player; an extra
		// `for (sid => player in players)` loop is neither needed nor safe, as it would run
		// initPlayer twice for the same sid.
		GameClient.registerStateDisposer(this, GameClient.callbacks.onAdd("players", (player, sid) -> {
			Waiter.put(() -> {
				if (destroyed)
					return;
				initPlayer(sid, player);
			});
		}));

		GameClient.registerStateDisposer(this, GameClient.callbacks.onRemove("players", (player, sid) -> {
			Waiter.put(() -> {
				if (destroyed)
					return;

				var character = characters.get(sid);
				characters.remove(sid);
				if (character != null) {
					charactersLayer.remove(character, true);
					character.destroy();
				}
				updateCharacters();
			});
		}));

		// GameClient.room.onMessage("ping", function(message) {
		// 	Waiter.put(() -> {
		// 		GameClient.send("pong");
		// 		@:privateAccess {
		// 			if (stage?.phillyWindow == null) return;
		// 			stage.curLight = FlxG.random.int(0, stage.phillyLightsColors.length - 1, [stage.curLight]);
		// 			stage.phillyWindow.color = stage.phillyLightsColors[stage.curLight];
		// 		}
		// 	});
		// });

		GameClient.registerStateMessage(this, "charPlay", function(_message:Array<Dynamic>) {
			if (_message == null || _message.length < 2)
				return;

			var sid:String = _message[0];
			var message:Array<Dynamic> = _message[1];

			Waiter.put(() -> {
				if (destroyed)
					return;
				if (message == null || message[0] == null)
					return;

				playerAnim(message[0], sid);
			});
		});

		GameClient.registerStateDisposer(this, GameClient.callbacks.onChange(GameClient.room.state.gameplaySettings, () -> {
			Waiter.putPersist(() -> {
				if (destroyed)
					return;
				FreeplayState.updateFreeplayMusicPitch();
				//FlxG.animationTimeScale = ClientPrefs.getGameplaySetting('songspeed');
			});
		}));

	}

	override function destroy() {
		super.destroy();

		// Unregister every handler this state registered (onMessage + schema callbacks). The
		// crash was these closures still being queued by websocket messages after the state
		// switched away, then hitting destroyed objects on the next frame.
		GameClient.disposeStateHandlers(this);

		// `GameClient.leaveRoomCleanup()` first queues `FlxG.switchState(new OnlineState())`
		// (this state dies next frame) and then immediately sets `GameClient.room = null`. By the
		// time destroy() runs, `GameClient.room.state` goes through Room.get_state() on null ->
		// native ACCESS_VIOLATION (Room.get_state()+0xA, RCX=0). try/catch cannot catch a cpp null
		// dereference, so guard the lookup.
		try {
			var r = GameClient.room;
			if (r != null && r.state != null)
				GameClient.clearCallbacks(r.state.gameplaySettings);
		} catch (exc) {
			trace(exc);
		}
	}

	var lastSwapped = false;

	final TEXT_BG_COLOR = 0x8A000000;

	override function create() {
		super.create();

		// On-screen controls: UP/DOWN walk the icon ring and B leaves the room. There is no A:
		// every icon is tapped directly, so a confirm button would only duplicate the tap.
		// Mounted up here because the icon row below has to know whether the buttons exist before
		// it can dodge their corner.
		addVirtualPad(UP_DOWN, B);
		// Online pad layout: shrunk buttons tucked into the corners, clear of the UI.
		OnlineNav.layoutColumn(virtualPad);

		#if windows
		if (!Lib.application.window.resizable)
			Lib.application.window.resizable = true;
		#end

		#if DISCORD_ALLOWED
		DiscordClient.resetClientID();
		DiscordClient.changePresence("In the Lobby", null, null, false);
		#end

		WeekData.reloadWeekFiles(false);
		for (i in 0...WeekData.weeksList.length) {
			WeekData.setDirectoryFromWeek(WeekData.weeksLoaded.get(WeekData.weeksList[i]));
		}
		Mods.loadTopMod();
		WeekData.setDirectoryFromWeek();

		// No animation time scale is set here: Flixel
		// 4.11 has no `animationTimeScale` (a flixel 5.x addition) and this engine handles song
		// speed through `PlayState.songSpeed` / `playbackRate`, so there is nothing to reset.

		FlxG.cameras.reset(cum);
		FlxG.cameras.add(camHUD, false);
		FlxG.cameras.setDefaultDrawTarget(cum, true);
		camHUD.bgColor.alpha = 0;

		groupHUD = new FlxGroup();
		groupHUD.cameras = [camHUD];

		// STAGE

		stage = new LobbyStage();
		stage.cameras = [cum];
		add(stage);

		// var debugPoser = new online.objects.DebugPosHelper();
		// add(debugPoser);

		cum.scroll.set(200, 130);
		cum.zoom = 0.5;

		add(charactersLayer);

		// POST STAGE

		// player1Text = new FlxText(0, 100, 0, "PLAYER 1");
		// player1Text.setFormat("VCR OSD Mono", 25, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);

		// player1Bg = new FlxSprite(-1000);
		// player1Bg.makeGraphic(1, 1, 0xA4000000);
		// player1Bg.updateHitbox();
		// player1Bg.y = player1Text.y - 30;
		// groupHUD.add(player1Bg);
		// groupHUD.add(player1Text);

		// player2Text = new FlxText(0, 100, 0, "PLAYER 2");
		// player2Text.setFormat("VCR OSD Mono", 25, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);

		// player2Bg = new FlxSprite(-1000);
		// player2Bg.makeGraphic(1, 1, 0xA4000000);
		// player2Bg.updateHitbox();
		// player2Bg.y = player2Text.y - 30;
		// groupHUD.add(player2Bg);
		// groupHUD.add(player2Text);

		chatBox = new ChatBox(camHUD, (cmd, args) -> {
			switch (cmd) {
				case "pa":
					if (args[0] != null && args[0].trim() != "")
						playerAnim(args[0]);
					else {
						var anims = "";
						// `.iterator()` is explicit: Haxe 4.2.5 cannot iterate a Map value directly
						// ("You can't iterate on a Dynamic value, please specify Iterator");
						// `for (k => v in map)` is fine elsewhere.
						for (anim in @:privateAccess getCharacterSelf().animation._animations.iterator())
							anims += '"${anim.name}" ';
						ChatBox.addMessage("> Please enter the animation you want to play!\nAvailable animations: " + anims);
					}
					return true;
				case "results":
					FlxG.switchState(new ResultsState());
					return true;
				case "restage":
					checkStage();
					return true;
				case "help":
					ChatBox.addMessage("> Room Commands: /pa <anim>, /results, /restage");
			}
			return false;
		});
		groupHUD.add(chatBox);

		items = new FlxTypedGroup<FlxSprite>();

		settingsIconBg = new FlxSprite();
		settingsIconBg.makeGraphic(100, 100, TEXT_BG_COLOR);
		settingsIconBg.updateHitbox();
		settingsIconBg.y = FlxG.height - settingsIconBg.height - 20;
		// A and B sit in the bottom-right corner, so on touch builds the whole icon row (and the
		// room-code / song labels stacked above it, which all hang off this x) moves left until it
		// clears them. Desktop builds without touch controls keep the original corner.
		settingsIconBg.x = FlxG.width - settingsIconBg.width - 20 - (virtualPad != null ? 100 : 0);
		groupHUD.add(settingsIconBg);

		settingsIcon = new FlxSprite(settingsIconBg.x, settingsIconBg.y);
		settingsIcon.antialiasing = ClientPrefs.data.globalAntialiasing;
		settingsIcon.frames = Paths.getSparrowAtlas('online_settings');
		settingsIcon.animation.addByPrefix('idle', "settings", 24);
		settingsIcon.animation.play('idle');
		settingsIcon.updateHitbox();
		settingsIcon.x += settingsIconBg.width / 2 - settingsIcon.width / 2;
		settingsIcon.y += settingsIconBg.height / 2 - settingsIcon.height / 2;
		settingsIcon.ID = 0;
		items.add(settingsIcon);

		chatIconBg = new FlxSprite();
		chatIconBg.makeGraphic(100, 100, TEXT_BG_COLOR);
		chatIconBg.updateHitbox();
		chatIconBg.y = settingsIconBg.y;
		chatIconBg.x = settingsIconBg.x - chatIconBg.width - 20;
		groupHUD.add(chatIconBg);

		chatIcon = new FlxSprite(chatIconBg.x, chatIconBg.y);
		chatIcon.antialiasing = ClientPrefs.data.globalAntialiasing;
		chatIcon.frames = Paths.getSparrowAtlas('online_chat');
		chatIcon.animation.addByPrefix('idle', "chat", 24);
		chatIcon.animation.play('idle');
		chatIcon.updateHitbox();
		chatIcon.x += chatIconBg.width / 2 - chatIcon.width / 2;
		chatIcon.y += chatIconBg.height / 2 - chatIcon.height / 2;
		chatIcon.ID = 1;
		items.add(chatIcon);

		playIconBg = new FlxSprite();
		playIconBg.makeGraphic(100, 100, TEXT_BG_COLOR);
		playIconBg.updateHitbox();
		playIconBg.y = chatIconBg.y;
		playIconBg.x = chatIconBg.x - playIconBg.width - 20;
		groupHUD.add(playIconBg);

		playIcon = new FlxSprite(playIconBg.x, playIconBg.y);
		playIcon.antialiasing = ClientPrefs.data.globalAntialiasing;
		playIcon.frames = Paths.getSparrowAtlas('online_play');
		playIcon.animation.addByPrefix('idle', "play", 24);
		playIcon.animation.play('idle');
		playIcon.updateHitbox();
		playIcon.x += playIconBg.width / 2 - playIcon.width / 2;
		playIcon.y += playIconBg.height / 2 - playIcon.height / 2;
		playIcon.ID = 2;
		items.add(playIcon);

		roomCode = new FlxText(0, 0, 0, OnlineLang.L('room.code', 'Room Code: ') + '????');
		roomCode.setFormat(OnlineLang.font(), 18, FlxColor.WHITE, RIGHT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		roomCode.x = settingsIconBg.x + settingsIconBg.width - roomCode.width;
		roomCode.y = settingsIconBg.y - roomCode.height - 10;
		roomCode.ID = 3;

		roomCodeBg = new FlxSprite();
		roomCodeBg.makeGraphic(1, 1, TEXT_BG_COLOR);
		roomCodeBg.updateHitbox();
		roomCodeBg.y = roomCode.y;
		roomCodeBg.x = roomCode.x;
		roomCodeBg.scale.set(roomCode.width, roomCode.height);
		roomCodeBg.updateHitbox();
		groupHUD.add(roomCodeBg);
		items.add(roomCode);

		songName = new FlxText(0, 0, 0, OnlineLang.L('room.song', 'Selected Song: ') + '????');
		songName.setFormat(OnlineLang.font(), 18, FlxColor.WHITE, RIGHT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		songName.x = roomCodeBg.x + roomCodeBg.width - songName.width;
		songName.y = roomCodeBg.y - songName.height - 10;
		songName.ID = 4;

		songNameBg = new FlxSprite();
		songNameBg.makeGraphic(1, 1, TEXT_BG_COLOR);
		songNameBg.updateHitbox();
		songNameBg.y = songName.y;
		songNameBg.x = songName.x;
		songNameBg.scale.set(songName.width, songName.height);
		songNameBg.updateHitbox();
		groupHUD.add(songNameBg);
		items.add(songName);

		verifyMod = new FlxText(0, 0, 0, "...");
		verifyMod.setFormat(OnlineLang.font(), 18, FlxColor.WHITE, RIGHT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		verifyMod.x = songNameBg.x + songNameBg.width - verifyMod.width;
		verifyMod.y = songNameBg.y - verifyMod.height - 10;
		verifyMod.ID = 5;

		verifyModBg = new FlxSprite();
		verifyModBg.makeGraphic(1, 1, TEXT_BG_COLOR);
		verifyModBg.updateHitbox();
		verifyModBg.y = verifyMod.y;
		verifyModBg.x = verifyMod.x;
		verifyModBg.scale.set(verifyMod.width, verifyMod.height);
		verifyModBg.updateHitbox();
		groupHUD.add(verifyModBg);
		items.add(verifyMod);

		groupHUD.add(items);

		itemTipBg = new FlxSprite(-1000);
		itemTipBg.makeGraphic(1, 1, TEXT_BG_COLOR);
		itemTipBg.updateHitbox();
		groupHUD.add(itemTipBg);

		itemTip = new FlxText(0, 0, 0, "...");
		itemTip.setFormat(OnlineLang.font(), 18, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		groupHUD.add(itemTip);

		groupHUD.add(leavePie = new LeavePie());

		add(groupHUD);
		
		updateTexts(true);

		// The pad itself was mounted at the top of create(); its camera is registered last so it
		// draws over the stage and the HUD.
		addPadCamera();

		FlxG.mouse.visible = true;
		FlxG.autoPause = false;

		verifyDownloadMod(false, true);
		checkStage();

		if (stage != null)
			stage.createPost();

		GameClient.send("status", "In the Lobby");

		registerMessages();
	}

	var hasStage:Bool = false;
	function checkStage() {
		if (!GameClient.isConnected()) {
			return;
		}

		if (GameClient.room.state.stageName == "") {
			hasStage = true;
			return;
		}

		if (FileSystem.exists(Paths.mods('${GameClient.room.state.stageMod}/stages/${GameClient.room.state.stageName}.json')) ||
			OpenFlAssets.exists(Paths.getPath('stages/${GameClient.room.state.stageName}.json'), TEXT)) {
			hasStage = true;
			return;
		}

		if (GameClient.room.state.stageURL != null) {
			hasStage = false;

			OnlineMods.downloadMod(GameClient.room.state.stageURL, false, (_) -> {
				if (destroyed)
					return;

				checkStage();
			});
		}
	}

	function checkNoteSkin(player:Player, ?manualDownload:Bool = false) {
		if (!FileSystem.exists(Paths.mods(player.noteSkinMod)) && player.noteSkinURL != null) {
			OnlineMods.downloadMod(player.noteSkinURL, manualDownload, function(_) {
				Mods.updatedOnState = false;
				Mods.parseList();
				Mods.pushGlobalMods();
			});

			if(!manualDownload && ClientPrefs.data.disableAutoDownloads) {
				chatBox.addNoteSkinDownloadMessage(function() {
					checkNoteSkin(player, true);
				});
			}
		}
	}

	override function openSubState(obj:FlxSubState) {
		obj.cameras = [camHUD];
		super.openSubState(obj);
	}

	override function closeSubState() {
		super.closeSubState();

		GameClient.send("status", "In the Lobby");
	}

	var optionShake:FlxTween;

	var elapsedShit = 3.;
	var lastFocused = false;
	var updateTimer = 1.0;

	/**
	 * `FlxG.mouse.overlaps(obj, camHUD)` is broken on flixel 4.11: FlxPointer.overlaps takes the
	 * pointer's world coords under `FlxG.camera` (this state's main `cum`, zoom 0.5 / scroll
	 * 200,130) and passes them as screen coords to overlapsPoint(..., InScreenSpace=true), while
	 * the object side converts via camHUD again; the double conversion shifts badly whenever
	 * zoom != 1. Hit-test with camHUD's own world coords instead (screen coords when zoom=1).
	 */
	function mouseOverlapsItem(obj:FlxSprite):Bool {
		if (obj == null || camHUD == null)
			return false;
		var point = FlxG.mouse.getWorldPosition(camHUD);
		var hit:Bool = obj.overlapsPoint(point, false);
		point.put();
		return hit;
	}

	/** Icon index under the pointer, or -1. Hover only reports it; the click selects it. */
	function itemUnderPointer():Int {
		if (mouseOverlapsItem(settingsIconBg))
			return settingsIcon.ID;
		if (mouseOverlapsItem(chatIconBg))
			return chatIcon.ID;
		if (mouseOverlapsItem(playIconBg))
			return playIcon.ID;
		// The three text rows are tested as text *and* as block: the block is a 1x1 sprite scaled
		// to the text, so before the share size is known it can be zero-height, and a row with a
		// zero-height block could not be clicked at all ("Selected Song" was one of them).
		if (mouseOverlapsItem(roomCodeBg) || mouseOverlapsItem(roomCode))
			return roomCode.ID;
		if (mouseOverlapsItem(songNameBg) || mouseOverlapsItem(songName))
			return songName.ID;
		if (mouseOverlapsItem(verifyModBg) || mouseOverlapsItem(verifyMod))
			return verifyMod.ID;
		return -1;
	}

	/**
	 * A long hold of ESC/BACK did not leave the room, and the earlier fix (`LeavePie.finished`
	 * reset + `leaveRoom(forceStateChange)`) did not help. This traces `pressed('back')` / global
	 * ESC / hold progress / connection into `logs/online_leave_trace.log` and falls back to a
	 * 0.65s hold of `FlxG.keys.pressed.ESCAPE/BACKSPACE` when LeavePie fails; it works even when
	 * getPlayerSelf() == null and RoomState.update returns early.
	 */
	function updateLeaveFallback(elapsed:Float):Void {
		if (leavePie == null)
			return;

		if (chatBox != null && chatBox.focused) {
			leaveHold = 0;
			return;
		}

		#if android
		// The engine never maps the Android back key onto controls.BACK, and the system back gesture
		// arrives as a quick press/release pair, so the hold below can never fill. Leave on release.
		if (FlxG.android.justReleased.BACK && !leaveFallbackFired) {
			leaveFallbackFired = true;
			GameClient.leaveTrace('FALLBACK leaveRoom (Android back)');
			GameClient.leaveRoom(null, true);
			return;
		}
		#end

		var controlsBack:Bool = controls.pressed('back') #if android || FlxG.android.pressed.BACK #end;
		var held:Bool = FlxG.keys.pressed.ESCAPE || FlxG.keys.pressed.BACKSPACE || controlsBack;

		leaveTraceTimer -= elapsed;
		if (held) {
			leaveHold += elapsed;

			if (leaveTraceTimer <= 0) {
				leaveTraceTimer = 0.25;
				GameClient.leaveTrace('hold: controlsBack=' + controlsBack
					+ ' esc=' + FlxG.keys.pressed.ESCAPE
					+ ' amount=' + leavePie.pieDial.amount
					+ ' hold=' + leaveHold
					+ ' connected=' + GameClient.isConnected()
					+ ' self=' + (GameClient.getPlayerSelf() != null));
			}

			// The 1.2s threshold is well past LeavePie's ~0.5s: if LeavePie works the state is
			// already destroyed and this never runs; if it does not, leave forcibly after 1.2s.
			if (leaveHold >= 1.2 && !leaveFallbackFired) {
				leaveFallbackFired = true;
				GameClient.leaveTrace('FALLBACK leaveRoom (long hold ESC/BACK)');
				GameClient.leaveRoom(null, true);
			}
		}
		else {
			leaveHold = 0;
			leaveFallbackFired = false;
		}
	}

    override function update(elapsed:Float) {
		// Fallback leave check runs first so it still fires when getPlayerSelf() == null returns early.
		updateLeaveFallback(elapsed);

		if (GameClient.getPlayerSelf() == null) {
			if (FlxG.keys.justPressed.ESCAPE) {
				GameClient.leaveRoom('Self not in the room (update).');
			}
			return;
		}

		super.update(elapsed);

		if (GameClient.getPlayerSelf() == null) {
			if (FlxG.keys.justPressed.ESCAPE) {
				GameClient.leaveRoom('Self not in the room (update).');
			}
			return;
		}

		// A dialog on top (room settings, the stage picker) owns the pointer and the keys. Without
		// this a pad tap or a click would also act on a lobby icon underneath.
		if (subState != null)
			return;

		if (FlxG.keys.justPressed.F11) {
			GameClient.reconnect();
		}

		#if lumod
		if (FlxG.keys.justPressed.F12) {
			trace('reloading lumod');
			// Lumod.storage.scripts.clear();
			lmLoad();
		}
		#end

		if (lastFocused != (chatBox.focused && chatBox.typeText.text.length > 0)) {
			if (!lastFocused) // is now typing
				GameClient.send("status", "Typing...");
			else
				GameClient.send("status", "In the Lobby");
		}

		lastFocused = chatBox.focused && chatBox.typeText.text.length > 0;

		// Every frame, not only on the 5-second refresh: the rows are stacked off live text
		// heights and their hit blocks hang off that geometry (see layoutTextStack).
		layoutTextStack();

		updateTimer -= elapsed;
		if (updateTimer <= 0) {
			updateTimer = 5.0;

			var sumReceivedBytes = 0.0;
			var sumContentLength = 0.0;
			for (down in ModDownloader.downloaders) {
				// Haxe 4.2.5 has no safe-navigation; `down?.client` is expanded to null checks.
				if (down != null && down.client != null && down.status == READING_BODY) {
					sumReceivedBytes += down.client.receivedBytes;
					sumContentLength += down.client.contentLength;
				}
			}

			if (sumContentLength > 0) {
				GameClient.send("status", 'Downloading (${Math.floor(sumReceivedBytes / sumContentLength * 100)}%)');
			}
			else {
				if (lastFocused)
					GameClient.send("status", "Typing...");
				else
					GameClient.send("status", "In the Lobby");
			}
		}
		
		// if (FlxG.keys.justPressed.SPACE) {
		// 	Alert.alert("Camera Location:", '${cum.scroll.x},${cum.scroll.y} x ${cum.zoom}');
		// }
		// if (FlxG.keys.pressed.U) {
		// 	cum.zoom -= elapsed * 0.5;
		// }
		// if (FlxG.keys.pressed.O) {
		// 	cum.zoom += elapsed * 0.5;
		// }
		// if (FlxG.keys.pressed.I) {
		// 	cum.scroll.y -= elapsed * 20;
		// }
		// if (FlxG.keys.pressed.J) {
		// 	cum.scroll.x -= elapsed * 20;
		// }
		// if (FlxG.keys.pressed.K) {
		// 	cum.scroll.y += elapsed * 20;
		// }
		// if (FlxG.keys.pressed.L) {
		// 	cum.scroll.x += elapsed * 20;
		// }

		#if DISCORD_ALLOWED
		elapsedShit += elapsed;

		if (elapsedShit >= 3) {
			elapsedShit = 0;
			DiscordClient.updateOnlinePresence();
		}
		#end

		for (item in items) {
			if (curSelected == item.ID) {
				if (item == settingsIcon)
					item.angle += 20 * elapsed;
				else if (item == chatIcon)
					item.angle = FlxMath.lerp(item.angle, 20, elapsed * 5);

				if (item == playIcon) {
					if (GameClient.getPlayerSelf().hasSong) {
						item.scale.set(FlxMath.lerp(item.scale.x, 1.2, elapsed * 10), FlxMath.lerp(item.scale.y, 1.2, elapsed * 10));
					}
					else {
						item.scale.set(FlxMath.lerp(item.scale.x, 1.05, elapsed * 10), FlxMath.lerp(item.scale.y, 1.05, elapsed * 10));
					}
				}
				else
					item.scale.set(FlxMath.lerp(item.scale.x, 1.1, elapsed * 10), FlxMath.lerp(item.scale.y, 1.1, elapsed * 10));
			}
			else if (hoverIndex == item.ID) {
				// Hovered but not selected: a gentler version of the selection pop, so the two
				// states stay tellable apart.
				item.angle = FlxMath.lerp(item.angle, 0, elapsed * 5);
				item.scale.set(FlxMath.lerp(item.scale.x, 1.05, elapsed * 10), FlxMath.lerp(item.scale.y, 1.05, elapsed * 10));
			}
			else {
				item.angle = FlxMath.lerp(item.angle, 0, elapsed * 5);
				item.scale.set(FlxMath.lerp(item.scale.x, 1, elapsed * 10), FlxMath.lerp(item.scale.y, 1, elapsed * 10));
			}
		}
		playIcon.alpha = GameClient.getPlayerSelf().hasSong ? 1.0 : 0.5;

		// The chat box owns the pointer while it is focused; drop any leftover highlight then.
		hoverIndex = -1;

		if (!chatBox.focused) {
			// A tap that lands on the on-screen pad belongs to the pad, never to an icon behind it.
			var padTap = OnlineNav.padBlocks(virtualPad);
			var pointerClick = FlxG.mouse.justPressed && !padTap;

			// Hover only lights the icon up. Moving the pointer no longer takes the selection away
			// from the keyboard, which is what made this screen unusable on a touchscreen.
			hoverIndex = padTap ? -1 : itemUnderPointer();

			var held = false;
			for (key in ['note_left', 'note_down', 'note_up', 'note_right']) {
				if (controls.pressed(key)) {
					held = true;
					break;
				}
			}
			playerHold = held;

			// trace('playerHold = ' + playerHold + ', oppHold = ' + oppHold);

			if (FlxG.keys.pressed.ALT) { // useless, but why not?
				var suffix = FlxG.keys.pressed.CONTROL ? 'miss' : '';
				if (controls.NOTE_LEFT_P) {
					playerAnim('singLEFT' + suffix);
				}
				if (controls.NOTE_RIGHT_P) {
					playerAnim('singRIGHT' + suffix);
				}
				if (controls.NOTE_UP_P) {
					playerAnim('singUP' + suffix);
				}
				if (controls.NOTE_DOWN_P) {
					playerAnim('singDOWN' + suffix);
				}
				if (controls.TAUNT) {
					var altSuffix = FlxG.keys.pressed.SHIFT ? '-alt' : '';
					playerAnim('taunt' + altSuffix);
				}
			} else {
				// Wheel + keyboard walk the icon ring, with hold-to-repeat. LEFT/UP step one way
				// and RIGHT/DOWN the other; NavRepeat reports "up" as -1, so the sign flips here.
				// (This screen has no d-pad: the icons themselves are the touch target.)
				var prevHeld = controls.UI_LEFT || controls.UI_UP;
				var nextHeld = controls.UI_RIGHT || controls.UI_DOWN;
				var steps = -nav.poll(prevHeld, nextHeld, elapsed) + FlxG.mouse.wheel;
				while (steps != 0) {
					var dir = steps > 0 ? 1 : -1;
					changeSelection(dir);
					steps -= dir;
				}
				if (FlxG.keys.pressed.CONTROL && FlxG.keys.justPressed.C) {
					Clipboard.text = GameClient.getRoomSecret(true);
					Alert.alert(OnlineLang.L('room.codeCopied', 'Room code copied!'));
				}

				if (FlxG.keys.justPressed.SHIFT) {
					openSubState(new RoomSettingsSubstate());
				}
			}
			
			// A click selects the icon it hit first, then runs it; clicking empty space does nothing.
			if ((!FlxG.keys.pressed.ALT && controls.ACCEPT) || (pointerClick && hoverIndex >= 0)) {
				if (pointerClick)
					curSelected = hoverIndex;
				switch (curSelected) {
					case 0:
						openSubState(new RoomSettingsSubstate());
					case 1:
						chatBox.focused = true;
					case 2:
						var selfPlayer:Player = GameClient.getPlayerSelf();

						if (!selfPlayer.hasSong && GameClient.room.state.song != "" && (Mods.getModDirectories().contains(GameClient.room.state.modDir) || GameClient.room.state.modDir == "")) {
							Mods.currentModDirectory = GameClient.room.state.modDir;
							if (GameClient.chartIsSegmented(GameClient.room.state.song, GameClient.room.state.folder, GameClient.room.state.modDir)) {
								// Segmented chart: no one-file chart to hash, so say why the play button refuses
								// instead of letting hashRawSong throw (or, worse, verifying nothing at all).
								GameClient.refuseSegmentedChart();
								if (optionShake != null)
									optionShake.cancel();
								optionShake = ShitUtil.shake(playIcon, 0.05, 0.3, FlxAxes.X);
							}
							else {
								try {
									GameClient.send("verifyChart", Song.hashRawSong(GameClient.room.state.song, GameClient.room.state.folder));
								}
								catch (exc) {
									Alert.alert(OnlineLang.L('room.exception', 'Caught an exception!'), ShitUtil.readableError(exc));
									if (optionShake != null)
										optionShake.cancel();
									optionShake = ShitUtil.shake(playIcon, 0.05, 0.3, FlxAxes.X);
								}
							}
						}
						else if (selfPlayer.hasSong) {
							checkStage();

							if (!hasStage) {
								Alert.alert(OnlineLang.L('room.noStage', "You don't have the current stage!"));
							}
							else {
								GameClient.send("startGame");
							}
						}
						else {
							if (GameClient.room.state.song == "") {
								Alert.alert(OnlineLang.L('room.noSong', "Song isn't selected!"));
							}
							else {
								Alert.alert(OnlineLang.L('room.noSongMod', "You don't have the current song/mod!"));
							}
							var sond = FlxG.sound.play(Paths.sound('badnoise' + FlxG.random.int(1, 3)));
							sond.pitch = 1.1;
							if (optionShake != null)
								optionShake.cancel();
							optionShake = ShitUtil.shake(playIcon, 0.05, 0.3, FlxAxes.X);
						}
					case 3:
						// The room code is always shown now (see the first refresh in updateTexts); this item
						// only copies it to the clipboard and alerts.
						Clipboard.text = GameClient.getRoomSecret(true);
						Alert.alert(OnlineLang.L('room.codeCopied', 'Room code copied!'));
					case 4:
						if (GameClient.hasPerms() || GameClient.room.state.allPlayersChoose) {
							FlxG.switchState(new FreeplayState());
							FlxG.mouse.visible = false;
						}
						else {
							Alert.alert(OnlineLang.L('room.hostOnly', 'Only the host can do that!'));
							var sond = FlxG.sound.play(Paths.sound('badnoise' + FlxG.random.int(1, 3)));
							sond.pitch = 1.1;
							if (optionShake != null)
								optionShake.cancel();
							optionShake = ShitUtil.shake(songName, 0.05, 0.3, FlxAxes.X);
						}
					case 5:
						if (verifyDownloadMod(true)) {
							FlxG.switchState(new DownloaderState());
						}
				}
			}
			else if (FlxG.mouse.justPressedRight && !padTap) {
				if (curSelected == 5) {
					FlxG.switchState(new DownloaderState());
				}
			}
		}

		if (FlxG.sound.music != null)
			Conductor.songPosition = FlxG.sound.music.time;
    }
	
	function verifyDownloadMod(manual:Bool, ?ignoreAlert:Bool = false) {
		try {
			trace(GameClient.getPlayerSelf().hasSong, GameClient.room.state.song, GameClient.room.state.modDir);
			if (GameClient.room.state.song == "") {
				if (ignoreAlert)
					return false;

				if (GameClient.hasPerms())
					return true;

				Alert.alert(OnlineLang.L('room.noSong', "Song isn't selected!"));
				var sond = FlxG.sound.play(Paths.sound('badnoise' + FlxG.random.int(1, 3)));
				sond.pitch = 1.1;
				if (optionShake != null)
					optionShake.cancel();
				optionShake = ShitUtil.shake(verifyMod, 0.05, 0.3, FlxAxes.X);
				return false;
			}
			if (GameClient.getPlayerSelf().hasSong) {
				if (ignoreAlert)
					return false;

				if (GameClient.hasPerms())
					return true;

				Alert.alert(OnlineLang.L('room.songInstalled', 'You already have this song installed!'));
				var sond = FlxG.sound.play(Paths.sound('badnoise' + FlxG.random.int(1, 3)));
				sond.pitch = 1.1;
				if (optionShake != null)
					optionShake.cancel();
				optionShake = ShitUtil.shake(verifyMod, 0.05, 0.3, FlxAxes.X);
				return false;
			}

			if (Mods.getModDirectories().contains(GameClient.room.state.modDir) || GameClient.room.state.modDir == null || GameClient.room.state.modDir == "") {
				Mods.currentModDirectory = GameClient.room.state.modDir;
				if (GameClient.chartIsSegmented(GameClient.room.state.song, GameClient.room.state.folder, GameClient.room.state.modDir)) {
					// The background callers pass ignoreAlert; only the verify button raises the popup.
					if (!ignoreAlert)
						GameClient.refuseSegmentedChart();
					return false;
				}
				try {
					GameClient.send("verifyChart", Song.hashRawSong(GameClient.room.state.song, GameClient.room.state.folder));
					return false;
				}
				catch (exc) {
					// Used to be silent: the verify button could do nothing and say nothing.
					if (!ignoreAlert)
						GameClient.refuseUnhashableChart(exc);
				}
			}

			if (GameClient.room.state.modDir != null && GameClient.room.state.modURL != null && GameClient.room.state.modURL != "") {
				var daModURL = GameClient.room.state.modURL;
				OnlineMods.downloadMod(daModURL, manual, (mod) -> {
					if (GameClient.isConnected())
						GameClient.send("notifyInstall", daModURL);

					if (destroyed)
						return;

					if (GameClient.isConnected() && GameClient.room.state.modDir == mod) {
						if (Mods.getModDirectories().contains(GameClient.room.state.modDir)) {
							Mods.currentModDirectory = GameClient.room.state.modDir;
							// This runs in the async download callback: an exception here has no caller left
							// to catch it, so it is handled inside -- otherwise the hash is lost silently and
							// the room waits for hasSong forever.
							try {
								if (GameClient.chartIsSegmented(GameClient.room.state.song, GameClient.room.state.folder, GameClient.room.state.modDir)) {
									GameClient.refuseSegmentedChart();
								}
								else {
									GameClient.send("verifyChart", Song.hashRawSong(GameClient.room.state.song, GameClient.room.state.folder));
								}
							}
							catch (exc:Dynamic) {
								Sys.println(exc);
								GameClient.refuseUnhashableChart(exc);
							}
						}
					}
				});
			}
			else if (!ignoreAlert) {
				if (GameClient.room.state.modURL == null || GameClient.room.state.modURL == "") {
					Alert.alert(OnlineLang.L('room.modNotFound', "Mod couldn't be found!"), OnlineLang.L('room.modNoURL', "Host didn't specify the URL of this mod"));
				}
				else if (Mods.getModDirectories().contains(GameClient.room.state.modDir)) {
					// Haxe 4.2.5 has no `??`; expand `modDir ?? "mods/"` to an explicit null check.
			var modDir:String = GameClient.room.state.modDir;
			if (modDir == null)
				modDir = "mods/";
			Alert.alert(OnlineLang.L('room.modNotFound', "Mod couldn't be found!"), OnlineLang.L('room.modExpectedPath', 'Expected mod data to exist in this path: ') + modDir);
				}
				var sond = FlxG.sound.play(Paths.sound('badnoise' + FlxG.random.int(1, 3)));
				sond.pitch = 1.1;
				if (optionShake != null)
					optionShake.cancel();
				optionShake = ShitUtil.shake(verifyMod, 0.05, 0.3, FlxAxes.X);
			}
		}
		catch (exc) {
			Sys.println(exc);
		}

		return false;
	}

	var _textsInit = false;
	/** The room code is filled once, on the first room state. */
	var _roomCodeShown = false;

	/** Write the room-code text; layoutTextStack() sizes and places its block. */
	function setRoomCodeText(text:String):Void {
		roomCode.text = text;
	}

	/**
	 * Re-stacks the three right-aligned rows (mod / song / room code) and their blocks.
	 *
	 * This runs every frame. The rows hang off each other's *live* heights, and each block is a
	 * 1x1 sprite scaled to its text, so sizing them only on the 5-second refresh read heights from
	 * before the text had ever regenerated: the rows ended up overlapping, and a block that came
	 * out zero-high made its row impossible to click.
	 */
	function layoutTextStack():Void {
		if (roomCodeBg == null || songNameBg == null || verifyModBg == null)
			return;

		stackRow(roomCode, roomCodeBg, null);
		stackRow(songName, songNameBg, roomCodeBg);
		stackRow(verifyMod, verifyModBg, songNameBg);
	}

	/** Sizes one right-aligned row and its block, and stacks it directly above "below". */
	function stackRow(text:FlxText, bg:FlxSprite, ?below:FlxSprite):Void {
		if (text == null || bg == null)
			return;

		// updateHitbox() regenerates the text first, so width/height describe what is drawn.
		// Measure at scale 1: the hover animation scales these rows, and baking that into the box
		// would move the row out from under the pointer that just hovered it.
		var sx:Float = text.scale.x;
		var sy:Float = text.scale.y;
		text.scale.set(1, 1);
		text.updateHitbox();
		text.scale.set(sx, sy);

		text.x = settingsIconBg.x + settingsIconBg.width - text.width;
		text.y = (below == null ? settingsIconBg.y : below.y) - text.height - 10;

		bg.scale.set(Math.max(1, text.width), Math.max(1, text.height));
		bg.updateHitbox();
		bg.setPosition(text.x, text.y);
	}

    function updateTexts(?init:Bool = false) {
		if (init)
			_textsInit = true;

		if (destroyed || GameClient.room == null || !_textsInit)
			return;

		var selfPlayer:Player = GameClient.getPlayerSelf();
		if (selfPlayer == null)
			return;

		// Showing the room code only when the code item was clicked (case 3 below) would leave
		// left the placeholder `Room Code: ????` otherwise, so players could not read or report
		// it. Show it permanently from the first room state; clicking still copies.
		if (!_roomCodeShown) {
			_roomCodeShown = true;
			setRoomCodeText(OnlineLang.L('room.code', 'Room Code: ') + '"' + GameClient.getRoomSecret() + '"');
		}
		
		// Haxe 4.2.5 has no `??`; expand `modDir ?? ""` to an explicit null check.
		var modDirRaw:String = GameClient.room.state.modDir;
		var daModName = modDirRaw != null ? modDirRaw : "";
		if (daModName.length > 30) {
			daModName = daModName.substr(0, 30) + "...";
		}

		if (daModName == "" || GameClient.room.state.song == "") {
			verifyMod.text = OnlineLang.L('room.noChosenMod', 'No chosen mod.');
		}
		else if (selfPlayer.hasSong) {
			verifyMod.text = OnlineLang.L('room.mod', 'Mod: ') + daModName;
		}
		else {
			if (GameClient.room.state.modURL == null || GameClient.room.state.modURL == "")
				verifyMod.text = OnlineLang.L('room.modUnknown', 'No mod named: ') + daModName + OnlineLang.L('room.modUnknown.tail', " (Unknown; Host didn't specify mod's URL)");
			else 
				verifyMod.text = OnlineLang.L('room.modUnknown', 'No mod named: ') + daModName + OnlineLang.L('room.modVerify.tail', ' (Download/Verify it here!)');
		}

		songName.text = OnlineLang.L('room.song', 'Selected Song: ') + GameClient.room.state.song;
		if (GameClient.room.state.song == null || GameClient.room.state.song.trim() == "")
			songName.text += OnlineLang.L('room.songNone', '(None)');
		else if (!selfPlayer.hasSong)
			songName.text += OnlineLang.L('room.songNotFound', ' (Not found!)');
		layoutTextStack();

		updateCharacters();

		switch (curSelected) {
			case 0:
				itemTip.text = OnlineLang.L('room.tip.settings', " - SETTINGS - \nOpens server settings.\n\n(Keybind: SHIFT)");
			case 1:
				itemTip.text = OnlineLang.L('room.tip.chat', " - CHAT - \nOpens chat.\n\n(Keybind: TAB)");
			case 2:
				itemTip.text = OnlineLang.L('room.tip.ready', " - START GAME/READY - \nToggles your READY status.\n\nPlayers also need to have the\ncurrently selected mod installed.\n\n(Both sides can only\nhave up to 2 players).");
			case 3:
				itemTip.text = OnlineLang.L('room.tip.code', " - ROOM CODE - \nUnique code of this room.\n\nACCEPT - Reveals the code and\ncopies it to your clipboard.\n\nCTRL + C - Copies the code without\nrevealing it on the screen.");
			case 4:
				itemTip.text = OnlineLang.L('room.tip.song', " - SELECT SONG - \nSelects the song.\n\n(Players with host permissions\ncan only do that)");
			case 5:
				itemTip.text = OnlineLang.L('room.tip.mod', " - MOD - \nDownloads the currently selected mod\nif it isn't installed.\n\nAfter you install it\npress this button again!\n\nRIGHT CLICK - Open Mod Downloader");
			default:
				itemTip.text = OnlineLang.L('room.tip.lobby', " - LOBBY - \nPress UI keybinds\nor use your mouse\nto select an option!");
		}

		itemTip.x = settingsIconBg.x + settingsIconBg.width - itemTip.width;
		itemTip.y = verifyMod.y - itemTip.height - 20;
		itemTipBg.x = itemTip.x;
		itemTipBg.y = itemTip.y;
		itemTipBg.scale.set(itemTip.width, itemTip.height);
		itemTipBg.updateHitbox();
    }

	// @interpret
	function updateCharacters() {
		if (destroyed)
			return;

		// var sides = [0, 0];
		var maxOffset = 0.;
		for (character in characters) {
			character.character.ox = character.player.ox;
			character.repos();
			character.updatePlayerText();

			maxOffset = Math.max(maxOffset, character.character.ox);

			// sides[character.player.bfSide ? 1 : 0]++;
		}

		charactersLayer.members.sort(sortByOX);

		funnyMode = Std.int(maxOffset);

		//cum.zoom = 0.9 - (maxOffset * 0.1);
	}
	
	function sortByOX(a:LobbyCharacter, b:LobbyCharacter) {
		if (a == null || b == null) return 0;
		return b.character.ox - a.character.ox;
	}

	function changeSelection(diffe:Int) {
		curSelected += diffe;

		if (curSelected >= items.length) {
			curSelected = 0;
		}
		else if (curSelected < 0) {
			curSelected = items.length - 1;
		}
	}

	static function playMusic(value:Bool) {
		FreeplayState.destroyFreeplayVocals();

		var room = GameClient.room;
		if (value && room != null && room.state != null) {
			// The server can report hasSong = true with song = "" (older servers set verifyChart
			// unconditionally); that used to call loadSong("", "") and fail with
			// "Missing file: assets/data//.json". Alert and play lobby music when no song exists.
			var song:String = room.state.song;
			if (song == null || song.trim() == "") {
				online.gui.Alert.alert(OnlineLang.L('room.noSong', "Song isn't selected!"));
			}
			else {
				try {
					// Switch the asset directory to the song's mod instead of falling back to assets/weekX.
					// Only when the mod is actually installed; otherwise stay shared.
					var modDir:String = room.state.modDir;
					if (modDir != null && modDir != "" && Mods.getModDirectories().contains(modDir))
						Mods.currentModDirectory = modDir;
					else
						Mods.currentModDirectory = "";

					Difficulty.list = CoolUtil.asta(room.state.diffList);
					PlayState.loadSong(song, room.state.folder);

					var diff = Difficulty.getString(room.state.diff);
					var trackSuffix = diff == "Erect" || diff == "Nightmare" ? "-erect" : "";

					FlxG.sound.playMusic(Paths.inst(PlayState.SONG.song, trackSuffix), 0.5);
					Conductor.mapBPMChanges(PlayState.SONG);
					Conductor.bpm = PlayState.SONG.bpm;
					return;
				}
				catch (exc) {
					trace(exc);
				}
			}
		}

		states.TitleState.playFreakyMusic(0.5);
		Conductor.bpm = 102;
	}

	public function getCharacterSelf() {
		return characters.get(GameClient.room.sessionId).character;
	}

	function playerAnim(anim:String, ?sid:String) {
		if (destroyed)
			return;
		
		// Haxe 4.2.5 has no `??`; use an explicit null check for sid.
		var character = characters.get(sid != null ? sid : GameClient.room.sessionId);
		if (character == null)
			return;
		
		character.character.playAnim(anim, true);
		if (anim.endsWith('miss'))
			var sond = FlxG.sound.play(Paths.sound('missnote' + FlxG.random.int(1, 3)), 0.25);

		if (sid == null) {
			GameClient.send("charPlay", [anim]);
		}
	}

	override function beatHit() {
		updateTexts();

		for (sid => character in characters) {
			character.danceLogic(curBeat);
		}

		// There is no `MusicBeatState.stages` array to fan `beatHit()` out to, so the stage's
		// `beat` counter is assigned and its `beatHit()` invoked explicitly here. This keeps
		// the lobby stage's light changes in sync with the room.
		if (stage != null) {
			stage.beat = curBeat;
			stage.beatHit();
		}

		super.beatHit();
	}
}

#if lumod
@:build(lumod.LuaScriptClass.build())
#end
class LobbyCharacter extends FlxTypedGroup<FlxSprite> {
	/** Ping is a Float (ms); the profile card wants an integer, not 12.345678901234. */
	static function pingMs(v:Dynamic):String {
		if (v == null) return "?";
		var f:Float = Std.parseFloat(Std.string(v));
		return Math.isNaN(f) ? "?" : Std.string(Math.round(f));
	}

	public var player:Player;
	public var character:Character;
	public var profileBox:ProfileBox;
	public var noSkin:Bool = false;
	var dlSkinTxt:FlxText;
	public var profileBoxXOffset:Float = 400;
	public var profileBoxXOffsetP2:Float = 100;
	public var profileBoxYOffset:Float = 50;
	public var xBoxStepOffset:Float = 450;
	public var yBoxStepOffset:Float = 150;
	public var xCharStepOffset:Float = 400;
	public var charOffsetX:Float = 0;

	public function new(player:Player, ?camHUD:FlxCamera, ?isVerified:Bool = false, ?sizeAdd:Int = 12) {
		super();

		this.player = player;
	
		profileBox = new ProfileBox(isVerified ? player.name : null, isVerified, 50, sizeAdd);
		profileBox.autoUpdateThings = false;
		profileBox.autoCardHeight = true;
		profileBox.avatarMaxSize = 100;
		profileBox.text.text = player.name;
		profileBox.setPosition(0, profileBoxYOffset);
		//if (camHUD != null)
		//	profileBox.camera = camHUD;
		add(profileBox);

		dlSkinTxt = new FlxText(0, 0, 0, OnlineLang.L('room.downloadSkin', 'DOWNLOAD SKIN'));
		dlSkinTxt.setFormat(OnlineLang.font(), 18, FlxColor.WHITE, RIGHT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);

		loadCharacter();
	}

	var _prevNoSkin:Bool = false;
	var _changedNoSkin:Bool = false;

	override function update(elapsed:Float) {
		super.update(elapsed);

		_changedNoSkin = _prevNoSkin != noSkin;
		_prevNoSkin = noSkin;

		if (noSkin) {
			if (_changedNoSkin) {
				character.colorTransform.redOffset = -255;
				character.colorTransform.greenOffset = -255;
				character.colorTransform.blueOffset = -255;
				character.alpha = 0.5;
				add(dlSkinTxt);
			}

			dlSkinTxt.setPosition(
				character.x + character.width / 2 - dlSkinTxt.width / 2, 
				character.y + character.height / 2 - dlSkinTxt.height / 2
			);

			if (FlxG.mouse.justPressed && FlxG.mouse.overlaps(character, character.camera))
				loadCharacter(true, true);
		}
		else if (_changedNoSkin) {
			character.colorTransform.redOffset = 0;
			character.colorTransform.greenOffset = 0;
			character.colorTransform.blueOffset = 0;
			character.alpha = 1;
			remove(dlSkinTxt);
		}

		danceLogic();
	}

	var yellowMarker:FlxTextFormatMarkerPair;
	var pingMarker:FlxTextFormatMarkerPair;

	public function updatePlayerText() {
		if (yellowMarker == null)
			yellowMarker = new FlxTextFormatMarkerPair(new FlxTextFormat(FlxColor.YELLOW), "<y>");
		if (pingMarker == null)
			pingMarker = new FlxTextFormatMarkerPair(new FlxTextFormat(FlxColor.GREEN), "<p>");

		@:privateAccess
		pingMarker.format.format.color = FlxColor.interpolate(FlxColor.fromString("#00ff00"), FlxColor.fromString("#ff0000"), player.ping / 400);

		if (profileBox.user != player.name) {
			profileBox.updateData(player.name, player.verified);
		}

		profileBox.text.clearFormats();

		// The club name is reached with safe-navigation inside one expression
		// (`profileBox?.profileData?.club != null`); Haxe 4.2.5 needs explicit null checks here.
		var selfName:String = player.name;
		if (player.verified) {
			var clubSuffix:String = '';
			if (profileBox != null && profileBox.profileData != null && profileBox.profileData.club != null)
				clubSuffix = ' [${profileBox.profileData.club}]';
			selfName = '<y>${player.name + clubSuffix}<y>';
		}

		profileBox.text.applyMarkup(
		selfName
		, [yellowMarker]);

		profileBox.desc.applyMarkup(
			(player.verified && profileBox.profileData != null ? 
				FlxStringUtil.formatMoney(player.points, false) + 'FP (' + ShitUtil.toOrdinalNumber(profileBox.profileData.rank) + ")\n"
			 : "") +
			OnlineLang.L('room.ping', 'Ping: ') + "<p>" + pingMs(player.ping) + "ms<p>\n\n" +
			player.status + "\n" +
			(!player.isReady ? OnlineLang.L('room.not', 'NOT ') : "") + OnlineLang.L('room.ready', 'READY') +
			(noSkin ? OnlineLang.L('room.unloadedSkin', '\n(Unloaded Skin)') : "")
		, [pingMarker]);

		profileBox.updatePositions();
	}

	public function danceLogic(?curBeat:Null<Int>) {
		if (player.isReady)
			return;
		
		if (character != null && character.animation.curAnim != null) {
			if (curBeat != null) {
				if (curBeat % character.danceEveryNumBeats == 0 && !character.animation.curAnim.name.startsWith('sing'))
					character.dance();
			}
			else {
				if (!(character.animation.curAnim.name.endsWith('miss') || character.isMissing)
						&& !player.noteHold
						&& character.holdTimer > Conductor.stepCrochet * (0.0011 / FlxG.sound.music.pitch) * character.singDuration
						&& character.animation.curAnim.name.startsWith('sing')
						&& !(character.animation.curAnim.name.endsWith('miss') || character.isMissing))
					character.dance();
			}
		}
	}

	public function loadCharacter(?enableDownload:Bool = true, ?manualDownload:Bool = false) {
		if (character != null) {
			remove(character);
			character.destroy();
			character = null;
		}

		if (player.skin.length > 0) {
			online.util.ShitUtil.tempSwitchMod(player.skin.items[3], () -> {
				character = new Character(0, 0, player.skin.items[0] + player.skin.items[player.bfSide ? 2 : 1], player.bfSide);
			});

			if (character != null && character.loadFailed && enableDownload && player.skinURL != null) {
				OnlineMods.downloadMod(player.skinURL, manualDownload, (_) -> {
					if (RoomState.instance == null || RoomState.instance.destroyed)
						return;

					loadCharacter(false);
				});
			}
			noSkin = character == null || character.loadFailed;
		}
		else {
			noSkin = false;
		}

		if (character == null || character.loadFailed) {
			character = new Character(0, 0, "bf" + (player.bfSide ? "" : '-opponent'), player.bfSide);
		}

		character.noHoldBullshit = true;
		add(character);

		remove(profileBox, true);
		insert(members.indexOf(character) + 1, profileBox);

		_bfSide = player.bfSide;

		repos();
	}

	var _bfSide = false;

	// var _charCamPos = FlxPoint.get();

	public function repos() {
		if (_bfSide != player.bfSide) {
			loadCharacter(false);
		}
		_bfSide = player.bfSide;

		// left side
		if (!player.bfSide) {
			character.x = charOffsetX + 200 + character.positionArray[0] - character.ox * xCharStepOffset;
			character.y = 120 + character.positionArray[1];
			profileBox.x = profileBoxXOffset - profileBox.width / 2 - character.ox * xBoxStepOffset;
		}
		// right side
		else {
			character.x = charOffsetX + 700 + character.positionArray[0] + character.ox * xCharStepOffset;
			character.y = 120 + character.positionArray[1];
			profileBox.x = profileBoxXOffsetP2 + FlxG.width - profileBoxXOffset - profileBox.width / 2 + character.ox * xBoxStepOffset;
		}
		// character.getScreenPosition(_charCamPos, profileBox.camera);
		// profileBox.x = _charCamPos.x + character.width / 2 * character.camera.zoom - profileBox.width / 2; 
		// profileBox.y = profileBoxYOffset + character.ox * yBoxStepOffset;
		// profileBox.x = character.x + character.width / 2 - profileBox.width / 2;
		profileBox.y = 100;
	}
}

/**
 * `LobbyStage` extends `FlxGroup` directly. There is no JSON-driven stage base class
 * (nothing that pushes into `MusicBeatState.stages` or provides `createPost()`,
 * `beatHit()`, `game`), and the stage generation differs:
 * `StageBackdrop` extends nothing, `StageFile` (source/StageData.hx:16) has no `objects` field,
 * `addObjectsToState`/`dummy`/`reservedNames` do not exist, and there is no
 * `assets/preload/stages/lobby.json`. The class is therefore self-contained (`FlxGroup`)
 * instead of growing a general-purpose objects loader in the stage core.
 *
 * Sprites in JSON order (scroll factors): sky(-1585,-526,1,1), city(-1399,-100,.9,1),
 * window(-1131,69,.9,1), behindTrain(-94,-42,1,1), street(-1268,-44,1,1); `train` is skipped
 * via `ignoreNames`. Only `window` is read back; the others are the drawn backdrop.
 *
 * Dropped, behaviour-neutral: `var phillyTrain:PhillyTrain` and its `beatHit(curBeat)` call
 * (its only assignment site is commented out, so it was always a null no-op).
 * Assets live in `assets/shared/images/lobby/` where `Paths.image()` looks them up.
 */
class LobbyStage extends FlxGroup {
	// `phillyTrain` is not declared; see the class comment.
	var phillyWindow:FlxSprite;
	var curLight:Int = 0;
	var phillyLightsColors:Array<FlxColor> = [0xFF31A2FD, 0xFF31FD8C, 0xFFFB33F5, 0xFFFD4531, 0xFFFBA633];

	public function new() {
		super();
		create();
	}

	/** Equivalent of `StageData.addObjectsToState(stageData.objects, ..., ignoreNames: ['train'])`. */
	function makeSprite(image:String, x:Float, y:Float, scrollX:Float, scrollY:Float):FlxSprite {
		var spr = new BGSprite('lobby/$image', x, y, scrollX, scrollY);
		add(spr);
		return spr;
	}

	/** Stage setup; called from `new()`. */
	function create() {
		// `lobby.json` declares `"directory": "week3"`; `Paths.setCurrentLevel()` applies it and
		// it is what the online character skins are loaded against.
		Paths.setCurrentLevel('week3');

		makeSprite('sky', -1585, -526, 1, 1);
		makeSprite('city', -1399, -100, 0.9, 1);
		phillyWindow = makeSprite('window', -1131, 69, 0.9, 1);
		makeSprite('behindTrain', -94, -42, 1, 1);
		// `train` is excluded (`ignoreNames: ['train']`), and its only purpose was the
		// commented-out `PhillyTrain` field, so it is not created here either.
		makeSprite('street', -1268, -44, 1, 1);

		phillyWindow.alpha = 0;
	}

	/** Called by `RoomState.create()` right after this is added. */
	public function createPost() {}

	override function update(elapsed:Float) {
		super.update(elapsed);

		if (phillyWindow != null) {
			phillyWindow.alpha -= (Conductor.crochet / 1000) * FlxG.elapsed * 1.5;
		}
	}

	public function beatHit() {
		// `phillyTrain.beatHit(curBeat)` is not called here (see the class comment).
		// `curBeat % 4` reads the beat counter that is pushed in by `RoomState.beatHit()`;
		// there is no stages fan-out, so the value is set explicitly.
		if (phillyWindow != null) {
			if (beat % 4 == 0) {
				curLight = FlxG.random.int(0, phillyLightsColors.length - 1, [curLight]);
				phillyWindow.color = phillyLightsColors[curLight];
				phillyWindow.alpha = 1;
			}
		}
	}

	/** Beat counter fed by `RoomState.beatHit()`. */
	public var beat:Int = 0;
}