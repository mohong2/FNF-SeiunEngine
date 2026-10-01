package substates;

import backend.MusicBeatSubstate;
import WeekData;
import FlxTextMenuItem;
import openfl.display.BitmapData;
#if MODS_ALLOWED
import sys.FileSystem;
#end

class ModSelectSubstate extends MusicBeatSubstate
{
	public var modList:Array<String>;
	public var curSelectedMod:Int;
	public var onConfirm:Int->Void;
	public var onCancel:Void->Void;

	// UI elements
	/** If true, the restart warning is hidden (used by Freeplay which only filters songs). */
	public var suppressRestartWarning:Bool = false;

	var bgOverlay:FlxSprite;
	var modIconLeft:FlxSprite;
	var modIconCenter:FlxSprite;
	var modIconRight:FlxSprite;
	var modNameLeft:FlxTextMenuItem;
	var modNameCenter:FlxTextMenuItem;
	var modNameRight:FlxTextMenuItem;
	var hintText:FlxText;
	var restartWarning:FlxText;
	var transitioning:Bool = false;

	public function new(modList:Array<String>, curSelectedMod:Int, ?onConfirm:Int->Void, ?onCancel:Void->Void)
	{
		super();
		this.modList = modList;
		this.curSelectedMod = curSelectedMod;
		this.onConfirm = onConfirm;
		this.onCancel = onCancel;
	}

	override function create()
	{
		// Dark overlay background — fix to screen so it covers viewport regardless of camera scroll
		bgOverlay = new FlxSprite().makeGraphic(FlxG.width, FlxG.height, FlxColor.BLACK);
		bgOverlay.scrollFactor.set(0, 0);
		bgOverlay.alpha = 0;
		add(bgOverlay);
		FlxTween.tween(bgOverlay, {alpha: 0.85}, 0.2);

		// Left mod
		modIconLeft = new FlxSprite();
		modIconLeft.scrollFactor.set(0, 0);
		modIconLeft.antialiasing = ClientPrefs.data.globalAntialiasing;
		add(modIconLeft);

		modNameLeft = new FlxTextMenuItem(0, 0, '', 26);
		modNameLeft.scrollFactor.set(0, 0);
		modNameLeft.isMenuItem = false;
		modNameLeft.setFormat(Paths.languageFont(), 26, FlxColor.WHITE, CENTER);
		add(modNameLeft);

		// Center mod
		modIconCenter = new FlxSprite();
		modIconCenter.scrollFactor.set(0, 0);
		modIconCenter.antialiasing = ClientPrefs.data.globalAntialiasing;
		add(modIconCenter);

		modNameCenter = new FlxTextMenuItem(0, 0, '', 36);
		modNameCenter.scrollFactor.set(0, 0);
		modNameCenter.isMenuItem = false;
		modNameCenter.setFormat(Paths.languageFont(), 36, FlxColor.WHITE, CENTER);
		add(modNameCenter);

		// Right mod
		modIconRight = new FlxSprite();
		modIconRight.scrollFactor.set(0, 0);
		modIconRight.antialiasing = ClientPrefs.data.globalAntialiasing;
		add(modIconRight);

		modNameRight = new FlxTextMenuItem(0, 0, '', 26);
		modNameRight.scrollFactor.set(0, 0);
		modNameRight.isMenuItem = false;
		modNameRight.setFormat(Paths.languageFont(), 26, FlxColor.WHITE, CENTER);
		add(modNameRight);

		// Hint text
		hintText = new FlxText(0, FlxG.height - 50, FlxG.width, '', 18);
		hintText.scrollFactor.set(0, 0);
		hintText.setFormat(Paths.languageFont(), 18, FlxColor.WHITE, CENTER);
		hintText.alpha = 0.7;
		add(hintText);

		// Restart warning text (shown when selected mod requires restart)
		restartWarning = new FlxText(0, 0, FlxG.width, '', 20);
		restartWarning.scrollFactor.set(0, 0);
		restartWarning.setFormat(Paths.languageFont(), 20, 0xFFFF6666, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		restartWarning.borderSize = 1.5;
		add(restartWarning);

		updatePositions(true);

		// Start with a fade-in scale effect on center
		modIconCenter.scale.set(0.5, 0.5);
		modNameCenter.alpha = 0;
		FlxTween.tween(modIconCenter.scale, {x: 1.0, y: 1.0}, 0.3, {ease: FlxEase.backOut});
		FlxTween.tween(modNameCenter, {alpha: 1.0}, 0.3);

		#if (TOUCH_CONTROLS || desktop)
		addVirtualPad(LEFT_RIGHT, A_B);
		addPadCamera();
		#end

		super.create();
	}

	function updatePositions(instant:Bool = false)
	{
		var centerX:Float = FlxG.width / 2;
		var centerY:Float = FlxG.height / 2 - 50;
		var spacing:Float = 300;

		// === Center ===
		var displayName:String = WeekData.getModFolderDisplayName(modList[curSelectedMod]);
		modNameCenter.text = displayName;
		modNameCenter.screenCenter(X);
		modNameCenter.y = centerY + 100;

		loadModIcon(modIconCenter, modList[curSelectedMod]);
		modIconCenter.setGraphicSize(120, 120);
		modIconCenter.updateHitbox();
		modIconCenter.screenCenter(X);
		modIconCenter.y = centerY - 50;
		modIconCenter.alpha = 1.0;

		if (!instant)
		{
			modIconCenter.scale.set(0.5, 0.5);
			modNameCenter.alpha = 0;
			FlxTween.tween(modIconCenter.scale, {x: 1.0, y: 1.0}, 0.25, {ease: FlxEase.backOut});
			FlxTween.tween(modNameCenter, {alpha: 1.0}, 0.2);
		}

		// === Left ===
		if (modList.length > 1)
		{
			var leftIdx:Int = (curSelectedMod > 0) ? curSelectedMod - 1 : modList.length - 1;
			modNameLeft.text = WeekData.getModFolderDisplayName(modList[leftIdx]);
			modNameLeft.x = centerX - spacing - modNameLeft.width / 2;
			modNameLeft.y = centerY + 80;
			modNameLeft.alpha = 0.4;

			loadModIcon(modIconLeft, modList[leftIdx]);
			modIconLeft.setGraphicSize(80, 80);
			modIconLeft.updateHitbox();
			modIconLeft.x = centerX - spacing - modIconLeft.width / 2;
			modIconLeft.y = centerY - 30;
			modIconLeft.alpha = 0.4;
			modIconLeft.visible = true;
			modNameLeft.visible = true;
		}
		else
		{
			modIconLeft.visible = false;
			modNameLeft.visible = false;
		}

		// === Right ===
		if (modList.length > 1)
		{
			var rightIdx:Int = (curSelectedMod + 1) % modList.length;
			modNameRight.text = WeekData.getModFolderDisplayName(modList[rightIdx]);
			modNameRight.x = centerX + spacing - modNameRight.width / 2;
			modNameRight.y = centerY + 80;
			modNameRight.alpha = 0.4;

			loadModIcon(modIconRight, modList[rightIdx]);
			modIconRight.setGraphicSize(80, 80);
			modIconRight.updateHitbox();
			modIconRight.x = centerX + spacing - modIconRight.width / 2;
			modIconRight.y = centerY - 30;
			modIconRight.alpha = 0.4;
			modIconRight.visible = true;
			modNameRight.visible = true;
		}
		else
		{
			modIconRight.visible = false;
			modNameRight.visible = false;
		}

		hintText.text = ClientPrefs.touchUIEnabled()
			? Language.get('Mod.selectHint.android', '← →  Switch Mod    A  Confirm    B  Cancel')
			: Language.get('Mod.selectHint', '← →  Switch Mod    ENTER / TAB  Confirm    ESC  Cancel');
		hintText.screenCenter(X);

		// Update restart warning for the currently selected mod
		updateRestartWarning();
	}

	function updateRestartWarning()
	{
		if (suppressRestartWarning)
		{
			restartWarning.visible = false;
			return;
		}
		var modFolder:String = modList[curSelectedMod];
		if (modFolder == null || modFolder.length == 0)
		{
			restartWarning.visible = false;
			return;
		}

		var needsRestart:Bool = false;
		#if MODS_ALLOWED
		var packPath = Paths.mods(modFolder + '/pack.json');
		if (FileSystem.exists(packPath))
		{
			try
			{
				var rawJson:String = File.getContent(packPath);
				if (rawJson != null && rawJson.length > 0)
				{
					var stuff:Dynamic = backend.JsonUtil.parseTolerant(rawJson);
					needsRestart = Reflect.getProperty(stuff, "restart") == true;
				}
			}
			catch (e:Dynamic) {}
		}
		#end

		if (needsRestart)
		{
			restartWarning.text = Language.get("Mod.restartSubstate", "⚠ This mod requires a game restart to take full effect!");
			restartWarning.screenCenter(X);
			restartWarning.y = FlxG.height / 2 + 170;
			restartWarning.visible = true;
		}
		else
		{
			restartWarning.visible = false;
		}
	}

	function loadModIcon(icon:FlxSprite, modFolder:String)
	{
		if (modFolder == null || modFolder == '')
		{
			icon.loadGraphic(Paths.image('unknownMod'));
		}
		else
		{
			#if MODS_ALLOWED
			var iconPath = Paths.mods('${modFolder}/pack.png');
			if (FileSystem.exists(iconPath))
			{
				var bmp = BitmapData.fromFile(iconPath);
				icon.loadGraphic(bmp, true, 150, 150);
				var totalFrames = Math.floor(bmp.width / 150) * Math.floor(bmp.height / 150);
				if (totalFrames > 1)
				{
					icon.animation.add("icon", [for (i in 0...totalFrames) i], 10);
					icon.animation.play("icon");
				}
				return;
			}
			#end
			icon.loadGraphic(Paths.image('unknownMod'));
		}
	}

	override function update(elapsed:Float)
	{
		if (transitioning)
		{
			super.update(elapsed);
			return;
		}

		// ENTER or TAB to confirm
		if (FlxG.keys.justPressed.ENTER || FlxG.keys.justPressed.TAB
			#if (TOUCH_CONTROLS || desktop) || (virtualPad != null && virtualPad.buttonA.justPressed) #end)
		{
			transitioning = true;
			FlxG.sound.play(Paths.sound('confirmMenu'), 0.7);

			// Fade out and close
			FlxTween.tween(bgOverlay, {alpha: 0}, 0.15);
			FlxTween.tween(modIconCenter.scale, {x: 0.3, y: 0.3}, 0.15, {ease: FlxEase.backIn});
			FlxTween.tween(modNameCenter, {alpha: 0}, 0.15);
			new FlxTimer().start(0.15, function(_) {
				if (onConfirm != null) onConfirm(curSelectedMod);
				close();
			});
			super.update(elapsed);
			return;
		}

		// ESC or BACKSPACE to cancel
		if (FlxG.keys.justPressed.ESCAPE || FlxG.keys.justPressed.BACKSPACE
			#if (TOUCH_CONTROLS || desktop) || (virtualPad != null && virtualPad.buttonB.justPressed) #end)
		{
			transitioning = true;
			FlxG.sound.play(Paths.sound('cancelMenu'), 0.6);

			FlxTween.tween(bgOverlay, {alpha: 0}, 0.15);
			FlxTween.tween(modIconCenter.scale, {x: 0.3, y: 0.3}, 0.15, {ease: FlxEase.backIn});
			FlxTween.tween(modNameCenter, {alpha: 0}, 0.15);
			new FlxTimer().start(0.15, function(_) {
				if (onCancel != null) onCancel();
				close();
			});
			super.update(elapsed);
			return;
		}

		// Left/Right to cycle mods with smooth transition
		if (FlxG.keys.justPressed.LEFT
			#if (TOUCH_CONTROLS || desktop) || (virtualPad != null && virtualPad.buttonLeft.justPressed) #end)
		{
			var prev = curSelectedMod - 1;
			if (prev < 0) prev = modList.length - 1;
			curSelectedMod = prev;
			updatePositions(false);
			updateRestartWarning();
			FlxG.sound.play(Paths.sound('scrollMenu'), 0.4);
		}
		if (FlxG.keys.justPressed.RIGHT
			#if (TOUCH_CONTROLS || desktop) || (virtualPad != null && virtualPad.buttonRight.justPressed) #end)
		{
			curSelectedMod = (curSelectedMod + 1) % modList.length;
			updatePositions(false);
			updateRestartWarning();
			FlxG.sound.play(Paths.sound('scrollMenu'), 0.4);
		}

		super.update(elapsed);
	}

	#if (TOUCH_CONTROLS || desktop)
	override function destroy() {
		removeVirtualPad();
		super.destroy();
	}
	#end
}
