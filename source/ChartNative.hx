package;

/**
 * Native (hxcpp C++) fast path for huge streamed charts.
 *
 * Two phases, both optional at the call site: a failure of either entry point returns null and
 * the caller falls back to the Haxe path (ChartStream + the generateSong note loop), so a
 * native problem can only cost speed, never correctness. On non-cpp targets every entry point
 * is a no-op.
 *
 * PHASE 1 - scanParts(): scans every part file once, in parallel across parts. Produces the
 * merged chart skeleton (chart-level bytes preserved exactly; one skeleton object per section
 * with "sectionNotes":[]), the raw chart-level events array of every part beyond the first, the
 * per-section sectionNotes byte ranges and scalars, and the exact note-entry count.
 *
 * PHASE 2 - foldParts(): parses the recorded sectionNotes byte ranges and folds them exactly
 * like PlayState.generateSong's note loop with the TurboDensity.GhostCollapser: representatives
 * get the final merged noteDensity, taps that merge produce no row, holds and every sustain row
 * are emitted as their own row. Rows are returned in chart (append) order; rowsSorted reports
 * whether that order is already strumTime-nondecreasing.
 *
 * Field semantics (must stay in sync with PlayState.generateSong):
 *  - flags bits: 0 mustPress, 1 isSustainNote, 2 isSustainEnd, 3 gfNote, 4 noAnimation,
 *    5 hitCausesMiss, 6 ignoreNote, 7 oppNote.
 *  - typeIdx: index into typeTable, -1 means the empty note type ('').
 *  - density: final noteDensity of a representative (1 for holds and sustain rows).
 *  - fedCount: raw notes consumed + emitted sustain rows (GhostCollapser.fedCount).
 */

typedef NativeScanResult = {
	var skeletonJson:String;
	var eventsJson:Array<String>;
	var noteCount:Float;
	var sawNegativeNote:Bool;
	var sectionCount:Int;
	var rangesStart:Array<Float>;
	var rangesLen:Array<Int>;
	var rangesPart:Array<Int>;
	/** Per section: bit0 mustHitSection, bit1 gfSection, bit2 changeBPM, bit3 altAnim. */
	var secFlags:Array<Int>;
	var secBpm:Array<Float>;
	var scanMs:Float;
};

typedef NativeFoldOptions = {
	var workers:Int;
	var laneCount:Int;
	var mania:Int;
	var isNewVersion:Bool;
	var songSpeed:Float;
	/** FlxMath.roundDecimal(songSpeed, 2): divisor of the sustain base offset. */
	var sustainSpeedDiv:Float;
	var playOpponent:Bool;
	var rewrite:Bool;
	var rewriteAmmo:Int;
	/** Conductor.stepCrochet at the start of the chart. */
	var stepCrochet:Float;
	var rangeMs:Float;
	var minGapPx:Float;
	var maniaScale:Float;
	/** Numeric note type index -> type name (default types followed by custom ones). */
	var typeNames:Array<String>;
};

typedef NativeFoldResult = {
	var strumTime:Array<Float>;
	var sustainLength:Array<Float>;
	var parentST:Array<Float>;
	var parentSL:Array<Float>;
	var stepCrochetAt:Array<Float>;
	var density:Array<Float>;
	var noteData:Array<Int>;
	var maniaAt:Array<Int>;
	var typeIdx:Array<Int>;
	/** bits: 0 mustPress, 1 isSustainNote, 2 isSustainEnd, 3 gfNote, 4 noAnimation,
	 *  5 hitCausesMiss, 6 ignoreNote, 7 oppNote. */
	var flags:Array<Int>;
	var typeTable:Array<String>;
	var fedCount:Float;
	var lastStrumTime:Float;
	var sawNegativeNote:Bool;
	/** True iff the emitted row strumTimes are nondecreasing, so the caller can skip sorting. */
	var rowsSorted:Bool;
	var foldMs:Float;
};

#if cpp
private extern class ChartNativeImpl
{
	@:native("seiun_chart_scan") public static function scan(paths:Array<String>, workers:Int):Int;
	@:native("seiun_chart_scan_skeleton") public static function scanSkeleton():String;
	@:native("seiun_chart_scan_events") public static function scanEvents():Array<String>;
	@:native("seiun_chart_scan_note_count") public static function scanNoteCount():Float;
	@:native("seiun_chart_scan_saw_negative") public static function scanSawNegative():Bool;
	@:native("seiun_chart_scan_section_count") public static function scanSectionCount():Int;
	@:native("seiun_chart_scan_ranges_start") public static function scanRangesStart():Array<Float>;
	@:native("seiun_chart_scan_ranges_len") public static function scanRangesLen():Array<Int>;
	@:native("seiun_chart_scan_ranges_part") public static function scanRangesPart():Array<Int>;
	@:native("seiun_chart_scan_sec_flags") public static function scanSecFlags():Array<Int>;
	@:native("seiun_chart_scan_sec_bpm") public static function scanSecBpm():Array<Float>;
	@:native("seiun_chart_scan_ms") public static function scanMs():Float;
	@:native("seiun_chart_scan_cleanup") public static function scanCleanup():Void;

	@:native("seiun_chart_fold") public static function fold(paths:Array<String>, start:Array<Float>, len:Array<Int>,
		part:Array<Int>, secFlags:Array<Int>, secBpm:Array<Float>, workers:Int, laneCount:Int, mania:Int,
		isNewVersion:Bool, songSpeed:Float, sustainSpeedDiv:Float, playOpponent:Bool, rewrite:Bool,
		rewriteAmmo:Int, stepCrochet:Float, rangeMs:Float, minGapPx:Float, maniaScale:Float,
		typeNames:Array<String>):Int;
	@:native("seiun_chart_fold_strum") public static function foldStrum():Array<Float>;
	@:native("seiun_chart_fold_sustain") public static function foldSustain():Array<Float>;
	@:native("seiun_chart_fold_parent_st") public static function foldParentST():Array<Float>;
	@:native("seiun_chart_fold_parent_sl") public static function foldParentSL():Array<Float>;
	@:native("seiun_chart_fold_step") public static function foldStep():Array<Float>;
	@:native("seiun_chart_fold_density") public static function foldDensity():Array<Float>;
	@:native("seiun_chart_fold_note_data") public static function foldNoteData():Array<Int>;
	@:native("seiun_chart_fold_mania") public static function foldMania():Array<Int>;
	@:native("seiun_chart_fold_type_idx") public static function foldTypeIdx():Array<Int>;
	@:native("seiun_chart_fold_flags") public static function foldFlags():Array<Int>;
	@:native("seiun_chart_fold_types") public static function foldTypes():Array<String>;
	@:native("seiun_chart_fold_fed") public static function foldFed():Float;
	@:native("seiun_chart_fold_last_strum") public static function foldLastStrum():Float;
	@:native("seiun_chart_fold_saw_negative") public static function foldSawNegative():Bool;
	@:native("seiun_chart_fold_rows_sorted") public static function foldRowsSorted():Bool;
	@:native("seiun_chart_fold_ms") public static function foldMs():Float;
	@:native("seiun_chart_fold_error") public static function foldError():String;
	@:native("seiun_chart_fold_cleanup") public static function foldCleanup():Void;
}
#end

@:headerCode('#include <string>
#include <vector>
extern int seiun_chart_scan(::Array< ::String > paths, int workers);
extern ::String seiun_chart_scan_skeleton();
extern ::Array< ::String > seiun_chart_scan_events();
extern double seiun_chart_scan_note_count();
extern bool seiun_chart_scan_saw_negative();
extern int seiun_chart_scan_section_count();
extern ::Array<double> seiun_chart_scan_ranges_start();
extern ::Array<int> seiun_chart_scan_ranges_len();
extern ::Array<int> seiun_chart_scan_ranges_part();
extern ::Array<int> seiun_chart_scan_sec_flags();
extern ::Array<double> seiun_chart_scan_sec_bpm();
extern double seiun_chart_scan_ms();
extern void seiun_chart_scan_cleanup();
extern int seiun_chart_fold(::Array< ::String > paths, ::Array<double> start, ::Array<int> len, ::Array<int> part,
	int workers, int laneCount, int mania, bool isNewVersion, double songSpeed, double sustainSpeedDiv,
	bool playOpponent, bool rewrite, int rewriteAmmo, double stepCrochet, double rangeMs, double minGapPx,
	double maniaScale, ::Array< ::String > typeNames);
extern ::Array<double> seiun_chart_fold_strum();
extern ::Array<double> seiun_chart_fold_sustain();
extern ::Array<double> seiun_chart_fold_parent_st();
extern ::Array<double> seiun_chart_fold_parent_sl();
extern ::Array<double> seiun_chart_fold_step();
extern ::Array<double> seiun_chart_fold_density();
extern ::Array<int> seiun_chart_fold_note_data();
extern ::Array<int> seiun_chart_fold_mania();
extern ::Array<int> seiun_chart_fold_type_idx();
extern ::Array<int> seiun_chart_fold_flags();
extern ::Array< ::String > seiun_chart_fold_types();
extern double seiun_chart_fold_fed();
extern double seiun_chart_fold_last_strum();
extern bool seiun_chart_fold_saw_negative();
extern bool seiun_chart_fold_rows_sorted();
extern double seiun_chart_fold_ms();
extern ::String seiun_chart_fold_error();
extern void seiun_chart_fold_cleanup();
extern double seiun_chart_debug_parse_wait_ms();
extern double seiun_chart_debug_fold_only_ms();extern double seiun_chart_debug_read_ms();
extern double seiun_chart_debug_decode_ms();
extern double seiun_chart_debug_blocks();
')
@:cppFileCode('// ============================================================================
// SeiunEngine native streaming-chart scanner + fold.
// Hand-written, allocation-light, two-phase implementation of
// ChartStream.scanParts + PlayState.generateSong\'s note loop (the GhostCollapser
// branch). Everything here is a translation unit local to ChartNative.cpp:
// Phase 1 - scanParts(): parallel per-part stream scan; builds the merged chart
//   skeleton (raw chart-level bytes preserved), per-section sectionNotes byte
//   ranges, per-section scalars and the exact note-entry count.
// Phase 2 - foldParts(): ordered pipeline. Worker threads pread the recorded
//   sectionNotes ranges and decode+normalise each note; one consumer thread
//   folds them in chart order with GhostCollapser semantics and appends packed
//   rows. No Haxe object is touched on a worker thread.
// Any anomaly -> return 0 so the Haxe caller falls back to the Haxe path.
// ============================================================================
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <cmath>
#include <string>
#include <vector>
#include <thread>
#include <atomic>
#include <mutex>
#include <algorithm>
#include <new>
#include <exception>

#include <chrono>

#if defined(_M_X64) || defined(_M_IX86) || defined(__SSE2__)
#define SEINATIVE_SSE2 1
#include <emmintrin.h>
#endif

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

namespace seinative {

// ChartSectionReader.MAX_RANGE_BYTES: a bigger sectionNotes value cannot be handed to Haxe either.
static const uint64_t MAX_RANGE_BYTES = 64ull * 1024ull * 1024ull;
// Safety caps: a chart past these would not be representable in the Haxe path either.
static const int MAX_SECTIONS = 20000000;
static const int MAX_WORKERS = 12;
static const uint64_t MAX_NOTE_ENTRIES = 20000000000ull;  // 2e10, huge but explicit
// Phase 2 chunk target: consecutive sections whose sectionNotes bytes sum to about this much.
static const uint64_t FOLD_CHUNK_BYTES = 96ull * 1024ull * 1024ull;
static const int FOLD_CHUNK_MAX_SECTIONS = 65536;
static const int MAX_EMITTED_ROWS = 60000000;
// GhostCollapser.MAX_REPRESENTED
static const double MAX_REPRESENTED = 65536.0;

struct FilePath
{
	std::string utf8;
#ifdef _WIN32
	std::wstring wide;
#endif
};

static std::string haxe_string_utf8(const ::String &s)
{
	const char *p = s.utf8_str();
	return p ? std::string(p) : std::string();
}

static void make_path(FilePath &dst, const ::String &s)
{
	dst.utf8 = haxe_string_utf8(s);
#ifdef _WIN32
	const wchar_t *w = s.wchar_str();
	dst.wide = w ? std::wstring(w) : std::wstring();
#endif
}

static FILE *open_read(const FilePath &p)
{
#ifdef _WIN32
	return _wfopen(p.wide.c_str(), L"rb");
#else
	return fopen(p.utf8.c_str(), "rb");
#endif
}

static inline int64_t now_ms()
{
	using namespace std::chrono;
	return (int64_t)duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

#ifdef _WIN32
static inline int64_t seek64(FILE *f, int64_t off, int whence) { return _fseeki64(f, off, whence); }
static inline int64_t tell64(FILE *f) { return _ftelli64(f); }
#else
static inline int64_t seek64(FILE *f, int64_t off, int whence) { return (int64_t)fseeko(f, (off_t)off, whence); }
static inline int64_t tell64(FILE *f) { return (int64_t)ftello(f); }
#endif

static int64_t file_size(FILE *f)
{
	if (!f) return -1;
	if (seek64(f, 0, SEEK_END) != 0) return -1;
	int64_t n = tell64(f);
	seek64(f, 0, SEEK_SET);
	return n;
}

static bool read_at(FILE *f, int64_t off, size_t len, std::vector<unsigned char> &buf)
{
	if (len > buf.size()) buf.resize(len);
	if (seek64(f, off, SEEK_SET) != 0) return false;
	size_t got = fread(buf.data(), 1, len, f);
	return got == len;
}

// UTF-8 encoding of one UTF-16 code unit (used by the note-type string decoder).
static void append_utf8_code_unit(std::string &out, unsigned int c)
{
	if (c < 0x80)
		out.push_back((char)c);
	else if (c < 0x800)
	{
		out.push_back((char)(0xC0 | (c >> 6)));
		out.push_back((char)(0x80 | (c & 0x3F)));
	}
	else if (c < 0x10000)
	{
		out.push_back((char)(0xE0 | (c >> 12)));
		out.push_back((char)(0x80 | ((c >> 6) & 0x3F)));
		out.push_back((char)(0x80 | (c & 0x3F)));
	}
	else
	{
		out.push_back((char)(0xF0 | (c >> 18)));
		out.push_back((char)(0x80 | ((c >> 12) & 0x3F)));
		out.push_back((char)(0x80 | ((c >> 6) & 0x3F)));
		out.push_back((char)(0x80 | (c & 0x3F)));
	}
}

static inline int seinative_ctz32(unsigned int v)
{
#ifdef _MSC_VER
	unsigned long idx = 0;
	_BitScanForward(&idx, v);
	return (int)idx;
#else
	return __builtin_ctz(v);
#endif
}

static inline bool is_finite(double v) { return std::isfinite(v); }

// Requested worker count <= 0 means "let the native side decide" (PlayState/Song pass 0).
// Cap below the hardware thread count: the work is I/O and memory bound, and the engine keeps
// other threads busy. Returns 1..MAX_NATIVE_AUTO_WORKERS.
static const int MAX_NATIVE_AUTO_WORKERS = 8;
static int auto_workers()
{
	unsigned hc = std::thread::hardware_concurrency();
	int w = (int)(hc ? hc : 4u);
	if (w > MAX_NATIVE_AUTO_WORKERS) w = MAX_NATIVE_AUTO_WORKERS;
	if (w < 1) w = 1;
	return w;
}

static inline bool is_ws(int c) { return c == \' \' || c == \'\\t\' || c == \'\\n\' || c == \'\\r\'; }
static inline bool is_digit(int c) { return c >= \'0\' && c <= \'9\'; }
static inline bool is_num_char(int c) { return is_digit(c) || c == \'-\' || c == \'+\' || c == \'.\' || c == \'e\' || c == \'E\'; }

// 10^n, exactly representable as a double for n <= 22 (same constants as ChartStream.pow10).
static inline double pow10_exact(int n)
{
	static const double tab[23] = {
		1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
		1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22};
	if (n >= 0 && n <= 22) return tab[n];
	return pow(10.0, (double)n);
}

// ────────────────────────────────────────────────────────────────────────────
// Sequential chunked reader (phase 1). Reads a part file front to back with an
// 8 MiB window; refill() keeps the unread tail so tokens spanning a chunk
// boundary stay visible.
// ────────────────────────────────────────────────────────────────────────────
class SeqReader
{
public:
	FILE *f = nullptr;
	std::vector<unsigned char> buf;
	uint64_t bufStart = 0;  // absolute file offset of buf[0]
	size_t bufLen = 0;
	size_t pos = 0;
	bool eof = false;

	bool open(const FilePath &p)
	{
		f = open_read(p);
		if (!f) return false;
		buf.resize(8u << 20);
		bufStart = 0;
		bufLen = 0;
		pos = 0;
		eof = false;
		return refill();
	}

	void close()
	{
		if (f)
		{
			fclose(f);
			f = nullptr;
		}
	}

	inline uint64_t abs_pos() const { return bufStart + (uint64_t)pos; }

	bool refill()
	{
		if (eof) return false;
		size_t keep = bufLen - pos;
		if (keep > 0 && pos > 0) memmove(buf.data(), buf.data() + pos, keep);
		bufStart += (uint64_t)pos;
		pos = 0;
		bufLen = keep;
		size_t want = buf.size() - bufLen;
		size_t got = want ? fread(buf.data() + bufLen, 1, want, f) : 0;
		bufLen += got;
		if (got == 0)
		{
			eof = true;
			return bufLen > 0;
		}
		return true;
	}

	inline int peek()
	{
		if (pos >= bufLen)
		{
			if (!refill()) return -1;
		}
		return buf[pos];
	}

	// Makes at least n bytes available from pos, when the file has them.
	bool ensure(size_t n)
	{
		while (bufLen - pos < n && !eof)
		{
			if (!refill()) break;
		}
		return bufLen - pos >= n;
	}
};

} // namespace seinative
namespace seinative {

// Per-part result of phase 1.
struct PartScan
{
	bool ok = false;
	std::string error;
	bool sawNotes = false;
	bool notesInSong = false;
	bool hasSongObj = false;
	bool hasRootEvents = false;
	bool hasSongEvents = false;
	std::string rootEvents;
	std::string songEvents;
	uint64_t noteCount = 0;
	bool sawNegative = false;
	std::vector<double> rangeStart;
	std::vector<int> rangeLen;
	std::vector<int> secFlags;
	std::vector<double> secBpm;
	std::vector<std::string> sections;
	std::string head;    // part 0: raw chart bytes before the notes array\'s \'[\'
	std::string suffix;  // part 0: raw chart bytes after the notes array\'s \']\'
};

struct RawScan
{
	bool ok = false;
	std::string error;
	std::string skeletonJson;
	std::vector<::String> eventsJson;   // empty ::String == Haxe null
	std::vector<double> rangesStart;
	std::vector<int> rangesLen;
	std::vector<int> rangesPart;
	std::vector<int> secFlags;
	std::vector<double> secBpm;
	std::vector<std::string> typeNames;  // unused by scan; kept for symmetry
	double noteCount = 0;
	bool sawNegativeNote = false;
	double scanMs = 0;
	int sectionCount = 0;
};

static RawScan g_scan;

// ────────────────────────────────────────────────────────────────────────────
// Phase 1 parser for one chart part.
// ────────────────────────────────────────────────────────────────────────────
class PartScanner
{
public:
	SeqReader r;
	PartScan *out = nullptr;
	bool isFirst = false;

	std::string *emit = nullptr;
	bool failed = false;
	std::string err;
	uint64_t notes = 0;
	int prevByte = -1;

	inline int peek() { return r.peek(); }

	inline int next()
	{
		int c = r.peek();
		if (c < 0) return -1;
		if (emit) emit->push_back((char)c);
		r.pos++;
		return c;
	}

	// next() that never copies to the skeleton (used while consuming sectionNotes bytes).
	inline int next_raw()
	{
		int c = r.peek();
		if (c < 0) return -1;
		r.pos++;
		return c;
	}

	void fail(const char *m)
	{
		if (!failed)
		{
			failed = true;
			err = m;
		}
	}

	void skipWs()
	{
		while (true)
		{
			int c = peek();
			if (!is_ws(c)) return;
			next();
		}
	}

	void skipWsRaw()
	{
		while (true)
		{
			int c = peek();
			if (!is_ws(c)) return;
			r.pos++;
		}
	}

	bool expect(int ch)
	{
		int c = next();
		if (c != ch)
		{
			fail("unexpected byte");
			return false;
		}
		return true;
	}

	bool literal(const char *s)
	{
		for (const char *p = s; *p; ++p)
		{
			if (next() != *p)
			{
				fail("bad literal");
				return false;
			}
		}
		return true;
	}

	// Reads one JSON string, optionally decoding it. Escaped chars are decoded exactly like
	// ChartStream.noteString: \\n \\t \\r \\b \\f, \\uXXXX and "anything else -> that byte".
	bool readString(std::string *decoded)
	{
		if (next() != \'"\')
		{
			fail("expected string");
			return false;
		}
		while (true)
		{
			int c = next();
			if (c < 0)
			{
				fail("unterminated string");
				return false;
			}
			if (c == \'\\\\\')
			{
				int e = next();
				if (e < 0)
				{
					fail("unterminated escape");
					return false;
				}
				switch (e)
				{
					case \'n\': if (decoded) decoded->push_back((char)10); break;
					case \'t\': if (decoded) decoded->push_back((char)9); break;
					case \'r\': if (decoded) decoded->push_back((char)13); break;
					case \'b\': if (decoded) decoded->push_back((char)8); break;
					case \'f\': if (decoded) decoded->push_back((char)12); break;
					case \'u\':
					{
						unsigned int v = 0;
						for (int i = 0; i < 4; i++)
						{
							int d = next();
							int hv;
							if (d >= \'0\' && d <= \'9\') hv = d - \'0\';
							else if (d >= \'a\' && d <= \'f\') hv = d - \'a\' + 10;
							else if (d >= \'A\' && d <= \'F\') hv = d - \'A\' + 10;
							else
							{
								fail("bad \\\\u escape");
								return false;
							}
							v = (v << 4) | (unsigned int)hv;
						}
						if (decoded) append_utf8_code_unit(*decoded, v);
						break;
					}
					default:
						if (decoded) decoded->push_back((char)e);
						break;
				}
			}
			else if (c == \'"\')
			{
				return true;
			}
			else if (decoded)
			{
				decoded->push_back((char)c);
			}
		}
	}

	bool skipString()
	{
		return readString(nullptr);
	}

	bool skipNumberValue()
	{
		bool any = false;
		while (true)
		{
			int c = peek();
			if (!is_num_char(c)) break;
			next();
			any = true;
		}
		if (!any) fail("expected number");
		return any;
	}

	// Generic JSON number token; value via strtod (used only for section scalars, never for notes).
	bool parseNumberValue(double *value)
	{
		std::string tok;
		while (true)
		{
			int c = peek();
			if (!is_num_char(c)) break;
			tok.push_back((char)c);
			next();
		}
		if (tok.empty())
		{
			fail("expected number");
			return false;
		}
		*value = strtod(tok.c_str(), nullptr);
		return true;
	}

	bool skipValue(int depth)
	{
		if (depth > 64)
		{
			fail("nesting too deep");
			return false;
		}
		int c = peek();
		if (c < 0)
		{
			fail("unexpected eof");
			return false;
		}
		if (is_ws(c)) skipWs();
		c = peek();
		if (c < 0)
		{
			fail("unexpected eof");
			return false;
		}
		switch (c)
		{
			case \'"\': return skipString();
			case \'{\': return skipObject(depth);
			case \'[\': return skipArray(depth);
			case \'t\': return literal("true");
			case \'f\': return literal("false");
			case \'n\': return literal("null");
			default: return skipNumberValue();
		}
	}

	bool skipObject(int depth)
	{
		if (!expect(\'{\')) return false;
		skipWs();
		if (peek() == \'}\')
		{
			next();
			return true;
		}
		while (true)
		{
			skipWs();
			if (!skipString()) return false;
			skipWs();
			if (!expect(\':\')) return false;
			skipWs();
			if (!skipValue(depth + 1)) return false;
			skipWs();
			int c = next();
			if (c == \'}\') return true;
			if (c != \',\')
			{
				fail("bad object separator");
				return false;
			}
		}
	}

	bool skipArray(int depth)
	{
		if (!expect(\'[\')) return false;
		skipWs();
		if (peek() == \']\')
		{
			next();
			return true;
		}
		while (true)
		{
			if (!skipValue(depth + 1)) return false;
			skipWs();
			int c = next();
			if (c == \']\') return true;
			if (c != \',\')
			{
				fail("bad array separator");
				return false;
			}
		}
	}

	// Consumes a sectionNotes value that starts with \'[\': counts its note entries (a \'[\' at
	// depth 1, exactly ChartStream.Cursor.skipValueFast) and flags a \'-\' that starts a number
	// at note-element depth (the legacy event-note marker). Returns after the matching \']\'.
	//
	// This is the phase-1 hot loop (>=95% of a huge chart\'s bytes), so the common case -- a run
	// of bytes that cannot affect the scanner state -- is skipped 16 bytes at a time with SSE2.
	// Only \'"\', \'[\', \']\', \'-\' and \'\\\' can change state; everything else (digits, \',\', \'.\',...)
	// is inert. That turns the per-note cost into two bracket handlers instead of ~22 bytes.
	bool skipNotesBody()
	{
		if (next() != \'[\')
		{
			fail("sectionNotes is not an array");
			return false;
		}
		int depth = 1;
		bool inStr = false;
		bool esc = false;
		uint64_t cnt = 0;
		int last = \'[\';
		while (true)
		{
			if (r.pos >= r.bufLen)
			{
				last = prevByte >= 0 ? prevByte : last;
				if (!r.refill())
				{
					fail("unterminated sectionNotes");
					return false;
				}
				continue;
			}
			const unsigned char *b = r.buf.data();
			size_t p = r.pos;
			const size_t end = r.bufLen;

			if (!inStr)
			{
				// Skip the inert run.
				while (p < end)
				{
#ifdef SEINATIVE_SSE2
					if (p + 16 <= end)
					{
						__m128i v = _mm_loadu_si128((const __m128i *)(b + p));
						__m128i m = _mm_or_si128(
							_mm_or_si128(_mm_cmpeq_epi8(v, _mm_set1_epi8(\'"\')), _mm_cmpeq_epi8(v, _mm_set1_epi8(\'[\'))),
							_mm_or_si128(_mm_or_si128(_mm_cmpeq_epi8(v, _mm_set1_epi8(\']\')), _mm_cmpeq_epi8(v, _mm_set1_epi8(\'-\'))),
								_mm_cmpeq_epi8(v, _mm_set1_epi8(\'\\\\\'))));
						int mask = _mm_movemask_epi8(m);
						if (mask == 0)
						{
							p += 16;
							continue;
						}
						unsigned int m32 = (unsigned int)mask;
						p += (size_t)seinative_ctz32(m32);
						break;
					}
#endif
					int c = (int)b[p];
					if (c == \'"\' || c == \'[\' || c == \']\' || c == \'-\' || c == \'\\\\\') break;
					p++;
				}
				if (p >= end)
				{
					prevByte = end > 0 ? (int)b[end - 1] : last;
					r.pos = end;
					continue;
				}
				int c = (int)b[p];
				if (c == \'"\')
				{
					inStr = true;
					p++;
				}
				else if (c == \'[\')
				{
					depth++;
					if (depth == 2) cnt++;
					p++;
				}
				else if (c == \']\')
				{
					depth--;
					if (depth == 0)
					{
						r.pos = p + 1;
						notes += cnt;
						prevByte = c;
						return true;
					}
					p++;
				}
				else if (c == \'-\' && depth == 2)
				{
					int prev = p > 0 ? (int)b[p - 1] : last;
					if (prev < 0 || prev == \'[\' || prev == \',\' || prev == \' \' || prev == \'\\t\' || prev == \'\\n\' || prev == \'\\r\')
						out->sawNegative = true;
					p++;
				}
				else
				{
					p++; // backslash outside a string: inert for the state machine
				}
				r.pos = p;
				prevByte = (int)b[p - 1];
				last = prevByte;
				continue;
			}

			// Inside a string: \'"\' and \'\\\' matter, everything else is inert.
			while (p < end)
			{
				int c = (int)b[p];
				if (esc)
				{
					esc = false;
					p++;
				}
				else if (c == \'\\\\\')
				{
					esc = true;
					p++;
				}
				else if (c == \'"\')
				{
					inStr = false;
					p++;
					break;
				}
				else
					p++;
			}
			prevByte = end > 0 ? (int)b[end - 1] : last;
			last = prevByte;
			r.pos = p;
			if (p >= end && !r.refill())
			{
				fail("unterminated sectionNotes");
				return false;
			}
		}
	}

	// Haxe truthiness of a JSON value (Dynamic condition): false for null/false/0/0.0/"".
	bool parseTruthy(bool *value)
	{
		int c = peek();
		if (c < 0)
		{
			fail("eof");
			return false;
		}
		switch (c)
		{
			case \'t\':
				*value = true;
				return literal("true");
			case \'f\':
				*value = false;
				return literal("false");
			case \'n\':
				*value = false;
				return literal("null");
			case \'"\':
			{
				std::string s;
				if (!readString(&s)) return false;
				*value = !s.empty();
				return true;
			}
			case \'{\':
				*value = true;
				return skipObject(0);
			case \'[\':
				*value = true;
				return skipArray(0);
			default:
			{
				double v = 0;
				if (!parseNumberValue(&v)) return false;
				*value = (v != 0);
				return true;
			}
		}
	}

	bool parseBpm(double *value)
	{
		int c = peek();
		if (c == \'"\' || c == \'{\' || c == \'[\' || c == \'t\' || c == \'f\' || c == \'n\')
		{
			*value = 0;
			return skipValue(0);
		}
		return parseNumberValue(value);
	}

	bool parseSection()
	{
		std::string sec;
		std::string *saved = emit;
		emit = &sec;
		bool ok = true;
		double rangeStart = 0;
		int rangeLen = 0;
		bool hasNotesKey = false;
		bool mustHit = false;
		bool gf = false;
		bool changeBpm = false;
		bool altAnim = false;
		double bpm = 0;

		if (next() != \'{\')
		{
			fail("expected section object");
			ok = false;
		}

		if (ok)
		{
			skipWs();
			bool anyField = false;
			if (peek() == \'}\')
			{
				next();
			}
			else
			{
				while (true)
				{
					skipWs();
					std::string key;
					if (!readString(&key)) { ok = false; break; }
					skipWs();
					if (!expect(\':\')) { ok = false; break; }
					skipWs();
					anyField = true;
					int c = peek();
					if (key == "sectionNotes")
					{
						if (hasNotesKey)
						{
							fail("duplicate sectionNotes");
							ok = false;
							break;
						}
						hasNotesKey = true;
						rangeStart = (double)r.abs_pos();
						sec += "[]";
						std::string *keep = emit;
						emit = nullptr;
						bool sok;
						if (c == \'[\') sok = skipNotesBody();
						else sok = skipValue(0);
						emit = keep;
						if (!sok) { ok = false; break; }
						uint64_t len = r.abs_pos() - (uint64_t)rangeStart;
						if (len > MAX_RANGE_BYTES)
						{
							fail("sectionNotes range over 64MB");
							ok = false;
							break;
						}
						rangeLen = (int)len;
					}
					else if (key == "mustHitSection")
					{
						if (!parseTruthy(&mustHit)) { ok = false; break; }
					}
					else if (key == "gfSection")
					{
						if (!parseTruthy(&gf)) { ok = false; break; }
					}
					else if (key == "changeBPM")
					{
						if (!parseTruthy(&changeBpm)) { ok = false; break; }
					}
					else if (key == "altAnim")
					{
						if (!parseTruthy(&altAnim)) { ok = false; break; }
					}
					else if (key == "bpm")
					{
						if (!parseBpm(&bpm)) { ok = false; break; }
					}
					else
					{
						if (!skipValue(0)) { ok = false; break; }
					}
					skipWs();
					int d = next();
					if (d == \'}\') break;
					if (d != \',\')
					{
						fail("bad section separator");
						ok = false;
						break;
					}
				}
			}
			if (ok && !hasNotesKey)
			{
				if (anyField) sec += ",\\"sectionNotes\\":[]";
				else sec += "\\"sectionNotes\\":[]";
			}
		}

		emit = saved;
		if (!ok) return false;

		out->sections.push_back(std::move(sec));
		out->rangeStart.push_back(rangeStart);
		out->rangeLen.push_back(rangeLen);
		out->secFlags.push_back((mustHit ? 1 : 0) | (gf ? 2 : 0) | (changeBpm ? 4 : 0) | (altAnim ? 8 : 0));
		out->secBpm.push_back(bpm);
		return true;
	}

	// Consumes a notes array. In part 0 the raw chart bytes around it are routed to head/suffix;
	// every part\'s section skeleton bytes are routed into out->sections.
	bool parseNotesArray(int kind)
	{
		(void)kind;
		std::string *saved = emit;
		emit = nullptr;
		if (next() != \'[\')
		{
			fail("notes is not an array");
			emit = saved;
			return false;
		}
		skipWsRaw();
		bool ok = true;
		if (peek() == \']\')
		{
			r.pos++;
		}
		else
		{
			while (true)
			{
				skipWsRaw();
				if (peek() != \'{\')
				{
					fail("notes entry is not an object");
					ok = false;
					break;
				}
				if (!parseSection()) { ok = false; break; }
				skipWsRaw();
				int c = next_raw();
				if (c == \']\') break;
				if (c != \',\')
				{
					fail("bad notes separator");
					ok = false;
					break;
				}
			}
		}
		if (isFirst) emit = &out->suffix;
		else emit = saved;
		return ok;
	}

	// Scans one JSON object level. kind: 0 = chart root, 1 = the root\'s direct "song" object,
	// 2 = any other nested object. Mirrors ChartStream.scanObject: only a direct root/song object
	// can own the section array and the chart-level events; a nested "song" key re-enables notes
	// scanning exactly like the Haxe scanner, so it is accepted only when it cannot be the owner.
	bool parseLevel(int kind, bool allowNotes)
	{
		if (next() != \'{\')
		{
			fail("expected object");
			return false;
		}
		skipWs();
		if (peek() == \'}\')
		{
			next();
			return true;
		}
		while (true)
		{
			skipWs();
			std::string key;
			if (!readString(&key)) return false;
			skipWs();
			if (!expect(\':\')) return false;
			skipWs();
			int c = peek();
			if (allowNotes && key == "notes" && c == \'[\')
			{
				if (kind != 0 && kind != 1)
				{
					fail("section array outside chart root/song");
					return false;
				}
				if (out->sawNotes)
				{
					fail("more than one section array");
					return false;
				}
				out->sawNotes = true;
				out->notesInSong = (kind == 1);
				if (!parseNotesArray(kind)) return false;
			}
			else if (key == "song" && c == \'{\')
			{
				if (kind == 0) out->hasSongObj = true;
				if (!parseLevel(kind == 0 ? 1 : 2, true)) return false;
			}
			else if (c == \'{\')
			{
				if (!parseLevel(2, false)) return false;
			}
			else if (key == "events" && (kind == 0 || kind == 1))
			{
				bool isArray = (c == \'[\');
				std::string text;
				std::string *saved = emit;
				if (!isFirst)
				{
					emit = &text;
					if (!skipValue(0))
					{
						emit = saved;
						return false;
					}
					emit = saved;
				}
				else if (!skipValue(0))
					return false;
				if (!isFirst)
				{
					std::string *target = (kind == 0) ? &out->rootEvents : &out->songEvents;
					bool *has = (kind == 0) ? &out->hasRootEvents : &out->hasSongEvents;
					if (isArray)
					{
						*target = std::move(text);
						*has = true;
					}
					else
					{
						target->clear();
						*has = false;
						*has = false;
					}
				}
			}
			else
			{
				if (!skipValue(0)) return false;
			}
			skipWs();
			int d = next();
			if (d == \'}\') return true;
			if (d != \',\')
			{
				fail("bad object separator");
				return false;
			}
		}
	}

	bool run(const FilePath &path)
	{
		if (!r.open(path))
		{
			fail("cannot open part file");
			return false;
		}
		if (isFirst) emit = &out->head;
		skipWs();
		if (!parseLevel(0, true))
		{
			r.close();
			return false;
		}
		skipWsRaw();
		if (peek() != -1)
		{
			fail("trailing bytes after chart root");
			r.close();
			return false;
		}
		r.close();
		if (!out->sawNotes)
		{
			fail("no section array");
			return false;
		}
		if (notes > MAX_NOTE_ENTRIES)
		{
			fail("too many note entries");
			return false;
		}
		out->noteCount = notes;
		out->ok = true;
		return true;
	}
};

static void run_one_part(const FilePath &path, int index, PartScan &result)
{
	PartScanner sc;
	sc.out = &result;
	sc.isFirst = (index == 0);
	if (!sc.run(path))
	{
		result.ok = false;
		result.error = sc.err;
	}
}

static void clear_scan()
{
	g_scan.ok = false;
	g_scan.error.clear();
	g_scan.skeletonJson.clear();
	g_scan.eventsJson.clear();
	g_scan.rangesStart.clear();
	g_scan.rangesLen.clear();
	g_scan.rangesPart.clear();
	g_scan.secFlags.clear();
	g_scan.secBpm.clear();
	g_scan.typeNames.clear();
	g_scan.noteCount = 0;
	g_scan.sawNegativeNote = false;
	g_scan.scanMs = 0;
	g_scan.sectionCount = 0;
}

static int run_scan(const ::Array< ::String > &paths, int workers)
{
	clear_scan();
	const int n = paths.mPtr ? paths->length : 0;
	if (n < 1 || n > 4096)
	{
		g_scan.error = "bad part count";
		return 0;
	}
	std::vector<FilePath> files((size_t)n);
	for (int i = 0; i < n; i++)
	{
		const ::String &s = paths->__get(i);
		make_path(files[(size_t)i], s);
	}

	int64_t started = now_ms();

	std::vector<PartScan> parts((size_t)n);
	int w = workers;
	if (w <= 0) w = auto_workers();
	if (w < 1) w = 1;
	if (w > MAX_WORKERS) w = MAX_WORKERS;
	if (w > n) w = n;
	std::atomic<int> nextPart(0);
	std::vector<std::thread> threads;
	threads.reserve((size_t)w);
	for (int t = 0; t < w; t++)
	{
		threads.emplace_back([&]() {
			for (;;)
			{
				int i = nextPart.fetch_add(1);
				if (i >= n) return;
				run_one_part(files[(size_t)i], i, parts[(size_t)i]);
			}
		});
	}
	for (auto &th : threads) th.join();
	threads.clear();

	// Validate + merge in part order.
	uint64_t totalSections = 0;
	double totalNotes = 0;
	bool sawNeg = false;
	for (int i = 0; i < n; i++)
	{
		PartScan &p = parts[(size_t)i];
		if (!p.ok)
		{
			g_scan.error = "part " + std::to_string(i) + ": " + p.error;
			return 0;
		}
		if (p.rangeStart.size() != p.secFlags.size() || p.rangeStart.size() != p.secBpm.size() ||
			p.rangeStart.size() != p.rangeLen.size())
		{
			g_scan.error = "part section table mismatch";
			return 0;
		}
		totalSections += p.rangeStart.size();
		if (totalSections > (uint64_t)MAX_SECTIONS)
		{
			g_scan.error = "too many sections";
			return 0;
		}
		totalNotes += (double)p.noteCount;
		if (p.sawNegative) sawNeg = true;
	}

	// Assemble the merged skeleton: part 0\'s chart wrapper with its section array replaced by
	// the concatenation of every part\'s section skeletons.
	const PartScan &first = parts[0];
	if (!first.sawNotes)
	{
		g_scan.error = "part 0 has no section array";
		return 0;
	}
	size_t skeletonSize = first.head.size() + first.suffix.size() + 2;
	for (int i = 0; i < n; i++)
	{
		for (const std::string &s : parts[(size_t)i].sections) skeletonSize += s.size() + 1;
	}
	std::string skel;
	skel.reserve(skeletonSize);
	skel.append(first.head);
	skel.push_back(\'[\');
	bool firstSection = true;
	for (int i = 0; i < n; i++)
	{
		for (const std::string &s : parts[(size_t)i].sections)
		{
			if (!firstSection) skel.push_back(\',\');
			firstSection = false;
			skel.append(s);
		}
	}
	skel.push_back(\']\');
	skel.append(first.suffix);
	g_scan.skeletonJson = std::move(skel);

	// eventsJson: [0] is null (part 0\'s events are inside skeletonJson); i>=1 is the raw
	// chart-level events array of that part, or null when the part has none / a non-array.
	g_scan.eventsJson.resize((size_t)n);
	for (int i = 1; i < n; i++)
	{
		PartScan &p = parts[(size_t)i];
		if (p.hasSongObj ? p.hasSongEvents : p.hasRootEvents)
		{
			const std::string &text = p.hasSongObj ? p.songEvents : p.rootEvents;
			g_scan.eventsJson[(size_t)i] = ::String::create(text.c_str(), (int)text.size());
		}
	}

	g_scan.rangesStart.reserve(totalSections);
	g_scan.rangesLen.reserve(totalSections);
	g_scan.rangesPart.reserve(totalSections);
	g_scan.secFlags.reserve(totalSections);
	g_scan.secBpm.reserve(totalSections);
	for (int i = 0; i < n; i++)
	{
		PartScan &p = parts[(size_t)i];
		const size_t cnt = p.rangeStart.size();
		g_scan.rangesStart.insert(g_scan.rangesStart.end(), p.rangeStart.begin(), p.rangeStart.end());
		g_scan.rangesLen.insert(g_scan.rangesLen.end(), p.rangeLen.begin(), p.rangeLen.end());
		g_scan.rangesPart.insert(g_scan.rangesPart.end(), cnt, i);
		g_scan.secFlags.insert(g_scan.secFlags.end(), p.secFlags.begin(), p.secFlags.end());
		g_scan.secBpm.insert(g_scan.secBpm.end(), p.secBpm.begin(), p.secBpm.end());
	}
	g_scan.sectionCount = (int)totalSections;
	g_scan.noteCount = totalNotes;
	g_scan.sawNegativeNote = sawNeg;
	g_scan.ok = true;
	g_scan.scanMs = (double)(now_ms() - started);
	// free per-part buffers as soon as the merged copy exists
	for (int i = 0; i < n; i++)
	{
		parts[(size_t)i].sections.clear();
		parts[(size_t)i].head.clear();
		parts[(size_t)i].suffix.clear();
	}
	return 1;
}

} // namespace seinative
namespace seinative {

struct RawFold
{
	bool ok = false;
	std::string error;
	std::vector<double> strumTime;
	std::vector<double> sustainLength;
	std::vector<double> parentST;
	std::vector<double> parentSL;
	std::vector<double> stepCrochetAt;
	std::vector<double> density;
	std::vector<int> noteData;
	std::vector<int> maniaAt;
	std::vector<int> typeIdx;
	std::vector<int> flags;
	std::vector<::String> typeTable;
	double fedCount = 0;
	double lastStrumTime = 0;
	double foldMs = 0;
	bool sawNegativeNote = false;
	bool rowsSorted = true;
};

static RawFold g_fold;
static int64_t g_debug_parse_wait_ms = 0;
static int64_t g_debug_fold_only_ms = 0;
static std::atomic<int64_t> g_dbg_read_ms(0);
static std::atomic<int64_t> g_dbg_decode_ms(0);
static std::atomic<int64_t> g_dbg_blocks(0);

// Frees every emitted column, capacity included. A fold that failed halfway can hold hundreds of
// megabytes, and none of it may stay resident while the Haxe fallback builds the note list instead.
static void clear_fold_rows()
{
	std::vector<double>().swap(g_fold.strumTime);
	std::vector<double>().swap(g_fold.sustainLength);
	std::vector<double>().swap(g_fold.parentST);
	std::vector<double>().swap(g_fold.parentSL);
	std::vector<double>().swap(g_fold.stepCrochetAt);
	std::vector<double>().swap(g_fold.density);
	std::vector<int>().swap(g_fold.noteData);
	std::vector<int>().swap(g_fold.maniaAt);
	std::vector<int>().swap(g_fold.typeIdx);
	std::vector<int>().swap(g_fold.flags);
	std::vector<::String>().swap(g_fold.typeTable);
}

static void seinative_reset_debug_counters()
{
	g_dbg_read_ms.store(0);
	g_dbg_decode_ms.store(0);
	g_dbg_blocks.store(0);
}

// Type name -> (typeIdx, typeFlags) where typeFlags bit0 Alt, bit1 Hurt, bit2 GF Sing, bit3 No Animation.
struct TypeInterner
{
	std::mutex mtx;
	std::vector<std::string> names;
	std::vector<unsigned char> flags;

	static unsigned char compute_flags(const std::string &name)
	{
		unsigned char f = 0;
		if (name == "Alt Animation") f |= 1;
		if (name == "Hurt Note") f |= 2;
		if (name == "GF Sing") f |= 4;
		if (name == "No Animation") f |= 8;
		return f;
	}

	// Returns -1 for the empty type (\'\' is not interned: typeIdx -1 means it).
	int intern(const std::string &name, unsigned char *outFlags)
	{
		if (name.empty())
		{
			*outFlags = 0;
			return -1;
		}
		std::lock_guard<std::mutex> lock(mtx);
		for (size_t i = 0; i < names.size(); i++)
		{
			if (names[i] == name)
			{
				*outFlags = flags[i];
				return (int)i;
			}
		}
		unsigned char f = compute_flags(name);
		names.push_back(name);
		flags.push_back(f);
		*outFlags = f;
		return (int)names.size() - 1;
	}
};

struct FoldCfg
{
	int workers = 1;
	int laneCount = 4;
	int mania = 3;
	bool isNewVersion = true;
	bool playOpponent = false;
	bool rewrite = false;
	int rewriteAmmo = 4;
	double songSpeed = 1.0;
	double sustainSpeedDiv = 1.0;
	double stepCrochet = 0.0;
	double rangeMs = 1.0;
	double minGapPx = 4.0;
	double maniaScale = 1.0;
	double pxPerMs = 0.0;
	std::vector<std::string> typeNames;
	std::vector<double> stepAt;  // per section: stepCrochet in effect
};

struct FoldSource
{
	std::vector<FilePath> files;
	std::vector<double> start;
	std::vector<int> len;
	std::vector<int> part;
	std::vector<int> secFlags;
	std::vector<double> secBpm;
	int sectionCount = 0;
};

struct BlockNotes
{
	int secBegin = 0;
	std::vector<int> secNoteStart;
	std::vector<int> secNoteCount;
	std::vector<double> strum;
	std::vector<double> sustain;
	std::vector<int> noteData;
	std::vector<int> typeIdx;
	std::vector<int> flags;
	std::vector<int> typeFlags;
	bool ok = true;
	std::string error;
};

struct ParsedChunk
{
	int secBegin = 0;
	int secEnd = 0;
	std::vector<BlockNotes> blocks;
	bool ok = true;
	std::string error;

	void clear()
	{
		secBegin = 0;
		secEnd = 0;
		blocks.clear();
		ok = true;
		error.clear();
	}
};

} // namespace seinative
namespace seinative {

// ────────────────────────────────────────────────────────────────────────────
// Byte-range note parser for phase 2: exactly ChartStream.parseSectionNotes, plus the
// per-note normalisation the PlayState loop performs before the GhostCollapser fold.
// ────────────────────────────────────────────────────────────────────────────
struct MemScan
{
	const unsigned char *p = nullptr;
	const unsigned char *end = nullptr;

	inline int cur() const { return p < end ? (int)*p : -1; }
	inline int next() { return p < end ? (int)*p++ : -1; }
	inline bool expect(int c) { return next() == c; }

	inline void ws()
	{
		while (p < end && is_ws(*p)) p++;
	}

	// ChartStream.noteNumber, bit for bit: collect an integer mantissa and a fraction-digit
	// count, then divide by an exact power of ten; fall back to strtod only for exponents,
	// zero-digit tokens and more-than-15-digit mantissas (where ChartStream falls back to
	// Std.parseFloat).
	bool number(double *out)
	{
		const unsigned char *start = p;
		bool neg = false;
		if (p < end && *p == \'-\')
		{
			neg = true;
			p++;
		}
		else if (p < end && *p == \'+\')
			p++;

		// Integer mantissa: for <= 15 significant digits every intermediate value is an exact
		// integer below 2^53, so uint64 accumulation gives the same double as ChartStream\'s
		// double accumulation while staying off the 4-cycle FP multiply chain.
		uint64_t mant = 0;
		int digits = 0;
		while (p < end && is_digit(*p))
		{
			mant = mant * 10 + (uint64_t)(*p - \'0\');
			digits++;
			p++;
		}
		int frac = 0;
		if (p < end && *p == \'.\')
		{
			p++;
			while (p < end && is_digit(*p))
			{
				mant = mant * 10 + (uint64_t)(*p - \'0\');
				frac++;
				digits++;
				p++;
			}
		}
		if (digits == 0 || digits > 15 || (p < end && (*p == \'e\' || *p == \'E\')))
		{
			const unsigned char *stop = p;
			while (stop < end && is_num_char(*stop)) stop++;
			std::string tok((const char *)start, (size_t)(stop - start));
			*out = strtod(tok.c_str(), nullptr);
			p = stop;
			return true;
		}
		double v = (frac > 0) ? (double)mant / pow10_exact(frac) : (double)mant;
		*out = neg ? -v : v;
		return true;
	}

	// ChartStream.noteString decoding.
	bool string(std::string *out)
	{
		if (!expect(\'"\')) return false;
		while (true)
		{
			int c = next();
			if (c < 0) return false;
			if (c == \'\\\\\')
			{
				int e = next();
				if (e < 0) return false;
				switch (e)
				{
					case \'n\': out->push_back((char)10); break;
					case \'t\': out->push_back((char)9); break;
					case \'r\': out->push_back((char)13); break;
					case \'b\': out->push_back((char)8); break;
					case \'f\': out->push_back((char)12); break;
					case \'u\':
					{
						unsigned int v = 0;
						for (int i = 0; i < 4; i++)
						{
							int d = next();
							int hv;
							if (d >= \'0\' && d <= \'9\') hv = d - \'0\';
							else if (d >= \'a\' && d <= \'f\') hv = d - \'a\' + 10;
							else if (d >= \'A\' && d <= \'F\') hv = d - \'A\' + 10;
							else return false;
							v = (v << 4) | (unsigned int)hv;
						}
						append_utf8_code_unit(*out, v);
						break;
					}
					default: out->push_back((char)e); break;
				}
			}
			else if (c == \'"\')
			{
				return true;
			}
			else
			{
				out->push_back((char)c);
			}
		}
	}
};

// Worker-local type resolution cache (numeric indices resolved once per worker block).
struct TypeCache
{
	std::vector<int> numIdx;
	std::vector<unsigned char> numFlags;
	std::string lastString;
	int lastStringIdx = -2;
	unsigned char lastStringFlags = 0;

	void init(size_t typeNamesCount)
	{
		numIdx.assign(typeNamesCount, -2);
		numFlags.assign(typeNamesCount, 0);
	}
};

static inline void resolve_type(bool hasType, bool isString, const std::string &sval, double nval,
	const FoldCfg &cfg, TypeInterner &interner, TypeCache &tc, int *outIdx, unsigned char *outFlags)
{
	if (!hasType)
	{
		*outIdx = -1;
		*outFlags = 0;
		return;
	}
	if (isString)
	{
		if (sval.empty())
		{
			*outIdx = -1;
			*outFlags = 0;
			return;
		}
		if (tc.lastStringIdx >= -1 && tc.lastString == sval)
		{
			*outIdx = tc.lastStringIdx;
			*outFlags = tc.lastStringFlags;
			return;
		}
		unsigned char f = 0;
		int idx = interner.intern(sval, &f);
		tc.lastString = sval;
		tc.lastStringIdx = idx;
		tc.lastStringFlags = f;
		*outIdx = idx;
		*outFlags = f;
		return;
	}
	// numeric resolve: Std.int(nval) (trunc toward zero); non-finite / out of int32 -> empty.
	int idx = -2147483647 - 1;
	if (is_finite(nval) && nval >= -2147483648.0 && nval <= 2147483647.0) idx = (int)nval;
	if (idx < 0 || idx >= (int)cfg.typeNames.size())
	{
		*outIdx = -1;
		*outFlags = 0;
		return;
	}
	if (tc.numIdx[(size_t)idx] != -2)
	{
		*outIdx = tc.numIdx[(size_t)idx];
		*outFlags = tc.numFlags[(size_t)idx];
		return;
	}
	unsigned char f = 0;
	int resolved = interner.intern(cfg.typeNames[(size_t)idx], &f);
	tc.numIdx[(size_t)idx] = resolved;
	tc.numFlags[(size_t)idx] = f;
	*outIdx = resolved;
	*outFlags = f;
}

} // namespace seinative
namespace seinative {

// Parses one sectionNotes byte range and appends decoded+normalised note events to blk.
// Returns false on any anomaly (the caller then falls back to the Haxe path).
static bool parse_notes_range(const unsigned char *data, size_t len, const FoldSource &src, int secIndex,
	const FoldCfg &cfg, BlockNotes &blk, TypeInterner &interner, TypeCache &tc)
{
	MemScan ms;
	ms.p = data;
	ms.end = data + len;
	int secFlag = src.secFlags[(size_t)secIndex];
	bool mustHit = (secFlag & 1) != 0;
	bool gfSec = (secFlag & 2) != 0;

	ms.ws();
	if (!ms.expect(\'[\')) return false;
	ms.ws();
	if (ms.cur() == \']\')
	{
		ms.p++;
		ms.ws();
		return ms.p == ms.end;
	}
	while (true)
	{
		ms.ws();
		if (!ms.expect(\'[\')) return false;
		double strum = 0.0;
		double dataV = 0.0;
		double sus = 0.0;
		bool hasType = false;
		bool typeIsString = false;
		double typeNum = 0.0;
		std::string typeStr;
		int count = 0;
		ms.ws();
		// Fast path: the normal chart shape is exactly three plain non-negative numbers. It
		// avoids the generic per-element dispatch for essentially every note of a real chart.
		bool fastDone = false;
		if (is_digit(ms.cur()))
		{
			const unsigned char *save = ms.p;
			if (ms.number(&strum))
			{
				ms.ws();
				if (ms.cur() == \',\')
				{
					ms.p++;
					ms.ws();
					if (is_digit(ms.cur()) && ms.number(&dataV))
					{
						ms.ws();
						if (ms.cur() == \',\')
						{
							ms.p++;
							ms.ws();
							if (is_digit(ms.cur()) && ms.number(&sus))
							{
								ms.ws();
								if (ms.cur() == \']\')
								{
									ms.p++;
									fastDone = true;
									count = 3;
								}
							}
						}
					}
				}
			}
			if (!fastDone) ms.p = save;
		}
		while (!fastDone)
		{
			ms.ws();
			int c = ms.cur();
			if (c < 0) return false;
			if (c == \']\')
			{
				ms.p++;
				break;
			}
			bool isNull = false;
			bool isStr = false;
			double nval = 0.0;
			if (c == \'"\')
			{
				if (!ms.string(&typeStr)) return false;
				isStr = true;
			}
			else if (c == \'n\')
			{
				if (ms.end - ms.p < 4 || memcmp(ms.p, "null", 4) != 0) return false;
				ms.p += 4;
				isNull = true;
			}
			else if (c == \'t\')
			{
				if (ms.end - ms.p < 4 || memcmp(ms.p, "true", 4) != 0) return false;
				ms.p += 4;
				nval = 1.0;
			}
			else if (c == \'f\')
			{
				if (ms.end - ms.p < 5 || memcmp(ms.p, "false", 5) != 0) return false;
				ms.p += 5;
				nval = 0.0;
			}
			else
			{
				if (!ms.number(&nval)) return false;
			}
			if (nval < 0) return false;  // legacy event notes are negative: let the Haxe path take it
			if (isStr)
			{
				hasType = true;
				typeIsString = true;
			}
			else if (!isNull)
			{
				if (count == 0)
					strum = nval;
				else if (count == 1)
					dataV = nval;
				else if (count == 2)
					sus = nval;
				else
				{
					hasType = true;
					typeIsString = false;
					typeNum = nval;
				}
			}
			count++;
			ms.ws();
			int d = ms.cur();
			if (d == \',\')
			{
				ms.p++;
				continue;
			}
			if (d == \']\')
			{
				ms.p++;
				break;
			}
			return false;
		}

		if (!is_finite(strum) || !is_finite(dataV) || !is_finite(sus) || !is_finite(typeNum)) return false;
		if (dataV < -2147483648.0 || dataV > 2147483647.0) return false;
		int rawData = (int)dataV;  // Std.int truncation

		if (cfg.rewrite && rawData >= 0)
		{
			if (cfg.rewriteAmmo <= 0) return false;
			bool rewriteHit = (rawData < cfg.rewriteAmmo) ? mustHit : !mustHit;
			rawData = (rawData % cfg.rewriteAmmo) + (rewriteHit ? 0 : cfg.rewriteAmmo);
		}
		int noteDataIdx = rawData % cfg.laneCount;

		bool gottaHit;
		if (cfg.isNewVersion)
			gottaHit = (rawData < cfg.laneCount);
		else
			gottaHit = (rawData >= cfg.laneCount) ? !mustHit : mustHit;
		bool isGFSide = gfSec && (gottaHit == mustHit);
		if (cfg.playOpponent) gottaHit = !gottaHit;

		int tIdx;
		unsigned char tFlags;
		resolve_type(hasType, typeIsString, typeStr, typeNum, cfg, interner, tc, &tIdx, &tFlags);

		int fl = 0;
		if (gottaHit) fl |= 1;
		if (isGFSide || (tFlags & 4) != 0) fl |= 8;
		if ((tFlags & 8) != 0) fl |= 16;
		if ((tFlags & 2) != 0) fl |= 32;
		if ((tFlags & 2) != 0 && gottaHit) fl |= 64;
		bool opp = cfg.playOpponent ? gottaHit : !gottaHit;
		if (opp) fl |= 128;

		blk.strum.push_back(strum);
		blk.sustain.push_back(sus);
		blk.noteData.push_back(noteDataIdx);
		blk.typeIdx.push_back(tIdx);
		blk.flags.push_back(fl);
		blk.typeFlags.push_back((int)tFlags);

		ms.ws();
		int d = ms.cur();
		if (d == \',\')
		{
			ms.p++;
			continue;
		}
		if (d == \']\')
		{
			ms.p++;
			break;
		}
		return false;
	}
	ms.ws();
	return ms.p == ms.end;
}

static void parse_block(const FoldSource &src, const FoldCfg &cfg, ParsedChunk &chunk, int blockIndex,
	int blockBegin, int blockEnd, TypeInterner &interner)
{
	BlockNotes &blk = chunk.blocks[(size_t)blockIndex];
	blk.secBegin = blockBegin;
	TypeCache tc;
	tc.init(cfg.typeNames.size());
	std::vector<FILE *> handles(src.files.size(), nullptr);
	std::vector<unsigned char> buf;
	const int expected = blockEnd - blockBegin;
	blk.secNoteStart.reserve((size_t)expected);
	blk.secNoteCount.reserve((size_t)expected);
	{
		// ~21 bytes per 3-element note entry: reserve once so no worker pays for vector growth.
		uint64_t blockBytes = 0;
		for (int s = blockBegin; s < blockEnd; s++) blockBytes += (uint64_t)src.len[(size_t)s];
		size_t est = (size_t)(blockBytes / 21);
		blk.strum.reserve(est);
		blk.sustain.reserve(est);
		blk.noteData.reserve(est);
		blk.typeIdx.reserve(est);
		blk.flags.reserve(est);
		blk.typeFlags.reserve(est);
	}
	bool ok = true;
	std::string error;
	for (int s = blockBegin; s < blockEnd; s++)
	{
		int startIdx = (int)blk.strum.size();
		int len = src.len[(size_t)s];
		int cnt = 0;
		if (len > 0)
		{
			int pi = src.part[(size_t)s];
			if (pi < 0 || pi >= (int)handles.size())
			{
				ok = false;
				error = "bad part index";
				break;
			}
			FILE *f = handles[(size_t)pi];
			if (!f)
			{
				f = open_read(src.files[(size_t)pi]);
				if (!f)
				{
					ok = false;
					error = "cannot open part file";
					break;
				}
				handles[(size_t)pi] = f;
			}
			int64_t tr = now_ms();
			if (!read_at(f, (int64_t)src.start[(size_t)s], (size_t)len, buf))
			{
				ok = false;
				error = "cannot read sectionNotes range";
				break;
			}
			g_dbg_read_ms.fetch_add(now_ms() - tr);
			int64_t td = now_ms();
			if (!parse_notes_range(buf.data(), (size_t)len, src, s, cfg, blk, interner, tc))
			{
				ok = false;
				error = "sectionNotes parse failure";
				break;
			}
			g_dbg_decode_ms.fetch_add(now_ms() - td);
			cnt = (int)blk.strum.size() - startIdx;
		}
		blk.secNoteStart.push_back(startIdx);
		blk.secNoteCount.push_back(cnt);
	}
	g_dbg_blocks.fetch_add(1);
	for (size_t i = 0; i < handles.size(); i++)
	{
		if (handles[i]) fclose(handles[i]);
	}
	if (!ok)
	{
		// Only this worker\'s block is touched here. ParsedChunk.ok/error belong to the consumer
		// thread, which aggregates block failures after joining the workers (chunk_failed()).
		blk.ok = false;
		blk.error = error;
	}
}

} // namespace seinative
namespace seinative {

struct FoldState
{
	std::vector<double> lastTime;
	std::vector<double> lastRate;
	std::vector<double> lastSlowRate;
	std::vector<double> lastDensity;
	std::vector<int> anchorRow;

	void init(int laneCount)
	{
		const int slots = laneCount * 2;
		lastTime.assign((size_t)slots, -1e30);
		lastRate.assign((size_t)slots, 0.0);
		lastSlowRate.assign((size_t)slots, 0.0);
		lastDensity.assign((size_t)slots, 0.0);
		anchorRow.assign((size_t)slots, -1);
	}
};

static inline void emit_row(RawFold &out, double strum, double sus, double pst, double psl, double step,
	double dens, int nd, int mania, int ti, int fl)
{
	out.strumTime.push_back(strum);
	out.sustainLength.push_back(sus);
	out.parentST.push_back(pst);
	out.parentSL.push_back(psl);
	out.stepCrochetAt.push_back(step);
	out.density.push_back(dens);
	out.noteData.push_back(nd);
	out.maniaAt.push_back(mania);
	out.typeIdx.push_back(ti);
	out.flags.push_back(fl);
}

static inline void track_row(RawFold &out, double strum)
{
	if (strum < out.lastStrumTime) out.rowsSorted = false;
	if (strum > out.lastStrumTime) out.lastStrumTime = strum;
}

static bool fold_chunk(const ParsedChunk &chunk, const FoldCfg &cfg, FoldState &st, RawFold &out)
{
	for (size_t bi = 0; bi < chunk.blocks.size(); bi++)
	{
		const BlockNotes &blk = chunk.blocks[bi];
		if (!blk.ok)
	{
		out.error = blk.error.empty() ? "sectionNotes parse failure" : blk.error;
		return false;
	}
		const size_t secCount = blk.secNoteCount.size();
		for (size_t si = 0; si < secCount; si++)
		{
			int gsec = blk.secBegin + (int)si;
			double step = cfg.stepAt[(size_t)gsec];
			double susBase = step / cfg.sustainSpeedDiv;
			int start = blk.secNoteStart[si];
			int count = blk.secNoteCount[si];
			for (int k = 0; k < count; k++)
			{
				int i = start + k;
				double strum = blk.strum[(size_t)i];
				double sus = blk.sustain[(size_t)i];
				int nd = blk.noteData[(size_t)i];
				int ti = blk.typeIdx[(size_t)i];
				int fl = blk.flags[(size_t)i];
				out.fedCount += 1.0;
				bool hold = sus > 0;
				if (!hold)
				{
					int lane = nd < 0 ? -nd : nd;
					if (lane >= cfg.laneCount) lane %= cfg.laneCount;
					int slot = (((fl & 1) != 0) ? cfg.laneCount : 0) + lane;
					bool mergeable = false;
					if (st.anchorRow[(size_t)slot] >= 0 && st.lastRate[(size_t)slot] == cfg.pxPerMs &&
						st.lastSlowRate[(size_t)slot] > 0)
					{
						double dt = strum - st.lastTime[(size_t)slot];
						if (dt >= 0)
						{
							if (dt <= cfg.rangeMs)
								mergeable = true;
							else if (cfg.minGapPx > 0 && dt * st.lastSlowRate[(size_t)slot] < cfg.minGapPx)
								mergeable = true;
						}
					}
					if (mergeable && st.lastDensity[(size_t)slot] > 0 && st.lastDensity[(size_t)slot] < MAX_REPRESENTED)
					{
						st.lastDensity[(size_t)slot] += 1.0;
						continue;
					}
					int prevRow = st.anchorRow[(size_t)slot];
					if (prevRow >= 0 && st.lastDensity[(size_t)slot] > 0)
						out.density[(size_t)prevRow] = st.lastDensity[(size_t)slot];
					if ((int)out.strumTime.size() >= MAX_EMITTED_ROWS) { out.error = "row cap reached"; return false; }
					int row = (int)out.strumTime.size();
					emit_row(out, strum, sus, 0.0, 0.0, step, 1.0, nd, cfg.mania, ti, fl);
					track_row(out, strum);
					st.anchorRow[(size_t)slot] = row;
					st.lastDensity[(size_t)slot] = 1.0;
					st.lastTime[(size_t)slot] = strum;
					st.lastRate[(size_t)slot] = cfg.pxPerMs;
					st.lastSlowRate[(size_t)slot] = cfg.pxPerMs;
				}
				else
				{
					if ((int)out.strumTime.size() >= MAX_EMITTED_ROWS) { out.error = "row cap reached"; return false; }
					emit_row(out, strum, sus, 0.0, 0.0, step, 1.0, nd, cfg.mania, ti, fl);
					track_row(out, strum);
				}
				if (sus >= 1.0)
				{
					double fd = floor(sus / step);
					if (fd >= 1.0)
					{
						if (fd > 10000000.0) { out.error = "sustain length past the fold limit"; return false; }
						int floorSus = (int)fd;
						int keepFl = fl & ~(2 | 4);
						for (int j = 0; j <= floorSus; j++)
						{
							double t = (strum + step * (double)j) + susBase;
							int fl2 = keepFl | 2 | ((j == floorSus) ? 4 : 0);
							if ((int)out.strumTime.size() >= MAX_EMITTED_ROWS) { out.error = "row cap reached"; return false; }
							emit_row(out, t, sus, strum, sus, step, 1.0, nd, cfg.mania, ti, fl2);
							track_row(out, t);
							out.fedCount += 1.0;
						}
					}
				}
			}
		}
	}
	return true;
}

// std::thread\'s destructor calls std::terminate() for a still-joinable thread. run_fold starts the
// next chunk\'s parsers before it folds the current one, so before this every early exit (fold limit,
// bad arguments, an exception) aborted the whole game instead of falling back to Haxe. Joining in the
// destructor makes the thread lifetime safe on every path, including stack unwinding.
static void join_slot_threads(std::vector<std::thread> &threads)
{
	for (size_t i = 0; i < threads.size(); i++)
	{
		std::thread &t = threads[i];
		if (!t.joinable()) continue;
		try { t.join(); }
		catch (...) { try { t.detach(); } catch (...) {} }
	}
	threads.clear();
}

struct ChunkSlot
{
	ParsedChunk pc;
	std::vector<std::thread> threads;

	~ChunkSlot() { join_slot_threads(threads); }
};

// Aggregates block-level failure state after the workers joined. Blocks are the only objects a worker
// writes, so the chunk itself needs no cross-thread writes.
static bool chunk_failed(ParsedChunk &pc)
{
	if (!pc.ok) return true;
	for (size_t b = 0; b < pc.blocks.size(); b++)
	{
		if (!pc.blocks[b].ok)
		{
			pc.ok = false;
			pc.error = pc.blocks[b].error.empty() ? std::string("sectionNotes parse failure") : pc.blocks[b].error;
			return true;
		}
	}
	return false;
}

static bool build_chunk(const FoldSource &src, int from, ParsedChunk &pc)
{
	pc.clear();
	if (from >= src.sectionCount) return false;
	pc.secBegin = from;
	int i = from;
	uint64_t bytes = 0;
	while (i < src.sectionCount)
	{
		int len = src.len[(size_t)i];
		if (len > 0) bytes += (uint64_t)len;
		i++;
		if (bytes >= FOLD_CHUNK_BYTES) break;
		if (i - from >= FOLD_CHUNK_MAX_SECTIONS) break;
	}
	pc.secEnd = i;
	return true;
}

static void start_chunk_parse(ChunkSlot &slot, const FoldSource &src, const FoldCfg &cfg, TypeInterner &interner)
{
	int nsec = slot.pc.secEnd - slot.pc.secBegin;
	if (nsec <= 0) return;
	join_slot_threads(slot.threads);
	int w = cfg.workers;
	if (w > nsec) w = nsec;
	if (w < 1) w = 1;
	slot.pc.blocks.resize((size_t)w);
	slot.threads.reserve((size_t)w);
	// Split by sectionNotes bytes, not by section count: on a real huge chart almost all bytes
	// sit in a few dense sections, so an equal section split would leave most workers idle.
	std::vector<int> bounds((size_t)w + 1);
	bounds[0] = slot.pc.secBegin;
	bounds[(size_t)w] = slot.pc.secEnd;
	{
		uint64_t total = 0;
		for (int s = slot.pc.secBegin; s < slot.pc.secEnd; s++) total += (uint64_t)src.len[(size_t)s];
		int cur = slot.pc.secBegin;
		uint64_t acc = 0;
		for (int b = 1; b < w; b++)
		{
			uint64_t target = total * (uint64_t)b / (uint64_t)w;
			while (cur < slot.pc.secEnd && acc < target)
			{
				acc += (uint64_t)src.len[(size_t)cur];
				cur++;
			}
			if (cur < bounds[(size_t)(b - 1)]) cur = bounds[(size_t)(b - 1)];
			bounds[(size_t)b] = cur;
		}
	}
	for (int b = 0; b < w; b++)
	{
		int b0 = bounds[(size_t)b];
		int b1 = bounds[(size_t)(b + 1)];
		slot.threads.emplace_back([&slot, &src, &cfg, &interner, b, b0, b1]() {
			try
			{
				parse_block(src, cfg, slot.pc, b, b0, b1, interner);
			}
			catch (const std::exception &e)
			{
				// A worker must never call std::terminate: record the failure and let the consumer
				// fall back to the Haxe path.
				BlockNotes &blk = slot.pc.blocks[(size_t)b];
				blk.ok = false;
				blk.error = std::string("worker exception: ") + e.what();
			}
			catch (...)
			{
				BlockNotes &blk = slot.pc.blocks[(size_t)b];
				blk.ok = false;
				blk.error = "worker exception";
			}
		});
	}
}

static int run_fold_impl(const ::Array< ::String > &paths, const ::Array<double> &startArr, const ::Array<int> &lenArr,
	const ::Array<int> &partArr, const ::Array<int> &secFlagsArr, const ::Array<double> &secBpmArr,
	int workers, int laneCount, int mania, bool isNewVersion, double songSpeed, double sustainSpeedDiv,
	bool playOpponent, bool rewrite, int rewriteAmmo, double stepCrochet, double rangeMs, double minGapPx,
	double maniaScale, const ::Array< ::String > &typeNamesArr)
{
	g_fold.ok = false;
	g_fold.error.clear();
	clear_fold_rows(); // swaps: a previous failed fold may have left hundreds of MB of capacity
	g_fold.fedCount = 0;
	g_fold.lastStrumTime = 0;
	g_fold.foldMs = 0;
	g_fold.sawNegativeNote = false;
	g_fold.rowsSorted = true;
	seinative_reset_debug_counters();

	int64_t t0 = now_ms();

	FoldCfg cfg;
	cfg.workers = workers;
	if (cfg.workers <= 0) cfg.workers = auto_workers();
	if (cfg.workers < 1) cfg.workers = 1;
	if (cfg.workers > MAX_WORKERS) cfg.workers = MAX_WORKERS;
	cfg.laneCount = laneCount;
	cfg.mania = mania;
	cfg.isNewVersion = isNewVersion;
	cfg.playOpponent = playOpponent;
	cfg.rewrite = rewrite;
	cfg.rewriteAmmo = rewriteAmmo;
	cfg.songSpeed = songSpeed;
	cfg.sustainSpeedDiv = sustainSpeedDiv;
	cfg.stepCrochet = stepCrochet;
	cfg.rangeMs = rangeMs;
	cfg.minGapPx = minGapPx;
	cfg.maniaScale = maniaScale;

	if (paths.mPtr == nullptr || paths->length < 1) { g_fold.error = "no part paths"; return 0; }
	if (cfg.laneCount <= 0 || cfg.laneCount > 32) { g_fold.error = "unsupported lane count"; return 0; }
	if (cfg.rewrite && cfg.rewriteAmmo <= 0) { g_fold.error = "rewrite note style without ammo"; return 0; }

	if (!is_finite(cfg.songSpeed) || cfg.songSpeed <= 0) cfg.songSpeed = 1.0;
	if (!is_finite(cfg.minGapPx) || cfg.minGapPx < 0) cfg.minGapPx = 0;
	if (!is_finite(cfg.rangeMs) || cfg.rangeMs < 0) cfg.rangeMs = 0;
	if (!is_finite(cfg.maniaScale) || cfg.maniaScale <= 0) cfg.maniaScale = 1.0;
	cfg.pxPerMs = 0.45 * cfg.songSpeed * cfg.maniaScale;
	if (!is_finite(cfg.sustainSpeedDiv) || cfg.sustainSpeedDiv <= 0) { g_fold.error = "invalid sustain speed divisor"; return 0; }
	if (!is_finite(cfg.stepCrochet) || cfg.stepCrochet <= 0) { g_fold.error = "invalid step crochet"; return 0; }

	const int nSec = startArr.mPtr ? startArr->length : 0;
	if (nSec <= 0 || nSec > MAX_SECTIONS) { g_fold.error = "invalid section count"; return 0; }
	if (lenArr.mPtr == nullptr || partArr.mPtr == nullptr || secFlagsArr.mPtr == nullptr || secBpmArr.mPtr == nullptr)
	{
		g_fold.error = "missing range arrays";
		return 0;
	}
	if (lenArr->length != nSec || partArr->length != nSec || secFlagsArr->length != nSec || secBpmArr->length != nSec)
	{
		g_fold.error = "range array length mismatch";
		return 0;
	}

	FoldSource src;
	const int nParts = paths->length;
	src.files.resize((size_t)nParts);
	for (int i = 0; i < nParts; i++) make_path(src.files[(size_t)i], paths->__get(i));
	src.start.resize((size_t)nSec);
	src.len.resize((size_t)nSec);
	src.part.resize((size_t)nSec);
	src.secFlags.resize((size_t)nSec);
	src.secBpm.resize((size_t)nSec);
	src.sectionCount = nSec;
	for (int i = 0; i < nSec; i++)
	{
		double st = startArr->__get(i);
		int ln = lenArr->__get(i);
		int pt = partArr->__get(i);
		int sf = secFlagsArr->__get(i);
		double bpm = secBpmArr->__get(i);
		if (!is_finite(st) || st < 0) { g_fold.error = "invalid section start"; return 0; }
		if (ln < 0 || (uint64_t)ln > MAX_RANGE_BYTES) { g_fold.error = "sectionNotes range past the size limit"; return 0; }
		if (pt < 0 || pt >= nParts) { g_fold.error = "bad part index"; return 0; }
		src.start[(size_t)i] = st;
		src.len[(size_t)i] = ln;
		src.part[(size_t)i] = pt;
		src.secFlags[(size_t)i] = sf;
		src.secBpm[(size_t)i] = bpm;
	}

	if (typeNamesArr.mPtr != nullptr)
	{
		cfg.typeNames.reserve((size_t)typeNamesArr->length);
		for (int i = 0; i < typeNamesArr->length; i++)
			cfg.typeNames.push_back(haxe_string_utf8(typeNamesArr->__get(i)));
	}

	cfg.stepAt.resize((size_t)nSec);
	double step = cfg.stepCrochet;
	for (int i = 0; i < nSec; i++)
	{
		int sf = src.secFlags[(size_t)i];
		double bpm = src.secBpm[(size_t)i];
		if ((sf & 4) != 0 && bpm > 0 && is_finite(bpm))
		{
			double crochet = (60.0 / bpm) * 1000.0;
			step = crochet / 4.0;
		}
		cfg.stepAt[(size_t)i] = step;
	}

	TypeInterner interner;
	FoldState st;
	st.init(cfg.laneCount);

	ChunkSlot slots[2];
	if (!build_chunk(src, 0, slots[0].pc)) { g_fold.error = "empty chart"; return 0; }
	start_chunk_parse(slots[0], src, cfg, interner);

	int chunkBegin = 0;
	int chunkIndex = 0;
	bool ok = true;
	int64_t parseWaitMs = 0;
	int64_t foldOnlyMs = 0;
	while (chunkBegin < nSec)
	{
		// Slot parity is the CHUNK index parity, not the first section index: chunk indices are
		// consecutive, so the next chunk always lands in the other slot.
		ChunkSlot &cur = slots[chunkIndex & 1];
		int64_t tw = now_ms();
		join_slot_threads(cur.threads);
		parseWaitMs += now_ms() - tw;
		int64_t tf = now_ms();
		if (chunk_failed(cur.pc))
		{
			ok = false;
			g_fold.error = cur.pc.error;
			break;
		}
		int nextBegin = cur.pc.secEnd;
		if (nextBegin < nSec)
		{
			ChunkSlot &nxt = slots[(chunkIndex + 1) & 1];
			if (!build_chunk(src, nextBegin, nxt.pc))
			{
				ok = false;
				g_fold.error = "empty chunk";
				break;
			}
			start_chunk_parse(nxt, src, cfg, interner);
		}
		if (!fold_chunk(cur.pc, cfg, st, g_fold))
		{
			ok = false;
			g_fold.error = g_fold.error.empty() ? "fold failure" : ("fold failure: " + g_fold.error);
			break;
		}
		foldOnlyMs += now_ms() - tf;
		cur.pc.clear();
		chunkBegin = nextBegin;
		chunkIndex++;
	}
	g_debug_parse_wait_ms = parseWaitMs;
	g_debug_fold_only_ms = foldOnlyMs;

	if (!ok)
	{
		g_fold.ok = false;
		clear_fold_rows();
		return 0;
	}

	for (size_t slot = 0; slot < st.anchorRow.size(); slot++)
	{
		int row = st.anchorRow[slot];
		if (row >= 0 && st.lastDensity[slot] > 0) g_fold.density[(size_t)row] = st.lastDensity[slot];
	}

	double mx = 0;
	bool any = !g_fold.strumTime.empty();
	if (any)
	{
		mx = g_fold.strumTime[0];
		for (size_t i = 1; i < g_fold.strumTime.size(); i++)
			if (g_fold.strumTime[i] > mx) mx = g_fold.strumTime[i];
	}
	g_fold.lastStrumTime = mx;

	g_fold.typeTable.clear();
	for (size_t i = 0; i < interner.names.size(); i++)
		g_fold.typeTable.push_back(::String::create(interner.names[i].c_str(), (int)interner.names[i].size()));
	bool anyEmpty = false;
	for (size_t i = 0; i < g_fold.typeIdx.size(); i++)
		if (g_fold.typeIdx[i] < 0)
		{
			anyEmpty = true;
			break;
		}
	if (anyEmpty) g_fold.typeTable.push_back(::String::create("", 0));

	g_fold.ok = true;
	g_fold.foldMs = (double)(now_ms() - t0);
	return 1;
}

// Failure is a return value, never a process abort. Anything thrown inside run_fold_impl (allocation
// failure, std::thread construction, ...) unwinds through the ChunkSlot destructors, which join the
// still-running parsers, and lands here; the Haxe caller then takes the old, correct path.
static int run_fold(const ::Array< ::String > &paths, const ::Array<double> &startArr, const ::Array<int> &lenArr,
	const ::Array<int> &partArr, const ::Array<int> &secFlagsArr, const ::Array<double> &secBpmArr,
	int workers, int laneCount, int mania, bool isNewVersion, double songSpeed, double sustainSpeedDiv,
	bool playOpponent, bool rewrite, int rewriteAmmo, double stepCrochet, double rangeMs, double minGapPx,
	double maniaScale, const ::Array< ::String > &typeNamesArr)
{
	try
	{
		return run_fold_impl(paths, startArr, lenArr, partArr, secFlagsArr, secBpmArr, workers, laneCount, mania,
			isNewVersion, songSpeed, sustainSpeedDiv, playOpponent, rewrite, rewriteAmmo, stepCrochet, rangeMs,
			minGapPx, maniaScale, typeNamesArr);
	}
	catch (const std::bad_alloc &)
	{
		g_fold.ok = false;
		g_fold.error = "out of memory";
		clear_fold_rows();
		return 0;
	}
	catch (const std::exception &e)
	{
		g_fold.ok = false;
		g_fold.error = std::string("exception: ") + e.what();
		clear_fold_rows();
		return 0;
	}
	catch (...)
	{
		g_fold.ok = false;
		g_fold.error = "unknown exception";
		clear_fold_rows();
		return 0;
	}
}

} // namespace seinative
// ============================================================================
// hxcpp-facing entry points (Haxe imports these through ChartNativeImpl).
// ============================================================================

static ::Array<double> to_haxe_doubles(const std::vector<double> &v)
{
	return ::Array_obj<double>::fromData(v.empty() ? nullptr : v.data(), (int)v.size());
}

static ::Array<int> to_haxe_ints(const std::vector<int> &v)
{
	return ::Array_obj<int>::fromData(v.empty() ? nullptr : v.data(), (int)v.size());
}

int seiun_chart_scan(::Array< ::String > paths, int workers)
{
	try
	{
		return seinative::run_scan(paths, workers);
	}
	catch (...)
	{
		seinative::clear_scan();
		return 0;
	}
}

::String seiun_chart_scan_skeleton()
{
	try
	{
		return ::String::create(seinative::g_scan.skeletonJson.c_str(), (int)seinative::g_scan.skeletonJson.size());
	}
	catch (...)
	{
		return ::String::create("", 0);
	}
}

::Array< ::String > seiun_chart_scan_events()
{
	return ::Array_obj< ::String >::fromData(seinative::g_scan.eventsJson.empty() ? nullptr : seinative::g_scan.eventsJson.data(),
		(int)seinative::g_scan.eventsJson.size());
}

double seiun_chart_scan_note_count() { return seinative::g_scan.noteCount; }
bool seiun_chart_scan_saw_negative() { return seinative::g_scan.sawNegativeNote; }
int seiun_chart_scan_section_count() { return seinative::g_scan.sectionCount; }
::Array<double> seiun_chart_scan_ranges_start() { return to_haxe_doubles(seinative::g_scan.rangesStart); }
::Array<int> seiun_chart_scan_ranges_len() { return to_haxe_ints(seinative::g_scan.rangesLen); }
::Array<int> seiun_chart_scan_ranges_part() { return to_haxe_ints(seinative::g_scan.rangesPart); }
::Array<int> seiun_chart_scan_sec_flags() { return to_haxe_ints(seinative::g_scan.secFlags); }
::Array<double> seiun_chart_scan_sec_bpm() { return to_haxe_doubles(seinative::g_scan.secBpm); }
double seiun_chart_scan_ms() { return seinative::g_scan.scanMs; }

void seiun_chart_scan_cleanup()
{
	std::string().swap(seinative::g_scan.skeletonJson);
	std::vector<::String>().swap(seinative::g_scan.eventsJson);
	std::vector<double>().swap(seinative::g_scan.rangesStart);
	std::vector<int>().swap(seinative::g_scan.rangesLen);
	std::vector<int>().swap(seinative::g_scan.rangesPart);
	std::vector<int>().swap(seinative::g_scan.secFlags);
	std::vector<double>().swap(seinative::g_scan.secBpm);
}

int seiun_chart_fold(::Array< ::String > paths, ::Array<double> start, ::Array<int> len, ::Array<int> part,
	::Array<int> secFlags, ::Array<double> secBpm, int workers, int laneCount, int mania, bool isNewVersion,
	double songSpeed, double sustainSpeedDiv, bool playOpponent, bool rewrite, int rewriteAmmo, double stepCrochet,
	double rangeMs, double minGapPx, double maniaScale, ::Array< ::String > typeNames)
{
	try
	{
		return seinative::run_fold(paths, start, len, part, secFlags, secBpm, workers, laneCount, mania,
			isNewVersion, songSpeed, sustainSpeedDiv, playOpponent, rewrite, rewriteAmmo, stepCrochet, rangeMs,
			minGapPx, maniaScale, typeNames);
	}
	catch (...)
	{
		seinative::g_fold.ok = false;
		seinative::g_fold.error = "native exception";
		seinative::clear_fold_rows();
		return 0;
	}
}

::Array<double> seiun_chart_fold_strum() { return to_haxe_doubles(seinative::g_fold.strumTime); }
::Array<double> seiun_chart_fold_sustain() { return to_haxe_doubles(seinative::g_fold.sustainLength); }
::Array<double> seiun_chart_fold_parent_st() { return to_haxe_doubles(seinative::g_fold.parentST); }
::Array<double> seiun_chart_fold_parent_sl() { return to_haxe_doubles(seinative::g_fold.parentSL); }
::Array<double> seiun_chart_fold_step() { return to_haxe_doubles(seinative::g_fold.stepCrochetAt); }
::Array<double> seiun_chart_fold_density() { return to_haxe_doubles(seinative::g_fold.density); }
::Array<int> seiun_chart_fold_note_data() { return to_haxe_ints(seinative::g_fold.noteData); }
::Array<int> seiun_chart_fold_mania() { return to_haxe_ints(seinative::g_fold.maniaAt); }
::Array<int> seiun_chart_fold_type_idx() { return to_haxe_ints(seinative::g_fold.typeIdx); }
::Array<int> seiun_chart_fold_flags() { return to_haxe_ints(seinative::g_fold.flags); }
::Array< ::String > seiun_chart_fold_types()
{
	return ::Array_obj< ::String >::fromData(seinative::g_fold.typeTable.empty() ? nullptr : seinative::g_fold.typeTable.data(),
		(int)seinative::g_fold.typeTable.size());
}
double seiun_chart_fold_fed() { return seinative::g_fold.fedCount; }
double seiun_chart_fold_last_strum() { return seinative::g_fold.lastStrumTime; }
bool seiun_chart_fold_saw_negative() { return seinative::g_fold.sawNegativeNote; }
bool seiun_chart_fold_rows_sorted() { return seinative::g_fold.rowsSorted; }
double seiun_chart_fold_ms() { return seinative::g_fold.foldMs; }
::String seiun_chart_fold_error() { return ::String::create(seinative::g_fold.error.c_str(), (int)seinative::g_fold.error.size()); }

void seiun_chart_fold_cleanup() { seinative::clear_fold_rows(); }
double seiun_chart_debug_read_ms() { return (double)seinative::g_dbg_read_ms.load(); }
double seiun_chart_debug_decode_ms() { return (double)seinative::g_dbg_decode_ms.load(); }
double seiun_chart_debug_blocks() { return (double)seinative::g_dbg_blocks.load(); }
double seiun_chart_debug_parse_wait_ms() { return (double)seinative::g_debug_parse_wait_ms; }
double seiun_chart_debug_fold_only_ms() { return (double)seinative::g_debug_fold_only_ms; }')
class ChartNative
{
	/** Whether the native module was compiled in and initialised. */
	public static function available():Bool
	{
		#if cpp
		return true;
		#else
		return false;
		#end
	}

	/** Phase 1: skeleton + per-section sectionNotes byte ranges + note-entry count. Null = use Haxe. */
	public static function scanParts(paths:Array<String>, workers:Int):NativeScanResult
	{
		#if cpp
		if (paths == null || paths.length == 0) return null;
		var ok:Int = ChartNativeImpl.scan(paths, workers);
		if (ok <= 0) return null;
		var result:NativeScanResult = {
			skeletonJson: ChartNativeImpl.scanSkeleton(),
			eventsJson: ChartNativeImpl.scanEvents(),
			noteCount: ChartNativeImpl.scanNoteCount(),
			sawNegativeNote: ChartNativeImpl.scanSawNegative(),
			sectionCount: ChartNativeImpl.scanSectionCount(),
			rangesStart: ChartNativeImpl.scanRangesStart(),
			rangesLen: ChartNativeImpl.scanRangesLen(),
			rangesPart: ChartNativeImpl.scanRangesPart(),
			secFlags: ChartNativeImpl.scanSecFlags(),
			secBpm: ChartNativeImpl.scanSecBpm(),
			scanMs: ChartNativeImpl.scanMs()
		};
		ChartNativeImpl.scanCleanup();
		return result;
		#else
		return null;
		#end
	}

	/** Phase 2: parse+fold the recorded ranges. Null = use Haxe. */
	public static function foldParts(paths:Array<String>, start:Array<Float>, len:Array<Int>, part:Array<Int>,
		secFlags:Array<Int>, secBpm:Array<Float>, opts:NativeFoldOptions):NativeFoldResult
	{
		#if cpp
		if (paths == null || paths.length == 0 || start == null || len == null || part == null ||
			secFlags == null || secBpm == null || opts == null) return null;
		var ok:Int = ChartNativeImpl.fold(paths, start, len, part, secFlags, secBpm, opts.workers,
			opts.laneCount, opts.mania, opts.isNewVersion, opts.songSpeed, opts.sustainSpeedDiv,
			opts.playOpponent, opts.rewrite, opts.rewriteAmmo, opts.stepCrochet, opts.rangeMs,
			opts.minGapPx, opts.maniaScale, opts.typeNames);
		if (ok <= 0) return null;
		var result:NativeFoldResult = {
			strumTime: ChartNativeImpl.foldStrum(),
			sustainLength: ChartNativeImpl.foldSustain(),
			parentST: ChartNativeImpl.foldParentST(),
			parentSL: ChartNativeImpl.foldParentSL(),
			stepCrochetAt: ChartNativeImpl.foldStep(),
			density: ChartNativeImpl.foldDensity(),
			noteData: ChartNativeImpl.foldNoteData(),
			maniaAt: ChartNativeImpl.foldMania(),
			typeIdx: ChartNativeImpl.foldTypeIdx(),
			flags: ChartNativeImpl.foldFlags(),
			typeTable: ChartNativeImpl.foldTypes(),
			fedCount: ChartNativeImpl.foldFed(),
			lastStrumTime: ChartNativeImpl.foldLastStrum(),
			sawNegativeNote: ChartNativeImpl.foldSawNegative(),
			rowsSorted: ChartNativeImpl.foldRowsSorted(),
			foldMs: ChartNativeImpl.foldMs()
		};
		ChartNativeImpl.foldCleanup();
		return result;
		#else
		return null;
		#end
	}

	/** Why the last foldParts() call returned null ('' when nothing was recorded). */
	public static function lastFoldError():String
	{
		#if cpp
		return ChartNativeImpl.foldError();
		#else
		return '';
		#end
	}
}
