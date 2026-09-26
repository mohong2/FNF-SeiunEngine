package;

import flixel.FlxG;
import flixel.FlxSprite;
import flixel.graphics.frames.FlxAtlasFrames;
import openfl.utils.AssetType;
import shaders.RGBPalette;
import shaders.RGBPalette.RGBShaderReference;

using StringTools;

class StrumNote extends FlxSprite
{
	private var colorSwap:ColorSwap;
	/** 0.7.3/1.0.4 compatibility: RGB reference (lazy; falls back to colorSwap until a script changes it). */
	public var rgbShader:RGBShaderReference = null;
	/** 0.7.3 compatibility: useRGBShader toggle (static animations stay unshaded). */
	public var useRGBShader:Bool = true;
	/** True when the texture is a 0.7.3 white note atlas (noteSkins/*) and should be tinted by the RGB shader. */
	public var useRgbColor:Bool = false;
	public var resetAnim:Float = 0;
	private var noteData:Int = 0;
	public var direction:Float = 90;//plan on doing scroll directions soon -bb
	public var downScroll:Bool = false;//plan on doing scroll directions soon -bb
	public var sustainReduce:Bool = true;

	/** Multi-key: lane of this strum (0 ~ ammo-1). */
	public var lane(default, null):Int = 0;

	public var animationArray:Array<String> = ['static', 'pressed', 'confirm'];
	public var static_anim(default, set):String = "static";
	public var pressed_anim(default, set):String = "pressed";
	public var confirm_anim(default, set):String = "confirm";

	private function set_static_anim(value:String):String {
		if (!PlayState.isPixelStage) {
			animation.addByPrefix('static', value);
			animationArray[0] = value;
			if (animation.curAnim != null && animation.curAnim.name == 'static') playAnim('static');
		}
		return value;
	}

	private function set_pressed_anim(value:String):String {
		if (!PlayState.isPixelStage) {
			animation.addByPrefix('pressed', value);
			animationArray[1] = value;
			if (animation.curAnim != null && animation.curAnim.name == 'pressed') playAnim('pressed');
		}
		return value;
	}

	private function set_confirm_anim(value:String):String {
		if (!PlayState.isPixelStage) {
			animation.addByPrefix('confirm', value);
			animationArray[2] = value;
			if (animation.curAnim != null && animation.curAnim.name == 'confirm') playAnim('confirm');
		}
		return value;
	}

	private var player:Int;

	public var texture(default, set):String = null;
	private function set_texture(value:String):String {
		if(texture != value) {
			texture = value;
			reloadNote();
		}
		return value;
	}

	/** SPACE strums reuse the UP animation. */
	inline static function strumToBase(strumAnim:String):String
	{
		return (strumAnim == 'SPACE') ? 'UP' : strumAnim;
	}

	public function new(x:Float, y:Float, leData:Int, player:Int) {
		noteData = leData;
		this.player = player;
		lane = leData;
		super(x, y);

		// The 0.6.3 atlas names strum animations by direction (arrowLEFT / left press / left confirm);
		// the SPACE lane reuses the up direction.
		animationArray[0] = strumToBase(EKData.getStrumAnim(PlayState.mania, leData));
		animationArray[1] = animationArray[0].toLowerCase();
		animationArray[2] = animationArray[1];

		// Follows the Old/New note style setting (Old = flat NOTE_assets, New = noteSkins/NOTE_assets).
		var skin:String = Note.defaultNoteSkin;
		if(PlayState.SONG != null && PlayState.SONG.arrowSkin != null && PlayState.SONG.arrowSkin.length > 1)
			skin = PlayState.SONG.arrowSkin;
		// Multi-key: always use the stock ColorSwap so the shader stays active; custom skins are not tinted automatically.
		colorSwap = new ColorSwap();
		shader = colorSwap.shader;
		// 0.7.3/1.0.4 compatibility: the RGB reference is lazy. Static animations keep the original
		// texture; it takes over only once a script changes rgbShader (falling back to colorSwap).
		rgbShader = new RGBShaderReference(this, Note.initializeGlobalRGBShader(leData));
		rgbShader.fallbackShader = colorSwap.shader;
		rgbShader.enabled = false;
		// In the editor / test environment (PlayState.instance == null) the chart's disableNoteRGB
		// always applies; the player's noteRGBMode only matters during real gameplay.
		var chartDisabled:Bool = (PlayState.SONG != null && PlayState.SONG.disableNoteRGB);
		if (PlayState.instance == null ? chartDisabled : ClientPrefs.noteRGBDisabled(chartDisabled))
		{
			rgbShader.forceDisabled = true;
			useRGBShader = false;
		}
		texture = skin;
		scrollFactor.set();
	}

	public function reloadNote()
	{
		var lastAnim:String = null;
		if(animation.curAnim != null) lastAnim = animation.curAnim.name;

		// Note skin selection: append the chosen noteSkin to the texture name when the file exists.
		// Same order as Note.reloadNote: try the direct suffix first (legacy NOTE_assets-<skin> /
		// new noteSkins/NOTE_assets-<skin>). A legacy texture never falls back to noteSkins/*,
		// which would force the legacy style onto the new atlas.
		var loadSkin:String = (texture != null) ? texture : Note.defaultNoteSkin;
		var skinPostfix:String = Note.getNoteSkinPostfix();
		if (skinPostfix.length > 0)
		{
			var direct:String = loadSkin + skinPostfix;
			if (Paths.fileExists('images/' + direct + '.png', IMAGE))
				loadSkin = direct;
			else if (ClientPrefs.data.noteStyle == 'New' && !loadSkin.startsWith('noteSkins/'))
			{
				var prefixed:String = 'noteSkins/' + loadSkin + skinPostfix;
				if (Paths.fileExists('images/' + prefixed + '.png', IMAGE))
					loadSkin = prefixed;
			}
		}

		if(PlayState.isPixelStage)
		{
			loadGraphic(Paths.image('pixelUI/' + loadSkin));
			width = width / 4;
			height = height / 5;
			loadGraphic(Paths.image('pixelUI/' + loadSkin), true, Math.floor(width), Math.floor(height));
			antialiasing = false;
			var b:Int = EKData.getBaseTexture(PlayState.mania, lane);
			setGraphicSize(Std.int(width * PlayState.daPixelZoom * (EKData.pixelScales[PlayState.mania] / EKData.pixelScales[3])));
			updateHitbox();
			animation.add('static', [b]);
			animation.add('pressed', [b + 4, b + 8], 12, false);
			animation.add('confirm', [b + 12, b + 16], 24, false);
		}
		else
		{
			frames = Paths.getSparrowAtlas(loadSkin);
			if (frames != null)
			{
				animation.addByPrefix('static', 'arrow' + animationArray[0]);
				animation.addByPrefix('pressed', animationArray[1] + ' press', 24, false);
				animation.addByPrefix('confirm', animationArray[1] + ' confirm', 24, false);

				antialiasing = ClientPrefs.data.globalAntialiasing;
				setGraphicSize(Std.int(width * 0.7 * Note.noteScale(PlayState.mania)));
			}
		}
		updateHitbox();

		// 0.7.3 atlases: noteSkins/* white textures are tinted by the RGB shader, otherwise ColorSwap.
		useRgbColor = (loadSkin != null && loadSkin.startsWith('noteSkins/'));
		if (rgbShader != null)
		{
			rgbShader.fallbackShader = colorSwap != null ? colorSwap.shader : null;
			rgbShader.enabled = useRgbColor;
		}

		if(lastAnim != null) playAnim(lastAnim, true);
	}

	public function postAddedToGroup() {
		playAnim('static');
		/**
		 * Multi-key positioning:
		 * 1K-3K are laid out by width, 4K by swagWidth, 5K+ by (width - lessX), plus xtra/50/screen half minus restPosition.
		 **/
		switch (PlayState.mania)
		{
			case 0 | 1 | 2: x += width * noteData;
			case 3: x += (Note.swagWidth * noteData);
			default: x += ((width - EKData.lessX[PlayState.mania]) * noteData);
		}
		x += EKData.offsetX[PlayState.mania];
		x += 50;
		x += ((FlxG.width / 2) * player);
		ID = noteData;
		x -= EKData.restPosition[PlayState.mania];
	}

	override function update(elapsed:Float) {
		if(resetAnim > 0) {
			resetAnim -= elapsed;
			if(resetAnim <= 0) {
				playAnim('static');
				resetAnim = 0;
			}
		}
		if(animation.curAnim != null && animation.curAnim.name == 'confirm' && !PlayState.isPixelStage) {
			centerOrigin();
		}
		super.update(elapsed);
	}

	public function playAnim(anim:String, ?force:Bool = false) {
		animation.play(anim, force);
		centerOffsets();
		centerOrigin();
		if (useRgbColor) {
			// 0.7.3 atlas: 'static' shows the raw white texture, press/confirm are tinted by the RGB palette.
			rgbShader.enabled = (animation.curAnim != null && animation.curAnim.name != 'static');
		} else if(animation.curAnim == null || animation.curAnim.name == 'static') {
			colorSwap.hue = 0;
			colorSwap.saturation = 0;
			colorSwap.brightness = 0;
		} else {
			// Lane colour (base texture colour + target delta + the user's arrowHSV offset).
			applyLaneColor();

			if(animation.curAnim.name == 'confirm' && !PlayState.isPixelStage) {
				centerOrigin();
			}
		}
	}

	/** Applies the lane colour to ColorSwap (same as Note). */
	public function applyLaneColor():Void
	{
		if (colorSwap == null) return;
		var delta:Array<Float> = EKData.getLaneColorSwap(PlayState.mania, lane);
		var colorIdx:Int = EKData.letterColorIndex.get(EKData.getLetter(PlayState.mania, lane));
		if (colorIdx < 0) colorIdx = lane;
		var hsv:Array<Int> = (colorIdx < ClientPrefs.data.arrowHSV.length) ? ClientPrefs.data.arrowHSV[colorIdx] : [0, 0, 0];
		var hue:Float = delta[0] + hsv[0] / 360;
		while (hue < 0) hue += 1;
		while (hue >= 1) hue -= 1;
		colorSwap.hue = hue;
		colorSwap.saturation = delta[1] + hsv[1] / 100;
		colorSwap.brightness = delta[2] + hsv[2] / 100;
	}
}
