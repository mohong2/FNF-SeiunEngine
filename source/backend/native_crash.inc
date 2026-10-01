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
//    the unstripped .so by tools/gen_linemap.py, pushed to the device or
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

void seiun_set_crash_dir(const char* dir)
{
	if (dir == NULL || dir[0] == 0) return;
	size_t l = strlen(dir);
	if (l >= sizeof(seiun_dir) - 48) return;
	memcpy(seiun_dir, dir, l + 1);
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
#else
	return "unknown";
#endif
}

// ── crash linemap (precomputed DWARF line table, see tools/gen_linemap.py) ──
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

static void seiun_ensure_crash_dir(void)
{
#if defined(_WIN32)
	if (seiun_dir[0]) CreateDirectoryA(seiun_dir, NULL);
	else CreateDirectoryA("crash", NULL);
#else
	if (seiun_dir[0]) mkdir(seiun_dir, 0755);
	else mkdir("crash", 0755);
#endif
}

static void seiun_crash_path(char* path, size_t n)
{
	time_t t = time(NULL);
	struct tm tmv;
#if defined(_WIN32)
	localtime_s(&tmv, &t);
#else
	localtime_r(&t, &tmv);
#endif
	seiun_ensure_crash_dir();
	if (seiun_dir[0])
		snprintf(path, n, "%snative_crash_%04d%02d%02d_%02d%02d%02d.txt",
			seiun_dir,
			tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday, tmv.tm_hour, tmv.tm_min, tmv.tm_sec);
	else
		snprintf(path, n, "crash/native_crash_%04d%02d%02d_%02d%02d%02d.txt",
			tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday, tmv.tm_hour, tmv.tm_min, tmv.tm_sec);
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

static void seiun_mark_crash_pending(void);

/**
 * Opens every crash file with the same three lines, so the Windows SEH dump, the
 * abort() path, the LuaJIT panic and the POSIX signal handler all read (and
 * parse, see tools/crash_triage.py) exactly the same way.
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
static void seiun_write_crash_file(const char* body)
{
	FILE* f = fopen(seiun_crash_file(), "w");
	if (f != NULL)
	{
		fputs(body, f);
		fclose(f);
	}
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

static void seiun_write_crash_file_fd(const char* body, size_t len, int append)
{
	seiun_write_fd(seiun_crash_file(), body, len, append);
	seiun_mark_crash_pending();
}
#endif

// A one-shot marker for the Haxe layer: the native handler cannot safely run
// FlxG / CrashCatcherState itself, so the next launch consumes this file and
// shows the existing crash-catcher recovery screen (a graceful "rollback").
static void seiun_mark_crash_pending(void)
{
	char mpath[600];
	if (seiun_dir[0])
		snprintf(mpath, sizeof(mpath), "%snative_crash.pending", seiun_dir);
	else
		snprintf(mpath, sizeof(mpath), "crash/native_crash.pending");
#if defined(_WIN32)
	FILE* f = fopen(mpath, "w");
	if (f != NULL)
	{
		if (seiun_path[0] != 0)
			fputs(seiun_path, f);
		fputc('\n', f);
		fclose(f);
	}
#else
	char mbody[600];
	int ml = 0;
	if (seiun_path[0] != 0)
		seiun_append(mbody, sizeof(mbody), &ml, "%s\n", seiun_path);
	else
		seiun_append(mbody, sizeof(mbody), &ml, "\n");
	seiun_write_fd(mpath, mbody, (size_t)ml, 0);
#endif
}

// Best-effort OS popup. The process is already fatally broken, so failure is
// intentionally silent; after the popup the original crash path continues.
// (Android intentionally has none - the logcat mirror + next-launch recovery
// screen are the user-visible surface there.)
static void seiun_native_crash_popup(const char* path)
{
#if defined(_WIN32)
	char msg[1024];
	snprintf(msg, sizeof(msg),
		"A native crash has been recorded by SeiunEngine.\r\n\r\nLog: %s\r\n\r\nThe game will now exit.", path);
	MessageBoxA(NULL, msg, "SeiunEngine native crash", MB_OK | MB_ICONERROR | MB_TOPMOST);
#elif defined(__APPLE__) && defined(TARGET_OS_IPHONE) && !TARGET_OS_IPHONE
	char text[1024];
	snprintf(text, sizeof(text),
		"A native crash has been recorded by SeiunEngine.\n\nLog: %s\n\nThe game will now exit.", path);
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
		"A native crash has been recorded by SeiunEngine.\n\nLog: %s\n\nThe game will now exit.", path);
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
	if (GetModuleFileNameA(mod, path, (DWORD)sizeof(path)))
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
// "Module+0xRVA" that tools/mapresolve.py consumes.
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
	char exePath[MAX_PATH];
	exePath[0] = 0;
	HMODULE exeMod = GetModuleHandleA(NULL);
	GetModuleFileNameA(exeMod, exePath, (DWORD)sizeof(exePath));

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
		HANDLE h = CreateFileA(pdbPath, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
			OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
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
		GetModuleFileNameA(mod, modName, sizeof(modName));
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

	// The one actionable line: how to turn the offsets above into function names
	// with the symbol bundle published next to the release.
	seiun_append(body, cap, &len,
		"\n--- Triage ---\n"
		"python tools/mapresolve.py ApplicationMain.map <offset from the backtrace>\n"
		"(first check the map belongs to this exe:"
		" python tools/verify_map.py SeiunEngine.exe ApplicationMain.map)\n");
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
		seiun_write_crash_file(body);
#else
		{
			int btStart = len;
			seiun_append(body, cap, &len, "\nBacktrace (stack intact at panic time):\n");
			seiun_write_unwind_backtrace(body, cap, &len);
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
		char exePath[MAX_PATH];
		exePath[0] = 0;
		if (GetModuleFileNameA(NULL, exePath, (DWORD)sizeof(exePath)))
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
