package mohong;

/**
 * Dialog type for TaskDialog/MessageBox. backend.Dialog defines its own
 * copy on non-Windows.
 */
enum abstract DialogType(Int) {
	var Info = 0;
	var Warning = 1;
	var Error = 2;
}

/**
 * Win32 helpers (dark mode, console, dialogs). No-ops off Windows.
 * Class exists everywhere: Main's desktop branch references it on mac/linux.
 */

#if (cpp && windows)
// Windows declarations must stay inside this class' own .cpp.
//
// They used to be injected with @:headerCode, i.e. into the generated
// "mohong/Windows.h". hxcpp includes every class header from __boot__.cpp, so
// that leaked windows.h (and with it OUT/TRANSPARENT/WAIT_FAILED/COLOR_*) into
// thousands of unrelated headers; as long as this class happened to be included
// last it went unnoticed, and the moment hxcpp picked a different order the next
// headers with a Haxe field of the same name stopped compiling (C2208/C2059).
// Scoping the include to the .cpp removes the whole class of failure, whatever
// order hxcpp decides on. backend/Dialog.hx and backend/NativeMem.hx, the only
// other files with raw Win32 code, carry their own copy of this block.
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
class Windows
{
	/**
	 * Dark title bar (DWM 19/20).
	 * No-op off Windows.
	 */
	public static function enableDarkMode():Void
	{
		#if (cpp && windows)
		untyped __cpp__('
		{
			HMODULE dwmapi = LoadLibraryA("dwmapi.dll");
			if (dwmapi)
			{
				typedef HRESULT (WINAPI *DwmSetWindowAttributeFunc)(HWND, DWORD, LPCVOID, DWORD);
				DwmSetWindowAttributeFunc DwmSetWindowAttribute = (DwmSetWindowAttributeFunc)GetProcAddress(dwmapi, "DwmSetWindowAttribute");
				if (DwmSetWindowAttribute)
				{
					HWND hwnd = GetActiveWindow();
					if (hwnd)
					{
						BOOL useDarkMode = 1;
						DwmSetWindowAttribute(hwnd, 20, &useDarkMode, sizeof(useDarkMode));
						DwmSetWindowAttribute(hwnd, 19, &useDarkMode, sizeof(useDarkMode));
					}
				}
				FreeLibrary(dwmapi);
			}
		}
		');
		#end
	}

	/**
	 * Whether *this process* allocated the console. A console inherited from the
	 * launching terminal is not ours, so the Trace Console option must not close it
	 * when it is switched off.
	 */
	public static var consoleOwned:Bool = false;

	/**
	 * Allocate a console. Returns success (true when one is already attached).
	 * false off Windows.
	 */
	public static function allocConsole():Bool
	{
		#if (cpp && windows)
		if (hasConsole()) return true;
		var ok:Bool = untyped __cpp__('AllocConsole() != 0');
		if (ok) consoleOwned = true;
		return ok;
		#else
		return false;
		#end
	}

	/**
	 * Free the console. Returns success.
	 * false off Windows.
	 */
	public static function freeConsole():Bool
	{
		#if (cpp && windows)
		var ok:Bool = untyped __cpp__('FreeConsole() != 0');
		if (ok) consoleOwned = false;
		return ok;
		#else
		return false;
		#end
	}

	/**
	 * Write UTF-8 to the console (WriteConsoleW).
	 * No-op off Windows.
	 */
	public static function writeConsole(text:String):Void
	{
		#if (cpp && windows)
		untyped __cpp__('
		{
			HANDLE hOut = GetStdHandle(STD_OUTPUT_HANDLE);
			if (hOut != INVALID_HANDLE_VALUE)
			{
				int wlen = MultiByteToWideChar(CP_UTF8, 0, {0}.c_str(), -1, NULL, 0);
				if (wlen > 0)
				{
					wchar_t* wbuf = (wchar_t*)alloca(wlen * sizeof(wchar_t));
					MultiByteToWideChar(CP_UTF8, 0, {0}.c_str(), -1, wbuf, wlen);
					DWORD written = 0;
					WriteConsoleW(hOut, wbuf, wlen - 1, &written, NULL);
				}
			}
		}
		', text);
		#end
	}

	/**
	 * Has a console?
	 * false off Windows.
	 */
	public static function hasConsole():Bool
	{
		#if (cpp && windows)
		return untyped __cpp__('GetConsoleWindow() != NULL');
		#else
		return false;
		#end
	}

	/**
	 * Free then allocate. Returns success.
	 * false off Windows.
	 */
	public static function reopenConsole():Bool
	{
		#if (cpp && windows)
		freeConsole();
		return allocConsole();
		#else
		return false;
		#end
	}

	/**
	 * Enable ANSI escapes.
	 * No-op off Windows.
	 */
	public static function enableAnsiColors():Void
	{
		#if (cpp && windows)
		untyped __cpp__('
		{
			HANDLE hOut = GetStdHandle(STD_OUTPUT_HANDLE);
			if (hOut != INVALID_HANDLE_VALUE)
			{
				DWORD dwMode = 0;
				if (GetConsoleMode(hOut, &dwMode))
				{
					dwMode |= 0x0004; // ENABLE_VIRTUAL_TERMINAL_PROCESSING
					SetConsoleMode(hOut, dwMode);
				}
			}
		}
		');
		#end
	}

	/**
	 * Native OK dialog (TaskDialog, fallback MessageBoxW).
	 * No-op off Windows.
	 */
	public static function showDialog(title:String, message:String, type:DialogType):Void
	{
		#if (cpp && windows)
		untyped __cpp__('
		{
			HWND hwnd = GetActiveWindow();

			const char* titleStr = {0}.c_str();
			const char* msgStr = {1}.c_str();
			int iconType = {2};

			int tLen = MultiByteToWideChar(CP_UTF8, 0, titleStr, -1, NULL, 0);
			int mLen = MultiByteToWideChar(CP_UTF8, 0, msgStr, -1, NULL, 0);

			WCHAR* tW = (WCHAR*)alloca(tLen * sizeof(WCHAR));
			WCHAR* mW = (WCHAR*)alloca(mLen * sizeof(WCHAR));

			MultiByteToWideChar(CP_UTF8, 0, titleStr, -1, tW, tLen);
			MultiByteToWideChar(CP_UTF8, 0, msgStr, -1, mW, mLen);

			// TD_*_ICON values: Info=-3, Warning=-1, Error=-2
			PCWSTR tdIcons[3] = {
				(PCWSTR)(ULONG_PTR)(WORD)(-3),
				(PCWSTR)(ULONG_PTR)(WORD)(-1),
				(PCWSTR)(ULONG_PTR)(WORD)(-2)
			};

			// MB_ICON* values
			UINT mbIcons[3] = {
				MB_ICONINFORMATION,
				MB_ICONWARNING,
				MB_ICONERROR
			};

			PCWSTR icon = (iconType >= 0 && iconType < 3) ? tdIcons[iconType] : NULL;
			UINT mbFlags = MB_OK | ((iconType >= 0 && iconType < 3) ? mbIcons[iconType] : 0);

			HMODULE comctl32 = LoadLibraryA("comctl32.dll");
			if (comctl32)
			{
				typedef HRESULT (WINAPI *TaskDialogFunc)(HWND, HINSTANCE, PCWSTR, PCWSTR, PCWSTR, int, PCWSTR, int*);
				TaskDialogFunc pTaskDialog = (TaskDialogFunc)GetProcAddress(comctl32, "TaskDialog");
				if (pTaskDialog)
				{
					int btn = 0;
					pTaskDialog(hwnd, NULL, tW, mW, NULL, 1, icon, &btn);
					FreeLibrary(comctl32);
					return;
				}
				FreeLibrary(comctl32);
			}

			MessageBoxW(hwnd, mW, tW, mbFlags);
		}
		', title, message, type);
		#end
	}

	/**
	 * Native Yes/No; true = Yes.
	 * true off Windows (callers gate it anyway).
	 *
	 * Temp var instead of return __cpp__: MSVC has no statement-expressions.
	 */
	public static function showYesNoMessageBox(title:String, message:String):Bool
	{
		#if (cpp && windows)
		var result:Bool = false;
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

			int mbResult = MessageBoxW(hwnd, mW, tW, MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2);
			{2} = (mbResult == IDYES);
		}
		', title, message, result);
		return result;
		#else
		return true;
		#end
	}
}
