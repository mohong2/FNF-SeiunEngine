package tink.url;

@:forward
abstract PortionArray(Array<Portion>) from Array<Portion> to Array<Portion> {
	@:to
	public function toStringArray()
		return [for(p in this) p.toString()];
}