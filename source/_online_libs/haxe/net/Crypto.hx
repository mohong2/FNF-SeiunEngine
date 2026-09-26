package haxe.net;

import haxe.io.Bytes;

#if python
@:pythonImport("os")
extern class RandomOs
{
	static public function urandom(count:Int):Array<Int>;
}
#end

class Crypto {
    static public function getSecureRandomBytes(length:Int):Bytes {
        var reason = '';
        try {
            #if flash
                return Bytes.ofData(untyped __global__["flash.crypto.generateRandomBytes"](length));
            #elseif js
                untyped __js__('var Crypto = typeof crypto === "undefined" ? require("crypto") : crypto');
                var bytes:Dynamic = untyped __js__("(Crypto.randomBytes) ? Crypto.randomBytes({0}) : Crypto.getRandomValues(new Uint8Array({0}))", length);
                var out = Bytes.alloc(length);
                for (n in 0 ... length) out.set(n, bytes[n]);
                return out;
            #elseif python
                var out = Bytes.alloc(length);
                var bytes = RandomOs.urandom(length);
                for (n in 0 ... length) out.set(n, bytes[n]);
                return out;
            #elseif java
                return Bytes.ofData(java.security.SecureRandom.getSeed(length));
            #elseif cs
                var out = Bytes.alloc(length);
                var rng = new cs.system.security.cryptography.RNGCryptoServiceProvider();
                rng.GetBytes(out.getData());
                return out;
            #elseif (windows || hl)
                /* var input = sys.io.File.read("\\Device\\KsecDD"); */
                return haxe.io.Bytes.ofString(getRandomString(16));
            #elseif sys
                // https://en.wikipedia.org/wiki//dev/random
                var out = Bytes.alloc(length);
                var input = sys.io.File.read("/dev/urandom");
                input.readBytes(out, 0, length);
                input.close();
                return out;
            #end
        } catch (e:Dynamic) {
            reason = '$e';
        }
        throw "Can't find a secure source of random bytes. Reason: " + reason;
    }

    // workaround for windows platform
    public static function getRandomString(length:Int, ?charactersToUse = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"): String
    {
        var str = "";
        for (i in 0...length){
            str += charactersToUse.charAt( Math.floor((Math.random() *  (Date.now().getTime() % (charactersToUse.length) ) )));
        }
        return str;
    }

}
