package states;

import flixel.FlxG;
import flixel.FlxSprite;
import flixel.text.FlxText;
import flixel.util.FlxColor;
import flixel.util.FlxTimer;
import flixel.tweens.FlxTween;
import flixel.tweens.FlxEase;
import flixel.math.FlxMath;
import flixel.math.FlxRect;
import flixel.util.FlxSpriteUtil;
import backend.MusicBeatState;
import backend.SystemDiag;
import mohong.TraceManager;
#if sys
import sys.io.File;
import sys.FileSystem;
import haxe.io.Path;
#end

class CrashCatcherState extends MusicBeatState
{
	// -- Static crash info set by Main.hx before switching to this state --
	public static var lastCrashMessage:String = "";
	public static var lastCrashStack:String = "";
	public static var lastCrashPath:String = "";
	public static var crashCount:Int = 0;

	// -- UI elements --
	var bg:FlxSprite;
	var titleTxt:FlxText;
	var subtitleTxt:FlxText;
	var titleUnderline:FlxSprite;

	var errorPanel:FlxSprite;
	var errorLabel:FlxText;
	var errorText:FlxText;

	var stackPanel:FlxSprite;
	var stackLabel:FlxText;
	var stackText:FlxText;

	var btnReturn:FlxSprite;
	var btnReturnTxt:FlxText;
	var btnSave:FlxSprite;
	var btnSaveTxt:FlxText;
	var btnCopy:FlxSprite;
	var btnCopyTxt:FlxText;

	var savedConfirmTxt:FlxText;
	var instructionsTxt:FlxText;
	var crashCountTxt:FlxText;

	// -- GitHub report prompt --
	var reportHintTxt:FlxText;
	var reportUrlTxt:FlxText;
	var reportUrlUnderline:FlxSprite;
	var reportHintPulse:Float = 0;
	var urlHovered:Bool = false;

	// -- Easter egg for high crash counts --
	var easterEggTxt:FlxText;

	// -- Scroll state for panels --
	var scrollOffset:Float = 0;
	var maxScroll:Float = 0;
	var stackViewH:Float = 0;
	var errorScrollOffset:Float = 0;
	var errorMaxScroll:Float = 0;
	var errorViewH:Float = 0;

	// -- Button selection --
	var selectedButton:Int = 0; // 0 = return, 1 = save, 2 = copy

	// -- Save countdown (5-second delay) --
	var saveState:Int = 0; // 0=idle, 1=counting, 2=saving
	var saveCountdown:Float = 5;
	var saveCountdownTxt:FlxText;
	var saveCooldownActive:Bool = false;

	// ================ Mobile touch helpers ================
	function checkTouchInteraction():Bool
	{
		#if mobile
		for (touch in FlxG.touches.list)
			if (touch.justReleased) return true;
		#end
		return false;
	}

	function touchOverlapsButton(btn:FlxSprite):Bool
	{
		#if mobile
		for (touch in FlxG.touches.list)
			if (touch.justReleased && touch.overlaps(btn)) return true;
		#end
		return false;
	}

	// ================ Open GitHub URL ================
	function openGitHubUrl()
	{
		var url:String = Language.get("CrashCatcher.reportURL", "https://github.com/mohong2/FNF-SeiunEngine/issues");
		CoolUtil.browserLoad(url);
		FlxG.sound.play(Paths.sound('scrollMenu'));
	}

	// -- Colors --
	var accentColor:FlxColor = FlxColor.fromRGB(220, 50, 50);
	var panelBgColor:FlxColor = FlxColor.fromRGB(15, 18, 30);
	var panelAlpha:Float = 0.75;

	override function create()
	{
		super.create();

		#if LUA_ALLOWED
		initLuaScripts();
		setOnLuas('controls', controls);
		setOnLuas('state', this);
		callOnLuas('onCreatePost', []);
		#end

		#if cpp
		Discord.DiscordClient.shutdown();
		#end

		// -- Background (full screen, dark acrylic) --
		bg = new FlxSprite().makeGraphic(FlxG.width, FlxG.height, FlxColor.fromRGBFloat(0.04, 0.04, 0.08, 0.92));
		bg.alpha = 0;
		add(bg);

		// -- Dynamic layout tracker for title area --
		var titleAreaY:Float = 28;

		// -- Title (Minecraft-style "出了点问题...") --
		var titleStr:String;
		if (crashCount > 1)
			titleStr = Language.get("CrashCatcher.titleAgain", "Uh oh! Something went wrong... again!");
		else
			titleStr = Language.get("CrashCatcher.title", "Uh oh! Something went wrong...");

		titleTxt = new FlxText(0, titleAreaY, FlxG.width, titleStr, 44);
		titleTxt.setFormat(Paths.languageFont(), 44, FlxColor.RED, CENTER);
		titleTxt.alpha = 0;
		add(titleTxt);

		// -- Subtitle --
		titleAreaY += 52;
		subtitleTxt = new FlxText(0, titleAreaY, FlxG.width,
			Language.get("CrashCatcher.subtitle", "The game ran into a problem and needs to recover."), 16);
		subtitleTxt.setFormat(Paths.languageFont(), 16, FlxColor.GRAY, CENTER);
		subtitleTxt.alpha = 0;
		add(subtitleTxt);


		// -- Crash count indicator (if > 1) --
		if (crashCount > 1)
		{
			titleAreaY += 24;
			crashCountTxt = new FlxText(0, titleAreaY, FlxG.width,
				Language.get("CrashCatcher.crashCount", "Crash count:") + " " + crashCount, 12);
			crashCountTxt.setFormat(Paths.languageFont(), 12, FlxColor.fromRGB(180, 120, 120), CENTER);
			crashCountTxt.alpha = 0;
			add(crashCountTxt);
		}

		// -- Easter egg for frequent crashers --
		var eggMsg:String = getEasterEgg(crashCount);
		if (eggMsg != "")
		{
			titleAreaY += 22;
			easterEggTxt = new FlxText(0, titleAreaY, FlxG.width, eggMsg, 13);
			easterEggTxt.setFormat(Paths.languageFont(), 13, FlxColor.fromRGB(255, 200, 100), CENTER);
			easterEggTxt.alpha = 0;
			add(easterEggTxt);
		}

		// -- Underline --
		titleUnderline = new FlxSprite().makeGraphic(400, 3, accentColor);
		titleUnderline.screenCenter(X);
		titleUnderline.y = titleAreaY + 24;
		titleUnderline.scale.x = 0;
		add(titleUnderline);

		// -- GitHub report hint (always shown, below buttons area) --
		var githubUrl:String = Language.get("CrashCatcher.reportURL", "https://github.com/mohong2/FNF-SeiunEngine/issues");
		reportHintTxt = new FlxText(30, 0, FlxG.width - 60,
			Language.get("CrashCatcher.reportHint",
				"Please report this error to the developer on GitHub, otherwise it may never be fixed!"), 12);
		reportHintTxt.setFormat(Paths.languageFont(), 12, FlxColor.fromRGB(200, 150, 100), CENTER);
		reportHintTxt.alpha = 0;
		add(reportHintTxt);

		// -- Clickable GitHub URL (styled like an HTML link) --
		reportUrlTxt = new FlxText(0, 0, FlxG.width, githubUrl, 13);
		reportUrlTxt.setFormat(Paths.languageFont(), 13, FlxColor.fromRGB(100, 180, 255), CENTER);
		reportUrlTxt.alpha = 0;
		add(reportUrlTxt);

		// Underline for the URL (hidden by default, shown on hover)
		reportUrlUnderline = new FlxSprite().makeGraphic(1, 1, FlxColor.fromRGB(100, 180, 255));
		reportUrlUnderline.alpha = 0;
		add(reportUrlUnderline);

		// -- Layout calculations --
		var panelMargin:Float = 30;
		var panelWidth:Int = Std.int(FlxG.width - panelMargin * 2);
		var upperY:Float = titleUnderline.y + 20;
		var bottomReserved:Float = 200; // buttons + hints + instructions
		var remainingH:Float = Math.max(100, FlxG.height - upperY - bottomReserved);
		var gap:Float = 12;
		var upperAreaH:Int = Std.int(remainingH * 0.48);
		var lowerAreaH:Int = Std.int(remainingH * 0.48);
		var lowerY:Float = upperY + upperAreaH + gap;

		// -- Upper panel: Error message --
		errorPanel = createRoundedPanel(panelMargin, upperY, panelWidth, upperAreaH, panelBgColor);
		add(errorPanel);

		errorLabel = new FlxText(panelMargin + 16, upperY + 12, panelWidth - 32,
			Language.get("CrashCatcher.errorLabel", "Error:"), 18);
		errorLabel.setFormat(Paths.languageFont(), 18, accentColor, LEFT);
		errorLabel.alpha = 0;
		add(errorLabel);

		errorText = new FlxText(panelMargin + 16, upperY + 40, panelWidth - 32, lastCrashMessage, 14);
		errorText.setFormat(Paths.languageFont(), 14, FlxColor.fromRGB(220, 220, 230), LEFT);
		errorText.alpha = 0;
		add(errorText);

		// -- Lower panel: Stack trace --
		stackPanel = createRoundedPanel(panelMargin, lowerY, panelWidth, lowerAreaH, panelBgColor);
		add(stackPanel);

		stackLabel = new FlxText(panelMargin + 16, lowerY + 10, panelWidth - 32,
			Language.get("CrashCatcher.stackLabel", "Stack Trace:"), 16);
		stackLabel.setFormat(Paths.languageFont(), 16, FlxColor.fromRGB(180, 180, 200), LEFT);
		stackLabel.alpha = 0;
		add(stackLabel);

		stackViewH = lowerAreaH - 46;
		stackText = new FlxText(panelMargin + 16, lowerY + 34, panelWidth - 32, lastCrashStack, 12);
		stackText.setFormat(Paths.languageFont(), 12, FlxColor.fromRGB(170, 170, 190), LEFT);
		stackText.alpha = 0;
		add(stackText);

		if (stackText.height > stackViewH)
			maxScroll = stackText.height - stackViewH;
		stackText.clipRect = FlxRect.get(0, 0, stackText.fieldWidth, stackViewH);

		errorViewH = upperAreaH - 46;
		if (errorText.height > errorViewH)
			errorMaxScroll = errorText.height - errorViewH;
		errorText.clipRect = FlxRect.get(0, 0, errorText.fieldWidth, errorViewH);

		// -- Crash file path info --
		var infoTxt = "";
		if (lastCrashPath != "")
		{
			infoTxt = Language.get("CrashCatcher.savedTo", "Report saved to") + ": " + lastCrashPath;
		}
		var pathInfo = new FlxText(panelMargin, lowerY + lowerAreaH + 6, panelWidth, infoTxt, 11);
		pathInfo.setFormat(Paths.languageFont(), 11, FlxColor.fromRGB(120, 120, 140), LEFT);
		pathInfo.alpha = 0;
		add(pathInfo);

		// -- Buttons --
		var btnY:Float = Math.min(lowerY + lowerAreaH + 50, FlxG.height - 150);
		var btnW:Int = 190;
		var btnH:Int = 46;
		var btnGap:Int = 16;
		var totalBtnW:Float = btnW * 3 + btnGap * 2;
		var btnStartX:Float = (FlxG.width - totalBtnW) / 2;

		// Return to menu button
		btnReturn = createButton(btnStartX, btnY, btnW, btnH, accentColor);
		add(btnReturn);

		btnReturnTxt = new FlxText(0, 0, btnW,
			"> " + Language.get("CrashCatcher.returnToMenu", "Return to Menu") + " <", 20);
		btnReturnTxt.setFormat(Paths.languageFont(), 20, FlxColor.WHITE, CENTER);
		btnReturnTxt.alpha = 0;
		add(btnReturnTxt);
		centerTextOnButton(btnReturnTxt, btnReturn);

		// Save report button
		btnSave = createButton(btnStartX + btnW + btnGap, btnY, btnW, btnH, FlxColor.fromRGB(70, 75, 90));
		add(btnSave);

		btnSaveTxt = new FlxText(0, 0, btnW,
			Language.get("CrashCatcher.saveReport", "Save Report"), 20);
		btnSaveTxt.setFormat(Paths.languageFont(), 20, FlxColor.WHITE, CENTER);
		btnSaveTxt.alpha = 0;
		add(btnSaveTxt);
		centerTextOnButton(btnSaveTxt, btnSave);

		// Copy report button
		btnCopy = createButton(btnStartX + (btnW + btnGap) * 2, btnY, btnW, btnH, FlxColor.fromRGB(80, 110, 150));
		add(btnCopy);

		btnCopyTxt = new FlxText(0, 0, btnW,
			Language.get("CrashCatcher.copyReport", "Copy Log"), 20);
		btnCopyTxt.setFormat(Paths.languageFont(), 20, FlxColor.WHITE, CENTER);
		btnCopyTxt.alpha = 0;
		add(btnCopyTxt);
		centerTextOnButton(btnCopyTxt, btnCopy);

		// Save countdown overlay (hidden by default, only shown when counting)
		saveCountdownTxt = new FlxText(0, 0, btnW, "", 28);
		saveCountdownTxt.setFormat(Paths.languageFont(), 28, FlxColor.fromRGB(255, 200, 100), CENTER);
		saveCountdownTxt.alpha = 0;
		saveCountdownTxt.visible = false;
		add(saveCountdownTxt);

		// Saved confirmation
		savedConfirmTxt = new FlxText(0, btnY + btnH + 8, FlxG.width, "", 14);
		savedConfirmTxt.setFormat(Paths.languageFont(), 14, FlxColor.GREEN, CENTER);
		savedConfirmTxt.alpha = 0;
		add(savedConfirmTxt);

		// -- GitHub report hint (below buttons) --
		reportHintTxt.y = btnY + btnH + 26;
		reportUrlTxt.y = btnY + btnH + 44;

		// -- Instructions --
		var instrText = Language.get("CrashCatcher.instructions",
			"ENTER / CLICK: Select  |  ARROWS: Switch button  |  SCROLL: Panels  |  ESC: Return to menu");
		instructionsTxt = new FlxText(0, FlxG.height - 36, FlxG.width, instrText, 13);
		instructionsTxt.setFormat(Paths.languageFont(), 13, FlxColor.GRAY, CENTER);
		instructionsTxt.alpha = 0;
		add(instructionsTxt);

		// -- Fade in animations --
		FlxTween.tween(bg, {alpha: 1}, 0.6, {ease: FlxEase.quartOut});

		FlxTween.tween(titleTxt, {alpha: 1}, 0.5, {ease: FlxEase.quartOut, startDelay: 0.1});
		FlxTween.tween(subtitleTxt, {alpha: 1}, 0.5, {ease: FlxEase.quartOut, startDelay: 0.18});
		if (crashCountTxt != null)
			FlxTween.tween(crashCountTxt, {alpha: 1}, 0.4, {ease: FlxEase.quartOut, startDelay: 0.22});
		FlxTween.tween(titleUnderline.scale, {x: 1}, 0.6, {ease: FlxEase.quartOut, startDelay: 0.25});

		FlxTween.tween(errorPanel, {alpha: panelAlpha}, 0.5, {ease: FlxEase.quartOut, startDelay: 0.3});
		FlxTween.tween(errorLabel, {alpha: 1}, 0.4, {ease: FlxEase.quartOut, startDelay: 0.33});
		FlxTween.tween(errorText, {alpha: 1}, 0.4, {ease: FlxEase.quartOut, startDelay: 0.36});
		FlxTween.tween(stackPanel, {alpha: panelAlpha}, 0.5, {ease: FlxEase.quartOut, startDelay: 0.38});
		FlxTween.tween(stackLabel, {alpha: 1}, 0.4, {ease: FlxEase.quartOut, startDelay: 0.41});
		FlxTween.tween(stackText, {alpha: 1}, 0.4, {ease: FlxEase.quartOut, startDelay: 0.44});
		FlxTween.tween(pathInfo, {alpha: 1}, 0.4, {ease: FlxEase.quartOut, startDelay: 0.47});
		if (easterEggTxt != null)
			FlxTween.tween(easterEggTxt, {alpha: 1}, 0.5, {ease: FlxEase.quartOut, startDelay: 0.5});

		new FlxTimer().start(0.55, function(_) {
			FlxTween.tween(btnReturn, {alpha: 1}, 0.35, {ease: FlxEase.quartOut});
			FlxTween.tween(btnReturnTxt, {alpha: 1}, 0.35, {ease: FlxEase.quartOut});
			FlxTween.tween(btnSave, {alpha: 1}, 0.35, {ease: FlxEase.quartOut, startDelay: 0.05});
			FlxTween.tween(btnSaveTxt, {alpha: 1}, 0.35, {ease: FlxEase.quartOut, startDelay: 0.05});
			FlxTween.tween(btnCopy, {alpha: 1}, 0.35, {ease: FlxEase.quartOut, startDelay: 0.1});
			FlxTween.tween(btnCopyTxt, {alpha: 1}, 0.35, {ease: FlxEase.quartOut, startDelay: 0.1});
			FlxTween.tween(reportHintTxt, {alpha: 0.7}, 0.4, {ease: FlxEase.quartOut, startDelay: 0.15});
			FlxTween.tween(reportUrlTxt, {alpha: 0.8}, 0.4, {ease: FlxEase.quartOut, startDelay: 0.18});
			FlxTween.tween(instructionsTxt, {alpha: 1}, 0.35, {ease: FlxEase.quartOut, startDelay: 0.13});
		});

		#if android
		addVirtualPad(LEFT_FULL, A_B);
		addPadCamera();
		#end
	}

	// ================ Helper: rounded panel ================
	function createRoundedPanel(x:Float, y:Float, width:Int, height:Int, color:FlxColor):FlxSprite
	{
		#if android
		// 部分安卓设备上 FlxSpriteUtil.drawRoundRect 配合透明背景会导致崩溃
		var panel = new FlxSprite(x, y).makeGraphic(width, height, color);
		#else
		var panel = new FlxSprite(x, y).makeGraphic(width, height, FlxColor.TRANSPARENT);
		FlxSpriteUtil.drawRoundRect(panel, 0, 0, width, height, 14, 14, color, {thickness: 0, color: FlxColor.TRANSPARENT});
		#end
		panel.alpha = 0;
		return panel;
	}

	// ================ Helper: button ================
	function createButton(x:Float, y:Float, w:Int, h:Int, borderColor:FlxColor):FlxSprite
	{
		#if android
		var btn = new FlxSprite(x, y).makeGraphic(w, h, FlxColor.fromRGB(22, 25, 34));
		#else
		var btn = new FlxSprite(x, y).makeGraphic(w, h, FlxColor.TRANSPARENT);
		FlxSpriteUtil.drawRoundRect(btn, 0, 0, w, h, 12, 12,
			FlxColor.fromRGB(22, 25, 34), {thickness: 2, color: borderColor});
		#end
		btn.alpha = 0;
		return btn;
	}

	function centerTextOnButton(txt:FlxText, btn:FlxSprite)
	{
		txt.x = btn.x + (btn.width - txt.width) / 2;
		txt.y = btn.y + (btn.height - txt.height) / 2 - 2;
	}

	// ================ Update ================
	override function update(elapsed:Float)
	{
		#if LUA_ALLOWED
		callOnLuas('onUpdate', [elapsed]);
		#end
		#if HSCRIPT_ALLOWED
		callOnHscript('onUpdate', [elapsed]);
		#end
		// -- Panel scrolling (mouse wheel) --
		#if !mobile
		if (FlxG.mouse.overlaps(errorPanel))
		{
			var wheel = FlxG.mouse.wheel;
			if (wheel != 0)
			{
				errorScrollOffset -= wheel * 30;
				errorScrollOffset = FlxMath.bound(errorScrollOffset, 0, errorMaxScroll);
				var er = errorText.clipRect;
				if (er != null) { er.y = errorScrollOffset; errorText.clipRect = er; }
			}
		}
		if (FlxG.mouse.overlaps(stackPanel))
		{
			var wheel = FlxG.mouse.wheel;
			if (wheel != 0)
			{
				scrollOffset -= wheel * 30;
				scrollOffset = FlxMath.bound(scrollOffset, 0, maxScroll);
				var sr = stackText.clipRect;
				if (sr != null) { sr.y = scrollOffset; stackText.clipRect = sr; }
			}
		}
		#end

		super.update(elapsed);
		#if LUA_ALLOWED
		callOnLuas('onUpdatePost', [elapsed]);
		#end

		// -- Save countdown logic --
		if (saveState == 1)
		{
			saveCountdown -= elapsed;
			var displayNum:Int = Math.ceil(saveCountdown);
			saveCountdownTxt.text = Std.string(displayNum);
			centerTextOnButton(saveCountdownTxt, btnSave);

			if (saveCountdown <= 0)
			{
				saveState = 2;
				saveCountdownTxt.text = "";
				saveCountdownTxt.alpha = 0;
				saveCountdownTxt.visible = false;
				btnSaveTxt.alpha = 1;
				doSaveReport();
			}
		}

		// -- Report hint pulsing (subtle attention grab) --
		if (reportHintTxt.alpha > 0.01)
		{
			reportHintPulse += elapsed;
			reportHintTxt.alpha = 0.5 + 0.25 * Math.sin(reportHintPulse * 1.2);
		}

		// -- Clickable GitHub URL: hover underline + click to open --
		{
			#if !mobile
			var mouseInUrl:Bool = FlxG.mouse.overlaps(reportUrlTxt);
			if (mouseInUrl != urlHovered)
			{
				urlHovered = mouseInUrl;
				if (urlHovered)
				{
					// Show underline
					reportUrlUnderline.makeGraphic(Std.int(reportUrlTxt.width), 1, FlxColor.fromRGB(100, 180, 255));
					reportUrlUnderline.x = reportUrlTxt.x + (FlxG.width - reportUrlTxt.width) / 2;
					reportUrlUnderline.y = reportUrlTxt.y + reportUrlTxt.height + 1;
					reportUrlUnderline.alpha = 0;
					FlxTween.tween(reportUrlUnderline, {alpha: 0.8}, 0.15);
					// Change cursor appearance (via color shift)
					reportUrlTxt.color = FlxColor.fromRGB(150, 210, 255);
				}
				else
				{
					FlxTween.tween(reportUrlUnderline, {alpha: 0}, 0.15);
					reportUrlTxt.color = FlxColor.fromRGB(100, 180, 255);
				}
			}

			if (mouseInUrl && FlxG.mouse.justPressed)
			{
				openGitHubUrl();
			}
			#end

			#if mobile
			for (touch in FlxG.touches.list)
			{
				if (touch.justReleased && touch.overlaps(reportUrlTxt))
				{
					openGitHubUrl();
					break;
				}
			}
			#end
		}

		// -- Keyboard navigation --
		if (saveState != 1) // Don't allow switching while counting down
		{
			if (controls.UI_LEFT_P || controls.UI_RIGHT_P)
			{
				selectedButton = (selectedButton + 1) % 3;
				updateButtonSelection();
				FlxG.sound.play(Paths.sound('scrollMenu'));
			}

			if (controls.ACCEPT)
			{
				switch (selectedButton)
				{
					case 0:
						returnToMenu();
					case 1:
						saveReport();
					case 2:
						doCopyLog();
				}
			}
		}
		else
		{
			// During countdown, pressing again cancels
			if (controls.ACCEPT || controls.BACK || FlxG.keys.justPressed.ESCAPE
				#if android || FlxG.android.justReleased.BACK #end)
			{
				cancelSaveCountdown();
			}
		}

		if (controls.BACK #if android || FlxG.android.justReleased.BACK #end || FlxG.keys.justPressed.ESCAPE)
		{
			if (saveState == 1)
				cancelSaveCountdown();
			else
				returnToMenu();
		}

		// -- Mouse click (desktop) --
		if (FlxG.mouse.justPressed)
		{
			if (FlxG.mouse.overlaps(btnReturn))
			{
				selectedButton = 0;
				updateButtonSelection();
				if (saveState == 1) cancelSaveCountdown();
				else returnToMenu();
			}
			else if (FlxG.mouse.overlaps(btnSave))
			{
				selectedButton = 1;
				updateButtonSelection();
				saveReport();
			}
			else if (FlxG.mouse.overlaps(btnCopy))
			{
				selectedButton = 2;
				updateButtonSelection();
				doCopyLog();
			}
		}

		#if mobile
		// -- Touch click (mobile) --
		{
			var touchPressed:Bool = false;
			var touchOverReturn:Bool = false;
			var touchOverSave:Bool = false;
			var touchOverCopy:Bool = false;
			for (touch in FlxG.touches.list)
			{
				if (touch.justReleased)
				{
					touchPressed = true;
					if (touch.overlaps(btnReturn)) touchOverReturn = true;
					if (touch.overlaps(btnSave)) touchOverSave = true;
					if (touch.overlaps(btnCopy)) touchOverCopy = true;
				}
			}
			if (touchPressed)
			{
				if (touchOverReturn)
				{
					selectedButton = 0;
					updateButtonSelection();
					if (saveState == 1) cancelSaveCountdown();
					else returnToMenu();
				}
				else if (touchOverSave)
				{
					selectedButton = 1;
					updateButtonSelection();
					saveReport();
				}
				else if (touchOverCopy)
				{
					selectedButton = 2;
					updateButtonSelection();
					doCopyLog();
				}
			}
		}
		#end
	}

	// ================ Cancel save countdown ================
	function cancelSaveCountdown()
	{
		if (saveState != 1) return;
		saveState = 0;
		saveCountdown = 5;
		saveCountdownTxt.text = "";
		saveCountdownTxt.alpha = 0;
		saveCountdownTxt.visible = false;
		btnSaveTxt.alpha = 1; // Restore button text
		updateButtonSelection();
		FlxG.sound.play(Paths.sound('cancelMenu'));
		savedConfirmTxt.text = Language.get("CrashCatcher.saveCancelled", "Save cancelled.");
		savedConfirmTxt.alpha = 1;
		FlxTween.tween(savedConfirmTxt, {alpha: 0}, 1.5);
	}

	// ================ Button selection highlight ================
	function updateButtonSelection()
	{
		btnReturnTxt.text = (selectedButton == 0)
			? "> " + Language.get("CrashCatcher.returnToMenu", "Return to Menu") + " <"
			: Language.get("CrashCatcher.returnToMenu", "Return to Menu");
		centerTextOnButton(btnReturnTxt, btnReturn);

		var saveLabel:String;
		if (saveState == 1)
			saveLabel = Language.get("CrashCatcher.saveCancelling", "[CANCEL]");
		else if (saveState == 2)
			saveLabel = Language.get("CrashCatcher.savedDone", "Saved!");
		else
			saveLabel = Language.get("CrashCatcher.saveReport", "Save Report");

		btnSaveTxt.text = (selectedButton == 1)
			? "> " + saveLabel + " <"
			: saveLabel;
		centerTextOnButton(btnSaveTxt, btnSave);

		btnCopyTxt.text = (selectedButton == 2)
			? "> " + Language.get("CrashCatcher.copyReport", "Copy Log") + " <"
			: Language.get("CrashCatcher.copyReport", "Copy Log");
		centerTextOnButton(btnCopyTxt, btnCopy);
	}

	// ================ Copy the crash log to the clipboard ================
	function doCopyLog()
	{
		try
		{
			// Full report: error + stack + system/renderer/GPU info + recent logs + native crash logs
			var report:String = SystemDiag.buildCrashDump(lastCrashMessage, lastCrashStack, crashCount);

			// The dump on disk is generated from the same data - just point at it.
			#if sys
			if (lastCrashPath != "" && sys.FileSystem.exists(lastCrashPath))
			{
				report += "\n[Full dump on disk: " + lastCrashPath + "]\n";
			}
			#end

			var ok:Bool = backend.SeiunOverlay.setClipboardText(report);

			savedConfirmTxt.text = ok
				? Language.get("CrashCatcher.copiedConfirm", "Crash log copied to clipboard!")
				: Language.get("CrashCatcher.copiedFail", "Could not copy - please use Save Report instead.");
			savedConfirmTxt.alpha = 1;
			FlxTween.tween(savedConfirmTxt, {alpha: 0}, 3, {startDelay: 2});
			FlxG.sound.play(Paths.sound('confirmMenu'));
		}
		catch (e:Dynamic)
		{
			TraceManager.error('trace.crashCatcher.copyFailed', 'CrashCatcherState - Failed to copy log: {}', [e]);
			savedConfirmTxt.text = Language.get("CrashCatcher.copiedFail", "Could not copy - please use Save Report instead.");
			savedConfirmTxt.alpha = 1;
			FlxTween.tween(savedConfirmTxt, {alpha: 0}, 3, {startDelay: 2});
		}
	}

	// ================ Return to main menu ================
	function returnToMenu()
	{
		// Fade out (all elements with identical duration for consistent exit)
		var fadeTime:Float = 0.22;
		FlxTween.tween(titleTxt, {alpha: 0}, fadeTime);
		FlxTween.tween(subtitleTxt, {alpha: 0}, fadeTime);
		if (crashCountTxt != null) FlxTween.tween(crashCountTxt, {alpha: 0}, fadeTime);
		if (easterEggTxt != null) FlxTween.tween(easterEggTxt, {alpha: 0}, fadeTime);
		FlxTween.tween(titleUnderline, {alpha: 0}, fadeTime);
		FlxTween.tween(errorPanel, {alpha: 0}, fadeTime);
		FlxTween.tween(errorLabel, {alpha: 0}, fadeTime);
		FlxTween.tween(errorText, {alpha: 0}, fadeTime);
		FlxTween.tween(stackPanel, {alpha: 0}, fadeTime);
		FlxTween.tween(stackLabel, {alpha: 0}, fadeTime);
		FlxTween.tween(stackText, {alpha: 0}, fadeTime);
		FlxTween.tween(btnReturn, {alpha: 0}, fadeTime);
		FlxTween.tween(btnReturnTxt, {alpha: 0}, fadeTime);
		FlxTween.tween(btnSave, {alpha: 0}, fadeTime);
		FlxTween.tween(btnSaveTxt, {alpha: 0}, fadeTime);
		FlxTween.tween(btnCopy, {alpha: 0}, fadeTime);
		FlxTween.tween(btnCopyTxt, {alpha: 0}, fadeTime);
		FlxTween.tween(saveCountdownTxt, {alpha: 0}, fadeTime);
		FlxTween.tween(reportHintTxt, {alpha: 0}, fadeTime);
		FlxTween.tween(reportUrlTxt, {alpha: 0}, fadeTime);
		FlxTween.tween(reportUrlUnderline, {alpha: 0}, fadeTime);
		FlxTween.tween(instructionsTxt, {alpha: 0}, fadeTime);
		FlxTween.tween(bg, {alpha: 0}, fadeTime);
		// savedConfirmTxt may be visible
		if (savedConfirmTxt.alpha > 0) FlxTween.tween(savedConfirmTxt, {alpha: 0}, fadeTime);

		FlxG.sound.play(Paths.sound('cancelMenu'));

		new FlxTimer().start(fadeTime + 0.05, function(_) {
			WeekData.loadTheFirstEnabledMod();
			PlayState.changedDifficulty = false;
			PlayState.replayMode = false;
			FlxG.sound.playMusic(Paths.music('freakyMenu'));
			MusicBeatState.switchState(new MainMenuState());
		});
	}

	// ================ Save report (with 5-second countdown) ================
	function saveReport()
	{
		if (saveState == 1)
		{
			// Already counting down — cancel instead
			cancelSaveCountdown();
			return;
		}
		if (saveState == 2)
		{
			// Already saved — show a brief hint
			savedConfirmTxt.text = Language.get("CrashCatcher.savedAlready", "Report already saved!");
			savedConfirmTxt.alpha = 1;
			FlxTween.tween(savedConfirmTxt, {alpha: 0}, 1.5);
			return;
		}

		// Start 5-second countdown
		saveState = 1;
		saveCountdown = 5;
		saveCountdownTxt.text = "5";
		saveCountdownTxt.alpha = 1;
		saveCountdownTxt.visible = true;
		centerTextOnButton(saveCountdownTxt, btnSave);
		btnSaveTxt.alpha = 0; // Hide button text while counting
		FlxG.sound.play(Paths.sound('scrollMenu'));
		updateButtonSelection();
	}

	// ================ Actually save the report to file ================
	function doSaveReport()
	{
		try
		{
			#if sys
			var dateNow:String = Date.now().toString();
			dateNow = dateNow.replace(" ", "_");
			dateNow = dateNow.replace(":", "'");
			// Same prefix as the other Haxe-layer dumps (Main.hx); native dumps stay native_crash_*.
			var path:String = "./crash/" + "SeiunEngine_" + dateNow + ".txt";

			if (!FileSystem.exists("./crash/"))
				FileSystem.createDirectory("./crash/");

			// Full report: error + stack + system/renderer/GPU info + recent logs + native crash logs
			var report:String = SystemDiag.buildCrashDump(lastCrashMessage, lastCrashStack, crashCount);
			report += "\nIf this crash happened during gameplay, consider including your replay file for debugging.\n";
			report += "Please report this error to the GitHub page: https://github.com/mohong2/FNF-SeiunEngine\n";
			report += "SeiunEngine by mo_hong\n";

			File.saveContent(path, report);

			btnSaveTxt.alpha = 1; // Restore button text

			var msg = Language.get("CrashCatcher.savedConfirm", "Report saved!") + "\n" + path;
			savedConfirmTxt.text = msg;
			savedConfirmTxt.alpha = 1;
			FlxTween.tween(savedConfirmTxt, {alpha: 0}, 5, {startDelay: 3});
			FlxG.sound.play(Paths.sound('confirmMenu'));

			// Auto-copy path hint: update instructions
			instructionsTxt.text = Language.get("CrashCatcher.instructionsSaved",
				"Report saved! ENTER: Return to menu  |  ESC: Return to menu");

			#else
			savedConfirmTxt.text = Language.get("CrashCatcher.savedFail", "Could not save report (unsupported platform).");
			savedConfirmTxt.alpha = 1;
			FlxTween.tween(savedConfirmTxt, {alpha: 0}, 3, {startDelay: 2});
			#end
		}
		catch(e:Dynamic)
		{
			TraceManager.error('trace.crashCatcher.saveFailed', 'CrashCatcherState - Failed to save report: {}', [e]);
			savedConfirmTxt.text = Language.get("CrashCatcher.savedFail", "Could not save report (unsupported platform).");
			savedConfirmTxt.alpha = 1;
			FlxTween.tween(savedConfirmTxt, {alpha: 0}, 3, {startDelay: 2});
			btnSaveTxt.alpha = 1;
		}
	}

	// ================ Easter egg messages ================
	function getEasterEgg(count:Int):String
	{
		if (count >= 50)
			return Language.get("CrashCatcher.egg50", "Are you... trying to break a record?");
		if (count >= 30)
			return Language.get("CrashCatcher.egg30", "You know what they say: insanity is doing the same thing over and over...");
		if (count >= 20)
			return Language.get("CrashCatcher.egg20", "How many more times are you going to crash?!");
		if (count >= 15)
			return Language.get("CrashCatcher.egg15", "At this point, just go play something else...");
		if (count >= 10)
			return Language.get("CrashCatcher.egg10", "I think you should take a break...");
		if (count >= 5)
			return Language.get("CrashCatcher.egg5", "Third time's the charm! ...Right?");
		if (count >= 3)
			return Language.get("CrashCatcher.egg3", "You might want to report this...");
		return "";
	}
}
