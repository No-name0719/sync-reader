import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

/// docs/05 §2 的完整示例（字段值有精简）。
Map<String, Object?> sampleMetaJson() => {
  'schemaVersion': 1,
  'bookId': '01JBGX4A2N6P8R0T2V4X6Z8B1D',
  'rev': 42,
  'deviceId': '01JBGX3Z5W8M9Q2V7K4T6R8Y0C',
  'deviceName': 'Pixel 7',
  'createdAt': '2026-10-26T08:00:00.000Z',
  'updatedAt': '2026-10-26T21:30:15.123Z',
  'deleted': false,
  'deletedAt': null,
  'dedupOf': null,
  'book': {
    'title': '三体',
    'author': '刘慈欣',
    'format': 'epub',
    'fileName': '三体.epub',
    'contentHash': 'sha256:9f2c',
    'sizeBytes': 2384123,
    'language': 'zh',
    'coverHash': 'sha256:77ab',
    'tocFingerprint': 'tfp:4b1e',
  },
  'progress': {
    'locator': {
      'type': 'epub',
      'spineIndex': 12,
      'href': 'OEBPS/ch05.xhtml',
      'blockIndex': 87,
      'charOffset': 1204,
    },
    'percent': 0.4127,
    'updatedAt': '2026-10-26T21:30:15.123Z',
  },
  'reading': {'totalSeconds': 128730, 'lastReadAt': '2026-10-26T21:30:15.123Z'},
  'annotations': <Object?>[],
  'extra': <String, Object?>{},
};

void main() {
  group('BookMeta JSON 往返', () {
    test('fromJson → toJson 与输入一致', () {
      final json = sampleMetaJson();
      final meta = BookMeta.fromJson(json);
      expect(meta.book.title, '三体');
      expect(meta.progress?.locator, isA<EpubLocator>());

      final roundTrip = meta.toJson();
      expect(roundTrip['schemaVersion'], 1);
      expect(roundTrip['bookId'], json['bookId']);
      expect(roundTrip['rev'], 42);
      expect((roundTrip['book'] as Map)['contentHash'], 'sha256:9f2c');
      expect((roundTrip['progress'] as Map)['percent'], 0.4127);
    });

    test('时间字段统一输出为 UTC ISO-8601', () {
      final meta = BookMeta.fromJson(sampleMetaJson());
      expect(
        meta.updatedAt.toUtc().toIso8601String(),
        '2026-10-26T21:30:15.123Z',
      );
    });
  });

  group('BookMeta 严格校验（docs/05 §6：失败标记 Corruption 并跳过）', () {
    test('缺少必填字段抛 FormatException', () {
      final json = sampleMetaJson()..remove('bookId');
      expect(() => BookMeta.fromJson(json), throwsFormatException);
    });

    test('rev < 1 抛 FormatException', () {
      final json = sampleMetaJson();
      (json['book'] as Map)['contentHash'] = 'sha256:9f2c';
      json['rev'] = 0;
      expect(() => BookMeta.fromJson(json), throwsFormatException);
    });

    test('progress.percent 越界抛 FormatException（不变式 4）', () {
      final json = sampleMetaJson();
      (json['progress'] as Map)['percent'] = 1.5;
      expect(() => BookMeta.fromJson(json), throwsFormatException);
    });
  });

  group('向前兼容（docs/05 §6：读方容忍未知字段、写回保留 schemaVersion）', () {
    test('未知顶层字段不报错（仅忽略）', () {
      final json = sampleMetaJson()..['futureField'] = {'any': 1};
      final meta = BookMeta.fromJson(json);
      expect(meta.bookId, isNotEmpty);
    });

    test('未知 locator.type 降级为 RawLocator（docs/02 §D2.5）', () {
      final json = sampleMetaJson();
      (json['progress'] as Map)['locator'] = {'type': 'mobi', 'pos': 7};
      final meta = BookMeta.fromJson(json);
      expect(meta.progress?.locator, isA<RawLocator>());
    });
  });

  group('LWW 冲突定序（docs/04 §6.2：rev → updatedAt → deviceId）', () {
    BookMeta meta({int rev = 1, String? updatedAt, String deviceId = 'A'}) {
      final json = sampleMetaJson()
        ..['rev'] = rev
        ..['deviceId'] = deviceId;
      if (updatedAt != null) json['updatedAt'] = updatedAt;
      return BookMeta.fromJson(json);
    }

    test('rev 大者胜', () {
      expect(meta(rev: 2).compareTo(meta(rev: 1)), greaterThan(0));
    });

    test('rev 相同比 updatedAt', () {
      final older = meta(rev: 3, updatedAt: '2026-10-26T10:00:00.000Z');
      final newer = meta(rev: 3, updatedAt: '2026-10-26T11:00:00.000Z');
      expect(newer.compareTo(older), greaterThan(0));
    });

    test('rev、updatedAt 均同比 deviceId 字典序', () {
      final a = meta(rev: 3, deviceId: 'A', updatedAt: '2026-10-26T10:00:00Z');
      final b = meta(rev: 3, deviceId: 'B', updatedAt: '2026-10-26T10:00:00Z');
      expect(b.compareTo(a), greaterThan(0));
    });
  });

  group('tombstone（docs/05 §2 / docs/04 §7）', () {
    test('toTombstone 保留 book 供游离文件重关联，rev 递增', () {
      final meta = BookMeta.fromJson(sampleMetaJson());
      final tomb = meta.toTombstone(
        deletedAt: DateTime.utc(2026, 10, 26),
        deviceId: '01JBGX3Z5W8M9Q2V7K4T6R8Y0C',
        deviceName: 'Pixel 7',
      );
      expect(tomb.deleted, isTrue);
      expect(tomb.deletedAt, DateTime.utc(2026, 10, 26));
      expect(tomb.rev, meta.rev + 1);
      expect(tomb.book.title, meta.book.title, reason: 'tombstone 保留 book');
    });
  });
}
