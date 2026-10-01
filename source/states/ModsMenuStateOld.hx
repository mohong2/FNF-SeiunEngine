package states;

#if desktop
import Discord.DiscordClient;
#end
import haxe.Json;
import haxe.format.JsonParser;
import openfl.display.BitmapData;
import flash.geom.Rectangle;
import flixel.ui.FlxButton;
import flixel.FlxBasic;
import sys.io.File;
/*import haxe.zip.Reader;
import haxe.zip.Entry;
import haxe.zip.Uncompress;
import haxe.zip.Writer;*/
import options.ModSettingsSubState;
import mohong.TraceManager;
using StringTools;

class ModsMenuStateOld extends MusicBeatState
{
	var instance:ModsMenuStateOld;
	var mods:Array<ModMetadata> = [];
	static var changedAThing = false;
	var bg:FlxSprite;
	var intendedColor:Int;
	var colorTween:FlxTween;

	var noModsTxt:FlxText;
	var selector:AttachedSprite;
	var descriptionTxt:FlxText;
	private static var curSelected:Int = 0;
	public static var defaultColor:FlxColor = 0xFF665AFF;
	//0.7.3
	var buttonSettings:FlxButton; 
	var buttonIcons:Map<FlxButton, FlxSprite> = [];

	var buttonDown:FlxButton;
	var buttonTop:FlxButton;
	var buttonDisableAll:FlxButton;
	var buttonEnableAll:FlxButton;
	var buttonUp:FlxButton;
	var buttonToggle:FlxButton;
	var buttonsArray:Array<FlxButton> = [];

	var installButton:FlxButton;
	var removeButton:FlxButton;

	var modsList:Array<Dynamic> = [];

	var visibleWhenNoMods:Array<FlxBasic> = [];
	var visibleWhenHasMods:Array<FlxBasic> = [];

	override function create()
	{
		instance = this;
		Paths.clearStoredMemory();
		Paths.clearUnusedMemory();
		WeekData.setDirectoryFromWeek();
		#if desktop
		FlxG.mouse.visible = true;
		
		// Updating Discord Rich Presence
		DiscordClient.changePresence("In the Menus", null);
		#end

		bg = new FlxSprite().loadGraphic(Paths.image('menuDesat'));
		bg.antialiasing = ClientPrefs.data.globalAntialiasing;
		add(bg);
		bg.screenCenter();

		noModsTxt = new FlxText(0, 0, FlxG.width, Language.get("Mod.noModsTxt", "NO MODS INSTALLED\nPRESS BACK TO EXIT AND INSTALL A MOD"), 48);
		if(FlxG.random.bool(0.1)) noModsTxt.text += '\nBITCH.'; //meanie
		noModsTxt.setFormat(Paths.languageFont(), 32, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		noModsTxt.scrollFactor.set();
		noModsTxt.borderSize = 2;
		add(noModsTxt);
		noModsTxt.screenCenter();
		visibleWhenNoMods.push(noModsTxt);

		var path:String = 'modsList.txt';
		if(FileSystem.exists(path))
		{
			var leMods:Array<String> = CoolUtil.coolTextFile(path);
			for (i in 0...leMods.length)
			{
				if(leMods.length > 1 && leMods[0].length > 0) {
					var modSplit:Array<String> = leMods[i].split('|');
					if(!Paths.ignoreModFolders.contains(modSplit[0].toLowerCase()))
					{
						addToModsList([modSplit[0], (modSplit[1] == '1')]);
						//trace(modSplit[1]);
					}
				}
			}
		}

		// FIND MOD FOLDERS
		var boolshit = true;
		if (FileSystem.exists("modsList.txt")){
			for (folder in Paths.getModDirectories())
			{
				if(!Paths.ignoreModFolders.contains(folder))
				{
					addToModsList([folder, true]); //i like it false by default. -bb //Well, i like it True! -Shadow
				}
			}
		}
		saveTxt();

		selector = new AttachedSprite();
		selector.xAdd = -205;
		selector.yAdd = -68;
		selector.alphaMult = 0.5;
		makeSelectorGraphic();
		add(selector);
		visibleWhenHasMods.push(selector);
		var settings:String = Language.get("Mod.settings", "settings");
		var top:String = Language.get("Mod.top", "TOP");
		var disableAll:String = Language.get("Mod.disableAll", "DisableAll");
		var enableAll:String = Language.get("Mod.enableAll", "EnableAll");


		//attached buttons
		var startX:Int = 1120;

		buttonToggle = new FlxButton(startX, 0, "ON", function()
		{
			modsList[curSelected][1] = !modsList[curSelected][1];
			updateButtonToggle();
			FlxG.sound.play(Paths.sound('scrollMenu'), 0.6);
		});
		buttonToggle.setGraphicSize(50, 50);
		buttonToggle.updateHitbox();
		add(buttonToggle);
		buttonsArray.push(buttonToggle);
		visibleWhenHasMods.push(buttonToggle);

		buttonToggle.label.setFormat(Paths.languageFont(), 24, FlxColor.WHITE, CENTER);
		setAllLabelsOffset(buttonToggle, -15, 10);
		startX -= 70;

		buttonUp = new FlxButton(startX, 0, "/\\", function()
		{
			moveMod(-1);
			FlxG.sound.play(Paths.sound('scrollMenu'), 0.6);
		});
		buttonUp.setGraphicSize(50, 50);
		buttonUp.updateHitbox();
		add(buttonUp);
		buttonsArray.push(buttonUp);
		visibleWhenHasMods.push(buttonUp);
		buttonUp.label.setFormat(Paths.languageFont(), 24, FlxColor.BLACK, CENTER);
		setAllLabelsOffset(buttonUp, -15, 10);
		startX -= 70;

		buttonDown = new FlxButton(startX, 0, "\\/", function() {
			moveMod(1);
			FlxG.sound.play(Paths.sound('scrollMenu'), 0.6);
		});
		buttonDown.setGraphicSize(50, 50);
		buttonDown.updateHitbox();
		add(buttonDown);
		buttonsArray.push(buttonDown);
		visibleWhenHasMods.push(buttonDown);
		buttonDown.label.setFormat(Paths.languageFont(), 24, FlxColor.BLACK, CENTER);
		setAllLabelsOffset(buttonDown, -15, 10);

		startX -= 100;
		buttonTop = new FlxButton(startX, 0, top, function() {
			for (i in 0...curSelected) //so it shifts to the top instead of replacing the top one
			{
				moveMod(-1, true);
			}
			FlxG.sound.play(Paths.sound('scrollMenu'), 0.6);
		});
		buttonTop.setGraphicSize(80, 50);
		buttonTop.updateHitbox();
		buttonTop.label.setFormat(Paths.languageFont(), 24, FlxColor.BLACK, CENTER);
		setAllLabelsOffset(buttonTop, 0, 10);
		add(buttonTop);
		buttonsArray.push(buttonTop);
		visibleWhenHasMods.push(buttonTop);


		startX -= 190;
		buttonDisableAll = new FlxButton(startX, 0, disableAll, function() {
			for (i in modsList)
			{
				i[1] = false;
			}
			updateButtonToggle();
			FlxG.sound.play(Paths.sound('scrollMenu'), 0.6);
		});
		buttonDisableAll.setGraphicSize(170, 50);
		buttonDisableAll.updateHitbox();
		buttonDisableAll.label.setFormat(Paths.languageFont(), 24, FlxColor.BLACK, CENTER);
		buttonDisableAll.label.fieldWidth = 170;
		setAllLabelsOffset(buttonDisableAll, 0, 10);
		add(buttonDisableAll);
		buttonsArray.push(buttonDisableAll);
		visibleWhenHasMods.push(buttonDisableAll);

		startX -= 190;
		buttonEnableAll = new FlxButton(startX, 0, enableAll, function() {
			for (i in modsList)
			{
				i[1] = true;
			}
			updateButtonToggle();
			FlxG.sound.play(Paths.sound('scrollMenu'), 0.6);
		});
		buttonEnableAll.setGraphicSize(170, 50);
		buttonEnableAll.updateHitbox();
		buttonEnableAll.label.setFormat(Paths.languageFont(), 24, FlxColor.BLACK, CENTER);
		buttonEnableAll.label.fieldWidth = 170;
		setAllLabelsOffset(buttonEnableAll, 0, 10);
		add(buttonEnableAll);
		buttonsArray.push(buttonEnableAll);
		visibleWhenHasMods.push(buttonEnableAll);

		// more buttons
		var startX:Int = 1100;

		buttonSettings = new FlxButton(410, 10, settings, function() {
		openModSettings();
		FlxG.sound.play(Paths.sound('scrollMenu'), 0.6);
		});
		buttonSettings.setGraphicSize(80, 50);
		buttonSettings.updateHitbox();
		add(buttonSettings);
		buttonsArray.push(buttonSettings);
		visibleWhenHasMods.push(buttonSettings);
		buttonSettings.label.setFormat(Paths.languageFont(), 18, FlxColor.BLACK, CENTER);
		setAllLabelsOffset(buttonSettings, 0, 10);
		buttonsArray.push(buttonSettings);
		visibleWhenHasMods.push(buttonSettings);



		/*
		installButton = new FlxButton(startX, 620, "Install Mod", function()
		{
			installMod();
		});
		installButton.setGraphicSize(150, 70);
		installButton.updateHitbox();
		installButton.color = FlxColor.GREEN;
		installButton.label.fieldWidth = 135;
		installButton.label.setFormat(Paths.languageFont(), 16, FlxColor.WHITE, CENTER);
		setAllLabelsOffset(installButton, 2, 24);
		add(installButton);
		startX -= 180;

		removeButton = new FlxButton(startX, 620, "Delete Selected Mod", function()
		{
			var path = haxe.io.Path.join([Paths.mods(), modsList[curSelected][0]]);
			if(FileSystem.exists(path) && FileSystem.isDirectory(path))
			{
				TraceManager.info('trace.modsMenuOld.deleteDir', 'Trying to delete directory {}', [path]);
				try
				{
					FileSystem.deleteFile(path); //FUCK YOU HAXE WHY DONT YOU WORK WAAAAAAAAAAAAH

					var icon = mods[curSelected].icon;
					var alphabet = mods[curSelected].alphabet;
					remove(icon);
					remove(alphabet);
					icon.destroy();
					alphabet.destroy();
					modsList.remove(modsList[curSelected]);
					mods.remove(mods[curSelected]);

					if(curSelected >= mods.length) --curSelected;
					changeSelection();
				}
				catch(e)
				{
					TraceManager.error('trace.modsMenuOld.deleteError', 'Error deleting directory: {}', [e]);
				}
			}
		});
		removeButton.setGraphicSize(150, 70);
		removeButton.updateHitbox();
		removeButton.color = FlxColor.RED;
		removeButton.label.fieldWidth = 135;
		removeButton.label.setFormat(Paths.languageFont(), 16, FlxColor.WHITE, CENTER);
		setAllLabelsOffset(removeButton, 2, 15);
		add(removeButton);
		visibleWhenHasMods.push(removeButton);*/

		///////
		descriptionTxt = new FlxText(148, 0, FlxG.width - 216, "", 32);
		descriptionTxt.setFormat(Paths.languageFont(), 32, FlxColor.WHITE, LEFT);
		descriptionTxt.scrollFactor.set();
		add(descriptionTxt);
		visibleWhenHasMods.push(descriptionTxt);

		var i:Int = 0;
		var len:Int = modsList.length;
		while (i < modsList.length)
		{
			var values:Array<Dynamic> = modsList[i];
			if(!FileSystem.exists(Paths.mods(values[0])))
			{
				modsList.remove(modsList[i]);
				continue;
			}

			var newMod:ModMetadata = new ModMetadata(values[0]);
			mods.push(newMod);

			newMod.alphabet = new Alphabet(0, 0, mods[i].name, true);
			var scale:Float = Math.min(840 / newMod.alphabet.width, 1);
			newMod.alphabet.scaleX = scale;
			newMod.alphabet.scaleY = scale;
			newMod.alphabet.y = i * 150;
			newMod.alphabet.x = 310;
			add(newMod.alphabet);
			//Don't ever cache the icons, it's a waste of loaded memory
			var loadedIcon:BitmapData = null;
			var iconToUse:String = Paths.mods(values[0] + '/pack.png');
			if(FileSystem.exists(iconToUse))
			{
				loadedIcon = BitmapData.fromFile(iconToUse);
			}

			newMod.icon = new AttachedSprite();
			if(loadedIcon != null)
			{
				newMod.icon.loadGraphic(loadedIcon, true, 150, 150);//animated icon support
				var totalFrames = Math.floor(loadedIcon.width / 150) * Math.floor(loadedIcon.height / 150);
				newMod.icon.animation.add("icon", [for (i in 0...totalFrames) i],10);
				newMod.icon.animation.play("icon");
			}
			else
			{
				newMod.icon.loadGraphic(Paths.image('unknownMod'));
			}
			newMod.icon.sprTracker = newMod.alphabet;
			newMod.icon.xAdd = -newMod.icon.width - 30;
			newMod.icon.yAdd = -45;
			add(newMod.icon);
			i++;
		}

		if(curSelected >= mods.length) curSelected = 0;

		if(mods.length < 1)
			bg.color = defaultColor;
		else
			bg.color = mods[curSelected].color;

		intendedColor = bg.color;
		changeSelection();
		updatePosition();
		FlxG.sound.play(Paths.sound('scrollMenu'));

		#if (TOUCH_CONTROLS || desktop)
		addVirtualPad(UP_DOWN, B);
		#end
		#if LUA_ALLOWED
		initLuaScripts();
		setOnLuas('controls', controls);
		setOnLuas('state', this);
		callOnLuas('onCreatePost', []);
		#end
		super.create();

		// === Mod loading tip (v0.2.1+) — after super.create so Language is loaded ===
		var loadingTip:FlxText = new FlxText(15, FlxG.height - 30, FlxG.width - 30,
			Language.get("Mod.loadingTip", "Since v0.2.1: Top mod here no longer affects game assets.\nSelect your active mod in Main Menu -> Mod Select."), 13);
		loadingTip.setFormat(Paths.languageFont(), 13, 0xFFFFCC00, CENTER);
		loadingTip.scrollFactor.set();
		add(loadingTip);
	}
			function updateButtonPositions()
	{
		for (button in buttonsArray)
		{
			if (buttonIcons.exists(button))
			{
				var icon = buttonIcons.get(button);
				icon.x = button.x;
				icon.y = button.y;
			}
		}
	}
	function openModSettings()
	{
		if (mods.length == 0) return;
		
		var curMod = mods[curSelected];
		var folder = curMod.folder;
		
		var settings = loadModSettings(folder);
		if (settings != null && settings.length > 0)
		{
			openSubState(new ModSettingsSubState(settings, folder, curMod.name));
		}
		else
		{
			FlxG.sound.play(Paths.sound('cancelMenu'));
		}
	}
	
	function loadModSettings(folder:String):Array<Dynamic>
	{
		var path = Paths.mods(folder + '/data/settings.json');
		if (FileSystem.exists(path))
		{
			try
			{
				var rawJson = File.getContent(path);
				return backend.JsonUtil.parseTolerant(rawJson);
			}
			catch (e:Dynamic)
			{
				TraceManager.error('trace.modsMenuOld.settingsError', 'Error loading settings: {}', [e]);
			}
		}
		return null;
	}





	/*function getIntArray(max:Int):Array<Int>{
		var arr:Array<Int> = [];
		for (i in 0...max) {
			arr.push(i);
		}
		return arr;
	}*/
	function addToModsList(values:Array<Dynamic>)
	{
		for (i in 0...modsList.length)
		{
			if(modsList[i][0] == values[0])
			{
				//trace(modsList[i][0], values[0]);
				return;
			}
		}
		modsList.push(values);
	}

	function updateButtonToggle()
	{
		if (modsList[curSelected][1])
		{
			buttonToggle.label.text = Language.get("Mod.ON", "ON");
			buttonToggle.color = FlxColor.GREEN;
		}
		else
		{
			buttonToggle.label.text = Language.get("Mod.OFF", "OFF");
			buttonToggle.color = FlxColor.RED;
		}
	}

	function moveMod(change:Int, skipResetCheck:Bool = false)
	{
		if(mods.length > 1)
		{
			var newPos:Int = curSelected + change;
			if(newPos < 0)
			{
				modsList.push(modsList.shift());
				mods.push(mods.shift());
			}
			else if(newPos >= mods.length)
			{
				modsList.insert(0, modsList.pop());
				mods.insert(0, mods.pop());
			}
			else
			{
				var lastArray:Array<Dynamic> = modsList[curSelected];
				modsList[curSelected] = modsList[newPos];
				modsList[newPos] = lastArray;

				var lastMod:ModMetadata = mods[curSelected];
				mods[curSelected] = mods[newPos];
				mods[newPos] = lastMod;
			}
			changeSelection(change);

		}
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

	var noModsSine:Float = 0;
	var canExit:Bool = true;
	override function update(elapsed:Float)
	{
		#if LUA_ALLOWED
		callOnLuas('onUpdate', [elapsed]);
		#end
		#if HSCRIPT_ALLOWED
		callOnHscript('onUpdate', [elapsed]);
		#end
		if(noModsTxt.visible)
		{
			noModsSine += 180 * elapsed;
			noModsTxt.alpha = 1 - Math.sin((Math.PI * noModsSine) / 180);
		}

		if(canExit && controls.BACK)
		{
			if(colorTween != null) {
				colorTween.cancel();
			}
			FlxG.sound.play(Paths.sound('cancelMenu'));
			saveTxt();
			MusicBeatState.switchState(new MainMenuState());
		}

		if(controls.UI_UP_P)
		{
			changeSelection(-1);
			FlxG.sound.play(Paths.sound('scrollMenu'));
		}
		if(controls.UI_DOWN_P)
		{
			changeSelection(1);
			FlxG.sound.play(Paths.sound('scrollMenu'));
		}
		updatePosition(elapsed);
		#if LUA_ALLOWED
		callOnLuas('onUpdatePost', [elapsed]);
		#end
		#if HSCRIPT_ALLOWED
		callOnHscript('onUpdatePost', [elapsed]);
		#end
		super.update(elapsed);
	}

	function setAllLabelsOffset(button:FlxButton, x:Float, y:Float)
	{
		for (point in button.labelOffsets)
		{
			point.set(x, y);
		}
	}

	function changeSelection(change:Int = 0)
	{
		var noMods:Bool = (mods.length < 1);
		for (obj in visibleWhenHasMods)
		{
			obj.visible = !noMods;
		}
		for (obj in visibleWhenNoMods)
		{
			obj.visible = noMods;
		}
		if(noMods) return;

		curSelected += change;
		if(curSelected < 0)
			curSelected = mods.length - 1;
		else if(curSelected >= mods.length)
			curSelected = 0;

		var newColor:Int = mods[curSelected].color;
		if(newColor != intendedColor) {
			if(colorTween != null) {
				colorTween.cancel();
			}
			intendedColor = newColor;
			colorTween = FlxTween.color(bg, 1, bg.color, intendedColor, {
				onComplete: function(twn:FlxTween) {
					colorTween = null;
				}
			});
		}

		var i:Int = 0;
		for (mod in mods)
		{
			mod.alphabet.alpha = 0.6;
			if(i == curSelected)
			{
				mod.alphabet.alpha = 1;
				selector.sprTracker = mod.alphabet;
				descriptionTxt.text = mod.description;

                if (ClientPrefs.data.language == 'Chinese' && mod.zhdescription != null) {
                    descriptionTxt.text = mod.zhdescription;
                }
                
				if (mod.restart){//finna make it to where if nothing changed then it won't reset
					descriptionTxt.text += Language.get("Mod.restart", "(This Mod will restart the game!)");
				}

				// correct layering
				var stuffArray:Array<FlxSprite> = [/*removeButton, installButton,*/ selector, descriptionTxt, mod.alphabet, mod.icon];
				for (obj in stuffArray)
				{
					remove(obj);
					insert(members.length, obj);
				}
				for (obj in buttonsArray)
				{
					remove(obj);
					insert(members.length, obj);
				}
			}
			i++;
		}
		updateButtonToggle();
	}

	function updatePosition(elapsed:Float = -1)
	{
		var i:Int = 0;
		for (mod in mods)
		{
			var intendedPos:Float = (i - curSelected) * 225 + 200;
			if(i > curSelected) intendedPos += 225;
			if(elapsed == -1)
			{
				mod.alphabet.y = intendedPos;
			}
			else
			{
				mod.alphabet.y = FlxMath.lerp(mod.alphabet.y, intendedPos, CoolUtil.boundTo(elapsed * 12, 0, 1));
			}

			if(i == curSelected)
			{
				descriptionTxt.y = mod.alphabet.y + 160;
				for (button in buttonsArray)
				{
					button.y = mod.alphabet.y + 320;
				}
			}
			i++;
		}
	}

	var cornerSize:Int = 11;
	function makeSelectorGraphic()
	{
		selector.makeGraphic(1100, 450, FlxColor.BLACK);
		selector.pixels.fillRect(new Rectangle(0, 190, selector.width, 5), 0x0);

		// Why did i do this? Because i'm a lmao stupid, of course
		// also i wanted to understand better how fillRect works so i did this shit lol???
		selector.pixels.fillRect(new Rectangle(0, 0, cornerSize, cornerSize), 0x0);														 //top left
		drawCircleCornerOnSelector(false, false);
		selector.pixels.fillRect(new Rectangle(selector.width - cornerSize, 0, cornerSize, cornerSize), 0x0);							 //top right
		drawCircleCornerOnSelector(true, false);
		selector.pixels.fillRect(new Rectangle(0, selector.height - cornerSize, cornerSize, cornerSize), 0x0);							 //bottom left
		drawCircleCornerOnSelector(false, true);
		selector.pixels.fillRect(new Rectangle(selector.width - cornerSize, selector.height - cornerSize, cornerSize, cornerSize), 0x0); //bottom right
		drawCircleCornerOnSelector(true, true);
	}

	function drawCircleCornerOnSelector(flipX:Bool, flipY:Bool)
	{
		var antiX:Float = (selector.width - cornerSize);
		var antiY:Float = flipY ? (selector.height - 1) : 0;
		if(flipY) antiY -= 2;
		selector.pixels.fillRect(new Rectangle((flipX ? antiX : 1), Std.int(Math.abs(antiY - 8)), 10, 3), FlxColor.BLACK);
		if(flipY) antiY += 1;
		selector.pixels.fillRect(new Rectangle((flipX ? antiX : 2), Std.int(Math.abs(antiY - 6)),  9, 2), FlxColor.BLACK);
		if(flipY) antiY += 1;
		selector.pixels.fillRect(new Rectangle((flipX ? antiX : 3), Std.int(Math.abs(antiY - 5)),  8, 1), FlxColor.BLACK);
		selector.pixels.fillRect(new Rectangle((flipX ? antiX : 4), Std.int(Math.abs(antiY - 4)),  7, 1), FlxColor.BLACK);
		selector.pixels.fillRect(new Rectangle((flipX ? antiX : 5), Std.int(Math.abs(antiY - 3)),  6, 1), FlxColor.BLACK);
		selector.pixels.fillRect(new Rectangle((flipX ? antiX : 6), Std.int(Math.abs(antiY - 2)),  5, 1), FlxColor.BLACK);
		selector.pixels.fillRect(new Rectangle((flipX ? antiX : 8), Std.int(Math.abs(antiY - 1)),  3, 1), FlxColor.BLACK);
	}

	/*var _file:FileReference = null;
	function installMod() {
		var zipFilter:FileFilter = new FileFilter('ZIP', 'zip');
		_file = new FileReference();
		_file.addEventListener(Event.SELECT, onLoadComplete);
		_file.addEventListener(Event.CANCEL, onLoadCancel);
		_file.addEventListener(IOErrorEvent.IO_ERROR, onLoadError);
		_file.browse([zipFilter]);
		canExit = false;
	}

	function onLoadComplete(_):Void
	{
		_file.removeEventListener(Event.SELECT, onLoadComplete);
		_file.removeEventListener(Event.CANCEL, onLoadCancel);
		_file.removeEventListener(IOErrorEvent.IO_ERROR, onLoadError);

		var fullPath:String = null;
		@:privateAccess
		if(_file.__path != null) fullPath = _file.__path;

		if(fullPath != null)
		{
			var rawZip:String = File.getContent(fullPath);
			if(rawZip != null)
			{
				MusicBeatState.resetState();
				var uncompressingFile:Bytes = new Uncompress().run(File.getBytes(rawZip));
				if (uncompressingFile.done)
				{
					trace('test');
					_file = null;
					return;
				}
			}
		}
		_file = null;
		canExit = true;
		trace("File couldn't be loaded! Wtf?");
	}

	function onLoadCancel(_):Void
	{
		_file.removeEventListener(Event.SELECT, onLoadComplete);
		_file.removeEventListener(Event.CANCEL, onLoadCancel);
		_file.removeEventListener(IOErrorEvent.IO_ERROR, onLoadError);
		_file = null;
		canExit = true;
		trace("Cancelled file loading.");
	}

	function onLoadError(_):Void
	{
		_file.removeEventListener(Event.SELECT, onLoadComplete);
		_file.removeEventListener(Event.CANCEL, onLoadCancel);
		_file.removeEventListener(IOErrorEvent.IO_ERROR, onLoadError);
		_file = null;
		canExit = true;
		trace("Problem loading file");
	}*/
	override function destroy() {
		instance = null;
		super.destroy();
	}
}

class ModMetadata
{
	public var folder:String;
	public var name:String;
	public var description:String;
	public var color:FlxColor;
	public var restart:Bool;//trust me. this is very important
	public var zhdescription:String;
	public var alphabet:Alphabet;
	public var icon:AttachedSprite;

	public function new(folder:String)
	{
		this.folder = folder;
		this.name = folder;
		this.description = "No description provided.";
		this.color = ModsMenuStateOld.defaultColor;
		this.restart = false;
		this.zhdescription = "No description provided.";

		//Try loading json
		var path = Paths.mods(folder + '/pack.json');
		if(FileSystem.exists(path)) {
			var rawJson:String = File.getContent(path);
			if(rawJson != null && rawJson.length > 0) {
				var stuff:Dynamic = null;
				try {
					stuff = backend.JsonUtil.parseTolerant(rawJson);
				} catch(e) {
					TraceManager.error('trace.modsMenuOld.invalidPackJson', 'Invalid pack.json in mod "{}" ({}): {}', [folder, path, e]);
				}
				if(stuff != null) {
					//using reflects cuz for some odd reason my haxe hates the stuff.var shit
					var colors:Array<Int> = Reflect.getProperty(stuff, "color");
					var description:String = Reflect.getProperty(stuff, "description");
					var name:String = Reflect.getProperty(stuff, "name");
					var restart:Dynamic = Reflect.getProperty(stuff, "restart");
					var zhdescription:String = Reflect.getProperty(stuff, "zhdescription");

				if(name != null && name.length > 0)
				{
					this.name = name;
				}
				if(description != null && description.length > 0)
				{
					this.description = description;
				}
				if(name == 'Name')
				{
					this.name = folder;
				}
				if(description != null && description.length > 0) {
						this.description = description;
					}
				if(zhdescription != null && zhdescription.length > 0) {
						this.zhdescription = zhdescription;
					}

				if(description == 'Description')
				{
					this.description = Language.get("Mod.noDescription", "No description provided.");
				}
				if(colors != null && colors.length > 2)
				{
					this.color = FlxColor.fromRGB(colors[0], colors[1], colors[2]);
				}

				// pack.json may omit "restart"; guard against null before casting to Bool.
				this.restart = (restart == true);
				/*
				if(stuff.name != null && stuff.name.length > 0)
				{
					this.name = stuff.name;
				}
				if(stuff.description != null && stuff.description.length > 0)
				{
					this.description = stuff.description;
				}
				if(stuff.color != null && stuff.color.length > 2)
				{
					this.color = FlxColor.fromRGB(stuff.color[0], stuff.color[1], stuff.color[2]);
				}*/
				}
			}
		}
	}
}
