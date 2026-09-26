#if ONLINE_ALLOWED
package;

import flixel.FlxSprite;
import flixel.FlxCamera;
import flixel.math.FlxPoint;

/**
 * Interface for a vertically scrollable menu list (`targetY`, `distancePerItem`,
 * `snapToPosition`).
 *
 * Why it is a standalone root-package module here instead of living next to `Alphabet`:
 * this engine's `source/Alphabet.hx` does not declare the interface, and the online slice refers
 * to `Scrollable` by its bare name
 * (`online/objects/AlphaLikeText.hx` does `implements Scrollable`, `online/substates/
 * SoFunkinSubstate.hx` uses it as a variable type). A root-level module lets
 * `source/online/import.hx` inject it with a single unambiguous `import Scrollable;`.
 * Guarded by ONLINE_ALLOWED so the macro-off build is untouched.
 */
interface Scrollable extends IFlxSprite {
	public var targetY:Int;
	public var distancePerItem:FlxPoint;
	public var startPosition:FlxPoint;
	function snapToPosition():Void;
	public var changeX:Bool;
	public var changeY:Bool;

	var isMenuItem:Bool;
	var scaleX(default, set):Float;
	var scaleY(default, set):Float;

	// IFlxSprite doesn't have?
	public var width(get, set):Float;
	public var height(get, set):Float;
	public var cameras(get, set):Array<FlxCamera>;

	public var text(default, set):String;
}
#end
