package tink.chunk;

import haxe.io.Bytes;

abstract Seekable(Array<Int>) {

  inline function new(a) this = a; 

  public var length(get, never):Int;
    inline function get_length()
      return this.length;

  @:arrayAccess public inline function get(index:Int)
    return this[index];
  
  @:from static public inline function ofChunk(c:Chunk)
    return ofBytes(c);
  
  @:from static public function ofBytes(b:Bytes)
    return new Seekable([for (i in 0...b.length) b.get(i)]);

  @:from static public inline function ofString(s:String) 
    return ofBytes(Bytes.ofString(s));
}