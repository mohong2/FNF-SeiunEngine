package haxe.net;
import haxe.io.Error;
import haxe.net.impl.SocketSys;
import haxe.net.impl.WebSocketGeneric;
import sys.net.Host;
import sys.ssl.Socket;
import sys.ssl.Certificate;
import sys.ssl.Key;

class WebSocketServer { 

	var _isDebug:Bool;
	var _isSecure:Bool;
	var _listenSocket:sys.net.Socket;
	#if neko
	var keepalive:Dynamic;
	#end
	function new(host:String, port:Int, maxConnections:Int, isSecure:Dynamic = null, isDebug:Bool = false) {
		_isDebug = isDebug;
		_isSecure = isSecure != null;
		_listenSocket = _isSecure ? new sys.ssl.Socket() : new sys.net.Socket() ;
		
		if(_isSecure){
			cast(_listenSocket, sys.ssl.Socket).setCA( Certificate.loadFile(Reflect.field(isSecure, "CA")) );
        	cast(_listenSocket, sys.ssl.Socket).setCertificate( Certificate.loadFile(Reflect.field(isSecure, "Certificate")), Key.readPEM(sys.io.File.getContent(Reflect.field(isSecure, "Key")), false) );
			cast(_listenSocket, sys.ssl.Socket).verifyCert = false;
		}
		_listenSocket.bind(new Host(host), port);
		_listenSocket.setBlocking(false);
		_listenSocket.listen(maxConnections);
		
		#if neko
		keepalive = neko.Lib.load("std", "socket_set_keepalive",4);
		//disable keepalive:
		keepalive( @:privateAccess _listenSocket.__s, false, null, null );
		#end
	}
	
	public static function create(host:String, port:Int, maxConnections:Int, isSecure:Bool, isDebug:Bool) {
		return new WebSocketServer(host, port, maxConnections, isSecure ? true : null, isDebug);
	}
	
	public function accept():WebSocket {
		// Additive SeiunEngine guard: after closeListen() the field is null, and a null receiver is a
		// hard crash on hxcpp rather than a catchable exception.
		var listen = _listenSocket;
		if (listen == null) {
			return null;
		}
		try {
			var socket:Dynamic = null;
			 if(_isSecure){
				socket = cast(listen, sys.ssl.Socket).accept();
			}else{
				socket = listen.accept();
			}
			return WebSocket.createFromAcceptedSocket(Socket2.createFromExistingSocket(socket, _isDebug), '', _isDebug);
		}
		catch (e:Dynamic) {
			
			return null;
		}
	}
	
	/** Additive SeiunEngine: true while the listen socket is bound (false after closeListen). */
	public function isListening():Bool {
		return _listenSocket != null;
	}
	
	/**
	 * Additive SeiunEngine: releases the listen port so an embedded host can stop accepting
	 * connections and free the port for another server instance. Idempotent and safe to call from
	 * another thread; accept() returns null afterwards. Existing callers never call this, so the
	 * dedicated server's behaviour is unchanged.
	 */
	public function closeListen():Void {
		var socket = _listenSocket;
		_listenSocket = null;
		if (socket != null) {
			try socket.close() catch (e:Dynamic) {}
		}
	}
	
}
