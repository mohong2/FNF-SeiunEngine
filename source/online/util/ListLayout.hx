package online.util;

/**
 * Geometry of a fixed-row scrolling list (friends / requests / notifications), kept free of
 * flixel on purpose so the neko layout probe can run these functions instead of restating them.
 *
 * The lists in FriendsState are FlxSpriteGroups, whose children carry absolute coordinates: the
 * state must not call screenCenter() on a group after adding rows.
 * so every position here is computed and then applied to the group as-is.
 */
class ListLayout {
	public static inline var STATUS_ONLINE:String = 'ONLINE';
	public static inline var STATUS_OFFLINE:String = 'Offline';

	/** Move the cursor and keep it inside 0..count-1. An empty list keeps the cursor at 0. */
	public static function moveCursor(cursor:Int, step:Int, count:Int):Int {
		if (count <= 0)
			return 0;
		var next = cursor + step;
		if (next < 0)
			return 0;
		if (next > count - 1)
			return count - 1;
		return next;
	}

	/** The cursor step that walks circularly, for the tab bar. */
	public static function wrapCursor(cursor:Int, step:Int, count:Int):Int {
		if (count <= 0)
			return 0;
		var next = (cursor + step) % count;
		if (next < 0)
			next += count;
		return next;
	}

	/** Never negative: an empty list always has scroll 0. */
	public static function clampScroll(scroll:Int, count:Int, visibleRows:Int):Int {
		var max = count - visibleRows;
		if (max < 0)
			max = 0;
		if (scroll < 0)
			return 0;
		if (scroll > max)
			return max;
		return scroll;
	}

	/** Smallest move of a valid scroll that brings `cursor` inside the visible window. */
	public static function scrollToShow(scroll:Int, cursor:Int, count:Int, visibleRows:Int):Int {
		if (visibleRows <= 0)
			return 0;
		var next = clampScroll(scroll, count, visibleRows);
		if (cursor < next)
			next = cursor;
		else if (cursor >= next + visibleRows)
			next = cursor - visibleRows + 1;
		return clampScroll(next, count, visibleRows);
	}

	/** Vertical centre of `index`, in list-local pixels (index is absolute, not screen order). */
	public static function slotCenterY(index:Int, rowHeight:Int, rowGap:Int):Float {
		return index * (rowHeight + rowGap) + rowHeight / 2;
	}

	/** Top of the row that carries `index`, in list-local pixels. */
	public static function slotTopY(index:Int, rowHeight:Int, rowGap:Int):Float {
		return index * (rowHeight + rowGap);
	}

	/** Screen y of a row drawn at screen-order `slot` while the list is scrolled by `scrollPx`. */
	public static function rowScreenY(listTop:Float, slot:Int, rowHeight:Int, rowGap:Int, scrollPx:Float):Float {
		return listTop + slot * (rowHeight + rowGap) - scrollPx;
	}

	/** The row under the pointer, or -1 (outside the list box, or past the loaded rows). */
	public static function rowAtY(pointerY:Float, listTop:Float, rowHeight:Int, rowGap:Int, scrollPx:Float, loadedRows:Int, count:Int):Int {
		if (loadedRows <= 0)
			return -1;
		var rel = pointerY - listTop + scrollPx;
		if (rel < 0)
			return -1;
		var step = rowHeight + rowGap;
		if (step <= 0)
			return -1;
		var slot = Math.floor(rel / step);
		if (slot < 0 || slot >= loadedRows)
			return -1;
		// Inside the row proper, not the gap under it.
		if (rel - slot * step > rowHeight)
			return -1;
		var index = slot;
		if (index < 0 || index >= count)
			return -1;
		return index;
	}
	
	/** Screen x of the left edge of a horizontally centred `width`-wide block. */
	public static function centeredX(screenWidth:Float, width:Float):Float {
		return (screenWidth - width) / 2;
	}

	/**
	 * Vertical geometry of a block of `count` rows that must live inside [top, bottom].
	 *
	 * `measuredHeight` is the row height at whatever font the caller chose (only known after
	 * setFormat); `gap` is the space between rows. When even that does not fit, the rows are
	 * compressed into the block instead of spilling out of it -- which is what the online menu used
	 * to do once it grew past six entries.
	 */
	public static function fitListRows(count:Int, top:Float, bottom:Float, measuredHeight:Float, gap:Float):ListFit {
		var available = bottom - top;
		if (available < 1)
			available = 1;

		var lineHeight = measuredHeight + gap;
		if (lineHeight <= 0)
			lineHeight = 1;

		var compressed = false;
		if (count > 0 && lineHeight * count > available) {
			lineHeight = available / count;
			compressed = true;
		}

		var listHeight = count > 0 ? lineHeight * count : 0;
		var firstY = listHeight < available && count > 0 ? top + (available - listHeight) / 2 : top;
		return { lineHeight: lineHeight, firstY: firstY, compressed: compressed };
	}

	/** True when `index` of `count` rows is inside the window scroll..scroll+visibleRows-1. */
	public static function isVisible(scroll:Int, index:Int, count:Int, visibleRows:Int):Bool {
		var max = count - visibleRows;
		if (max < 0)
			max = 0;
		if (scroll < 0)
			scroll = 0;
		if (scroll > max)
			scroll = max;
		return index >= scroll && index < scroll + visibleRows && index < count;
	}
}

typedef ListFit = {
	var lineHeight:Float;
	var firstY:Float;
	var compressed:Bool;
}