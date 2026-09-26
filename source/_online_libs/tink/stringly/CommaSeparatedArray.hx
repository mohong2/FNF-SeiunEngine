package tink.stringly;

@:forward
abstract CommaSeparatedArray<T>(Array<T>) from Array<T> to Array<T> {
	@:from
	public static function fromStringToString(v:String):CommaSeparatedArray<String>
		return [for(item in v.split(',')) ((item:tink.Stringly):String)]; // TODO: support quoted strings if they contains a comma?
		
	@:from
	public static function fromStringToInt(v:String):CommaSeparatedArray<Int>
		return [for(item in v.split(',')) ((item:tink.Stringly):Int)];
		
	@:from
	public static function fromStringToBool(v:String):CommaSeparatedArray<Bool>
		return [for(item in v.split(',')) ((item:tink.Stringly):Bool)];
		
	@:from
	public static function fromStringToFloat(v:String):CommaSeparatedArray<Float>
		return [for(item in v.split(',')) ((item:tink.Stringly):Float)];
}