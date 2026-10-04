package popup;

import flixel.FlxSprite;
import flixel.FlxG;
import flixel.FlxCamera;
import flixel.graphics.FlxGraphic;
import flixel.group.FlxSpriteGroup;
import flixel.tweens.FlxTween;

/**
 * Object pool for rating popups.
 * Eliminates GC churn from frequent sprite creation in popUpScore().
 *
 * Usage:
 *   var rp = new RatingPopup();
 *   rp.targetCameras = [camHUD];
 *   add(rp.container);
 *   rp.show("sick", 123, playbackRate, ...);
 *
 * Layer contract: FlxTypedGroup.draw() walks `members` from index 0 upwards, so a higher index is
 * drawn later (= on top). Sprites are therefore *appended* by container.add() and *unlisted* with
 * container.remove(spr, true) the instant their fade ends, which keeps `members` in generation
 * order and lets the newest popup draw on top. Keeping a dead sprite in `members` broke both the
 * order and the frame time:
 *   * FlxGroup.add() returns early for an object that is already a member (FlxGroup.hx:225-227), so
 *     a reused icon silently kept its original (lower) slot and drew *under* newer ones;
 *   * clearAll() popped members without decrementing FlxGroup.length, which is the bound of the
 *     per-frame draw()/update() loops, so the cost grew with every hit.
 *
 * Soft-coded: tweak static vars at runtime.
 */
class RatingPopup
{
	// ---- tunable animation params ----
	public static var RATING_SCALE:Float          = 0.7;
	public static var COMBO_SCALE:Float           = 0.7;
	public static var NUM_SCALE:Float             = 0.5;
	public static var PIXEL_RATING_SCALE:Float    = 0.85;
	public static var PIXEL_COMBO_SCALE:Float     = 0.85;
	public static var PIXEL_NUM_SCALE:Float       = 1.0;

	public static var ACCEL_Y_RATING:Float        = 550;
	public static var VEL_Y_RATING_MIN:Float      = 140;
	public static var VEL_Y_RATING_MAX:Float      = 175;
	public static var VEL_X_RATING_MIN:Float      = 0;
	public static var VEL_X_RATING_MAX:Float      = 10;

	public static var ACCEL_Y_COMBO_MIN:Float     = 200;
	public static var ACCEL_Y_COMBO_MAX:Float     = 300;
	public static var VEL_Y_COMBO_MIN:Float       = 140;
	public static var VEL_Y_COMBO_MAX:Float       = 160;
	public static var VEL_X_COMBO_MIN:Float       = 1;
	public static var VEL_X_COMBO_MAX:Float       = 10;

	public static var ACCEL_Y_NUM_MIN:Float       = 200;
	public static var ACCEL_Y_NUM_MAX:Float       = 300;
	public static var VEL_Y_NUM_MIN:Float         = 140;
	public static var VEL_Y_NUM_MAX:Float         = 160;
	public static var VEL_X_NUM_MIN:Float         = -5;
	public static var VEL_X_NUM_MAX:Float         = 5;

	public static var FADE_DURATION:Float         = 0.2;
	public static var FADE_DELAY_RATING:Float     = 0.001;
	public static var FADE_DELAY_COMBO:Float      = 0.002;
	public static var FADE_DELAY_NUM:Float        = 0.002;

	public static var RATING_X_OFFSET:Float       = -40;
	public static var RATING_Y_OFFSET:Float       = -60;
	public static var COMBO_Y_OFFSET:Float        = 60;
	public static var NUM_Y_OFFSET:Float          = 80;
	public static var NUM_SPACING:Float           = 43;
	public static var NUM_X_START:Float           = -90;
	public static var COMBO_X_EXTRA:Float         = 50;

	public static var POOL_SIZE:Int               = 8;
	public static var NUM_POOL_SIZE:Int           = 30;

	// ---- instance state ----
	public var container:FlxSpriteGroup;

	/**
	 * Every sprite this popup owns (only used by destroyAll()).
	 * One homogeneous pool is enough: rating, digit and COMBO sprites are all plain FlxSprites whose
	 * entire state is rewritten by _config() on every acquire, so three separate lists only made the
	 * "which list does this retired sprite belong to" bookkeeping ambiguous.
	 */
	var _pool:Array<FlxSprite> = [];
	/** Retired sprites, reused LIFO => acquire/retire are O(1) (was: linear scan over the pool). */
	var _free:Array<FlxSprite> = [];

	/** Sprite -> its running fade; kept only so clearAll() can stop a fade early. */
	var _tweens:Map<FlxSprite, FlxTween> = new Map();

	/** Resolved popup graphics (rating / digits / COMBO word), reused across hits. */
	var _gfxCache:Map<String, FlxGraphic> = new Map();

	public var targetCameras:Array<FlxCamera> = null;
	public var antialiasing:Bool = true;
	public var isPixel:Bool = false;
	public var daPixelZoom:Float = 6;

	public function new()
	{
		container = new FlxSpriteGroup();
		for (i in 0...(POOL_SIZE + NUM_POOL_SIZE))
		{
			var s:FlxSprite = _deadSprite();
			_pool.push(s);
			_free.push(s);
		}
	}

	static inline function _deadSprite():FlxSprite {
		var s = new FlxSprite();
		s.kill();
		return s;
	}

	/** O(1): take a retired sprite off the free stack (create one only if the stack is empty). */
	function _acquire():FlxSprite
	{
		var s:FlxSprite = (_free.length > 0) ? _free.pop() : null;
		if (s == null)
		{
			s = new FlxSprite();
			_pool.push(s);
		}
		s.revive();
		return s;
	}

	/**
	 * Retire one live popup: drop its tween, unlist it (Splice=true keeps FlxGroup.length in sync,
	 * which is what FlxTypedGroup.draw()/update() iterate) and push it back on the free stack.
	 */
	function _retire(spr:FlxSprite):Void
	{
		if (spr == null) return;
		if (_pool.indexOf(spr) < 0)
		{
			// Not ours: another system put this object into our container. Only unlist it. Pooling or
			// killing a foreign object breaks the *next* popup instead: _acquire() would hand it out as
			// a rating/digit sprite, and FlxSpriteGroup.loadGraphic() is a no-op, so that slot draws
			// nothing while its screenCenter()/updateHitbox() use the group's member-derived size.
			if (container != null) container.remove(spr, true);
			return;
		}
		if (!spr.alive) return; // never push the same sprite twice
		_tweens.remove(spr);
		if (container != null) container.remove(spr, true);
		spr.kill();
		_free.push(spr);
	}

	inline function _cancelTween(spr:FlxSprite) {
		var t = _tweens.get(spr);
		if (t != null) { t.cancel(); _tweens.remove(spr); }
	}

	/** Remove every popup from the container and return the sprites to the pool. */
	public function clearAll():Void
	{
		if (container == null) return;
		var arr:Array<FlxSprite> = container.members;
		// Backwards: each removal splices the array, and indices below i are untouched.
		var i:Int = arr.length - 1;
		while (i >= 0)
		{
			var spr:FlxSprite = arr[i--];
			if (spr == null) continue;
			_cancelTween(spr);
			if (spr.alive) _retire(spr);
			else container.remove(spr, true); // defensive: a dead sprite must never keep a slot
		}
	}

	inline function _show(spr:FlxSprite):Void
	{
		container.add(spr);
		// add() runs FlxSpriteGroup.preAdd(), which overwrites the sprite camera with the container's
		// *raw* array (null for comboGroup). Re-assert the popup cameras so every revive renders
		// exactly like the first one instead of depending on insertion order.
		if (targetCameras != null) spr.cameras = targetCameras;
	}

	/** Start the stock fade-out; the sprite is unlisted and pooled when the tween finishes. */
	function _fade(spr:FlxSprite, duration:Float, delay:Float):Void
	{
		var t = FlxTween.tween(spr, {alpha: 0}, duration, {
			startDelay: delay,
			onComplete: function(_) _retire(spr)
		});
		_tweens.set(spr, t);
	}

	/** Resolve a popup graphic once; re-resolve only if the engine purge destroyed the cached one. */
	inline function _graphic(key:String):FlxGraphic
	{
		var g:FlxGraphic = _gfxCache.get(key);
		if (g != null && _graphicAlive(g)) return g;
		g = Paths.image(key);
		if (g != null) _gfxCache.set(key, g);
		return g;
	}

	/** Same test as Paths.isGraphicAlive(): a destroyed FlxGraphic loses its frame collections. */
	static inline function _graphicAlive(g:FlxGraphic):Bool
	{
		if (g == null || g.bitmap == null) return false;
		@:privateAccess
		return g.frameCollections != null;
	}

	public function show(ratingKey:String, combo:Int, rate:Float, baseX:Float,
		hideHud:Bool, showRating:Bool, showCombo:Bool, showComboNum:Bool,
		comboOffset:Array<Int>, crochet:Float, comboStacking:Bool):Void
	{
		if (!comboStacking) clearAll();

		var px:String  = isPixel ? 'pixelUI/' : '';
		var sx:String  = isPixel ? '-pixel' : '';
		var pr:Float   = rate;
		var pz:Float   = daPixelZoom;
		var cam:Array<FlxCamera> = targetCameras;
		var aa:Bool    = antialiasing;
		var fadeDur:Float = FADE_DURATION / pr;

		var offRX:Float = comboOffset.length > 0 ? comboOffset[0] : 0;
		var offRY:Float = comboOffset.length > 1 ? comboOffset[1] : 0;
		var offNX:Float = comboOffset.length > 2 ? comboOffset[2] : 0;
		var offNY:Float = comboOffset.length > 3 ? comboOffset[3] : 0;

		// ---- rating sprite (members[0]) ----
		if (showRating)
		{
			var r:FlxSprite = _acquire();
			_config(r, _graphic(px + ratingKey + sx),
				baseX + RATING_X_OFFSET + offRX,
				RATING_Y_OFFSET - offRY,
				!hideHud, cam, aa,
				ACCEL_Y_RATING * pr * pr,
				-FlxG.random.float(VEL_Y_RATING_MIN, VEL_Y_RATING_MAX) * pr,
				-FlxG.random.float(VEL_X_RATING_MIN, VEL_X_RATING_MAX) * pr,
				isPixel ? (pz * PIXEL_RATING_SCALE) : RATING_SCALE);
			_show(r);
			_fade(r, fadeDur, crochet * FADE_DELAY_RATING / pr);
		}

		// ---- number sprites (members[1+]) ----
		var maxX:Float = 0;
		if (showComboNum)
		{
			var digits:Array<Int> = _splitDigits(combo);
			var numDelay:Float = crochet * FADE_DELAY_NUM / pr;
			for (loop in 0...digits.length)
			{
				var ns:FlxSprite = _acquire();
				_config(ns, _graphic(px + 'num' + digits[loop] + sx),
					baseX + (NUM_SPACING * loop) + NUM_X_START + offNX,
					NUM_Y_OFFSET - offNY,
					!hideHud, cam, aa,
					FlxG.random.float(ACCEL_Y_NUM_MIN, ACCEL_Y_NUM_MAX) * pr * pr,
					-FlxG.random.float(VEL_Y_NUM_MIN, VEL_Y_NUM_MAX) * pr,
					-FlxG.random.float(VEL_X_NUM_MIN, VEL_X_NUM_MAX) * pr,
					isPixel ? (pz * PIXEL_NUM_SCALE) : NUM_SCALE);
				_show(ns);
				_fade(ns, fadeDur, numDelay);

				if (ns.x > maxX) maxX = ns.x;
			}
		}

		// ---- combo word sprite (members[last]) ----
		if (showCombo)
		{
			var c:FlxSprite = _acquire();
			_config(c, _graphic(px + 'combo' + sx),
				baseX + offRX,
				COMBO_Y_OFFSET - offRY,
				!hideHud, cam, aa,
				FlxG.random.float(ACCEL_Y_COMBO_MIN, ACCEL_Y_COMBO_MAX) * pr * pr,
				-FlxG.random.float(VEL_Y_COMBO_MIN, VEL_Y_COMBO_MAX) * pr,
				-FlxG.random.float(VEL_X_COMBO_MIN, VEL_X_COMBO_MAX) * pr,
				isPixel ? (pz * PIXEL_COMBO_SCALE) : COMBO_SCALE);
			c.x = maxX + COMBO_X_EXTRA;
			_show(c);
			_fade(c, fadeDur, crochet * FADE_DELAY_COMBO / pr);
		}
	}

	/**
	 * Applies the full per-hit sprite state. The rating and the digit/COMBO sprites used to have two
	 * byte-identical copies of this body; one shared method keeps them provably in sync.
	 */
	inline function _config(spr:FlxSprite, graphic:FlxGraphic,
		x:Float, yOff:Float, visible:Bool,
		cameras:Array<FlxCamera>, aa:Bool,
		accelY:Float, velY:Float, velX:Float,
		scale:Float):Void
	{
		spr.alpha = 1; spr.scale.set(1, 1);
		spr.acceleration.set(0, 0); spr.velocity.set(0, 0); spr.angle = 0;
		spr.loadGraphic(graphic);
		spr.screenCenter();
		spr.x = x; spr.y += yOff;
		spr.acceleration.y = accelY; spr.velocity.y = velY; spr.velocity.x = velX;
		spr.visible = visible; spr.antialiasing = aa;
		if (cameras != null) spr.cameras = cameras;
		if (scale > 0) spr.setGraphicSize(Std.int(spr.width * scale));
		spr.updateHitbox();
	}

	/**
	 * Digits drawn under the rating icon. Every digit is shown, so the popup never looks like it
	 * wrapped back to 0 at a digit boundary (the vanilla-style 4-digit cap rendered 10000 as
	 * "0000", 10001 as "0001", ...). The number row grows with the combo and the COMBO word
	 * follows its right edge (maxX), which is the pre-existing behaviour of this engine.
	 * combo < 10 is still hidden by the caller (PlayState keeps that on purpose).
	 */
	static function _splitDigits(n:Int):Array<Int>
	{
		if (n == 0) return [0];
		var d:Array<Int> = [];
		while (n > 0) { d.push(n % 10); n = Math.floor(n / 10); }
		d.reverse();
		if (d.length == 2) d.insert(0, 0);
		return d;
	}

	public function destroyAll():Void
	{
		// Unlist first: destroying still-listed members would leave the group pointing at dead sprites.
		clearAll();
		for (s in _pool) s.destroy();
		_pool = [];
		_free = [];
		_tweens = new Map();
		_gfxCache = new Map();
	}
}
