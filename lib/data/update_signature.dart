// Updates are only trusted when signed.
//
// The file that says "there is a new version, and this is where to get it" sits on the account
// server. If that server were ever taken over, whoever did could point every installed copy at
// a build of their own. So the file is signed with a key that is not on the server (it stays on
// the PC that makes releases), and the app checks the signature against the public half below
// before it believes a word of it. A checksum from the same server would prove nothing.
//
// ECDSA on the P-256 curve with SHA-256, the signature in DER (what `openssl dgst -sha256 -sign`
// writes).

import 'dart:typed_data';

import 'package:pointycastle/export.dart' as pc;

/// The public half of the release key: an uncompressed P-256 point, in hex.
const updatePublicKey =
    '040e137dd4731029da56b8963caab9dcf29ff2f40b4a96702f20c1c8fa4656515359f133bca28dcc3887df9f8258240857dd543499f999c5548ad4653bd12cfd88';

Uint8List _hex(String s) => Uint8List.fromList([for (var i = 0; i + 1 < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);

BigInt _int(List<int> bytes) => bytes.fold(BigInt.zero, (v, b) => (v << 8) | BigInt.from(b));

/// The two numbers of a DER signature: SEQUENCE { INTEGER r, INTEGER s }. Null when it isn't one.
(BigInt, BigInt)? _der(Uint8List sig) {
  var i = 0;
  int? length() {
    if (i >= sig.length) return null;
    var n = sig[i++];
    if (n < 0x80) return n;
    final count = n & 0x7f;
    if (count == 0 || count > 2 || i + count > sig.length) return null;
    n = 0;
    for (var k = 0; k < count; k++) {
      n = (n << 8) | sig[i++];
    }
    return n;
  }

  BigInt? integer() {
    if (i >= sig.length || sig[i++] != 0x02) return null;
    final n = length();
    if (n == null || n == 0 || i + n > sig.length) return null;
    final v = _int(sig.sublist(i, i + n));
    i += n;
    return v;
  }

  if (sig.isEmpty || sig[i++] != 0x30) return null;
  final total = length();
  if (total == null || i + total != sig.length) return null;
  final r = integer(), s = integer();
  if (r == null || s == null || i != sig.length) return null;
  return (r, s);
}

/// Whether [signature] (DER) is the release key's signature of exactly [message].
bool updateSignatureIsValid(Uint8List message, Uint8List signature, {String publicKey = updatePublicKey}) {
  try {
    final rs = _der(signature);
    if (rs == null) return false;
    final params = pc.ECDomainParameters('prime256v1');
    final point = params.curve.decodePoint(_hex(publicKey));
    if (point == null) return false;
    final signer = pc.ECDSASigner(pc.SHA256Digest())..init(false, pc.PublicKeyParameter<pc.ECPublicKey>(pc.ECPublicKey(point, params)));
    return signer.verifySignature(message, pc.ECSignature(rs.$1, rs.$2));
  } catch (_) {
    return false;
  }
}

/// "1.2.10" against "1.2.9": above 0 when [a] is the newer. Anything after a "+" or "-" (a build
/// number, "beta") is left out; a missing part counts as 0.
int compareVersions(String a, String b) {
  List<int> parts(String v) => [for (final p in v.trim().split(RegExp(r'[+\-]')).first.split('.')) int.tryParse(p.trim()) ?? 0];
  final x = parts(a), y = parts(b);
  for (var i = 0; i < x.length || i < y.length; i++) {
    final c = (i < x.length ? x[i] : 0).compareTo(i < y.length ? y[i] : 0);
    if (c != 0) return c;
  }
  return 0;
}
