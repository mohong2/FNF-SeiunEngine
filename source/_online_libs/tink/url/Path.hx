package tink.url;

using haxe.io.Path;
using StringTools;

abstract Path(String) to String {
  
  public function parts():PortionArray
    return [for (p in this.split('/')) if (p != '') new Portion(p)];//TODO: consider using a cache
  
  public var absolute(get, never):Bool;
    inline function get_absolute()
      return this.charAt(0) == '/';
      
  public var isDir(get, never):Bool;
    inline function get_isDir()
      return this.charAt(this.length - 1) == '/';
    
  inline function new(s) 
    this = s;
    
  public function join(that:Path):Path
    return 
      if (that == '') cast this;
      else if (that.absolute) that;
      else //it's a little heavy to run through the WHOLE normalization here, but eh ... pull requests welcome
        if (isDir) ofString(this + (that : String));
        else switch this.lastIndexOf('/') {
          case -1: that;
          case v: this.substr(0, v + 1) + that;
        }
  
  @:from static public function ofString(s:String) {//TODO: consider what to do with invalid paths, e.g. '....'
    return new Path(normalize(s));
  }
  
  static public function normalize(s:String) {
    s = s.replace('\\', '/').trim();
    if (s == '.')
      return './';
      
    var isDir = s.endsWith('/..') || s.endsWith('/') || s.endsWith('/.');
    
    var parts = [],
        isAbsolute = s.startsWith('/'),
        up = 0;
    
    for (part in s.split('/'))
      switch part.trim() {
        case '':
        case '.':
        case '..': 
          if (parts.pop() == null) up++;
        case v: parts.push(v);
      }
      
    if (isAbsolute)
      parts.unshift('');
    else
      for (i in 0...up)
        parts.unshift('..');
    
    if (isDir)
      parts.push('');
      
    
    return parts.join('/');
  }
  
  public inline function toString():String
    return this;
  
  static public var root(default, null):Path = new Path('/');
}