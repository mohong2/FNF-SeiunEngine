package backend;

import haxe.CallStack;
import haxe.Exception;
import Language;

#if (cpp && windows)
import mohong.Windows;
import mohong.Windows.DialogType;
#elseif android
import android.Tools as AndroidTools;
#elseif (linux || mac)
import sys.io.Process;
#end

import flixel.FlxG;

#if (cpp && windows)
// showYesNoWindows() below is a raw Win32 snippet, and it used to get <windows.h>
// for free from mohong/Windows.h. That header no longer drags windows.h into every
// translation unit that includes it (see the comment in mohong/Windows.hx), so the
// declarations are provided here instead - scoped to this class' own .cpp.
@:cppFileCode('
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#undef ERROR
#undef FALSE
#undef TRUE
#undef NO_ERROR
#undef DELETE
#undef OUT
#undef IN
#undef TRANSPARENT
#undef WAIT_FAILED
#undef COLOR_HIGHLIGHT
')
#end

#if !(cpp && windows)
enum abstract DialogType(Int) {
	var Info = 0;
	var Warning = 1;
	var Error = 2;
}
#end

/**
 * Cross-platform dialog base class.
 * 跨平台弹窗基类。
 *
 * Windows: native TaskDialog/MessageBox (mohong.Windows)
 * Android: native alert (android.Tools)
 * Linux:   zenity -> kdialog -> xmessage -> in-game popup
 * macOS:   osascript (always available)
 * iOS/JS:  in-game popup / browser dialogs
 *
 * Example / 示例:
 * ```
 * Dialog.show("Title", "Message");
 * Dialog.show("Title", "Message", DialogType.Warning);
 * Dialog.showYesNo("Confirm", "Are you sure?", function() trace("Yes"), function() trace("No"));
 * ```
 */
class Dialog
{
	/**
	 * Show a simple OK dialog.
	 * 显示简单的确定弹窗。
	 */
	public static function show(title:String, message:String, type:String = 'Info'):Void
	{
		#if (cpp && windows)
		var dialogType:DialogType = DialogType.Info;
		switch(type) {
			case 'Warning': dialogType = DialogType.Warning;
			case 'Error': dialogType = DialogType.Error;
			default: dialogType = DialogType.Info;
		}
		Windows.showDialog(title, message, dialogType);
		#elseif android
		AndroidTools.showNativeAlertDialog(title, message, {name: Language.get('Dialog.ok', 'OK'), func: function() {}}, null, null, false);
		#elseif linux
		showLinux(title, message, type);
		#elseif mac
		showMac(title, message, type);
		#elseif js
		lime.app.Application.current.window.alert(message, title);
		#else
		showInGame(title, message, [Language.get('Dialog.ok', 'OK')], [null]);
		#end
	}

	/**
	 * Show a Yes/No confirmation dialog.
	 * 显示是/否确认弹窗。
	 */
	public static function showYesNo(title:String, message:String, onYes:Void->Void, onNo:Void->Void):Void
	{
		#if (cpp && windows)
		showYesNoWindows(title, message, onYes, onNo);
		#elseif android
		AndroidTools.showNativeAlertDialog(title, message,
			{name: Language.get('Dialog.yes', 'Yes'), func: onYes},
			{name: Language.get('Dialog.no', 'No'), func: onNo}, null, false);
		#elseif linux
		showYesNoLinux(title, message, onYes, onNo);
		#elseif mac
		showYesNoMac(title, message, onYes, onNo);
		#elseif js
		if (js.Browser.window.confirm('$title\n\n$message')) onYes() else onNo();
		#else
		showInGame(title, message, [Language.get('Dialog.yes', 'Yes'), Language.get('Dialog.no', 'No')], [onYes, onNo]);
		#end
	}

	/**
	 * Show a dialog with custom buttons.
	 * 显示带自定义按钮的弹窗。
	 */
	public static function showCustom(title:String, message:String, buttons:Array<{name:String, callback:Void->Void}>, ?cancelable:Bool = true):Void
	{
		#if android
		var pos:{name:String, func:Void->Void} = null;
		var neg:{name:String, func:Void->Void} = null;
		var neu:{name:String, func:Void->Void} = null;
		for (b in buttons)
		{
			if (pos == null) pos = {name: b.name, func: b.callback};
			else if (neg == null) neg = {name: b.name, func: b.callback};
			else if (neu == null) neu = {name: b.name, func: b.callback};
			else break;
		}
		AndroidTools.showNativeAlertDialog(title, message, pos, neg, neu, cancelable);
		#elseif (cpp && windows)
		showCustomWindows(title, message, buttons);
		#elseif linux
		showCustomLinux(title, message, buttons);
		#elseif mac
		showCustomMac(title, message, buttons);
		#elseif js
		var msg = '$title\n\n$message\n\n';
		for (i in 0...buttons.length) msg += '${i + 1}. ${buttons[i].name}\n';
		lime.app.Application.current.window.alert(msg, title);
		if (buttons.length > 0 && buttons[0].callback != null) buttons[0].callback();
		#else
		showInGame(title, message, [for (b in buttons) b.name], [for (b in buttons) b.callback]);
		#end
	}

	// -------------------------------------------------------------------------
	// Linux: zenity -> kdialog -> xmessage -> in-game popup
	// -------------------------------------------------------------------------
	#if linux
	static function showLinux(title:String, message:String, type:String):Void
	{
		if (commandExists('zenity'))
			runProcess(['zenity', '--' + linuxIcon(type), '--title=' + title, '--text=' + message, '--width=420']);
		else if (commandExists('kdialog'))
			runProcess(['kdialog', '--title', title, '--msgbox', message]);
		else if (commandExists('xmessage'))
			runProcess(['xmessage', '-center', title + '\n\n' + message]);
		else
			showInGame(title, message, [Language.get('Dialog.ok', 'OK')], [null]);
	}

	static function showYesNoLinux(title:String, message:String, onYes:Void->Void, onNo:Void->Void):Void
	{
		var yesLabel = Language.get('Dialog.yes', 'Yes');
		var noLabel = Language.get('Dialog.no', 'No');
		if (commandExists('zenity'))
		{
			var p = new Process('zenity', ['--question', '--title=' + title, '--text=' + message, '--ok-label=' + yesLabel, '--cancel-label=' + noLabel]);
			var yes = p.exitCode() == 0;
			p.close();
			if (yes) onYes() else onNo();
		}
		else if (commandExists('kdialog'))
		{
			var p = new Process('kdialog', ['--title', title, '--yesno', message]);
			var yes = p.exitCode() == 0;
			p.close();
			if (yes) onYes() else onNo();
		}
		else if (commandExists('xmessage'))
		{
			var p = new Process('xmessage', ['-center', '-buttons', yesLabel + ':0,' + noLabel + ':1', title + '\n\n' + message]);
			var yes = p.exitCode() == 0;
			p.close();
			if (yes) onYes() else onNo();
		}
		else
			showInGame(title, message, [yesLabel, noLabel], [onYes, onNo]);
	}

	static function showCustomLinux(title:String, message:String, buttons:Array<{name:String, callback:Void->Void}>):Void
	{
		var labels = [for (b in buttons) b.name];
		if (labels.length == 0) labels = [Language.get('Dialog.ok', 'OK')];

		if (labels.length <= 2 && commandExists('zenity'))
		{
			if (labels.length == 1)
			{
				runProcess(['zenity', '--info', '--title=' + title, '--text=' + message, '--ok-label=' + labels[0]]);
				if (buttons.length > 0 && buttons[0].callback != null) buttons[0].callback();
			}
			else
			{
				var p = new Process('zenity', ['--question', '--title=' + title, '--text=' + message,
					'--ok-label=' + labels[0], '--cancel-label=' + labels[1]]);
				var ok = p.exitCode() == 0;
				p.close();
				if (ok)
				{
					if (buttons[0].callback != null) buttons[0].callback();
				}
				else
				{
					if (buttons[1].callback != null) buttons[1].callback();
				}
			}
		}
		else
			showInGame(title, message, labels, [for (b in buttons) b.callback]);
	}

	static function linuxIcon(type:String):String
	{
		return switch(type) { case 'Warning': 'warning'; case 'Error': 'error'; default: 'info'; };
	}
	#end

	// -------------------------------------------------------------------------
	// macOS: osascript (always available on macOS)
	// -------------------------------------------------------------------------
	#if mac
	static function showMac(title:String, message:String, type:String):Void
	{
		var icon = switch(type) { case 'Warning': 'caution'; case 'Error': 'stop'; default: 'note'; };
		var okLabel = shellQuote(Language.get('Dialog.ok', 'OK'));
		var script = 'display dialog ' + shellQuote(message) + ' with title ' + shellQuote(title)
			+ ' buttons {' + okLabel + '} default button ' + okLabel + ' with icon ' + icon;
		runProcess(['osascript', '-e', script]);
	}

	static function showYesNoMac(title:String, message:String, onYes:Void->Void, onNo:Void->Void):Void
	{
		var yesLabel = shellQuote(Language.get('Dialog.yes', 'Yes'));
		var noLabel = shellQuote(Language.get('Dialog.no', 'No'));
		var script = 'display dialog ' + shellQuote(message) + ' with title ' + shellQuote(title)
			+ ' buttons {' + noLabel + ', ' + yesLabel + '} default button ' + yesLabel
			+ ' cancel button ' + noLabel + ' with icon caution';
		var p = new Process('osascript', ['-e', script]);
		var yes = p.exitCode() == 0;
		p.close();
		if (yes) onYes() else onNo();
	}

	static function showCustomMac(title:String, message:String, buttons:Array<{name:String, callback:Void->Void}>):Void
	{
		var labels = [for (b in buttons) b.name];
		if (labels.length == 0) labels = [Language.get('Dialog.ok', 'OK')];
		var script = 'display dialog ' + shellQuote(message) + ' with title ' + shellQuote(title)
			+ ' buttons {' + labels.map(shellQuote).join(', ') + '} default button ' + shellQuote(labels[0]);
		runProcess(['osascript', '-e', script]);
		if (buttons.length > 0 && buttons[0].callback != null) buttons[0].callback();
	}
	#end

	// -------------------------------------------------------------------------
	// Shared helpers (Linux + macOS)
	// -------------------------------------------------------------------------
	#if (linux || mac)
	static function commandExists(cmd:String):Bool
	{
		try {
			var p = new Process('sh', ['-c', 'command -v ' + cmd]);
			var found = p.exitCode() == 0;
			p.close();
			return found;
		} catch (e:Dynamic) {
			return false;
		}
	}

	static function runProcess(args:Array<String>):Void
	{
		try {
			var p = new Process(args[0], args.slice(1));
			p.exitCode();
			p.close();
		} catch (e:Dynamic) {}
	}

	static function shellQuote(s:String):String
	{
		return '"' + StringTools.replace(StringTools.replace(s, '\\', '\\\\'), '"', '\\"') + '"';
	}
	#end

	// -------------------------------------------------------------------------
	// In-game popup fallback (iOS / no external dialog tools available)
	// -------------------------------------------------------------------------
	static function showInGame(title:String, message:String, labels:Array<String>, callbacks:Array<Void->Void>):Void
	{
		try {
			if (FlxG.state == null)
			{
				trace('[Dialog] No state to attach popup, skipped: ' + title + ' - ' + message);
				return;
			}
			popup.DialogPopup.show(title, message, labels, callbacks);
		} catch (e:Dynamic) {
			trace('[Dialog] In-game popup failed: ' + e);
		}
	}

	// -------------------------------------------------------------------------
	// Windows-specific implementations
	// -------------------------------------------------------------------------
	#if (cpp && windows)
	private static function showYesNoWindows(title:String, message:String, onYes:Void->Void, onNo:Void->Void):Void
	{
		untyped __cpp__('
		{
			HWND hwnd = GetActiveWindow();

			const char* titleStr = {0}.c_str();
			const char* msgStr = {1}.c_str();

			int tLen = MultiByteToWideChar(CP_UTF8, 0, titleStr, -1, NULL, 0);
			int mLen = MultiByteToWideChar(CP_UTF8, 0, msgStr, -1, NULL, 0);

			WCHAR* tW = (WCHAR*)alloca(tLen * sizeof(WCHAR));
			WCHAR* mW = (WCHAR*)alloca(mLen * sizeof(WCHAR));

			MultiByteToWideChar(CP_UTF8, 0, titleStr, -1, tW, tLen);
			MultiByteToWideChar(CP_UTF8, 0, msgStr, -1, mW, mLen);

			int result = MessageBoxW(hwnd, mW, tW, MB_YESNO | MB_ICONQUESTION);

			if (result == IDYES)
			{
				{2}();
			}
			else
			{
				{3}();
			}
		}
		', title, message, onYes, onNo);
	}

	private static function showCustomWindows(title:String, message:String, buttons:Array<{name:String, callback:Void->Void}>):Void
	{
		// For Windows, fallback to MessageBox with OK button only for custom dialogs
		show(title, message, 'Info');
		if (buttons.length > 0 && buttons[0].callback != null) buttons[0].callback();
	}
	#end
}
