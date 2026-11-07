// SeiunEngine native crash hooks - included via @:cppInclude from NativeCrash.hx
// Windows: SetUnhandledExceptionFilter (SEH) + SIGABRT + LuaJIT panic hooks;
// POSIX (Linux/macOS/Android): sigaction for the fatal signals.
// All observers only: they write a log (+ one-shot pending marker), show a
// best-effort OS popup (desktop), mirror to logcat (Android), and then let the
// process die as before.
//
// Windows:
//  - fast-fail/abort() terminations (CRT asserts, pure virtual calls, LuaJIT's
//    default panic) bypass the unhandled exception filter entirely, so those
//    crashes used to leave no log at all. signal(SIGABRT) sees them.
//  - an unprotected error inside the Lua VM would print "PANIC: ..." and die
//    without any engine context. lua_atpanic() intercepts it, logging the Lua
//    error message and a backtrace before aborting.
//  - the SEH path records no call stack by itself. dbghelp (StackWalk64 +
//    SymFromAddr, loaded dynamically at crash time) prints one; with the build
//    PDB next to the exe the frames resolve to real function names/lines.
//
// Android (previously this platform logged only signal number + si_addr):
//  - sigaltstack + SA_ONSTACK: stack-overflow SIGSEGVs used to kill the signal
//    handler itself on the dead stack before anything was written.
//  - full register dump (PC/SP/LR/gprs) extracted from the kernel signal
//    context for arm64 / armv7 / x86_64 / x86.
//  - _Unwind_Backtrace from <unwind.h> (present for every NDK ABI) walks the
//    real crash chain; frames are annotated with dladdr() into the tombstone
//    format "pc <offset> <lib> (symbol+offset)", so `adb logcat | ndk-stack`
//    and offline llvm-symbolizer both work directly.
//  - crash/linemap support: a precomputed address->file:line table (built from
//    the unstripped .so by tools/crash.py linemap, pushed to the device or
//    embedded as an asset) is binary-searched at crash time, adding the exact
//    "[source/File.cpp:123]" for every frame inside the game library. This is
//    how the actual C++ line number gets into an on-device crash report.
//  - the whole body is mirrored to logcat (tag "SeiunEngine-Crash") so the
//    report survives even if the crash/ directory is unreachable.
//  - /proc/self/maps snapshot written next to the log (offsets for every
//    mapped module; needed for offline symbolication).
//  - device properties (model / Android version / ABI) and the engine context
//    fed from Haxe (app version, current state/song, recent log tail) are
//    embedded in the report.
//  - all crash-time file IO is open()/write() only (no stdio heap use).
//
// Everything is async-signal-safe to the extent practical for a crash logger:
// the base report (signal, registers, context, logs) hits the disk BEFORE any
// backtrace/symbol work that could itself fault on a corrupted process.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <signal.h>
#include <stdarg.h>

#if defined(_WIN32)
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  ifndef NOMINMAX
#    define NOMINMAX
#  endif
#  include <windows.h>
#  include <dbghelp.h>
#else
#  include <sys/stat.h>
#  include <sys/types.h>
#  include <fcntl.h>
#  include <unistd.h>
#  include <stdint.h>
#  include <dlfcn.h>
// MAX_PATH is a Windows constant, but the crash reporter sizes stack buffers
// from it on every platform (a Chinese install path plus a long file name still
// has to fit). POSIX libcs do not define it, so supply the same value here
// rather than guarding every use with #ifdef _WIN32.
#  ifndef MAX_PATH
#    define MAX_PATH 260
#  endif
#  if defined(__APPLE__)
#    include <TargetConditionals.h>
#  endif
#  if defined(__linux__) || defined(__APPLE__)
#    include <sys/ucontext.h>
#  endif
#  if defined(__ANDROID__)
#    include <sys/system_properties.h>
#  endif
// _Unwind_Backtrace comes from the compiler-rt/libgcc unwinder that is already
// linked into every C++ binary using exceptions; <unwind.h> is available in
// every NDK (clang resource include dir) and on desktop Linux/macOS.
#  if defined(__has_include)
#    if __has_include(<unwind.h>)
#      define SEIUN_HAS_UNWIND 1
#      include <unwind.h>
#    endif
#  endif
#  if !defined(__ANDROID__)
#    include <execinfo.h>
#  endif
#endif

// ── UTF-8 <-> UTF-16 exactly at the Windows API boundary ─────────────────────

// Every string in this file is UTF-8: that is what hxString::__CStr() returns and
// what the Haxe layer hands us. Windows' *A APIs decode their input with the
// process ANSI code page instead, so a Chinese install path ("O:\测试 中文\")
// either produced mojibake in a MessageBoxA or made fopen()/CreateDirectoryA()
// fail and the crash report vanished completely. The *W APIs take UTF-16, so the
// conversion happens only here, at the boundary:
//   internal UTF-8  ->  MultiByteToWideChar(CP_UTF8)  ->  *W API
//
// Conversions write into caller-provided stack buffers on purpose: the same
// helpers run inside the SEH/signal handlers, where malloc is not safe.
#if defined(_WIN32)
static int seiun_utf8_to_utf16(const char* src, wchar_t* dst, int dstCount)
{
	if (src == NULL || dst == NULL || dstCount <= 0)
		return 0;
	int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, src, -1, dst, dstCount);
	if (n == 0)
	{
		// Strict conversion failed (truncated/invalid tail). A lossy path is still
		// infinitely better than writing the crash report nowhere at all.
		n = MultiByteToWideChar(CP_UTF8, 0, src, -1, dst, dstCount);
	}
	return n > 0;
}

static int seiun_utf16_to_utf8(const wchar_t* src, char* dst, size_t dstCount)
{
	if (src == NULL || dst == NULL || dstCount == 0)
		return 0;
	dst[0] = 0;
	if (WideCharToMultiByte(CP_UTF8, 0, src, -1, dst, (int)dstCount, NULL, NULL) <= 0)
	{
		dst[0] = 0;
		return 0;
	}
	return 1;
}

// _wfopen() for a UTF-8 path. Callers keep the "w" text mode the reports always
// used, so the file still has CRLF line endings; the UTF-8 BOM is written by the
// report writer itself.
static FILE* seiun_fopen_utf8(const char* path, const wchar_t* mode)
{
	wchar_t wpath[1024];
	if (!seiun_utf8_to_utf16(path, wpath, (int)(sizeof(wpath) / sizeof(wpath[0]))))
		return NULL;
	return _wfopen(wpath, mode);
}

// UTF-8 path of a loaded module (GetModuleFileNameA would mangle/cut a Chinese
// path - the reports name the exe, the PDB and the faulting module).
static DWORD seiun_module_file_name_utf8(HMODULE module, char* out, size_t outCap)
{
	if (out == NULL || outCap == 0)
		return 0;
	out[0] = 0;
	wchar_t wpath[MAX_PATH * 2];
	DWORD len = GetModuleFileNameW(module, wpath, (DWORD)(sizeof(wpath) / sizeof(wpath[0])));
	if (len == 0)
		return 0;
	if (!seiun_utf16_to_utf8(wpath, out, outCap))
		return 0;
	return (DWORD)strlen(out);
}

// Open an existing file for reading, UTF-8 path (the PDB next to a Chinese-named
// install directory used to be reported as missing).
static HANDLE seiun_create_file_read_utf8(const char* path)
{
	wchar_t wpath[1024];
	if (!seiun_utf8_to_utf16(path, wpath, (int)(sizeof(wpath) / sizeof(wpath[0]))))
		return INVALID_HANDLE_VALUE;
	return CreateFileW(wpath, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
		OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
}
#endif

#if defined(_WIN32)
static const char* seiun_exception_name(unsigned long code)
{
	switch (code)
	{
		case 0xC0000005UL: return "ACCESS_VIOLATION";
		case 0xC0000006UL: return "IN_PAGE_ERROR";
		case 0xC000000DUL: return "ILLEGAL_INSTRUCTION";
		case 0xC0000094UL: return "INTEGER_DIVIDE_BY_ZERO";
		case 0xC0000095UL: return "INTEGER_OVERFLOW";
		case 0xC00000FDUL: return "STACK_OVERFLOW";
		case 0xC0000409UL: return "STACK_BUFFER_OVERRUN";
		case 0x80000003UL: return "BREAKPOINT";
		case 0xC0000135UL: return "DLL_NOT_FOUND";
		default: return "UNKNOWN";
	}
}
#else
static const char* seiun_signal_name(int sig)
{
	switch (sig)
	{
		case SIGSEGV: return "SIGSEGV (segmentation fault / access violation)";
		case SIGABRT: return "SIGABRT (abort, e.g. LuaJIT panic / assert)";
		case SIGBUS: return "SIGBUS (bus error / misaligned access)";
		case SIGFPE: return "SIGFPE (arithmetic / floating point error)";
		case SIGILL: return "SIGILL (illegal instruction)";
		default: return "SIGNAL";
	}
}

static const char* seiun_sigcode_name(int sig, int code)
{
	if (sig == SIGSEGV)
	{
		switch (code)
		{
			case SEGV_MAPERR: return "SEGV_MAPERR (address not mapped to object)";
			case SEGV_ACCERR: return "SEGV_ACCERR (invalid permissions for mapped object)";
			default: return "unknown SEGV code";
		}
	}
	if (sig == SIGBUS)
	{
		switch (code)
		{
			case BUS_ADRALN: return "BUS_ADRALN (invalid address alignment)";
			case BUS_ADRERR: return "BUS_ADRERR (non-existent physical address)";
			case BUS_OBJERR: return "BUS_OBJERR (object-specific hardware error)";
			default: return "unknown BUS code";
		}
	}
	if (sig == SIGFPE)
	{
		switch (code)
		{
			case FPE_INTDIV: return "FPE_INTDIV (integer divide by zero)";
			case FPE_INTOVF: return "FPE_INTOVF (integer overflow)";
			case FPE_FLTDIV: return "FPE_FLTDIV (float divide by zero)";
			case FPE_FLTOVF: return "FPE_FLTOVF (float overflow)";
			case FPE_FLTUND: return "FPE_FLTUND (float underflow)";
			case FPE_FLTRES: return "FPE_FLTRES (float inexact result)";
			case FPE_FLTINV: return "FPE_FLTINV (invalid float operation)";
			default: return "unknown FPE code";
		}
	}
	if (sig == SIGILL)
	{
		switch (code)
		{
			case ILL_ILLOPC: return "ILL_ILLOPC (illegal opcode)";
			case ILL_ILLOPN: return "ILL_ILLOPN (illegal operand)";
			case ILL_ILLADR: return "ILL_ILLADR (illegal addressing mode)";
			default: return "unknown ILL code";
		}
	}
	return "unknown si_code";
}
#endif

// ── engine-injected context (fed from Haxe, normal execution context) ───────

static char seiun_dir[512];          // absolute crash dir with trailing slash, or ""
static char seiun_app_info[256];     // "SeiunEngine <version> (<platform>)"
static char seiun_ctx_line[512];     // "state=... | song=... | glErr=..."
static char seiun_recent_logs[32768]; // TraceManager tail
static char seiun_build_info[256];    // "built=... | exe=... | map=..." (Haxe-fed)
static char seiun_env_info[512];      // "OS=... | GPU=... | driver=..." (Haxe-fed)

void seiun_set_crash_dir(const char* dir)
{
	if (dir == NULL || dir[0] == 0) return;
	size_t l = strlen(dir);
	if (l >= sizeof(seiun_dir) - 48) return;
	memcpy(seiun_dir, dir, l + 1);

	// Publish the directory to the other module of this process: lime.ndll is a
	// separate shared library with its own copy of this logic, and it cannot call
	// back into the exe (see .haxelib/lime/git/project/src/utils/FatalReport.cpp).
	// The environment is inherited by every later LoadLibrary/dlopen in this
	// process, so both sides write into the same folder - including the Android
	// external storage root, which the ndll could not otherwise know.
#if defined(_WIN32)
	{
		wchar_t wdir[1024];
		if (seiun_utf8_to_utf16(seiun_dir, wdir, (int)(sizeof(wdir) / sizeof(wdir[0]))))
			SetEnvironmentVariableW(L"SEIUN_CRASH_DIR", wdir);
	}
#else
	setenv("SEIUN_CRASH_DIR", seiun_dir, 1);
#endif
}

void seiun_set_app_info(const char* info)
{
	if (info == NULL) return;
	size_t l = strlen(info);
	if (l >= sizeof(seiun_app_info)) l = sizeof(seiun_app_info) - 1;
	memcpy(seiun_app_info, info, l);
	seiun_app_info[l] = 0;
}

void seiun_set_runtime_context(const char* ctx)
{
	if (ctx == NULL) return;
	size_t l = strlen(ctx);
	if (l >= sizeof(seiun_ctx_line)) l = sizeof(seiun_ctx_line) - 1;
	memcpy(seiun_ctx_line, ctx, l);
	seiun_ctx_line[l] = 0;
}

/**
 * OS / GPU / driver identity fed from Haxe (SystemDiag already collects it from
 * the live GL context). Written into fatal reports: the C++ layer can query the
 * OS itself, but not the renderer it may have failed to create.
 */
void seiun_set_env_info(const char* info)
{
	if (info == NULL) return;
	size_t l = strlen(info);
	if (l >= sizeof(seiun_env_info)) l = sizeof(seiun_env_info) - 1;
	memcpy(seiun_env_info, info, l);
	seiun_env_info[l] = 0;
}

void seiun_set_recent_logs(const char* logs)
{
	if (logs == NULL) return;
	size_t l = strlen(logs);
	if (l >= sizeof(seiun_recent_logs)) l = sizeof(seiun_recent_logs) - 1;
	memcpy(seiun_recent_logs, logs, l);
	seiun_recent_logs[l] = 0;
}

/**
 * Build fingerprint fed from Haxe (exe/PDB paths + mtimes + hashes).
 *
 * A crash log is only useful if it can be tied to the exact build that produced
 * it: the offsets in the report must be resolved against the PDB that matches
 * that exe. Reports used to carry no build identity at all, so a log could
 * silently predate several relinks and be symbolized against the wrong PDB.
 */
void seiun_set_build_info(const char* info)
{
	if (info == NULL) return;
	size_t l = strlen(info);
	if (l >= sizeof(seiun_build_info)) l = sizeof(seiun_build_info) - 1;
	memcpy(seiun_build_info, info, l);
	seiun_build_info[l] = 0;
}

/**
 * Appends one identity fragment to the build fingerprint instead of replacing
 * it. The Haxe layer calls this right after a linemap is installed, so a report
 * can state which address->line table produced its "[source/File.cpp:123]"
 * frames. The fragment is dropped (never truncated) when the buffer is full.
 */
void seiun_append_build_info(const char* part)
{
	if (part == NULL || part[0] == 0) return;
	size_t used = strlen(seiun_build_info);
	size_t add = strlen(part);
	if (used + (used ? 3 : 0) + add >= sizeof(seiun_build_info)) return;
	if (used)
	{
		memcpy(seiun_build_info + used, " | ", 3);
		used += 3;
	}
	memcpy(seiun_build_info + used, part, add + 1);
}

// CPU ABI of the running build (compile-time constant, NOT the device's
// primary ABI - an armeabi-v7a build on an arm64 device must still resolve to
// the armeabi-v7a linemap). Used by the Haxe layer to pick the matching
// linemap file (on Windows the linemap is named "windows-x64").
const char* seiun_get_cpu_abi(void)
{
#if defined(__ANDROID__)
	#if defined(__aarch64__)
		return "arm64-v8a";
	#elif defined(__arm__)
		return "armeabi-v7a";
	#elif defined(__x86_64__)
		return "x86_64";
	#elif defined(__i386__)
		return "x86";
	#else
		return "unknown";
	#endif
#elif defined(_WIN64)
	return "windows-x64";
#elif defined(_WIN32)
	return "windows-x86";
#elif defined(__APPLE__)
	// Apple platforms: the ABI selects the per-arch library and symbols artifact.
	#if defined(__aarch64__) || defined(__arm64__)
		return "apple-arm64";
	#elif defined(__x86_64__)
		return "apple-x86_64";
	#elif defined(__arm__)
		return "apple-armv7";
	#else
		return "apple-unknown";
	#endif
#else
	return "unknown";
#endif
}

// ── crash linemap (precomputed DWARF line table, see tools/crash.py linemap) ──
//
// Binary format (little endian):
//   magic 'SELM', u32 version, u32 entry_count, u32 str_table_offset
//   entries[entry_count]: { u32 rel_addr, u32 line, u32 str_off }  (sorted by rel_addr)
//   string table (NUL-terminated file paths)
// rel_addr is relative to the module load base (dladdr dli_fbase).
// Entries with line==0 are "no source info" terminators; the binary search
// returns the last entry with rel_addr <= pc, which is exact because the
// generator emits a row at every file:line change and at every sequence end.
// Defined on every platform (cheap no-op on Windows where PDB lines exist) so
// the Haxe call sites link everywhere.

static const unsigned char* seiun_linemap = NULL;
static unsigned int seiun_linemap_len = 0;
static char seiun_linemap_lib[96] = {0};

void seiun_set_linemap(const void* data, unsigned int len, const char* libName)
{
	if (data == NULL || len < 16) return;
	if (libName == NULL || libName[0] == 0) return;
	size_t ll = strlen(libName);
	if (ll >= sizeof(seiun_linemap_lib)) ll = sizeof(seiun_linemap_lib) - 1;
	seiun_linemap = (const unsigned char*)data;
	seiun_linemap_len = len;
	memcpy(seiun_linemap_lib, libName, ll);
	seiun_linemap_lib[ll] = 0;
}

static unsigned int seiun_lm_u32(const unsigned char* p)
{
	return (unsigned int)p[0] | ((unsigned int)p[1] << 8) |
	       ((unsigned int)p[2] << 16) | ((unsigned int)p[3] << 24);
}

// Returns 1 and fills out with "<file>:<line>" when a source row was found.
static int seiun_linemap_lookup(unsigned int off, char* out, size_t cap)
{
	out[0] = 0;
	if (seiun_linemap == NULL || seiun_linemap_len < 20) return 0;
	const unsigned char* b = seiun_linemap;
	if (b[0] != 'S' || b[1] != 'E' || b[2] != 'L' || b[3] != 'M') return 0;
	unsigned int n = seiun_lm_u32(b + 8);
	unsigned int strOff = seiun_lm_u32(b + 12);
	if (n == 0 || strOff == 0 || strOff >= seiun_linemap_len) return 0;
	// binary search: last entry with rel_addr <= off
	unsigned int lo = 0, hi = n;
	while (lo + 1 < hi)
	{
		unsigned int mid = lo + (hi - lo) / 2;
		if (seiun_lm_u32(b + 16 + (size_t)mid * 12) <= off) lo = mid; else hi = mid;
	}
	if (seiun_lm_u32(b + 16 + (size_t)lo * 12) > off) return 0;
	unsigned int line = seiun_lm_u32(b + 16 + (size_t)lo * 12 + 4);
	unsigned int so = seiun_lm_u32(b + 16 + (size_t)lo * 12 + 8);
	if (line == 0) return 0;
	if (strOff + so >= seiun_linemap_len) return 0;
	const char* file = (const char*)(b + strOff + so);
	snprintf(out, cap, "%s:%u", file, (unsigned)line);
	return 1;
}

// ── shared output helpers ────────────────────────────────────────────────────

// Single crash buffer + single crash path; only one handler ever runs (the
// first to win the crash flag). The path is computed once so multi-phase
// writes (basic info first, enhanced log after) land on the same file.
static char seiun_body[65536];
static char seiun_path[512];

#if defined(_WIN32)
static volatile LONG seiun_crash_written = 0;
#else
static volatile sig_atomic_t seiun_crash_written = 0;
#endif

// Create <dir> and every missing parent ("<storage>/crash/" on a fresh profile).
// Component-wise, with the wide API, so a Chinese directory really appears.
static void seiun_ensure_crash_dir(void)
{
	const char* dir = seiun_dir[0] ? seiun_dir : "crash";
#if defined(_WIN32)
	wchar_t wdir[1024];
	if (!seiun_utf8_to_utf16(dir, wdir, (int)(sizeof(wdir) / sizeof(wdir[0]))))
		return;
	for (wchar_t* p = wdir + 1; *p; ++p)
	{
		if (*p != L'\\' && *p != L'/')
			continue;
		if (*(p - 1) == L':') // keep the drive prefix ("O:") intact
			continue;
		wchar_t saved = *p;
		*p = 0;
		CreateDirectoryW(wdir, NULL);
		*p = saved;
	}
	CreateDirectoryW(wdir, NULL);
#else
	char tmp[sizeof(seiun_dir) + 8];
	snprintf(tmp, sizeof(tmp), "%s", dir);
	for (char* p = tmp + 1; *p; ++p)
	{
		if (*p != '/')
			continue;
		*p = 0;
		mkdir(tmp, 0755);
		*p = '/';
	}
	mkdir(tmp, 0755);
#endif
}

/**
 * Report path builder: "<crash dir>/<prefix>_YYYYMMDD_HHMMSS.txt".
 * The prefix is what tools/crash.py keys on, so every writer passes the
 * one its reports have always used ("native_crash" for native faults,
 * "SeiunEngine_..." from the Haxe layer and the fatal funnel).
 */
static void seiun_make_path(char* path, size_t n, const char* prefix)
{
	time_t t = time(NULL);
	struct tm tmv;
#if defined(_WIN32)
	localtime_s(&tmv, &t);
#else
	localtime_r(&t, &tmv);
#endif
	seiun_ensure_crash_dir();
	snprintf(path, n, "%s%s_%04d%02d%02d_%02d%02d%02d.txt",
		seiun_dir[0] ? seiun_dir : "crash/",
		prefix,
		tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday, tmv.tm_hour, tmv.tm_min, tmv.tm_sec);
}

static void seiun_crash_path(char* path, size_t n)
{
	seiun_make_path(path, n, "native_crash");
}

static const char* seiun_crash_file(void)
{
	if (seiun_path[0] == 0)
		seiun_crash_path(seiun_path, sizeof(seiun_path));
	return seiun_path;
}

// Engine context (app version / state / recent log tail) shared by every
// handler so a below-Haxe crash still carries the gameplay situation.
static void seiun_append(char* buf, size_t cap, int* len, const char* fmt, ...);
static void seiun_append_engine_context(char* buf, size_t cap, int* len)
{
	seiun_append(buf, cap, len, "\n--- Engine context ---\n");
	if (seiun_app_info[0])
		seiun_append(buf, cap, len, "App: %s\n", seiun_app_info);
	if (seiun_ctx_line[0])
		seiun_append(buf, cap, len, "Context: %s\n", seiun_ctx_line);
#if !defined(_WIN32)
	// Build fingerprint (abi / .so name / size / mtime / hash, plus the loaded
	// linemap identity). The Windows path prints the same line from
	// seiun_append_build_identity, so it is deliberately POSIX-only here to keep
	// the Windows report byte-for-byte unchanged.
	if (seiun_build_info[0])
		seiun_append(buf, cap, len, "Build: %s\n", seiun_build_info);
#endif
	if (seiun_recent_logs[0])
		seiun_append(buf, cap, len, "Recent engine logs (tail, newest last):\n%s\n\n", seiun_recent_logs);
}

// vsnprintf-based append that never lets the running length pass the buffer.
static void seiun_append(char* buf, size_t cap, int* len, const char* fmt, ...)
{
	if (*len < 0 || (size_t)*len >= cap)
		return;
	va_list ap;
	va_start(ap, fmt);
	int l = vsnprintf(buf + *len, cap - (size_t)*len, fmt, ap);
	va_end(ap);
	if (l < 0)
		return;
	if ((size_t)*len + (size_t)l >= cap)
	{
		*len = (int)cap - 1;
		return;
	}
	*len += l;
}

/**
 * The one actionable block: which tool turns the "module+offset" frames above
 * into source lines. Kept in one place so every report path - Windows SEH,
 * abort(), the LuaJIT panic and the POSIX signal handler - says the same thing,
 * and so it can be updated without hunting four call sites.
 */
static void seiun_append_triage(char* buf, size_t cap, int* len)
{
#if defined(_WIN32)
	seiun_append(buf, cap, len,
		"\n--- Triage ---\n"
		"tools\\diag report <this report>    (checks the build fingerprint, then resolves)\n"
		"map      : export/symbols/windows-<mode>/ApplicationMain.map\n"
		"manifest : export/symbols/windows-<mode>/build.json  (exe size + PE TimeDateStamp)\n"
		"manual   : python tools/crash.py resolve <map> <offset from the backtrace>\n"
		"check it : python tools/crash.py verify-map SeiunEngine.exe <map>\n");
#elif defined(__ANDROID__)
	seiun_append(buf, cap, len,
		"\n--- Triage ---\n"
		"python tools/crash.py symbolize <this report>       (matches the build, uses the unstripped .so)\n"
		"symbols  : export/symbols/android-<mode>/libApplicationMain*.so\n"
		"manual   : ndk-stack -sym <that directory> -dump <this report>\n"
		"A [source/File.cpp:123] suffix came from the linemap embedded in this build; if the\n"
		"tool disagrees with one, that embedded table is stale (build twice to refresh it).\n");
#else
	seiun_append(buf, cap, len,
		"\n--- Triage ---\n"
		"names only: export/<mode>/linux/obj/ApplicationMain has .symtab but no DWARF\n"
		"manual    : addr2line -f -C -e <that binary> <offset from the backtrace>\n");
#endif
}

static void seiun_mark_crash_pending(void);

/**
 * Opens every crash file with the same three lines, so the Windows SEH dump, the
 * abort() path, the LuaJIT panic and the POSIX signal handler all read (and
 * parse, see tools/crash.py) exactly the same way.
 */
static void seiun_append_report_header(char* buf, size_t cap, int* len, const char* kind)
{
	time_t t = time(NULL);
	struct tm tmv;
#if defined(_WIN32)
	localtime_s(&tmv, &t);
#else
	localtime_r(&t, &tmv);
#endif
	seiun_append(buf, cap, len, "=== SeiunEngine Crash Report ===\n");
	seiun_append(buf, cap, len, "Kind: %s\n", kind);
	seiun_append(buf, cap, len, "Date: %04d-%02d-%02d %02d:%02d:%02d\n",
		tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday, tmv.tm_hour, tmv.tm_min, tmv.tm_sec);
}

#if defined(_WIN32)
// UTF-8 BOM first: Notepad and every report reader then decode the Chinese text
// in these files correctly instead of falling back to the ANSI code page.
static const char seiun_utf8_bom[3] = { (char)0xEF, (char)0xBB, (char)0xBF };

static void seiun_write_crash_file_at(const char* path, const char* body)
{
	FILE* f = seiun_fopen_utf8(path, L"w");
	if (f != NULL)
	{
		fwrite(seiun_utf8_bom, 1, sizeof(seiun_utf8_bom), f);
		fputs(body, f);
		fclose(f);
	}
}

static void seiun_write_crash_file(const char* body)
{
	seiun_write_crash_file_at(seiun_crash_file(), body);
	seiun_mark_crash_pending();
}
#else
// POSIX: fd-based writes only (stdio may allocate; the heap can be corrupted).
static void seiun_write_fd(const char* path, const char* body, size_t len, int append)
{
	int fd = open(path, O_WRONLY | O_CREAT | (append ? O_APPEND : O_TRUNC), 0644);
	if (fd < 0) return;
	const char* p = body;
	while (len > 0)
	{
		ssize_t w = write(fd, p, len);
		if (w <= 0) break;
		p += w;
		len -= (size_t)w;
	}
	close(fd);
}

// POSIX counterpart of seiun_write_crash_file_at: same BOM, explicit path.
static void seiun_write_crash_file_at(const char* path, const char* body)
{
	static const char bom[3] = { (char)0xEF, (char)0xBB, (char)0xBF };
	seiun_write_fd(path, bom, sizeof(bom), 0);
	seiun_write_fd(path, body, strlen(body), 1);
}

static void seiun_write_crash_file_fd(const char* body, size_t len, int append)
{
	if (!append)
	{
		// Same UTF-8 BOM as the Windows path (POSIX readers are byte-oriented,
		// but the reports are copied between platforms).
		static const char bom[3] = { (char)0xEF, (char)0xBB, (char)0xBF };
		seiun_write_fd(seiun_crash_file(), bom, sizeof(bom), 0);
		append = 1;
	}
	seiun_write_fd(seiun_crash_file(), body, len, append);
	seiun_mark_crash_pending();
}
#endif

// A one-shot marker for the Haxe layer: the native handler cannot safely run
// FlxG / CrashCatcherState itself, so the next launch consumes this file and
// shows the existing crash-catcher recovery screen (a graceful "rollback").
static void seiun_mark_crash_pending_at(const char* crashPath)
{
	char mpath[600];
	if (seiun_dir[0])
		snprintf(mpath, sizeof(mpath), "%snative_crash.pending", seiun_dir);
	else
		snprintf(mpath, sizeof(mpath), "crash/native_crash.pending");
#if defined(_WIN32)
	FILE* f = seiun_fopen_utf8(mpath, L"w");
	if (f != NULL)
	{
		if (crashPath != NULL && crashPath[0] != 0)
			fputs(crashPath, f);
		fputc('\n', f);
		fclose(f);
	}
#else
	char mbody[600];
	int ml = 0;
	if (crashPath != NULL && crashPath[0] != 0)
		seiun_append(mbody, sizeof(mbody), &ml, "%s\n", crashPath);
	else
		seiun_append(mbody, sizeof(mbody), &ml, "\n");
	seiun_write_fd(mpath, mbody, (size_t)ml, 0);
#endif
}

static void seiun_mark_crash_pending(void)
{
	seiun_mark_crash_pending_at(seiun_path);
}

// Best-effort OS popup. The process is already fatally broken, so failure is
// intentionally silent; after the popup the original crash path continues.
// (Android intentionally has none - the logcat mirror + next-launch recovery
// screen are the user-visible surface there.)
static void seiun_native_crash_popup(const char* path)
{
#if defined(_WIN32)
	// UTF-16 end to end (MessageBoxW + a converted buffer): MessageBoxA decoded
	// the UTF-8 body with the ANSI code page, so every Chinese character in this
	// box came out as mojibake.
	// Deliberately no TaskDialog/LoadLibrary here - this runs inside the SEH
	// handler, where loading a new module is exactly what must be avoided.
	char msg[2048];
	snprintf(msg, sizeof(msg),
		"SeiunEngine 检测到原生崩溃 / A native crash has been recorded.\r\n\r\n"
		"游戏即将退出。崩溃报告已保存到 / The game will now exit. Report:\r\n%s\r\n\r\n"
		"请把这份报告发给开发者 / Please send this report to the developers.",
		path);
	wchar_t wmsg[2048];
	wchar_t wtitle[128];
	if (seiun_utf8_to_utf16(msg, wmsg, (int)(sizeof(wmsg) / sizeof(wmsg[0]))) &&
		seiun_utf8_to_utf16("SeiunEngine 原生崩溃 / Native crash", wtitle, (int)(sizeof(wtitle) / sizeof(wtitle[0]))))
		MessageBoxW(NULL, wmsg, wtitle, MB_OK | MB_ICONERROR | MB_TOPMOST);
#elif defined(__APPLE__) && defined(TARGET_OS_IPHONE) && !TARGET_OS_IPHONE
	char text[1024];
	snprintf(text, sizeof(text),
		"SeiunEngine 检测到原生崩溃 / A native crash has been recorded.\n\n"
		"崩溃报告 / Report: %s\n\n游戏即将退出 / The game will now exit.", path);
	char script[2048];
	snprintf(script, sizeof(script),
		"display alert \"SeiunEngine native crash\" message \"%s\" as critical", text);
	pid_t pid = fork();
	if (pid == 0)
	{
		execl("/usr/bin/osascript", "osascript", "-e", script, (char*)NULL);
		_exit(127);
	}
#elif defined(__linux__) && !defined(__ANDROID__)
	char text[1024];
	snprintf(text, sizeof(text),
		"SeiunEngine 检测到原生崩溃 / A native crash has been recorded.\n\n"
		"崩溃报告 / Report: %s\n\n游戏即将退出 / The game will now exit.", path);
	char zenityText[1024];
	snprintf(zenityText, sizeof(zenityText), "--text=%s", text);
	char xmessageText[1024];
	snprintf(xmessageText, sizeof(xmessageText), "SeiunEngine native crash\n\n%s", text);
	pid_t pid = fork();
	if (pid == 0)
	{
		execlp("zenity", "zenity", "--error", "--title=SeiunEngine native crash", zenityText, (char*)NULL);
		execlp("kdialog", "kdialog", "--error", text, (char*)NULL);
		execlp("xmessage", "xmessage", "-center", xmessageText, (char*)NULL);
		_exit(127);
	}
#else
	(void)path;
#endif
}

// ── Android extras: logcat mirror + device properties ───────────────────────

#if defined(__ANDROID__)
typedef int (*seiun_logprint_fn)(int prio, const char* tag, const char* fmt, ...);
static seiun_logprint_fn seiun_log_print = NULL;
#define SEIUN_LOGCAT_TAG "SeiunEngine-Crash"

// Resolved once at install time (dlopen inside a signal handler is not safe).
static void seiun_logcat_init(void)
{
	void* h = dlopen("liblog.so", RTLD_NOW | RTLD_LOCAL);
	if (h != NULL)
		seiun_log_print = (seiun_logprint_fn)dlsym(h, "__android_log_print");
}

// Mirror the whole report to logcat, line by line (logcat truncates long
// entries). Called strictly after the file + pending marker are on disk.
static void seiun_logcat_mirror(const char* body)
{
	if (seiun_log_print == NULL) return;
	const char* p = body;
	char chunk[1024];
	while (*p)
	{
		const char* nl = strchr(p, '\n');
		size_t l = nl ? (size_t)(nl - p) : strlen(p);
		if (l == 0) { p++; continue; }
		if (l > sizeof(chunk) - 1) l = sizeof(chunk) - 1;
		memcpy(chunk, p, l);
		chunk[l] = 0;
		seiun_log_print(6 /*ANDROID_LOG_ERROR*/, SEIUN_LOGCAT_TAG, "%s", chunk);
		p += nl ? (size_t)(nl - p) + 1 : l;
	}
}

static void seiun_write_android_props(char* buf, size_t cap, int* len)
{
	char model[92] = {0}, manuf[92] = {0}, release[92] = {0}, sdk[92] = {0}, fp[128] = {0};
	__system_property_get("ro.product.model", model);
	__system_property_get("ro.product.manufacturer", manuf);
	__system_property_get("ro.build.version.release", release);
	__system_property_get("ro.build.version.sdk", sdk);
	__system_property_get("ro.build.fingerprint", fp);
	seiun_append(buf, cap, len, "Device: %s %s | Android %s (API %s) | ABI: %s\n",
		manuf[0] ? manuf : "?", model[0] ? model : "?",
		release[0] ? release : "?", sdk[0] ? sdk : "?", seiun_get_cpu_abi());
	seiun_append(buf, cap, len, "Build fingerprint: %s\n", fp[0] ? fp : "?");
}
#endif // __ANDROID__

// ── POSIX: register dump + backtrace ────────────────────────────────────────

#if !defined(_WIN32)

// Per-arch register dump from the kernel signal context; also returns the
// faulting PC via outPc.
static uintptr_t seiun_write_registers(char* buf, size_t cap, int* len, void* uctx)
{
	uintptr_t pc = 0;
	if (uctx == NULL) return 0;
#if defined(__APPLE__) && (defined(__aarch64__) || defined(__x86_64__))
	ucontext_t* uc = (ucontext_t*)uctx;
  #if defined(__aarch64__)
	// Only stable fields are used here (__fp/__lr became opaque pointers in
	// recent macOS SDKs).
	// SDK names the struct __darwin_arm_thread_state64 (mach/arm/_structs.h);
	// there is no __darwin_arm_thread_state64_t typedef.
	const struct __darwin_arm_thread_state64* ss = &uc->uc_mcontext->__ss;
	pc = (uintptr_t)ss->__pc;
	seiun_append(buf, cap, len, "Registers (arm64):\n");
	seiun_append(buf, cap, len, "  PC=0x%016llx SP=0x%016llx CPSR=0x%08x\n",
		(unsigned long long)ss->__pc, (unsigned long long)ss->__sp,
		(unsigned)ss->__cpsr);
	for (int i = 0; i < 29; i += 4)
	{
		seiun_append(buf, cap, len, "  x%-2d=0x%016llx x%-2d=0x%016llx x%-2d=0x%016llx x%-2d=0x%016llx\n",
			i,     (unsigned long long)ss->__x[i],
			i + 1, (unsigned long long)ss->__x[i + 1],
			i + 2, (unsigned long long)ss->__x[i + 2],
			i + 3, (unsigned long long)ss->__x[i + 3]);
	}
  #else // apple x86_64
	// SDK names the struct __darwin_x86_thread_state64 (mach/i386/_structs.h);
	// there is no __darwin_x86_thread_state64_t typedef.
	const struct __darwin_x86_thread_state64* ss = &uc->uc_mcontext->__ss;
	pc = (uintptr_t)ss->__rip;
	seiun_append(buf, cap, len, "Registers (x64):\n");
	seiun_append(buf, cap, len, "  RIP=0x%016llx RSP=0x%016llx RBP=0x%016llx\n",
		(unsigned long long)ss->__rip, (unsigned long long)ss->__rsp, (unsigned long long)ss->__rbp);
	seiun_append(buf, cap, len, "  RAX=0x%016llx RBX=0x%016llx RCX=0x%016llx RDX=0x%016llx\n",
		(unsigned long long)ss->__rax, (unsigned long long)ss->__rbx,
		(unsigned long long)ss->__rcx, (unsigned long long)ss->__rdx);
  #endif
#elif defined(__aarch64__) // linux / android
	ucontext_t* uc = (ucontext_t*)uctx;
	pc = (uintptr_t)uc->uc_mcontext.pc;
	seiun_append(buf, cap, len, "Registers (arm64):\n");
	seiun_append(buf, cap, len, "  PC=0x%016llx SP=0x%016llx LR(x30)=0x%016llx\n",
		(unsigned long long)uc->uc_mcontext.pc, (unsigned long long)uc->uc_mcontext.sp,
		(unsigned long long)uc->uc_mcontext.regs[30]);
	for (int i = 0; i < 30; i += 4)
	{
		seiun_append(buf, cap, len, "  x%-2d=0x%016llx x%-2d=0x%016llx x%-2d=0x%016llx x%-2d=0x%016llx\n",
			i,     (unsigned long long)uc->uc_mcontext.regs[i],
			i + 1, (unsigned long long)uc->uc_mcontext.regs[i + 1],
			i + 2, (unsigned long long)uc->uc_mcontext.regs[i + 2],
			i + 3, (unsigned long long)uc->uc_mcontext.regs[i + 3]);
	}
#elif defined(__arm__) // linux / android
	ucontext_t* uc = (ucontext_t*)uctx;
	pc = (uintptr_t)uc->uc_mcontext.arm_pc;
	seiun_append(buf, cap, len, "Registers (arm32):\n");
	seiun_append(buf, cap, len, "  PC=0x%08lx SP=0x%08lx LR=0x%08lx FP=0x%08lx IP=0x%08lx\n",
		(unsigned long)uc->uc_mcontext.arm_pc, (unsigned long)uc->uc_mcontext.arm_sp,
		(unsigned long)uc->uc_mcontext.arm_lr, (unsigned long)uc->uc_mcontext.arm_fp,
		(unsigned long)uc->uc_mcontext.arm_ip);
	seiun_append(buf, cap, len, "  r0=0x%08lx r1=0x%08lx r2=0x%08lx r3=0x%08lx r4=0x%08lx\n",
		(unsigned long)uc->uc_mcontext.arm_r0, (unsigned long)uc->uc_mcontext.arm_r1,
		(unsigned long)uc->uc_mcontext.arm_r2, (unsigned long)uc->uc_mcontext.arm_r3,
		(unsigned long)uc->uc_mcontext.arm_r4);
	seiun_append(buf, cap, len, "  r5=0x%08lx r6=0x%08lx r7=0x%08lx r8=0x%08lx r9=0x%08lx\n",
		(unsigned long)uc->uc_mcontext.arm_r5, (unsigned long)uc->uc_mcontext.arm_r6,
		(unsigned long)uc->uc_mcontext.arm_r7, (unsigned long)uc->uc_mcontext.arm_r8,
		(unsigned long)uc->uc_mcontext.arm_r9);
	seiun_append(buf, cap, len, "  r10=0x%08lx CPSR=0x%08lx\n",
		(unsigned long)uc->uc_mcontext.arm_r10, (unsigned long)uc->uc_mcontext.arm_cpsr);
#elif defined(__x86_64__) // linux / android
	ucontext_t* uc = (ucontext_t*)uctx;
	pc = (uintptr_t)uc->uc_mcontext.gregs[REG_RIP];
	seiun_append(buf, cap, len, "Registers (x64):\n");
	seiun_append(buf, cap, len, "  RIP=0x%016llx RSP=0x%016llx RBP=0x%016llx\n",
		(unsigned long long)uc->uc_mcontext.gregs[REG_RIP],
		(unsigned long long)uc->uc_mcontext.gregs[REG_RSP],
		(unsigned long long)uc->uc_mcontext.gregs[REG_RBP]);
	seiun_append(buf, cap, len, "  RAX=0x%016llx RBX=0x%016llx RCX=0x%016llx RDX=0x%016llx\n",
		(unsigned long long)uc->uc_mcontext.gregs[REG_RAX],
		(unsigned long long)uc->uc_mcontext.gregs[REG_RBX],
		(unsigned long long)uc->uc_mcontext.gregs[REG_RCX],
		(unsigned long long)uc->uc_mcontext.gregs[REG_RDX]);
	seiun_append(buf, cap, len, "  RSI=0x%016llx RDI=0x%016llx\n",
		(unsigned long long)uc->uc_mcontext.gregs[REG_RSI],
		(unsigned long long)uc->uc_mcontext.gregs[REG_RDI]);
#elif defined(__i386__) // linux / android
	ucontext_t* uc = (ucontext_t*)uctx;
	pc = (uintptr_t)uc->uc_mcontext.gregs[REG_EIP];
	seiun_append(buf, cap, len, "Registers (x86):\n");
	seiun_append(buf, cap, len, "  EIP=0x%08lx ESP=0x%08lx EBP=0x%08lx\n",
		(unsigned long)uc->uc_mcontext.gregs[REG_EIP],
		(unsigned long)uc->uc_mcontext.gregs[REG_ESP],
		(unsigned long)uc->uc_mcontext.gregs[REG_EBP]);
	seiun_append(buf, cap, len, "  EAX=0x%08lx EBX=0x%08lx ECX=0x%08lx EDX=0x%08lx\n",
		(unsigned long)uc->uc_mcontext.gregs[REG_EAX],
		(unsigned long)uc->uc_mcontext.gregs[REG_EBX],
		(unsigned long)uc->uc_mcontext.gregs[REG_ECX],
		(unsigned long)uc->uc_mcontext.gregs[REG_EDX]);
	seiun_append(buf, cap, len, "  ESI=0x%08lx EDI=0x%08lx\n",
		(unsigned long)uc->uc_mcontext.gregs[REG_ESI],
		(unsigned long)uc->uc_mcontext.gregs[REG_EDI]);
#endif
	(void)buf; (void)cap; (void)len;
	return pc;
}

static const char* seiun_posix_basename(const char* path)
{
	if (path == NULL) return NULL;
	const char* b = strrchr(path, '/');
	return b ? b + 1 : path;
}

// Tombstone-style annotation for one PC:
// "pc 00034abc libApplicationMain-64.so (Symbol+0x1c) [source/File.cpp:123]"
// The bare hex offset + lib name is exactly what `ndk-stack` parses.
static void seiun_annotate_pc(char* dst, size_t cap, uintptr_t pc)
{
	Dl_info info;
	memset(&info, 0, sizeof(info));
	if (dladdr((const void*)pc, &info) != 0 && info.dli_fname != NULL)
	{
		uintptr_t base = (uintptr_t)info.dli_fbase;
		const char* lib = seiun_posix_basename(info.dli_fname);
	#if defined(__LP64__) || defined(__arm64__) || defined(__aarch64__)
		snprintf(dst, cap, "pc %016llx %s", (unsigned long long)(pc - base), lib ? lib : "?");
	#else
		snprintf(dst, cap, "pc %08lx %s", (unsigned long)(pc - base), lib ? lib : "?");
	#endif
		if (info.dli_sname != NULL)
		{
			size_t used = strlen(dst);
			snprintf(dst + used, cap - used, " (%s+0x%llx)",
				info.dli_sname, (unsigned long long)(pc - (uintptr_t)info.dli_saddr));
		}
		// Exact file:line via the precomputed linemap, only for the library it
		// was generated from (basename prefix match covers -64/-v7 suffixes).
		if (seiun_linemap != NULL && seiun_linemap_lib[0] != 0 && lib != NULL &&
			strncmp(lib, seiun_linemap_lib, strlen(seiun_linemap_lib)) == 0)
		{
			char src[256];
			if (seiun_linemap_lookup((unsigned int)(pc - base), src, sizeof(src)) && src[0] != 0)
			{
				size_t used = strlen(dst);
				snprintf(dst + used, cap - used, " [%s]", src);
			}
		}
	}
	else
	{
		snprintf(dst, cap, "pc 0x%llx (unknown module)", (unsigned long long)pc);
	}
}

#if defined(SEIUN_HAS_UNWIND)
struct seiun_bt_state
{
	char* buf;
	size_t cap;
	int* len;
	int count;
};

static _Unwind_Reason_Code seiun_unwind_cb(struct _Unwind_Context* ctx, void* data)
{
	struct seiun_bt_state* st = (struct seiun_bt_state*)data;
	uintptr_t pc = (uintptr_t)_Unwind_GetIP(ctx);
	if (pc == 0) return _URC_END_OF_STACK;
	char line[512];
	seiun_annotate_pc(line, sizeof(line), pc);
	seiun_append(st->buf, st->cap, st->len, "  #%02d %s\n", st->count, line);
	if (++st->count >= 64) return _URC_END_OF_STACK;
	if (*st->len < 0 || (size_t)*st->len >= st->cap - 640) return _URC_END_OF_STACK;
	return _URC_NO_REASON;
}

// Walks the current stack. In a signal handler the interrupted frames sit
// right above the handler frame, so frames 0-1 are the handler + kernel
// signal trampoline and everything after that is the real crash chain.
static int seiun_write_unwind_backtrace(char* buf, size_t cap, int* len)
{
	seiun_append(buf, cap, len, "Backtrace (newest first; #00-#01 are the handler/signal trampoline):\n");
	struct seiun_bt_state st;
	st.buf = buf; st.cap = cap; st.len = len; st.count = 0;
	_Unwind_Backtrace(&seiun_unwind_cb, &st);
	if (st.count == 0)
		seiun_append(buf, cap, len, "  (unwinder produced no frames)\n");
	return st.count;
}
#else
static int seiun_write_unwind_backtrace(char* buf, size_t cap, int* len)
{
	(void)buf; (void)cap; (void)len;
	return 0;
}
#endif

// /proc/self/maps snapshot next to the crash log: the module base of every
// mapping, required for offline llvm-symbolizer/ndk-stack runs.
#if defined(__linux__)
static void seiun_dump_maps(void)
{
	if (seiun_path[0] == 0) return;
	char mpath[640];
	size_t l = strlen(seiun_path);
	if (l > 4) l -= 4; // strip ".txt"
	snprintf(mpath, sizeof(mpath), "%.*s_maps.txt", (int)l, seiun_path);
	int in = open("/proc/self/maps", O_RDONLY);
	if (in < 0) return;
	int out = open(mpath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (out >= 0)
	{
		char buf[8192];
		ssize_t r;
		while ((r = read(in, buf, sizeof(buf))) > 0)
		{
			ssize_t off = 0;
			while (off < r)
			{
				ssize_t w = write(out, buf + off, (size_t)(r - off));
				if (w <= 0) break;
				off += w;
			}
		}
		close(out);
	}
	close(in);
}
#endif // __linux__

static void seiun_posix_finish(const char* body, int len, int btStart)
{
	// Phase 2 already appended into the buffer by callers; write the tail.
	if (len > btStart)
		seiun_write_crash_file_fd(body + btStart, (size_t)(len - btStart), 1);
#if defined(__linux__)
	seiun_dump_maps();
#endif
#if defined(__ANDROID__)
	seiun_logcat_mirror(body);
#else
	seiun_native_crash_popup(seiun_crash_file());
#endif
}

static void seiun_posix_handler(int sig, siginfo_t* si, void* uctx)
{
	if (seiun_crash_written != 0)
	{
		signal(sig, SIG_DFL);
		raise(sig);
		return;
	}
	seiun_crash_written = 1;

	char* body = seiun_body;
	size_t cap = sizeof(seiun_body);
	int len = 0;
	seiun_append_report_header(body, cap, &len, "Native crash (POSIX fatal signal)");
	seiun_append(body, cap, &len, "\n--- Signal ---\n");
	seiun_append(body, cap, &len, "Signal: %d - %s\n", sig, seiun_signal_name(sig));
	seiun_append(body, cap, &len, "si_code: %d (%s)\n", si ? si->si_code : 0,
		seiun_sigcode_name(sig, si ? si->si_code : 0));
	seiun_append(body, cap, &len, "Fault address (si_addr, memory pointer): 0x%p\n",
		si ? si->si_addr : (void*)0);

	// Registers + faulting PC from the kernel signal context.
	uintptr_t faultPc = seiun_write_registers(body, cap, &len, uctx);
	if (faultPc != 0)
	{
		char ann[512];
		seiun_annotate_pc(ann, sizeof(ann), faultPc);
		seiun_append(body, cap, &len, "Faulting PC annotated: %s\n", ann);
	}

#if defined(__ANDROID__)
	seiun_write_android_props(body, cap, &len);
#endif
	seiun_append_engine_context(body, cap, &len);

	// Phase 1 on disk: everything above is durable before any unwinding.
	seiun_write_crash_file_fd(body, (size_t)len, 0);

	// Phase 2: backtrace (appended; a fault during unwind cannot destroy the
	// phase-1 data because the file is never truncated again).
	int btStart = len;
	seiun_append(body, cap, &len, "\n");
	int n = seiun_write_unwind_backtrace(body, cap, &len);
	if (n == 0)
	{
		seiun_append(body, cap, &len, "Backtrace fallback (execinfo):\n");
#if !defined(__ANDROID__)
		void* bt[64];
		int bn = backtrace(bt, 64);
		for (int i = 0; i < bn; i++)
		{
			char ann[512];
			seiun_annotate_pc(ann, sizeof(ann), (uintptr_t)bt[i]);
			seiun_append(body, cap, &len, "  #%02d %s\n", i, ann);
		}
#else
		seiun_append(body, cap, &len, "  (not available)\n");
#endif
	}
	seiun_append_triage(body, cap, &len);
	seiun_posix_finish(body, len, btStart);

	signal(sig, SIG_DFL);
	raise(sig);
}
#endif // !_WIN32

// ── dbghelp (loaded lazily at crash time, never linked) ──────────────────────

#if defined(_WIN32)
typedef BOOL (WINAPI *SeiunStackWalk64Fn)(DWORD, HANDLE, HANDLE, LPSTACKFRAME64, PVOID,
	PREAD_PROCESS_MEMORY_ROUTINE64, PFUNCTION_TABLE_ACCESS_ROUTINE64,
	PGET_MODULE_BASE_ROUTINE64, PTRANSLATE_ADDRESS_ROUTINE64);
typedef PVOID (WINAPI *SeiunSymFunctionTableAccess64Fn)(HANDLE, DWORD64);
typedef DWORD64 (WINAPI *SeiunSymGetModuleBase64Fn)(HANDLE, DWORD64);
typedef BOOL (WINAPI *SeiunSymInitializeFn)(HANDLE, const char*, BOOL);
typedef BOOL (WINAPI *SeiunSymFromAddrFn)(HANDLE, DWORD64, PDWORD64, PSYMBOL_INFO);
typedef BOOL (WINAPI *SeiunSymGetLineFromAddr64Fn)(HANDLE, DWORD64, PDWORD, PIMAGEHLP_LINE64);
typedef DWORD (WINAPI *SeiunSymSetOptionsFn)(DWORD);
typedef unsigned short (WINAPI *SeiunCaptureStackBackTraceFn)(unsigned long, unsigned long, void**, unsigned long*);
typedef BOOL (WINAPI *SeiunSymGetModuleInfo64Fn)(HANDLE, DWORD64, PIMAGEHLP_MODULE64);

static struct
{
	HMODULE lib;
	SeiunStackWalk64Fn stackWalk64;
	SeiunSymFunctionTableAccess64Fn funcTableAccess64;
	SeiunSymGetModuleBase64Fn getModuleBase64;
	SeiunSymFromAddrFn symFromAddr;
	SeiunSymGetLineFromAddr64Fn symGetLineFromAddr64;
	SeiunCaptureStackBackTraceFn captureBacktrace;
	/* Deliberately NOT named like the dbghelp.h symbol: this TU must resolve it
	   through GetProcAddress only, never through dbghelp.lib. */
	SeiunSymGetModuleInfo64Fn seiun_symModuleInfo;
	int ready; // StackWalk64/SymFromAddr usable (SymInitialize succeeded)
} seiun_dbghelp;

static void seiun_dbghelp_init(void)
{
	if (seiun_dbghelp.lib != NULL)
		return;
	HMODULE lib = LoadLibraryA("dbghelp.dll");
	if (lib == NULL)
		return;
	SeiunSymInitializeFn symInit = (SeiunSymInitializeFn)GetProcAddress(lib, "SymInitialize");
	SeiunStackWalk64Fn walk = (SeiunStackWalk64Fn)GetProcAddress(lib, "StackWalk64");
	SeiunSymFunctionTableAccess64Fn fta = (SeiunSymFunctionTableAccess64Fn)GetProcAddress(lib, "SymFunctionTableAccess64");
	SeiunSymGetModuleBase64Fn gmb = (SeiunSymGetModuleBase64Fn)GetProcAddress(lib, "SymGetModuleBase64");
	if (symInit == NULL || walk == NULL || fta == NULL || gmb == NULL)
		return;
	seiun_dbghelp.lib = lib;
	seiun_dbghelp.stackWalk64 = walk;
	seiun_dbghelp.funcTableAccess64 = fta;
	seiun_dbghelp.getModuleBase64 = gmb;
	seiun_dbghelp.symFromAddr = (SeiunSymFromAddrFn)GetProcAddress(lib, "SymFromAddr");
	seiun_dbghelp.symGetLineFromAddr64 = (SeiunSymGetLineFromAddr64Fn)GetProcAddress(lib, "SymGetLineFromAddr64");
	seiun_dbghelp.seiun_symModuleInfo = (SeiunSymGetModuleInfo64Fn)GetProcAddress(lib, "SymGetModuleInfo64");
	{
		HMODULE ntdll = GetModuleHandleA("ntdll.dll");
		if (ntdll != NULL)
			seiun_dbghelp.captureBacktrace = (SeiunCaptureStackBackTraceFn)GetProcAddress(ntdll, "RtlCaptureStackBackTrace");
	}
	{
		SeiunSymSetOptionsFn setOpts = (SeiunSymSetOptionsFn)GetProcAddress(lib, "SymSetOptions");
		// UNDNAME | DEFERRED_LOADS | LOAD_LINES | NO_PROMPTS (no symbol-server dialogs)
		if (setOpts != NULL)
			setOpts(0x00000002 | 0x00000004 | 0x00000010 | 0x00080000);
	}
	// Invade loads the module list for the current process; with the build PDB
	// next to the exe, SymFromAddr then resolves real function names.
	if (symInit(GetCurrentProcess(), NULL, TRUE))
		seiun_dbghelp.ready = 1;
}

// Module name + base for an arbitrary address; outName "?" when unmapped.
static ULONG_PTR seiun_module_for_address(ULONG_PTR addr, char* outName, size_t outCap)
{
	outName[0] = '?';
	outName[1] = 0;
	if (addr == 0)
		return 0;
	HMODULE mod = NULL;
	if (!GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
		(LPCSTR)addr, &mod))
		return 0;
	char path[1024];
	path[0] = 0;
	if (seiun_module_file_name_utf8(mod, path, sizeof(path)))
	{
		const char* name = path;
		for (const char* p = path; *p; ++p)
			if (*p == '\\' || *p == '/')
				name = p + 1;
		strncpy(outName, name, outCap - 1);
		outName[outCap - 1] = 0;
	}
	return (ULONG_PTR)mod;
}

// "<module>+0xRVA  <symbol>+0xdisp [file:line]" for one address.
//
// Two independent sources feed the "[file:line]" part:
//  - the embedded linemap (the same SELM table the POSIX path uses), which needs
//    no sidecar file at all and is the only source that always exists in a
//    release build;
//  - dbghelp, but ONLY where it really has a PDB (SymType == SymPdb).
//
// Without a PDB dbghelp falls back to the export table and produces confident
// nonsense - a plain Haxe function shows up as "<vsnprintf>+0x8B614E", and
// "lime_hl_hb_shape+0x4411" is equally invented. A wrong function name is worse
// than none, so such names are dropped and the reader gets the exact
// "Module+0xRVA" that tools/crash.py consumes.
static void seiun_annotate_address(char* dst, size_t cap, DWORD64 pc)
{
	char modName[128];
	ULONG_PTR base = seiun_module_for_address((ULONG_PTR)pc, modName, sizeof(modName));
	if (base != 0)
		snprintf(dst, cap, "%s+0x%llX", modName, (unsigned long long)(pc - (DWORD64)base));
	else
		snprintf(dst, cap, "0x%llX (unmapped)", (unsigned long long)pc);
	int haveSource = 0;

	// "May dbghelp name this frame?" Two ways it cannot:
	//  - the main module has no matching PDB (every release build), so dbghelp
	//    would answer from the export table;
	//  - the displacement is far larger than any real function, which means the
	//    nearest export is simply on the other side of the address space.
	int namesTrustworthy = 1;
	if (base == 0)
		namesTrustworthy = 0;
	else if (seiun_dbghelp.ready && seiun_dbghelp.seiun_symModuleInfo != NULL &&
		base == (ULONG_PTR)GetModuleHandleA(NULL))
	{
		IMAGEHLP_MODULE64 mi;
		memset(&mi, 0, sizeof(mi));
		mi.SizeOfStruct = sizeof(IMAGEHLP_MODULE64);
		if (seiun_dbghelp.seiun_symModuleInfo(GetCurrentProcess(), (DWORD64)base, &mi))
			namesTrustworthy = ((int)mi.SymType == 3);
	}

	if (namesTrustworthy && seiun_dbghelp.ready && seiun_dbghelp.symFromAddr != NULL)
	{
		char symBuf[sizeof(SYMBOL_INFO) + 384];
		memset(symBuf, 0, sizeof(symBuf));
		SYMBOL_INFO* si = (SYMBOL_INFO*)symBuf;
		si->SizeOfStruct = sizeof(SYMBOL_INFO);
		si->MaxNameLen = 383;
		DWORD64 disp = 0;
		if (seiun_dbghelp.symFromAddr(GetCurrentProcess(), pc, &disp, si))
		{
			// A displacement this large is not "inside the symbol": the nearest
			// export is somewhere else entirely, so the name would only mislead.
			if (disp <= 0x10000)
			{
				size_t used = strlen(dst);
				snprintf(dst + used, cap - used, " <%s>+0x%llX", si->Name, (unsigned long long)disp);
			}
			if (seiun_dbghelp.symGetLineFromAddr64 != NULL)
			{
				IMAGEHLP_LINE64 line;
				memset(&line, 0, sizeof(line));
				line.SizeOfStruct = sizeof(IMAGEHLP_LINE64);
				DWORD disp32 = 0;
				if (seiun_dbghelp.symGetLineFromAddr64(GetCurrentProcess(), pc, &disp32, &line) && line.FileName != NULL)
				{
					const char* fn = line.FileName;
					size_t flen = strlen(fn);
					if (flen > 60)
						fn = fn + (flen - 60);
					size_t used2 = strlen(dst);
					snprintf(dst + used2, cap - used2, " [%s:%lu]", fn, (unsigned long)line.LineNumber);
					haveSource = 1;
				}
			}
		}
	}
	// Exact cpp file:line from the linemap generated for this build
	// (tools/gen_linemap_msvc.py). Only the module the table was made from is
	// annotated; the module basename is compared as a prefix.
	if (!haveSource && base != 0 && seiun_linemap != NULL && seiun_linemap_lib[0] != 0 &&
		strncmp(modName, seiun_linemap_lib, strlen(seiun_linemap_lib)) == 0)
	{
		char src[256];
		if (seiun_linemap_lookup((unsigned int)(pc - (DWORD64)base), src, sizeof(src)) && src[0] != 0)
		{
			size_t used = strlen(dst);
			snprintf(dst + used, cap - used, " [%s]", src);
		}
	}
}

// ── build identity (makes a crash log resolvable against a specific PDB) ─────

/**
 * PE TimeDateStamp + SizeOfImage of the running main module, read straight from
 * its mapped headers (cheap: no file IO, no heap).
 */
static int seiun_module_build_stamp(HMODULE mod, unsigned long* outStamp, unsigned long* outSize)
{
	if (mod == NULL || outStamp == NULL || outSize == NULL)
		return 0;
	const unsigned char* base = (const unsigned char*)mod;
	__try
	{
		if (base[0] != 'M' || base[1] != 'Z')
			return 0;
		long e_lfanew = *(const long*)(base + 0x3C);
		if (e_lfanew <= 0 || e_lfanew > 0x1000)
			return 0;
		const unsigned char* pe = base + e_lfanew;
		if (pe[0] != 'P' || pe[1] != 'E' || pe[2] != 0 || pe[3] != 0)
			return 0;
		*outStamp = *(const unsigned long*)(pe + 8);       // COFF TimeDateStamp
		if (*(const unsigned short*)(pe + 24) != 0x20B)    // PE32+ only
			return 0;
		*outSize = *(const unsigned long*)(pe + 24 + 56);  // SizeOfImage
		return 1;
	}
	__except (EXCEPTION_EXECUTE_HANDLER)
	{
		return 0;
	}
}

/**
 * Records which binary is running and which symbol sources are actually usable.
 *
 * dbghelp's SymType is the verdict. SymPdb (3) means real function names and
 * file:line. Anything else - SymNone (0), SymExport (5), ... - means dbghelp is
 * guessing from the export table, and a release build ships no PDB on purpose,
 * so that is the expected answer rather than an error. The embedded linemap is
 * what turns an offset into "[source/File.cpp:123]" without any sidecar file;
 * the published .map is the fallback for frames the linemap does not cover.
 */
static void seiun_append_build_identity(char* buf, size_t cap, int* len)
{
	// UTF-8 throughout: the exe really can live in a Chinese install path.
	char exePath[MAX_PATH * 2];
	exePath[0] = 0;
	HMODULE exeMod = GetModuleHandleA(NULL);
	seiun_module_file_name_utf8(exeMod, exePath, sizeof(exePath));

	unsigned long stamp = 0, imgSize = 0;
	int haveStamp = seiun_module_build_stamp(exeMod, &stamp, &imgSize);

	seiun_append(buf, cap, len, "\n--- Build identity ---\n");
	if (seiun_build_info[0])
		seiun_append(buf, cap, len, "Build: %s\n", seiun_build_info);
	seiun_append(buf, cap, len, "Main module: %s\n", exePath[0] ? exePath : "?");
	if (haveStamp)
		seiun_append(buf, cap, len,
			"Main module stamp: TimeDateStamp=0x%08lX (%lu) SizeOfImage=0x%lX\n",
			stamp, stamp, imgSize);

	// The address->line table embedded in this image. Its identity is what makes
	// the "[source/File.cpp:123]" annotations in the backtrace trustworthy, so
	// say plainly whether one is loaded and which build it came from.
	if (seiun_linemap == NULL)
		seiun_append(buf, cap, len, "Linemap: none loaded - frames carry module+offset only\n");
	else if (seiun_linemap_len < 20 || seiun_linemap[0] != 'S' || seiun_linemap[1] != 'E'
		|| seiun_linemap[2] != 'L' || seiun_linemap[3] != 'M')
		seiun_append(buf, cap, len, "Linemap: %s (%u bytes) is not a valid table - ignored\n",
			seiun_linemap_lib, seiun_linemap_len);
	else
		seiun_append(buf, cap, len,
			"Linemap: %s (%u bytes, %u entries) - annotated frames read [source/File.cpp:LINE]\n",
			seiun_linemap_lib, seiun_linemap_len, seiun_lm_u32(seiun_linemap + 8));

	// A PDB next to the exe only exists in a local symbol build (art/build_profile.bat);
	// mentioning it when it is absent would just be noise in every release report.
	char pdbPath[MAX_PATH];
	pdbPath[0] = 0;
	if (exePath[0])
	{
		size_t l = strlen(exePath);
		if (l + 5 < sizeof(pdbPath))
		{
			memcpy(pdbPath, exePath, l + 1);
			char* dot = NULL;
			for (char* p = pdbPath; *p; ++p)
				if (*p == '.') dot = p;
			if (dot != NULL && dot > pdbPath)
				*dot = 0;
			strcat(pdbPath, ".pdb");
		}
	}
	if (pdbPath[0])
	{
		HANDLE h = seiun_create_file_read_utf8(pdbPath);
		if (h != INVALID_HANDLE_VALUE)
		{
			LARGE_INTEGER sz;
			sz.QuadPart = 0;
			GetFileSizeEx(h, &sz);
			CloseHandle(h);
			seiun_append(buf, cap, len, "Local PDB: %s (%lld bytes)\n", pdbPath, (long long)sz.QuadPart);
		}
	}

	if (!seiun_dbghelp.ready)
		seiun_append(buf, cap, len, "Symbols: dbghelp unavailable - frames are raw module+offset\n");
	else if (seiun_dbghelp.seiun_symModuleInfo == NULL)
		seiun_append(buf, cap, len, "Symbols: unknown (SymGetModuleInfo64 unavailable)\n");
	else
	{
		IMAGEHLP_MODULE64 mi;
		memset(&mi, 0, sizeof(mi));
		mi.SizeOfStruct = sizeof(IMAGEHLP_MODULE64);
		if (!seiun_dbghelp.seiun_symModuleInfo(GetCurrentProcess(), (DWORD64)(ULONG_PTR)exeMod, &mi))
			seiun_append(buf, cap, len, "Symbols: SymGetModuleInfo64 failed (err %lu)\n", GetLastError());
		else if ((int)mi.SymType == 3)
			seiun_append(buf, cap, len,
				"Symbols: SymType=3 (SymPdb - names and file:line are real) | PdbAge=%lu | PdbSig=%08lX%04lX%04lX | LoadedPdb=%s\n",
				(unsigned long)mi.PdbAge,
				(unsigned long)mi.PdbSig70.Data1, (unsigned long)mi.PdbSig70.Data2,
				(unsigned long)mi.PdbSig70.Data3,
				mi.LoadedPdbName[0] ? mi.LoadedPdbName : "(none)");
		else
			seiun_append(buf, cap, len,
				"Symbols: SymType=%d (no PDB for this image - normal for a release build;"
				" resolve the offsets with the published .map)\n", (int)mi.SymType);
	}
}

// Proper unwind from the faulting context (x64 only; the build is x64).
static int seiun_write_stackwalk(char* out, size_t cap, CONTEXT* ctx)
{
#if defined(_M_X64) || defined(__x86_64__)
	if (!seiun_dbghelp.ready || ctx == NULL)
		return 0;
	STACKFRAME64 frame;
	memset(&frame, 0, sizeof(frame));
	frame.AddrPC.Offset = ctx->Rip;
	frame.AddrPC.Mode = AddrModeFlat;
	frame.AddrFrame.Offset = ctx->Rbp;
	frame.AddrFrame.Mode = AddrModeFlat;
	frame.AddrStack.Offset = ctx->Rsp;
	frame.AddrStack.Mode = AddrModeFlat;
	int len = 0;
	seiun_append(out, cap, &len,
		"Backtrace (StackWalk64, innermost first - [source/File.cpp:LINE] comes from the embedded linemap):\n");
	DWORD64 prevPc = 0;
	for (int i = 0; i < 32; i++)
	{
		if (len >= (int)cap - 768)
			break;
		if (!seiun_dbghelp.stackWalk64(IMAGE_FILE_MACHINE_AMD64, GetCurrentProcess(), GetCurrentThread(),
			&frame, ctx, NULL, seiun_dbghelp.funcTableAccess64, seiun_dbghelp.getModuleBase64, NULL))
			break;
		if (frame.AddrPC.Offset == 0 || frame.AddrPC.Offset == prevPc)
			break;
		prevPc = frame.AddrPC.Offset;
		char line[640];
		seiun_annotate_address(line, sizeof(line), frame.AddrPC.Offset);
		seiun_append(out, cap, &len, "  #%02d %s\n", i, line);
	}
	return len;
#else
	(void)out; (void)cap; (void)ctx;
	return 0;
#endif
}

// Live-stack capture for the SIGABRT / LuaJIT panic paths (stack intact there).
static int seiun_write_live_backtrace(char* out, size_t cap)
{
	if (seiun_dbghelp.captureBacktrace == NULL)
		return 0;
	void* frames[64];
	unsigned short n = seiun_dbghelp.captureBacktrace(0, 64, frames, NULL);
	if (n == 0)
		return 0;
	int len = 0;
	seiun_append(out, cap, &len, "Backtrace (captured, outermost last):\n");
	for (unsigned short i = 0; i < n; i++)
	{
		if (len >= (int)cap - 768)
			break;
		char line[640];
		seiun_annotate_address(line, sizeof(line), (DWORD64)(ULONG_PTR)frames[i]);
		seiun_append(out, cap, &len, "  #%02d %s\n", i, line);
	}
	return len;
}

// Fallback when unwinding fails (e.g. through JIT code): scan the raw stack
// for values that look like return addresses into known modules.
static int seiun_write_stack_scan(char* out, size_t cap, ULONG_PTR rsp)
{
	int len = 0;
	seiun_append(out, cap, &len, "Stack scan near RSP (module hits only):\n");
	if (rsp == 0)
		return len;
	__try
	{
		for (int i = 0; i < 160; i++)
		{
			if (len >= (int)cap - 256)
				break;
			ULONG_PTR v = ((ULONG_PTR*)rsp)[i];
			char modName[128];
			ULONG_PTR base = seiun_module_for_address(v, modName, sizeof(modName));
			if (base != 0)
				seiun_append(out, cap, &len, "  rsp+0x%03X: %s+0x%llX\n",
					i * (int)sizeof(ULONG_PTR), modName, (unsigned long long)(v - (DWORD64)base));
		}
	}
	__except (EXCEPTION_EXECUTE_HANDLER) {}
	return len;
}
#endif // _WIN32

// ── Windows: unhandled exception filter ──────────────────────────────────────

#if defined(_WIN32)
static LONG WINAPI seiun_seh_handler(EXCEPTION_POINTERS* info)
{
	if (InterlockedCompareExchange(&seiun_crash_written, 1, 0) != 0)
		return EXCEPTION_CONTINUE_SEARCH;

	if (info == NULL || info->ExceptionRecord == NULL)
		return EXCEPTION_CONTINUE_SEARCH;

	char* body = seiun_body;
	size_t cap = sizeof(seiun_body);
	int len = 0;
	seiun_append_report_header(body, cap, &len, "Native crash (Windows Structured Exception Handling)");
	seiun_append(body, cap, &len, "\n--- Exception ---\n");

	EXCEPTION_RECORD* er = info->ExceptionRecord;
	seiun_append(body, cap, &len, "Exception code: 0x%08lX (%s)\n",
		(unsigned long)er->ExceptionCode, seiun_exception_name(er->ExceptionCode));
	seiun_append(body, cap, &len, "Exception flags: 0x%08lX\n", (unsigned long)er->ExceptionFlags);
	seiun_append(body, cap, &len, "Exception address (faulting instruction pointer): 0x%p\n",
		(void*)er->ExceptionAddress);
	HMODULE mod = NULL;
	char modName[300] = "?";
	ULONG_PTR moduleBase = 0;
	if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
		(LPCSTR)er->ExceptionAddress, &mod))
	{
		moduleBase = (ULONG_PTR)mod;
		seiun_module_file_name_utf8(mod, modName, sizeof(modName));
	}
	seiun_append(body, cap, &len, "Faulting module: %s\n", modName);
	if (moduleBase != 0)
	{
		seiun_append(body, cap, &len, "Module base: 0x%p\n", (void*)moduleBase);
		seiun_append(body, cap, &len, "Fault offset: 0x%016llX\n",
			(unsigned long long)((ULONG_PTR)er->ExceptionAddress - moduleBase));
	}
	// ACCESS_VIOLATION is by far the common case (a null this-pointer deref shows
	// up here as "read at 0x8"), so spell it out instead of leaving two raw
	// numbers whose meaning the reader has to look up.
	if (er->ExceptionCode == 0xC0000005 && er->NumberParameters >= 2)
	{
		unsigned long long kind = (unsigned long long)er->ExceptionInformation[0];
		seiun_append(body, cap, &len, "Access violation: %s at 0x%016llX\n",
			kind == 0 ? "read" : kind == 1 ? "write" : kind == 8 ? "execute" : "unknown",
			(unsigned long long)er->ExceptionInformation[1]);
	}
	else
	{
		seiun_append(body, cap, &len, "Exception parameters: %lu\n", (unsigned long)er->NumberParameters);
		for (DWORD i = 0; i < er->NumberParameters && i < 2; i++)
			seiun_append(body, cap, &len, "  param[%lu]: 0x%p\n",
				(unsigned long)i, (void*)er->ExceptionInformation[i]);
	}
	if (info->ContextRecord != NULL)
	{
		CONTEXT* c = info->ContextRecord;
		seiun_append(body, cap, &len, "\n--- Registers ---\n");
#if defined(_M_X64) || defined(__x86_64__)
		seiun_append(body, cap, &len, "Registers (x64):\n");
		seiun_append(body, cap, &len, "  RIP=0x%016llX RSP=0x%016llX RBP=0x%016llX\n",
			(unsigned long long)c->Rip, (unsigned long long)c->Rsp, (unsigned long long)c->Rbp);
		seiun_append(body, cap, &len, "  RAX=0x%016llX RBX=0x%016llX RCX=0x%016llX RDX=0x%016llX\n",
			(unsigned long long)c->Rax, (unsigned long long)c->Rbx, (unsigned long long)c->Rcx, (unsigned long long)c->Rdx);
		seiun_append(body, cap, &len, "  RSI=0x%016llX RDI=0x%016llX R8=0x%016llX  R9=0x%016llX\n",
			(unsigned long long)c->Rsi, (unsigned long long)c->Rdi, (unsigned long long)c->R8, (unsigned long long)c->R9);
		seiun_append(body, cap, &len, "  R10=0x%016llX R11=0x%016llX R12=0x%016llX R13=0x%016llX\n",
			(unsigned long long)c->R10, (unsigned long long)c->R11, (unsigned long long)c->R12, (unsigned long long)c->R13);
		seiun_append(body, cap, &len, "  R14=0x%016llX R15=0x%016llX\n",
			(unsigned long long)c->R14, (unsigned long long)c->R15);
#elif defined(_M_IX86) || defined(__i386__)
		seiun_append(body, cap, &len, "Registers (x86):\n");
		seiun_append(body, cap, &len, "  EIP=0x%08X ESP=0x%08X EBP=0x%08X\n",
			(unsigned int)c->Eip, (unsigned int)c->Esp, (unsigned int)c->Ebp);
		seiun_append(body, cap, &len, "  EAX=0x%08X EBX=0x%08X ECX=0x%08X EDX=0x%08X\n",
			(unsigned int)c->Eax, (unsigned int)c->Ebx, (unsigned int)c->Ecx, (unsigned int)c->Edx);
		seiun_append(body, cap, &len, "  ESI=0x%08X EDI=0x%08X\n",
			(unsigned int)c->Esi, (unsigned int)c->Edi);
#elif defined(_M_ARM64)
		seiun_append(body, cap, &len, "Registers (ARM64):\n");
		seiun_append(body, cap, &len, "  PC=0x%016llX SP=0x%016llX\n",
			(unsigned long long)c->Pc, (unsigned long long)c->Sp);
#endif
	}
	seiun_append_engine_context(body, cap, &len);

	// Build identity in phase 1: if the symbol work below faults, the report
	// still says which exe produced these offsets and which linemap/.map can
	// resolve them. dbghelp goes first so the Symbols: line is already final by
	// the time the backtrace decides whether names may be shown at all.
	seiun_dbghelp_init();
	seiun_append_build_identity(body, cap, &len);
	seiun_append(body, cap, &len, "\n");

	// Phase 1 on disk: registers/exception info land even if dbghelp itself
	// dies inside a corrupted heap while resolving symbols below.
	seiun_write_crash_file(body);
	// Show the popup before the (less safe) symbol work, so the user at least
	// sees it even if dbghelp dies while resolving addresses.
	seiun_native_crash_popup(seiun_crash_file());

	// Phase 2: backtrace + stack scan appended, file overwritten in place.
	seiun_append(body, cap, &len, "\n");
	len += seiun_write_stackwalk(body + len, cap - (size_t)len, info->ContextRecord);
#if defined(_M_X64) || defined(__x86_64__)
	if (info->ContextRecord != NULL)
		len += seiun_write_stack_scan(body + len, cap - (size_t)len, (ULONG_PTR)info->ContextRecord->Rsp);
#endif

	seiun_append_triage(body, cap, &len);
	seiun_write_crash_file(body);

	return EXCEPTION_CONTINUE_SEARCH;
}

// abort()/terminate path: CRT asserts, pure virtual calls, etc. These bypass
// SetUnhandledExceptionFilter, so they used to die without any log. Returning
// from the handler lets abort() proceed and terminate as before.
static void __cdecl seiun_sigabrt_handler(int sig)
{
	(void)sig;
	if (InterlockedCompareExchange(&seiun_crash_written, 1, 0) != 0)
		return; // already logged (e.g. by the LuaJIT panic handler)

	seiun_dbghelp_init();
	char* body = seiun_body;
	size_t cap = sizeof(seiun_body);
	int len = 0;
	seiun_append_report_header(body, cap, &len,
		"Native crash (abort()/terminate path - SIGABRT; CRT assert, pure virtual call, etc.)");
	seiun_append_engine_context(body, cap, &len);
	seiun_append_build_identity(body, cap, &len);
	seiun_append(body, cap, &len, "\n");
	len += seiun_write_live_backtrace(body + len, cap - (size_t)len);
	seiun_append_triage(body, cap, &len);
	seiun_write_crash_file(body);
	seiun_native_crash_popup(seiun_crash_file());
}
#endif // _WIN32

// ── LuaJIT panic hook (both platforms) ───────────────────────────────────────

// Minimal LuaJIT C API surface (statically linked into the exe; declared here
// to avoid a lua.hpp dependency in this TU - signatures match Lua 5.1).
struct lua_State;
#ifdef __cplusplus
extern "C" {
#endif
typedef int (*seiun_lua_CFunction)(lua_State*);
seiun_lua_CFunction lua_atpanic(lua_State* L, seiun_lua_CFunction panicf);
const char* lua_tolstring(lua_State* L, int idx, size_t* len);
#ifdef __cplusplus
}
#endif

// Called by LuaJIT when an unprotected error escapes to the C API boundary.
// Without this, LuaJIT prints "PANIC: unprotected error..." and terminates,
// leaving no engine-side log at all.
static int seiun_lua_panic_handler(lua_State* L)
{
	int logged = 0;
#if defined(_WIN32)
	logged = (InterlockedCompareExchange(&seiun_crash_written, 1, 0) == 0);
#else
	if (seiun_crash_written == 0)
	{
		seiun_crash_written = 1;
		logged = 1;
	}
#endif
	if (logged)
	{
		char* body = seiun_body;
		size_t cap = sizeof(seiun_body);
		int len = 0;
		seiun_append_report_header(body, cap, &len,
			"Native crash (LuaJIT panic: unprotected error in call to Lua API)");
		const char* msg = (L != NULL) ? lua_tolstring(L, -1, NULL) : NULL;
		seiun_append(body, cap, &len, "Lua error message: %s\n", (msg != NULL) ? msg : "(non-string error object)");
		seiun_append_engine_context(body, cap, &len);
#if defined(_WIN32)
		seiun_dbghelp_init();
		// Phase 1: basic body + popup/marker before the (fragile) live backtrace.
		seiun_write_crash_file(body);
		seiun_native_crash_popup(seiun_crash_file());
		// Phase 2: overwrite with the backtrace appended.
		len += seiun_write_live_backtrace(body + len, cap - (size_t)len);
		seiun_append_triage(body, cap, &len);
		seiun_write_crash_file(body);
#else
		{
			int btStart = len;
			seiun_append(body, cap, &len, "\nBacktrace (stack intact at panic time):\n");
			seiun_write_unwind_backtrace(body, cap, &len);
			seiun_append_triage(body, cap, &len);
			seiun_write_crash_file_fd(body, (size_t)len, 0);
#if defined(__linux__)
			seiun_dump_maps();
#endif
#if defined(__ANDROID__)
			seiun_logcat_mirror(body);
#else
			seiun_native_crash_popup(seiun_crash_file());
#endif
			(void)btStart;
		}
#endif
	}
	abort();
	return 0; // not reached
}

// Install the panic handler on one lua_State (called from Haxe after newstate).
void seiun_install_lua_panic(void* L)
{
	if (L != NULL)
		lua_atpanic((lua_State*)L, seiun_lua_panic_handler);
}

// ── installer ────────────────────────────────────────────────────────────────

static void seiun_install_native_crash_hooks()
{
#if defined(_WIN32)
	SetUnhandledExceptionFilter(seiun_seh_handler);
	// SIGABRT: the only signal UCRT abort() honors before terminating.
	signal(SIGABRT, seiun_sigabrt_handler);
#else
#if defined(__ANDROID__)
	seiun_logcat_init();
#endif
	// Alternate signal stack: a SIGSEGV from stack overflow has no usable stack
	// left; SA_ONSTACK lets the handler run (and write its log) on this one.
	{
		static char seiun_altstack[64 * 1024];
		stack_t ss;
		memset(&ss, 0, sizeof(ss));
		ss.ss_sp = seiun_altstack;
		ss.ss_size = sizeof(seiun_altstack);
		ss.ss_flags = 0;
		sigaltstack(&ss, NULL);
	}
	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_sigaction = seiun_posix_handler;
	sa.sa_flags = SA_SIGINFO | SA_RESETHAND | SA_ONSTACK;
	sigemptyset(&sa.sa_mask);
	sigaction(SIGSEGV, &sa, NULL);
	sigaction(SIGABRT, &sa, NULL);
	sigaction(SIGBUS, &sa, NULL);
	sigaction(SIGFPE, &sa, NULL);
	sigaction(SIGILL, &sa, NULL);
#endif
}

// -- pre-Haxe boot hooks -----------------------------------------------------
//
// The Haxe entry point (Main.main -> NativeCrash.install) runs after hxcpp's
// class static initialisation (__boot_all), so a fault during that phase used to
// leave no report at all - exactly what the ModDownloader boot crash did. These
// hooks run while the library/executable is still initialising, before any Haxe
// code, and make the crash logger usable from the very first instruction.
// install() is idempotent; Haxe calls it again later, harmlessly.

#if defined(__ANDROID__)
static char seiun_android_pkg[192];

// /proc/self/cmdline holds the process name, i.e. the package name (a ":suffix"
// marks a secondary process and is cut off).
static void seiun_android_read_package(void)
{
	seiun_android_pkg[0] = 0;
	int fd = open("/proc/self/cmdline", O_RDONLY);
	if (fd < 0) return;
	char buf[256];
	ssize_t r = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (r <= 0) return;
	buf[r] = 0;
	size_t i = 0;
	while (i < (size_t)r && buf[i] != 0 && buf[i] != ':' && i < sizeof(seiun_android_pkg) - 1)
	{
		seiun_android_pkg[i] = buf[i];
		i++;
	}
	seiun_android_pkg[i] = 0;
}

// Default crash directory under the app's own external files dir. The process
// cwd on Android is "/" (not writable), so without this every crash before
// Haxe's setCrashDir survived only in logcat. Never overwrites Haxe's choice.
static void seiun_android_default_crash_dir(void)
{
	if (seiun_dir[0] != 0) return;
	seiun_android_read_package();
	if (seiun_android_pkg[0] == 0) return;
	snprintf(seiun_dir, sizeof(seiun_dir),
		"/storage/emulated/0/Android/data/%s/files/crash/", seiun_android_pkg);
	seiun_ensure_crash_dir();
}

// Fingerprint of the exact .so that is running: name, size, mtime and an FNV-1a
// hash of its first/last 64 KB (same constants as fnv1aFile in NativeCrash.hx).
// Only written when nothing was set yet, so the more detailed Haxe-fed info is
// never overwritten.
static void seiun_android_self_build_id(void)
{
	if (seiun_build_info[0] != 0) return;
	Dl_info dli;
	memset(&dli, 0, sizeof(dli));
	if (dladdr((const void*)&seiun_install_native_crash_hooks, &dli) == 0 || dli.dli_fname == NULL)
		return;
	struct stat st;
	if (stat(dli.dli_fname, &st) != 0) return;

	unsigned int h = 0x811C9DC5u;
	int round;
	for (round = 0; round < 2; round++)
	{
		off_t off = 0;
		if (round == 1)
		{
			if (st.st_size <= 65536 * 2) break;
			off = st.st_size - 65536;
		}
		int fd = open(dli.dli_fname, O_RDONLY);
		if (fd < 0) break;
		if (lseek(fd, off, SEEK_SET) < 0) { close(fd); break; }
		unsigned char chunk[65536];
		ssize_t got = read(fd, chunk, sizeof(chunk));
		close(fd);
		if (got <= 0) break;
		ssize_t i;
		for (i = 0; i < got; i++)
		{
			h ^= chunk[i];
			h *= 0x01000193u;
		}
	}
	const char* lib = seiun_posix_basename(dli.dli_fname);
	snprintf(seiun_build_info, sizeof(seiun_build_info),
		"abi=%s | so=%s | size=%lldB@%llds#%08x",
		seiun_get_cpu_abi(), lib ? lib : "?",
		(long long)st.st_size, (long long)st.st_mtime, (unsigned int)h);
}

__attribute__((constructor)) static void seiun_android_boot_hooks(void)
{
	seiun_android_default_crash_dir();
	seiun_android_self_build_id();
	seiun_install_native_crash_hooks();
}
#endif // __ANDROID__

#if defined(_WIN32)
// MSVC has no __attribute__((constructor)); a pointer in the CRT's C++ init
// table runs before main() and before hxcpp's __boot_all(). The object is linked
// straight into the executable, so this only exists there - which is where it is
// needed.
static void seiun_windows_boot_hooks(void)
{
	// Default dir "<exe dir>/crash/" so even a fault before Haxe's setCrashDir
	// lands next to the binary instead of in whatever the cwd happened to be.
	if (seiun_dir[0] == 0)
	{
		char exePath[MAX_PATH * 2];
		exePath[0] = 0;
		if (seiun_module_file_name_utf8(NULL, exePath, sizeof(exePath)))
		{
			char* slash = strrchr(exePath, '\\');
			if (slash != NULL)
			{
				*(slash + 1) = 0;
				snprintf(seiun_dir, sizeof(seiun_dir), "%scrash\\", exePath);
			}
		}
	}
	seiun_install_native_crash_hooks();
}
#pragma section(".CRT$XCU", read)
__declspec(allocate(".CRT$XCU")) static void (*seiun_windows_boot_hook_ptr)(void) = seiun_windows_boot_hooks;
#endif // _WIN32

// ════════════════════════════════════════════════════════════════════════════
// Top-level fatal funnel: seiun_fatal_report()
//
// This is the ONE entry point for every failure that leaves the process in a
// state where it cannot continue, but that does not come from a hardware fault:
//   - a Haxe exception that escapes __boot_all()/__hxcpp_main()  (HxcppMain.h)
//   - a Haxe exception that escapes Main.main() (the Haxe layer reports its own
//     richer dump and calls seiun_collect_diag() for the block below)
//   - lime's ndll failing to initialise (that module has its own copy, see
//     .haxelib/lime/git/project/src/utils/FatalReport.cpp)
//
// Fixed order, because each step needs something the next one may not have:
//   1. build the report in memory (no IO, no heap beyond the static buffers)
//   2. write it to <crash dir>/SeiunEngine_fatal_<kind>_<time>.txt (UTF-8 + BOM)
//   3. write crash/native_crash.pending so the next launch can offer recovery
//   4. mirror to logcat / OutputDebugString / stderr (survives an unwritable dir)
//   5. show the dialog ON THE MAIN THREAD, then let the caller exit
//
// Everything is deliberately allocation-free (static buffers, stack strings):
// this runs after a Haxe exception which may itself have been caused by a
// corrupted heap, and on a thread whose state nobody can vouch for.
// ════════════════════════════════════════════════════════════════════════════

#include <errno.h>

#if defined(_WIN32)
#  include <tlhelp32.h>   // Module32FirstW (loaded module list)
#else
#  include <sys/wait.h>   // waitpid (dialog helper process)
#endif

#if defined(__linux__)
#  include <link.h>        // dl_iterate_phdr (module list)
#  include <sys/utsname.h> // uname (OS string)
#elif defined(__APPLE__)
#  include <mach-o/dyld.h> // _dyld_image_count (module list)
#  include <sys/utsname.h>
#endif
#if defined(__APPLE__) && defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
#  include <os/log.h>     // os_log: the only user-visible console on iOS
#endif

// The dialog is a public entry point as well: the Haxe layer calls it when lime
// itself is unavailable (missing lime.ndll) and no Haxe-side dialog can exist.
extern "C" void seiun_show_dialog_utf8(const char* title, const char* message);
extern "C" void seiun_fatal_report(const char* kind, const char* msg, const char* detail);
extern "C" int seiun_collect_diag(char* out, size_t cap);

static char seiun_fatal_body[65536];
static char seiun_fatal_path[600];

// ── small text helpers ──────────────────────────────────────────────────────

static int seiun_ci_contains(const char* hay, const char* needle)
{
	if (hay == NULL || needle == NULL || needle[0] == 0)
		return 0;
	size_t nl = strlen(needle);
	for (const char* p = hay; *p; ++p)
	{
		size_t i = 0;
		while (i < nl && p[i])
		{
			char a = p[i], b = needle[i];
			if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
			if (b >= 'A' && b <= 'Z') b = (char)(b - 'A' + 'a');
			if (a != b) break;
			i++;
		}
		if (i == nl) return 1;
	}
	return 0;
}

// Copies the first quoted token out of msg ("... ID of \"videos\"" -> videos).
static void seiun_quoted_token(const char* msg, char* out, size_t cap)
{
	out[0] = 0;
	if (msg == NULL) return;
	const char* a = strchr(msg, '"');
	if (a == NULL) a = strchr(msg, '\'');
	if (a == NULL) return;
	const char* b = strchr(a + 1, *a);
	if (b == NULL) return;
	size_t l = (size_t)(b - a - 1);
	if (l == 0) return;
	if (l >= cap) l = cap - 1;
	memcpy(out, a + 1, l);
	out[l] = 0;
}

// FormatMessage() keeps the "%1" placeholders when the caller supplies no insert
// list, which is how "error 193: %1 is not a valid Win32 application" ends up in
// a report. Drop them and the spaces they leave behind.
static void seiun_strip_format_inserts(char* text)
{
	for (char* p = text; *p; )
	{
		if (*p == '%' && p[1] >= '0' && p[1] <= '9')
		{
			memmove(p, p + 2, strlen(p + 2) + 1);
			continue;
		}
		p++;
	}
	while (*text == ' ' || *text == '\t' || *text == ':')
		memmove(text, text + 1, strlen(text));
}

// GetLastError()/errno are only meaningful for the code that just failed: by the
// time this reporter has created its directory and opened its file, the value is
// its own ("183: the file already exists"). Callers snapshot it on entry and
// restore it right before they ask for the description.
static void seiun_snapshot_last_error(char* out, size_t cap)
{
#if defined(_WIN32)
	snprintf(out, cap, "%lu", (unsigned long)GetLastError());
#else
	snprintf(out, cap, "%d", errno);
#endif
}

static void seiun_restore_last_error(const char* snapshot)
{
#if defined(_WIN32)
	if (snapshot != NULL && snapshot[0])
		SetLastError((DWORD)strtoul(snapshot, NULL, 10));
#else
	if (snapshot != NULL && snapshot[0])
		errno = (int)strtol(snapshot, NULL, 10);
#endif
}

// Last Win32/errno code at the moment the report is built. GetLastError() is
// only meaningful on the thread that failed, so it is read here, first.
static void seiun_describe_last_error(char* out, size_t cap)
{
#if defined(_WIN32)
	DWORD err = GetLastError();
	wchar_t wbuf[512];
	wbuf[0] = 0;
	DWORD n = FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL,
		err, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT), wbuf,
		(DWORD)(sizeof(wbuf) / sizeof(wbuf[0])), NULL);
	char ubuf[512];
	seiun_utf16_to_utf8(wbuf, ubuf, sizeof(ubuf));
	if (n == 0) ubuf[0] = 0;
	// Trim the trailing CR/LF FormatMessage appends.
	for (size_t i = strlen(ubuf); i > 0; --i)
	{
		if (ubuf[i - 1] == '\r' || ubuf[i - 1] == '\n' || ubuf[i - 1] == ' ')
			ubuf[i - 1] = 0;
		else
			break;
	}
	seiun_strip_format_inserts(ubuf);
	if (err == 0)
		snprintf(out, cap, "0 (no error was recorded)");
	else if (ubuf[0])
		snprintf(out, cap, "%lu (%s)", (unsigned long)err, ubuf);
	else
		snprintf(out, cap, "%lu (no system text)", (unsigned long)err);
#else
	snprintf(out, cap, "errno=%d (%s)", errno, strerror(errno));
#endif
}

// ── environment: OS / GPU / driver / process ────────────────────────────────

static void seiun_describe_os(char* out, size_t cap)
{
	out[0] = 0;
#if defined(_WIN32)
	// GetVersionEx is manifest-lied to; RtlGetVersion always tells the truth.
	typedef LONG (WINAPI *SeiunRtlGetVersionFn)(OSVERSIONINFOW*);
	OSVERSIONINFOW vi;
	memset(&vi, 0, sizeof(vi));
	vi.dwOSVersionInfoSize = sizeof(vi);
	HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
	if (ntdll != NULL)
	{
		SeiunRtlGetVersionFn fn = (SeiunRtlGetVersionFn)GetProcAddress(ntdll, "RtlGetVersion");
		if (fn != NULL)
			fn(&vi);
	}
	SYSTEM_INFO si;
	memset(&si, 0, sizeof(si));
	GetNativeSystemInfo(&si);
	const char* arch = "unknown";
	switch (si.wProcessorArchitecture)
	{
		case PROCESSOR_ARCHITECTURE_AMD64: arch = "x64"; break;
		case PROCESSOR_ARCHITECTURE_INTEL: arch = "x86"; break;
		case PROCESSOR_ARCHITECTURE_ARM64: arch = "arm64"; break;
		case PROCESSOR_ARCHITECTURE_ARM: arch = "arm"; break;
	}
	snprintf(out, cap, "Windows %lu.%lu (build %lu) %s, %d-bit process",
		(unsigned long)vi.dwMajorVersion, (unsigned long)vi.dwMinorVersion,
		(unsigned long)vi.dwBuildNumber, arch, (int)(sizeof(void*) * 8));
#elif defined(__ANDROID__)
	char model[92] = {0}, manuf[92] = {0}, release[92] = {0}, sdk[92] = {0};
	__system_property_get("ro.product.model", model);
	__system_property_get("ro.product.manufacturer", manuf);
	__system_property_get("ro.build.version.release", release);
	__system_property_get("ro.build.version.sdk", sdk);
	snprintf(out, cap, "Android %s (API %s) %s %s, abi=%s, %d-bit process",
		release, sdk, manuf, model, seiun_get_cpu_abi(), (int)(sizeof(void*) * 8));
#else
	struct utsname un;
	memset(&un, 0, sizeof(un));
	if (uname(&un) == 0)
		snprintf(out, cap, "%s %s (%s), %d-bit process",
			un.sysname, un.release, un.machine, (int)(sizeof(void*) * 8));
	else
		snprintf(out, cap, "unknown POSIX system, %d-bit process", (int)(sizeof(void*) * 8));
#endif
}

/**
 * Adapter + driver version of the display that renders the game.
 *
 * Loaded through GetProcAddress on purpose: advapi32 is always present, but
 * linking stubs into the game for a line of diagnostics is not worth it, and
 * this code must keep compiling for every other target unchanged.
 */
static void seiun_describe_gpu(char* out, size_t cap)
{
	out[0] = 0;
#if defined(_WIN32)
	char adapter[256];
	adapter[0] = 0;
	DISPLAY_DEVICEW dd;
	memset(&dd, 0, sizeof(dd));
	dd.cb = sizeof(dd);
	if (EnumDisplayDevicesW(NULL, 0, &dd, 0))
		seiun_utf16_to_utf8(dd.DeviceString, adapter, sizeof(adapter));

	char driver[128];
	driver[0] = 0;
	HMODULE advapi = LoadLibraryW(L"advapi32.dll");
	if (advapi != NULL)
	{
		typedef LONG (WINAPI *SeiunRegOpenKeyExWFn)(HKEY, LPCWSTR, DWORD, REGSAM, PHKEY);
		typedef LONG (WINAPI *SeiunRegQueryValueExWFn)(HKEY, LPCWSTR, LPDWORD, LPDWORD, LPBYTE, LPDWORD);
		typedef LONG (WINAPI *SeiunRegCloseKeyFn)(HKEY);
		SeiunRegOpenKeyExWFn openKey = (SeiunRegOpenKeyExWFn)GetProcAddress(advapi, "RegOpenKeyExW");
		SeiunRegQueryValueExWFn queryValue = (SeiunRegQueryValueExWFn)GetProcAddress(advapi, "RegQueryValueExW");
		SeiunRegCloseKeyFn closeKey = (SeiunRegCloseKeyFn)GetProcAddress(advapi, "RegCloseKey");
		if (openKey != NULL && queryValue != NULL && closeKey != NULL)
		{
			// 0000 = the primary display adapter's driver key.
			HKEY key = NULL;
			if (openKey(HKEY_LOCAL_MACHINE,
				L"SYSTEM\\CurrentControlSet\\Control\\Class\\{4d36e968-e325-11ce-bfc1-08002be10318}\\0000",
				0, 0x20019 /*KEY_READ*/, &key) == 0 && key != NULL)
			{
				wchar_t wver[128];
				DWORD cb = sizeof(wver);
				DWORD type = 0;
				if (queryValue(key, L"DriverVersion", NULL, &type, (LPBYTE)wver, &cb) == 0)
					seiun_utf16_to_utf8(wver, driver, sizeof(driver));
				closeKey(key);
			}
		}
		FreeLibrary(advapi);
	}
	snprintf(out, cap, "%s%s%s",
		adapter[0] ? adapter : "(no display adapter reported)",
		driver[0] ? " driver " : "",
		driver);
#else
	// The GL vendor/renderer strings are only reachable through the engine, which
	// is exactly what failed here; the Haxe layer pushes them via setEnvInfo().
	snprintf(out, cap, "(see Env: line - filled from the live GL context by the engine)");
#endif
}

static void seiun_describe_process(char* out, size_t cap)
{
	char cwd[512];
	cwd[0] = 0;
#if defined(_WIN32)
	{
		wchar_t wcwd[512];
		if (GetCurrentDirectoryW((DWORD)(sizeof(wcwd) / sizeof(wcwd[0])), wcwd))
			seiun_utf16_to_utf8(wcwd, cwd, sizeof(cwd));
	}
#else
	if (getcwd(cwd, sizeof(cwd)) == NULL) cwd[0] = 0;
#endif
	out[0] = 0;
#if defined(_WIN32)
	snprintf(out, cap, "pid=%lu | cwd=%s", (unsigned long)GetCurrentProcessId(), cwd[0] ? cwd : "?");
#else
	snprintf(out, cap, "pid=%ld | cwd=%s", (long)getpid(), cwd[0] ? cwd : "?");
#endif
}

// ── lime module probe ───────────────────────────────────────────────────────

// Name a PE's machine type from its headers (0x8664 = x64, 0x14C = x86).
static const char* seiun_pe_machine_name(unsigned short machine)
{
	switch (machine)
	{
		case 0x8664: return "x64";
		case 0x014C: return "x86 (32-bit)";
		case 0xAA64: return "arm64";
		case 0x01C4: return "armv7";
		default: return "unknown";
	}
}

/**
 * Is the native module this engine cannot run without actually loadable?
 *
 * When lime.ndll is missing, or is the 32-bit build in a 64-bit process, hxcpp
 * only ever says "Could not load module lime@lime_init": the Win32 error code
 * that explains it is lost. So the fatal path probes the file itself - existence,
 * size, PE/ELF bitness and a real LoadLibraryW/dlopen - and the report then says
 * "error 193, 32-bit module in a 64-bit process" instead of leaving the user (and
 * the maintainer) to guess.
 */
static void seiun_probe_native_module(char* out, size_t cap)
{
	out[0] = 0;
	int len = 0;

	char exePath[MAX_PATH * 2];
	exePath[0] = 0;
#if defined(_WIN32)
	seiun_module_file_name_utf8(NULL, exePath, sizeof(exePath));
#elif defined(__linux__)
	{
		ssize_t n = readlink("/proc/self/exe", exePath, sizeof(exePath) - 1);
		if (n > 0) exePath[n] = 0;
	}
#endif
	char dir[600];
	dir[0] = 0;
	if (exePath[0])
	{
		snprintf(dir, sizeof(dir), "%s", exePath);
		char* slash = strrchr(dir, '\\');
		char* slash2 = strrchr(dir, '/');
		if (slash2 != NULL && (slash == NULL || slash2 > slash)) slash = slash2;
		if (slash != NULL) *(slash + 1) = 0;
	}

	static const char* names[] = {
#if defined(_WIN32)
		"lime.ndll", "lime.dll",
#elif defined(__APPLE__)
		"lime.ndll", "liblime.dylib",
#else
		"liblime.so", "lime.ndll",
#endif
		NULL
	};

	for (int i = 0; names[i] != NULL; ++i)
	{
		char path[700];
		snprintf(path, sizeof(path), "%s%s", dir, names[i]);

		long long size = -1;
#if defined(_WIN32)
		{
			wchar_t wpath[1024];
			if (seiun_utf8_to_utf16(path, wpath, (int)(sizeof(wpath) / sizeof(wpath[0]))))
			{
				WIN32_FILE_ATTRIBUTE_DATA fad;
				memset(&fad, 0, sizeof(fad));
				if (GetFileAttributesExW(wpath, GetFileExInfoStandard, &fad))
					size = ((long long)fad.nFileSizeHigh << 32) | (long long)fad.nFileSizeLow;
			}
		}
#else
		{
			struct stat st;
			if (stat(path, &st) == 0) size = (long long)st.st_size;
		}
#endif
		if (size < 0)
		{
			seiun_append(out, cap, &len, "%s: NOT FOUND next to the executable (%s)\n", names[i], path);
			continue;
		}

		// Bitness straight from the file header: this is the answer for the
		// "I copied a 32-bit ndll" case even if loading it would crash us.
		char bits[64];
		bits[0] = 0;
		FILE* f = NULL;
#if defined(_WIN32)
		f = seiun_fopen_utf8(path, L"rb");
#else
		f = fopen(path, "rb");
#endif
		if (f != NULL)
		{
			unsigned char hdr[64];
			size_t got = fread(hdr, 1, sizeof(hdr), f);
			if (got >= 64)
			{
#if defined(_WIN32)
				if (hdr[0] == 'M' && hdr[1] == 'Z')
				{
					long e_lfanew = *(const long*)(hdr + 0x3C);
					if (e_lfanew > 0 && e_lfanew < 0x1000)
					{
						if (fseek(f, e_lfanew, SEEK_SET) == 0)
						{
							unsigned char pe[26];
							if (fread(pe, 1, sizeof(pe), f) == sizeof(pe) &&
								pe[0] == 'P' && pe[1] == 'E')
							{
								unsigned short machine = *(const unsigned short*)(pe + 4);
								snprintf(bits, sizeof(bits), "PE machine=0x%04X (%s)",
									machine, seiun_pe_machine_name(machine));
							}
						}
					}
				}
#endif
				if (bits[0] == 0 && hdr[0] == 0x7F && hdr[1] == 'E' && hdr[2] == 'L' && hdr[3] == 'F')
				{
					unsigned short machine = (unsigned short)(hdr[18] | (hdr[19] << 8));
					snprintf(bits, sizeof(bits), "ELF class=%d (%s), machine=0x%04X",
						(int)hdr[4], hdr[4] == 2 ? "64-bit" : "32-bit", machine);
				}
			}
			fclose(f);
		}

		// And the real load result, with the OS error code that hxcpp swallows.
		char loadResult[256];
		loadResult[0] = 0;
#if defined(_WIN32)
		{
			wchar_t wpath[1024];
			SetLastError(0);
			HMODULE h = seiun_utf8_to_utf16(path, wpath, (int)(sizeof(wpath) / sizeof(wpath[0])))
				? LoadLibraryW(wpath) : NULL;
			if (h != NULL)
			{
				snprintf(loadResult, sizeof(loadResult), "LoadLibraryW OK (handle %p)", (void*)h);
			}
			else
			{
				DWORD err = GetLastError();
				char text[256];
				text[0] = 0;
				wchar_t wbuf[512];
				wbuf[0] = 0;
				if (FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL,
					err, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT), wbuf,
					(DWORD)(sizeof(wbuf) / sizeof(wbuf[0])), NULL) != 0)
					seiun_utf16_to_utf8(wbuf, text, sizeof(text));
				for (size_t k = strlen(text); k > 0; --k)
				{
					if (text[k - 1] == '\r' || text[k - 1] == '\n' || text[k - 1] == ' ')
						text[k - 1] = 0;
					else
						break;
				}
				seiun_strip_format_inserts(text);
				snprintf(loadResult, sizeof(loadResult), "LoadLibraryW failed: error %lu%s%s%s",
					(unsigned long)err, text[0] ? " - " : "", text,
					err == 193 ? " [ERROR_BAD_EXE_FORMAT: wrong bitness]" :
					err == 126 ? " [ERROR_MOD_NOT_FOUND: missing dependency or not present]" :
					err == 127 ? " [ERROR_PROC_NOT_FOUND]" : "");
			}
		}
#else
		{
			void* h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
			if (h != NULL)
			{
				snprintf(loadResult, sizeof(loadResult), "dlopen OK");
				dlclose(h);
			}
			else
			{
				const char* e = dlerror();
				snprintf(loadResult, sizeof(loadResult), "dlopen failed: %s", e ? e : "no error text");
			}
		}
#endif
		seiun_append(out, cap, &len, "%s: %lld bytes | %s | %s\n",
			names[i], size, bits[0] ? bits : "(unrecognised header)", loadResult);
	}

	// Where the game actually looks for it, for the "it is in the wrong folder"
	// case (lime searches the cwd, the exe dir and the haxelib path).
	seiun_append(out, cap, &len, "Expected next to: %s\n", dir[0] ? dir : "(unknown)");
	seiun_append(out, cap, &len, "Crash dir in use: %s\n", seiun_dir[0] ? seiun_dir : "crash/ (relative to cwd)");
}

// ── loaded module list ──────────────────────────────────────────────────────

#if defined(__linux__)
typedef struct
{
	char* buf;
	size_t cap;
	int* len;
	int count;
} SeiunPhdrArgs;

static int seiun_phdr_cb(struct dl_phdr_info* info, size_t size, void* data)
{
	(void)size;
	SeiunPhdrArgs* args = (SeiunPhdrArgs*)data;
	if (args->count >= 80)
		return 1; // bounded: a module list is not worth a bigger report
	seiun_append(args->buf, args->cap, args->len, "  %p  %s\n", (void*)(uintptr_t)info->dlpi_addr,
		info->dlpi_name && info->dlpi_name[0] ? info->dlpi_name : "(main executable)");
	args->count++;
	return 0;
}

// dl_iterate_phdr is exported by libc on every Android since 4.0, but the NDK's
// <link.h> only declares it for __ANDROID_API__ >= 21 on 32-bit ARM, and lime
// builds with APP_PLATFORM=android-16 (project/lib/sdl3/.../Application.mk), so
// a direct call does not compile for armeabi-v7a. Look the symbol up at run time
// there instead - the same idea as the __android_log_print probe above: API 21+
// devices get the real module list, older ones report it as unavailable.
#if defined(__ANDROID__)
typedef int (*SeiunPhdrCb)(struct dl_phdr_info*, size_t, void*);
typedef int (*SeiunIteratePhdrFn)(SeiunPhdrCb, void*);

static int seiun_iterate_phdr(SeiunPhdrCb cb, void* data)
{
	SeiunIteratePhdrFn fn = (SeiunIteratePhdrFn)dlsym(RTLD_DEFAULT, "dl_iterate_phdr");
	return (fn != NULL) ? fn(cb, data) : 0;
}
#  define SEIUN_ITERATE_PHDR(cb, data) seiun_iterate_phdr((cb), (data))
#else
#  define SEIUN_ITERATE_PHDR(cb, data) dl_iterate_phdr((cb), (data))
#endif
#endif

static void seiun_append_modules(char* buf, size_t cap, int* len)
{
	seiun_append(buf, cap, len, "\n--- Loaded modules (base, path) ---\n");
#if defined(_WIN32)
	HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, GetCurrentProcessId());
	if (snap == INVALID_HANDLE_VALUE)
	{
		seiun_append(buf, cap, len, "(CreateToolhelp32Snapshot failed: %lu)\n", GetLastError());
		return;
	}
	MODULEENTRY32W me;
	memset(&me, 0, sizeof(me));
	me.dwSize = sizeof(me);
	int count = 0;
	if (Module32FirstW(snap, &me))
	{
		do
		{
			if (count >= 80)
			{
				seiun_append(buf, cap, len, "  ... (more modules omitted)\n");
				break;
			}
			char path[700];
			seiun_utf16_to_utf8(me.szExePath, path, sizeof(path));
			seiun_append(buf, cap, len, "  0x%p  %llu B  %s\n",
				(void*)me.modBaseAddr, (unsigned long long)me.modBaseSize, path);
			count++;
		} while (Module32NextW(snap, &me));
	}
	CloseHandle(snap);
#elif defined(__linux__)
	{
		SeiunPhdrArgs args;
		args.buf = buf;
		args.cap = cap;
		args.len = len;
		args.count = 0;
		SEIUN_ITERATE_PHDR(seiun_phdr_cb, &args);
		if (args.count == 0)
			seiun_append(buf, cap, len, "  (module list unavailable on this device)\n");
	}
#elif defined(__APPLE__)
	{
		uint32_t n = _dyld_image_count();
		for (uint32_t i = 0; i < n && i < 80; i++)
		{
			const char* name = _dyld_get_image_name(i);
			seiun_append(buf, cap, len, "  %p  %s\n", (void*)_dyld_get_image_header(i), name ? name : "?");
		}
	}
#else
	seiun_append(buf, cap, len, "(not available on this platform)\n");
#endif
}

// ── the one explanation table ───────────────────────────────────────────────

/**
 * Turns a raw exception string into "what happened / why / how to fix it".
 *
 * Both languages are printed on purpose: the dialog is the only thing a player
 * sees, and a report may be opened by someone whose system language differs from
 * the game's. Only the failure modes that really are actionable get an entry;
 * everything else falls through to the generic text (never an empty explanation).
 */
static void seiun_explain_fatal(const char* kind, const char* msg, char* out, size_t cap)
{
	out[0] = 0;
	int len = 0;
	const char* text = msg != NULL ? msg : "";
	const char* k = kind != NULL ? kind : "";

	if (seiun_ci_contains(text, "no asset library with an id of") || seiun_ci_contains(k, "asset"))
	{
		char id[96];
		seiun_quoted_token(text, id, sizeof(id));
		seiun_append(out, cap, &len,
			"【缺少资源库 / Missing asset library%s%s】\n"
			"What : 引擎要求加载资源库%s，但这次构建里没有它。\n"
			"        The engine asked for an asset library that this build does not contain.\n"
			"Why  : project.xml 里 <library name=\"...\" preload=\"true\"/> 与对应的\n"
			"        <assets path=\"assets/...\" library=\"...\"/> 落在了不同的构建条件里。\n"
			"        最常见的是 videos：它需要 VIDEOS_ALLOWED（32 位构建默认关闭），\n"
			"        而 <library> 却写在条件之外，于是预加载清单里有库、包体里没有资源。\n"
			"        资源目录为空（没有任何文件）时 Lime 同样不会生成该库。\n"
			"Fix  : 打开 project.xml，把该 <library> 放进同一个 <section if=\"...\"> 内，\n"
			"        或改成 preload=\"false\"；并确认对应资源目录里至少有一个文件\n"
			"        （例如 assets/videos/put-your-videos-here.txt）。\n",
			id[0] ? ": " : "", id[0] ? id : "",
			id[0] ? "（ID 见下）" : "");
		if (id[0])
			seiun_append(out, cap, &len, "Library ID: \"%s\"\n", id);
	}
	else if (seiun_ci_contains(text, "could not load module") ||
		seiun_ci_contains(text, "lime.ndll") || seiun_ci_contains(text, "liblime") ||
		seiun_ci_contains(k, "lime_load") || seiun_ci_contains(k, "native_module"))
	{
		seiun_append(out, cap, &len,
			"【无法加载 lime 原生模块 / Cannot load the lime native module】\n"
			"What : hxcpp 在启动时 dlopen/LoadLibrary 了 lime 的 ndll，这一步失败了，\n"
			"        所以整个引擎（窗口、图形、声音）都不存在。\n"
			"        hxcpp could not load lime's native library, so no window/GL/audio exists.\n"
			"Why  : 1) lime.ndll 缺失或不在 exe 同目录；\n"
			"         2) 位数不对：64 位 exe 配了 32 位 ndll（Windows 错误码 193）；\n"
			"         3) 依赖缺失（VC++ 运行库、SDL3、OpenAL 等 DLL）；\n"
			"         4) 被安全软件/杀毒隔离。\n"
			"Fix  : 确认 exe 同目录下有 x64 的 lime.ndll（Linux: liblime.so，\n"
			"        macOS: lime.ndll），并与 exe 同一次构建产生：\n"
			"        haxelib run lime rebuild windows -64 -D lime-sdl3\n"
			"        下面的 \"lime module probe\" 会给出文件大小、位数和真实的系统错误码。\n");
	}
	else if (seiun_ci_contains(text, "0xc000007b") || seiun_ci_contains(text, "bad image") ||
		seiun_ci_contains(text, "error 193"))
	{
		seiun_append(out, cap, &len,
			"【位数不匹配 / Wrong bitness】\n"
			"What : 某个 DLL/ndll 的位数与进程不一致（0xc000007b / error 193）。\n"
			"Fix  : 全链路都用 64 位产物：lime.ndll 必须来自\n"
			"        haxelib run lime rebuild windows -64 -D lime-sdl3\n");
	}
	else if (seiun_ci_contains(text, "sdl") && (seiun_ci_contains(text, "init") ||
		seiun_ci_contains(text, "window") || seiun_ci_contains(text, "renderer")))
	{
		seiun_append(out, cap, &len,
			"【SDL 初始化失败 / SDL could not start】\n"
			"What : SDL 无法创建视频/渲染环境（报错原文在 Detail 里，即 SDL_GetError()）。\n"
			"Why  : 显卡驱动过旧或损坏、远程桌面/虚拟机没有 3D 加速、\n"
			"        独显被禁用、RDP 会话里没有 GL、或 SDL3 的 DLL 版本不匹配。\n"
			"Fix  : 更新显卡驱动；退出远程桌面在本机运行；\n"
			"        或在启动参数里换成软件渲染/窗口化后再试。\n");
	}
	else if (seiun_ci_contains(k, "launch") || seiun_ci_contains(k, "startup"))
	{
		seiun_append(out, cap, &len,
			"【启动阶段异常 / Exception while starting】\n"
			"What : Main.main() 的启动 try 捕获到异常，此时窗口/引擎状态可能还不存在，\n"
			"        所以没有游戏内恢复界面，只能报告后退出。\n"
			"        The exception escaped the boot sequence, before the engine was usable.\n"
			"Why  : 资源缺失或被改动（assets/、pack.json）、模组脚本在加载时抛错、\n"
			"        存档/配置文件损坏、显卡或音频初始化失败、权限不足导致无法写文件。\n"
			"Fix  : 1) 看报告里的 Stack Trace，第一行 .hx 文件名+行号就是出错位置；\n"
			"       2) 把 mods/ 清空（或只留默认内容）再启动一次；\n"
			"       3) 删除 crash/ 之外的用户配置（如 settings/）后重试，确认不是配置损坏；\n"
			"       4) 上面的环境信息（OS/GPU）会说明是否与驱动有关。\n");
	}
	else if (seiun_ci_contains(k, "engine_init") || seiun_ci_contains(k, "init_fail"))
	{
		seiun_append(out, cap, &len,
			"【引擎初始化失败 / Engine failed to initialise】\n"
			"What : new Main() 抛出异常，游戏对象没有建立起来。\n"
			"        Constructing the engine sprite failed, so no game object exists.\n"
			"Why  : 关键资源（字体/音效/图标）缺失或损坏、FlxG 初始化失败、\n"
			"        模组替换了核心资源、显存不足、OpenGL 上下文无法创建。\n"
			"Fix  : 确认 assets/ 完整（不要只拷贝 exe）；清空 mods/ 再试；\n"
			"        更新显卡驱动；报告里的 GL 错误与模块列表可用于进一步定位。\n");
	}
	else if (seiun_ci_contains(text, "out of memory") || seiun_ci_contains(text, "bad_alloc"))
	{
		seiun_append(out, cap, &len,
			"【内存不足 / Out of memory】\n"
			"What : 进程无法再分配内存，引擎无法继续。\n"
			"Fix  : 关闭其他程序；如果这是某首歌/某个模组触发的，先把该模组移出 mods/。\n");
	}
	else
	{
		seiun_append(out, cap, &len,
			"【未分类的致命错误 / Unclassified fatal error】\n"
			"What : 一个没有被任何已知规则匹配到的错误，原始信息见上面的 Message。\n"
			"         报错带有 .hx 文件与行号时，那里就是 Haxe 侧抛出异常的位置。\n"
			"Fix  : 把这份报告（含 Detail 与 Loaded modules）发给开发者；\n"
			"        若最近装过模组/脚本，先清空 mods/ 再试一次以排除模组因素。\n");
	}
}

/**
 * Haxe-facing wrapper around seiun_explain_fatal(): writes the explanation into
 * a caller-provided buffer and returns its length.
 *
 * The Haxe reporter (Main.reportCrash) and this file must tell the player the
 * same story for the same failure, so the table lives here once and both layers
 * read it. Returns 0 when the buffer is unusable.
 */
extern "C" int seiun_explain_fatal_to(char* out, size_t cap, const char* kind, const char* msg)
{
	if (out == NULL || cap < 2)
		return 0;
	seiun_explain_fatal(kind, msg, out, cap);
	return (int)strlen(out);
}

// ── dialog: one implementation per OS ───────────────────────────────────────

// UTF-8 BOM, shared by every writer in this file.
static const char* seiun_utf8_bom_bytes(void)
{
	static const char bom[4] = { (char)0xEF, (char)0xBB, (char)0xBF, 0 };
	return bom;
}

// The dialog text for the fork/exec paths goes through a UTF-8 file: quotes,
// newlines and Chinese then never need shell/AppleScript escaping.
static void seiun_dialog_write_temp(const char* text, char* outPath, size_t outCap)
{
	outPath[0] = 0;
#if !defined(_WIN32)
	const char* candidates[3];
	candidates[0] = "/tmp/seiun_fatal_dialog.txt";
	candidates[1] = "/data/local/tmp/seiun_fatal_dialog.txt";
	candidates[2] = NULL;
	for (int i = 0; candidates[i] != NULL; ++i)
	{
		FILE* f = fopen(candidates[i], "wb");
		if (f == NULL) continue;
		fwrite(seiun_utf8_bom_bytes(), 1, 3, f);
		fputs(text, f);
		fclose(f);
		snprintf(outPath, outCap, "%s", candidates[i]);
		return;
	}
#else
	(void)text;
	(void)outCap;
#endif
}

/**
 * Blocks until the user dismisses the box. Safe on the main thread; the crash
 * observers never call it (they run under the loader lock / in a signal handler).
 */
static int seiun_show_dialog_platform(const char* title, const char* message, const char* crashDir)
{
	if (title == NULL) title = "SeiunEngine";
	if (message == NULL) message = "";

#if defined(_WIN32)
	wchar_t wtitle[256];
	wchar_t wmsg[6000];
	if (!seiun_utf8_to_utf16(title, wtitle, (int)(sizeof(wtitle) / sizeof(wtitle[0]))))
		return 0;
	if (!seiun_utf8_to_utf16(message, wmsg, (int)(sizeof(wmsg) / sizeof(wmsg[0]))))
		seiun_utf8_to_utf16("(message too long to display - see the report file)", wmsg,
			(int)(sizeof(wmsg) / sizeof(wmsg[0])));

	HWND hwnd = GetActiveWindow();
	int shown = 0;
	// TaskDialog (the simple export, not TaskDialogIndirect): same native look
	// the engine's own dialogs already use, and it needs no comctl32 v6 headers.
	HMODULE comctl32 = LoadLibraryW(L"comctl32.dll");
	if (comctl32 != NULL)
	{
		typedef HRESULT (WINAPI *SeiunTaskDialogFn)(HWND, HINSTANCE, PCWSTR, PCWSTR, PCWSTR, int, PCWSTR, int*);
		SeiunTaskDialogFn td = (SeiunTaskDialogFn)GetProcAddress(comctl32, "TaskDialog");
		if (td != NULL)
		{
			int btn = 0;
			// 1 = TDCBF_OK_BUTTON, icon = TD_ERROR_ICON (-2) as an integer resource.
			if (td(hwnd, NULL, wtitle, wmsg, NULL, 1, (PCWSTR)(ULONG_PTR)(WORD)(-2), &btn) == 0)
				shown = 1;
		}
		FreeLibrary(comctl32);
	}
	if (!shown)
		MessageBoxW(hwnd, wmsg, wtitle, MB_OK | MB_ICONERROR | MB_SETFOREGROUND | MB_TOPMOST);
	shown = 1;

	// "Open crash folder?" - the only follow-up action worth offering, and the
	// one that turns "send me the report" into two clicks.
	if (crashDir != NULL && crashDir[0] != 0)
	{
		wchar_t wdir[1024];
		if (seiun_utf8_to_utf16(crashDir, wdir, (int)(sizeof(wdir) / sizeof(wdir[0]))))
		{
			if (MessageBoxW(hwnd,
				L"打开崩溃报告所在的文件夹？\nOpen the folder that contains the crash report?",
				L"SeiunEngine", MB_YESNO | MB_ICONQUESTION) == IDYES)
			{
				HMODULE shell32 = LoadLibraryW(L"shell32.dll");
				if (shell32 != NULL)
				{
					typedef HINSTANCE (WINAPI *SeiunShellExecuteWFn)(HWND, LPCWSTR, LPCWSTR, LPCWSTR, LPCWSTR, INT);
					SeiunShellExecuteWFn se = (SeiunShellExecuteWFn)GetProcAddress(shell32, "ShellExecuteW");
					if (se != NULL)
						se(NULL, L"open", wdir, NULL, NULL, SW_SHOWNORMAL);
					FreeLibrary(shell32);
				}
			}
		}
	}
	(void)shown;
	return 1;
#elif defined(__ANDROID__)
	// No dialog on Android: logcat is the console, and the next launch offers the
	// crash-catcher recovery screen (native_crash.pending).
	seiun_logcat_mirror(message);
	return 0;
#elif defined(__APPLE__) && defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
	os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_FAULT, "%{public}s: %{public}s", title, message);
	return 0;
#elif defined(__APPLE__)
	// Message through a UTF-8 file: osascript sees the text as AppleScript has to
	// read it, so quotes/newlines/Chinese never need shell escaping.
	char tmp[256];
	seiun_dialog_write_temp(message, tmp, sizeof(tmp));
	if (tmp[0] != 0)
	{
		char script[1024];
		snprintf(script, sizeof(script),
			"set m to do shell script \"cat '%s'\"\n"
			"display alert \"SeiunEngine\" message m as critical", tmp);
		pid_t pid = fork();
		if (pid == 0)
		{
			execl("/usr/bin/osascript", "osascript", "-e", script, (char*)NULL);
			_exit(127);
		}
		if (pid > 0)
		{
			int status = 0;
			waitpid(pid, &status, 0);
			if (WIFEXITED(status) && WEXITSTATUS(status) == 0)
				return 1;
		}
	}
	fprintf(stderr, "SeiunEngine: %s\n%s\n", title, message);
	return 0;
#else
	// Linux/BSD: zenity (GNOME) -> kdialog (KDE) -> xmessage. Text goes through a
	// UTF-8 file for xmessage, and through --text for zenity/kdialog.
	if (getenv("DISPLAY") == NULL && getenv("WAYLAND_DISPLAY") == NULL)
	{
		fprintf(stderr, "SeiunEngine: %s\n%s\n", title, message);
		return 0;
	}
	char tmp[256];
	seiun_dialog_write_temp(message, tmp, sizeof(tmp));
	pid_t pid = fork();
	if (pid == 0)
	{
		if (tmp[0] != 0)
			execlp("zenity", "zenity", "--error", "--title=SeiunEngine", "--text", message, (char*)NULL);
		execlp("kdialog", "kdialog", "--title", "SeiunEngine", "--error", message, (char*)NULL);
		if (tmp[0] != 0)
			execlp("xmessage", "xmessage", "-center", "-file", tmp, (char*)NULL);
		_exit(127);
	}
	if (pid > 0)
	{
		int status = 0;
		waitpid(pid, &status, 0);
		if (WIFEXITED(status) && WEXITSTATUS(status) == 0)
			return 1;
	}
	fprintf(stderr, "SeiunEngine: %s\n%s\n", title, message);
	return 0;
#endif
}

extern "C" void seiun_show_dialog_utf8(const char* title, const char* message)
{
	seiun_show_dialog_platform(title, message, seiun_dir[0] ? seiun_dir : "crash");
}

// ── diagnostics block for the Haxe reporter ─────────────────────────────────

/**
 * Everything the C++ layer knows that Haxe cannot ask for anymore once the
 * engine is dead: OS, GPU/driver, the real Win32 error, the lime module probe
 * and the module list. The Haxe crash dump appends this verbatim, so both
 * reporters produce reports with the same sections.
 */
extern "C" int seiun_collect_diag(char* out, size_t cap)
{
	if (out == NULL || cap < 64)
		return 0;
	out[0] = 0;
	int len = 0;
	char line[512];

	// Read before anything below can touch the error state.
	char lastError[32];
	seiun_snapshot_last_error(lastError, sizeof(lastError));

	seiun_append(out, cap, &len, "\n--- Native diagnostics (C++ layer) ---\n");
	seiun_describe_os(line, sizeof(line));
	seiun_append(out, cap, &len, "OS: %s\n", line);
	seiun_describe_gpu(line, sizeof(line));
	seiun_append(out, cap, &len, "GPU: %s\n", line);
	if (seiun_env_info[0])
		seiun_append(out, cap, &len, "Env: %s\n", seiun_env_info);
	seiun_describe_process(line, sizeof(line));
	seiun_append(out, cap, &len, "Process: %s\n", line);
	seiun_restore_last_error(lastError);
	seiun_describe_last_error(line, sizeof(line));
	seiun_append(out, cap, &len, "LastError: %s\n", line);

	seiun_append(out, cap, &len, "\n--- lime module probe ---\n");
	char probe[2048];
	seiun_probe_native_module(probe, sizeof(probe));
	seiun_append(out, cap, &len, "%s", probe);

	seiun_append_modules(out, cap, &len);
	return len;
}

// ── the funnel itself ───────────────────────────────────────────────────────

/**
 * Writes the report + pending marker, mirrors it to the platform log, shows the
 * dialog and returns (the caller decides how to exit: hxcpp's WinMain returns
 * -1, Haxe calls Sys.exit(1)).
 *
 * @param kind   short machine tag, also part of the file name ("haxe_uncaught")
 * @param msg    one line, shown in the dialog ("Could not load module lime@...")
 * @param detail optional multi-line text (exception stack, SDL error, ...)
 */
extern "C" void seiun_fatal_report(const char* kind, const char* msg, const char* detail)
{
	char* body = seiun_fatal_body;
	size_t cap = sizeof(seiun_fatal_body);
	int len = 0;

	const char* k = (kind != NULL && kind[0]) ? kind : "fatal";
	const char* m = (msg != NULL && msg[0]) ? msg : "(no message)";

	// The error code of whatever actually failed, before this reporter's own IO
	// overwrites it.
	char lastError[32];
	seiun_snapshot_last_error(lastError, sizeof(lastError));

	// File name: SeiunEngine_fatal_<kind>_<time>.txt - the "SeiunEngine_" prefix is
	// what tools/crash.py already matches, so triage finds these too.
	char prefix[96];
	int plen = 0;
	seiun_append(prefix, sizeof(prefix), &plen, "SeiunEngine_fatal_");
	for (const char* p = k; *p && plen < (int)sizeof(prefix) - 2; ++p)
	{
		char c = *p;
		if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_')
			prefix[plen++] = c;
		else
			prefix[plen++] = '_';
	}
	prefix[plen] = 0;
	seiun_make_path(seiun_fatal_path, sizeof(seiun_fatal_path), prefix);

	seiun_append_report_header(body, cap, &len, k);
	seiun_append(body, cap, &len, "Message: %s\n", m);

	// Explanation: what/why/fix, in both languages.
	{
		char explain[4096];
		seiun_explain_fatal(k, m, explain, sizeof(explain));
		seiun_append(body, cap, &len, "\n--- Diagnosis ---\n%s", explain);
	}

	seiun_append(body, cap, &len, "\n--- Environment ---\n");
	{
		char line[512];
		seiun_describe_os(line, sizeof(line));
		seiun_append(body, cap, &len, "OS: %s\n", line);
		seiun_describe_gpu(line, sizeof(line));
		seiun_append(body, cap, &len, "GPU: %s\n", line);
		if (seiun_env_info[0])
			seiun_append(body, cap, &len, "Env: %s\n", seiun_env_info);
		seiun_describe_process(line, sizeof(line));
		seiun_append(body, cap, &len, "Process: %s\n", line);
		seiun_restore_last_error(lastError);
		seiun_describe_last_error(line, sizeof(line));
		seiun_append(body, cap, &len, "LastError: %s\n", line);
		if (seiun_app_info[0])
			seiun_append(body, cap, &len, "App: %s\n", seiun_app_info);
	}
	seiun_append(body, cap, &len, "\n--- lime module probe ---\n");
	{
		char probe[2048];
		seiun_probe_native_module(probe, sizeof(probe));
		seiun_append(body, cap, &len, "%s", probe);
	}

	if (detail != NULL && detail[0] != 0)
	{
		seiun_append(body, cap, &len, "\n--- Detail ---\n%s\n", detail);
	}
	else
	{
		seiun_append(body, cap, &len, "\n--- Detail ---\n(none)\n");
	}

	seiun_append_engine_context(body, cap, &len);
#if defined(_WIN32)
	seiun_dbghelp_init();
	seiun_append_build_identity(body, cap, &len);
#else
	if (seiun_build_info[0])
		seiun_append(body, cap, &len, "\n--- Build identity ---\nBuild: %s\n", seiun_build_info);
#endif
	seiun_append_modules(body, cap, &len);
	seiun_append_triage(body, cap, &len);

	// 2. report on disk, 3. pending marker for the next launch.
	seiun_write_crash_file_at(seiun_fatal_path, body);
	seiun_mark_crash_pending_at(seiun_fatal_path);

	// 4. mirror: on a GUI build printf goes nowhere, so logcat/DebugView gets the
	// text instead. This also survives an unwritable crash directory.
#if defined(__ANDROID__)
	seiun_logcat_mirror(body);
#endif
#if defined(_WIN32)
	OutputDebugStringA(body);
#else
	fprintf(stderr, "%s\n", body);
#endif

	// 5. the dialog: short, human, with the report path and who to send it to.
	{
		char title[256];
		char msgBox[4096];
		char explain[1024];
		seiun_explain_fatal(k, m, explain, sizeof(explain));
		// Only the first paragraph of the explanation: a MessageBox is not a log.
		char* nl = strchr(explain, '\n');
		char* nl2 = nl ? strchr(nl + 1, '\n') : NULL;
		if (nl != NULL && nl2 != NULL) *(nl2 + 1) = 0;

		int isBoot = seiun_ci_contains(k, "boot") || seiun_ci_contains(k, "lime") ||
			seiun_ci_contains(k, "startup");
		snprintf(title, sizeof(title), "%s",
			isBoot ? "SeiunEngine 启动失败 / Startup failed"
				: "SeiunEngine 崩溃 / Crashed");

		int msgLen = 0;
		seiun_append(msgBox, sizeof(msgBox), &msgLen,
			"%.900s\n\n%.1200s\n\n崩溃报告已保存到 / Report saved to:\n%s\n\n"
			"请把这份报告发给开发者 / Please send this report to the developers.\n"
			"https://github.com/mohong2/FNF-SeiunEngine/issues\n",
			m, explain, seiun_fatal_path);
		seiun_show_dialog_platform(title, msgBox, seiun_dir[0] ? seiun_dir : "crash");
	}
}
