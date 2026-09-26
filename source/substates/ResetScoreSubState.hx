package substates;

import flixel.FlxSubState;
using StringTools;

class ResetScoreSubState extends MusicBeatSubstate
{
	var bg:FlxSprite;
	var alphabetArray:Array<FlxTextMenuItem> = [];
	var icon:HealthIcon;
	var onYes:Bool = false;
	var yesText:FlxTextMenuItem;
	var noText:FlxTextMenuItem;

	var song:String;
	var difficulty:Int;
	var week:Int;

	// Week -1 = Freeplay
	public function new(song:String, difficulty:Int, character:String, week:Int = -1)
	{
		this.song = song;
		this.difficulty = difficulty;
		this.week = week;

		super();

		var name:String = song;
		if(week > -1) {
			name = WeekData.weeksLoaded.get(WeekData.weeksList[week]).weekName;
		}
		name += ' (' + CoolUtil.difficulties[difficulty] + ')?';

		bg = new FlxSprite().makeGraphic(FlxG.width, FlxG.height, FlxColor.BLACK);
		bg.alpha = 0;
		bg.scrollFactor.set();
		add(bg);

		var tooLong:Float = (name.length > 18) ? 0.8 : 1; //Fucking Winter Horrorland
		var text:FlxTextMenuItem = new FlxTextMenuItem(0, 180, Language.get('ResetScore.prompt', 'Reset the score of'), 48); text.isMenuItem = false;
		text.screenCenter(X);
		alphabetArray.push(text);
		text.alpha = 0;
		add(text);
		var text:FlxTextMenuItem = new FlxTextMenuItem(0, text.y + 90, name, 48); text.isMenuItem = false;
		text.scale.x = tooLong;
		text.screenCenter(X);
		if(week == -1) text.x += 60 * tooLong;
		alphabetArray.push(text);
		text.alpha = 0;
		add(text);
		if(week == -1) {
			icon = new HealthIcon(character);
			icon.setGraphicSize(Std.int(icon.width * tooLong));
			icon.updateHitbox();
			icon.setPosition(text.x - icon.width + (10 * tooLong), text.y - 30);
			icon.alpha = 0;
			add(icon);
		}

		yesText = new FlxTextMenuItem(0, text.y + 150, Language.get('Dialog.yes', 'Yes'), 48); yesText.isMenuItem = false;
		yesText.screenCenter(X);
		yesText.x -= 200;
		add(yesText);
		noText = new FlxTextMenuItem(0, text.y + 150, Language.get('Dialog.no', 'No'), 48); noText.isMenuItem = false;
		noText.screenCenter(X);
		noText.x += 200;
		add(noText);
		updateOptions();
		#if android
		addVirtualPad(LEFT_RIGHT, A_B);
		addPadCamera();
		#end
	}

	override function update(elapsed:Float)
	{
		bg.alpha += elapsed * 1.5;
		if(bg.alpha > 0.6) bg.alpha = 0.6;

		for (i in 0...alphabetArray.length) {
			var spr = alphabetArray[i];
			spr.alpha += elapsed * 2.5;
		}
		if(week == -1) icon.alpha += elapsed * 2.5;

		if(controls.UI_LEFT_P || controls.UI_RIGHT_P) {
			FlxG.sound.play(Paths.sound('scrollMenu'), 1);
			onYes = !onYes;
			updateOptions();
		}

		if(controls.BACK) {
			FlxG.sound.play(Paths.sound('cancelMenu'), 1);
			close();
		} else if(controls.ACCEPT) {
			if(onYes) {
				if(week == -1) {
					Highscore.resetSong(song, difficulty);
				} else {
					Highscore.resetWeek(WeekData.weeksList[week], difficulty);
				}
			}
			FlxG.sound.play(Paths.sound('cancelMenu'), 1);
			close();
		}
		super.update(elapsed);
	}

	function updateOptions() {
		var scales:Array<Float> = [0.75, 1];
		var alphas:Array<Float> = [0.6, 1.25];
		var confirmInt:Int = onYes ? 1 : 0;

		yesText.alpha = alphas[confirmInt];
		yesText.scale.set(scales[confirmInt], scales[confirmInt]);
		noText.alpha = alphas[1 - confirmInt];
		noText.scale.set(scales[1 - confirmInt], scales[1 - confirmInt]);
		if(week == -1) icon.animation.curAnim.curFrame = confirmInt;
	}
}