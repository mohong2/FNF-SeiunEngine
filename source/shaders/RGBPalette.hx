package shaders;

import flixel.FlxSprite;
import flixel.math.FlxMath;
import flixel.system.FlxAssets.FlxShader;
import flixel.util.FlxColor;
import ClientPrefs;

/**
 * Flexible fallback behaviour:
 *  - by default it does not take over a sprite's shader (note colours keep using colorSwap);
 *  - the global palette is cloned and attached only when a mod script actually changes
 *    rgbShader.r/g/b/mult, so scripts like `rgbShader.mult = 0` work out of the box;
 *  - rgbShader.enabled = false falls back to the engine shader (fallbackShader) instead of
 *    being set to null;
 *  - attaching is refused while ClientPrefs.data.shaders is off, keeping rendering shader-free.
 *
 * The global palette is cached per (noteData + mania), so every note on a lane shares one
 * uniform instead of building a shader each.
 */
class RGBPalette
{
	public var shader(default, null):RGBPaletteShader = new RGBPaletteShader();
	public var r(default, set):FlxColor;
	public var g(default, set):FlxColor;
	public var b(default, set):FlxColor;
	public var mult(default, set):Float;

	private function set_r(color:FlxColor):FlxColor
	{
		r = color;
		shader.r.value = [color.redFloat, color.greenFloat, color.blueFloat];
		return color;
	}

	private function set_g(color:FlxColor):FlxColor
	{
		g = color;
		shader.g.value = [color.redFloat, color.greenFloat, color.blueFloat];
		return color;
	}

	private function set_b(color:FlxColor):FlxColor
	{
		b = color;
		shader.b.value = [color.redFloat, color.greenFloat, color.blueFloat];
		return color;
	}

	private function set_mult(value:Float):Float
	{
		mult = FlxMath.bound(value, 0, 1);
		shader.mult.value = [mult];
		return mult;
	}

	public function new()
	{
		r = 0xFFFF0000;
		g = 0xFF00FF00;
		b = 0xFF0000FF;
		mult = 1.0;
	}
}

/**
 * Reference held by a sprite: reads and writes go to the shared palette and the first write clones it,
 * so one mod script cannot repaint a whole lane.
 */
class RGBShaderReference
{
	public var r(default, set):FlxColor;
	public var g(default, set):FlxColor;
	public var b(default, set):FlxColor;
	public var mult(default, set):Float;
	public var enabled(default, set):Bool = false;

	/** Shared global palette (all notes on a lane share it). */
	public var parent:RGBPalette;

	private var _owner:FlxSprite;
	private var _original:RGBPalette;

	/** Shader used when enabled=false (this engine: colorSwap.shader; null = no shader). */
	public var fallbackShader:FlxShader = null;

	/**
	 * Neutral-aware fallback: resolved through the ColorSwap reference, so a neutral colour attaches no
	 * shader at all (essential for batching thousands of notes) and its GLSL program is only built otherwise.
	 */
	public var fallbackColorSwap:ColorSwap = null;

	/** Blocks the RGB shader while SONG.disableNoteRGB is set. */
	public var forceDisabled:Bool = false;

	public function new(owner:FlxSprite, ref:RGBPalette)
	{
		parent = ref;
		_owner = owner;
		_original = ref;

		@:bypassAccessor
		{
			r = parent.r;
			g = parent.g;
			b = parent.b;
			mult = parent.mult;
		}
	}

	/** Rebinds a reused instance to another lane's shared palette (note pooling / mania changes). */
	public function rebind(ref:RGBPalette):Void
	{
		parent = ref;
		_original = ref;
		allowNew = true;
		@:bypassAccessor
		{
			r = parent.r;
			g = parent.g;
			b = parent.b;
			mult = parent.mult;
		}
		enabled = false;
	}

	private function set_r(value:FlxColor):FlxColor
	{
		if (allowNew && value != _original.r) cloneOriginal();
		return (r = parent.r = value);
	}

	private function set_g(value:FlxColor):FlxColor
	{
		if (allowNew && value != _original.g) cloneOriginal();
		return (g = parent.g = value);
	}

	private function set_b(value:FlxColor):FlxColor
	{
		if (allowNew && value != _original.b) cloneOriginal();
		return (b = parent.b = value);
	}

	private function set_mult(value:Float):Float
	{
		if (allowNew && value != _original.mult) cloneOriginal();
		return (mult = parent.mult = value);
	}

	private function set_enabled(value:Bool):Bool
	{
		enabled = value;
		if (value && !forceDisabled && ClientPrefs.data.shaders)
			_owner.shader = parent.shader;
		else if (fallbackColorSwap != null)
		{
			if (ClientPrefs.data.perfMode && fallbackColorSwap.isNeutral())
				_owner.shader = null;
			else
				_owner.shader = fallbackColorSwap.shader;
		}
		else
			_owner.shader = fallbackShader;
		return enabled;
	}

	public var allowNew:Bool = true;

	private function cloneOriginal():Void
	{
		if (!allowNew) return;
		allowNew = false;
		if (_original != parent) return;

		parent = new RGBPalette();
		parent.r = _original.r;
		parent.g = _original.g;
		parent.b = _original.b;
		parent.mult = _original.mult;
		// Attach through the setter so forceDisabled / the shaders setting are honoured
		enabled = true;
	}
}

class RGBPaletteShader extends FlxShader
{
	@:glFragmentHeader('
		#pragma header

		uniform vec3 r;
		uniform vec3 g;
		uniform vec3 b;
		uniform float mult;

		vec4 flixel_texture2DCustom(sampler2D bitmap, vec2 coord) {
			vec4 color = flixel_texture2D(bitmap, coord);
			if (!hasTransform || color.a == 0.0 || mult == 0.0) {
				return color;
			}

			vec4 newColor = color;
			newColor.rgb = min(color.r * r + color.g * g + color.b * b, vec3(1.0));
			newColor.a = color.a;

			color = mix(color, newColor, mult);

			if(color.a > 0.0) {
				return vec4(color.rgb, color.a);
			}
			return vec4(0.0, 0.0, 0.0, 0.0);
		}')

	@:glFragmentSource('
		#pragma header

		void main() {
			gl_FragColor = flixel_texture2DCustom(bitmap, openfl_TextureCoordv);
		}')

	public function new()
	{
		super();
	}
}
