package backend;

import flixel.FlxG;
import flixel.system.scaleModes.BaseScaleMode;
import lime.ui.Window;
import mohong.TraceManager;
import openfl.events.Event;
import openfl.geom.Matrix;

/**
 * Device-pixel aware replacement for flixel's `RatioScaleMode`.
 *
 * A scale mode positions the game canvas in *stage units*, so it has to know how
 * many stage units one device pixel is worth. That ratio is not constant:
 *
 *   - lime measures its window in points (`window.width`, e.g. 812),
 *   - the drawable behind it is measured in pixels (`window.width * window.scale`,
 *     2436 on a 3x iPhone, 2x on a Retina Mac),
 *   - openfl keeps the stage in points (display matrix = window.scale) or moves it
 *     into drawable pixels (`openfl_dpi_aware`, matrix = 1).
 *
 * `RatioScaleMode` takes `stage.stageWidth` for granted. When that value describes
 * a different space than the display matrix, the letterbox offset is computed in
 * one space and applied in the other: the canvas lands off-centre by
 * `offset * pixelRatio` and the part that leaves the screen is clipped, which is
 * the "render only covers part of the screen" bug.
 *
 * This mode reads the real mapping (Context3D's back buffer and the stage's display
 * matrix) and lays the game out from it, so it is correct in either convention. On
 * a consistent stage it reproduces `RatioScaleMode` exactly.
 *
 * `fillScreen` selects the fit: `false` = contain (letterbox), `true` = cover (crop).
 */
class RenderScale extends BaseScaleMode
{
	/** Fill the screen and crop, instead of letterboxing. */
	public static var fillScreen:Bool = false;

	/** Installed instance, `null` until `install()` ran. */
	public static var instance(default, null):RenderScale = null;

	static var handlersInstalled:Bool = false;

	// Last measurement, for describe() / the crash dump.
	public static var physicalWidth:Int = 0;
	public static var physicalHeight:Int = 0;
	public static var stageUnitsPerPixel:Float = 1;
	public static var displayMatrixScale:Float = 1;
	public static var displayMatrixScaleY:Float = 1;
	public static var windowScale:Float = 1;
	public static var windowWidth:Int = 0;
	public static var windowHeight:Int = 0;
	public static var stageWidth:Int = 0;
	public static var stageHeight:Int = 0;
	/** True when the stage's display matrix and the drawable size disagree. */
	public static var inconsistent:Bool = false;
	/** Why the last measurement fell back to the stock behaviour, or `null`. */
	public static var fallbackReason:String = null;

	// Values cached by measure() for the size hooks below.
	var measured:Bool = false;
	var fitUnitsX:Float = 0;
	var fitUnitsY:Float = 0;
	var visibleUnitsX:Float = 0;
	var visibleUnitsY:Float = 0;
	var stageUnitsPerPixelY:Float = 1;
	// Stage coordinate of the top-left visible pixel: the display matrix maps
	// device = matrix * stage, so a translated matrix moves the visible origin.
	var visibleOriginX:Float = 0;
	var visibleOriginY:Float = 0;
	var warnedInconsistent:Bool = false;

	public function new()
	{
		super();
	}

	/** Installs the mode (idempotent) and points `FlxG.scaleMode` at it. */
	public static function install():RenderScale
	{
		if (instance == null)
		{
			instance = new RenderScale();
		}

		if (FlxG.game != null && FlxG.scaleMode != instance)
		{
			FlxG.scaleMode = instance;
		}
		else
		{
			reapply();
		}

		installHandlers();

		// The drawable size is only valid once the GL surface exists; measure again
		// on the first presented frame.
		requestRemeasure();
		return instance;
	}

	/** Re-applies the layout on the next frame. */
	public static function requestRemeasure():Void
	{
		if (FlxG.stage == null)
		{
			return;
		}

		var done:Bool = false;
		var onFrame:openfl.events.Event->Void = null;
		onFrame = function(_)
		{
			if (done)
			{
				return;
			}
			done = true;
			FlxG.stage.removeEventListener(Event.ENTER_FRAME, onFrame);
			reapply();
		};
		FlxG.stage.addEventListener(Event.ENTER_FRAME, onFrame);
	}

	/**
	 * Re-measures now. `FlxGame.onResize` is private to flixel, so this goes through
	 * the public `FlxG.resizeGame`, which re-runs the current scale mode.
	 */
	public static function reapply():Void
	{
		if (FlxG.game == null || FlxG.stage == null)
		{
			return;
		}
		if (FlxG.scaleMode != instance)
		{
			FlxG.scaleMode = instance;
		}
		FlxG.resizeGame(FlxG.stage.stageWidth, FlxG.stage.stageHeight);
	}

	/** Switches between contain and cover, and re-applies. */
	public static function setFillScreen(value:Bool):Void
	{
		if (fillScreen == value)
		{
			return;
		}
		fillScreen = value;
		reapply();
	}

	static function installHandlers():Void
	{
		if (handlersInstalled || FlxG.stage == null)
		{
			return;
		}
		handlersInstalled = true;

		// Mobile targets report the new window size only after the app becomes
		// active again, so the resize event alone can arrive late.
		FlxG.signals.focusGained.add(function() requestRemeasure());
	}

	override public function onMeasure(Width:Int, Height:Int):Void
	{
		if (!measure(Width, Height))
		{
			// No window or no drawable yet: keep flixel's behaviour instead of
			// dividing by zero. The next resize retries.
			measured = false;
			super.onMeasure(Width, Height);
			return;
		}

		measured = true;
		super.onMeasure(Width, Height);
	}

	override function updateGameSize(Width:Int, Height:Int):Void
	{
		if (!measured)
		{
			super.updateGameSize(Width, Height);
			return;
		}
		gameSize.set(fitUnitsX, fitUnitsY);
	}

	override function updateDeviceSize(Width:Int, Height:Int):Void
	{
		if (!measured)
		{
			super.updateDeviceSize(Width, Height);
			return;
		}
		deviceSize.set(visibleUnitsX, visibleUnitsY);
	}

	override function updateGamePosition():Void
	{
		if (FlxG.game == null)
		{
			return;
		}
		// `offset` is centred inside the visible rectangle, which does not always
		// start at the stage origin.
		FlxG.game.x = offset.x + visibleOriginX;
		FlxG.game.y = offset.y + visibleOriginY;
	}

	/**
	 * Reads the stage <-> device mapping and caches the target rectangle.
	 * Returns false when there is nothing trustworthy to measure yet.
	 */
	function measure(stageW:Int, stageH:Int):Bool
	{
		var window:Window = null;
		try
		{
			if (FlxG.stage != null)
			{
				window = FlxG.stage.window;
			}
		}
		catch (e:Dynamic) {}

		if (window == null)
		{
			fallbackReason = 'no window';
			return false;
		}

		var logicalW:Int = 0;
		var logicalH:Int = 0;
		try
		{
			logicalW = window.width;
			logicalH = window.height;
		}
		catch (e:Dynamic) {}

		if (logicalW <= 0 || logicalH <= 0 || stageW <= 0 || stageH <= 0)
		{
			fallbackReason = 'zero size (window ' + logicalW + 'x' + logicalH + ', stage ' + stageW + 'x' + stageH + ')';
			return false;
		}

		var ratio:Float = 1;
		try
		{
			ratio = window.scale;
		}
		catch (e:Dynamic) {}
		if (!Math.isFinite(ratio) || ratio <= 0)
		{
			ratio = 1;
		}

		// Drawable size: what openfl configured for this frame, i.e. what the GPU
		// scans out.
		var pxW:Int = 0;
		var pxH:Int = 0;
		try
		{
			var c3d = FlxG.stage.context3D;
			if (c3d != null)
			{
				pxW = c3d.backBufferWidth;
				pxH = c3d.backBufferHeight;
			}
		}
		catch (e:Dynamic) {}

		if (pxW <= 0 || pxH <= 0)
		{
			pxW = Math.round(logicalW * ratio);
			pxH = Math.round(logicalH * ratio);
		}

		// Device pixels per stage unit: exactly what openfl multiplies stage
		// coordinates by when it builds the projection.
		var matrixX:Float = ratio;
		var matrixY:Float = ratio;
		var matrixTX:Float = 0;
		var matrixTY:Float = 0;
		try
		{
			@:privateAccess var matrix:Matrix = FlxG.stage.__displayMatrix;
			if (matrix != null)
			{
				matrixX = matrix.a;
				matrixY = matrix.d;
				matrixTX = matrix.tx;
				matrixTY = matrix.ty;
			}
		}
		catch (e:Dynamic) {}

		if (!Math.isFinite(matrixX) || matrixX <= 0)
		{
			matrixX = ratio;
		}
		if (!Math.isFinite(matrixY) || matrixY <= 0)
		{
			matrixY = ratio;
		}

		stageUnitsPerPixel = 1 / matrixX;
		stageUnitsPerPixelY = 1 / matrixY;

		// The part of the stage that is on screen, in stage units.
		visibleUnitsX = pxW * stageUnitsPerPixel;
		visibleUnitsY = pxH * stageUnitsPerPixelY;

		// When this disagrees with the stage's own size, laying the game out inside
		// the visible rectangle is the only thing that still fills the screen.
		inconsistent = Math.abs(visibleUnitsX - stageW) > Math.max(2, stageW * 0.01)
			|| Math.abs(visibleUnitsY - stageH) > Math.max(2, stageH * 0.01);
		if (!inconsistent)
		{
			visibleUnitsX = stageW;
			visibleUnitsY = stageH;
		}

		visibleOriginX = -matrixTX / matrixX;
		visibleOriginY = -matrixTY / matrixY;

		// Fit the game into the physical screen. The aspect ratio comes from the
		// initial game size: BaseScaleMode resets FlxG.width/height right after this.
		var gameW:Int = FlxG.initialWidth > 0 ? FlxG.initialWidth : FlxG.width;
		var gameH:Int = FlxG.initialHeight > 0 ? FlxG.initialHeight : FlxG.height;
		var gameRatio:Float = gameW / Math.max(1, gameH);
		var realRatio:Float = pxW / Math.max(1, pxH);
		var fitByWidth:Bool = realRatio < gameRatio;
		if (fillScreen)
		{
			fitByWidth = !fitByWidth;
		}

		var fitPxW:Float;
		var fitPxH:Float;
		if (fitByWidth)
		{
			fitPxW = pxW;
			fitPxH = pxW / gameRatio;
		}
		else
		{
			fitPxH = pxH;
			fitPxW = pxH * gameRatio;
		}

		fitUnitsX = fitPxW * stageUnitsPerPixel;
		fitUnitsY = fitPxH * stageUnitsPerPixelY;

		physicalWidth = pxW;
		physicalHeight = pxH;
		stageWidth = stageW;
		stageHeight = stageH;
		windowWidth = logicalW;
		windowHeight = logicalH;
		windowScale = ratio;
		displayMatrixScale = matrixX;
		displayMatrixScaleY = matrixY;
		fallbackReason = null;

		if (inconsistent && !warnedInconsistent)
		{
			warnedInconsistent = true;
			TraceManager.warn('trace.render.inconsistent',
				'Stage/display mismatch: stage {}x{} units, visible {}x{} units (matrix {}x{}), drawable {}x{}',
				[stageW, stageH, Std.int(visibleUnitsX), Std.int(visibleUnitsY), matrixX, matrixY, pxW, pxH]);
		}

		return true;
	}

	/** One-line summary for the boot log and the crash dump. */
	public static function describe():String
	{
		var x:Float = FlxG.game != null ? FlxG.game.x : 0;
		var y:Float = FlxG.game != null ? FlxG.game.y : 0;
		var camScaleX:Float = instance != null ? instance.scale.x : 1;
		var camScaleY:Float = instance != null ? instance.scale.y : 1;

		return 'window=' + windowWidth + 'x' + windowHeight
			+ ' drawable=' + physicalWidth + 'x' + physicalHeight
			+ ' stage=' + stageWidth + 'x' + stageHeight
			+ ' windowScale=' + fmt(windowScale)
			+ ' displayMatrix=' + fmt(displayMatrixScale) + 'x' + fmt(displayMatrixScaleY)
			+ ' game=' + FlxG.initialWidth + 'x' + FlxG.initialHeight
			+ ' canvas=' + fmt(x) + ',' + fmt(y)
			+ ' camScale=' + fmt(camScaleX) + '/' + fmt(camScaleY)
			+ ' fit=' + (fillScreen ? 'cover' : 'contain')
			+ (inconsistent ? ' INCONSISTENT' : '')
			+ (fallbackReason != null ? ' fallback=' + fallbackReason : '');
	}

	static inline function fmt(v:Float):String
	{
		if (!Math.isFinite(v))
		{
			return 'NaN';
		}
		return Std.string(Math.round(v * 100) / 100);
	}
}
