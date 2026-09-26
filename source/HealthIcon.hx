package;

import openfl.utils.Assets as OpenFlAssets;
import flixel.graphics.frames.FlxTileFrames; // needed by the ONLINE_ALLOWED `loadIcon` below

using StringTools;

class HealthIcon extends FlxSprite
{
	public var sprTracker:FlxSprite;
	private var isOldIcon:Bool = false;
	private var isPlayer:Bool = false;
	private var char:String = '';
	public var frameCount:Int = 2;

	public function new(char:String = 'bf', isPlayer:Bool = false)
	{ 
		super();
		isOldIcon = (char == 'bf-old');
		this.isPlayer = isPlayer;
		pixelPerfectPosition = isPlayer;
		changeIcon(char);
		scrollFactor.set();
	}

	override function update(elapsed:Float)
	{
		super.update(elapsed);

		if (sprTracker != null)
			setPosition(sprTracker.x + sprTracker.width + 12, sprTracker.y - 30);
	}

	public function swapOldIcon() {
		if(isOldIcon = !isOldIcon) changeIcon('bf-old');
		else changeIcon('bf');
	}

	private var iconOffsets:Array<Float> = [0, 0, 0];
	public function changeIcon(char:String) {
		if(this.char != char) {
			var name:String = 'icons/' + char;
			if(!Paths.fileExists('images/' + name + '.png', IMAGE)) name = 'icons/icon-' + char; //Older versions of psych engine's support
			if(!Paths.fileExists('images/' + name + '.png', IMAGE)) name = 'icons/icon-face'; //Prevents crash from missing icon
			var file:Dynamic = Paths.image(name);

			loadGraphic(file);
			var imgWidth:Int = Math.floor(width);
			var imgHeight:Int = Math.floor(height);
			
			frameCount = Math.round(imgWidth / imgHeight);
			
			if (frameCount < 2) frameCount = 2;
			if (frameCount > 3) frameCount = 3;
			
			var frameWidth:Int = Math.round(imgWidth / frameCount);
			
			loadGraphic(file, true, frameWidth, imgHeight);
			
			var offsetX:Float = (frameWidth - 150) / 2;
			var offsetY:Float = (imgHeight - 150) / 2;
			
			for (i in 0...iconOffsets.length) {
				iconOffsets[i] = 0;
			}
			iconOffsets[0] = offsetX;
			iconOffsets[1] = offsetY;
			if (frameCount == 3) {
				iconOffsets[2] = 0; 
			}
			
			updateHitbox();


			if (frameCount == 3) {
				animation.add(char, [0, 1, 2], 0, false, isPlayer);
			} else {
				animation.add(char, [0, 1, 0], 0, false, isPlayer);
			}
			animation.play(char);
			pixelPerfectPosition = isPlayer;
			drawFrame(true);
			this.char = char;

			antialiasing = ClientPrefs.data.globalAntialiasing;
			if(char.endsWith('-pixel')) {
				antialiasing = false;
			}
		}
	}
	public var autoAdjustOffset:Bool = true;
	override function updateHitbox()
	{
		super.updateHitbox();
		if(autoAdjustOffset)
		{
			offset.x = iconOffsets[0];
			offset.y = iconOffsets[1];
		}
	}

	public function getCharacter():String {
		return char;
	}

	#if ONLINE_ALLOWED
	// ─── Online support: members the online code needs ──────────────────────────
	// These members are declared only for the online code (lobby sort/offset, remote
	// player icons). Everything here is guarded by ONLINE_ALLOWED so the macro-off build is
	// untouched.
	//
	// Implementation notes:
	//   * `loadIcon` uses `final tileFrames:FlxTileFrames = cast frames;` + `tileFrames.tileSize`,
	//     both present in the pinned flixel 4.11.0
	//     (.haxelib/flixel/git/flixel/graphics/frames/FlxTileFrames.hx:33).
	//   * `findIconPath` returns the bare icon key and uses the engine's existing `Paths.fileExists`
	//     call (identical to what `changeIcon` above already does).
	// -------------------------------------------------------------------------

	/**
	 * NOTE: this engine's `isPlayer` field is private, so external code cannot promote it.
	 * Left as-is on purpose — promoting the field would be an unguarded change to the
	 * macro-off build. If a later layer turns out to read `icon.isPlayer` from outside, split
	 * the existing declaration inside an `#if ONLINE_ALLOWED` instead of adding a field.
	 */

	/** Online lobby sort/offset slot. */
	public var ox:Int;

	/** Snaps the icon to its tracker; the engine's `update()` inlines the same math. */
	public function snapToTracker() {
		if (sprTracker != null)
			setPosition(sprTracker.x + sprTracker.width + 12, sprTracker.y - 30);
	}

	/** Resolves an icon key, trying the two legacy fallbacks before the default face icon. */
	public static function findIconPath(char:String) {
		var name:String = 'icons/' + char;
		if (!Paths.fileExists('images/' + name + '.png', IMAGE))
			name = 'icons/icon-' + char; // Older versions of psych engine's support
		if (!Paths.fileExists('images/' + name + '.png', IMAGE))
			name = 'icons/icon-face'; // Prevents crash from missing icon
		return name;
	}

	/** Loads a graphic and re-derives the per-icon offsets. */
	public function loadIcon(asset:flixel.system.FlxAssets.FlxGraphicAsset) {
		loadGraphic(asset, true);

		final tileFrames:FlxTileFrames = cast frames;
		if (tileFrames == null || tileFrames.tileSize == null)
			return;

		var iSize:Float = Math.round(tileFrames.parent.width / tileFrames.parent.height);
		tileFrames.tileSize.set(Math.floor(tileFrames.parent.width / iSize), Math.floor(tileFrames.parent.height));
		iconOffsets[0] = (width - 150) / iSize;
		iconOffsets[1] = (height - 150) / iSize;
		updateHitbox();

		animation.add(char, [for (i in 0...frames.frames.length) i], 0, false, isPlayer);
	}
	#end
}
