package tink;

using tink.CoreApi;
using StringTools;

@:transitive
abstract Stringly(String) from String to String {
   
  static function isNumber(s:String, allowFloat:Bool) {
    
    if (s.length == 0) return false;
    
    var pos = 0,
        max = s.length;
        
    inline function isDigit(code)
      return code ^ 0x30 < 10;//a sharp glimpse at the ASCII table revealed this to me
        
    inline function digits()
      while (pos < max && isDigit(s.fastCodeAt(pos))) pos++;
    
    inline function allow(code)
      return 
        if (pos < max && s.fastCodeAt(pos) == code) pos++ > -1;//always true ... not pretty, but generates much simpler code ... check with 3.3 again to see if it can be removed
        else false;
    
    allow('-'.code);
    
    if (!allowFloat) {
      if (allow('0'.code))
        allow('x'.code);
    }
    
    digits();
    
    if (allowFloat && pos < max) {
      if (allow('.'.code))
        digits();
        
      if (allow('e'.code) || allow('E'.code)) {
        allow('+'.code) || allow('-'.code);
        digits();
      }
    }
    
    return pos == max;
  }
    
  @:to public function toBool()
    return 
      this != null && switch this.trim().toLowerCase() {
        case 'false', '0', 'no': false;
        default: true;
      }
      
  public inline function isFloat() {
    return isNumber(this.trim(), true);
  }
    
  @:to public function parseFloat()
    return switch this.trim() {
      case v if (isNumber(v, true)):
        Success((Std.parseFloat(v) : Float));
      case v:
        Failure(new Error(UnprocessableEntity, '$v (encoded as $this) is not a valid float'));
    }
  
  @:to inline function toFloat()
    return parseFloat().sure();
    
  public inline function isInt() {
    return isNumber(this.trim(), false);
  }
    
  @:to public function parseInt()
    return switch this.trim() {
      case v if (isNumber(v, false)):
        Success((Std.parseInt(v) : Int));
      case v:
        Failure(new Error(UnprocessableEntity, '$v (encoded as $this) is not a valid integer'));
    }
        
  @:to inline function toInt()
    return parseInt().sure();
    
  
  // This is a subset of ISO 8601
  // - Only support full date+time: so for example '20:00Z' (no date) or '2017-01-01' (no time) are not supported
  // - timezone indicator must exist, either "Z" or "+00:00". "+00" and "+0000" are not supported
  // - sub-seconds is optional, but must be 3 digits if exists ".000"
  static var SUPPORTED_DATE_REGEX = ~/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d{3})?(Z|[\+-]\d{2}:\d{2})$/;
  
  @:to public function parseDate() {
    inline function fail(?pos:haxe.PosInfos) {
      return Failure(new Error(UnprocessableEntity, '$this is not a valid date' #if !macro, pos #end));
    }
    return switch parseFloat() {
      case Success(f):
        Success(Date.fromTime(f));
      case Failure(_): 
        if(!SUPPORTED_DATE_REGEX.match(this)) return fail();
      #if js
        var date:Date = #if haxe4 js.Syntax.code #else untyped __js__ #end('new Date({0})', this);
        if(Math.isNaN(date.getTime())) fail() else Success(date);
      #elseif java
        var outcome = try {
          var epoch = java.time.Instant.parse(this).getEpochSecond();
          var stamp = (Math.pow(1, 32) * epoch.high) + epoch.low;
          Success(Date.fromTime(stamp * 1000));
        } catch(e:Dynamic)
          Failure(new Error("java.time.Instant is not supported"));

        outcome.isSuccess() ? outcome : try {
          var d = java.javax.xml.bind.DatatypeConverter.parseDateTime(this).getTime();
          Success(new Date(d.getYear() + 1900, d.getMonth(), d.getDate(), d.getHours(), d.getMinutes(), d.getSeconds()));
        } catch(e:Dynamic)
          fail();
      #elseif cs
        try {
          var s = if(SUPPORTED_DATE_REGEX.matched(2) == null) this else this.substr(0, 23) + '0000' + this.substr(23);
          var d = cs.system.DateTime.Parse(s, null, cs.system.globalization.DateTimeStyles.None);
          Success(@:privateAccess new Date(d));
        } catch(e:Dynamic) 
          fail();
      #elseif php
        var s = this.replace('Z', '+00:00');
        var d = DateTime.createFromFormat(if(SUPPORTED_DATE_REGEX.matched(2) == null) 'Y-m-d\\TH:i:sP' else 'Y-m-d\\TH:i:s.uP', s, new DateTimeZone('UTC'));
        if( #if haxe4 php.Syntax.code #else untyped __php__ #end ('!{0}', d)) return fail();
        Success(Date.fromTime(d.getTimestamp() * 1000));
      #else
        var s = SUPPORTED_DATE_REGEX.matched(1).split('T');
        var d = s[0].split('-');
        var t = s[1].split(':');
        var y = Std.parseInt(d[0]) - 1970;
        var m = Std.parseInt(d[1]);
        var d = Std.parseInt(d[2]);
        var hh = Std.parseInt(t[0]);
        var mm = Std.parseInt(t[1]);
        var ss = Std.parseInt(t[2]);
        
        var days = y * 365 + d - 1;
        days += y < 2 ? 0 : Std.int((y-2) / 4); // leap years
        var daysOfMonth = [31,28,31,30,31,30,31,31,30,31,30,31];
        for(m in 0...m-1) days += daysOfMonth[m];
        if(y >= 2) if((y-2) % 4 != 0 || m >= 3) days ++; // current year is leap and already passed Feb
        var stamp = days * 86400 + hh * 3600 + mm * 60 + ss;
        
        var stamp = stamp + switch SUPPORTED_DATE_REGEX.matched(2) {
          case null: 0.0;
          case v: Std.parseInt(v.substr(1)) / 1000;
        }
        
        var stamp = stamp + switch SUPPORTED_DATE_REGEX.matched(3) {
          case 'Z': 0.0;
          case v:
            var positive = v.charCodeAt(0) == '+'.code;
            var s = v.substr(1).split(':');
            (Std.parseInt(s[0]) * 3600 + Std.parseInt(s[1]) * 60) * (positive ? -1 : 1);
        }
        
        Success(Date.fromTime(stamp * 1000));
        
      #end
    }
  }
  
  @:to inline function toDate()
    return parseDate().sure();

  public inline function parse<T>(f:Stringly->T)
    return f.bind(this).catchExceptions();
      
  @:from static inline function ofBool(b:Bool):Stringly
    return if (b) 'true' else 'false';
    
  @:from static inline function ofInt(i:Int):Stringly
    return Std.string(i);  
    
  @:from static inline function ofFloat(f:Float):Stringly
    return Std.string(f);
    
  @:from static inline function ofDate(d:Date):Stringly
    return ofFloat(d.getTime());
}

#if php
@:native('DateTime')
extern class DateTime {
  static function createFromFormat(format:String, time:String, ?timezone:Dynamic):DateTime;
  function getTimestamp():Int;
}
@:native('DateTimeZone')
extern class DateTimeZone {
  function new(s:String);
}
#end
