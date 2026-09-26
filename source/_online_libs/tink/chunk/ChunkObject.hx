package tink.chunk;

import haxe.io.Bytes;

interface ChunkObject {
  function getByte(i:Int):Int;
  function getCursor():ChunkCursor;
  function flatten(into:Array<ByteChunk>):Void;
  function getLength():Int;
  function slice(from:Int, to:Int):Chunk;
  function toString():String;
  function toBytes():Bytes;
  function blitTo(target:Bytes, offset:Int):Void;
}