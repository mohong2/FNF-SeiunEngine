package tink.chunk;

import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.FPHelper;
import tink.Chunk;

// TODO: integrate into Chunk ultimately
// Source: https://github.com/nodejs/node/blob/44161274821a2e81e7a5706c06cf8aa8bd2aa972/lib/internal/buffer.js
class ChunkTools {
	public static function readUInt8(chunk:Chunk, offset:Int):Int {
		check(chunk, offset, 1);
		var val = chunk[offset];
		return val;
	}
	
	public static function readInt8(chunk:Chunk, offset:Int):Int {
		var val = readUInt8(chunk, offset);
		return val > 0x7f ? val - 0x100 : val;
	}
	
	public static function readUInt16LE(chunk:Chunk, offset:Int):Int {
		check(chunk, offset, 2);
		var first = chunk[offset];
		var last = chunk[offset + 1];
		return first + (last << 8);
	}
	
	public static function readInt16LE(chunk:Chunk, offset:Int):Int {
		var val = readUInt16LE(chunk, offset);
		return val > 0x7fff ? val - 0x10000 : val;
	}
	
	public static function readUInt24LE(chunk:Chunk, offset:Int):Int {
		check(chunk, offset, 3);
		var first = chunk[offset];
		var mid = chunk[offset + 1];
		var last = chunk[offset + 2];
		return first + (mid << 8) + (last << 16);
	}
	
	public static function readInt24LE(chunk:Chunk, offset:Int):Int {
		var val = readUInt24LE(chunk, offset);
		return val > 0x7fffff ? val - 0x1000000 : val;
	}
	
	public static function readInt32LE(chunk:Chunk, offset:Int):Int {
		check(chunk, offset, 4);

		var val = chunk[offset] +
			(chunk[offset+1] << 8) +
			(chunk[offset+2] << 16) +
			(chunk[offset+3] << 24); // Overflow
			
		return
			#if python
				val > (python.Syntax #if haxe4 .code #else .pythonCode #end('0x7fffffff'):Int) ? val - (python.Syntax #if haxe4 .code #else .pythonCode #end('0x100000000'):Int) : val;
			#elseif lua
				val > (untyped __lua__('0x7fffffff'):Int) ? val - (untyped __lua__('0x100000000'):Int) : val;
			#else
				val;
			#end
	}
	
	public static function readDoubleLE(chunk:Chunk, offset:Int):Float {
		var l = readInt32LE(chunk, 0);
		var h = readInt32LE(chunk, 4);
		return FPHelper.i64ToDouble(l, h);
	}
	
	public static function readNullTerminatedString(chunk:Chunk, offset:Int):String {
		return try new BytesInput(chunk, offset).readUntil(0) catch(e:Dynamic) chunk.toString();
	}
	
	public static function writeUInt8(v:Int):Chunk {
		#if python
		return Bytes.ofData(PythonStruct.pack('<B', v));
		#else
		var bytes = Bytes.alloc(1);
		bytes.set(0, v & 0xff);
		return bytes;
		#end
	}
	
	public static function writeInt8(v:Int):Chunk {
		#if python
		return Bytes.ofData(PythonStruct.pack('<b', v));
		#else
		var bytes = Bytes.alloc(1);
		v = v & 0xff;
		if(v < 0) v += 0x100;
		bytes.set(0, v);
		return bytes;
		#end
	}
	
	public static function writeUInt16LE(v:Int):Chunk {
		#if python
		return Bytes.ofData(PythonStruct.pack('<H', v));
		#else
		var bytes = Bytes.alloc(2);
		bytes.set(0, v & 0xff);
		bytes.set(1, (v >>> 8) & 0xff);
		return bytes;
		#end
	}
	
	public static inline function writeInt16LE(v:Int):Chunk {
		#if python
		return Bytes.ofData(PythonStruct.pack('<h', v));
		#else
		return writeUInt16LE(v);
		#end
	}
	
	public static function writeUInt24LE(v:Int):Chunk {
		var bytes = Bytes.alloc(3);
		bytes.set(0, v & 0xff);
		bytes.set(1, (v >>> 8) & 0xff);
		bytes.set(2, (v >>> 16) & 0xff);
		return bytes;
	}
	
	public static inline function writeInt24LE(v:Int):Chunk {
		return writeUInt24LE(v);
	}
	
	public static function writeInt32LE(v:Int):Chunk {
		#if python
		return Bytes.ofData(PythonStruct.pack('<l', v));
		#else
		var bytes = Bytes.alloc(4);
		bytes.set(0, v & 0xff);
		bytes.set(1, (v >>> 8) & 0xff);
		bytes.set(2, (v >>> 16) & 0xff);
		bytes.set(3, (v >>> 24) & 0xff);
		return bytes;
		#end
	}
	
	public static function writeDoubleLE(v:Float):Chunk {
		#if lua
		var data = untyped __lua__('("<d"):pack({0})', v);
		var bytes = Bytes.alloc(8);
		for(i in 0...8) bytes.set(i, lua.NativeStringTools.byte(data, i+1));
		return bytes;
		#elseif python
		return Bytes.ofData(PythonStruct.pack('<d', v));
		#else
		var bytes = Bytes.alloc(8);
		var i64 = FPHelper.doubleToI64(v);
		var l = i64.low;
		var h = i64.high;
		bytes.set(0, l & 0xff);
		bytes.set(1, (l >>> 8) & 0xff);
		bytes.set(2, (l >>> 16) & 0xff);
		bytes.set(3, (l >>> 24) & 0xff);
		bytes.set(4, h & 0xff);
		bytes.set(5, (h >>> 8) & 0xff);
		bytes.set(6, (h >>> 16) & 0xff);
		bytes.set(7, (h >>> 24) & 0xff);
		return bytes;
		#end
	}
	
	// counterpart of StringTools.lpad
	public static function lpad(chunk:Chunk, pad:Chunk, length:Int):Chunk {
		if(pad.length != 0) while(chunk.length < length) chunk = pad & chunk;
		return chunk;
	}
	
	// counterpart of StringTools.rpad
	public static function rpad(chunk:Chunk, pad:Chunk, length:Int):Chunk {
		if(pad.length != 0) while(chunk.length < length) chunk = chunk & pad;
		return chunk;
	}
	
	static inline function check(chunk:Chunk, offset:Int, length:Int) {
		if(chunk.length < offset + length) throw 'Out of range (chunk length = ${chunk.length}, read offset = ${offset}, read length = ${length})';
	}
}

#if python
@:pythonImport('struct')
extern class PythonStruct {
	static function pack(format:String, value:Dynamic):python.Bytes;
	static function unpack(format:String, value:python.Bytes):Dynamic;
}
#end