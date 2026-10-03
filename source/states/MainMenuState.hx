package states;

import backend.Dialog;
import backend.seiun.ui.*;
import script.lua.FunkinLua;
import options.OptionsState;
import substates.ModSelectSubstate;
import states.ModState;
import backend.ModConfig;
import backend.CompatEngine;
#if cpp
import Discord.DiscordClient;
#end
import flixel.FlxObject;
import flixel.group.FlxGroup.FlxTypedGroup;
import flixel.addons.transition.FlxTransitionableState;
import flixel.effects.FlxFlicker;
import flixel.graphics.frames.FlxAtlasFrames;
import flixel.tweens.FlxEase.EaseFunction;
import lime.app.Application;
import Achievements;
import editors.MasterEditorMenu;
import mohong.TraceManager;
import haxe.Json;
import flixel.input.keyboard.FlxKey;
#if MODS_ALLOWED
import sys.FileSystem;
import sys.io.File;
#end

using StringTools;

class MainMenuState extends SeiunMenuState
{
	public static var seiunengineVersion(get, null):String = '';
	public static var psychEngineVersion:String = '0.6.4';
	public static var fnfGameVersion:String = '0.2.7.1';
	public static var extrakeysVersion:String = '0.4.6';

	public static var curSelected:Int = 0;

	public var menuItems:FlxTypedGroup<FlxSprite>;
	public var camGame:FlxCamera;
	public var camAchievement:FlxCamera;

	public var optionShit:Array<String> = [
		'story_mode',
		'freeplay',
		#if ONLINE_ALLOWED 'online', #end
		#if MODS_ALLOWED 'mods', #end
		#if ACHIEVEMENTS_ALLOWED 'awards', #end
		'credits',
		#if !switch 'donate', #end
		'options'
	];

	public var bg:FlxSprite;
	public var magenta:FlxSprite;
	public var camFollow:FlxObject;
	public var camFollowPos:FlxObject;
	public var debugKeys:Array<FlxKey>;
	public var mouseOverlapIndex = -1;
	public static var instance:MainMenuState;

	// === Seiun menu animation layers ===
	var particleGroup:FlxTypedGroup<FlxSprite>;
	var itemGlows:FlxTypedGroup<FlxSprite>;
	var auroraGlowA:FlxSprite;
	var auroraGlowB:FlxSprite;
	var itemBaseY:Array<Float> = [];
	var itemRestY:Array<Float> = [];
	var itemBaseWidth:Array<Float> = [];
	var itemBaseHeight:Array<Float> = [];
	var ambientTimer:Float = 0;
	var glowAlphaTarget:Float = 0.5;

	// === Mod Selection (persists across state transitions) ===
	public static var selectedModFolder:String = '';

	var currentModText:FlxText;
	var pendingModIndex:Int = -1;
	var pendingModRestart:Bool = false;
	static function get_seiunengineVersion():String {
		try {
			var meta = Application.current.meta;
			if (meta != null) {
				var v:Dynamic = meta.get('version');
				if (v != null && Std.string(v).length > 0) return Std.string(v);
			}
		} catch (e:Dynamic) {}
		return '0.2.2preonline2';
	}

	override function create()
	{
		instance = this;

		#if MODS_ALLOWED
		loadActiveMod();
		Paths.pushGlobalMods();
		// Use the user-selected mod folder (from ModSelectSubstate), default to vanilla
		Paths.currentModDirectory = selectedModFolder;
		// Apply mod pack.json config: window title, state/substate replacements
		ModState.applyModPackConfig(selectedModFolder);
		#end
		FlxG.mouse.visible = true;
		#if cpp
		// Updating Discord Rich Presence
		DiscordClient.changePresence("In the Menus", null);
		#end
		debugKeys = ClientPrefs.copyKey(ClientPrefs.keyBinds.get('debug_1'));
		FlxG.keys.preventDefaultKeys.remove(TAB);

		camGame = new FlxCamera();
		camAchievement = new FlxCamera();
		camAchievement.bgColor.alpha = 0;

		FlxG.cameras.reset(camGame);
		FlxG.cameras.add(camAchievement, false);
		FlxG.cameras.setDefaultDrawTarget(camGame, true);

		transIn = FlxTransitionableState.defaultTransIn;
		transOut = FlxTransitionableState.defaultTransOut;

		persistentUpdate = persistentDraw = true;

		var yScroll:Float = Math.max(0.25 - (0.05 * (optionShit.length - 4)), 0.1);
		bg = new FlxSprite(-80).loadGraphic(Paths.image('menuBG'));
		bg.scrollFactor.set(0, yScroll);
		bg.setGraphicSize(Std.int(bg.width * 1.175));
		bg.updateHitbox();
		bg.screenCenter();
		bg.antialiasing = ClientPrefs.data.globalAntialiasing;
		add(bg);

		camFollow = new FlxObject(0, 0, 1, 1);
		camFollowPos = new FlxObject(0, 0, 1, 1);
		add(camFollow);
		add(camFollowPos);

		magenta = new FlxSprite(-80).loadGraphic(Paths.image('menuDesat'));
		magenta.scrollFactor.set(0, yScroll);
		magenta.setGraphicSize(Std.int(magenta.width * 1.175));
		magenta.updateHitbox();
		magenta.screenCenter();
		magenta.visible = false;
		magenta.antialiasing = ClientPrefs.data.globalAntialiasing;
		magenta.color = 0xFFfd719b;
		add(magenta);
		

		if (MenuFX.enabled())
		{
			// ── Seiun aurora: drifting additive glows behind the menu ──
			auroraGlowA = MenuFX.makeGlow(920, 0xFFFD719B, 0.32);
			auroraGlowA.blend = ADD;
			auroraGlowA.scrollFactor.set(0, 0);
			auroraGlowA.screenCenter();
			add(auroraGlowA);

			auroraGlowB = MenuFX.makeGlow(760, 0xFF8A5CFF, 0.26);
			auroraGlowB.blend = ADD;
			auroraGlowB.scrollFactor.set(0, 0);
			auroraGlowB.screenCenter();
			add(auroraGlowB);
		}

		// Selection halos must render *behind* the menu items they highlight;
		// adding them first keeps the item art crisp instead of washed out.
		itemGlows = new FlxTypedGroup<FlxSprite>();
		add(itemGlows);
		menuItems = new FlxTypedGroup<FlxSprite>();
		add(menuItems);

		var scale:Float = 1;
		/*if(optionShit.length > 6) {
			scale = 6 / optionShit.length;
		}*/

		for (i in 0...optionShit.length)
		{
			var offset:Float = 108 - (Math.max(optionShit.length, 4) - 4) * 80;
			var menuItem:FlxSprite = new FlxSprite(0, (i * 140)  + offset);
			menuItem.scale.x = scale;
			menuItem.scale.y = scale;
			menuItem.frames = Paths.getSparrowAtlas('mainmenu/menu_' + optionShit[i]);
			menuItem.animation.addByPrefix('idle', optionShit[i] + " basic", 24);
			menuItem.animation.addByPrefix('selected', optionShit[i] + " white", 24);
			menuItem.animation.play('idle');
			menuItem.ID = i;
			menuItems.add(menuItem);
			var scr:Float = (optionShit.length - 4) * 0.135;
			if(optionShit.length < 6) scr = 0;
			menuItem.scrollFactor.set(0, scr);
			menuItem.antialiasing = ClientPrefs.data.globalAntialiasing;
			menuItem.updateHitbox();
			itemBaseWidth.push(menuItem.width);
			itemBaseHeight.push(menuItem.height);
			
			var leftMargin = 100;
			menuItem.x = leftMargin;
			itemBaseY.push(menuItem.y);
			itemRestY.push(menuItem.y);

			if (MenuFX.enabled())
			{
				// Soft glow behind every item (only the selected one shows)
				var glow:FlxSprite = MenuFX.makeGlow(360, 0xFFFFA8E0, glowAlphaTarget);
				glow.scale.set(1.45, 0.62);
				glow.updateHitbox();
				glow.blend = ADD;
				glow.scrollFactor.copyFrom(menuItem.scrollFactor);
				glow.visible = (i == 0);
				itemGlows.add(glow);
			}
		}

		// ── Particles (selection bursts + ambient sparkles) ──
		if (MenuFX.enabled())
		{
			particleGroup = new FlxTypedGroup<FlxSprite>();
			add(particleGroup);
		}

		FlxG.camera.follow(camFollowPos, null, 1);
		// 版本信息统一右对齐，贴住屏幕右边缘，避免长文本溢出。
		var versionRightEdge:Int = FlxG.width - 10;
		// (y, label) pairs, listed top-to-bottom as they appear on screen
		var versionLabels:Array<Array<Dynamic>> = [
			[FlxG.height - 84,  "ExtraKeys v" + extrakeysVersion],
			[FlxG.height - 64,  "Seiun Engine v" + seiunengineVersion],
			[FlxG.height - 44,  "Psych Engine v0.6.3+0.7.3+1.0.4 (Active: " + CompatEngine.current() + ")"],
			[FlxG.height - 24,  "Friday Night Funkin' v" + fnfGameVersion]
		];
		#if ONLINE_ALLOWED
		// SeiunOnline shares the version block with the engine rows: ExtraKeys and Seiun Engine
		// move up one slot so the online client version sits right below Seiun Engine.
		versionLabels[0][0] = versionLabels[0][0] - 20;
		versionLabels[1][0] = versionLabels[1][0] - 20;
		versionLabels.insert(2, [FlxG.height - 64, "SeiunOnline v" + online.Protocol.VERSION + " (net v" + online.Protocol.NETWORK_VERSION + ")"]);
		#end
		if (TitleState.updateAvailable)
			versionLabels.unshift([FlxG.height - 124, Language.get('MainMenu.updateAvailable', 'Update available: ') + TitleState.updateVersion]);
		for (label in versionLabels)
		{
			var versionShit:FlxText = new FlxText(0, Std.int(label[0]), versionRightEdge, Std.string(label[1]), 12);
			versionShit.scrollFactor.set();
			versionShit.setFormat(Paths.languageFont(), 16, FlxColor.WHITE, RIGHT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
			add(versionShit);
		}

		#if HSCRIPT_ALLOWED
		var hscriptversionShit:FlxText = new FlxText(0, FlxG.height - 704, versionRightEdge, "Hscript version: " + HScript.hscriptVersion, 12);
		hscriptversionShit.scrollFactor.set();
		hscriptversionShit.setFormat(Paths.languageFont(), 16, FlxColor.WHITE, RIGHT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		add(hscriptversionShit);
		#end

		#if LUA_ALLOWED
		var luaversionShit:FlxText = new FlxText(0, FlxG.height - 684, versionRightEdge, "Lua version: " + FunkinLua.luaversion, 12);
		luaversionShit.scrollFactor.set();
		luaversionShit.setFormat(Paths.languageFont(), 16, FlxColor.WHITE, RIGHT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		add(luaversionShit);
		#end

		// === Active mod indicator ===
		currentModText = new FlxText(5, FlxG.height - 24, 0, "", 16);
		currentModText.scrollFactor.set();
		currentModText.setFormat(Paths.languageFont(), 16, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		currentModText.borderSize = 1;
		add(currentModText);

		// Ensure menu music is playing (may not be if TitleState was replaced)
		if (FlxG.sound.music != null && FlxG.sound.music.playing)
			MenuFX.menuMusicActive = true;
		MenuFX.ensureMenuMusic(0.8);

		// Warm the settings-menu assets so they are GPU-ready on the very first
		// entry into Options (avoids blank images until the textures re-upload).
		try { Paths.image('menuDesat'); } catch (e:Dynamic) {}
		try { Paths.getSparrowAtlas('checkboxanim'); } catch (e:Dynamic) {}
		try { Paths.getSparrowAtlas('characters/BOYFRIEND'); } catch (e:Dynamic) {}

		// NG.core.calls.event.logEvent('swag').send();

		changeItem();

		// ── Entry animation: items stream up from below their slot, top option
		//    first with the rest trailing behind (lag). The Y motion goes through
		//    `itemBaseY` because update() drives item.y from it every frame. ──
		for (i in 0...menuItems.length)
		{
			var item:FlxSprite = menuItems.members[i];
			var idx:Int = i;
			var delay:Float = Math.min(i * 0.07, 0.5) + 0.05;
			var restY:Float = itemRestY[i];

			FlxTween.cancelTweensOf(item, ['alpha']);
			item.alpha = 0;
			FlxTween.tween(item, {alpha: itemAlphaFor(i)}, 0.35, {startDelay: delay, ease: FlxEase.sineOut});

			itemBaseY[i] = restY + 460; // start well below the resting slot
			item.y = itemBaseY[i];
			FlxTween.num(itemBaseY[i], restY, 0.6, {startDelay: delay, ease: FlxEase.expoOut},
				function(v:Float) { itemBaseY[idx] = v; });
		}
		#if ACHIEVEMENTS_ALLOWED
		Achievements.loadAchievements();
		var leDate = Date.now();
		if (leDate.getDay() == 5 && leDate.getHours() >= 18) {
			var achieveID:Int = Achievements.getAchievementIndex('friday_night_play');
			if(!Achievements.isAchievementUnlocked(Achievements.achievementsStuff[achieveID][2])) { //It's a friday night. WEEEEEEEEEEEEEEEEEE
				Achievements.markUnlocked(Achievements.achievementsStuff[achieveID][2]);
				giveAchievement();
				ClientPrefs.saveSettings();
			}
		}
		#end
		#if (TOUCH_CONTROLS || desktop)
		addVirtualPad(UP_DOWN, A_B_C);
		#end
		super.create();

		// Language is now loaded (by MusicBeatState.create), safe to use translations
		// Re-set font because languageFont() now returns the correct language-specific font
		currentModText.setFormat(Paths.languageFont(), 16, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		updateActiveModText();

		#if LUA_ALLOWED
		initLuaScripts();
		setOnLuas('controls', controls);
		setOnLuas('state', this);
		callOnLuas('onCreatePost', []);
		#end
	}

	#if ACHIEVEMENTS_ALLOWED
	// Unlocks "Freaky on a Friday Night" achievement
	function giveAchievement() {
		add(new AchievementObject('friday_night_play', camAchievement));
		FlxG.sound.play(Paths.sound('confirmMenu'), 0.7);
		TraceManager.info('trace.mainMenu.giveAchievement', 'Giving achievement "friday_night_play"');
	}
	#end

	var selectedSomethin:Bool = false;

	override function update(elapsed:Float)
	{
		#if LUA_ALLOWED
		callOnLuas('onUpdate', [elapsed]);
		#end
		#if HSCRIPT_ALLOWED
		callOnHscript('onUpdate', [elapsed]);
		#end
		// Handle deferred mod restart (from ModSelectSubstate selection)
		if (pendingModRestart)
		{
			pendingModRestart = false;
			FlxG.sound.music.fadeOut(0.3);
			TitleState.initialized = false;
			TitleState.closedState = false;
			FlxG.camera.fade(FlxColor.BLACK, 0.5, false, FlxG.resetGame, false);
			return;
		}

		if (FlxG.sound.music != null && FlxG.sound.music.volume < 0.8)
		{
			FlxG.sound.music.volume += 0.5 * FlxG.elapsed;
			if(FreeplayState.vocals != null) FreeplayState.vocals.volume += 0.5 * elapsed;
		}

		// ── Seiun menu animations ──
		if (auroraGlowA != null)
		{
			var t:Float = MenuFX.time;
			MenuFX.driftGlow(auroraGlowA, t, FlxG.width * 0.5, FlxG.height * 0.36, 140, 70, 0.35, 0.28, 0, 0, 0.28, 0.09, 0.5, 0, 0xFFFD719B, 0.055);
			MenuFX.driftGlow(auroraGlowB, t, FlxG.width * 0.78, FlxG.height * 0.66, 120, 65, 0.23, 0.31, 2.1, 1.2, 0.22, 0.08, 0.42, 1.0, 0xFF8A5CFF, 0.045);
		}

		if (!selectedSomethin)
		{
			for (i in 0...menuItems.length)
			{
				var item:FlxSprite = menuItems.members[i];
				if (i < itemBaseY.length)
					item.y = itemBaseY[i] + MenuFX.bob(7, 1.7 + (i % 3) * 0.25, i * 0.95);

				var glow:FlxSprite = (i < itemGlows.length) ? itemGlows.members[i] : null;
				if (glow != null)
				{
					glow.visible = (i == curSelected);
					if (glow.visible)
					{
						// Use the base frame size so the glow stays locked to the item
						// even while the idle/selected animation frames change size.
						var baseW:Float = (i < itemBaseWidth.length) ? itemBaseWidth[i] : item.width;
						var baseH:Float = (i < itemBaseHeight.length) ? itemBaseHeight[i] : item.height;
						glow.x = item.x + baseW * 0.5 - glow.width * glow.scale.x * 0.5;
						glow.y = item.y + baseH * 0.5 - glow.height * glow.scale.y * 0.5;
					}
				}
			}
		}

		// Ambient sparkles drifting in the background
		ambientTimer += elapsed;
		if (ambientTimer > 0.14)
		{
			ambientTimer = 0;
			MenuFX.ambientSparkle(particleGroup,
				FlxG.random.float(0, FlxG.width),
				FlxG.random.float(FlxG.height * 0.15, FlxG.height * 0.85),
				FlxColor.fromRGB(255, 226, 250),
				FlxG.random.float(3, 7));
		}

		var lerpVal:Float = CoolUtil.boundTo(elapsed * 7.5, 0, 1);
		camFollowPos.setPosition(FlxMath.lerp(camFollowPos.x, camFollow.x, lerpVal), FlxMath.lerp(camFollowPos.y, camFollow.y, lerpVal));
		// 防穿透: 鼠标在虚拟按键上时, 下层菜单不做悬停/点击判定
		var overControls:Bool = (virtualPad != null && virtualPad.isMouseOverAnyButton());
		if (!overControls && !selectedSomethin)
		{
			var newMouseOverlapIndex = -1;
			for (item in menuItems) {
				if (FlxG.mouse.overlaps(item)) {
					newMouseOverlapIndex = item.ID;
					break;
				}
			}
			if (FlxG.mouse.wheel != 0) {
				FlxG.sound.play(Paths.sound('scrollMenu'));
				changeItem(-FlxG.mouse.wheel);
			}

			if (mouseOverlapIndex != newMouseOverlapIndex) {
				mouseOverlapIndex = newMouseOverlapIndex;
				refreshItemAlphas();
			}
			if (FlxG.mouse.justPressed && mouseOverlapIndex >= 0 && mouseOverlapIndex != curSelected) {
				curSelected = mouseOverlapIndex;
				changeItem(0);
				FlxG.sound.play(Paths.sound('scrollMenu'));
			}
		}
		if (!selectedSomethin)
		{
			if (controls.UI_UP_P)
			{
				FlxG.sound.play(Paths.sound('scrollMenu'));
				changeItem(-1);
			}

			if (controls.UI_DOWN_P)
			{
				FlxG.sound.play(Paths.sound('scrollMenu'));
				changeItem(1);
			}

			if (controls.BACK)
			{
				selectedSomethin = true;
				FlxG.sound.play(Paths.sound('cancelMenu'));
				MusicBeatState.switchState(new TitleState());
			}

			// TAB to open mod selection (when there are mods installed)
			#if MODS_ALLOWED
			if (FlxG.keys.justPressed.TAB && !selectedSomethin)
			{
				openModSelectSubstate();
			}
			#end

			// 开启触屏支持后, 鼠标点击不再直接确认, 防止误触 (用虚拟按键/键盘确认)
			if (FlxG.mouse.justPressed && mouseOverlapIndex == curSelected && !selectedSomethin && !ClientPrefs.data.touchControls || controls.ACCEPT) {
				if (optionShit[curSelected] == 'donate') {
					CoolUtil.browserLoad('https://ninja-muffin24.itch.io/funkin');
				} else {
					selectedSomethin = true;
					FlxG.sound.play(Paths.sound('confirmMenu'));
					MenuFX.screenFlash(camGame, 0xFFFFFFFF, 0.42, 0.5);
					MenuFX.punchZoom(0.05);
					var selSpr:FlxSprite = menuItems.members[curSelected];
					MenuFX.burstParticles(particleGroup, selSpr.x + selSpr.width * 0.5, selSpr.y + selSpr.height * 0.5, 0xFFFF9FE8, 24, 340);
					
					if(ClientPrefs.data.flashing) FlxFlicker.flicker(magenta, 1.1, 0.15, false);
					
					menuItems.forEach(function(spr:FlxSprite) {
						if (curSelected != spr.ID) {
							FlxTween.tween(spr, {
								alpha: 0,
								x: spr.x - 500 
							}, 0.4, {
								ease: FlxEase.quadOut,
								onComplete: function(twn:FlxTween) { spr.kill(); }
							});
						} else {
							FlxFlicker.flicker(spr, 0.45, 0.06, false, false, function(flick:FlxFlicker) {
								var daChoice:String = optionShit[curSelected];
								
								switch (daChoice) {
									case 'story_mode':
										MenuFX.menuSwitch(new StoryMenuState());
									case 'freeplay':
										MenuFX.menuSwitch(new FreeplayState());
									#if ONLINE_ALLOWED
									case 'online':
										MenuFX.menuSwitch(new online.states.OnlineState());
									#end
									#if MODS_ALLOWED
									case 'mods':
										if(!ClientPrefs.data.oldmodsmenu)
										MenuFX.menuSwitch(new ModsMenuState());
										else
										MenuFX.menuSwitch(new ModsMenuStateOld());
									#end
									case 'awards':
										MenuFX.menuSwitch(new AchievementsMenuState());
									case 'credits':
										MenuFX.menuSwitch(new CreditsState());
									case 'options':
										// Options uses the standard transition so its
										// images/UI settle in reliably on first entry.
										MusicBeatState.switchState(new options.OptionsState());
										OptionsState.onPlayState = false;
										#if ONLINE_ALLOWED
										// Mirrors source MainMenuState.hx:365
										OptionsState.onOnlineRoom = false;
										#end
								}
							});
						}
					});
				}
			}
			else if (#if (TOUCH_CONTROLS || desktop) (virtualPad != null && virtualPad.buttonC.justPressed) ||	#end FlxG.keys.anyJustPressed(debugKeys))
			{
				selectedSomethin = true;
				MusicBeatState.switchState(new MasterEditorMenu());
			}
		}

		super.update(elapsed);

		#if LUA_ALLOWED
		callOnLuas('onUpdatePost', [elapsed]);
		#end
		#if HSCRIPT_ALLOWED
		callOnHscript('onUpdatePost', [elapsed]);
		#end
	}

	/** Alpha used for a menu item: selected and hovered stay bright, the rest dim slightly. */
	function itemAlphaFor(i:Int):Float
	{
		return (i == curSelected || i == mouseOverlapIndex) ? 1 : 0.8;
	}

	/** Smoothly re-apply item alpha from the current selection + hover state. */
	function refreshItemAlphas():Void
	{
		for (i in 0...menuItems.length)
			MenuFX.fadeAlpha(menuItems.members[i], itemAlphaFor(i), 0.18);
	}

	function changeItem(huh:Int = 0)
	{
		curSelected += huh;

		if (curSelected >= menuItems.length)
			curSelected = 0;
		if (curSelected < 0)
			curSelected = menuItems.length - 1;

		menuItems.forEach(function(spr:FlxSprite)
		{
			// Snap to the base scale so the hitbox/offset math below never reads
			// a mid-pulse scale value (which would drift the item's position).
			spr.scale.set(1, 1);
			spr.animation.play('idle');
			spr.updateHitbox();

			if (spr.ID == curSelected)
			{
				spr.animation.play('selected');
				var add:Float = 0;
				if(menuItems.length > 4) {
					add = menuItems.length * 8;
				}
				// Aim the camera at the resting slot, never at wherever the
				// entry animation currently has the item mid-flight.
				var midY:Float = (spr.ID < itemRestY.length)
					? itemRestY[spr.ID] + spr.height * 0.5
					: spr.getGraphicMidpoint().y;
				camFollow.setPosition(
					FlxG.width / 2,
					midY - add
				);
				spr.centerOffsets();
			}
		});
		refreshItemAlphas();

		// ── Seiun selection feedback: pop + glow burst + camera kick ──
		var selItem:FlxSprite = menuItems.members[curSelected];
		MenuFX.pulse(selItem, 0.14, 0.2);
		var selGlow:FlxSprite = (curSelected < itemGlows.length) ? itemGlows.members[curSelected] : null;
		if (selGlow != null) MenuFX.pulse(selGlow, 0.35, 0.3);
		MenuFX.punchZoom(0.02);
		MenuFX.burstParticles(particleGroup, selItem.x + selItem.width * 0.5, selItem.y + selItem.height * 0.5, 0xFFFF9FE8, 10, 190);
	}

	override function onMenuBeat(beat:Int):Void
	{
		if (selectedSomethin || menuItems == null || menuItems.length == 0
			|| curSelected < 0 || curSelected >= menuItems.length)
			return;

		var spr:FlxSprite = menuItems.members[curSelected];
		MenuFX.pulse(spr, 0.07, 0.15);
		var glow:FlxSprite = (curSelected < itemGlows.length) ? itemGlows.members[curSelected] : null;
		MenuFX.glowPulse(glow, 0.95, glowAlphaTarget, 0.4);
		MenuFX.punchZoom(0.013);
	}
	// =============== Mod Selection ===============

	override function closeSubState() {
		if (pendingModIndex >= 0)
		{
			applyModSelection(pendingModIndex);
			pendingModIndex = -1;
		}
		persistentUpdate = true;
		super.closeSubState();
		// Restore camera follow after substate closes so menu scrolling works again
		FlxG.camera.follow(camFollowPos, null, 1);
	}

	function openModSelectSubstate()
	{
		#if MODS_ALLOWED
		// Reset camera to center before opening substate to prevent offset issues
		camFollow.setPosition(FlxG.width / 2, FlxG.height / 2);
		camFollowPos.setPosition(FlxG.width / 2, FlxG.height / 2);
		FlxG.camera.scroll.set(0, 0);

		// Build the mod list from modsList.txt + mod folders
		var modFolders:Array<String> = []; // '' = vanilla
		var modsListPath:String = 'modsList.txt';
		if (FileSystem.exists(modsListPath))
		{
			var lines:Array<String> = CoolUtil.coolTextFile(modsListPath);
			for (line in lines)
			{
				var parts = line.split('|');
				if (parts.length >= 1 && parts[0].length > 0
					&& !Paths.ignoreModFolders.contains(parts[0].toLowerCase())
					&& !modFolders.contains(parts[0]))
				{
					modFolders.push(parts[0]);
				}
			}
		}
		// Also pick up any folders not yet in modsList.txt
		for (folder in Paths.getModDirectories())
		{
			if (!Paths.ignoreModFolders.contains(folder) && !modFolders.contains(folder))
				modFolders.push(folder);
		}
		modFolders.sort(function(a, b) return (a < b) ? -1 : ((a > b) ? 1 : 0));
		modFolders.insert(0, ''); // Vanilla first

		// Find current selection index
		var selIdx:Int = 0;
		for (i in 0...modFolders.length)
		{
			if (modFolders[i] == selectedModFolder) { selIdx = i; break; }
		}

		// Stop camera follow so the substate isn't affected by camera movement
		FlxG.camera.follow(null);

		pendingModIndex = -1;
		persistentUpdate = false;
		openSubState(new ModSelectSubstate(
			modFolders,
			selIdx,
			function(newIdx:Int) { pendingModIndex = newIdx; },
			function() { /* cancel */ }
		));
		#end
	}

	function applyModSelection(newIdx:Int)
	{
		#if MODS_ALLOWED
		applyModSelectionExternal(newIdx);
		#end
	}

	/** Public version that can be called from ModState (accepts pre-built modFolders). */
	public static function applyModSelectionExternal(newIdx:Int, ?modFolders:Array<String>):Void
	{
		#if MODS_ALLOWED
		if (modFolders == null) 
			modFolders = [''];
		var modsListPath:String = 'modsList.txt';
		if (FileSystem.exists(modsListPath))
		{
			var lines:Array<String> = CoolUtil.coolTextFile(modsListPath);
			for (line in lines)
			{
				var parts = line.split('|');
				if (parts.length >= 1 && parts[0].length > 0
					&& !Paths.ignoreModFolders.contains(parts[0].toLowerCase())
					&& !modFolders.contains(parts[0]))
				{
					modFolders.push(parts[0]);
				}
			}
		}
		for (folder in Paths.getModDirectories())
		{
			if (!Paths.ignoreModFolders.contains(folder) && !modFolders.contains(folder))
				modFolders.push(folder);
		}
		modFolders.sort(function(a, b) return (a < b) ? -1 : ((a > b) ? 1 : 0));
		// Insert vanilla at front after sort
		if (modFolders.indexOf('') < 0) modFolders.insert(0, '');

		if (newIdx < 0 || newIdx >= modFolders.length) return;

		var newFolder:String = modFolders[newIdx];
		if (newFolder == selectedModFolder) return;

		// Apply selection
		selectedModFolder = newFolder;
		Paths.currentModDirectory = newFolder;
		saveActiveMod();

		// Apply mod pack.json config: window title, state/substate replacements
		ModState.applyModPackConfig(newFolder);

		// Check mod config: API version + restart requirements
		var needsRestart:Bool = false;
		if (newFolder.length > 0)
		{
			var modCfg:ModConfig = ModConfig.load(newFolder);

			// ── API version compatibility check ──
			if (!ModConfig.isCompatible(modCfg))
			{
				var reason:String = ModConfig.incompatibilityReason(modCfg);
				TraceManager.warn('trace.mainMenu.incompatibleMod', 'Incompatible mod: {}', [reason]);
				// Still allow selection but show warning — the ModsMenu will display the reason.
			}

			needsRestart = modCfg.restartRequired;

			// If the mod defines any state/substate replacements,
			// force a restart regardless of the "restart" field.
			if (!needsRestart)
			{
				if (modCfg.stateReplacements.keys().hasNext())
					needsRestart = true;
				else if (modCfg.substateReplacements.keys().hasNext())
					needsRestart = true;
			}
		}
		

		// Always force a full game restart (through TitleState) when switching mods,
		// even when switching to "vanilla" (empty folder).  This ensures:
		//   - stateReplacements are properly cleared and TitleState is not replaced
		//   - global mods are re-evaluated
		//   - assets reload cleanly
		if (instance != null) {
			instance.pendingModRestart = true;
			instance.currentModText.text = Language.get("MainMenu.activeMod", "Active Mod: ")
				+ WeekData.getModFolderDisplayName(newFolder)
				+ "\n" + Language.get("Mod.restart", "(Restarting...)");
			instance.currentModText.color = 0xFFFF6666;
			instance.currentModText.setFormat(Paths.languageFont(), 16, 0xFFFF6666, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
			return;
		}
		else
		{
			// Called from outside MainMenuState (e.g. ModState TAB) — force a
			// full game restart so state replacements, window title etc. apply.
			TitleState.initialized = false;
			TitleState.closedState = false;
			FlxG.resetGame();
			return;
		}
		#end
	}

	function updateActiveModText()
	{
		#if MODS_ALLOWED
		var displayName:String = WeekData.getModFolderDisplayName(selectedModFolder);
		currentModText.text = Language.get("MainMenu.activeMod", "Active Mod:") + displayName;
		#else
		currentModText.text = '';
		#end
	}

	// =============== Persist active mod selection ===============

	/** Read the previously-selected mod folder from `activeMod.txt` (game root). */
	public static function loadActiveMod():Void {
		#if MODS_ALLOWED
		var path:String = 'activeMod.txt';
		if (FileSystem.exists(path)) {
			try {
				var content:String = File.getContent(path).trim();
				if (content.length > 0) {
					selectedModFolder = content;
				}
			} catch (e:Dynamic) {
				TraceManager.error('trace.mainMenu.activeModLoadError', 'Failed to load activeMod.txt: {}', [e]);
			}
		}
		#end
	}

	/** Persist the current mod folder to `activeMod.txt` (game root). */
	static function saveActiveMod():Void {
		#if MODS_ALLOWED
		try {
			File.saveContent('activeMod.txt', selectedModFolder);
		} catch (e:Dynamic) {
			TraceManager.error('trace.mainMenu.activeModSaveError', 'Failed to save activeMod.txt: {}', [e]);
		}
		#end
	}

	override function destroy() {
		if (particleGroup != null)
			for (p in particleGroup) FlxTween.cancelTweensOf(p);
		instance = null;
		super.destroy();
	}
	
}
