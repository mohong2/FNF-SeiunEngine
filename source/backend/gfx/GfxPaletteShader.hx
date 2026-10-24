package backend.gfx;

#if (FLX_DRAW_QUADS && !flash)
import flixel.graphics.tile.FlxGraphicsShader;

/**
 * L1b palette shader.
 *
 * Identical to FlxGraphicsShader's vertex stage and colour-transform maths, but
 * the fragment stage reads a one-byte index from "bitmap" and looks the colour
 * up in the 256x1 "palette" texture. Both inputs are sampled with NEAREST by
 * the draw item, so an index is never interpolated into a different entry.
 *
 * The index comes from .a for GL_ALPHA textures (GLES2/WebGL1) or .r for
 * R8/LUMINANCE (desktop core and GLES3); paletteUseAlpha selects the variant at
 * runtime without recompiling the shader.
 */
class GfxPaletteShader extends FlxGraphicsShader
{
	@:glFragmentHeader("
		uniform sampler2D palette;
		uniform bool paletteUseAlpha;

		vec4 flixel_palette2D(sampler2D indexTex, sampler2D paletteTex, vec2 coord)
		{
			vec4 texel = texture2D(indexTex, coord);
			float index = (paletteUseAlpha ? texel.a : texel.r) * 255.0;
			index = floor(index + 0.5);

			// 256 entries, NEAREST: entry centres are (i + 0.5) / 256.
			vec4 color = texture2D(paletteTex, vec2((index + 0.5) / 256.0, 0.5));

			if (!hasTransform)
			{
				return color;
			}

			if (color.a == 0.0)
			{
				return vec4(0.0, 0.0, 0.0, 0.0);
			}

			if (!hasColorTransform)
			{
				return color * openfl_Alphav;
			}

			color = vec4(color.rgb / color.a, color.a);

			// Same component-wise diagonal transform as FlxGraphicsShader; Mali/
			// Adreno drivers do not reliably fold the mat4 construction away.
			color = clamp(openfl_ColorOffsetv + vec4(color.rgb * openfl_ColorMultiplierv.rgb, color.a * openfl_ColorMultiplierv.w), 0.0, 1.0);

			if (color.a > 0.0)
			{
				return vec4(color.rgb * color.a * openfl_Alphav, color.a * openfl_Alphav);
			}
			return vec4(0.0, 0.0, 0.0, 0.0);
		}
	")
	@:glFragmentSource("
		#pragma header

		void main(void)
		{
			gl_FragColor = flixel_palette2D(bitmap, palette, openfl_TextureCoordv);
		}
	")
	public function new()
	{
		super();
	}
}
#end
