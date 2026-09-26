package online.substates;

#if ONLINE_ALLOWED
import flixel.util.FlxStringUtil;
import online.network.FunkinNetwork;
import openfl.filters.BlurFilter;
import online.network.Leaderboard;
import online.util.OnlineLang;

class TopPlayerSubstate extends MusicBeatSubstate {
	var topShit:Scoreboard = new Scoreboard(FlxG.width - 300, 35, 15, ["PLAYER", "POINTS"]);

	var blurFilter:BlurFilter;
	var coolCam:FlxCamera;

    var curPage:Int = 0;
    var curSelected(default, set):Int = -2;
	var curCategory:Int = 0;
	var curKeys:Int = 4;

	var categoryTxt:FlxText;
	var keysTxt:FlxText;
	/** Weekly view only: "resets in N days". */
	var resetTxt:FlxText;

	override function create() {
		super.create();

		blurFilter = new BlurFilter();
		for (cam in FlxG.cameras.list) {
			if (cam.filters == null)
				cam.filters = [];
			cam.filters.push(blurFilter);
		}

		coolCam = new FlxCamera();
		coolCam.bgColor.alpha = 0;
		FlxG.cameras.add(coolCam, false);

		cameras = [coolCam];
        
		topShit.screenCenter(XY);
		LoadingScreen.toggle(true);
		if (leaderboardTimer != null)
			leaderboardTimer.cancel();
		leaderboardTimer = new FlxTimer().start(0.5, t -> { generateLeaderboard(); });
		add(topShit);

		categoryTxt = new FlxText(0, 20);
		categoryTxt.setFormat(OnlineLang.font(), 20, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		add(categoryTxt);

		keysTxt = new FlxText(0, 50);
		keysTxt.setFormat(OnlineLang.font(), 20, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		add(keysTxt);

		resetTxt = new FlxText(0, topShit.y + topShit.background.height + 8);
		resetTxt.setFormat(OnlineLang.font(), 16, 0xFF9FB2C0, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		add(resetTxt);
		#if (TOUCH_CONTROLS || desktop)
		addVirtualPad(LEFT_FULL, A_B);
		addPadCamera();
		#end
    }

    var top:Array<Dynamic> = [];
	var leaderboardTimer:FlxTimer;

	/** Cached so the label is a pure lookup; the request happens once, off the main thread. */
	var weeklyResetStamp:Float = -1;
	var weeklyResetFetched:Bool = false;

	/** `/api/nextweekreset` answers a bare millisecond timestamp, not JSON. */
	function refreshResetLabel() {
		if (Leaderboard.categories[curCategory] != 'week') {
			resetTxt.text = '';
			return;
		}

		if (!weeklyResetFetched) {
			weeklyResetFetched = true;
			Thread.run(() -> {
				var response = FunkinNetwork.requestAPI('/api/nextweekreset', false);
				var stamp = -1.0;
				if (response != null && !response.isFailed()) {
					var parsed = Std.parseFloat(Std.string(response.getString()).trim());
					if (!Math.isNaN(parsed))
						stamp = parsed;
				}
				var resolved = stamp;
				Waiter.put(() -> {
					weeklyResetStamp = resolved;
					resetTxt.text = resetLabelFor(resolved);
					resetTxt.screenCenter(X);
				});
			}, (exc:haxe.Exception) -> trace('weekly reset failed: ' + exc));
			resetTxt.text = OnlineLang.L('leaderboard.reset.unknown', 'Weekly reset time unknown');
			resetTxt.screenCenter(X);
			return;
		}

		resetTxt.text = resetLabelFor(weeklyResetStamp);
		resetTxt.screenCenter(X);
	}

	function resetLabelFor(stamp:Float):String {
		if (stamp <= 0)
			return OnlineLang.L('leaderboard.reset.unknown', 'Weekly reset time unknown');
		// neko's 32-bit Std.int() overflows on 13-digit stamps, so this stays in Float.
		var days = Math.ffloor((stamp - Date.now().getTime()) / 86400000);
		if (days < 0)
			days = 0;
		return OnlineLang.L('leaderboard.reset', 'Weekly reset in ') + days + OnlineLang.L('leaderboard.reset.days', ' days');
	}

	function generateLeaderboard() {
		topShit.clearRows();
		topShit.selectRow(curSelected = (curSelected < 0 ? curSelected : 0));

		categoryTxt.text = '< ${Leaderboard.categoryTitles[curCategory]} >';
		categoryTxt.screenCenter(X);

		keysTxt.text = '< ${curKeys}k >';
		keysTxt.screenCenter(X);

		// The column really changes with the category. "week" is not a separate points pool --
		// the server filters score rows by submittedTs (LeaderboardStore.withinCategory) -- so the
		// header has to say what the numbers mean, and the weekly view says when it resets.
		var pointsLabel = Leaderboard.categories[curCategory] == 'week'
			? OnlineLang.L('leaderboard.points.week', 'WEEK POINTS') : OnlineLang.L('leaderboard.points.all', 'ALL TIME');
		topShit.setColumnLabel(1, pointsLabel);
		refreshResetLabel();

		try {
			var sortProp = 'points${curKeys}k';
			Leaderboard.fetchPlayerLeaderboard(curPage, Leaderboard.categories[curCategory], sortProp, top -> {
				LoadingScreen.toggle(false);
				if (!topShit.exists)
					return;

                // Haxe 4.2.5 has no null-coalescing operator; expand it.
				this.top = top != null ? top : [];

				if (top == null) {
                    close();
                    return;
                }

				var coolColor:Null<FlxColor> = null;
				for (i in 0...top.length) {
					if (curPage == 0) {
						switch (i) {
							case 0:
								coolColor = FlxColor.ORANGE;
							default:
								coolColor = null;
						}
					}
					// The local server keeps a single points pool and answers with "points"; it
					// never sets a per-key field name. Read the requested field first, then fall
					// back -- without this the
					// POINTS column is 0 for every row, including players that do have points.
					var rowPoints:Dynamic = Reflect.field(top[i], sortProp);
					if (rowPoints == null)
						rowPoints = Reflect.field(top[i], 'points');

					topShit.setRow(i, [
						(i + 1 + curPage * 15) + ". " + top[i].player,
						FlxStringUtil.formatMoney(rowPoints != null ? rowPoints : 0, false)
					], coolColor);
				}
			});
		}
		catch (e:Dynamic) {
			LoadingScreen.toggle(false);
		}
	}

	/** Opens the full profile screen. */
	function showProfile(player:String):Void {
		if (player == null || player == '')
			return;

		LoadingScreen.toggle(false);
		online.gui.sidebar.tabs.ProfileTab.view(player);
	}

	override function destroy() {
		super.destroy();

		if (leaderboardTimer != null)
			leaderboardTimer.cancel();

		for (cam in FlxG.cameras.list) {
			// Haxe 4.2.5 has no safe-navigation (`?.`); expand to an explicit null check.
			if (cam != null && cam.filters != null)
				cam.filters.remove(blurFilter);
		}
		FlxG.cameras.remove(coolCam);
	}

    override function update(elapsed) {
        super.update(elapsed);

		if (controls.UI_LEFT_P && (curSelected < 0 || curPage != 0)) {
			if (curSelected == -2) {
				curPage = 0;
				curCategory--;
				if (curCategory < 0)
					curCategory = Leaderboard.categories.length - 1;
			}
			else if (curSelected == -1) {
				curPage = 0;
				curKeys--;
				if (curKeys < 4)
					curKeys = 9;
			}
			else 
            	curPage--;
            if (curPage < 0)
                curPage = 0;

			LoadingScreen.toggle(true);
			if (leaderboardTimer != null)
				leaderboardTimer.cancel();
			leaderboardTimer = new FlxTimer().start(0.5, t -> { generateLeaderboard(); });
        }
        else if (controls.UI_RIGHT_P) {
			if (curSelected == -2) {
				curPage = 0;
				curCategory++;
				if (curCategory >= Leaderboard.categories.length)
					curCategory = 0;
			}
			else if (curSelected == -1) {
				curPage = 0;
				curKeys++;
				if (curKeys > 9)
					curKeys = 4;
			}
			else
				curPage++;

			LoadingScreen.toggle(true);
			if (leaderboardTimer != null)
				leaderboardTimer.cancel();
			leaderboardTimer = new FlxTimer().start(0.5, t -> { generateLeaderboard(); });
        }
		else if (controls.UI_UP_P || FlxG.mouse.wheel > 0) {
			curSelected--;
			if (curSelected < -2)
				curSelected = 14;
			topShit.selectRow(curSelected);
		}
		else if (controls.UI_DOWN_P || FlxG.mouse.wheel < 0) {
			curSelected++;
			if (curSelected > 14)
				curSelected = -2;
			topShit.selectRow(curSelected);
		}
        else if (controls.BACK) {
			LoadingScreen.toggle(false);
            close();
        }
        else if (controls.ACCEPT || FlxG.mouse.justPressed) {
			if (top[curSelected] != null) {
				// This engine has no sidebar `ProfileTab.view(...)`, so the card below is the
				// replacement.
				showProfile(top[curSelected].player);
			}
        }
    }

	function set_curSelected(v) {
		categoryTxt.alpha = v == -2 ? 1 : 0.7;
		keysTxt.alpha = v == -1 ? 1 : 0.7;
		return curSelected = v;
	}
}
#end