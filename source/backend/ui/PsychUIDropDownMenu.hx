package backend.ui;

import backend.ui.PsychUIBox.UIStyleData;

/**
 * Drop-down menu: a rounded trigger box plus an expanded list of rows.
 *
 * Rewritten around the 1.0.4 ("Psych UI") logic, with the row layout fixed:
 *
 *  - Every row is measured from its own (possibly wrapped) label and the box is built for
 *    that exact height. The previous version sized the box from the height FlxText reported
 *    during construction and stacked the rows from 'FlxSpriteGroup.get_height()', which is
 *    computed from the children's *current* positions - with two-line labels the spacing came
 *    out uneven and the next row's box could cut through the line above it.
 *  - Vertically the label is centred inside the row with real padding, so a descender can
 *    never touch (or leave) the box.
 *  - The rounded box is rebuilt for the row's own size instead of stretching a one-line
 *    bitmap, so the corners stay round on a two-line row.
 *
 * The expanded list is re-parented to the topmost state while it is open, so no other UI can
 * cover it. That is also why a page/menu switch has to close it explicitly: the list is no
 * longer a child of the control that owns it. PsychUIBox calls 'closeAll()' whenever the
 * selected tab changes or the box is minimized, and every open instance also closes itself as
 * soon as it is hidden, removed or destroyed, so a list can never linger on another screen.
 */
class PsychUIDropDownMenu extends FlxSpriteGroup
{
	public static final CLICK_EVENT = "dropdown_click";

	/** Vertical gap between two rows. */
	static inline var ROW_GAP:Float = 2;

	/** Padding above / below a row's label inside its own box. */
	static inline var ROW_PAD_TOP:Float = 3;
	static inline var ROW_PAD_BOTTOM:Float = 5;

	/** Minimum height of a row (a one-line label). */
	static inline var ROW_MIN_H:Float = 22;

	/** Height of the closed trigger box and of its single-line content. */
	static inline var TRIGGER_H:Float = 22;

	/** How far each row slides while the list opens. */
	static inline var REVEAL_SLIDE:Float = 8;

	/** Delay between two rows of the open animation (seconds). */
	static inline var REVEAL_STAGGER:Float = 0.012;

	// == Open instances ==========================================================
	static var _openInstances:Array<PsychUIDropDownMenu> = [];

	/** True while any list is expanded. Callers use it to hold back other wheel input. */
	public static var anyDropdownOpen(get, never):Bool;

	static function get_anyDropdownOpen():Bool
	{
		// Drop entries whose control was torn down without closing (a state switch destroys the
		// whole tree): a stale entry would leave every wheel guard in the editors stuck.
		var i:Int = _openInstances.length;
		while (i-- > 0)
		{
			var menu:PsychUIDropDownMenu = _openInstances[i];
			if (menu == null || !menu.exists || !menu._isOpen) _openInstances.splice(i, 1);
		}
		return _openInstances.length > 0;
	}

	/**
	 * Closes every expanded list.
	 *
	 * Called when the page under a list changes (PsychUIBox tab switch / minimize), because an
	 * open list is hosted by the state rather than by its owner and would otherwise stay on
	 * screen until the player closed it by hand.
	 */
	public static function closeAll():Void
	{
		// close() removes the instance from the list, so walk a copy
		var open:Array<PsychUIDropDownMenu> = _openInstances.copy();
		for (menu in open)
			if (menu != null) menu.close();
		_openInstances = [];
	}

	static function registerOpen(menu:PsychUIDropDownMenu):Void
	{
		if (!_openInstances.contains(menu)) _openInstances.push(menu);
	}

	static function unregisterOpen(menu:PsychUIDropDownMenu):Void
	{
		_openInstances.remove(menu);
	}

	// == Data ====================================================================
	public var list(default, set):Array<String> = [];
	public var selectedIndex(default, set):Int = -1;
	public var selectedLabel(default, set):String = null;
	public var onSelect:Int->String->Void;
	public var broadcastDropDownEvent:Bool = true;

	/** Max rows shown at once (0 = every row). Longer lists scroll with the wheel / by dragging. */
	public var maxItems:Int = 0;

	/** Length of the open animation in seconds (0 = instant). */
	public var animDuration:Float = 0.12;

	/** Corner radius of the trigger and of every row. */
	public var borderRadius:Int = 6;

	// == Styles (unchanged palette) =============================================
	public var normalStyle:UIStyleData = {
		bgColor: 0xFFAAAAAA,
		textColor: FlxColor.BLACK,
		bgAlpha: 1
	};
	public var hoverStyle:UIStyleData = {
		bgColor: FlxColor.WHITE,
		textColor: FlxColor.BLACK,
		bgAlpha: 1
	};

	// == Trigger =================================================================
	var _bg:FlxSprite;
	var _label:FlxText;
	var _arrow:FlxText;
	var _triggerH:Int = Std.int(TRIGGER_H);

	/** The trigger label; kept so callers can restyle it (textObj.font = ...). */
	public var textObj(get, never):FlxText;

	function get_textObj():FlxText
	{
		return _label;
	}

	/** Width of the trigger box. */
	public var fieldWidth:Int = 100;

	// == Expanded list ===========================================================
	var _panel:FlxSpriteGroup;
	/** State/substate the open panel is temporarily attached to (null while closed). */
	var _host:flixel.FlxState = null;
	var _rows:Array<DropRow> = [];
	var _rowPool:Array<DropRow> = [];
	var _isOpen:Bool = false;
	/** Rows the last layout actually placed (the view may fit fewer than `maxItems`). */
	var _visibleCount:Int = 0;

	// == Scroll / press state ====================================================
	var _scroll:Int = 0;
	var _pressRow:Int = -1;
	var _dragAcc:Float = 0;
	var _dragged:Bool = false;
	var _lastMouseY:Float = 0;

	// == Open animation ==========================================================
	var _animTime:Float = 0;
	var _animating:Bool = false;

	public function new(x:Float, y:Float, list:Array<String>, callback:Int->String->Void, ?width:Float = 100)
	{
		super(x, y);
		if (list == null) list = [];
		onSelect = callback;

		fieldWidth = Std.int(Math.max(24, width));

		_bg = PsychUIHelper.createRoundedRectSprite(fieldWidth, Std.int(TRIGGER_H), borderRadius);
		_bg.color = normalStyle.bgColor;
		_bg.alpha = normalStyle.bgAlpha;
		add(_bg);

		_label = new FlxText(4, 3, fieldWidth - 26, '', 9);
		_label.font = 'assets/fonts/editors.ttf';
		_label.color = normalStyle.textColor;
		_label.borderSize = 2;
		add(_label);

		_arrow = new FlxText(fieldWidth - 20, 4, 20, '▼', 10);
		_arrow.font = 'assets/fonts/editors.ttf';
		_arrow.alignment = CENTER;
		_arrow.color = normalStyle.textColor;
		_arrow.borderSize = 2;
		add(_arrow);

		_panel = new FlxSpriteGroup();
		_panel.visible = false;
		add(_panel);

		// Bypass the setters: at this point neither the rows nor the label exist yet.
		@:bypassAccessor this.list = list.copy();
		if (list.length > 0) selectedIndex = 0;
	}

	// ===========================================================================
	//  Open / close
	// ===========================================================================

	public function open():Void
	{
		if (_isOpen || list.length == 0) return;

		_isOpen = true;
		_scroll = 0;
		resetPress();

		layoutRows();
		_panel.visible = true;
		panelToFront();
		registerOpen(this);

		_animTime = 0;
		_animating = animDuration > 0;
		if (_animating)
		{
			for (row in _rows)
			{
				positionRow(row, REVEAL_SLIDE);
				row.alpha = 0;
			}
		}
	}

	public function close():Void
	{
		if (!_isOpen) return;

		_isOpen = false;
		_animating = false;
		_panel.visible = false;

		for (row in _rows)
		{
			row.visible = false;
			row.active = false;
			row.pressed = false;
			positionRow(row, 0);
			row.alpha = 1;
		}

		resetPress();
		panelHome();
		unregisterOpen(this);
	}

	public function toggle():Void
	{
		if (_isOpen) close() else open();
	}

	// ===========================================================================
	//  Z-order: host the open panel on the topmost state while it is expanded
	// ===========================================================================

	function topState():flixel.FlxState
	{
		var state:flixel.FlxState = FlxG.state;
		while (state != null && state.subState != null)
			state = state.subState;
		return state;
	}

	function panelToFront():Void
	{
		if (_host != null) return;

		var host:flixel.FlxState = topState();
		if (host == null) return;

		// Keep the panel where it is: re-parenting must not move it, and the host may have a
		// different camera scroll / zoom than the control that owns this menu.
		final worldX:Float = _panel.x;
		final worldY:Float = _panel.y;
		final sfX:Float = _panel.scrollFactor.x;
		final sfY:Float = _panel.scrollFactor.y;

		remove(_panel);
		_host = host;
		_host.add(_panel);
		_panel.setPosition(worldX, worldY);
		_panel.scrollFactor.set(sfX, sfY);
		_panel.cameras = cameras;
	}

	function panelHome():Void
	{
		if (_host == null) return;

		try
		{
			_host.remove(_panel);
		}
		catch (e:Dynamic)
		{
			// The host went away while the list was open; the panel dies with it.
		}

		_host = null;
		// add() re-applies this control's position offset, so start from (0, 0).
		_panel.setPosition(0, 0);
		add(_panel);
	}

	// ===========================================================================
	//  Row layout
	// ===========================================================================

	/** Rows shown at once: maxItems when set, otherwise the whole list. */
	function rowLimit():Int
	{
		if (maxItems > 0) return Std.int(Math.max(1, Math.min(maxItems, list.length)));
		return list.length;
	}

	/**
	 * Rows the list may scroll through: `maxItems`, further capped by the rows the view can
	 * actually show, so nothing becomes unreachable and no scroll position shows fewer rows
	 * than the caller asked for.
	 */
	function scrollWindow():Int
	{
		var limit:Int = rowLimit();
		if (_isOpen && _visibleCount > 0) limit = Std.int(Math.min(limit, _visibleCount));
		return limit;
	}

	/** Rebuilds the visible rows from the current list / scroll / selection. */
	function layoutRows():Void
	{
		for (row in _rows)
			releaseRow(row);
		_rows = [];

		var limit:Int = rowLimit();
		var avail:Float = spaceBelow() - ROW_GAP;
		var y:Float = _triggerH + ROW_GAP;
		var shown:Int = 0;
		_visibleCount = 0;

		for (i in 0...list.length)
		{
			if (shown >= limit) break;
			if (i < _scroll) continue;

			var row:DropRow = obtainRow();
			row.prepare(list[i], fieldWidth, borderRadius);

			// Never grow past the bottom of the view: a two-line label makes the list taller, and a
			// list that hangs off the screen edge is exactly the "cut" this menu used to show. One
			// row is always kept, and the wheel pages through the rows that did not fit.
			if (shown > 0 && (y - _triggerH - ROW_GAP) + row.rowHeight > avail)
			{
				releaseRow(row);
				break;
			}

			row.ID = i;
			row.isSelected = (i == selectedIndex);
			row.localY = y;
			row.setPosition(0, y);
			row.visible = true;
			row.active = true;
			row.alpha = 1;
			_panel.add(row);
			_rows.push(row);

			y += row.rowHeight + ROW_GAP;
			shown++;
		}

		_visibleCount = shown;
	}

	/**
	 * Room left under this control inside its camera view, so the expanded list can be kept on
	 * screen (a list that runs off the bottom edge looks cut in half).
	 */
	function spaceBelow():Float
	{
		var cam:FlxCamera = (camera != null) ? camera : FlxG.camera;
		if (cam == null || _bg == null) return 100000;

		var pos:FlxPoint = _bg.getScreenPosition(null, cam);
		return cam.height - (pos.y + _triggerH);
	}

	function obtainRow():DropRow
	{
		var row:DropRow = (_rowPool.length > 0) ? _rowPool.pop() : new DropRow(borderRadius);
		return row;
	}

	function releaseRow(row:DropRow):Void
	{
		if (row == null) return;
		row.visible = false;
		row.active = false;
		row.pressed = false;
		row.alpha = 1;
		_panel.remove(row);
		_rowPool.push(row);
	}

	/**
	 * Places a row at its layout position (plus an animation offset).
	 *
	 * Once a row belongs to the panel its own position is in *state* space - the panel bakes its
	 * offset into its children - so the target is rebuilt from the panel's position plus the
	 * row's panel-relative Y. Both coordinates matter: resetting X to 0 (which is what the first
	 * version did) put every row at the left edge of the window instead of under the trigger.
	 */
	function positionRow(row:DropRow, offset:Float):Void
	{
		row.setPosition(_panel.x, _panel.y + row.localY + offset);
	}

	/** Index (into _rows) of the row under the pointer, or -1. */
	function rowIndexAtMouse():Int
	{
		var i:Int = 0;
		for (row in _rows)
		{
			if (row.visible && PsychUIEventHandler.overlaps(row.bg, camera)) return i;
			i++;
		}
		return -1;
	}

	/**
	 * Scrolls the visible window. 'delta' is in rows (positive = further down the list).
	 * Re-lays the rows out, and restarts the open animation so a scrolled list fades in again
	 * instead of showing half-faded rows.
	 */
	function scrollBy(delta:Int):Void
	{
		var limit:Int = scrollWindow();
		if (list.length <= limit) return;

		var newScroll:Int = Std.int(FlxMath.bound(_scroll + delta, 0, list.length - limit));
		if (newScroll == _scroll) return;

		_scroll = newScroll;
		layoutRows();

		if (_animating)
		{
			_animTime = 0;
			for (row in _rows)
			{
				positionRow(row, REVEAL_SLIDE);
				row.alpha = 0;
			}
		}
	}

	// ===========================================================================
	//  Trigger
	// ===========================================================================

	/** Grows the closed box when the selected label wraps onto a second line. */
	function updateTriggerSize():Void
	{
		_label.fieldWidth = fieldWidth - 26;

		var h:Int = Std.int(Math.max(TRIGGER_H, Math.ceil(_label.height) + 6));
		if (h != _triggerH)
		{
			_triggerH = h;
			PsychUIHelper.makeRoundedRect(_bg, fieldWidth, h, borderRadius);
			_bg.updateHitbox();
		}

		// Both the box and the arrow are baked into state space, so the box's own position has to
		// be part of the calculation - using a plain local offset put the arrow at the top of the
		// window whenever the menu was not at (0, 0).
		_arrow.y = _bg.y + (_triggerH - _arrow.height) / 2;
	}

	// ===========================================================================
	//  Selection
	// ===========================================================================

	function set_list(v:Array<String>):Array<String>
	{
		var keepLabel:String = selectedLabel;
		var keepIndex:Int = selectedIndex;

		list = (v != null) ? v : [];

		// Keep the selection when possible; otherwise fall back to the old index / the first row.
		if (keepLabel != null && list.indexOf(keepLabel) >= 0) selectedLabel = keepLabel;
		else if (keepIndex >= 0 && keepIndex < list.length) selectedIndex = keepIndex;
		else selectedIndex = (list.length > 0) ? 0 : -1;

		if (_isOpen)
		{
			_scroll = 0;
			layoutRows();
		}
		return list;
	}

	function set_selectedIndex(v:Int):Int
	{
		selectedIndex = (v >= 0 && v < list.length) ? v : -1;
		@:bypassAccessor selectedLabel = (selectedIndex >= 0) ? list[selectedIndex] : null;
		_label.text = (selectedLabel != null) ? selectedLabel : '';
		updateTriggerSize();

		for (row in _rows)
			row.isSelected = (row.ID == selectedIndex);
		return selectedIndex;
	}

	function set_selectedLabel(v:String):String
	{
		var id:Int = (v != null) ? list.indexOf(v) : -1;
		// An unknown label clears the trigger, exactly like the 1.0.4 behaviour.
		selectedIndex = (id >= 0) ? id : -1;
		return v;
	}

	function selectRow(id:Int):Void
	{
		if (id < 0 || id >= list.length) return;

		var label:String = list[id];
		close();
		selectedIndex = id;

		if (onSelect != null) onSelect(id, label);
		if (broadcastDropDownEvent) PsychUIEventHandler.event(CLICK_EVENT, this);
	}

	// ===========================================================================
	//  Update
	// ===========================================================================

	override function update(elapsed:Float):Void
	{
		super.update(elapsed);

		if (_isOpen)
		{
			// The panel is hosted by the state while open, so hiding / removing this control has
			// to close the list by hand - otherwise it stays on screen on its own.
			if (!exists || !visible || (_host != null && topState() != _host))
			{
				close();
				return;
			}

			// Stay glued to the trigger while the panel lives on the state.
			_panel.setPosition(x, y);
			_panel.scrollFactor.copyFrom(scrollFactor);
		}

		var over:Bool = PsychUIEventHandler.overlaps(_bg, camera);
		_bg.color = over ? hoverStyle.bgColor : normalStyle.bgColor;
		_bg.alpha = over ? hoverStyle.bgAlpha : normalStyle.bgAlpha;
		_label.color = over ? hoverStyle.textColor : normalStyle.textColor;
		_arrow.color = _label.color;

		if (_animating) tickReveal(elapsed);

		if (_isOpen)
		{
			// Open list: the wheel belongs to the list (callers guard their own wheel input
			// with anyDropdownOpen), and a click either picks a row, toggles, or closes.
			if (FlxG.mouse.wheel != 0)
			{
				scrollBy(-Std.int(FlxG.mouse.wheel));
				return;
			}

			updateRowStyles();
			handleOpenInput(elapsed);
			return;
		}

		if (FlxG.mouse.justPressed && over) toggle();
	}

	function updateRowStyles():Void
	{
		for (row in _rows)
		{
			var over:Bool = PsychUIEventHandler.overlaps(row.bg, camera);
			row.applyStyle(over, row.pressed);
		}
	}

	function handleOpenInput(elapsed:Float):Void
	{
		if (FlxG.mouse.justPressed)
		{
			if (PsychUIEventHandler.overlaps(_bg, camera))
			{
				toggle();
				return;
			}

			_pressRow = rowIndexAtMouse();
			if (_pressRow >= 0)
			{
				_dragAcc = 0;
				_dragged = false;
				_lastMouseY = FlxG.mouse.getWorldPosition(camera).y;
				_rows[_pressRow].pressed = true;
			}
			else
			{
				close();
				return;
			}
		}

		if (_pressRow < 0 || _pressRow >= _rows.length) return;

		if (FlxG.mouse.pressed)
		{
			var curY:Float = FlxG.mouse.getWorldPosition(camera).y;
			_dragAcc += curY - _lastMouseY;
			_lastMouseY = curY;

			if (Math.abs(_dragAcc) > 2) _dragged = true;

			// Drag-scrolls a list that does not fit (maxItems), and follows the row under the
			// pointer so a press can be dragged onto the row the player wants.
			var limit:Int = scrollWindow();
			if (list.length > limit && Math.abs(_dragAcc) >= 16)
			{
				var step:Int = Std.int(_dragAcc / 16);
				_dragAcc -= step * 16;
				scrollBy(-step);
			}

			var hovered:Int = rowIndexAtMouse();
			for (i in 0..._rows.length)
				_rows[i].pressed = (i == hovered);
			if (hovered >= 0) _pressRow = hovered;
		}

		if (FlxG.mouse.justReleased)
		{
			var row:DropRow = _rows[_pressRow];
			var dragged:Bool = _dragged;
			resetPress();

			if (row != null)
			{
				row.pressed = false;
				if (!dragged) selectRow(row.ID);
			}
		}
	}

	function resetPress():Void
	{
		for (row in _rows)
			row.pressed = false;
		_pressRow = -1;
		_dragAcc = 0;
		_dragged = false;
	}

	// ===========================================================================
	//  Reveal animation
	// ===========================================================================

	/**
	 * Rows fade in and slide up into place, one after the other.
	 *
	 * Only the rows' own position and alpha are animated: the scale of a FlxSpriteGroup is not
	 * applied to its children when they are drawn, so the previous "scale-y reveal" never
	 * actually showed up on screen.
	 */
	function tickReveal(elapsed:Float):Void
	{
		_animTime += elapsed;

		var total:Float = animDuration + REVEAL_STAGGER * Math.max(0, _rows.length - 1);
		var done:Bool = _animTime >= total;

		for (i => row in _rows)
		{
			var t:Float = FlxMath.bound((_animTime - i * REVEAL_STAGGER) / animDuration, 0, 1);
			var eased:Float = 1 - Math.pow(1 - t, 3);
			positionRow(row, REVEAL_SLIDE * (1 - eased));
			row.alpha = eased;
		}

		if (done)
		{
			_animating = false;
			for (row in _rows)
			{
				positionRow(row, 0);
				row.alpha = 1;
			}
		}
	}

	// ===========================================================================
	//  Cleanup
	// ===========================================================================

	override function destroy():Void
	{
		unregisterOpen(this);
		_isOpen = false;
		_animating = false;

		// If the panel is hosted by a state it belongs to that state now; just make sure an open
		// list cannot stay visible after its owner is gone.
		if (_panel != null) _panel.visible = false;
		_host = null;

		if (_rows != null)
		{
			for (row in _rows)
				if (_panel != null) _panel.remove(row);
			_rows = [];
		}

		if (_rowPool != null)
		{
			for (row in _rowPool)
				row.kill();
			_rowPool = [];
		}

		super.destroy();
	}
}

// == One row of the expanded list ===============================================
private class DropRow extends FlxSpriteGroup
{
	public var hoverStyle:UIStyleData = {
		bgColor: 0xFF0066FF,
		textColor: FlxColor.WHITE,
		bgAlpha: 1
	};
	public var normalStyle:UIStyleData = {
		bgColor: FlxColor.WHITE,
		textColor: FlxColor.BLACK,
		bgAlpha: 1
	};
	public var selectedStyle:UIStyleData = {
		bgColor: 0xFF003399,
		textColor: FlxColor.WHITE,
		bgAlpha: 1
	};
	public var pressedStyle:UIStyleData = {
		bgColor: 0xFF0044CC,
		textColor: FlxColor.WHITE,
		bgAlpha: 1
	};

	public var bg:FlxSprite;
	public var text:FlxText;

	/** Label shown in this row. */
	public var label:String = '';

	/** Height of this row, measured from the wrapped label in prepare(). */
	public var rowHeight:Float = 22;

	/** Panel-relative Y this row is laid out at (the reveal animation slides towards it). */
	public var localY:Float = 0;

	public var pressed:Bool = false;
	public var isSelected(default, set):Bool = false;

	var _radius:Int;
	var _bakedW:Int = -1;
	var _bakedH:Int = -1;

	public function new(?radius:Int = 6)
	{
		super(0, 0);
		_radius = radius;

		bg = PsychUIHelper.createRoundedRectSprite(1, 22, radius);
		add(bg);

		text = new FlxText(4, 0, 1, '', 9);
		text.font = 'assets/fonts/editors.ttf';
		text.color = FlxColor.BLACK;
		text.borderSize = 2;
		add(text);
	}

	/**
	 * Sizes this row around 'label': the text is measured *after* it was wrapped, and the box,
	 * the row height and the label's vertical centring are all derived from that one measurement.
	 */
	public function prepare(label:String, width:Int, radius:Int):Void
	{
		_radius = radius;
		this.label = label;

		// fieldWidth first, then the text: wrapping has to be in place before measuring.
		text.fieldWidth = width - 8;
		text.text = label;

		var textH:Float = Math.ceil(text.height);
		rowHeight = Math.max(22, textH + 3 + 5);

		bakeBg(width, Std.int(rowHeight));

		// Position the label against the box's *current* position: a FlxSpriteGroup bakes the
		// group offset into its children, so both move together when the row is laid out.
		text.x = bg.x + 4;
		text.y = bg.y + rowHeight / 2 - textH / 2;
		pressed = false;
		isSelected = false;
	}

	/** Rebuilds the rounded box for this row's own size (no stretched corners). */
	function bakeBg(width:Int, height:Int):Void
	{
		if (_bakedW == width && _bakedH == height) return;

		PsychUIHelper.makeRoundedRect(bg, width, height, _radius);
		bg.updateHitbox();
		_bakedW = width;
		_bakedH = height;
	}

	public function applyStyle(over:Bool, pressed:Bool):Void
	{
		var style:UIStyleData;
		if (isSelected && !over) style = selectedStyle;
		else if (pressed) style = pressedStyle;
		else if (over) style = hoverStyle;
		else style = normalStyle;

		bg.color = style.bgColor;
		bg.alpha = style.bgAlpha;
		text.color = style.textColor;
	}

	function set_isSelected(v:Bool):Bool
	{
		return isSelected = v;
	}
}
