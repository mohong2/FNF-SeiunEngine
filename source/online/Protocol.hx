package online;

/**
 * The engine's own application-layer handshake identity.
 *
 * It lives here instead of in `source/Main.hx` because Main.hx is a host file that both macro modes
 * compile: keeping that file's line count untouched (only the two protocol *values* changed, on their
 * original lines) keeps contract (a) a plain byte comparison for the macro-off build.
 *
 * The transport under this handshake is still the vendored colyseus library (matchmaking paths, WS
 * frame codes, msgpack + schema) -- that library is not ours to change. What *is* ours is who may
 * talk to whom: both ends have to present the same magic + version, and a server that does not is
 * refused with a message instead of being joined.
 */
class Protocol {
	/** Game-room handshake (join options `engine` + `protocol`). */
	public static inline var MAGIC:String = "seiunengine-online";
	/** Social / network-room handshake. */
	public static inline var NETWORK_MAGIC:String = "seiunengine-network";
	/** Protocol version counters. */
	public static inline var VERSION:Int = 1;
	public static inline var NETWORK_VERSION:Int = 1;
}
