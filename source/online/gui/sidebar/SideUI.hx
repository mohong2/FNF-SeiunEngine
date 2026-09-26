package online.gui.sidebar;
import online.util.OnlineLang;

import InputFormatter; // this engine declares InputFormatter in the root package, not `backend`
import flixel.input.keyboard.FlxKey;
import sys.FileSystem;
import online.gui.sidebar.tabs.*;
import online.gui.sidebar.obj.*;
import online.network.FunkinNetwork;
import flixel.FlxG;
import flixel.util.FlxColor;
import flixel.tweens.FlxTween;
import openfl.Lib;
import openfl.display.Shape;

class SideUI extends WSprite {
	public static var instance:SideUI;

	public var active(default, set):Bool;
	public var cursor:Bitmap;

	public static final DEFAULT_TAB_WIDTH:Int = 400;

	/**
	 * The tabs this engine ships. Chat lives in RoomState (the sidebar shell is not rebuilt for it),
	 * HostServer in server/ + start.ps1, Downloader in DownloaderState, Report is a stub.
	 */
	public var initTabs:Array<Class<TabSprite>> = [
		NotificationsTab,
		ProfileTab,
		FriendsTab
	];

	public var tabUI:Sprite;

	public var upBar:Bitmap;
	public var leftBar:Bitmap;
	public var welcome:TextField;
	public var tip:TextField;
	public var tabTitle:TextField;

	var tabButtons:Array<Bitmap> = [];
	var tabButtonsUnderlay:Array<Bitmap> = [];

	public var tabs:Array<TabSprite> = [];
	public var curTabIndex(default, set):Int;
	function set_curTabIndex(v:Int) {
		if (curTab != null) {
			curTab.onHide();
			tabUI.removeChild(curTab);
			curTab.onRemove();
		}

		curTabIndex = v;

		if (active) {
			tabUI.addChild(curTab);
			curTab.onShow();
		}

		onChangedTab();

		return curTabIndex;
	}
	public var curTab(get, never):TabSprite;
	function get_curTab() {
		return tabs[curTabIndex];
	}

	var _wasMouseShown:Bool = false;

	public function new() {
		super();

		instance = this;

		// No directory walk over assets/images/sidebar: here those icons live
		// in assets/preload/images/sidebar (~7 KB total) and staying packed is what lets
		// GAssets.image() find them in a release build. The walk also crashed on a directory that
		// only exists in a source checkout.

		if (stage != null)
			init();
		else
			addEventListener(Event.ADDED_TO_STAGE, init);
	}

	function init(?e:Event) {
		alpha = 0;

		mouseEnabled = false;
		mouseChildren = false;

		var bg = new Bitmap(new BitmapData(Lib.application.window.width, Lib.application.window.height, true, 0x8E000000));
		addChild(bg);

		tabUI = new Sprite();
		addChild(tabUI);

		leftBar = new Bitmap(new BitmapData(50, Lib.application.window.height, true, FlxColor.fromRGB(30, 30, 30)));
		tabUI.addChild(leftBar);
		
		upBar = new Bitmap(new BitmapData(Lib.application.window.width, 50, true, FlxColor.BLACK));
		addChild(upBar);

		welcome = this.createText(15, 15, 20);
		welcome.setText('...');
		addChild(welcome);

		tip = this.createText(15, 15, 15);
		tip.setText(OnlineLang.L('sidebar.tip.pre', 'Use ') + InputFormatter.getKeyName(cast(ClientPrefs.keyBinds.get('sidebar')[0], FlxKey)) + OnlineLang.L('sidebar.tip.post', ' to toggle the Network Sidebar!'), upBar.width, 0xFF535353);
		tip.x = upBar.width / 2 - tip.width / 2;
		tip.y = welcome.y;
		addChild(tip);

		tabTitle = this.createText(15, 15, 20);
		addChild(tabTitle);

		// assets/images/ui/cursor.png ships in neither repository, so the same small arrow is drawn
		// into a BitmapData. Keeping the pointer on the stage holds it above the sidebar instead of
		// disappearing under it like the system cursor once the game hides that one. Bitmap is not
		// interactive, so it cannot swallow the sidebar's mouse events.
		cursor = new Bitmap(makeCursor());
		cursor.visible = false;
		stage.addChild(cursor);

		for (i => tabClass in initTabs) {
			var daTab = Type.createInstance(tabClass, []);
			daTab.x = leftBar.width;
			daTab.y = upBar.height;
			daTab.widthSpace = Std.int(Lib.application.window.width - daTab.x);
			daTab.heightSpace = Std.int(Lib.application.window.height - daTab.y);
			tabs.push(daTab);
			
			var tabIconUnderlay = new Bitmap(new BitmapData(50, 50, true, FlxColor.fromRGB(100, 100, 100)));
			tabIconUnderlay.y = upBar.height + i * 50;
			tabButtonsUnderlay.push(tabIconUnderlay);
			tabUI.addChild(tabIconUnderlay);

			var tabIcon = new Bitmap(GAssets.image('sidebar/' + daTab.icon));
			tabIcon.smoothing = false;
			tabIcon.width = 50;
			tabIcon.height = 50;
			tabIcon.y = tabIconUnderlay.y;
			tabButtons.push(tabIcon);
			tabUI.addChild(tabIcon);
		}

		tabUI.x = -totalTabWidth();

		onChangedTab();

		stage.addEventListener(KeyboardEvent.KEY_DOWN, (e:KeyboardEvent) -> {
			if (LoadingScreen.loading)
				return;

			if ((e.keyCode.checkKey('sidebar') || (e.keyCode == 27 && active)) && stage.focus == null) {
				active = !active;
				// if (FunkinNetwork.loggedIn) {
				// 	active = !active;
				// 	return;
				// }
				// else {
				// 	Waiter.put(() -> {
				// 		Alert.alert("Forbidden!", "Sidebar is only accessible for\npeople that are logged to the network!");
				// 	});
				// }
			}
			
			if (active) {
				curTab.keyDown(e);

			}
		});
		stage.addEventListener(MouseEvent.MOUSE_MOVE, (e:MouseEvent) -> {
			cursor.x = e.stageX;
			cursor.y = e.stageY;

			if (LoadingScreen.loading)
				return;

			if (active) {
				onChangedTab();
				curTab.mouseMove(e);
			}
		});
		stage.addEventListener(MouseEvent.MOUSE_DOWN, (e:MouseEvent) -> {
			if (LoadingScreen.loading)
				return;

			if (e.localY > upBar.height * scaleY && e.localX > totalTabWidth() * scaleX && !Alert.isAnyFreezed())
				active = false;

			if (active) {
				for (i => button in tabButtons) {
					if (!tabButtonsUnderlay[i].overlapsMouse())
						continue;

					if (tabs[i].locked) {
						Alert.alert(OnlineLang.L('sidebar.tabLocked', 'This tab is inaccessible!'));
						break;
					}

					curTabIndex = i;
					break;
				}
				curTab.mouseDown(e);
			}
		});
		stage.addEventListener(MouseEvent.MOUSE_WHEEL, (e:MouseEvent) -> {
			if (LoadingScreen.loading)
				return;

			if (active)
				curTab.mouseWheel(e);
		});
	}

	function onChangedTab() {
		tabTitle.setText(curTab.title, upBar.width);
		tabTitle.x = 20;
		tabTitle.y = upBar.height / 2 - tabTitle.getTextHeight() / 2 - 5;

		for (i => tile in tabButtonsUnderlay) {
			tile.alpha = 0.2;
			if (tile.overlapsMouse())
				tile.alpha = 0.5;
			if (curTabIndex == i)
				tile.alpha = 1;
		}
	}

	function set_active(show:Bool) {
		if (show == active)
			return active;

		active = show;

		stage.focus = null;
		FlxTween.cancelTweensOf(this);
		FlxTween.cancelTweensOf(tabUI);
		FlxTween.cancelTweensOf(upBar);

		FlxG.mouse.enabled = !active;
		FlxG.keys.enabled = !active;
		cursor.visible = active;

		function onOnline() {
			if (!active)
				return;

			welcome.setText(OnlineLang.L('sidebar.loggedAs', 'Logged as ') + FunkinNetwork.nickname, upBar.width);
			welcome.x = upBar.width - welcome.width - 50;
			welcome.y = upBar.height / 2 - welcome.getTextHeight() / 2 - 5;

			tip.x = upBar.width / 2 - tip.width / 2;
			tip.y = welcome.y;

			curTab.onShowOnline();

			for (i => button in tabButtons) {
				button.alpha = tabs[i].locked ? 0.5 : 1;
			}
		}

		function onOffline() {
			if (!active)
				return;

			welcome.setText(OnlineLang.L('sidebar.notLoggedIn', 'Not logged in'), upBar.width);
			welcome.x = upBar.width - welcome.width - 50;
			welcome.y = upBar.height / 2 - welcome.getTextHeight() / 2 - 5;

			tip.y = welcome.y;

			curTab.onShowOffline();

			for (i => button in tabButtons) {
				button.alpha = tabs[i].locked ? 0.5 : 1;
			}
		}

		mouseEnabled = active;
		mouseChildren = active;

		if (active) {
			tabUI.addChild(curTab);
			curTab.onShow();
			_wasMouseShown = FlxG.mouse.visible;
			FlxG.mouse.visible = false;

			if (!FunkinNetwork.loggedIn)
				Thread.run(() -> {
					FunkinNetwork.ping();

					if (FunkinNetwork.loggedIn)
						Waiter.putPersist(onOnline);
					else
						Waiter.putPersist(onOffline);
				});
			else
				onOnline();

			// The `actuate` haxelib is not installed here, so FlxTween drives the same openfl
			// properties (the sidebar lives on Lib.current).
			FlxTween.tween(this, {alpha: 1}, 0.5);
			FlxTween.tween(upBar, {y: 0}, 0.2, {onComplete: _ -> FlxTween.tween(tabUI, {x: 0}, 0.2)});
		}
		else {
			FlxG.mouse.visible = _wasMouseShown;

			curTab.onHide();

			FlxTween.tween(this, {alpha: 0}, 0.5, {onComplete: _ -> {
				tabUI.removeChild(curTab);
				curTab.onRemove();
			}});
			FlxTween.tween(tabUI, {x: -totalTabWidth()}, 0.3, {onComplete: _ -> FlxTween.tween(upBar, {y: -upBar.height}, 0.2)});
		}
		return active;
	}

	/** The cursor, drawn instead of embedded (see the note in init()). */
	static function makeCursor():BitmapData {
		var shape = new Shape();
		shape.graphics.beginFill(0xFFFFFF);
		shape.graphics.lineStyle(1, 0x000000);
		shape.graphics.moveTo(0, 0);
		shape.graphics.lineTo(0, 16);
		shape.graphics.lineTo(4, 12);
		shape.graphics.lineTo(7, 19);
		shape.graphics.lineTo(10, 17);
		shape.graphics.lineTo(7, 11);
		shape.graphics.lineTo(12, 11);
		shape.graphics.lineTo(0, 0);
		shape.graphics.endFill();

		var data = new BitmapData(16, 20, true, 0x00000000);
		data.draw(shape);
		return data;
	}

	function totalTabWidth() {
		return leftBar.width + (curTab != null ? curTab.tabWidth : DEFAULT_TAB_WIDTH);
	}
}