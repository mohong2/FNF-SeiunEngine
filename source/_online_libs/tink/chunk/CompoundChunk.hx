package tink.chunk;

import haxe.io.Bytes;

class CompoundChunk extends ChunkBase implements ChunkObject {
  var chunks:Array<ChunkObject>;
  var offsets:Array<Int>;
  var length:Int;
  var depth:Int;
  
  public function getByte(i:Int) {
    var index = findChunk(i);
    return chunks[index].getByte(i - offsets[index]);
  }
  
  public function getLength()
    return this.length;

  static function asCompound(c:Chunk)
    return #if haxe4 Std.downcast #else Std.instance #end(c, CompoundChunk);

  static public function cons(a:Chunk, b:Chunk):Chunk
    return switch [a.length, b.length] {
      case [0, 0]: Chunk.EMPTY;
      case [0, _]: b;
      case [_, 0]: a;
      case [la, lb]: // TODO: add case for very short chunks (concatted in memory)
        switch [asCompound(a), asCompound(b)] {
          case [null, null]: create([a, b], 2);
          case [v, null] | [null, v]: 
            if (v.depth < 100)
              create([a, b], v.depth + 1);
            else {
              var flat = [];
              v.flatten(flat);
              (b:ChunkObject).flatten(flat);
              create(cast flat, 2);
            }
          case [a, b]:
            var depth = if (a.depth > b.depth) a.depth else b.depth;
            create(a.chunks.concat(b.chunks), depth);
        }
    }

  static function create(chunks:Array<Chunk>, depth:Int) {
    var ret = new CompoundChunk();
    var offsets = [0],
        length = 0;
    
    for (c in chunks) 
      offsets.push(length += c.length);

    ret.chunks = chunks;
    ret.offsets = offsets;
    ret.length = length;
    ret.depth = depth;
    
    return ret;
  }

  function new() {
    #if python
    super(); // https://github.com/HaxeFoundation/haxe/issues/7541
    #end
  }

  function findChunk(target:Int):Int {
    var min = 0,
        max = offsets.length - 1;
      
    while (min + 1 < max) {
      var guess = (min + max) >> 1;
      if (offsets[guess] > target) 
        max = guess;
      else
        min = guess;
    }
    
    return min;    
  }
  
  override public function flatten(into:Array<ByteChunk>) 
    for (c in chunks) c.flatten(into);
    
  public function slice(from:Int, to:Int):Chunk {
    var idxFrom = findChunk(from),
        idxTo = findChunk(to);

    if (idxFrom == idxTo) {
      var offset = offsets[idxFrom];
      return chunks[idxFrom].slice(from - offset, to - offset);
    }

    var ret = chunks.slice(idxFrom, idxTo + 1);
    {
      var c = ret[0];
      ret[0] = c.slice(from - offsets[idxFrom], offsets[idxFrom + 1]);
    }
    {
      var c = ret[ret.length - 1];
      ret[ret.length - 1] = c.slice(0, to - offsets[idxTo]);
    }

    return create(ret, depth);//technically the depth could decrease here, but counting is probably not worth the trouble
  }
    
  public function blitTo(target:Bytes, offset:Int):Void 
    for (i in 0...chunks.length)
      chunks[i].blitTo(target, offset + offsets[i]);
    
  public function toString() 
    return toBytes().toString();
    
  public function toBytes() {
    var ret = Bytes.alloc(this.length);
    blitTo(ret, 0);
    return ret;
  }
}