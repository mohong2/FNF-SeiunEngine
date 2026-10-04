package online_server;

import haxe.crypto.Hmac;
import haxe.crypto.Sha256;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import sys.io.File;
import sys.thread.Thread;

/**
 * Credential primitives: token/code hashing, constant-time comparison and the CSPRNG that
 * feeds every random identifier this server issues.
 *
 * Threat model (honest boundary, also stated in server/README.md):
 *  - Tokens and verification codes are never stored or logged in plaintext. Only
 *    HMAC-SHA256(secret, value) plus a short, non-secret lookup prefix is persisted, so a
 *    database snapshot does not yield usable bearer credentials.
 *  - The HMAC key lives in the same database (meta table, key "auth.secret"). This protects
 *    against a leaked *row* (a backup of one table, a log dump, an accidental SELECT result),
 *    not against an attacker who already owns the whole file. That is the usual trade-off for
 *    a self-hosted, single-process LAN server and it is documented rather than implied.
 *  - The CSPRNG prefers the OS entropy device. On Windows there is no /dev/urandom and Haxe
 *    offers no OS CSPRNG binding for neko/cpp, so it falls back to an HMAC-SHA256 DRBG seeded
 *    from a mixed entropy pool (high-resolution clock, process/thread data, object identity,
 *    a monotonically increasing counter and earlier output). That fallback is *not* a hardware
 *    CSPRNG: it is unpredictable to an external observer but its seed space is much smaller
 *    than 256 bits. The boundary is reported in the README and in the startup log line.
 */
class Crypto {
	/** Rows written with this prefix are not secret; they let a lookup avoid a full scan. */
	public static inline var TOKEN_PREFIX_CHARS:Int = 8;

	/** Per-installation HMAC key (hex). Set once by Db.open() before any credential is hashed. */
	static var secretHex:String = null;
	static var secret:Bytes = null;

	/** True when the OS entropy device answered; reported by /api/health and the README. */
	public static var osEntropyAvailable:Bool = false;
	static var osEntropyProbed:Bool = false;

	/** DRBG state (32 bytes) and a monotonic counter mixed into every draw. */
	static var drbgState:Bytes = null;
	static var drbgCounter:Float = 0;
	static var entropyPool:Bytes = null;

	// ------------------------------------------------------------------
	// Secret / CSPRNG
	// ------------------------------------------------------------------

	/**
	 * Installs the installation key that hashes credentials. Called by Db.open() with the value
	 * read from (or freshly written to) the meta table.
	 */
	public static function initSecret(hex:String):Void {
		if (hex == null || hex == "") return;
		secretHex = hex;
		try secret = Bytes.ofHex(hex) catch (e:Dynamic) secret = Sha256.make(Bytes.ofString(hex));
		if (secret == null || secret.length == 0) secret = Sha256.make(Bytes.ofString(hex));
	}

	public static function hasSecret():Bool return secret != null;

	/** Generates a fresh installation key (hex). Only used when meta has none yet. */
	public static function newSecretHex():String {
		var b = randomBytes(32);
		return b.toHex();
	}

	/**
	 * Draws n cryptographically unpredictable bytes. Order: /dev/urandom, then the HMAC-SHA256
	 * DRBG. Never throws for n <= 0 and never returns a constant.
	 */
	public static function randomBytes(n:Int):Bytes {
		if (n <= 0) return Bytes.alloc(0);
		var out = tryOsEntropy(n);
		if (out != null) return out;
		return drbgBytes(n);
	}

	/** Forces the one-time /dev/urandom probe so /api/health can report the entropy source. */
	public static function probeEntropy():Bool {
		if (!osEntropyProbed) tryOsEntropy(1);
		return osEntropyAvailable;
	}

	/** Hex string of n random bytes (2n characters). */
	public static function randomHex(bytes:Int):String {
		return randomBytes(bytes).toHex();
	}

	/**
	 * Reads the OS entropy device. sys.io.File.getBytes() reads to EOF, which never terminates
	 * on /dev/urandom, so a bounded read is used instead. Absence of the device (Windows) is a
	 * normal, recorded condition, not an error.
	 */
	static function tryOsEntropy(n:Int):Bytes {
		if (osEntropyProbed && !osEntropyAvailable) return null;
		osEntropyProbed = true;
		try {
			var input = File.read("/dev/urandom", true);
			var out = Bytes.alloc(n);
			input.readBytes(out, 0, n);
			input.close();
			osEntropyAvailable = true;
			return out;
		} catch (e:Dynamic) {
			osEntropyAvailable = false;
			return null;
		}
	}

	/** HMAC-SHA256(secret-or-pool, msg). */
	public static function hmac(key:Bytes, msg:Bytes):Bytes {
		return new Hmac(HashMethod.SHA256).make(key, msg);
	}

	public static function hmacHex(key:Bytes, msg:Bytes):String {
		return hmac(key, msg).toHex();
	}

	/**
	 * HMAC-SHA256 DRBG (NIST SP 800-90A style update, not a certified implementation):
	 *   state' = HMAC(K, state || counter || entropy)
	 *   output = HMAC(state', counter || entropy)
	 * Counter and entropy are mixed into every draw so two draws in the same millisecond differ.
	 */
	static function drbgBytes(n:Int):Bytes {
		var key = (secret != null) ? secret : poolKey();
		if (drbgState == null) drbgState = Sha256.make(entropySeed());
		var out = new BytesBuffer();
		while (out.length < n) {
			drbgCounter += 1;
			var noise = entropySeed();
			var msg = new BytesBuffer();
			msg.add(drbgState);
			msg.add(noise);
			msg.add(le64(drbgCounter));
			drbgState = hmac(key, msg.getBytes());
			var msg2 = new BytesBuffer();
			msg2.add(le64(drbgCounter));
			msg2.add(noise);
			out.add(hmac(drbgState, msg2.getBytes()));
		}
		return out.getBytes().sub(0, n);
	}

	/** Slowly-mixed entropy pool; every random draw advances it. */
	static function poolKey():Bytes {
		if (entropyPool == null) entropyPool = entropySeed();
		return entropyPool;
	}

	/** 32 bytes of mixed, non-secret-predictable process entropy. */
	static function entropySeed():Bytes {
		var buf = new BytesBuffer();
		var stamp = haxe.Timer.stamp();
		buf.add(Bytes.ofString(Std.string(stamp)));
		buf.add(le64(stamp * 1000000.0));
		buf.add(le64(Sys.time() * 1000.0));
		buf.add(Bytes.ofString(Std.string(Date.now().getTime())));
		buf.add(Bytes.ofString(Std.string(Math.random())));
		try buf.add(Bytes.ofString(Std.string(Sys.getCwd()))) catch (e:Dynamic) {}
		try buf.add(Bytes.ofString(Std.string(Sys.environment()))) catch (e:Dynamic) {}
		try buf.add(Bytes.ofString(Sys.systemName())) catch (e:Dynamic) {}
		try buf.add(Bytes.ofString(Std.string(Thread.current()))) catch (e:Dynamic) {}
		buf.add(Bytes.ofString(Std.string(drbgCounter)));
		// Type.getClassName returns null for anonymous classes on neko/cpp; Bytes.ofString(null)
		// throws, so the value is guarded instead of assumed to be a String.
		try {
			var className = Type.getClassName(Type.getClass(entropyPulse()));
			if (className != null) buf.add(Bytes.ofString(className));
		} catch (e:Dynamic) {}
		if (drbgState != null) buf.add(drbgState);
		var mixed = Sha256.make(buf.getBytes());
		if (entropyPool != null) mixed = hmac(entropyPool, mixed);
		entropyPool = mixed;
		return mixed;
	}

	/** Fresh object per seed call: its identity/hash differs every time on all targets. */
	static function entropyPulse():Dynamic return { t: haxe.Timer.stamp(), i: drbgCounter };

	static function le64(v:Float):Bytes {
		var b = Bytes.alloc(8);
		var x:Float = v;
		var i = 0;
		while (i < 8) {
			var lo:Int = Std.int(x % 256);
			if (lo < 0) lo += 256;
			b.set(i, lo);
			x = Math.ffloor(x / 256);
			i++;
		}
		return b;
	}

	// ------------------------------------------------------------------
	// Credential hashing
	// ------------------------------------------------------------------

	/** HMAC-SHA256(installation key, token) as lowercase hex. This is what the DB stores. */
	public static function hashToken(value:String):String {
		if (value == null) return null;
		var key = (secret != null) ? secret : poolKey();
		return hmacHex(key, Bytes.ofString(value));
	}

	/** Non-secret lookup prefix stored next to the hash. */
	public static function tokenPrefix(value:String):String {
		if (value == null) return null;
		return value.length <= TOKEN_PREFIX_CHARS ? value : value.substr(0, TOKEN_PREFIX_CHARS);
	}

	/** Verification codes use the same keyed hash as tokens. */
	public static function hashCode(code:String):String return hashToken(code);

	/**
	 * Length-independent, constant-time string comparison over UTF-8 bytes. The length is
	 * compared first, so only the length (not the content) is timing-visible.
	 */
	public static function equals(a:String, b:String):Bool {
		if (a == null || b == null) return false;
		var ab = Bytes.ofString(a);
		var bb = Bytes.ofString(b);
		if (ab.length != bb.length) return false;
		var diff = 0;
		for (i in 0...ab.length) diff |= ab.get(i) ^ bb.get(i);
		return diff == 0;
	}

	/**
	 * PBKDF2-HMAC-SHA256 (RFC 2898). Available for a future password endpoint; the current
	 * flow is email code + token, so nothing calls it yet.
	 */
	public static function pbkdf2(password:String, salt:String, iterations:Int, dkLen:Int):String {
		if (iterations < 1) iterations = 1;
		if (dkLen < 1) dkLen = 1;
		var pw = Bytes.ofString(password == null ? "" : password);
		var saltB = Bytes.ofString(salt == null ? "" : salt);
		var out = new BytesBuffer();
		var block = 1;
		while (out.length < dkLen) {
			var msg = new BytesBuffer();
			msg.add(saltB);
			msg.add(be32(block));
			var u = hmac(pw, msg.getBytes());
			var t = u;
			for (i in 1...iterations) {
				u = hmac(pw, u);
				for (j in 0...t.length) t.set(j, t.get(j) ^ u.get(j));
			}
			out.add(t);
			block++;
		}
		return out.getBytes().sub(0, dkLen).toHex();
	}

	static function be32(v:Int):Bytes {
		var b = Bytes.alloc(4);
		b.set(0, (v >>> 24) & 0xFF);
		b.set(1, (v >>> 16) & 0xFF);
		b.set(2, (v >>> 8) & 0xFF);
		b.set(3, v & 0xFF);
		return b;
	}

	/** Random hex string of the requested *character* count (legacy JsonStore.randomHex shape). */
	public static function randomHexChars(chars:Int):String {
		if (chars <= 0) return "";
		var bytes = Math.ceil(chars / 2);
		var hex = randomHex(Std.int(bytes));
		return hex.length <= chars ? hex : hex.substr(0, chars);
	}
}
