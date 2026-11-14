package flixel.graphics.tile;

// Local override of .haxelib/flixel/git/flixel/graphics/tile/FlxDrawQuadsItem.hx.
// Only the #if seiun_vulkan block at the top of render() is added; without that
// define the file compiles to the upstream behaviour.

#if FLX_DRAW_QUADS
import flixel.FlxCamera;
import flixel.graphics.frames.FlxFrame;
import flixel.graphics.tile.FlxDrawBaseItem.FlxDrawItemType;
import flixel.system.FlxAssets.FlxShader;
import flixel.math.FlxMatrix;
import openfl.geom.ColorTransform;
import openfl.display.ShaderParameter;
import openfl.Vector;

/**
 * Batched quad draw item.
 *
 * Both vertex alpha and vertex colour are optional attributes as far as openfl is concerned:
 * a `ShaderParameter` whose value holds fewer entries than one per vertex is uploaded as a
 * single constant generic attribute and costs nothing per vertex. So rather than always
 * pushing 4 alpha floats and 8 colour floats per quad, this item keeps one value per
 * attribute while the whole batch agrees on it, and only materialises the per-vertex arrays
 * once the batch actually has to mix values.
 *
 * Invariants:
 *  - `hasVertexColors` is `true` iff at least one quad wrote a non-identity colour, and the
 *    colour arrays then hold exactly `quadCount * VERTICES_PER_QUAD` entries of 4 components
 *    each, so a quad can never read another quad's colour.
 *  - `uniformAlpha` is `true` iff every quad in the batch shares one alpha; otherwise
 *    `alphas` holds one entry per vertex. Backfill values match what the eager
 *    implementation wrote for the same quads: multipliers `(1, 1, 1, 1)`, offsets
 *    `(0, 0, 0, 0)` and `transform.alphaMultiplier`.
**/
class FlxDrawQuadsItem extends FlxDrawBaseItem<FlxDrawQuadsItem>
{
	static inline var VERTICES_PER_QUAD = #if (openfl >= "8.5.0") 4 #else 6 #end;

	public var shader:FlxShader;

	var rects:Vector<Float>;
	var transforms:Vector<Float>;

	#if cpp
	/**
	 * Direct `Array<Float>` views onto `rects` / `transforms`.
	 *
	 * `openfl.Vector<Float>` is an abstract over the `IVector` interface, so every `push()` is a
	 * virtual dispatch. Pushing through the backing array instead removes ten interface calls
	 * per quad.
	 *
	 * `__array` is an implementation detail of openfl's non-flash `Vector` (see
	 * `openfl.Vector.FloatVector`), so this is deliberately restricted to `cpp`:
	 *  - `openfl.Vector` on cpp is `FloatVector implements IVector<Float>` wrapping
	 *    `private var __array:Array<Float>`, and `openfl.display._internal.Context3DGraphics`
	 *    reads it the same way (`untyped (rects).__array`) before handing it to `drawQuads()`.
	 *  - The alias survives batch reuse: `reset()` clears the vector with `rects.length = 0`,
	 *    which on cpp is `cpp.NativeArray.setSize(__array, 0)` - it shrinks the very same
	 *    `Array` object in place, it never reallocates or replaces it. Growing the array through
	 *    `push()` likewise keeps the `Array` object identity even when its backing store moves.
	 *  - On every other target the plain `Vector.push()` path below is used, i.e. the original
	 *    behaviour, so nothing depends on this detail off-cpp.
	 */
	var rectsArray:Array<Float>;
	/** `Array<Float>` view onto `transforms`, see `rectsArray`. */
	var transformsArray:Array<Float>;
	#end

	/** Per-vertex alpha, only filled once this batch mixes more than one alpha value. */
	var alphas:Array<Float>;
	/** Per-vertex colour multipliers, only filled once this batch contains a non-identity colour. */
	var colorMultipliers:Array<Float>;
	/** Per-vertex colour offsets, only filled once this batch contains a non-identity colour. */
	var colorOffsets:Array<Float>;

	/** True once this batch contains non-identity vertex colours. */
	var hasVertexColors:Bool = false;
	/** Number of quads already appended to this batch (used for lazy array materialisation). */
	var quadCount:Int = 0;

	/** Alpha shared by every quad added so far; uploaded as a constant attribute while `uniformAlpha`. */
	var firstAlpha:Float = 1.0;
	/** False as soon as a quad with a different alpha joins this batch. */
	var uniformAlpha:Bool = true;
	/** Reusable single element array used to upload a constant alpha attribute. */
	var alphaConstant:Array<Float>;

	public function new()
	{
		super();
		type = FlxDrawItemType.TILES;
		rects = new Vector<Float>();
		transforms = new Vector<Float>();
		#if cpp
		rectsArray = untyped rects.__array;
		transformsArray = untyped transforms.__array;
		#end
		alphas = [];
		alphaConstant = [1.0];
	}

	inline function pushRect(value:Float):Void
	{
		#if cpp
		rectsArray.push(value);
		#else
		rects.push(value);
		#end
	}

	inline function pushTransform(value:Float):Void
	{
		#if cpp
		transformsArray.push(value);
		#else
		transforms.push(value);
		#end
	}

	override public function reset():Void
	{
		super.reset();
		rects.length = 0;
		transforms.length = 0;
		alphas.splice(0, alphas.length);
		if (colorMultipliers != null)
			colorMultipliers.splice(0, colorMultipliers.length);
		if (colorOffsets != null)
			colorOffsets.splice(0, colorOffsets.length);
		hasVertexColors = false;
		quadCount = 0;
		uniformAlpha = true;
		firstAlpha = 1.0;
	}

	override public function dispose():Void
	{
		super.dispose();
		rects = null;
		transforms = null;
		#if cpp
		rectsArray = null;
		transformsArray = null;
		#end
		alphas = null;
		colorMultipliers = null;
		colorOffsets = null;
		alphaConstant = null;
	}

	override public function addQuad(frame:FlxFrame, matrix:FlxMatrix, ?transform:ColorTransform):Void
	{
		var rect = frame.frame;
		pushRect(rect.x);
		pushRect(rect.y);
		pushRect(rect.width);
		pushRect(rect.height);

		pushTransform(matrix.a);
		pushTransform(matrix.b);
		pushTransform(matrix.c);
		pushTransform(matrix.d);
		pushTransform(matrix.tx);
		pushTransform(matrix.ty);

		// --- alpha: constant attribute until the batch actually mixes alphas ---
		var alphaVal = transform != null ? transform.alphaMultiplier : 1.0;

		if (uniformAlpha)
		{
			if (quadCount == 0)
			{
				firstAlpha = alphaVal;
			}
			else if (alphaVal != firstAlpha)
			{
				// Materialise the constant alpha into a per-vertex array (backfill keeps it
				// vertex aligned), then keep writing one entry per vertex from now on.
				uniformAlpha = false;

				var vertexCount = quadCount * VERTICES_PER_QUAD;
				for (i in 0...vertexCount)
					alphas.push(firstAlpha);
			}
		}

		if (!uniformAlpha)
		{
			for (i in 0...VERTICES_PER_QUAD)
				alphas.push(alphaVal);
		}

		// --- vertex colours: not written at all until the batch needs them ---
		var rMult = transform != null ? transform.redMultiplier : 1;
		var gMult = transform != null ? transform.greenMultiplier : 1;
		var bMult = transform != null ? transform.blueMultiplier : 1;
		var rOff = transform != null ? transform.redOffset : 0.0;
		var gOff = transform != null ? transform.greenOffset : 0.0;
		var bOff = transform != null ? transform.blueOffset : 0.0;
		var aOff = transform != null ? transform.alphaOffset : 0.0;

		var isColored = transform != null
			&& (rMult != 1 || gMult != 1 || bMult != 1
				|| rOff != 0 || gOff != 0 || bOff != 0 || aOff != 0);

		if (isColored)
		{
			if (!hasVertexColors)
			{
				if (colorMultipliers == null)
					colorMultipliers = [];

				if (colorOffsets == null)
					colorOffsets = [];

				// Backfill identity colours for the quads added while this batch was still
				// all-default, so the colour arrays stay quad aligned.
				var vertexCount = quadCount * VERTICES_PER_QUAD;
				for (i in 0...vertexCount)
				{
					colorMultipliers.push(1);
					colorMultipliers.push(1);
					colorMultipliers.push(1);
					colorMultipliers.push(1);

					colorOffsets.push(0);
					colorOffsets.push(0);
					colorOffsets.push(0);
					colorOffsets.push(0);
				}

				hasVertexColors = true;
			}

			for (i in 0...VERTICES_PER_QUAD)
			{
				colorMultipliers.push(rMult);
				colorMultipliers.push(gMult);
				colorMultipliers.push(bMult);
				colorMultipliers.push(1);

				colorOffsets.push(rOff);
				colorOffsets.push(gOff);
				colorOffsets.push(bOff);
				colorOffsets.push(aOff);
			}
		}
		else if (hasVertexColors)
		{
			// This batch already switched to per-vertex colours, so keep identity colours
			// for this default quad to preserve alignment.
			for (i in 0...VERTICES_PER_QUAD)
			{
				colorMultipliers.push(1);
				colorMultipliers.push(1);
				colorMultipliers.push(1);
				colorMultipliers.push(1);

				colorOffsets.push(0);
				colorOffsets.push(0);
				colorOffsets.push(0);
				colorOffsets.push(0);
			}
		}

		quadCount++;
	}

	#if !flash
	override public function render(camera:FlxCamera):Void
	{
		#if seiun_vulkan
		// Opens the frame for this tick even when the item ends up drawing nothing.
		seiun.vulkan.VkQuads.beginSubmit(camera);
		#end

		if (rects.length == 0)
			return;

		if (graphics == null || graphics.shader == null)
			return;

		var shader = shader != null ? shader : graphics.shader;
		// A per-sprite custom shader cannot expand palette indices. Give it a
		// plain RGBA copy of the bitmap so it keeps working byte-for-byte; the
		// palette texture stays alive for every other sprite of this graphic.
		var inputBitmap = graphics.bitmap;
		var paletteIndex:Bool = inputBitmap != null && inputBitmap.paletteApplied;
		if (paletteIndex && this.shader != null)
		{
			inputBitmap = inputBitmap.getRGBAFallback();
			paletteIndex = inputBitmap != null && inputBitmap.paletteApplied;
		}
		shader.bitmap.input = inputBitmap;
		// Palette indices must never be interpolated: a filtered index is a
		// different palette entry, not a blend of two colours.
		shader.bitmap.filter = (!paletteIndex && (camera.antialiasing || antialiasing)) ? LINEAR : NEAREST;

		if (uniformAlpha)
		{
			// A one element value is uploaded as a constant vertex attribute, so the shader
			// reads the same alpha for every vertex without any per-vertex storage.
			alphaConstant[0] = firstAlpha;
			shader.alpha.value = alphaConstant;
		}
		else
		{
			shader.alpha.value = alphas;
		}

		// Only feed the colour arrays when this batch actually needs per-vertex colours;
		// `null` makes openfl upload a constant attribute and lets the shaders take their
		// cheaper untinted path.
		if (hasVertexColors)
		{
			shader.colorMultiplier.value = colorMultipliers;
			shader.colorOffset.value = colorOffsets;
		}
		else
		{
			shader.colorMultiplier.value = null;
			shader.colorOffset.value = null;
		}

		setParameterValue(shader.hasTransform, true);
		setParameterValue(shader.hasColorTransform, hasVertexColors);

		#if seiun_vulkan
		// The shader parameters are complete here, which is what the Vulkan backend
		// needs. Returns false when the backend is off; the OpenGL path below runs.
		if (seiun.vulkan.VkQuads.submit(this, camera, shader)) return;
		#end

		#if (openfl > "8.7.0")
		camera.canvas.graphics.overrideBlendMode(blend);
		#end
		camera.canvas.graphics.beginShaderFill(shader);
		camera.canvas.graphics.drawQuads(rects, null, transforms);
		super.render(camera);
	}

	inline function setParameterValue(parameter:ShaderParameter<Bool>, value:Bool):Void
	{
		if (parameter.value == null)
			parameter.value = [];
		parameter.value[0] = value;
	}
	#end
}
#end
