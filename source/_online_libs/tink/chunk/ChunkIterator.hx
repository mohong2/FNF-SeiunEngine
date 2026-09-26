package tink.chunk;

import haxe.io.Bytes;
import haxe.io.BytesData;

class ChunkIterator {
  
  var target:ChunkCursor;
  var _hasNext:Bool;
  
  public inline function new(target) {
    this.target = target;
    this._hasNext = target.length > target.currentPos;
  }
  
  public inline function hasNext()
    return _hasNext;
    
  public inline function next() {
    var ret = target.currentByte;
    _hasNext = target.next();
    return ret;
  }
}