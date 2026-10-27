/// locator 编解码与位置换算数学（docs/05 §3.3 type=md）：
/// percent/charOffset ↔ blockIndex、标题序号双向映射、非法 locator 降级判定。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/contract/progress_anchor.dart';
import 'package:sync_reader/features/reader/formats/md/md_block_parser.dart';
import 'package:sync_reader/features/reader/formats/md/md_locator.dart';

void main() {
  // 文档：'# H0\np0\n## H1\np1\n' → 块：h@0[0,4)、p@1[5,7)、h@2[8,13)、p@3[14,16)。
  const source = '# H0\np0\n## H1\np1\n';
  final blocks = const MdBlockParser().parse(source);

  group('MdLocator 编解码', () {
    test('encode → JSON 字段齐全，tryDecode 往返一致', () {
      final json = MdLocator.encode(
        headingIndex: 1,
        blockIndex: 2,
        charOffset: 3,
      );
      expect(
        json,
        '{"type":"md","headingIndex":1,"blockIndex":2,"charOffset":3}',
      );
      final data = MdLocator.tryDecode(json)!;
      expect(data.headingIndex, 1);
      expect(data.blockIndex, 2);
      expect(data.charOffset, 3);
    });

    test('非法输入返回 null（JSON 损坏 / type 不符 / 字段缺失或非法）', () {
      expect(MdLocator.tryDecode('not-json{{'), isNull);
      expect(MdLocator.tryDecode('[]'), isNull);
      expect(MdLocator.tryDecode('null'), isNull);
      expect(
        MdLocator.tryDecode('{"type":"txt","chapterIndex":1,"charOffset":0}'),
        isNull,
      );
      expect(MdLocator.tryDecode('{"type":"md","headingIndex":0}'), isNull);
      expect(
        MdLocator.tryDecode(
          '{"type":"md","headingIndex":-1,"blockIndex":0,"charOffset":0}',
        ),
        isNull,
      );
      expect(
        MdLocator.tryDecode(
          '{"type":"md","headingIndex":1.5,"blockIndex":0,"charOffset":0}',
        ),
        isNull,
      );
      expect(MdLocator.tryDecode(null), isNull);
      expect(MdLocator.tryDecode(''), isNull);
    });

    test('无进度常量（空对象）解码为 null → 走降级/无进度分支', () {
      expect(MdLocator.tryDecode(ProgressAnchor.empty.locatorJson), isNull);
    });
  });

  group('MdPositionMath.blockIndexAtCharOffset', () {
    test('落在块内/块间空隙都归到最后一个 sourceStart ≤ 偏移的块', () {
      expect(MdPositionMath.blockIndexAtCharOffset(blocks, 0), 0);
      expect(MdPositionMath.blockIndexAtCharOffset(blocks, 3), 0);
      expect(MdPositionMath.blockIndexAtCharOffset(blocks, 4), 0); // 换行符处
      expect(MdPositionMath.blockIndexAtCharOffset(blocks, 5), 1);
      expect(MdPositionMath.blockIndexAtCharOffset(blocks, 8), 2);
      expect(MdPositionMath.blockIndexAtCharOffset(blocks, 999), 3);
    });

    test('空块列表 → -1', () {
      expect(MdPositionMath.blockIndexAtCharOffset(const [], 0), -1);
    });
  });

  group('MdPositionMath.blockIndexForPercent', () {
    test('percent → 最近块（percent = sourceStart/全文字符数 的反演）', () {
      const total = 17; // source.length
      expect(MdPositionMath.blockIndexForPercent(blocks, total, 0.0), 0);
      // 0.3 * 17 = 5.1 → round 5 → 块 1。
      expect(MdPositionMath.blockIndexForPercent(blocks, total, 0.3), 1);
      // 0.5 * 17 = 8.5 → round 9 → 块 2（第二个标题）。
      expect(MdPositionMath.blockIndexForPercent(blocks, total, 0.5), 2);
      // 1.0 → 钳位到最后一块。
      expect(MdPositionMath.blockIndexForPercent(blocks, total, 1.0), 3);
      // 越界 percent 钳位。
      expect(MdPositionMath.blockIndexForPercent(blocks, total, -2), 0);
      expect(MdPositionMath.blockIndexForPercent(blocks, total, 42), 3);
    });

    test('空块列表 / 零长度文档 → -1', () {
      expect(MdPositionMath.blockIndexForPercent(const [], 0, 0.5), -1);
    });
  });

  group('MdPositionMath 标题序号映射', () {
    test('headingIndexUpTo：可见块之前最近的标题（无标题 → 0 兜底）', () {
      expect(MdPositionMath.headingIndexUpTo(blocks, 0), 0); // h
      expect(MdPositionMath.headingIndexUpTo(blocks, 1), 0); // p → 上一标题
      expect(MdPositionMath.headingIndexUpTo(blocks, 2), 1); // h
      expect(MdPositionMath.headingIndexUpTo(blocks, 3), 1); // p
      final noHeading = const MdBlockParser().parse('只有段落。\n');
      expect(MdPositionMath.headingIndexUpTo(noHeading, 0), 0);
    });

    test('blockIndexForHeading：标题序号 → 块下标（不存在 → -1）', () {
      expect(MdPositionMath.blockIndexForHeading(blocks, 0), 0);
      expect(MdPositionMath.blockIndexForHeading(blocks, 1), 2);
      expect(MdPositionMath.blockIndexForHeading(blocks, 2), -1);
      expect(MdPositionMath.blockIndexForHeading(blocks, -1), -1);
    });
  });
}
