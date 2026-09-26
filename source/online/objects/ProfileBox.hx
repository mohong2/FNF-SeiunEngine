package online.objects;

#if ONLINE_ALLOWED
import flixel.util.FlxGradient;
import openfl.display.BitmapData;
import flixel.util.FlxStringUtil;
import online.network.FunkinNetwork;
import flixel.util.FlxSpriteUtil;

//slop class, i coded it really lazily 
class ProfileBox extends FlxSpriteGroup {
    public var isSelf:Bool = false;

	public var user:String;
	public var verified:Bool = false;
	public var cardHeight:Int;
	public var autoCardHeight:Bool = true;
	public var profileData:Dynamic;

    var bg:FlxSprite;
	public var avatar:FlxSprite;
	public var text:FlxText;
	public var desc:FlxText;
	
	public var autoUpdateThings:Bool = true;
	public var sizeAdd:Int = 0;

	public function new(leUser:String, leVerified:Bool, ?leCardHeight:Int = 100, ?sizeAdd:Int = 0) {
        super();

		_ste = FlxG.state;

		this.sizeAdd = sizeAdd;

        bg = new FlxSprite();
		bg.alpha = 0.7;
        add(bg);

		avatar = new FlxSprite(0, 0, FunkinNetwork.getDefaultAvatar());
		avatar.antialiasing = ClientPrefs.data.globalAntialiasing;
		avatar.visible = false;
        add(avatar);

		text = new FlxText(0, 0, 0, "");
		text.setFormat(OnlineLang.font(), 16 + sizeAdd, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
        add(text);

		desc = new FlxText(0, 0, 0, "");
		desc.setFormat(OnlineLang.font(), 14 + sizeAdd, FlxColor.WHITE, LEFT, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		add(desc);

		cardHeight = leCardHeight;

		updateData(leUser, leVerified);
    }

	var _ste:Dynamic;

	public function updateData(leUser:String, leVerified:Bool) {
		if (destroyed)
			return;

		user = leUser;
		verified = leVerified;

		//avatar.makeGraphic(0, 0, FlxColor.TRANSPARENT);
		avatar.visible = false;

		profileData = null;
		drawBG();
		if (autoUpdateThings) {
			text.text = "";
			desc.text = "";
		}
		
		Thread.run(() -> {
			isSelf = verified && user == FunkinNetwork.nickname;

			if (verified)
				profileData = FunkinNetwork.fetchUserInfo(user);
			else
				profileData = null;

			Waiter.put(creativo);
		});
	}

    public function creativo() {
		#if SDEBUG trace(FlxG.state == _ste); #end

		if (destroyed)
			return;

		if (autoUpdateThings) {
			text.text = "";
			desc.text = "";
		}

		if (verified) {
			if (profileData != null) {
				if (autoUpdateThings) {
					if (isSelf)
						text.text = OnlineLang.L('profile.welcome', 'Welcome, ') + user + "!";
					else
						text.text = user;
					// Haxe 4.2.5 has no null-coalescing operator; expand it.
					desc.text = OnlineLang.L('profile.points', 'Points: ') + FlxStringUtil.formatMoney(profileData.points != null ? profileData.points : 0, false);
					desc.text += "\nRank: " + ShitUtil.toOrdinalNumber(profileData.rank);
					desc.text += "\nAvg. Accuracy: " + FlxMath.roundDecimal((profileData.avgAccuracy * 100), 2) + "%";
				}

				Thread.run(() -> {
					var avatarData = FunkinNetwork.getUserAvatar(user);

					Waiter.put(() -> {
						if (!destroyed) {
							var prevAvatar = avatar;

							// Animated GIF avatars would use
							// `new online.objects.FlxGifSprite(avatarData)`, which needs
							// `com.yagp.*`: absent here, not vendorable (offline) and on the
							// do-not-introduce list, so GIFs fall back to the static first frame.
							if (avatarData == null)
								avatar = new FlxSprite(0, 0, FunkinNetwork.getDefaultAvatar());
							else
								avatar = new FlxSprite(0, 0, BitmapData.fromBytes(avatarData));

							avatar.antialiasing = ClientPrefs.data.globalAntialiasing;
							insert(members.indexOf(prevAvatar), avatar);
							remove(prevAvatar);
							
							fitAvatar();
							updatePositions();
						}
					});
				});
			}
			else {
				if (autoUpdateThings) {
					if (isSelf) {
						text.text = OnlineLang.L('profile.notLoggedIn', 'Not logged in!');
						desc.text = OnlineLang.L('profile.clickToRegister', '(Click to register)');
					}
					else
						text.text = OnlineLang.L('profile.userNotFound', 'User not found!');
					cardHeight = 50;
				}
			}
		}

		drawBG();
    }
	
	var tempMask:FlxSprite;

    public function drawBG() {
		// Haxe 4.2.5 has no safe-navigation or `??`; the null-safe field reads are expanded below,
		// with 230 as the default hue.
		var profileHue:Float = 230;
		var profileHue2:Null<Float> = null;
		if (profileData != null) {
			if (profileData.profileHue != null)
				profileHue = profileData.profileHue;
			profileHue2 = profileData.profileHue2;
		}

		bg.makeGraphic(320 + 10 * sizeAdd, cardHeight, FlxColor.TRANSPARENT);

		if (profileHue2 != null) {
			// Haxe 4.2.5 has no null-coalescing assignment (`??=`); expand it.
			if (tempMask == null)
				tempMask = new FlxSprite();
			tempMask.makeGraphic(bg.frameWidth, bg.frameHeight, FlxColor.TRANSPARENT, true);

			FlxSpriteUtil.drawRoundRect(tempMask, 0, 0, bg.width, bg.height, 40, 40, FlxColor.WHITE);

			FlxSpriteUtil.alphaMaskFlxSprite(FlxGradient.createGradientFlxSprite(bg.frameWidth, bg.frameHeight, [
				FlxColor.fromHSL(profileHue, 0.35, 0.3),
				FlxColor.fromHSL(profileHue2, 0.4, 0.25)
			], 1, 90, true), tempMask, bg);
		}
		else {
			FlxSpriteUtil.drawRoundRect(bg, 0, 0, bg.width, bg.height, 40, 40, FlxColor.fromHSL(profileHue, 0.25, 0.25));
		}

		bg.updateHitbox();

		fitAvatar();
        updatePositions();
    }

	public var avatarMaxSize:Int = 80;

    public function fitAvatar() {
		if (avatar == null || avatar.width < 1)
            return;

		// flixel 4.11's `setGraphicSize(Width:Int, Height:Int)` rejects Float arguments, so the
		// values are wrapped in Std.int (the engine's own call sites do the same).
		avatar.setGraphicSize(Std.int(Math.min(cardHeight * 0.8, avatarMaxSize)), Std.int(Math.min(cardHeight * 0.8, avatarMaxSize)));
		avatar.updateHitbox();
		updatePositions();
    }

	var maxTextSize:Float = 0.0;
	var maxTextSizeDesc:Float = 0.0;
	var _cardHeight:Int;
    public function updatePositions() {
		if (destroyed)
			return;
		
		avatar.x = x + 20;
		avatar.y = y + height / 2 - avatar.height / 2;
		text.x = avatar.x + avatar.width + 20;
		text.y = y + 15;
		desc.x = text.x;
		if (!avatar.visible) {
			text.x = x + bg.width / 2 - text.width / 2;
			desc.x = x + bg.width / 2 - desc.width / 2;
			// text.y = y + bg.height / 2 - text.height / 2 - (desc.text.length > 0 ? (cardHeight >= 80 ? 20 : 10) : 0);
        }
		text.alignment = LEFT;
		desc.y = text.y + text.height + 5;
		if (desc.text.length < 1) {
			if (!avatar.visible)
				text.alignment = CENTER;
			desc.y = text.y + text.height;
			desc.height = 0;
		}

		maxTextSize = bg.width - (text.x - x) - 20;
		text.fieldWidth = maxTextSize;
		//text.scale.x = Math.min(1, maxTextSizeDesc / text.width);

		maxTextSizeDesc = bg.width - (desc.x - x) - 20;
		desc.fieldWidth = maxTextSizeDesc;
		//desc.scale.x = Math.min(1, maxTextSizeDesc / desc.width);

		if (autoCardHeight) {
			_cardHeight = Std.int(Math.max((desc.y - y) + desc.height, (avatar.y - y) + avatar.height) + 20);
			if (cardHeight != _cardHeight) {
				cardHeight = _cardHeight;
				drawBG();
			}
		}
    }

    override function update(elapsed) {
        super.update(elapsed);

		bg.alpha = FlxG.mouse.overlaps(this, camera) ? 1 : 0.8;
		if (FlxG.mouse.overlaps(this, camera) && FlxG.mouse.justPressed) {
			if (user != null && verified)
				// This engine has no sidebar, so the full profile screen is opened instead of
				// the sidebar's profile tab.
				online.gui.sidebar.tabs.ProfileTab.view(user);
			else if (isSelf && !FunkinNetwork.loggedIn)
				FlxG.switchState(new OnlineOptionsState(true));
        }
    }

    var destroyed:Bool = false;
    override function destroy() {
		destroyed = true;
        super.destroy();
    }
}
#end