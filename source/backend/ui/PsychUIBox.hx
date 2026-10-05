package backend.ui;

import flixel.tweens.FlxTween;
import flixel.tweens.FlxEase;
import flixel.math.FlxMath;

typedef UIStyleData = {
	var bgColor:FlxColor;
	var textColor:FlxColor;
	var bgAlpha:Float;
}

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
		bgAlpha: 0.6
	};
	public var unselectedStyle:UIStyleData = {
		bgColor: FlxColor.BLACK,
		textColor: FlxColor.WHITE,
		bgAlpha: 0.6
	};

	/** Corner radius for the panel background. Set to 0 for sharp corners. */
	public var borderRadius(default, set):Int = -1;

	public var canMove:Bool = true;
	public var canMinimize(default, set):Bool = true;
	public var isMinimized(default, set):Bool = false;
	public var minimizeOnFocusLost:Bool = false;

	/** If true, minimize/restore uses smooth height tween. */
	public var smoothMinimize(default, set):Bool = true;
	public var minimizeAnimDuration:Float = 0.25;

	public function new(x:Float, y:Float, width:Int, height:Int, tabs:Array<String> = null)
	{
		super(x, y);
		
		bg = PsychUIHelper.createRoundedRectSprite(width, height, borderRadius);
		bg.color = FlxColor.BLACK;
		bg.alpha = 0.6;
		add(bg);

		if(tabs != null)
		{
			for (tab in tabs)
			{
				var createdTab:PsychUITab = new PsychUITab(tab);
				this.tabs.push(createdTab);
				add(createdTab);
			}
		}

		resize(width, height);
		selectedIndex = 0;
		forceCheckNext = true;
	}

	// ── Reveal animation ──
	/** Duration (seconds) of the tab menu reveal animation. 0 = instant. */
	public var animDuration:Float = 0.15;

	var _animTimer:Float = 0;
	var _animating:Bool = false;
	var _animMembers:Array<FlxSprite> = []; // snapshot of menu children being animated

	var _draggingPos:FlxPoint;
	var _draggingPoint:FlxPoint;
	var _pressedBox:Bool = false;
	var _draggingBox:Bool = false;
	var _lastTab:PsychUITab;
	var _lastClick:Float = 0;

	/** Tracks the previously-active tab to detect switches. */
	var _prevSelectedTab:PsychUITab = null;

	/** Set true after the first update() call so the initial programmatic
	 *  selection (set during create()) doesn't trigger a reveal animation. */
	var _initialized:Bool = false;

	public var forceCheckNext:Bool = false;
	public var broadcastBoxEvents:Bool = true;
	override function update(elapsed:Float)
	{
		super.update(elapsed);

		_lastClick += elapsed;
		if(!!FlxG.mouse.pressed && _draggingBox && canMove)
		{
			var newPoint:FlxPoint = FlxG.mouse.getPositionInCameraView(camera);
			setPosition(_draggingPos.x - (_draggingPoint.x - newPoint.x), _draggingPos.y - (_draggingPoint.y - newPoint.y));
		}
		else
		{
			var wasDragging:Bool = _draggingBox;
			_draggingPos = null;
			_draggingPoint = null;
			_draggingBox = false;
			if(!FlxG.mouse.pressed)
			{
				if(_pressedBox) forceCheckNext = true;
				_pressedBox = false;
			}
			if(wasDragging && broadcastBoxEvents) PsychUIEventHandler.event(DROP_EVENT, this);
		}

		for (tab in tabs)
		{
			tab.scrollFactor.set(scrollFactor.x, scrollFactor.y);
			tab.text.scrollFactor.set(scrollFactor.x, scrollFactor.y);
		}

		var _ignoreTabUpdate:Bool = false;
		if(forceCheckNext || FlxG.mouse.justMoved || FlxG.mouse.justPressed || FlxG.mouse.justReleased)
		{
			forceCheckNext = false;
			for (tab in tabs)
			{
				var hoverOverTab:Bool = PsychUIEventHandler.overlaps(tab, camera);

				if(FlxG.mouse.justPressed)
				{
					if(hoverOverTab)
					{
						_pressedBox = true;
						if(selectedTab != tab)
						{
							isMinimized = false;
							_ignoreTabUpdate = true;
						}
						_lastTab = selectedTab;
						selectedTab = tab;
						_lastClick = 0;
						if(broadcastBoxEvents) PsychUIEventHandler.event(CLICK_EVENT, this);
					}
					else if(selectedTab == null || selectedTab != tab)
					{
						// clicking outside a tab while one is selected – maybe focus-lost minimise
					}
				}

				if(!_draggingBox && canMove && _pressedBox && FlxG.mouse.pressed && (Math.abs(FlxG.mouse.deltaScreenX) > 1 || Math.abs(FlxG.mouse.deltaScreenY) > 1))
				{
					_draggingPos = FlxPoint.weak(x, y);
					_draggingPoint = FlxG.mouse.getPositionInCameraView(camera);
					_draggingBox = true;
					if(broadcastBoxEvents) PsychUIEventHandler.event(DRAG_EVENT, this);
				}
				
				// Double-click minimises
				if(hoverOverTab && FlxG.mouse.justReleased && canMinimize && _lastClick < 0.15 && selectedTab == tab && _lastTab == selectedTab)
				{
					_ignoreTabUpdate = true;
					isMinimized = !isMinimized;
					_lastClick = 0;
				}

				// Apply style – instant, no tween (avoids flicker / background overflow)
				var style:UIStyleData = (selectedTab == tab) ? selectedStyle : unselectedStyle;
				tab.color = style.bgColor;
				tab.alpha = style.bgAlpha;
				tab.text.color = style.textColor;
			}
		}

		// ── Skip animation on the very first frame (initial tab from create()) ──
		if (!_initialized)
		{
			_initialized = true;
			_prevSelectedTab = selectedTab;
		}

		// ── Detect tab switch → start reveal animation ──
		if (_prevSelectedTab != selectedTab && selectedTab != null && !isMinimized && animDuration > 0)
		{
			// Reset any items left over from a previous interrupted animation
			for (m in _animMembers)
				if (m != null) m.alpha = 1;

			_animTimer = 0;
			_animating = true;
			_animMembers = [];
			for (m in selectedTab.menu.members)
			{
				if (m != null)
				{
					_animMembers.push(m);
					m.alpha = 0;
				}
			}
		}
		_prevSelectedTab = selectedTab;

		// ── Tick reveal animation (alpha-fade only; safe for all control types) ──
		if (_animating && selectedTab != null)
		{
			_animTimer += elapsed;
			if (_animTimer >= animDuration) _animTimer = animDuration;

			var ratio:Float = (_animTimer / animDuration);
			var eased:Float = 1 - Math.pow(1 - ratio, 3); // ease-out cubic
			var total:Int = _animMembers.length;
			for (i => m in _animMembers)
			{
				if (m == null) continue;
				var localRatio:Float = FlxMath.bound((eased * total - i) / (total - i + 0.0001), 0, 1);
				m.alpha = localRatio;
			}

			if (_animTimer >= animDuration)
			{
				// Ensure ALL items are at exactly alpha = 1 before cleaning up
				for (m in _animMembers)
					if (m != null) m.alpha = 1;
				_animating = false;
				_animMembers = [];
			}
		}

		if(_ignoreTabUpdate)
		{
			if(broadcastBoxEvents)
				PsychUIEventHandler.event(MINIMIZE_EVENT, this);
		}
		else if(selectedTab != null && !isMinimized)
			selectedTab.updateMenu(this, elapsed);

		if(minimizeOnFocusLost && FlxG.mouse.justPressed && !isMinimized && !PsychUIEventHandler.overlaps(bg, camera))
		{
			isMinimized = true;
			if(broadcastBoxEvents)
				PsychUIEventHandler.event(MINIMIZE_EVENT, this);
		}
	}

	override function set_cameras(v:Array<FlxCamera>)
	{
		for (tab in tabs) tab.cameras = v;
		return super.set_cameras(v);
	}

	override function set_camera(v:FlxCamera)
	{
		for (tab in tabs) tab.camera = v;
		return super.set_camera(v);
	}
			
	override function draw()
	{
		super.draw();

		if(selectedTab != null && !isMinimized)
			selectedTab.drawMenu(this);
	}

	override function destroy()
	{
		tabs = null;
		selectedTab = null;
		super.destroy();
	}

	public function addTab(name:String)
	{
		var createdTab:PsychUITab = new PsychUITab(name);
		tabs.push(createdTab);
		add(createdTab);
		updateTabs();

		if(selectedTab == null)
			selectedTab = createdTab;
	}

	public var tabHeight:Int = 20;
	public function updateTabs()
	{
		var wid:Int = Std.int(bg.width / tabs.length);
		for (num => tab in tabs)
		{
			tab.x = bg.x + wid * num;
			tab.resize(wid, tabHeight);
			tab.cameras = cameras;
		}
	}

	var _originalHeight:Int = 0;
	public function resize(width:Int, height:Int)
	{
		_originalHeight = height;
		PsychUIHelper.makeRoundedRect(bg, width, height, borderRadius);
		bg.setGraphicSize(width, height);
		bg.updateHitbox();
		updateTabs();
	}

	private function set_selectedTab(v:PsychUITab)
	{
		// An expanded drop-down list is hosted by the state (so nothing can cover it), which
		// means leaving this tab has to close it explicitly: the tab's menu stops being
		// updated/drawn as soon as another tab is selected, and the list would stay on screen.
		if(v != selectedTab) PsychUIDropDownMenu.closeAll();

		if(v != null)
		{
			@:bypassAccessor selectedName = v.name;
			@:bypassAccessor selectedIndex = tabs.indexOf(v);
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
		if(v == null || v.trim().length < 1) selectedTab = null;

		for (tab in tabs)
		{
			if(tab.name == v)
			{
				selectedTab = tab;
				return v;
			}
		}
		return null;
	}

	private function set_selectedIndex(v:Int)
	{
		v = Std.int(Math.max(Math.min(v, tabs.length-1), -1));
		if(v > -1) selectedTab = tabs[v];
		else selectedTab = null;
		return v;
	}

	public function getTab(name:String)
	{
		for (tab in tabs)
			if(tab.name == name)
				return tab;

		return null;
	}

	function set_canMinimize(v:Bool)
	{
		isMinimized = false;
		return (canMinimize = v);
	}

	function set_isMinimized(v:Bool)
	{
		if(!v)
		{
			// Restore – animate height back
			if(smoothMinimize)
			{
				FlxTween.cancelTweensOf(bg.scale, ['y']);
				FlxTween.tween(bg.scale, {y: 1.0}, minimizeAnimDuration, {ease: FlxEase.quartOut});
			}
			else
			{
				bg.setGraphicSize(Std.int(bg.width), _originalHeight);
				bg.updateHitbox();
			}
		}
		else
		{
			// Minimize – animate height down
			// The menu stops being updated while the box is minimized, so close any open list.
			PsychUIDropDownMenu.closeAll();
			selectedTab = null;
			var minimizeH:Int = tabHeight + 20;
			if(bg.frameHeight > 0 && smoothMinimize)
			{
				var targetScaleY:Float = minimizeH / bg.frameHeight;
				FlxTween.cancelTweensOf(bg.scale, ['y']);
				FlxTween.tween(bg.scale, {y: targetScaleY}, minimizeAnimDuration, {ease: FlxEase.quartOut});
			}
			else
			{
				bg.setGraphicSize(Std.int(bg.width), minimizeH);
				bg.updateHitbox();
			}
		}
		return (isMinimized = v);
	}

	function set_smoothMinimize(v:Bool):Bool
	{
		smoothMinimize = v;
		if(!v) FlxTween.cancelTweensOf(bg.scale, ['y']);
		return v;
	}

	function set_borderRadius(v:Int):Int
	{
		borderRadius = v;
		var w:Int = Std.int(bg.width);
		var h:Int = Std.int(bg.height);
		if(w < 1) w = 100;
		if(h < 1) h = 100;
		PsychUIHelper.makeRoundedRect(bg, w, h, (v < 0) ? -1 : v);
		return v;
	}
}