package backend.ui;

import flixel.math.FlxMath;
import flixel.math.FlxPoint;

typedef UIStyleData = {
	var bgColor:FlxColor;
	var textColor:FlxColor;
	var bgAlpha:Float;
}

/**
 * A draggable, collapsible panel with a tab row - the container every editor page lives in.
 *
 * Design rules that keep this thing from breaking (each one used to be a bug):
 *  - The page group ('PsychUITab.menu') is not a child of the box: the box updates and draws
 *    ONLY the selected page, and only while the box is expanded. A hidden page can therefore
 *    never read the mouse, never take focus and never swallow a click.
 *  - Interaction is decided from an explicit rect (box / tab), never from a sprite that happens
 *    to be hidden, so a collapsed panel cannot "click through" itself.
 *  - Nothing is animated with a tween: the collapse is one smoothed factor per frame, so a box
 *    that is destroyed or hidden mid-way can never leave a running tween behind.
 *  - Every accessor is null safe; 'tabs' may be empty.
 */
class PsychUIBox extends FlxSpriteGroup
{
	public static final CLICK_EVENT = "uibox_click";
	public static final MINIMIZE_EVENT = "uibox_minimize";
	public static final DRAG_EVENT = "uibox_drag";
	public static final DROP_EVENT = "uibox_drop";

	public var tabs(default, null):Array<PsychUITab> = [];

	public var selectedTab(default, set):PsychUITab = null;
	public var selectedIndex(default, set):Int = -1;
	public var selectedName(default, set):String = null;

	public var bg:FlxSprite;

	public var selectedStyle:UIStyleData = {
		bgColor: FlxColor.WHITE,
		textColor: FlxColor.BLACK,
		bgAlpha: 1
	};
	public var hoverStyle:UIStyleData = {
		bgColor: FlxColor.WHITE,
		textColor: FlxColor.BLACK,
		bgAlpha: 0.75
	};
	public var unselectedStyle:UIStyleData = {
		bgColor: FlxColor.BLACK,
		textColor: FlxColor.WHITE,
		bgAlpha: 0.6
	};

	/** Corner radius of the panel background. 0 = sharp corners. */
	public var borderRadius(default, set):Int = -1;

	public var canMove:Bool = true;
	public var canMinimize(default, set):Bool = true;
	public var isMinimized(default, set):Bool = false;
	public var minimizeOnFocusLost:Bool = false;

	/** If true the collapse / expand is animated (see minimizeAnimDuration). */
	public var smoothMinimize:Bool = true;
	public var minimizeAnimDuration:Float = 0.16;

	public var tabHeight:Int = 20;

	public var forceCheckNext:Bool = false;
	public var broadcastBoxEvents:Bool = true;

	// == geometry ===============================================================
	/** Height of the expanded panel (the value the caller asked for). */
	var _expandedH:Int = 0;
	/** Width of the panel. */
	var _boxW:Int = 0;

	// == collapse ===============================================================
	/** 0 = expanded, 1 = collapsed into the tab row. */
	var _collapse:Float = 0;

	// == tab hover ==============================================================
	var _tabHover:Array<Float> = [];
	var _tabApplied:Array<Float> = [];
	var _appliedSel:PsychUITab = null;

	// == drag / click ===========================================================
	var _dragAnchorX:Float = 0;
	var _dragAnchorY:Float = 0;
	var _dragMouseX:Float = 0;
	var _dragMouseY:Float = 0;
	var _pressed:Bool = false;
	var _dragging:Bool = false;
	var _lastTab:PsychUITab;
	var _lastClick:Float = 10;
	/** Seconds during which a click cannot trigger minimizeOnFocusLost. */
	var _suppressFocusLost:Float = 0;

	/** Last tab that had a page, restored when the box expands again. */
	var _lastSelected:PsychUITab;
	/** True when the current click is the one that expanded the panel. */
	var _justExpanded:Bool = false;

	// == page reveal ===========================================================
	/** Page whose controls were last faded in (a new page starts the fade again). */
	var _revealTab:PsychUITab = null;
	/** Controls of the page being faded in, in the order they were added. */
	var _revealMembers:Array<FlxSprite> = [];
	var _revealTime:Float = 0;
	var _revealActive:Bool = false;
	/** A page is waiting for the panel to finish unfolding before it fades in. */
	var _revealPending:Bool = false;
	static inline var REVEAL_DURATION:Float = 0.14;

	public function new(x:Float, y:Float, width:Int, height:Int, tabs:Array<String> = null)
	{
		super(x, y);

		bg = new FlxSprite();
		add(bg);

		if (tabs != null)
		{
			for (name in tabs)
			{
				if (name == null) continue;
				var created:PsychUITab = new PsychUITab(name);
				this.tabs.push(created);
				add(created);
			}
		}

		resize(width, height);
		if (this.tabs.length > 0) selectedIndex = 0;
		forceCheckNext = true;
	}

	// ===========================================================================
	// Update
	// ===========================================================================

	override function update(elapsed:Float)
	{
		// A hidden / inactive panel must not update: its controls would keep reading the mouse.
		if (!exists || !visible || !active || tabs == null) return;

		_lastClick += elapsed;
		if (_suppressFocusLost > 0) _suppressFocusLost -= elapsed;

		_tickCollapse(elapsed);
		_tickDrag();
		_tickTabs(elapsed);
		_tickReveal(elapsed);

		if (selectedTab != null && !isMinimized) selectedTab.updateMenu(this, elapsed);

		_tickFocusLost();
	}

	override function draw()
	{
		if (!exists || !visible) return;

		super.draw();

		if (selectedTab != null && !isMinimized && _collapse < 0.5)
			selectedTab.drawMenu(this);
	}

	// ===========================================================================
	// Tabs
	// ===========================================================================

	function _tickTabs(elapsed:Float)
	{
		var inputFrame:Bool = forceCheckNext || FlxG.mouse.justMoved || FlxG.mouse.justPressed || FlxG.mouse.justReleased;
		if (forceCheckNext) forceCheckNext = false;

		var justPressed:Bool = FlxG.mouse.justPressed;
		var justReleased:Bool = FlxG.mouse.justReleased;
		var switched:Bool = false;

		for (i in 0...tabs.length)
		{
			var tab:PsychUITab = tabs[i];
			if (tab == null || !tab.exists) continue;

			tab.scrollFactor.set(scrollFactor.x, scrollFactor.y);
			if (tab.text != null) tab.text.scrollFactor.set(scrollFactor.x, scrollFactor.y);

			var over:Bool = PsychUIEventHandler.overlaps(tab, camera);

			while (_tabHover.length <= i) _tabHover.push(0);
			_tabHover[i] = PsychUIHelper.approach(_tabHover[i], (over && selectedTab != tab) ? 1 : 0, elapsed, 16);

			while (_tabApplied.length <= i) _tabApplied.push(-999);
			var blend:Float = (selectedTab == tab) ? 0 : _tabHover[i];
			if (_tabApplied[i] != blend || _appliedSel != selectedTab)
			{
				_tabApplied[i] = blend;
				// Unselected tabs only brighten a little on hover: 0.6.3 never flipped the whole
				// header to white, it just made the black bar a bit lighter.
				var style:UIStyleData = (selectedTab == tab) ? selectedStyle : {
					bgColor: unselectedStyle.bgColor,
					textColor: unselectedStyle.textColor,
					bgAlpha: unselectedStyle.bgAlpha + 0.28 * FlxMath.bound(blend, 0, 1)
				};
				PsychUIHelper.applyStyle(tab, tab.text, style);
			}

			if (!inputFrame) continue;

			if (justPressed && over)
			{
				_pressed = true;
				_suppressFocusLost = 0.15;
				if (isMinimized)
				{
					// Expanding must not also count as "clicked the active tab" for the collapse
					// test below - that made the toolbox fold itself again on the same click.
					_justExpanded = true;
					isMinimized = false;
				}

				if (selectedTab != tab)
				{
					switched = true;
					_lastTab = selectedTab;
					selectedTab = tab;
				}
				else
					_lastTab = tab;

				_lastClick = 0;
				if (broadcastBoxEvents) PsychUIEventHandler.event(CLICK_EVENT, this);
			}

			if (!_dragging && canMove && _pressed && FlxG.mouse.pressed
				&& (Math.abs(FlxG.mouse.deltaScreenX) > 1 || Math.abs(FlxG.mouse.deltaScreenY) > 1))
			{
				var mouse:FlxPoint = FlxG.mouse.getPositionInCameraView(camera);
				_dragAnchorX = x;
				_dragAnchorY = y;
				_dragMouseX = mouse.x;
				_dragMouseY = mouse.y;
				_dragging = true;
				if (broadcastBoxEvents) PsychUIEventHandler.event(DRAG_EVENT, this);
			}

			// Double click (or a second click) on the active tab collapses / expands the panel.
			if (justReleased && over && canMinimize && !_justExpanded && _lastClick < 0.16 && _lastTab == tab && selectedTab == tab)
			{
				isMinimized = !isMinimized;
				_lastClick = 10;
				_lastTab = null;
				_suppressFocusLost = 0.15;
				if (broadcastBoxEvents) PsychUIEventHandler.event(MINIMIZE_EVENT, this);
			}
		}

		if (justReleased) _justExpanded = false;

		if (switched)
		{
			for (i in 0..._tabApplied.length) _tabApplied[i] = -999;
		}
		else
			_appliedSel = selectedTab;
	}

	// ===========================================================================
	// Drag
	// ===========================================================================

	function _tickDrag()
	{
		if (FlxG.mouse.pressed && _dragging && canMove)
		{
			var point:FlxPoint = FlxG.mouse.getPositionInCameraView(camera);
			var nx:Float = _dragAnchorX - (_dragMouseX - point.x);
			var ny:Float = _dragAnchorY - (_dragMouseY - point.y);
			setPosition(Math.round(nx), Math.round(ny));
			return;
		}

		var wasDragging:Bool = _dragging;
		_dragging = false;

		if (!FlxG.mouse.pressed)
		{
			if (_pressed) forceCheckNext = true;
			_pressed = false;
		}

		if (wasDragging && broadcastBoxEvents) PsychUIEventHandler.event(DROP_EVENT, this);
	}

	// ===========================================================================
	// Collapse
	// ===========================================================================

	function _tickCollapse(elapsed:Float)
	{
		var target:Float = isMinimized ? 1 : 0;

		if (!smoothMinimize || minimizeAnimDuration <= 0)
			_collapse = target;
		else if (Math.abs(_collapse - target) < 0.002)
			_collapse = target;
		else
			_collapse = PsychUIHelper.approach(_collapse, target, elapsed, 3 / minimizeAnimDuration);

		_applyCollapse();
	}

	function _applyCollapse()
	{
		if (bg == null) return;

		var minScale:Float = (_expandedH > 0) ? Math.min(1, tabHeight / Math.max(1, _expandedH)) : 1;
		bg.scale.x = 1;
		bg.scale.y = 1 + (minScale - 1) * FlxMath.bound(_collapse, 0, 1);
	}

	// ===========================================================================
	// Page reveal
	// ===========================================================================

	/**
	 * Fades the controls of a freshly shown page in, one after another (the 0.6.3 tab feel).
	 *
	 * Only 'alpha' is touched, and every member is restored to 1 before the list is dropped, so
	 * a page that is switched away from mid-fade can never leave an invisible control behind.
	 */
	function _tickReveal(elapsed:Float):Void
	{
		if (_revealTab != selectedTab)
		{
			_revealTab = selectedTab;
			_resetReveal();
			_revealPending = (selectedTab != null);
		}

		// Wait until the panel has unfolded enough to actually draw the page.
		if (_revealPending && selectedTab != null && _collapse < 0.55)
		{
			_revealPending = false;
			_beginReveal();
		}

		if (!_revealActive) return;

		if (selectedTab == null)
		{
			_resetReveal();
			return;
		}

		_revealTime += elapsed;
		var ratio:Float = Math.min(_revealTime / REVEAL_DURATION, 1);
		var eased:Float = 1 - Math.pow(1 - ratio, 3);

		var total:Int = _revealMembers.length;
		for (i in 0...total)
		{
			var m:FlxSprite = _revealMembers[i];
			if (m == null || !m.exists) continue;
			// Each item starts a bit later than the previous one: (eased * total - i) / (total - i).
			var local:Float = FlxMath.bound((eased * total - i) / Math.max(1e-4, total - i), 0, 1);
			m.alpha = local;
		}

		if (ratio >= 1) _resetReveal();
	}

	function _beginReveal():Void
	{
		if (selectedTab == null || selectedTab.menu == null) return;

		_revealMembers = [];
		for (m in selectedTab.menu.members)
		{
			if (m == null || !m.exists) continue;
			_revealMembers.push(m);
			m.alpha = 0;
		}
		_revealTime = 0;
		_revealActive = _revealMembers.length > 0;
	}

	function _resetReveal():Void
	{
		if (_revealMembers != null)
		{
			for (m in _revealMembers)
				if (m != null && m.exists) m.alpha = 1;
		}
		_revealMembers = [];
		_revealActive = false;
	}

	/** Height of the panel as it is drawn right now (used by the focus-lost test). */
	function _currentHeight():Float
	{
		var minH:Float = tabHeight;
		return Math.max(minH, _expandedH + (minH - _expandedH) * FlxMath.bound(_collapse, 0, 1));
	}

	// ===========================================================================
	// Focus lost
	// ===========================================================================

	function _tickFocusLost()
	{
		if (!minimizeOnFocusLost || isMinimized || !FlxG.mouse.justPressed) return;
		if (_suppressFocusLost > 0 || _pressed || _dragging) return;

		if (!PsychUIHelper.overlapsRect(this, 0, 0, _boxW, _currentHeight(), camera))
			isMinimized = true;
	}

	// ===========================================================================
	// Public API
	// ===========================================================================

	public function addTab(name:String)
	{
		if (name == null) return;
		var created:PsychUITab = new PsychUITab(name);
		tabs.push(created);
		add(created);
		updateTabs();
		if (selectedTab == null) selectedTab = created;
	}

	public function updateTabs()
	{
		if (tabs == null || tabs.length == 0) return;

		var wid:Int = Std.int(_boxW / tabs.length);
		if (wid < 1) wid = 1;

		for (i in 0...tabs.length)
		{
			var tab:PsychUITab = tabs[i];
			if (tab == null) continue;
			tab.x = x + wid * i;
			tab.y = y;
			tab.resize(wid, tabHeight);
			tab.cameras = cameras;
		}
	}

	public function resize(width:Int, height:Int)
	{
		_boxW = Std.int(Math.max(1, width));
		_expandedH = Std.int(Math.max(tabHeight + 1, height));

		if (bg != null)
		{
			PsychUIHelper.bakeRounded(bg, _boxW, _expandedH, borderRadius);
			bg.color = FlxColor.BLACK;
			bg.alpha = 0.6;
			bg.x = x;
			bg.y = y;
			// Collapse from the top edge, not from the middle of the panel.
			bg.origin.set(_boxW * 0.5, 0);
			_applyCollapse();
		}

		updateTabs();
	}

	public function getTab(name:String):PsychUITab
	{
		if (name == null) return null;
		for (tab in tabs)
			if (tab != null && tab.name == name) return tab;
		return null;
	}

	/** Height the panel had when it was last resized (expanded). */
	public var expandedHeight(get, never):Int;
	inline function get_expandedHeight():Int return _expandedH;

	override function set_x(v:Float):Float
	{
		var dx:Float = v - x;
		var result:Float = super.set_x(v);
		if (dx != 0 && tabs != null)
			for (tab in tabs)
				if (tab != null && tab.menu != null) tab.menu.x += dx;
		return result;
	}

	override function set_y(v:Float):Float
	{
		var dy:Float = v - y;
		var result:Float = super.set_y(v);
		if (dy != 0 && tabs != null)
			for (tab in tabs)
				if (tab != null && tab.menu != null) tab.menu.y += dy;
		return result;
	}

	/**
	 * A box that is hidden or deactivated stops updating, so a page that was mid-reveal has to
	 * be put back to full opacity right now - otherwise those sprites (which may be moved to a
	 * different menu by a layout switch) would stay half transparent forever.
	 */
	override function set_visible(v:Bool):Bool
	{
		if (!v) _resetReveal();
		return super.set_visible(v);
	}

	override function set_active(v:Bool):Bool
	{
		if (!v) _resetReveal();
		return super.set_active(v);
	}

	override function set_cameras(v:Array<FlxCamera>)
	{
		if (tabs != null)
			for (tab in tabs) if (tab != null) tab.cameras = v;
		return super.set_cameras(v);
	}

	override function set_camera(v:FlxCamera)
	{
		if (tabs != null)
			for (tab in tabs) if (tab != null) tab.camera = v;
		return super.set_camera(v);
	}

	override function destroy()
	{
		_resetReveal();
		tabs = null;
		selectedTab = null;
		super.destroy();
	}

	// ===========================================================================
	// Accessors
	// ===========================================================================

	private function set_selectedTab(v:PsychUITab)
	{
		// Leaving a tab has to close an expanded drop-down list: the list is hosted by the state,
		// so nothing would remove it once its page stops being drawn. The same goes for an input
		// that still owns the keyboard: its page is about to stop being updated / drawn.
		if (v != selectedTab)
		{
			PsychUIDropDownMenu.closeAll();
			PsychUIInputText.clearFocus();
		}

		if (v != null)
		{
			@:bypassAccessor selectedName = v.name;
			@:bypassAccessor selectedIndex = tabs.indexOf(v);
			_lastSelected = v;
		}
		else
		{
			@:bypassAccessor selectedName = null;
			@:bypassAccessor selectedIndex = -1;
		}
		return (selectedTab = v);
	}

	private function set_selectedName(v:String)
	{
		if (v == null || v.length < 1)
		{
			selectedTab = null;
			return v;
		}

		for (tab in tabs)
			if (tab != null && tab.name == v)
			{
				selectedTab = tab;
				return v;
			}

		return v;
	}

	private function set_selectedIndex(v:Int)
	{
		if (tabs == null || tabs.length == 0)
		{
			selectedTab = null;
			return (selectedIndex = -1);
		}

		var idx:Int = Std.int(Math.max(Math.min(v, tabs.length - 1), -1));
		if (idx > -1) selectedTab = tabs[idx];
		else selectedTab = null;
		return (selectedIndex = idx);
	}

	function set_canMinimize(v:Bool)
	{
		if (!v) isMinimized = false;
		return (canMinimize = v);
	}

	function set_isMinimized(v:Bool)
	{
		if (isMinimized == v) return v;
		isMinimized = v;

		if (v)
		{
			if (selectedTab != null) _lastSelected = selectedTab;
			_resetReveal();
			PsychUIDropDownMenu.closeAll();
			// A collapsed page must not keep the keyboard / IME captured.
			PsychUIInputText.clearFocus();
			selectedTab = null;
		}
		else
		{
			// NOTE: do not touch bg.visible here. Editors hide the background of a box that is
			// meant to float over the chart (the chart editor's File/Edit/View toolbox), and
			// re-showing it on expand painted a big empty black rectangle behind those buttons.
			if (selectedTab == null && tabs != null && tabs.length > 0)
			{
				var restore:PsychUITab = (_lastSelected != null && tabs.indexOf(_lastSelected) > -1) ? _lastSelected : tabs[0];
				selectedTab = restore;
			}
		}

		// Expand immediately on the next update; the tween-free smoothing catches up in ~0.16s.
		forceCheckNext = true;
		return v;
	}

	function set_borderRadius(v:Int)
	{
		borderRadius = v;
		if (bg != null)
		{
			PsychUIHelper.bakeRounded(bg, _boxW, _expandedH, v);
			bg.color = FlxColor.BLACK;
			bg.alpha = 0.6;
			bg.x = x;
			bg.y = y;
			bg.origin.set(_boxW * 0.5, 0);
		}
		return v;
	}
}