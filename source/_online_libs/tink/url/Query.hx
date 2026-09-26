package tink.url;

import haxe.DynamicAccess;
import tink.core.Named;

using StringTools;

abstract Query(String) from String to String {  
  
  public inline function parse() 
    return iterator();
    
  public function with(values:Map<Portion, Portion>):Query {
    var ret = new QueryStringBuilder();
    
    var insert = [for(key in values.keys()) key];
    
    for(p in iterator()) {
      if(values.exists(p.name)) {
        ret.add(p.name, values[p.name]);
        insert.remove(p.name);
      } else {
        ret.add(p.name, p.value);
      }
    }
    
    for(name in insert) ret.add(name, values[name]);
    
    return ret.toString();
  }
  
  
  @:to public inline function iterator() 
    return parseString(this);
  
  @:to public function toMap():Map<String, Portion>
    return [for (p in iterator()) (p.name:String).toString() => p.value]; // cast to string explicitly to help 3.2.1 cpp
  
  @:from static function ofObj(v:Dynamic<String>):Query {
    var ret = new QueryStringBuilder(),
        v:DynamicAccess<String> = v;
        
    for (k in v.keys())
      ret.add(k, v[k]);
      
    return ret.toString();
  }    
  
  public inline function toString():String
    return this;
    
  static public inline function build():QueryStringBuilder 
    return new QueryStringBuilder();
   
  static public inline function parseString(s:String, sep:String = '&', set:String = '=', pos:Int = 0)
    return new QueryStringParser(s, sep, set, pos);
    
}

abstract QueryStringBuilder(Array<String>) {
  
  public inline function new() {
    this = [];
  }
  
  public inline function add(name:Portion, value:Portion):QueryStringBuilder {
    this.push(name.raw + '=' + value.raw);
    return cast this;
  }
  
  public inline function toString(?sep:String = '&')
    return this.join(sep);
    
  public function copy():QueryStringBuilder
    return cast this.copy();
}

typedef QueryStringParam = Named<Portion>;

private class QueryStringParser {
  
  var s:String;
  var sep:String;
  var set:String;
  var pos:Int;
  
  public function new(s, sep, set, pos) {
    this.s = switch s {
      case null: '';
      default: s;
    }
    this.sep = sep;
    this.set = set;
    this.pos = pos;
  }
  
  public function hasNext() 
    return pos < s.length;
    
  public function next() {
    var next = s.indexOf(sep, pos);
    
    if (next == -1)
      next = s.length;
    
    var split = s.indexOf(set, pos);
    var start = pos;
      
    pos = next + sep.length;
    
    return 
      if (split == -1 || split > next)
        new QueryStringParam(trimmedSub(s, start, next), '');
      else
        new QueryStringParam(trimmedSub(s, start, split), trimmedSub(s, split + set.length, next));
  }

  static function trimmedSub(s:String, start:Int, end:Int) {
    
    if(start >= s.length) return new Portion('');
    
    while (s.fastCodeAt(start) < 33) 
      start++;
    
    if (end < s.length - 1)
      while (s.fastCodeAt(end-1) < 33) 
        end--;
      
    return new Portion(s.substring(start, end));
  }  
  
}
