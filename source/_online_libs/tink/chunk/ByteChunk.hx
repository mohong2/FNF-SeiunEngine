package tink.chunk;

import haxe.io.Bytes;
import haxe.io.BytesData;

class ByteChunk extends ChunkBase implements ChunkObject {
  //TODO: on JS this pretty much reinvents the wheel

  var data:BytesData;
  var from:Int;
  var to:Int;

  var wrapped(get, null):Bytes;
    inline function get_wrapped() {
      if (wrapped == null)
        wrapped = Bytes.ofData(data);
      return wrapped;
    }

  function new(data, from, to) {
    #if python
    super(); // https://github.com/HaxeFoundation/haxe/issues/7541
    #end
    this.data = data;
    this.from = from;
    this.to = to;
  }

  public inline function getByte(index:Int)
    return Bytes.fastGet(data, from + index);

  override public function flatten(into:Array<ByteChunk>)
    into.push(this);

  public inline function getLength():Int
    return to - from;

  public function getSlice(from:Int, to:Int) {
    if (to > this.getLength())
      to = this.getLength();

    if (from < 0)
      from = 0;

    return
      if (to <= from) null;
      else if (to == this.getLength() && from == 0) this;
      else new ByteChunk(data, this.from + from, to + this.from);
  }

  public function slice(from:Int, to:Int):Chunk
    return
      switch getSlice(from, to) {
        case null: Chunk.EMPTY;
        case v: v;
      }

  public function blitTo(target:Bytes, offset:Int):Void
    target.blit(offset, wrapped, from, getLength());

  public function toBytes():Bytes
    return wrapped.sub(from, getLength());

  public function toString():String
    return wrapped.getString(from, getLength());

  static public function of(b:Bytes):Chunk {
    if (b.length == 0)
      return Chunk.EMPTY;
    var ret = new ByteChunk(b.getData(), 0, b.length);
    ret.wrapped = b;
    return (ret:ChunkObject);
  }

}