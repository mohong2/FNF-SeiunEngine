package online.util;

/**
 * Where the submit button of a server-list field row goes, kept free of flixel on purpose.
 *
 * ServerListState.addFieldRow() reads the input box of an InputOption row and places a
 * ServerButton right of it. That clamp was wrong: FlxSpriteGroup children hold
 * absolute coordinates, so adding row.x on top of bg.x doubled the row offset and put the button
 * at x=1271 on a 1280-wide screen. Keeping the arithmetic here lets
 * tools/online_probe/LayoutProbe.hx run this function instead of restating it.
 */
class RowLayout {
	/** Default size of ServerButton. */
	public static inline var BUTTON_WIDTH:Int = 160;
	public static inline var BUTTON_HEIGHT:Int = 46;

	/** Gap between the input box and the button. */
	static inline var GAP:Float = 16;
	/** Margin kept free on the right when the window is narrower than the row needs. */
	static inline var MARGIN:Float = 10;

	/**
	 * Right of the input box, or as far right as the window allows, whichever is smaller.
	 * Pass the input box' absolute x/width: FlxSpriteGroup children already carry the row offset.
	 */
	public static function buttonX(inputBgX:Float, inputBgWidth:Float, buttonWidth:Float, screenWidth:Float):Float {
		return Math.min(inputBgX + inputBgWidth + GAP, screenWidth - buttonWidth - MARGIN);
	}

	/** Vertically centred on the input box. */
	public static function buttonY(inputBgY:Float, inputBgHeight:Float, buttonHeight:Float):Float {
		return inputBgY + inputBgHeight / 2 - buttonHeight / 2;
	}
}
