package options;

import backend.MusicBeatSubstate;
import FlxTextMenuItem;
import FlxTextMenuItem.FlxTextAttached;
import flixel.addons.display.FlxBackdrop;
import flixel.addons.display.FlxGridOverlay;
import flixel.tweens.FlxEase;
import flixel.tweens.FlxTween;
import flixel.util.FlxColor;
import flixel.math.FlxMath;
import haxe.Json;
import sys.FileSystem;
import sys.io.File;
import mohong.TraceManager;
import Paths;
import ClientPrefs;
import CheckboxThingie;
import Language;
import Controls;
#if cpp
import Discord.DiscordClient;
#end

class ModSettingsSubState extends MusicBeatSubstate
{
	var folder:String;
	var modName:String;
	var modSettings:Map<String, Dynamic> = new Map();

	var optionsArray:Array<Option>;
	var curSelected:Int = 0;
	var curOption:Option = null;

	var grpOptions:FlxTypedGroup<FlxTextMenuItem>;
	var checkboxGroup:FlxTypedGroup<CheckboxThingie>;
	var grpTexts:FlxTypedGroup<FlxTextAttached>;
	var descBox:FlxSprite;
	var descText:FlxText;
	/** Description currently rendered into descText; identical ones are not re-rasterized. */
	var descShown:String = null;
	var titleText:FlxTextMenuItem;

	var nextAccept:Int = 5;
	var holdTime:Float = 0;
	var holdValue:Float = 0;

	public function new(settings:Array<Dynamic>, folder:String, name:String)
	{
		super();
		this.folder = folder;
		this.modName = name;

		var title = '$name Settings';
		var rpcTitle = 'Mod Settings ($name)';

		#if desktop
		DiscordClient.changePresence(rpcTitle, null);
		#end

		// 背景
		var bg:FlxSprite = new FlxSprite().loadGraphic(Paths.image('menuDesat'));
		bg.color = 0xff17719b;
		bg.screenCenter();
		bg.antialiasing = ClientPrefs.data.globalAntialiasing;
		add(bg);

		// 网格
		var grid:FlxBackdrop = new FlxBackdrop(FlxGridOverlay.createGrid(80, 80, 160, 160, true, 0x33FFFFFF, 0x0));
		grid.velocity.set(40, 40);
		grid.alpha = 0;
		FlxTween.tween(grid, {alpha: 1}, 0.5, {ease: FlxEase.quadOut});
		add(grid);

		// 选项组
		grpOptions = new FlxTypedGroup<FlxTextMenuItem>();
		add(grpOptions);

		grpTexts = new FlxTypedGroup<FlxTextAttached>();
		add(grpTexts);

		checkboxGroup = new FlxTypedGroup<CheckboxThingie>();
		add(checkboxGroup);

		descBox = new FlxSprite().makeGraphic(1, 1, FlxColor.BLACK);
		descBox.alpha = 0.6;
		add(descBox);

		titleText = new FlxTextMenuItem(75, 40, title, 32);
		titleText.alpha = 0.4;
		add(titleText);

		descText = new FlxText(50, 600, 1180, "", 32);
		descText.setFormat(Paths.optionsfont(), 32, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		descText.scrollFactor.set();
		descText.borderSize = 2.4;
		add(descText);

		// 初始化 mod 设置存储
		if (FlxG.save.data.modSettings == null)
			FlxG.save.data.modSettings = new Map<String, Map<String, Dynamic>>();

		var allModSettings:Map<String, Map<String, Dynamic>> = FlxG.save.data.modSettings;
		if (allModSettings.exists(folder))
			modSettings = allModSettings.get(folder);
		else
		{
			modSettings = new Map();
			allModSettings.set(folder, modSettings);
		}

		optionsArray = [];

		for (setting in settings)
		{
			if (setting == null || setting.save == null) continue;

			var option:Option = null;
			var saveVar:String = setting.save;
			var defaultValue:Dynamic = setting.value != null ? setting.value : getDefaultValue(setting.type);

			var descriptionText:String = setting.description;
			if (setting.zhdescription != null && ClientPrefs.data.language == 'Chinese')
				descriptionText = setting.zhdescription;

			if (!modSettings.exists(saveVar))
				modSettings.set(saveVar, defaultValue);

			switch (setting.type.toLowerCase())
			{
				case "bool":
					option = new Option(
						setting.name != null ? setting.name : "Unnamed Setting",
						descriptionText, saveVar, "bool", defaultValue);
					option.setValue(modSettings.get(saveVar));

				case "int" | "integer":
					option = new Option(
						setting.name != null ? setting.name : "Unnamed Setting",
						descriptionText, saveVar, "int", defaultValue);
					if (setting.min != null) option.minValue = setting.min;
					if (setting.max != null) option.maxValue = setting.max;
					if (setting.step != null) option.changeValue = setting.step;
					if (setting.scroll != null) option.scrollSpeed = setting.scroll;
					option.setValue(modSettings.get(saveVar));

				case "float" | "number":
					option = new Option(
						setting.name != null ? setting.name : "Unnamed Setting",
						descriptionText, saveVar, "float", defaultValue);
					if (setting.min != null) option.minValue = setting.min;
					if (setting.max != null) option.maxValue = setting.max;
					if (setting.step != null) option.changeValue = setting.step;
					if (setting.scroll != null) option.scrollSpeed = setting.scroll;
					if (setting.decimals != null) option.decimals = setting.decimals;
					option.setValue(modSettings.get(saveVar));

				case "percent":
					option = new Option(
						setting.name != null ? setting.name : "Unnamed Setting",
						descriptionText, saveVar, "percent", defaultValue);
					if (setting.min != null) option.minValue = setting.min;
					if (setting.max != null) option.maxValue = setting.max;
					if (setting.step != null) option.changeValue = setting.step;
					if (setting.scroll != null) option.scrollSpeed = setting.scroll;
					option.setValue(modSettings.get(saveVar));

				case "string":
					option = new Option(
						setting.name != null ? setting.name : "Unnamed Setting",
						descriptionText, saveVar, "string", defaultValue);
					if (setting.options != null) option.options = setting.options;
					option.setValue(modSettings.get(saveVar));

				default:
					TraceManager.warn('trace.modSettings.unsupportedType', 'Unsupported setting type: {}', [setting.type]);
			}

			if (option != null)
			{
				var originalSetValue = option.setValue;
				var mySaveVar = saveVar;

				option.setValue = function(value:Dynamic) {
					originalSetValue(value);
					modSettings.set(mySaveVar, value);
				};

				option.getValue = function() {
					return modSettings.get(mySaveVar);
				};

				optionsArray.push(option);
			}
		}

		// 构建 UI
		for (i in 0...optionsArray.length)
		{
			var optionText = new FlxTextMenuItem(290, 260, optionsArray[i].name, 48);
			optionText.isMenuItem = true;
			optionText.targetY = i;
			grpOptions.add(optionText);

			if (optionsArray[i].type == 'button')
			{
				optionText.x -= 10;
				optionText.startPosition.x -= 10;
				var valueText = new FlxTextAttached(
					Language.get("option.traceConsole.pressEnter", "[Press ENTER]"),
					36, optionText.width + 80);
				valueText.sprTracker = optionText;
				valueText.copyAlpha = true;
				valueText.ID = i;
				grpTexts.add(valueText);
				optionsArray[i].setChild(valueText);
			}
			else if (optionsArray[i].type == 'bool')
			{
				var checkbox = new CheckboxThingie(optionText.x - 10, optionText.y, optionsArray[i].getValue() == true);
				checkbox.sprTracker = optionText;
				checkbox.ID = i;
				checkboxGroup.add(checkbox);
			}
			else
			{
				optionText.x -= 10;
				optionText.startPosition.x -= 10;
				var valueText = new FlxTextAttached('' + optionsArray[i].getValue(), 48, optionText.width + 80);
				valueText.sprTracker = optionText;
				valueText.copyAlpha = true;
				valueText.ID = i;
				grpTexts.add(valueText);
				optionsArray[i].setChild(valueText);
			}

			updateTextFrom(optionsArray[i]);
		}

		changeSelection();
		reloadCheckboxes();

		#if (TOUCH_CONTROLS || desktop)
		addVirtualPad(LEFT_FULL, A_B_C);
		addPadCamera();
		#end
	}

	override function update(elapsed:Float)
	{
		if (FlxG.mouse.wheel != 0)
		{
			changeSelection(-FlxG.mouse.wheel);
			FlxG.sound.play(Paths.sound('scrollMenu'));
		}

		// 鼠标点击 (虚拟按键上点击不穿透)
		if (FlxG.mouse.justPressed && !(virtualPad != null && virtualPad.isMouseOverAnyButton()))
		{
			for (checkbox in checkboxGroup)
			{
				if (FlxG.mouse.overlaps(checkbox))
				{
					curSelected = checkbox.ID;
					changeSelection(0);
					FlxG.sound.play(Paths.sound('scrollMenu'));
					optionsArray[checkbox.ID].setValue(!optionsArray[checkbox.ID].getValue());
					optionsArray[checkbox.ID].change();
					reloadCheckboxes();
					break;
				}
			}
			for (text in grpTexts)
			{
				if (FlxG.mouse.overlaps(text))
				{
					curSelected = text.ID;
					changeSelection(0);

					var option = optionsArray[text.ID];
					if (option.type != 'bool')
					{
						var add:Dynamic = (option.type == 'string') ? 0 : option.changeValue;

						switch (option.type)
						{
							case 'int' | 'float' | 'percent':
								holdValue = option.getValue() + add;
								if (holdValue < option.minValue) holdValue = option.minValue;
								else if (holdValue > option.maxValue) holdValue = option.maxValue;

								switch (option.type)
								{
									case 'int':
										holdValue = Math.round(holdValue);
										option.setValue(holdValue);
									case 'float' | 'percent':
										holdValue = FlxMath.roundDecimal(holdValue, option.decimals);
										option.setValue(holdValue);
								}

							case 'string':
								var num:Int = option.curOption + 1;
								if (num >= option.options.length) num = 0;
								option.curOption = num;
								option.setValue(option.options[num]);
						}
						updateTextFrom(option);
						option.change();
						FlxG.sound.play(Paths.sound('scrollMenu'));
					}
					break;
				}
			}
		}

		if (controls.UI_UP_P)   changeSelection(-1);
		if (controls.UI_DOWN_P) changeSelection(1);

		if (controls.BACK)
		{
			FlxG.sound.play(Paths.sound('cancelMenu'));
			close();
			return;
		}

		if (nextAccept <= 0)
		{
			var usesCheckbox = (curOption != null && (curOption.type == 'bool' || curOption.type == 'button'));

			if (usesCheckbox)
			{
				if (controls.ACCEPT)
				{
					FlxG.sound.play(Paths.sound('scrollMenu'));
					curOption.setValue((curOption.getValue() == true) ? false : true);
					curOption.change();
					reloadCheckboxes();
				}
			}
			else if (curOption != null)
			{
				if (controls.UI_LEFT || controls.UI_RIGHT)
				{
					var pressed = (controls.UI_LEFT_P || controls.UI_RIGHT_P);
					if (holdTime > 0.5 || pressed)
					{
						if (pressed)
						{
							var add:Dynamic = null;
							if (curOption.type != 'string')
								add = controls.UI_LEFT ? -curOption.changeValue : curOption.changeValue;

							switch (curOption.type)
							{
								case 'int' | 'float' | 'percent':
									holdValue = curOption.getValue() + add;
									if (holdValue < curOption.minValue) holdValue = curOption.minValue;
									else if (holdValue > curOption.maxValue) holdValue = curOption.maxValue;

									switch (curOption.type)
									{
										case 'int':
											holdValue = Math.round(holdValue);
											curOption.setValue(holdValue);
										case 'float' | 'percent':
											holdValue = FlxMath.roundDecimal(holdValue, curOption.decimals);
											curOption.setValue(holdValue);
									}
									updateTextFrom(curOption);
									curOption.change();
									FlxG.sound.play(Paths.sound('scrollMenu'));

								case 'string':
									var num:Int = curOption.curOption;
									if (controls.UI_LEFT_P) --num;
									else num++;

									if (num < 0) num = curOption.options.length - 1;
									else if (num >= curOption.options.length) num = 0;

									curOption.curOption = num;
									curOption.setValue(curOption.options[num]);
									updateTextFrom(curOption);
									curOption.change();
									FlxG.sound.play(Paths.sound('scrollMenu'));
							}
						}
						else if (curOption.type != 'string')
						{
							holdValue += curOption.scrollSpeed * elapsed * (controls.UI_LEFT ? -1 : 1);
							if (holdValue < curOption.minValue) holdValue = curOption.minValue;
							else if (holdValue > curOption.maxValue) holdValue = curOption.maxValue;

							switch (curOption.type)
							{
								case 'int':
									curOption.setValue(Math.round(holdValue));
								case 'float' | 'percent':
									curOption.setValue(FlxMath.roundDecimal(holdValue, curOption.decimals));
							}
							updateTextFrom(curOption);
							curOption.change();
						}
					}

					if (curOption.type != 'string') holdTime += elapsed;
				}
				else if (controls.UI_LEFT_R || controls.UI_RIGHT_R)
					clearHold();
			}

			if (#if (TOUCH_CONTROLS || desktop) (virtualPad != null && virtualPad.buttonC.justPressed) || #end controls.RESET)
			{
				for (i in 0...optionsArray.length)
				{
					var leOption = optionsArray[i];
					leOption.setValue(leOption.defaultValue);
					if (leOption.type != 'bool')
					{
						if (leOption.type == 'string')
							leOption.curOption = leOption.options.indexOf(leOption.getValue());
						updateTextFrom(leOption);
					}
					leOption.change();
				}
				FlxG.sound.play(Paths.sound('cancelMenu'));
				reloadCheckboxes();
			}
		}

		if (nextAccept > 0) nextAccept -= 1;
		super.update(elapsed);
	}

	override function close()
	{
		FlxG.save.data.modSettings.set(folder, modSettings);
		FlxG.save.flush();
		super.close();
	}

	// ── 辅助方法（原 BaseOptionsMenu） ──

	function updateTextFrom(option:Option)
	{
		var text:String = option.displayFormat;
		var val:Dynamic = option.getValue();
		if (option.type == 'percent') val *= 100;
		var def:Dynamic = option.defaultValue;
		option.text = text.replace('%v', val).replace('%d', def);
		if (option.child != null)
		{
			var parentText = grpOptions.members[optionsArray.indexOf(option)];
			if (parentText != null)
				option.child.offsetX = parentText.width + 80;
		}
	}

	function clearHold()
	{
		if (holdTime > 0.5) FlxG.sound.play(Paths.sound('scrollMenu'));
		holdTime = 0;
	}

	function changeSelection(change:Int = 0)
	{
		curSelected += change;
		if (curSelected < 0) curSelected = optionsArray.length - 1;
		if (curSelected >= optionsArray.length) curSelected = 0;

		// FlxText re-rasterizes (and re-uploads) its bitmap on every text change, so the
		// description is only written when it actually differs - adjacent options often
		// share one, and that is a whole text regeneration saved per cursor move.
		var desc:String = optionsArray[curSelected].description;
		if (desc != descShown)
		{
			descShown = desc;
			descText.text = desc;
			descText.screenCenter(Y);
			descText.y += 270;

			descBox.setPosition(descText.x - 10, descText.y - 10);
			descBox.setGraphicSize(Std.int(descText.width + 20), Std.int(descText.height + 25));
			descBox.updateHitbox();
		}

		var bullShit:Int = 0;
		for (item in grpOptions.members)
		{
			item.targetY = bullShit - curSelected;
			bullShit++;
			item.alpha = 0.6;
			if (item.targetY == 0) item.alpha = 1;
		}
		for (text in grpTexts)
		{
			text.alpha = 0.6;
			if (text.ID == curSelected) text.alpha = 1;
		}

		curOption = optionsArray[curSelected];
		FlxG.sound.play(Paths.sound('scrollMenu'));
	}

	function reloadCheckboxes()
	{
		for (checkbox in checkboxGroup)
			checkbox.daValue = (optionsArray[checkbox.ID].getValue() == true);
	}

	function getDefaultValue(type:String):Dynamic
	{
		return switch (type.toLowerCase())
		{
			case "bool": false;
			case "int" | "integer": 0;
			case "float" | "number": 0.0;
			case "percent": 1.0;
			case "string": "";
			default: null;
		}
	}
}
