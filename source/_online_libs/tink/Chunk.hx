package tink;

import haxe.io.Bytes;
import haxe.io.BytesData;
import tink.chunk.*;

private class EmptyChunk extends ChunkBase implements ChunkObject {
  public function new() {
    #if python
    super(); // https://github.com/HaxeFoundation/haxe/issues/7541
    #end
  }
  
  public function getByte(i:Int)
    return 0;
    
  public function getLength()
    return 0;
    
  public function slice(from:Int, to:Int):Chunk
    return this;
    
  public function blitTo(target:Bytes, offset:Int):Void {}
    
  public function toString()
    return '';
    
  public function toBytes()
    return EMPTY;
    
  static var EMPTY = Bytes.alloc(0);
}


@:jsonStringify(function(chunk) return chunk.toBytes())
@:jsonParse(tink.Chunk.ofBytes)
#if haxe4
@:tink.encode(function(chunk) return chunk.toBytes())
@:tink.decode(tink.Chunk.ofBytes)
#end
@:pure 
@:using(tink.chunk.ChunkTools)
abstract Chunk(ChunkObject) from ChunkObject to ChunkObject {
  
  public var length(get, never):Int;
    inline function get_length()
      return this.getLength();
      
  @:arrayAccess
  public inline function getByte(i:Int):Int
    return this.getByte(i);
      
  public function concat(that:Chunk) 
    return CompoundChunk.cons(this, that);
    
  public inline function cursor()  
    return this.getCursor();
  
  public inline function iterator()
    return new ChunkIterator(this.getCursor());
      
  public inline function sub(pos:Int, len:Int):Chunk 
    return this.slice(pos, pos + len);
      
  public inline function slice(from:Int, to:Int):Chunk 
    return this.slice(from, to);
    
  public inline function blitTo(target:Bytes, offset:Int)
    return this.blitTo(target, offset);
  
  public inline function toHex()
    return this.toBytes().toHex();
    
  @:to public inline function toString()
    return this.toString();
    
  @:to public inline function toBytes()
    return this.toBytes();
  
  #if (nodejs && !macro)
  @:to public inline function toBuffer()
    return js.node.Buffer.hxFromBytes(this.toBytes());
  #end
  
  #if (js && !nodejs && !macro)
  @:to inline function castToBlob()
    return toBlob();
  
  public inline function toBlob(?opt)
    return new js.html.Blob([this.toBytes().getData()], opt);
  #end
    
  static public function join(chunks:Array<Chunk>)
    return switch chunks {
      case null | []: EMPTY;
      case [v]: v;
      case v:
        var ret = v[0] & v[1];
        for (i in 2...v.length)
          ret = ret & v[i];
        ret;
    }
  
  @:from public static inline function ofBytes(b:Bytes):Chunk 
    return (ByteChunk.of(b) : ChunkObject);
    
  @:from public static inline function ofString(s:String):Chunk 
    return ofBytes(Bytes.ofString(s));
    
  #if (js && !nodejs)
  @:from public static inline function ofUint8Array(b:js.lib.Uint8Array):Chunk 
    return Bytes.ofData(b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength)); // TODO: create Uint8ArrayChunk to optimize
  #end
    
  #if (nodejs && !macro)
  @:from public static inline function ofBuffer(b:js.node.Buffer):Chunk 
    return new tink.chunk.nodejs.BufferChunk(b);
  #end
  
  @:from
  public static function ofByte(byte:Int):Chunk {
    var bytes = Bytes.alloc(1);
    bytes.set(0, byte);
    return bytes;
  }
    
  public static function ofHex(s:String):Chunk {
    var length = s.length >> 1;
    var bytes = Bytes.alloc(length);
    for(i in 0...length) bytes.set(i, parseHex(s.substr(i * 2, 2)));
    return bytes;
  }
  
  // Workaround parseInt bug in Haxe3/Lua
  // TODO: actually this is an optimization and can be applied on other targets too
  static inline function parseHex(v:String) {
    #if lua
    return lua.Lua.tonumber(v, 16);
    #else
    return Std.parseInt('0x' + v);
    #end
  }
    
  @:op(a & b) inline static function catChunk(a:Chunk, b:Chunk)
    return a.concat(b);
    
  @:op(a & b) static function rcatString(a:Chunk, b:String)
    return catChunk(a, b);
    
  @:op(a & b) static function lcatString(a:String, b:Chunk)
    return catChunk(a, b);
    
  @:op(a & b) static function lcatBytes(a:Bytes, b:Chunk)
    return catChunk(a, b);
    
  @:op(a & b) static function rcatBytes(a:Chunk, b:Bytes)
    return catChunk(a, b);
    
  @:op(a == b) static function eqChunk(a:Chunk, b:Chunk)
    return a.toString() == b.toString(); // TODO: optimize
    
  @:op(a == b) static function reqString(a:Chunk, b:String)
    return a.toString() == b.toString(); // TODO: optimize
    
  @:op(a == b) static function leqString(a:String, b:Chunk)
    return a.toString() == b.toString(); // TODO: optimize
    
  @:op(a == b) static function leqBytes(a:Bytes, b:Chunk)
    return a.toString() == b.toString(); // TODO: optimize
    
  @:op(a == b) static function reqBytes(a:Chunk, b:Bytes)
    return a.toString() == b.toString(); // TODO: optimize
    
  static public var EMPTY(default, null):Chunk = ((new EmptyChunk() : ChunkObject) : Chunk);//haxe 3.2.1 ¯\_(ツ)_/¯
}