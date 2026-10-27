import 'dart:math';

/// 生成 ULID 形态的库 ID（26 位 Crockford Base32：48 位时间戳 + 80 位随机，
/// docs/05 §4.1）。sync_core 不引第三方 ULID 包，本地实现仅用于首次
/// ensureLayout 生成 `library.json.libraryId`。
String newUlid({Random? random, DateTime? now}) {
  const encoding = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  final rng = random ?? Random.secure();
  final ms = (now ?? DateTime.now().toUtc()).millisecondsSinceEpoch;

  var time = ms & 0xFFFFFFFFFFFF; // 48 位
  final chars = List<String>.filled(26, '0');
  for (var i = 9; i >= 0; i--) {
    chars[i] = encoding[time & 0x1F];
    time >>= 5;
  }
  for (var i = 10; i < 26; i++) {
    chars[i] = encoding[rng.nextInt(32)];
  }
  return chars.join();
}
