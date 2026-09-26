package online_server;

import haxe.io.Bytes;
import haxe.io.BytesOutput;
import io.colyseus.serializer.schema.Schema;
import io.colyseus.serializer.schema.types.ArraySchema.IArraySchema;
import io.colyseus.serializer.schema.types.MapSchema.IMapSchema;
import io.colyseus.serializer.schema.types.ISchemaCollection;

/**
 * Server-side outbound encoder: turns online.backend.schema instances into the
 * @colyseus/schema wire format.
 *
 * The repo ships only a Decoder (client-side decoding) and no Encoder, so this class is
 * strictly the inverse of:
 *   source/_online_libs/io/colyseus/serializer/schema/Decoder.hx
 *   source/_online_libs/io/colyseus/serializer/schema/Schema.hx   (SPEC / OPERATION)
 *   source/_online_libs/io/colyseus/serializer/schema/encoding/Decode.hx
 *   source/_online_libs/io/colyseus/serializer/schema/types/{MapSchema,ArraySchema}.hx
 *
 * Three hard constraints come from the Decoder implementation:
 *
 *  1. Field indexes must stay below 64. decodeSchema reads a single byte:
 *     `operation = (byte >> 6) << 6; fieldIndex = byte % (operation == 0 ? 255 : operation)`,
 *     with no two-byte branch. The largest index across this project's 5 schemas is 28
 *     (Player.arrowColorsPixel).
 *
 *  2. A field pointing at a child structure/collection must use ADD(0x80|index) the first
 *     time, never REPLACE. decodeValue calls createInstance + refs.add only when
 *     `(operation & ADD) == ADD`; REPLACE yields null and drops the field.
 *
 *  3. **The encoder must track the client's current structure.** In the Decoder's main
 *     loop `ref` is a persistent cursor that only moves on 0xFF; after an empty collection
 *     (no entries) is encoded, writing the parent's next field directly makes the client
 *     decode that field index as a collection operation. This encoder therefore keeps
 *     currentRefId and calls switchTo(structure) before writing any field/item.
 *     The client resets ref to state (refId 0) at the start of every message, so
 *     currentRefId is reset per message as well.
 *
 * The server keeps the authoritative state copy: encoding also maintains __refId so later
 * patches can reuse the same refId.
 */
class SchemaEncoder {
	public static inline var SWITCH_TO_STRUCTURE:Int = 0xFF;

	public static inline var OP_REPLACE:Int = 0;
	public static inline var OP_DELETE:Int = 64;
	public static inline var OP_ADD:Int = 128;
	public static inline var OP_DELETE_AND_ADD:Int = 192;
	/** Collection "clear" operation (the CLEAR branch of Decoder.decodeArraySchema / decodeMapSchema). */
	public static inline var OP_CLEAR:Int = 10;

	var out:BytesOutput;
	var nextRefId:Int = 0;
	var currentRefId:Int = 0;
	var mapIndexes:haxe.ds.ObjectMap<Dynamic, Map<String, Int>> = new haxe.ds.ObjectMap();

	public function new() {}

	// ------------------------------------------------------------------
	// Full state: ROOM_STATE payload
	// ------------------------------------------------------------------

	public function encodeAll(state:Schema):Bytes {
		out = new BytesOutput();
		// root's refId must be 0: the client Decoder does refs.add(0, state) at construction
		// and resets ref to state before every decode. nextRefId is not reset because refIds
		// must stay monotonic, or a new structure would collide with an existing one.
		state.__refId = 0;
		currentRefId = 0;

		encodeSchemaFields(state, 0);
		return out.getBytes();
	}

	// ------------------------------------------------------------------
	// Incremental: ROOM_STATE_PATCH payload
	// ------------------------------------------------------------------

	/** Replaces one scalar field of a schema instance and updates the server-side state. */
	public function encodeFieldChange(schema:Schema, fieldName:String, value:Dynamic):Bytes {
		out = new BytesOutput();
		currentRefId = 0;

		var refId:Int = fieldOf(schema, "__refId");
		switchTo(refId);

		var index = indexOfField(schema, fieldName);
		var type = schema._types.get(index);

		Reflect.setField(schema, fieldName, value);

		out.writeByte(OP_REPLACE | index);
		encodePrimitive(type, value);
		return out.getBytes();
	}

	/** Adds a key -> schema instance to a map collection and updates the server-side state. */
	public function encodeMapAdd(coll:ISchemaCollection, key:String, value:Schema):Bytes {
		out = new BytesOutput();
		currentRefId = 0;

		var collRefId = ensureRefId(coll);
		switchTo(collRefId);

		out.writeByte(OP_ADD);
		encodeNumber(protocolIndex(coll, key));
		encodeString(key);
		encodeSchemaRef(value);

		setMapItem(coll, key, value);
		return out.getBytes();
	}

	/** Removes a key from a map collection and updates the server-side state. */
	public function encodeMapRemove(coll:ISchemaCollection, key:String):Bytes {
		out = new BytesOutput();
		currentRefId = 0;

		var collRefId = ensureRefId(coll);
		switchTo(collRefId);

		out.writeByte(OP_DELETE);
		encodeNumber(protocolIndex(coll, key));

		removeMapItem(coll, key);
		return out.getBytes();
	}

	/**
	 * Replaces the **entire contents** of an `ArraySchema<String>` field: CLEAR first, then one
	 * ADD per entry.
	 *
	 * `encodeFieldChange` only handles scalars (an "array" field falls through to
	 * encodePrimitive's default and throws), and `Player.skin` is a string array that changes
	 * at runtime (client `setSkin` -> server writes the schema).
	 *
	 * Per `Decoder.decodeArraySchema` / `ArraySchemaImpl.setByIndex`:
	 *   * The field itself needs **no** REPLACE: the collection's refId was already registered
	 *     with the client during the first full state / ADD patch, so `switchTo(collRefId)`
	 *     moves the cursor to it and CLEAR empties the array it currently points at.
	 *   * **CLEAR is required first**: when `index == 0 && operation == ADD && items.length > 0`,
	 *     `ArraySchemaImpl.setByIndex` does `insert(0, value)` (the first element is pushed to
	 *     the front); without clearing, entry 0 would be inserted in the wrong order.
	 */
	public function encodeStringArrayReplace(schema:Schema, fieldName:String, values:Array<String>):Bytes {
		out = new BytesOutput();
		currentRefId = 0;

		var coll:Dynamic = Reflect.field(schema, fieldName);
		if (fieldOf(coll, "__refId") == 0) {
			// The collection must already have been encoded to the client (encodeAll / encodeMapAdd
			// write a refId even for empty collections).
			trace('SchemaEncoder: collection "$fieldName" has no refId yet; the patch would be lost client-side');
		}
		var collRefId:Int = ensureRefId(coll);
		switchTo(collRefId);

		out.writeByte(OP_CLEAR);
		var items:Array<Dynamic> = Reflect.getProperty(coll, "items");
		while (items.length > 0) {
			items.pop();
		}

		for (i in 0...values.length) {
			out.writeByte(OP_ADD);
			encodeNumber(i);
			encodeString(values[i]);
			items.push(values[i]);
		}

		return out.getBytes();
	}

	// ------------------------------------------------------------------
	// Internals
	// ------------------------------------------------------------------

	function switchTo(refId:Int):Void {
		if (currentRefId == refId) {
			return;
		}
		out.writeByte(SWITCH_TO_STRUCTURE);
		encodeNumber(refId);
		currentRefId = refId;
	}

	function encodeSchemaFields(schema:Schema, schemaRefId:Int):Void {
		var indexes = new Array<Int>();
		for (k in schema._indexes.keys()) {
			indexes.push(k);
		}
		indexes.sort(function(a, b) return a - b);

		for (i in indexes) {
			var fieldName = schema._indexes.get(i);
			var type:String = schema._types.get(i);
			var childType:Dynamic = schema._childTypes.get(i);
			var value:Dynamic = Reflect.getProperty(schema, fieldName);

			if (value == null) {
				continue; // client fields carry their own defaults, so skip it
			}

			switchTo(schemaRefId);

			if (childType == null) {
				out.writeByte(OP_REPLACE | i);
				encodePrimitive(type, value);

			} else if (Std.isOfType(childType, String)) {
				// Collection whose elements are scalars (ArraySchema<String> / MapSchema<String> ...)
				out.writeByte(OP_REPLACE | i);
				encodeCollection(cast value, cast childType);

			} else {
				// Collection whose elements are schema child objects
				out.writeByte(OP_REPLACE | i);
				encodeCollection(cast value, null);
			}
		}
	}

	/** Encodes a collection field: write its refId as the field value, then switch in and write each entry. */
	function encodeCollection(coll:ISchemaCollection, ?primitiveType:String):Void {
		var refId = ensureRefId(coll);
		encodeNumber(refId);
		switchTo(refId);

		if (Std.isOfType(coll, IMapSchema)) {
			var items:Dynamic = Reflect.getProperty(coll, "items");
			var keys:Array<String> = Reflect.getProperty(items, "_keys");
			var getter = Reflect.field(items, "get");

			for (key in keys) {
				var value:Dynamic = Reflect.callMethod(items, getter, [key]);

				// Switch back to the collection itself: encoding the previous entry leaves the
				// client cursor on that child structure, so without switching back this entry
				// would be decoded as a field of the child (invisible with a single entry).
				switchTo(refId);

				out.writeByte(OP_ADD);
				encodeNumber(protocolIndex(coll, key));
				encodeString(key);

				if (primitiveType != null) {
					encodePrimitive(primitiveType, value);
				} else {
					encodeSchemaRef(cast value);
				}
			}

		} else {
			var arr:Array<Dynamic> = Reflect.getProperty(coll, "items");

			for (i in 0...arr.length) {
				// The cursor must be on the array itself before each element.
				switchTo(refId);

				out.writeByte(OP_ADD);
				encodeNumber(i);

				if (primitiveType != null) {
					encodePrimitive(primitiveType, arr[i]);
				} else {
					encodeSchemaRef(cast arr[i]);
				}
			}
		}
	}

	/** Writes a child structure: its refId as the parent field/element value, then switches to it and writes all its fields. */
	function encodeSchemaRef(value:Schema):Void {
		var refId = ensureRefId(value);
		encodeNumber(refId);
		switchTo(refId);
		encodeSchemaFields(value, refId);
	}

	function ensureRefId(obj:Dynamic):Int {
		var id:Int = fieldOf(obj, "__refId");
		if (id == 0) {
			nextRefId++;
			id = nextRefId;
			Reflect.setField(obj, "__refId", id);
		}
		return id;
	}

	function fieldOf(obj:Dynamic, name:String):Int {
		var v:Dynamic = Reflect.field(obj, name);
		if (v == null) {
			return 0;
		}
		return cast v;
	}

	function indexOfField(schema:Schema, fieldName:String):Int {
		for (i in schema._indexes.keys()) {
			if (schema._indexes.get(i) == fieldName) {
				return i;
			}
		}
		throw 'SchemaEncoder: field not found: $fieldName';
	}

	/** Protocol integer index for a map key: stable and unique within one collection. */
	function protocolIndex(coll:Dynamic, key:String):Int {
		var m = mapIndexes.get(coll);
		if (m == null) {
			m = new Map<String, Int>();
			mapIndexes.set(coll, m);
		}
		if (!m.exists(key)) {
			var next = 0;
			for (_ in m.keys()) {
				next++;
			}
			m.set(key, next);
		}
		return m.get(key);
	}

	function setMapItem(coll:ISchemaCollection, key:String, value:Schema):Void {
		var items:Dynamic = Reflect.getProperty(coll, "items");
		Reflect.callMethod(items, Reflect.field(items, "set"), [key, value]);
	}

	function removeMapItem(coll:ISchemaCollection, key:String):Void {
		var items:Dynamic = Reflect.getProperty(coll, "items");
		Reflect.callMethod(items, Reflect.field(items, "remove"), [key]);
	}

	// ------------------------------------------------------------------
	// Scalar encoding (must stay exactly symmetric with encoding/Decode.hx)
	// ------------------------------------------------------------------

	public function encodeNumber(v:Float):Void {
		if (Math.isNaN(v) || v != Math.ffloor(v) || v < -2147483648 || v > 2147483647) {
			out.writeByte(0xCB); // float 64
			out.writeDouble(v);
			return;
		}

		var i = Std.int(v);
		if (i >= 0 && i < 128) {
			out.writeByte(i); // positive fixint
		} else if (i < 0 && i >= -32) {
			out.writeByte(0x100 + i); // negative fixint
		} else {
			out.writeByte(0xD2); // int 32
			out.writeInt32(i);
		}
	}

	public function encodeString(s:String):Void {
		var bytes = Bytes.ofString(s);
		var len = bytes.length;

		if (len < 32) {
			out.writeByte(0xA0 | len); // fixstr
		} else if (len < 256) {
			out.writeByte(0xD9);
			out.writeByte(len);
		} else if (len < 65536) {
			out.writeByte(0xDA);
			out.writeByte(len & 0xFF);
			out.writeByte((len >> 8) & 0xFF);
		} else {
			out.writeByte(0xDB);
			out.writeInt32(len);
		}

		out.writeBytes(bytes, 0, len);
	}

	function encodePrimitive(type:String, value:Dynamic):Void {
		switch (type) {
			case "string":
				encodeString(cast value);

			case "number":
				encodeNumber(cast value);

			case "boolean":
				out.writeByte(((cast value : Bool)) ? 1 : 0);

			case "int8", "uint8":
				out.writeByte((cast value : Int) & 0xFF);

			case "int16", "uint16":
				var v:Int = cast value;
				out.writeByte(v & 0xFF);
				out.writeByte((v >> 8) & 0xFF);

			case "int32", "uint32":
				out.writeInt32(cast value);

			case "float32":
				out.writeFloat(cast value);

			case "float64":
				out.writeDouble(cast value);

			default:
				throw 'SchemaEncoder: unsupported primitive type "$type"';
		}
	}
}
