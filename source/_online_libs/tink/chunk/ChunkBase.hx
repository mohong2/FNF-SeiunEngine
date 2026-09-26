package tink.chunk;

class ChunkBase {
  var flattened:Array<ByteChunk>;
  #if python
  public function new() {} // https://github.com/HaxeFoundation/haxe/issues/7541
  #end
  public function getCursor() {
    if (flattened == null) 
      flatten(this.flattened = []);
    return ChunkCursor.create(flattened.copy());
  }
  public function flatten(into:Array<ByteChunk>) {}
}