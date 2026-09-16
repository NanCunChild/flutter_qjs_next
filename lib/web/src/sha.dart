part of '../web_apis.dart';

/// SHA-1 / SHA-2 and HMAC for `crypto.subtle`.
///
/// Implemented in Dart so the native library stays small and hashing does not
/// run on the JS heap. Verified against the FIPS test vectors in
/// `example/test/web_apis_crypto_test.dart`.
class _Sha {
  static const _blockSize = {
    'SHA-1': 64,
    'SHA-256': 64,
    'SHA-384': 128,
    'SHA-512': 128,
  };

  static Uint8List digest(String algorithm, Uint8List data) {
    switch (algorithm) {
      case 'SHA-1':
        return _sha1(data);
      case 'SHA-256':
        return _sha256(data);
      case 'SHA-384':
        return _sha512(data, sha384: true);
      case 'SHA-512':
        return _sha512(data);
      default:
        throw ArgumentError('Unsupported digest algorithm: $algorithm');
    }
  }

  /// RFC 2104 HMAC.
  static Uint8List hmac(String algorithm, Uint8List key, Uint8List data) {
    final blockSize = _blockSize[algorithm];
    if (blockSize == null) {
      throw ArgumentError('Unsupported HMAC hash: $algorithm');
    }
    var block = key.length > blockSize ? digest(algorithm, key) : key;
    final padded = Uint8List(blockSize)..setRange(0, block.length, block);
    final inner = Uint8List(blockSize + data.length);
    final outer = Uint8List(blockSize);
    for (var i = 0; i < blockSize; i++) {
      inner[i] = padded[i] ^ 0x36;
      outer[i] = padded[i] ^ 0x5c;
    }
    inner.setRange(blockSize, inner.length, data);
    final innerDigest = digest(algorithm, inner);
    final combined = Uint8List(blockSize + innerDigest.length)
      ..setRange(0, blockSize, outer)
      ..setRange(blockSize, blockSize + innerDigest.length, innerDigest);
    return digest(algorithm, combined);
  }

  /// Message padding shared by SHA-1 and SHA-256 (64-byte blocks).
  static Uint8List _pad64(Uint8List data) {
    final bitLength = data.length * 8;
    final padded = Uint8List(((data.length + 9 + 63) ~/ 64) * 64)
      ..setRange(0, data.length, data);
    padded[data.length] = 0x80;
    for (var i = 0; i < 8; i++) {
      padded[padded.length - 1 - i] = (bitLength >>> (8 * i)) & 0xff;
    }
    return padded;
  }

  static int _rotl32(int value, int bits) =>
      ((value << bits) | (value >>> (32 - bits))) & 0xffffffff;

  static Uint8List _sha1(Uint8List data) {
    final blocks = _pad64(data);
    var h0 = 0x67452301;
    var h1 = 0xEFCDAB89;
    var h2 = 0x98BADCFE;
    var h3 = 0x10325476;
    var h4 = 0xC3D2E1F0;
    final w = Int32List(80);
    for (var offset = 0; offset < blocks.length; offset += 64) {
      for (var i = 0; i < 16; i++) {
        final j = offset + i * 4;
        w[i] =
            (blocks[j] << 24) |
            (blocks[j + 1] << 16) |
            (blocks[j + 2] << 8) |
            blocks[j + 3];
      }
      for (var i = 16; i < 80; i++) {
        w[i] = _rotl32((w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]) & 0xffffffff, 1);
      }
      var a = h0, b = h1, c = h2, d = h3, e = h4;
      for (var i = 0; i < 80; i++) {
        final int f;
        final int k;
        if (i < 20) {
          f = (b & c) | (~b & d);
          k = 0x5A827999;
        } else if (i < 40) {
          f = b ^ c ^ d;
          k = 0x6ED9EBA1;
        } else if (i < 60) {
          f = (b & c) | (b & d) | (c & d);
          k = 0x8F1BBCDC;
        } else {
          f = b ^ c ^ d;
          k = 0xCA62C1D6;
        }
        final temp =
            (_rotl32(a, 5) + (f & 0xffffffff) + e + k + (w[i] & 0xffffffff)) &
            0xffffffff;
        e = d;
        d = c;
        c = _rotl32(b, 30);
        b = a;
        a = temp;
      }
      h0 = (h0 + a) & 0xffffffff;
      h1 = (h1 + b) & 0xffffffff;
      h2 = (h2 + c) & 0xffffffff;
      h3 = (h3 + d) & 0xffffffff;
      h4 = (h4 + e) & 0xffffffff;
    }
    return _words32([h0, h1, h2, h3, h4]);
  }

  static const _k256 = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  static Uint8List _sha256(Uint8List data) {
    final blocks = _pad64(data);
    final h = [
      0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
      0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ];
    final w = Int32List(64);
    for (var offset = 0; offset < blocks.length; offset += 64) {
      for (var i = 0; i < 16; i++) {
        final j = offset + i * 4;
        w[i] =
            (blocks[j] << 24) |
            (blocks[j + 1] << 16) |
            (blocks[j + 2] << 8) |
            blocks[j + 3];
      }
      for (var i = 16; i < 64; i++) {
        final x = w[i - 15] & 0xffffffff;
        final y = w[i - 2] & 0xffffffff;
        final s0 = _rotr32(x, 7) ^ _rotr32(x, 18) ^ (x >>> 3);
        final s1 = _rotr32(y, 17) ^ _rotr32(y, 19) ^ (y >>> 10);
        w[i] =
            ((w[i - 16] & 0xffffffff) +
                s0 +
                (w[i - 7] & 0xffffffff) +
                s1) &
            0xffffffff;
      }
      var a = h[0], b = h[1], c = h[2], d = h[3];
      var e = h[4], f = h[5], g = h[6], hh = h[7];
      for (var i = 0; i < 64; i++) {
        final s1 = _rotr32(e, 6) ^ _rotr32(e, 11) ^ _rotr32(e, 25);
        final ch = (e & f) ^ (~e & g);
        final temp1 =
            (hh + s1 + (ch & 0xffffffff) + _k256[i] + (w[i] & 0xffffffff)) &
            0xffffffff;
        final s0 = _rotr32(a, 2) ^ _rotr32(a, 13) ^ _rotr32(a, 22);
        final maj = (a & b) ^ (a & c) ^ (b & c);
        final temp2 = (s0 + (maj & 0xffffffff)) & 0xffffffff;
        hh = g;
        g = f;
        f = e;
        e = (d + temp1) & 0xffffffff;
        d = c;
        c = b;
        b = a;
        a = (temp1 + temp2) & 0xffffffff;
      }
      final next = [a, b, c, d, e, f, g, hh];
      for (var i = 0; i < 8; i++) {
        h[i] = (h[i] + next[i]) & 0xffffffff;
      }
    }
    return _words32(h);
  }

  static int _rotr32(int value, int bits) =>
      ((value >>> bits) | (value << (32 - bits))) & 0xffffffff;

  static Uint8List _words32(List<int> words) {
    final out = Uint8List(words.length * 4);
    for (var i = 0; i < words.length; i++) {
      out[i * 4] = (words[i] >>> 24) & 0xff;
      out[i * 4 + 1] = (words[i] >>> 16) & 0xff;
      out[i * 4 + 2] = (words[i] >>> 8) & 0xff;
      out[i * 4 + 3] = words[i] & 0xff;
    }
    return out;
  }

  static const _k512 = [
    0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f,
    0xe9b5dba58189dbbc, 0x3956c25bf348b538, 0x59f111f1b605d019,
    0x923f82a4af194f9b, 0xab1c5ed5da6d8118, 0xd807aa98a3030242,
    0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2,
    0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235,
    0xc19bf174cf692694, 0xe49b69c19ef14ad2, 0xefbe4786384f25e3,
    0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65, 0x2de92c6f592b0275,
    0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5,
    0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f,
    0xbf597fc7beef0ee4, 0xc6e00bf33da88fc2, 0xd5a79147930aa725,
    0x06ca6351e003826f, 0x142929670a0e6e70, 0x27b70a8546d22ffc,
    0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df,
    0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6,
    0x92722c851482353b, 0xa2bfe8a14cf10364, 0xa81a664bbc423001,
    0xc24b8b70d0f89791, 0xc76c51a30654be30, 0xd192e819d6ef5218,
    0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8,
    0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99,
    0x34b0bcb5e19b48a8, 0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb,
    0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3, 0x748f82ee5defb2fc,
    0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
    0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915,
    0xc67178f2e372532b, 0xca273eceea26619c, 0xd186b8c721c0c207,
    0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178, 0x06f067aa72176fba,
    0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b,
    0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc,
    0x431d67c49c100d4c, 0x4cc5d4becb3e42b6, 0x597f299cfc657e2a,
    0x5fcb6fab3ad6faec, 0x6c44198c4a475817,
  ];

  static int _rotr64(int value, int bits) =>
      (value >>> bits) | (value << (64 - bits));

  static Uint8List _sha512(Uint8List data, {bool sha384 = false}) {
    // 128-byte blocks with a 128-bit length field (the high 64 bits are always
    // zero for inputs this runtime can hold).
    final bitLength = data.length * 8;
    final blocks = Uint8List(((data.length + 17 + 127) ~/ 128) * 128)
      ..setRange(0, data.length, data);
    blocks[data.length] = 0x80;
    for (var i = 0; i < 8; i++) {
      blocks[blocks.length - 1 - i] = (bitLength >>> (8 * i)) & 0xff;
    }
    final h = sha384
        ? <int>[
            0xcbbb9d5dc1059ed8, 0x629a292a367cd507, 0x9159015a3070dd17,
            0x152fecd8f70e5939, 0x67332667ffc00b31, 0x8eb44a8768581511,
            0xdb0c2e0d64f98fa7, 0x47b5481dbefa4fa4,
          ]
        : <int>[
            0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b,
            0xa54ff53a5f1d36f1, 0x510e527fade682d1, 0x9b05688c2b3e6c1f,
            0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
          ];
    final w = Int64List(80);
    for (var offset = 0; offset < blocks.length; offset += 128) {
      for (var i = 0; i < 16; i++) {
        final j = offset + i * 8;
        var value = 0;
        for (var k = 0; k < 8; k++) {
          value = (value << 8) | blocks[j + k];
        }
        w[i] = value;
      }
      for (var i = 16; i < 80; i++) {
        final x = w[i - 15];
        final y = w[i - 2];
        final s0 = _rotr64(x, 1) ^ _rotr64(x, 8) ^ (x >>> 7);
        final s1 = _rotr64(y, 19) ^ _rotr64(y, 61) ^ (y >>> 6);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
      }
      var a = h[0], b = h[1], c = h[2], d = h[3];
      var e = h[4], f = h[5], g = h[6], hh = h[7];
      for (var i = 0; i < 80; i++) {
        final s1 = _rotr64(e, 14) ^ _rotr64(e, 18) ^ _rotr64(e, 41);
        final ch = (e & f) ^ (~e & g);
        final temp1 = hh + s1 + ch + _k512[i] + w[i];
        final s0 = _rotr64(a, 28) ^ _rotr64(a, 34) ^ _rotr64(a, 39);
        final maj = (a & b) ^ (a & c) ^ (b & c);
        final temp2 = s0 + maj;
        hh = g;
        g = f;
        f = e;
        e = d + temp1;
        d = c;
        c = b;
        b = a;
        a = temp1 + temp2;
      }
      final next = [a, b, c, d, e, f, g, hh];
      for (var i = 0; i < 8; i++) {
        h[i] = h[i] + next[i];
      }
    }
    final out = Uint8List(h.length * 8);
    for (var i = 0; i < h.length; i++) {
      for (var k = 0; k < 8; k++) {
        out[i * 8 + k] = (h[i] >>> (56 - 8 * k)) & 0xff;
      }
    }
    return sha384 ? Uint8List.sublistView(out, 0, 48) : out;
  }
}
