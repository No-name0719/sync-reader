/// 分组元数据模型单测（docs/05 §2.1 / §6 演进规则）。
library;

import 'dart:convert';

import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  group('GroupMeta 序列化', () {
    test('toJson 输出全部字段（含分组名与排序权重）', () {
      final group = buildGroup(
        groupId: groupIdOf(7),
        rev: 3,
        name: '小说',
        sortOrder: 12,
      );
      final json = group.toJson();
      expect(json['schemaVersion'], kGroupSchemaVersion);
      expect(json['groupId'], groupIdOf(7));
      expect(json['rev'], 3);
      expect(json['deviceId'], '01DEVA000000000000');
      expect(json['deviceName'], 'DeviceA');
      expect(json['name'], '小说');
      expect(json['sortOrder'], 12);
      expect(json['deleted'], isFalse);
      expect(json['deletedAt'], isNull);
      expect(json['createdAt'], isA<String>());
      expect(json['updatedAt'], isA<String>());
    });

    test('fromJson 往返一致（JSON 原文 → 对象 → JSON）', () {
      final group = buildGroup(groupId: groupIdOf(3), rev: 5, name: '长篇');
      final back = GroupMeta.fromJsonString(group.toJsonString());
      expect(back.groupId, group.groupId);
      expect(back.rev, group.rev);
      expect(back.name, group.name);
      expect(back.sortOrder, group.sortOrder);
      expect(back.createdAt, group.createdAt);
      expect(back.updatedAt, group.updatedAt);
      expect(back.deleted, isFalse);
    });

    test('未知字段容忍（读方只取已知键，不报错）', () {
      final raw = {
        ...buildGroup().toJson(),
        'futureField': {'a': 1},
        'anotherOne': [1, 2, 3],
      };
      final group = GroupMeta.fromJson(raw);
      expect(group.name, '小说');
      expect(group.sortOrder, 0);
    });

    test('必填字段缺失/类型错误抛 FormatException（严格校验）', () {
      final base = buildGroup().toJson();
      for (final key in const [
        'groupId',
        'rev',
        'deviceId',
        'deviceName',
        'createdAt',
        'updatedAt',
        'name',
        'sortOrder',
      ]) {
        final broken = Map<String, Object?>.of(base)..remove(key);
        expect(
          () => GroupMeta.fromJson(broken),
          throwsA(isA<FormatException>()),
          reason: '缺 $key 必须报错',
        );
      }
      final badRev = Map<String, Object?>.of(base)..['rev'] = 0;
      expect(() => GroupMeta.fromJson(badRev), throwsA(isA<FormatException>()));
    });

    test('墓碑形态：deleted=true + deletedAt，名称与排序保留', () {
      final group = buildGroup(name: '小说', sortOrder: 4);
      final tomb = group.toTombstone(
        deletedAt: t0.add(const Duration(hours: 2)),
        deviceId: '01DEVB000000000000',
        deviceName: 'DeviceB',
      );
      expect(tomb.isTombstone, isTrue);
      expect(tomb.deletedAt, t0.add(const Duration(hours: 2)));
      expect(tomb.rev, group.rev + 1);
      expect(tomb.name, '小说');
      expect(tomb.sortOrder, 4);
      final back = GroupMeta.fromJsonString(tomb.toJsonString());
      expect(back.isTombstone, isTrue);
      expect(back.deletedAt, tomb.deletedAt);
    });
  });

  group('定序（docs/04 §6.2 LWW）', () {
    test('rev 优先；rev 相同比 updatedAt；再相同比 deviceId', () {
      final a = buildGroup(rev: 1, updatedAt: t0);
      final b = buildGroup(rev: 2, updatedAt: t0);
      expect(a.compareTo(b), lessThan(0));

      final c = buildGroup(rev: 3, updatedAt: t0);
      final d = buildGroup(
        rev: 3,
        updatedAt: t0.add(const Duration(milliseconds: 1)),
      );
      expect(c.compareTo(d), lessThan(0));

      final e = buildGroup(rev: 3, deviceId: '01AAA000000000000');
      final f = buildGroup(rev: 3, deviceId: '01BBB000000000000');
      expect(e.compareTo(f), lessThan(0));
      expect(f.compareTo(e), greaterThan(0));
    });
  });

  group('书籍 meta 的分组字段（docs/05 §2.2）', () {
    test('toJson 输出 groupId；fromJson 缺失时为 null', () {
      final meta = buildMeta(bookId: bookIdOf(1), rev: 1);
      expect(meta.toJson()['groupId'], isNull);
      expect(meta.groupId, isNull);

      final withGroup = BookMeta(
        schemaVersion: meta.schemaVersion,
        bookId: meta.bookId,
        rev: meta.rev,
        deviceId: meta.deviceId,
        deviceName: meta.deviceName,
        createdAt: meta.createdAt,
        updatedAt: meta.updatedAt,
        book: meta.book,
        reading: meta.reading,
        groupId: groupIdOf(2),
      );
      final back = BookMeta.fromJsonString(withGroup.toJsonString());
      expect(back.groupId, groupIdOf(2));
    });

    test('旧客户端视角：meta JSON 无 groupId 键时解析为 null（不报错）', () {
      final json =
          jsonDecode(buildMeta().toJsonString()) as Map<String, Object?>;
      json.remove('groupId');
      final meta = BookMeta.fromJson(json.cast<String, Object?>());
      expect(meta.groupId, isNull);
    });
  });
}
