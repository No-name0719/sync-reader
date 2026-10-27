/// MdBlockParser 块解析表（FR-204）：覆盖 ATX/Setext 标题、围栏代码块内
/// `#`/`---` 不误判、表格、引用、列表嵌套/松散、hr 消歧、空文件、仅代码块、
/// 偏移数学（sourceStart/sourceEnd 与 substring 一致）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/formats/md/md_block_parser.dart';

void main() {
  const parser = MdBlockParser();

  List<MdBlock> parse(String source) => parser.parse(source);

  group('ATX 标题', () {
    test('#~###### 全级识别 + 文本剥离', () {
      final blocks = parse('# 一级\n## 二级\n###### 六级\n');
      expect(blocks, hasLength(3));
      expect(blocks.map((b) => b.type), everyElement(MdBlockType.heading));
      expect(blocks.map((b) => b.level), [1, 2, 6]);
      expect(blocks.map((b) => b.title), ['一级', '二级', '六级']);
    });

    test('空标题与纯 # 行', () {
      final blocks = parse('#\n## \n');
      expect(blocks, hasLength(2));
      expect(blocks.every((b) => b.type == MdBlockType.heading), isTrue);
      expect(blocks.every((b) => b.title.isEmpty), isTrue);
    });

    test('行尾 # 收尾剥离；紧贴 # 不剥离', () {
      expect(parse('## Title ##\n').single.title, 'Title');
      expect(parse('## Title# ##\n').single.title, 'Title#');
    });

    test('7 个 # 与无空格 # 不是标题（紧邻时合并为一个段落）', () {
      final blocks = parse('####### 七个\n#nospace\n');
      expect(blocks, hasLength(1));
      expect(blocks.single.type, MdBlockType.paragraph);
      // 空行分隔后各自成段。
      final separated = parse('####### 七个\n\n#nospace\n');
      expect(separated, hasLength(2));
      expect(separated.map((b) => b.type), everyElement(MdBlockType.paragraph));
    });

    test('缩进 ≤3 空格仍是标题', () {
      final blocks = parse('   # 缩进标题\n');
      expect(blocks.single.type, MdBlockType.heading);
      expect(blocks.single.title, '缩进标题');
    });
  });

  group('Setext 标题', () {
    test('=== 下划线 → 一级标题（吞并紧贴段落）', () {
      final source = 'Title line\n===\n';
      final blocks = parse(source);
      expect(blocks, hasLength(1));
      expect(blocks.single.type, MdBlockType.heading);
      expect(blocks.single.level, 1);
      expect(blocks.single.title, 'Title line');
      expect(
        source.substring(blocks.single.sourceStart, blocks.single.sourceEnd),
        'Title line\n===',
      );
    });

    test('--- 下划线紧跟段落 → 二级标题（非 hr）', () {
      final blocks = parse('Another\n---\n');
      expect(blocks, hasLength(1));
      expect(blocks.single.type, MdBlockType.heading);
      expect(blocks.single.level, 2);
      expect(blocks.single.title, 'Another');
    });

    test('多行段落 + === → 标题文本为各行合并', () {
      final blocks = parse('line1\nline2\n===\n');
      expect(blocks.single.type, MdBlockType.heading);
      expect(blocks.single.title, 'line1 line2');
    });

    test('无段落紧贴时 --- 是 hr、=== 是段落', () {
      final blocks = parse('---\n\n===\n');
      expect(blocks[0].type, MdBlockType.hr);
      expect(blocks[1].type, MdBlockType.paragraph);
    });
  });

  group('围栏代码块（修复基线缺陷：内部 # 与 --- 不误判）', () {
    test('``` 围栏内 # 行与 --- 行均为代码内容', () {
      final source = '# Head\n```\n# 不是标题\n---\n```\ntail\n';
      final blocks = parse(source);
      expect(blocks.map((b) => b.type).toList(), [
        MdBlockType.heading,
        MdBlockType.codeBlock,
        MdBlockType.paragraph,
      ]);
      expect(blocks[0].title, 'Head');
      expect(blocks[1].content, '```\n# 不是标题\n---\n```');
      expect(
        source.substring(blocks[1].sourceStart, blocks[1].sourceEnd),
        blocks[1].content,
      );
    });

    test('~~~ 围栏 + 内部 ``` 行不提前闭合', () {
      final blocks = parse('~~~\n```nested\n~~~\n');
      expect(blocks, hasLength(1));
      expect(blocks.single.type, MdBlockType.codeBlock);
    });

    test('闭合围栏长度须 ≥ 开行长度', () {
      final blocks = parse('````\na\n```\n````\n');
      // 开行 4 个反引号，``` 不足以闭合，```` 才闭合 → 一个代码块。
      expect(blocks, hasLength(1));
      expect(blocks.single.type, MdBlockType.codeBlock);
    });

    test('未闭合围栏吞到文末', () {
      final blocks = parse('```info\ncode line\n');
      expect(blocks, hasLength(1));
      expect(blocks.single.type, MdBlockType.codeBlock);
    });

    test('仅代码块文档', () {
      final blocks = parse('```\ncode\n```\n');
      expect(blocks, hasLength(1));
      expect(blocks.single.type, MdBlockType.codeBlock);
    });
  });

  group('表格', () {
    test('带首尾竖线的标准表格', () {
      final source = '| a | b |\n| --- | --- |\n| 1 | 2 |\n\nafter\n';
      final blocks = parse(source);
      expect(blocks, hasLength(2));
      expect(blocks[0].type, MdBlockType.table);
      expect(blocks[0].content, '| a | b |\n| --- | --- |\n| 1 | 2 |');
      expect(blocks[1].type, MdBlockType.paragraph);
    });

    test('无首尾竖线 + 对齐冒号定界行', () {
      final blocks = parse('a | b\n:--- | ---:\n1 | 2\n');
      expect(blocks.single.type, MdBlockType.table);
    });

    test('表格优先于 Setext（表头 + 定界行紧贴段落）', () {
      final blocks = parse('前文\na | b\n--- | ---\n');
      expect(blocks.map((b) => b.type).toList(), [
        MdBlockType.paragraph,
        MdBlockType.table,
      ]);
    });

    test('缺定界行则只是段落', () {
      final blocks = parse('a | b\nnot delim\n');
      expect(blocks.single.type, MdBlockType.paragraph);
    });

    test('围栏内的 | 定界行不是表格', () {
      final blocks = parse('```\n| a |\n| --- |\n```\n');
      expect(blocks.single.type, MdBlockType.codeBlock);
    });
  });

  group('引用块', () {
    test('连续 > 行归并为一个块', () {
      final source = '> line1\n> line2\n> > nested\nafter\n';
      final blocks = parse(source);
      expect(blocks, hasLength(2));
      expect(blocks[0].type, MdBlockType.quote);
      expect(blocks[0].content, '> line1\n> line2\n> > nested');
      expect(blocks[1].type, MdBlockType.paragraph);
    });

    test('空行终止引用', () {
      final blocks = parse('> q1\n\n> q2\n');
      expect(blocks.map((b) => b.type), everyElement(MdBlockType.quote));
      expect(blocks, hasLength(2));
    });
  });

  group('列表', () {
    test('无序 + 嵌套缩进归并为一个块', () {
      final source = '- a\n- b\n  - b1\n    续行\n';
      final blocks = parse(source);
      expect(blocks, hasLength(1));
      expect(blocks.single.type, MdBlockType.list);
      expect(
        source.substring(blocks.single.sourceStart, blocks.single.sourceEnd),
        source.trimRight(),
      );
    });

    test('有序列表', () {
      final blocks = parse('1. one\n2) two\n');
      expect(blocks.single.type, MdBlockType.list);
    });

    test('松散列表（空行分隔）归并为一个块且保留空行', () {
      final blocks = parse('- a\n\n- b\n');
      expect(blocks, hasLength(1));
      expect(blocks.single.type, MdBlockType.list);
      expect(blocks.single.content, '- a\n\n- b');
    });

    test('非列表内容终止列表', () {
      final blocks = parse('- a\ntext\n');
      expect(blocks.map((b) => b.type).toList(), [
        MdBlockType.list,
        MdBlockType.paragraph,
      ]);
    });

    test('- - - 是 hr 不是列表', () {
      final blocks = parse('- - -\n');
      expect(blocks.single.type, MdBlockType.hr);
    });
  });

  group('hr 消歧', () {
    test('*** / ___ / * * * 是 hr', () {
      final blocks = parse('***\n\n___\n\n* * *\n');
      expect(blocks, hasLength(3));
      expect(blocks.map((b) => b.type), everyElement(MdBlockType.hr));
    });

    test('*** 打断段落', () {
      final blocks = parse('text\n***\n');
      expect(blocks.map((b) => b.type).toList(), [
        MdBlockType.paragraph,
        MdBlockType.hr,
      ]);
    });

    test('非分隔线形态的斜星行是段落', () {
      final blocks = parse('***bold***\n');
      expect(blocks.single.type, MdBlockType.paragraph);
    });
  });

  group('图片与段落', () {
    test('独占一行图片 → image 块并提取 alt', () {
      final blocks = parse('![封面图](./img/cover.png)\n');
      expect(blocks.single.type, MdBlockType.image);
      expect(blocks.single.title, '封面图');
    });

    test('一行多图/图文混排仍是段落', () {
      final blocks = parse('![a](a.png) 文字 ![b](b.png)\n');
      expect(blocks.single.type, MdBlockType.paragraph);
    });

    test('多行段落合并，保留原始换行', () {
      final source = '第一行\n第二行\n';
      final blocks = parse(source);
      expect(blocks.single.type, MdBlockType.paragraph);
      expect(blocks.single.content, '第一行\n第二行');
    });
  });

  group('空输入与偏移数学', () {
    test('空文件与纯空白文件 → 空块列表', () {
      expect(parse(''), isEmpty);
      expect(parse('\n\n  \n\t\n'), isEmpty);
    });

    test('sourceStart/sourceEnd 与源文本 substring 一致（含 CRLF）', () {
      const source = '# T\r\nbody\r\n';
      final blocks = parse(source);
      expect(blocks, hasLength(2));
      expect(
        source.substring(blocks[0].sourceStart, blocks[0].sourceEnd),
        '# T',
      );
      expect(
        source.substring(blocks[1].sourceStart, blocks[1].sourceEnd),
        'body',
      );
      expect(blocks[0].sourceStart, 0);
      expect(blocks[1].sourceStart, 5);
    });

    test('块序列按文档顺序且 sourceStart 单调不减', () {
      final blocks = parse('# a\n\np\n\n```\n# b\n```\n\n## c\n');
      var last = -1;
      for (final b in blocks) {
        expect(b.sourceStart, greaterThanOrEqualTo(last));
        expect(b.sourceEnd, greaterThan(b.sourceStart));
        last = b.sourceStart;
      }
      // 围栏内的 # b 不是标题，全文标题只有 a 与 c。
      expect(
        blocks.where((b) => b.type == MdBlockType.heading).map((b) => b.title),
        ['a', 'c'],
      );
    });
  });
}
