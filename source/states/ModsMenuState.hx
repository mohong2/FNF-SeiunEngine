package states;

import flixel.graphics.FlxGraphic;
#if cpp
import Discord.DiscordClient;
#end
import flixel.addons.display.FlxGridOverlay;
import flixel.addons.transition.FlxTransitionableState;
import lime.utils.Assets;
import flixel.system.FlxSound;
import openfl.utils.Assets as OpenFlAssets;
import sys.io.File;
import sys.FileSystem;
import haxe.Json;
import haxe.format.JsonParser;
import openfl.display.BitmapData;
import flash.geom.Rectangle;
import flixel.FlxBasic;
import options.ModSettingsSubState;
import flixel.util.FlxSpriteUtil;
import WeekData;
import flixel.ui.FlxButton;
import AttachedSprite;
import sys.io.Process;
import lime.system.System;
import openfl.Lib;
import tjson.TJSON;
import FlxTextMenuItem;
import mohong.TraceManager;
import backend.ModConfig;

using StringTools;

class ModsMenuState extends MusicBeatState
{
	var bg:FlxSprite;
	var icon:FlxSprite;
	var modName:FlxTextMenuItem;
	var modDesc:FlxText;
	var modRestartText:FlxText;
	var modsList:Array<Dynamic> = [];

	var bgList:FlxSprite;
	var buttonReload:MenuButton;
	var buttonModFolder:MenuButton;
	var buttonToggleAll:MenuButton;
	var buttons:Array<MenuButton> = [];
	var settingsButton:MenuButton;

	var bgTitle:FlxSprite;
	var bgDescription:FlxSprite;
	var bgButtons:FlxSprite;

	var modsGroup:FlxTypedGroup<ModItem>;
	var curSelectedMod:Int = 0;
	
	var hoveringOnMods:Bool = true;
	var curSelectedButton:Int = -1;
	var modNameInitialY:Float = 0;

	var noModsSine:Float = 0;
	var noModsTxt:FlxText;

	var _lastControllerMode:Bool = false;
	var startMod:String = null;

	public static var instance:ModsMenuState;

	public function new(startMod:String = null)
	{
		this.startMod = startMod;
		super();
	}
	
	override function create()
	{

		Paths.clearStoredMemory();
		Paths.clearUnusedMemory();
		persistentUpdate = false;
		WeekData.setDirectoryFromWeek();

		#if cpp
		DiscordClient.changePresence("In the Menus", null);
		#end
		modsList = [];
		var path:String = 'modsList.txt';
		if(FileSystem.exists(path))
		{
			var leMods:Array<String> = CoolUtil.coolTextFile(path);
			for (i in 0...leMods.length)
			{
				if(leMods[i].length > 0) {
					var modSplit:Array<String> = leMods[i].split('|');
					if(modSplit.length >= 2 && modSplit[0].length > 0 && !Paths.ignoreModFolders.contains(modSplit[0].toLowerCase()))
					{
						modsList.push([modSplit[0], (modSplit[1] == '1')]);
					}
				}
			}
		}

		if (FileSystem.exists("modsList.txt")){
			for (folder in Paths.getModDirectories())
			{
				if(!Paths.ignoreModFolders.contains(folder))
				{
					var found = false;
					for (mod in modsList) {
						if (mod[0] == folder) {
							found = true;
							break;
						}
					}
					if (!found) {
						modsList.push([folder, true]);
					}
				}
			}
		}
		saveTxt();

		bg = new FlxSprite().loadGraphic(Paths.image('menuDesat'));
		bg.color = 0xFF665AFF;
		bg.antialiasing = ClientPrefs.data.globalAntialiasing;
		add(bg);
		bg.screenCenter();

		bgList = FlxSpriteUtil.drawRoundRect(new FlxSprite(40, 40).makeGraphic(340, 440, FlxColor.TRANSPARENT), 0, 0, 340, 440, 15, 15, FlxColor.BLACK);
		bgList.alpha = 0.6;
		add(bgList);

		modsGroup = new FlxTypedGroup<ModItem>();

		for (i in 0...modsList.length)
		{
			if(startMod == modsList[i][0]) curSelectedMod = i;
			var modItem:ModItem = new ModItem(modsList[i][0]);
			if(!modsList[i][1])
			{
				modItem.icon.color = 0xFFFF6666;
				modItem.text.color = FlxColor.GRAY;
			}
			modsGroup.add(modItem);
		}

		var mod:ModItem = modsGroup.members[curSelectedMod];
		if(mod != null) bg.color = mod.bgColor;

		var buttonX = bgList.x;
		var buttonWidth = Std.int(bgList.width);
		var buttonHeight = 80;

		buttonReload = new MenuButton(buttonX, bgList.y + bgList.height + 20, buttonWidth, buttonHeight, "RELOAD", reload);
		add(buttonReload);
		
		buttonToggleAll = new MenuButton(buttonX, buttonReload.y + buttonReload.bg.height + 20, buttonWidth, buttonHeight, "ENABLE ALL" , function() {
			Language.load();
			var allEnabled = true;
			for (mod in modsList) {
				if (!mod[1]) {
					allEnabled = false;
					break;
				}
			}
			
			for (i in 0...modsList.length) {
				modsList[i][1] = !allEnabled;
			}
			
			for (mod in modsGroup.members)
			{
				mod.icon.color = !allEnabled ? FlxColor.WHITE : 0xFFFF6666;
				mod.text.color = !allEnabled ? FlxColor.WHITE : FlxColor.GRAY;
			}
			
			buttonToggleAll.textOn.text = buttonToggleAll.textOff.text = !allEnabled ? 
				Language.get("Mod.disableAll", "DISABLE ALL") : Language.get("Mod.enableAll", "ENABLE ALL");
			buttonToggleAll.bg.color = !allEnabled ? 0xFFFF6666 : FlxColor.GREEN;
			
			updateModDisplayData();
			FlxG.sound.play(Paths.sound('scrollMenu'), 0.6);
		});
		buttonToggleAll.bg.color = FlxColor.GREEN;
		buttonToggleAll.focusChangeCallback = function(focus:Bool) {
			var allEnabled = true;
			for (mod in modsList) {
				if (!mod[1]) { allEnabled = false; break; }
			}
			buttonToggleAll.bg.color = allEnabled ? FlxColor.GREEN : 0xFFFF6666;
		};
		add(buttonToggleAll);

		if(modsList.length < 1)
		{
			buttonToggleAll.visible = false;

			var myX = bgList.x + bgList.width + 20;
			noModsTxt = new FlxText(myX, 0, FlxG.width - myX - 20, Language.get("Mod.noModsTxt", "NO MODS INSTALLED\nPRESS BACK TO EXIT AND INSTALL A MOD"), 48);
			if(FlxG.random.bool(0.1)) noModsTxt.text += '\nBITCH.';
			noModsTxt.setFormat(Paths.languageFont(), 32, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
			noModsTxt.borderSize = 2;
			add(noModsTxt);
			noModsTxt.screenCenter(Y);

			var txt = new FlxText(bgList.x + 15, bgList.y + 15, bgList.width - 30, Language.get("Mod.noMods", "No Mods found."), 16);
			txt.setFormat(Paths.languageFont(), 16, FlxColor.WHITE);
			add(txt);

			FlxG.autoPause = false;
			changeSelectedMod();
			#if LUA_ALLOWED
			initLuaScripts();
			setOnLuas('controls', controls);
			setOnLuas('state', this);
			callOnLuas('onCreatePost', []);
			#end
			#if (TOUCH_CONTROLS || desktop)
			// 无模组也必须加载虚拟按键, 否则 B/返回控件缺失会导致玩家卡死
			addVirtualPad(UP_DOWN, B);
			#end
			return super.create();
		}
		
		bgTitle = FlxSpriteUtil.drawRoundRectComplex(new FlxSprite(bgList.x + bgList.width + 20, 40).makeGraphic(840, 180, FlxColor.TRANSPARENT), 0, 0, 840, 180, 15, 15, 0, 0, FlxColor.BLACK);
		bgTitle.alpha = 0.6;
		add(bgTitle);

		icon = new FlxSprite(bgTitle.x + 15, bgTitle.y + 15);
		icon.antialiasing = ClientPrefs.data.globalAntialiasing;
		add(icon);

		modNameInitialY = icon.y + 80;
		modName = new FlxTextMenuItem(icon.x + 165, modNameInitialY, "", 48);
		modName.isMenuItem = false;
		modName.scale.y = 0.8;
		add(modName);

		bgDescription = FlxSpriteUtil.drawRoundRectComplex(new FlxSprite(bgTitle.x, bgTitle.y + 200).makeGraphic(840, 450, FlxColor.TRANSPARENT), 0, 0, 840, 450, 0, 0, 15, 15, FlxColor.BLACK);
		bgDescription.alpha = 0.6;
		add(bgDescription);
		
		modDesc = new FlxText(bgDescription.x + 15, bgDescription.y + 15, bgDescription.width - 30, "", 24);
		modDesc.setFormat(Paths.languageFont(), 24, FlxColor.WHITE, LEFT);
		// 裁剪超出描述框的文字
		modDesc.y = bgDescription.y + 15;
		add(modDesc);

		var myHeight = 100;
		modRestartText = new FlxText(bgDescription.x + 15, bgDescription.y + bgDescription.height - myHeight - 25, bgDescription.width - 30, 
			Language.get("Mod.restartNote", "* Moving or Toggling On/Off this Mod will restart the game."), 16);
		modRestartText.setFormat(Paths.languageFont(), 16, FlxColor.WHITE, RIGHT);
		add(modRestartText);

		bgButtons = FlxSpriteUtil.drawRoundRectComplex(new FlxSprite(bgDescription.x, bgDescription.y + bgDescription.height - myHeight).makeGraphic(840, myHeight, FlxColor.TRANSPARENT), 0, 0, 840, myHeight, 0, 0, 15, 15, FlxColor.WHITE);
		bgButtons.color = FlxColor.BLACK;
		bgButtons.alpha = 0.2;
		add(bgButtons);

		var buttonsX = bgButtons.x + 320;
		var buttonsY = bgButtons.y + 10;

		var button = new MenuButton(buttonsX, buttonsY, 80, 80, Paths.image('modsMenuButtons'), function() moveModToPosition(0), 54, 54);
		button.icon.animation.add('icon', [0]);
		button.icon.animation.play('icon', true);
		add(button);
		buttons.push(button);

		var button = new MenuButton(buttonsX + 100, buttonsY, 80, 80, Paths.image('modsMenuButtons'), function() moveModToPosition(curSelectedMod - 1), 54, 54);
		button.icon.animation.add('icon', [1]);
		button.icon.animation.play('icon', true);
		add(button);
		buttons.push(button);

		var button = new MenuButton(buttonsX + 200, buttonsY, 80, 80, Paths.image('modsMenuButtons'), function() moveModToPosition(curSelectedMod + 1), 54, 54);
		button.icon.animation.add('icon', [2]);
		button.icon.animation.play('icon', true);
		add(button);
		buttons.push(button);
		
		if(modsList.length < 2)
		{
			for (button in buttons)
				button.enabled = false;
		}

		settingsButton = new MenuButton(buttonsX + 300, buttonsY, 80, 80, Paths.image('modsMenuButtons'), function()
		{
			var curMod:ModItem = modsGroup.members[curSelectedMod];
			if(curMod != null && curMod.settings != null && curMod.settings.length > 0)
			{
				openSubState(new ModSettingsSubState(curMod.settings, curMod.folder, curMod.name));
			}
			else
			{
				FlxG.sound.play(Paths.sound('cancelMenu'));
			}
		}, 54, 54);

		settingsButton.icon.animation.add('icon', [3]);
		settingsButton.icon.animation.play('icon', true);
		add(settingsButton);
		buttons.push(settingsButton);

		if(modsGroup.members[curSelectedMod].settings == null || modsGroup.members[curSelectedMod].settings.length < 1)
			settingsButton.enabled = false;

		var button = new MenuButton(buttonsX + 400, buttonsY, 80, 80, Paths.image('modsMenuButtons'), function()
		{
			var curMod:ModItem = modsGroup.members[curSelectedMod];
			var mod:String = curMod.folder;
			if(modsList[curSelectedMod][1])
			{
				modsList[curSelectedMod][1] = false;
				curMod.icon.color = 0xFFFF6666;
				curMod.text.color = FlxColor.GRAY;
			}
			else
			{
				modsList[curSelectedMod][1] = true;
				curMod.icon.color = FlxColor.WHITE;
				curMod.text.color = FlxColor.WHITE;
			}

				updateModDisplayData();
			FlxG.sound.play(Paths.sound('scrollMenu'), 0.6);
		}, 54, 54);
		button.icon.animation.add('icon', [4]);
		button.icon.animation.play('icon', true);
		add(button);
		buttons.push(button);
		button.focusChangeCallback = function(focus:Bool) {
			if(!focus)
				button.bg.color = modsList[curSelectedMod][1] ? FlxColor.GREEN : 0xFFFF6666;
		};

		if(modsList.length < 1)
		{
			for (btn in buttons) btn.enabled = false;
			button.focusChangeCallback = null;
		}

		add(modsGroup);
						 
		#if (TOUCH_CONTROLS || desktop)
		addVirtualPad(UP_DOWN, B);
		#end

		changeSelectedMod();
		#if LUA_ALLOWED
		initLuaScripts();
		setOnLuas('controls', controls);
		setOnLuas('state', this);
		callOnLuas('onCreatePost', []);
		#end
		super.create();

		// === Mod loading tip (v0.2.1+) — after super.create so Language is loaded ===
		var loadingTip:FlxText = new FlxText(bgList.x + 10, bgList.y + bgList.height - 40, bgList.width - 20,
			Language.get("Mod.loadingTip", "Since v0.2.1: Top mod here no longer affects game assets.\nSelect your active mod in Main Menu -> Mod Select."), 13);
		loadingTip.setFormat(Paths.languageFont(), 13, 0xFFFFCC00, CENTER);
		loadingTip.scrollFactor.set();
		add(loadingTip);
	}
	
	var nextAttempt:Float = 1;
	var holdingMod:Bool = false;
	var mouseOffsets:FlxPoint = new FlxPoint();
	var holdingElapsed:Float = 0;
	var gottaClickAgain:Bool = false;

	var holdTime:Float = 0;
	var colorTween:FlxTween;
	var dragTarget:Int = -1;

	// ── 描述滑条 ──
	var modDescScroll:Float = 0;
	var modDescMaxScroll:Float = 0;

override function update(elapsed:Float)
{
	#if LUA_ALLOWED
	callOnLuas('onUpdate', [elapsed]);
	#end
	#if HSCRIPT_ALLOWED
	callOnHscript('onUpdate', [elapsed]);
	#end

	if(controls.BACK)
	{
		if(colorTween != null) {
			colorTween.cancel();
		}
		saveTxt();

		FlxG.sound.play(Paths.sound('cancelMenu'));
		MusicBeatState.switchState(new MainMenuState());

		persistentUpdate = false;
		FlxG.autoPause = ClientPrefs.data.autoPause;
		FlxG.mouse.visible = false;
		return;
	}

	if(controls.UI_DOWN_R || controls.UI_UP_R) holdTime = 0;

	if(modsList.length > 0)
	{
		var lastMode = hoveringOnMods;
		if(modsList.length > 1)
		{
			// Mouse pressed → detect click on mod items (虚拟按键上点击不穿透, 否则会误切换 hover 状态)
			if(FlxG.mouse.justPressed && !(virtualPad != null && virtualPad.isMouseOverAnyButton()))
			{
				hoveringOnMods = false;
				for (i in centerMod-2...centerMod+3)
				{
					var mod = modsGroup.members[i];
					if(mod == null || !mod.visible) continue;

					if(FlxG.mouse.overlaps(mod))
					{
						hoveringOnMods = true;
						mouseOffsets.x = FlxG.mouse.x - mod.x;
						mouseOffsets.y = FlxG.mouse.y - mod.y;
						
						if(curSelectedMod != i)
						{
							curSelectedMod = i;
							changeSelectedMod(0);
						}
						gottaClickAgain = false;
						break;
					}
				}
			}

			// Scroll wheel → scroll mod list (仅在鼠标不在描述区域时)
			var scrollDir:Int = 0;
			var makesSound:Bool = false;
			if (FlxG.mouse.wheel > 0 && !FlxG.mouse.overlaps(bgDescription))
			{
				scrollDir = -1;
				makesSound = true;
			}
			else if (FlxG.mouse.wheel < 0 && !FlxG.mouse.overlaps(bgDescription))
			{
				scrollDir = 1;
				makesSound = true;
			}

			if (scrollDir != 0)
			{
				if (!hoveringOnMods) hoveringOnMods = true;
				var shiftMult:Int = (FlxG.keys.pressed.SHIFT) ? 4 : 1;
				changeSelectedMod(scrollDir * shiftMult, makesSound);
			}

			if(hoveringOnMods)
			{
				var shiftMult:Int = (FlxG.keys.pressed.SHIFT) ? 4 : 1;
				if(controls.UI_DOWN_P)
					changeSelectedMod(shiftMult);
				else if(controls.UI_UP_P)
					changeSelectedMod(-shiftMult);
				else if(FlxG.mouse.wheel != 0)
					changeSelectedMod(-FlxG.mouse.wheel * shiftMult, true);
				else if(FlxG.keys.justPressed.HOME)
					changeSelectedMod(-999);
				else if(FlxG.keys.justPressed.END)
					changeSelectedMod(999);
				else if(controls.UI_UP || controls.UI_DOWN)
				{
					var lastHoldTime:Float = holdTime;
					holdTime += elapsed;
					if(holdTime > 0.5 && Math.floor(lastHoldTime * 8) != Math.floor(holdTime * 8)) 
						changeSelectedMod(shiftMult * (controls.UI_UP ? -1 : 1));
				}
				else if(FlxG.mouse.pressed)
				{
					var curMod:ModItem = modsGroup.members[curSelectedMod];
					if(curMod != null && FlxG.mouse.overlaps(curMod))
					{
						if(!holdingMod && FlxG.mouse.justMoved)
						{
							holdingMod = true;
							gottaClickAgain = true;
						}

						if(holdingMod)
						{
							var newY = FlxG.mouse.y - mouseOffsets.y;
							var minY = bgList.y + 5;
							var maxY = bgList.y + bgList.height - curMod.height - 5;
							newY = Math.max(minY, Math.min(maxY, newY));
							
							curMod.x = FlxG.mouse.x - mouseOffsets.x;
							curMod.y = newY;
							
							var itemHeight:Float = 86;
							var relativeY:Float = (curMod.y + curMod.height / 2) - bgList.y - 5;
							var targetIndex:Int = Math.floor(relativeY / itemHeight) + centerMod - 2;
							targetIndex = Std.int(Math.max(0, Math.min(modsList.length - 1, targetIndex)));
							
							if(targetIndex != curSelectedMod)
							{
								moveModToPosition(targetIndex);
								mouseOffsets.y = FlxG.mouse.y - modsGroup.members[curSelectedMod].y;
							}
						}
					}
				}
				else if(FlxG.mouse.justReleased && holdingMod)
				{
					holdingMod = false;
					holdingElapsed = 0;
					updateItemPositions();
					gottaClickAgain = true;
				}
			}
		}

		// ── 描述文字滑条 ──
		if (modDescMaxScroll > 0)
		{
			// 鼠标在描述区域时滚轮滚动
			if (FlxG.mouse.overlaps(bgDescription))
			{
				if (FlxG.mouse.wheel != 0)
				{
					modDescScroll -= FlxG.mouse.wheel * 40;
					modDescScroll = Math.max(0, Math.min(modDescScroll, modDescMaxScroll));
				}
			}
			// 键盘上下键
			if (FlxG.keys.justPressed.UP)
			{
				modDescScroll -= 40;
				modDescScroll = Math.max(0, modDescScroll);
			}
			else if (FlxG.keys.justPressed.DOWN)
			{
				modDescScroll += 40;
				modDescScroll = Math.min(modDescScroll, modDescMaxScroll);
			}

			// 移动文字 sprite，底部的按钮层自然遮盖溢出部分
			modDesc.y = bgDescription.y + 15 - modDescScroll;
		}
		else
		{
			modDesc.y = bgDescription.y + 15;
		}
	}
	else
	{
		noModsSine += 180 * elapsed;
		noModsTxt.alpha = 1 - Math.sin((Math.PI * noModsSine) / 180);
		
		nextAttempt -= elapsed;
		if(nextAttempt < 0)
		{
			nextAttempt = 2;
			Paths.getModDirectories();
			modsList = [];
			if(FileSystem.exists("modsList.txt")){
				for (folder in Paths.getModDirectories())
				{
					if(!Paths.ignoreModFolders.contains(folder))
					{
						var found = false;
						for (mod in modsList) {
							if (mod[0] == folder) {
								found = true;
								break;
							}
						}
						if (!found) {
							modsList.push([folder, true]);
						}
					}
				}
			}
			if(modsList.length > 0)
			{
				TraceManager.info('trace.modsMenu.foundReloading', 'mod(s) found! reloading');
				reload();
			}
		}
	}
	#if LUA_ALLOWED
	callOnLuas('onUpdatePost', [elapsed]);
	#end
	super.update(elapsed);
}
	function changeSelectedMod(add:Int = 0, isMouseWheel:Bool = false)
	{
		var max = modsList.length - 1;
		if(max < 0) return;

		var lastSelected = curSelectedMod;
		curSelectedMod += add;

		var limited:Bool = false;
		if(curSelectedMod < 0)
		{
			curSelectedMod = 0;
			limited = true;
		}
		else if(curSelectedMod > max)
		{
			curSelectedMod = max;
			limited = true;
		}
		
		if(!isMouseWheel && limited && Math.abs(add) == 1)
		{
			if(add < 0)
			{
				curSelectedMod = lastSelected;
				hoveringOnMods = false;
				curSelectedButton = -1;
				return;
			}
			else
			{
				curSelectedMod = lastSelected;
				hoveringOnMods = false;
				curSelectedButton = -2;
				return;
			}
		}
		
		holdingMod = false;
		holdingElapsed = 0;
		gottaClickAgain = true;
		updateModDisplayData();
		FlxG.sound.play(Paths.sound('scrollMenu'), 0.6);
	}

	function updateModDisplayData()
	{
		var curMod:ModItem = modsGroup.members[curSelectedMod];
		if(curMod == null) return;

		if(colorTween != null)
		{
			colorTween.cancel();
			colorTween.destroy();
		}
		colorTween = FlxTween.color(bg, 0.5, bg.color, curMod.bgColor);

		if(Math.abs(centerMod - curSelectedMod) > 2)
		{
			if(centerMod < curSelectedMod)
				centerMod = curSelectedMod - 2;
			else centerMod = curSelectedMod + 2;
		}
		updateItemPositions();

		if (curMod.icon != null) {
			icon.loadGraphic(curMod.icon.graphic);
			icon.setGraphicSize(150, 150);
			icon.updateHitbox();
		}

		modName.text = curMod.name;
		modName.scale.set(0.8, 0.8);
		modName.x = icon.x + 165;
		modName.y = modNameInitialY - (modName.height / 2);
		
		modRestartText.visible = curMod.mustRestart;

		// ── Build description text ──
		var descLines:Array<String> = [];

		// Use localised description if available
		if (ClientPrefs.data.language != 'English' && curMod.langdescription != null)
			descLines.push(curMod.langdescription);
		else
			descLines.push(curMod.desc);

		// Author & version
		var metaInfo:String = "";
		if (curMod.author.length > 0) metaInfo += Language.get("Mod.author", "Author: ") + curMod.author;
		if (curMod.modVersion.length > 0) {
			if (metaInfo.length > 0) metaInfo += "  |  ";
			metaInfo += Language.get("Mod.version", "Version: ") + curMod.modVersion;
		}
		if (metaInfo.length > 0) descLines.push("\n" + metaInfo);

		// Download link hint
		if (curMod.downloadLink.length > 0) {
			descLines.push("\n" + Language.get("Mod.downloadHint", "Download: ") + curMod.downloadLink);
		}

		// API version incompatibility warning
		if (curMod.incompatibleReason != null) {
			descLines.push("\n" + Language.get("Mod.incompatible", "⚠ INCOMPATIBLE: ") + curMod.incompatibleReason);
		}

		if (curMod.mustRestart) {
			descLines.push("\n" + Language.get("Mod.restart", "(This Mod will restart the game!)"));
		}

		modDesc.text = descLines.join("");

		// ── 更新描述滑条范围 ──
		var visibleH:Float = bgDescription.height - 115;
		modDescMaxScroll = Math.max(0, modDesc.height - visibleH);
		modDescScroll = 0;
		modDesc.y = bgDescription.y + 15;

		settingsButton.enabled = (curMod.settings != null && curMod.settings.length > 0);
	}

	var centerMod:Int = 2;
	function updateItemPositions()
	{
		#if HSCRIPT_ALLOWED
		callOnHscript('onUpdateItemPositions', []);
		#end
		var maxVisible = Math.max(4, centerMod + 2);
		var minVisible = Math.max(0, centerMod - 2);
		for (i => mod in modsGroup.members)
		{
			if(mod == null) continue;

			mod.visible = (i >= minVisible && i <= maxVisible);
			mod.x = bgList.x + 5;
			if (!holdingMod || i != curSelectedMod)
			{
				mod.y = bgList.y + (86 * (i - centerMod + 2)) + 5;
			}
			mod.alpha = 0.6;
			if(i == curSelectedMod) mod.alpha = 1;
			mod.selectBg.visible = (i == curSelectedMod);
		}
	}

function moveModToPosition(position:Int)
{
	if (position >= modsList.length) position = 0;
	else if (position < 0) position = modsList.length - 1;
	if (position == curSelectedMod) return;

	var movedMod = modsList.splice(curSelectedMod, 1)[0];
	var movedItem = modsGroup.members.splice(curSelectedMod, 1)[0];

	modsList.insert(position, movedMod);
	modsGroup.members.insert(position, movedItem);

	curSelectedMod = position;

	if (!holdingMod)
	{
		updateModDisplayData();
		updateItemPositions();
	}
	else
	{
		if (Math.abs(centerMod - curSelectedMod) > 2)
		{
			if (centerMod < curSelectedMod) centerMod = curSelectedMod - 2;
			else centerMod = curSelectedMod + 2;
		}
		var curMod = modsGroup.members[curSelectedMod];
		if (curMod != null)
		{
			if (colorTween != null)
			{
				colorTween.cancel();
				colorTween.destroy();
			}
			colorTween = FlxTween.color(bg, 0.5, bg.color, curMod.bgColor);
			icon.loadGraphic(curMod.icon.graphic);
			icon.setGraphicSize(150, 150);
			icon.updateHitbox();
			modName.text = curMod.name;
			modName.scale.set(0.8, 0.8);
			modName.isMenuItem = false;
			modName.x = icon.x + 165;
			modName.y = modNameInitialY - (modName.height / 2);
			modRestartText.visible = curMod.mustRestart;
			modDesc.text = curMod.desc;
			if (ClientPrefs.data.language != 'English' && curMod.langdescription != null)
				modDesc.text = curMod.langdescription;
			if (curMod.mustRestart)
				modDesc.text += "\n" + Language.get("Mod.restart", "(This Mod will restart the game!)");
			settingsButton.enabled = (curMod.settings != null && curMod.settings.length > 0);
		}
		updateItemPositions();
	}

	FlxG.sound.play(Paths.sound('scrollMenu'), 0.6);
}

	function reload()
	{
		#if HSCRIPT_ALLOWED
		callOnHscript('onReload', []);
		#end
		saveTxt();
		FlxG.autoPause = ClientPrefs.data.autoPause;
		FlxTransitionableState.skipNextTransIn = true;
		FlxTransitionableState.skipNextTransOut = true;
		var curMod:ModItem = modsGroup.members[curSelectedMod];
		MusicBeatState.switchState(new ModsMenuState(curMod != null ? curMod.folder : null));
	}
	
	function saveTxt()
	{
		var fileStr:String = '';
		for (values in modsList)
		{
			if(fileStr.length > 0) fileStr += '\n';
			fileStr += values[0] + '|' + (values[1] ? '1' : '0');
		}

		var path:String = 'modsList.txt';
		File.saveContent(path, fileStr);
		Paths.pushGlobalMods();
	}
	override function destroy() {
		instance = null;
		super.destroy();
	}
}

class ModItem extends FlxSpriteGroup
{
	public var selectBg:FlxSprite;
	public var icon:FlxSprite;
	public var text:FlxText;
	public var totalFrames:Int = 0;

	public var name:String = 'Unknown Mod';
	public var desc:String = 'No description provided.';
	public var langdescription:String = null;
	public var iconFps:Int = 10;
	public var bgColor:FlxColor = 0xFF665AFF;
	public var folder:String = 'unknownMod';
	public var mustRestart:Bool = false;
	public var settings:Array<Dynamic> = null;

	// ── Extended metadata (from ModConfig) ──
	public var author:String = "";
	public var modVersion:String = "";
	public var downloadLink:String = "";
	public var apiVersion:Int = 0;
	public var incompatibleReason:String = null;

	public function new(folder:String)
	{
		super();

		this.folder = folder;
		this.name = folder;

		// ── Load metadata via ModConfig (pack.json) ──
		var cfg:ModConfig = ModConfig.load(folder);
		if (cfg != null)
		{
			if (cfg.name.length > 0 && cfg.name != "Name") this.name = cfg.name;
			if (cfg.description.length > 0 && cfg.description != "Description") this.desc = cfg.description;
			this.author = cfg.author;
			this.modVersion = cfg.version;
			this.downloadLink = cfg.downloadLink;
			this.apiVersion = cfg.apiVersion;
			this.mustRestart = cfg.restartRequired;

			if (cfg.color.length >= 3)
				this.bgColor = FlxColor.fromRGB(cfg.color[0], cfg.color[1], cfg.color[2]);

			// ── API version compatibility ──
			if (!ModConfig.isCompatible(cfg))
				this.incompatibleReason = ModConfig.incompatibilityReason(cfg);
		}

		// ── Localised description from raw pack.json (language‑specific fields) ──
		var rawPackPath = Paths.mods(folder + '/pack.json');
		if(FileSystem.exists(rawPackPath)) {
			try {
				var rawJson = backend.JsonUtil.parseTolerant(File.getContent(rawPackPath));
				var langDescKey = Language.get("Mod.description");
				if(langDescKey != null && Reflect.hasField(rawJson, langDescKey))
					this.langdescription = Reflect.field(rawJson, langDescKey);
			} catch(e:Dynamic) {}
		}

		selectBg = new FlxSprite().makeGraphic(1, 1, FlxColor.WHITE);
		selectBg.alpha = 0.8;
		selectBg.visible = false;
		add(selectBg);

		icon = new FlxSprite(5, 5);
		icon.antialiasing = ClientPrefs.data.globalAntialiasing;
		add(icon);

		text = new FlxText(95, 38, 230, "", 16);

		// ── Icon (needs `icon` to be created first) ──
		var iconPath = Paths.mods('${folder}/pack.png');
		if(FileSystem.exists(iconPath)) {
			var bmp = BitmapData.fromFile(iconPath);
			icon.loadGraphic(bmp, true, 150, 150);
			totalFrames = Math.floor(bmp.width / 150) * Math.floor(bmp.height / 150);
		} else {
			icon.loadGraphic(Paths.image('unknownMod'), true, 150, 150);
		}

		// ── Settings ──
		var settingsPath = Paths.mods('$folder/data/settings.json');
		if(FileSystem.exists(settingsPath))
		{
			try { settings = tjson.TJSON.parse(File.getContent(settingsPath)); }
			catch(e:Dynamic) { TraceManager.error('trace.modsMenu.settingsError', 'Error loading mod settings: {}', [e]); }
		}
		text.setFormat(Paths.languageFont(), 16, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		text.borderSize = 2;
		text.y -= Std.int(text.height / 2);
		add(text);

		var iconPath = Paths.mods('${folder}/pack.png');
		if(FileSystem.exists(iconPath)) {
			var bmp = BitmapData.fromFile(iconPath);
			icon.loadGraphic(bmp, true, 150, 150);
			totalFrames = Math.floor(bmp.width / 150) * Math.floor(bmp.height / 150);
		} else {
			icon.loadGraphic(Paths.image('unknownMod'), true, 150, 150);
		}
		icon.scale.set(0.5, 0.5);
		icon.updateHitbox();
		
		text.text = this.name;
		selectBg.scale.set(width + 5, height + 5);
		selectBg.updateHitbox();
	}
}

class MenuButton extends FlxSpriteGroup
{
	public var bg:FlxSprite;
	public var textOn:FlxTextMenuItem;
	public var textOff:FlxTextMenuItem;
	public var icon:FlxSprite;
	public var onClick:Void->Void = null;
	public var enabled(default, set):Bool = true;
	public var onFocus(default, set):Bool = false;
	public var ignoreCheck:Bool = false;
	
	public function new(x:Float, y:Float, width:Int, height:Int, ?text:String = null, ?img:FlxGraphic = null, onClick:Void->Void = null, animWidth:Int = 0, animHeight:Int = 0)
	{
		super(x, y);
		bg = FlxSpriteUtil.drawRoundRect(new FlxSprite().makeGraphic(width, height, FlxColor.TRANSPARENT), 0, 0, width, height, 15, 15, FlxColor.WHITE);
		bg.color = FlxColor.BLACK;
		add(bg);

		if(text != null)
		{
			textOn = new FlxTextMenuItem(0, 0, text, 48);
			textOn.scale.set(0.6, 0.6);
			textOn.alpha = 0.6;
			textOn.visible = false;
			textOn.isMenuItem = false;
			centerOnBg(textOn);
			add(textOn);
			
			textOff = new FlxTextMenuItem(0, 0, text, 48);
			textOff.scale.set(0.6, 0.6);
			textOff.alpha = 0.6;
			textOff.isMenuItem = false;
			centerOnBg(textOff);
			add(textOff);
		}
		else if(img != null)
		{
			icon = new FlxSprite();
			if(animWidth > 0 || animHeight > 0) icon.loadGraphic(img, true, animWidth, animHeight);
			else icon.loadGraphic(img);
			centerOnBg(icon);
			add(icon);
		}

		this.onClick = onClick;
		setButtonVisibility(false);
	}

	function set_enabled(newValue:Bool)
	{
		enabled = newValue;
		setButtonVisibility(false);
		alpha = enabled ? 1 : 0.4;
		return newValue;
	}

	function set_onFocus(newValue:Bool)
	{
		if(enabled) setButtonVisibility(newValue);
		onFocus = newValue;
		return newValue;
	}

	public var focusChangeCallback:Bool->Void = null;
	public function setButtonVisibility(focusVal:Bool)
	{
		alpha = 1;
		bg.color = focusVal ? FlxColor.WHITE : FlxColor.BLACK;
		bg.alpha = focusVal ? 0.8 : 0.6;

		var focusAlpha = focusVal ? 1 : 0.6;
		if(textOn != null && textOff != null)
		{
			textOn.alpha = textOff.alpha = focusAlpha;
			textOn.visible = focusVal;
			textOff.visible = !focusVal;
		}
		else if(icon != null)
		{
			icon.alpha = focusAlpha;
			icon.color = focusVal ? FlxColor.BLACK : FlxColor.WHITE;
		}

		if(!enabled) alpha = 0.4;
		if(focusChangeCallback != null) focusChangeCallback(focusVal);
	}

	public function centerOnBg(spr:FlxSprite)
	{
		spr.x = bg.width/2 - spr.width/2;
		spr.y = bg.height/2 - spr.height/2;
	}
	
	override public function update(elapsed:Float)
	{
		super.update(elapsed);
		
		if(!enabled)
		{
			onFocus = false;
			return;
		}

		if(!ignoreCheck && FlxG.mouse.justMoved && FlxG.mouse.visible)
			onFocus = FlxG.mouse.overlaps(this);

		if(onFocus && onClick != null && FlxG.mouse.justPressed)
			onClick();
	}
}
