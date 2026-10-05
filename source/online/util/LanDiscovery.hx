package online.util;

import haxe.Json;
import haxe.io.Bytes;
import sys.net.Address;
import sys.net.Host;
import sys.net.Socket;
import sys.net.UdpSocket;
import sys.thread.Thread;

/** One server heard on the local network. */
typedef LanServer = {
	/** Ready-to-use address, derived from the datagram's source IP and the announced port. */
	var address:String;
	/** Host-chosen label, or an empty string. */
	var name:String;
}

/**
 * "Find servers on this network": a host shouts a small datagram at the broadcast address every
 * couple of seconds and a client that is looking listens on the same UDP port for a few seconds.
 * Nothing is saved on the listening side -- the results are only reported, and the player decides
 * which of them to keep.
 *
 * A subnet sweep is deliberately NOT used: measured on a real LAN, connecting to an address with
 * nobody behind it takes the full 21 s Windows SYN budget and then still reports success, so a
 * 254-host probe is both far too slow and wrong.
 *
 * The file is self-contained (sys / haxe only): the same source is compiled into the game client
 * and into the standalone server, and every failure degrades to "nothing found" instead of
 * throwing into a caller's update loop.
 */
class LanDiscovery
{
	/** UDP port for the announcements. Next to the game's 2567 / 2568 so it is easy to remember. */
	public static inline var PORT:Int = 2569;

	/** Marks our own datagrams, so a stray packet on the port cannot invent an entry. */
	static inline var MAGIC:String = 'seiunengine-lan';

	/** How long a scan listens, and how often a host re-announces itself. */
	public static inline var SCAN_SECONDS:Float = 4.0;
	static inline var ANNOUNCE_EVERY:Float = 1.5;

	/** What the most recent scan heard. Swapped in once, when the scan ends. */
	public static var found(default, null):Array<LanServer> = [];

	/** True from the moment a scan starts until its results are published. */
	public static var scanning(default, null):Bool = false;

	static var announcing:Bool = false;
	static var announcePort:Int = 0;
	static var announceName:String = '';
	static var announceTargets:Array<String> = [];

	/**
	 * Sends one "a server is here" datagram to every broadcast address of this machine.
	 *
	 * 255.255.255.255 alone is not enough: it leaves through the interface with the best route,
	 * which on a machine with a VPN or a WSL / Hyper-V adapter is often not the LAN at all. Each
	 * private IPv4 therefore also gets its own x.y.z.255.
	 *
	 * Best-effort: an unsupported platform, a missing broadcast permission or a network hiccup are
	 * all normal and simply leave discovery empty.
	 */
	public static function announceOnce(httpPort:Int, ?name:String):Void
	{
		if (httpPort <= 0)
			return;

		var targets:Array<String> = announceTargets.length > 0 ? announceTargets : broadcastTargets();
		if (targets.length == 0)
			targets = ['255.255.255.255'];

		var payload = Json.stringify({
			magic: MAGIC,
			port: httpPort,
			name: name == null ? '' : name
		});

		for (target in targets)
		{
			try
			{
				var socket = new UdpSocket();
				socket.setBroadcast(true);
				socket.bind(new Host('0.0.0.0'), 0);
				var bytes = Bytes.ofString(payload);
				socket.sendTo(bytes, 0, bytes.length, addressFor(target));
				socket.close();
			}
			catch (e:Dynamic)
			{
				// No broadcast on this network, no permission, no socket for that interface.
			}
		}
	}

	static function addressFor(ip:String):Address
	{
		var address = new Address();
		address.host = new Host(ip).ip;
		address.port = PORT;
		return address;
	}

	/** Limited broadcast plus the /24 broadcast of every private IPv4 this machine has. */
	static function broadcastTargets():Array<String>
	{
		var targets:Array<String> = ['255.255.255.255'];
		for (ip in localAddresses())
		{
			var lastDot = ip.lastIndexOf('.');

			if (lastDot <= 0)
				continue;

			var subnet = ip.substr(0, lastDot) + '.255';
			if (targets.indexOf(subnet) < 0)
				targets.push(subnet);
		}
		return targets;
	}

	/** Starts (or re-points) the background announcer. Idempotent. */
	public static function startAnnouncing(httpPort:Int, ?name:String):Void
	{
		if (httpPort <= 0)
			return;

		announcePort = httpPort;
		announceName = name == null ? '' : name;
		if (announcing)
			return;

		// Enumerated once, not per datagram: it spawns ipconfig.
		announceTargets = broadcastTargets();

		#if target.threaded
		announcing = true;
		Thread.create(() -> {
			while (announcing)
			{
				announceOnce(announcePort, announceName);
				Sys.sleep(ANNOUNCE_EVERY);
			}
		});
		#else
		announceOnce(announcePort, announceName);
		#end
	}

	/** Stops the announcer: a server that went down must stop claiming to be up. */
	public static function stopAnnouncing():Void
	{
		announcing = false;
		announcePort = 0;
	}

	/**
	 * Listens for announcements for `seconds` on a worker thread.
	 *
	 * The caller polls the scanning flag and then reads the results: the worker builds its own
	 * array and publishes it with a single assignment, so no collection is shared between threads.
	 */
	public static function startScan(?seconds:Float = SCAN_SECONDS):Void
	{
		if (scanning)
			return;

		#if target.threaded
		scanning = true;
		found = [];
		Thread.create(() -> {
			var results:Array<LanServer> = [];
			var socket:UdpSocket = null;
			try
			{
				socket = new UdpSocket();
				socket.bind(new Host('0.0.0.0'), PORT);
				socket.setBlocking(false);

				var buffer = Bytes.alloc(1024);
				var from = new Address();
				var deadline:Float = Sys.time() + seconds;
				while (Sys.time() < deadline)
				{
					var ready = Socket.select([socket], null, null, 0.2);
					if (ready == null || ready.read.length == 0)
						continue;

					var length:Int = socket.readFrom(buffer, 0, buffer.length, from);
					if (length <= 0)
						continue;

					var entry = parse(buffer.getString(0, length), from.getHost().toString());
					if (entry != null && !contains(results, entry.address))
						results.push(entry);
				}
			}
			catch (e:Dynamic)
			{
				trace('[lan] scan failed: ' + Std.string(e));
			}

			if (socket != null)
			{
				try socket.close() catch (e:Dynamic) {}
			}

			found = results;
			scanning = false;
		});
		#else
		found = [];
		#end
	}

	static function parse(text:String, senderIp:String):Null<LanServer>
	{
		try
		{
			var data:Dynamic = Json.parse(text);
			if (data == null || !Reflect.hasField(data, 'magic') || Std.string(Reflect.field(data, 'magic')) != MAGIC)
				return null;

			var portValue:Null<Int> = Reflect.hasField(data, 'port') ? Std.parseInt(Std.string(Reflect.field(data, 'port'))) : null;
			if (portValue == null || portValue <= 0)
				return null;

			// The address is built from the datagram itself. The sender has no idea which of its
			// interfaces a packet left from (and may have several), but the source IP is right
			// there in the received address.
			var name:String = Reflect.hasField(data, 'name') ? Std.string(Reflect.field(data, 'name')) : '';
			return { address: 'ws://' + senderIp + ':' + portValue, name: name };
		}
		catch (e:Dynamic)
		{
			return null;
		}
	}

	static function contains(list:Array<LanServer>, address:String):Bool
	{
		for (item in list)
			if (item.address == address)
				return true;
		return false;
	}

	// ------------------------------------------------------------------
	// Local interfaces (moved here from ServerList so the standalone server can use it too)
	// ------------------------------------------------------------------

	/**
	 * Best-effort list of this machine's private (RFC 1918) IPv4 addresses, in the order the
	 * platform's interface lister prints them and without duplicates. Nothing is guaranteed: a
	 * missing tool, an unusual locale or a virtual-only adapter all end in an empty result, which
	 * is a normal outcome rather than an error.
	 */
	public static function localAddresses():Array<String>
	{
		#if (desktop || neko || (cpp && server_build))
		var system:Null<String> = Sys.systemName();
		for (command in interfaceCommands(system))
		{
			var output = runInterfaceCommand(command);
			if (output == null)
				continue;

			var addresses = parsePrivateIPv4s(system, output);
			if (addresses.length > 0)
				return addresses;
		}
		return [];
		#else
		return [];
		#end
	}

	#if (desktop || neko || (cpp && server_build))
	/** argv of the platform commands that list interfaces; the first one is preferred. */
	static function interfaceCommands(system:Null<String>):Array<Array<String>>
	{
		return switch (system)
		{
			case 'Windows': [['ipconfig']];
			// The ip tool is the modern Linux lister; ifconfig is the fallback on older installs.
			case 'Linux': [['ip', '-4', 'addr', 'show'], ['ifconfig']];
			case 'Mac': [['ifconfig']];
			default: [];
		};
	}

	/** Runs one lister and returns its stdout, or null when the command is missing / cannot run. */
	static function runInterfaceCommand(command:Array<String>):Null<String>
	{
		if (command == null || command.length == 0)
			return null;

		try
		{
			var process = new sys.io.Process(command[0], command.slice(1));
			var output = process.stdout.readAll().toString();
			process.exitCode();
			process.close();
			return output;
		}
		catch (e:Dynamic)
		{
			// A missing lister throws here; the caller just tries the next command.
			return null;
		}
	}
	#end

	/**
	 * Pull the private IPv4 addresses out of one interface listing. Pure (no process, no state).
	 *
	 * Windows ipconfig marks its lines with the literal token "IPv4" (localised builds keep it)
	 * and puts the address after the last ':'; the ip and ifconfig tools write "inet <addr>[/prefix]".
	 */
	public static function parsePrivateIPv4s(systemName:Null<String>, output:String):Array<String>
	{
		var found:Array<String> = [];
		if (output == null)
			return found;

		for (line in output.split('\n'))
		{
			var candidate:String = null;
			if (systemName == 'Windows')
			{
				if (line.indexOf('IPv4') < 0)
					continue;

				var colon = line.lastIndexOf(':');
				if (colon < 0)
					continue;

				candidate = line.substr(colon + 1);
			}
			else
			{
				// "inet 192.168.1.5/24 ..." and "inet 192.168.1.5 netmask ..."; "inet6" has no
				// space after "inet" and is skipped by the search below.
				var marker = line.indexOf('inet ');
				if (marker < 0)
					continue;

				candidate = line.substr(marker + 'inet '.length);
			}

			var token = StringTools.trim(candidate);
			var space = token.indexOf(' ');
			if (space >= 0)
				token = token.substr(0, space);

			var slash = token.indexOf('/');
			if (slash >= 0)
				token = token.substr(0, slash);

			if (isPrivateIPv4(token) && found.indexOf(token) < 0)
				found.push(token);
		}

		return found;
	}

	/** True for a plain RFC 1918 IPv4 literal: 10/8, 172.16/12 and 192.168/16. */
	static function isPrivateIPv4(token:String):Bool
	{
		if (token == null || token == '')
			return false;

		var parts = token.split('.');
		if (parts.length != 4)
			return false;

		for (part in parts)
		{
			var value = Std.parseInt(part);
			// Reject "", "+1", "01" and anything outside a byte, so only dotted decimals pass.
			if (value == null || value < 0 || value > 255 || Std.string(value) != part)
				return false;
		}

		var first = Std.parseInt(parts[0]);
		var second = Std.parseInt(parts[1]);
		return first == 10
			|| (first == 192 && second == 168)
			|| (first == 172 && second >= 16 && second <= 31);
	}
}