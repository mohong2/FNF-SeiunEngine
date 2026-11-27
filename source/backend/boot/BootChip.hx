package backend.boot;

import flixel.FlxSprite;
import flixel.graphics.FlxGraphic;
import flixel.group.FlxGroup.FlxTypedGroup;
import flixel.text.FlxText;
import flixel.text.FlxText.FlxTextAlign;
import flixel.util.FlxColor;

/**
 * One corner label of the boot screen: a mark and/or a line of technical text, laid out as
 * a single unit.
 *
 * The chips are what make the boot say something concrete — which platform this is running
 * on, which renderer is actually drawing the frame. Each one is anchored to an edge and
 * vertically centred on a row, so a wider stage just moves them apart instead of pushing
 * them around.
 *
 * Marks are scaled about their own top-left corner (origin and offset both cleared): a
 * centred origin would move the artwork by origin * (1 - scale) the moment the sprite is
 * scaled, which is how a renderer mark ends up half off the bottom of the screen.
 */
class BootChip extends FlxTypedGroup<FlxSprite>
{
	static inline var GAP_ICON:Float = 12;

	var icon:FlxSprite;
	var label:FlxText;

	/** Size of the mark after scaling, in stage units. */
	var iconWidth:Float = 0;
	var iconHeight:Float = 0;

	var presence:Float = 0;

	/** Total width of the laid-out chip, in stage units. */
	public var chipWidth(default, null):Float = 0;

	public function new(text:String, font:String, size:Int, color:FlxColor, ?iconGraphic:FlxGraphic, ?iconHeightPx:Float = 0)
	{
		super();

		if (iconGraphic != null && iconGraphic.width > 0)
		{
			icon = new FlxSprite(0, 0, iconGraphic);
			icon.antialiasing = true;
			icon.color = color;
			scaleIcon(iconGraphic, iconHeightPx);
			add(icon);
		}

		label = new FlxText(0, 0, 0, text, size);
		label.setFormat(font, size, color, FlxTextAlign.LEFT);
		add(label);

		measure();
	}

	/** Sizes the mark to the requested height and pins its top-left to its own position. */
	function scaleIcon(graphic:FlxGraphic, heightPx:Float):Void
	{
		var k:Float = (heightPx > 0) ? heightPx / graphic.height : 1;
		iconWidth = graphic.width * k;
		iconHeight = graphic.height * k;
		icon.origin.set(0, 0);
		icon.offset.set(0, 0);
		icon.scale.set(k, k);
	}

	public function setText(text:String):Void
	{
		if (label.text == text) return;
		label.text = text;
		measure();
	}

	public function setLabelColor(color:FlxColor):Void
	{
		label.color = color;
	}

	function measure():Void
	{
		var w:Float = 0;
		if (icon != null) w += iconWidth + (label.text.length > 0 ? GAP_ICON : 0);
		w += label.textField.textWidth;
		chipWidth = w;
	}

	/**
	 * Places the chip with its left edge at x (or its right edge, when right-aligned),
	 * vertically centred on the given row.
	 */
	public function place(x:Float, rowY:Float, rightAligned:Bool = false):Void
	{
		var left:Float = rightAligned ? x - chipWidth : x;
		var cursor:Float = left;

		if (icon != null)
		{
			icon.x = cursor;
			icon.y = rowY - iconHeight / 2;
			cursor += iconWidth + (label.text.length > 0 ? GAP_ICON : 0);
		}

		label.x = cursor;
		label.y = rowY - label.height / 2;
	}

	/** 0 = hidden, 1 = fully visible. */
	public function fade(value:Float):Void
	{
		presence = value < 0 ? 0 : (value > 1 ? 1 : value);
		applyAlpha();
	}

	function applyAlpha():Void
	{
		if (icon != null) icon.alpha = 0.92 * presence;
		label.alpha = 0.9 * presence;
		visible = presence > 0.001;
	}

	// Nothing animates on its own: fade() and the boot timeline drive every value.
}