package tink.chunk;

import haxe.ds.Option;
using haxe.io.Bytes;

class ChunkCursor {
  
  var parts:Array<ByteChunk>;
  var curPart:ByteChunk;
  var curPartIndex:Int = 0;
  var curOffset:Int = 0;
  var curLength:Int = 0;
  
  public var length(default, null):Int = 0;
  public var currentPos(default, null):Int = 0;
  public var currentByte(default, null):Int = -1;
  
  static public function create(parts) {
    var ret = new ChunkCursor();
    ret.parts = parts;
    ret.reset();
    return ret;
  }
  
  /**
   *  Creates a cloned cursor
   *  @return cloned cursor
   */
  public function clone() {
    var ret = new ChunkCursor();
    ret.parts = this.parts.copy();
    ret.curPart = this.curPart;
    ret.curPartIndex = this.curPartIndex;
    ret.curOffset = this.curOffset;
    ret.curLength = this.curLength;
    ret.length = this.length;
    ret.currentPos = this.currentPos;
    ret.currentByte = this.currentByte;
    return ret;
  }

  function new() {}
    
  function reset() {
    length = 0;
    currentPos = 0;
    currentByte = -1;
    curOffset = 0;
    
    for (p in parts)
      length += p.getLength();
    
    this.curPart = parts[this.curPartIndex = 0];
    if (this.curPart != null) {
      this.curLength = this.curPart.getLength();
      this.currentByte = this.curPart.getByte(0);
    }    
  }
  
  /**
   *  Like prune(), but returns the removed chunk
   *  @return Removed chunk (chunk to the left of current position)
   */
  public function flush() {
    var ret = left();
    prune();
    return ret;
  }

  /**
   *  Remove chunk to the left of current position and reset `currentPos` to zero.
   */
  public inline function prune() 
    shift();

  /**
   *  Add a chunk to the end and reset `currentPos` to zero.
   *  @param chunk - Chunk to be added
   */
  public function add(chunk:Chunk) {
    (chunk : ChunkObject).flatten(parts);//load new data
    reset();
  }

  /**
   *  Remove data to the left of current position and optionally add a chunk at the end.
   *  Reset `currentPos` to zero.
   *  @param chunk - Optional chunk to be added to the end
   */
  public function shift(?chunk:Chunk) {

    parts.splice(0, curPartIndex);//throw out all old chunks
    
    switch parts[0] {
      case null:
      case chunk:
        switch chunk.getSlice(curOffset, curLength) {//get rid of old data in current chunk
          case null:
            parts.shift();
          case rest:
            parts[0] = rest;
        }
    }
    
    if (chunk != null)
      add(chunk);
    else
      reset();
  }

  /**
   *  Clear all data of this cursor
   */
  public function clear() {
    parts = [];
    reset();
  }

  /**
   *  Return the chunk to the left of current position, excluding current byte
   */
  public function left() {
    if (curPart == null) return Chunk.EMPTY;
    var left = [for (i in 0...curPartIndex) (parts[i]:Chunk)];
    left.push(curPart.slice(0, curOffset));
    return Chunk.join(left);
  }
  
  /**
   *  Return the chunk to the right of current position, including current byte
   */
  public function right() {
    if (curPart == null) return Chunk.EMPTY;
    var right = [for (i in curPartIndex...parts.length) (parts[i]:Chunk)];
    if (right.length > 0) {
      right[0] = curPart.slice(curOffset, curLength);
    }
    return Chunk.join(right);
  }

  public function seek(seekable:Seekable, ?options: { ?withoutPruning:Bool }):Option<Chunk> {

    if (curPart == null || seekable == null || seekable.length == 0)
      return None;

    var max = seekable.length - 1,
        first = seekable[0],
        candidates = [],
        count = 0,
        copy = clone();
    
    copy.shift();

    function part(b:ByteChunk, offset:Int) @:privateAccess {
      var data = b.data;
      
      for (i in b.from + offset ... b.to) {
        var byte = data.fastGet(i);

        if (candidates.length > 0) {
          var c = 0;
          while (c < count) {
            var pos = candidates[c];
            if (seekable[pos] == byte) 
              if (pos == max) {
                copy.moveBy(i-(b.from + offset) - seekable.length + 1);
                var before = copy.left();
                this.moveBy(before.length + seekable.length);
                switch options {
                  case null | { withoutPruning: false | null }:
                    this.prune();
                  default:
                }
                return Some(before);
              }
              else candidates[c++] = pos + 1;
            else {
              count--;
              var last = candidates.pop();
              if (count > c)
                candidates[c] = last;
            }

          }
        }

        if (byte == first)
          count = candidates.push(1);
      }

      copy.moveBy(b.to - (b.from + offset));

      return None;
    }

    switch part(curPart, curOffset) {
      case None: 

        for (i in curPartIndex+1...parts.length)
          switch part(parts[i], 0) {
            case Some(v): return Some(v);
            case None: 
          }

        return None;
      case v: return v;
    }
  }
  
  /**
   *  Like moveBy(), but returns the swept chunk instead of new position
   *  @param len - length to sweep
   *  @return the swept chunk
   */
  public function sweep(len:Int) {
    var data = right().slice(0, len);
    moveBy(len);
    return data;
  }
  
  /**
   *  Like moveTo(), but returns the swept chunk instead of new position
   *  @param pos - target position
   *  @return the swept chunk
   */
  public inline function sweepTo(pos:Int)
    return sweep(pos - currentPos);
  
  /**
   *  Move cursor position by specified amount.
   *  @param delta - amount to move
   *  @return new position
   */
  public inline function moveBy(delta:Int) 
    return moveTo(currentPos + delta);

  /**
   *  Move to specified position.
   *  If `position` is greater than length of cursor, it is set to `length - 1`.
   *  If `position` is less than zero, it is set to zero.
   *  @param position - the position to move to
   *  @return new position
   */
  public function moveTo(position:Int) {
    
    if (length == 0) return 0;

    if (position > length) position = length - 1;
    if (position < 0) position = 0;
    
    this.currentPos = position;
    
    if (position == length) ffwd();
    else
      for (i in 0...parts.length) {
        var c = parts[i];
        switch c.getLength() {
          case enough if (enough > position):
            this.curPart = c;
            this.curPartIndex = i;
            this.curOffset = position;
            this.curLength = c.getLength();
            this.currentByte = c.getByte(position);
            break;
          case v: 
            position -= v;
        }
      }

    return this.currentPos;
  }

  function ffwd() {
    currentByte = -1;
    curLength = 0;
    curOffset = 0;
    curPart = null;
    curPartIndex = parts.length;//right?
  }

  /**
   *  Advance to next byte
   *  @return `false` if there is no next byte
   */
  public function next():Bool {
    if (currentPos == length) return false;
    currentPos++;
    if (currentPos == length) {
      ffwd();
      return false;
    }
    if (curOffset == curLength - 1) {
      curOffset = 0;
      curPart = parts[++curPartIndex];
      curLength = curPart.getLength();
      currentByte = curPart.getByte(0);
    }
    else {
      currentByte = curPart.getByte(++curOffset);
    }
    return true;
  }
}
