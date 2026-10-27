/// 章节切分规则表测试（FR-202）：中文数字章回 / 阿拉伯数字 / 序章楔子类 /
/// 行首数字编号 / 空白变体 / 无章节 / 空文件 / 代码式伪行不误切 / 区间不变量。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_chapter_splitter.dart';

void main() {
  group('ruleIdForLine 规则表逐条', () {
    test('章回式：中文数字 + 各后缀字', () {
      for (final line in [
        '第一章 起始',
        '第一回 甄士隐',
        '第二节 议论',
        '第十二卷 江湖',
        '第三部 风起',
        '第四篇 观澜',
        '第五章 集市',
        '第一百二十三章 风云突变',
        '第一千零一章 大结局',
      ]) {
        expect(
          TxtChapterSplitter.ruleIdForLine(line),
          'chapterHeading',
          reason: line,
        );
      }
    });

    test('章回式：阿拉伯数字', () {
      expect(TxtChapterSplitter.ruleIdForLine('第1章 开端'), 'chapterHeading');
      expect(TxtChapterSplitter.ruleIdForLine('第1234章 大战'), 'chapterHeading');
    });

    test('章回式：空白变体', () {
      expect(TxtChapterSplitter.ruleIdForLine('第 一 章 起步'), 'chapterHeading');
      expect(TxtChapterSplitter.ruleIdForLine('　第12章　全角空白'), 'chapterHeading');
      expect(TxtChapterSplitter.ruleIdForLine('  第三章 缩进'), 'chapterHeading');
    });

    test('特殊章题：序章/楔子/引子/前言/尾声/后记/番外', () {
      for (final line in [
        '序章',
        '楔子',
        '引子',
        '前言',
        '尾声',
        '后记',
        '番外',
        '番外一',
        '番外12',
        '尾声：多年以后',
        '序章 风起云涌',
      ]) {
        expect(
          TxtChapterSplitter.ruleIdForLine(line),
          'specialHeading',
          reason: line,
        );
      }
    });

    test('行首独立数字编号：顿号/点/冒号 + 标题', () {
      expect(TxtChapterSplitter.ruleIdForLine('一、初见'), 'numericHeading');
      expect(TxtChapterSplitter.ruleIdForLine('12. 风云'), 'numericHeading');
      expect(TxtChapterSplitter.ruleIdForLine('3、再会'), 'numericHeading');
      expect(TxtChapterSplitter.ruleIdForLine('七：归途'), 'numericHeading');
    });

    test('误切防护：普通叙述行', () {
      expect(TxtChapterSplitter.ruleIdForLine('第二天，他们出发了。'), isNull);
      expect(
        TxtChapterSplitter.ruleIdForLine('第十九个年头的冬天格外冷，大家都在等待。'),
        isNull,
        reason: '行首"第十九个…"非章回后缀字，且长行不命中',
      );
    });

    test('误切防护：小数 / IP / 数据行', () {
      expect(
        TxtChapterSplitter.ruleIdForLine('3.14 是圆周率'),
        isNull,
        reason: '分隔符后紧跟数字 → 小数',
      );
      expect(TxtChapterSplitter.ruleIdForLine('127.0.0.1 本机地址'), isNull);
      expect(TxtChapterSplitter.ruleIdForLine('1,000 元'), isNull);
      expect(TxtChapterSplitter.ruleIdForLine('12'), isNull, reason: '裸数字行不切');
    });

    test('误切防护：代码式伪行', () {
      expect(
        TxtChapterSplitter.ruleIdForLine('1. x = 1;'),
        isNull,
        reason: '含代码标点',
      );
      expect(
        TxtChapterSplitter.ruleIdForLine('2. #include <stdio.h>'),
        isNull,
        reason: '含尖括号',
      );
      expect(TxtChapterSplitter.ruleIdForLine('int x = 1;'), isNull);
      expect(TxtChapterSplitter.ruleIdForLine('return 2;'), isNull);
    });

    test('误切防护：特殊词后随普通正文（无分隔符）', () {
      expect(
        TxtChapterSplitter.ruleIdForLine('前言不搭后语的一句话很长很长很长很长很长很长很长很长'),
        isNull,
      );
    });
  });

  group('split() 切分行为', () {
    test('中文数字章回 + 阿拉伯数字混合切分，偏移=行首', () {
      const text =
          '第一章 开端\n'
          '这是第一章的内容。\n'
          '第二十二章 转折\n'
          '这是第二十二章的内容。\n'
          '第100章 终局\n'
          '全书完。\n';
      final chapters = TxtChapterSplitter.split(text);
      expect(chapters, hasLength(3));
      expect(chapters[0].title, '第一章 开端');
      expect(chapters[1].title, '第二十二章 转折');
      expect(chapters[2].title, '第100章 终局');
      expect(chapters[0].startOffset, 0);
      expect(chapters[1].startOffset, text.indexOf('第二十二章'));
      expect(chapters[2].startOffset, text.indexOf('第100章'));
    });

    test('首章前有正文 → 生成"开篇"章且覆盖到首个命中行', () {
      const text = '这里是楔子之前的散落文字。\n第一章 开始\n内容';
      final chapters = TxtChapterSplitter.split(text);
      expect(chapters, hasLength(2));
      expect(chapters[0].title, TxtChapterSplitter.preambleChapterTitle);
      expect(chapters[0].startOffset, 0);
      expect(chapters[0].endOffset, text.indexOf('第一章'));
      expect(chapters[1].startOffset, text.indexOf('第一章'));
    });

    test('无任何命中 → 单章全文', () {
      const text = '没有章节标记的一段文字。\n再来一段。\n';
      final chapters = TxtChapterSplitter.split(text);
      expect(chapters, hasLength(1));
      expect(chapters[0].title, TxtChapterSplitter.singleChapterTitle);
      expect(chapters[0].startOffset, 0);
      expect(chapters[0].endOffset, text.length);
    });

    test('空文件 → 单章空区间，不抛异常', () {
      final chapters = TxtChapterSplitter.split('');
      expect(chapters, hasLength(1));
      expect(chapters[0].startOffset, 0);
      expect(chapters[0].endOffset, 0);
    });

    test('代码式伪行整段不误切（单章）', () {
      const text = '''
1. x = 1;
2. #include <stdio.h>
int main() {
  return 2;
}
3.14 是圆周率
127.0.0.1 localhost
''';
      final chapters = TxtChapterSplitter.split(text);
      expect(chapters, hasLength(1), reason: '代码文本不应产生章节');
    });

    test('CRLF 行尾：命中不受 \\r 影响，章题不含 \\r', () {
      const text = '第一章 开端\r\n内容A\r\n第二章 继续\r\n内容B\r\n';
      final chapters = TxtChapterSplitter.split(text);
      expect(chapters, hasLength(2));
      expect(chapters[0].title, '第一章 开端');
      expect(chapters[1].title, '第二章 继续');
      expect(chapters[1].startOffset, text.indexOf('第二章'));
    });

    test('区间不变量：相接 / 覆盖 / 升序', () {
      const text = '楔子\n短内容\n第一章 一\n内容一\n第二章 二\n内容二\n尾声\n完\n';
      final chapters = TxtChapterSplitter.split(text);
      expect(chapters.first.startOffset, 0);
      expect(chapters.last.endOffset, text.length);
      for (var i = 0; i < chapters.length - 1; i++) {
        expect(
          chapters[i].endOffset,
          chapters[i + 1].startOffset,
          reason: '第$i章',
        );
        expect(chapters[i].startOffset, lessThan(chapters[i].endOffset));
      }
    });

    test('章题限长', () {
      // 尾长恰在 48 上限内命中，但"章号 + 尾巴"总长 55 > 50 → 截断到限长。
      final text = '第一百二十三章 ${'长' * 47}\n正文\n';
      final chapters = TxtChapterSplitter.split(text);
      expect(chapters, hasLength(1));
      expect(chapters[0].title.length, TxtChapterSplitter.maxTitleLength);
      expect(chapters[0].title, startsWith('第一百二十三章'));
    });
  });
}
