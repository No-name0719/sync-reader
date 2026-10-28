/// ReaderSettings 音量键翻页字段（FR-209）序列化契约：默认 false、
/// JSON roundtrip、旧 JSON（无该键）向后兼容回落默认。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';

void main() {
  test('volumeKeyPageTurn 默认 false（出厂默认不开音量键翻页）', () {
    expect(ReaderSettings.defaults.volumeKeyPageTurn, isFalse);
  });

  test('toJson/fromJson roundtrip 保留 volumeKeyPageTurn', () {
    const settings = ReaderSettings(volumeKeyPageTurn: true);
    final restored = ReaderSettings.fromJson(settings.toJson());
    expect(restored, settings);
    expect(restored.volumeKeyPageTurn, isTrue);
  });

  test('旧 JSON（无 volumeKeyPageTurn 键）回落默认 false（向后兼容）', () {
    final legacy = ReaderSettings.fromJson({
      'fontSize': 20,
      'pageMode': 'page',
    });
    expect(legacy.fontSize, 20);
    expect(legacy.pageMode, ReaderPageMode.page);
    expect(legacy.volumeKeyPageTurn, isFalse);
  });

  test('copyWith 覆盖该字段，并参与 ==/hashCode', () {
    final on = ReaderSettings.defaults.copyWith(volumeKeyPageTurn: true);
    expect(on.volumeKeyPageTurn, isTrue);
    expect(on, isNot(ReaderSettings.defaults));
    expect(on.hashCode, isNot(ReaderSettings.defaults.hashCode));
    expect(on, ReaderSettings.defaults.copyWith(volumeKeyPageTurn: true));
  });
}
