/// FR-106 / NFR-07 规模基准：2000 本书库的搜索与书库查询性能实测。
///
/// **这是 NFR 性能基准，不是功能用例**：查询语义（排序/搜索/分组过滤）
/// 的正确性已由 `test/data/db/dao_test.dart` 覆盖；本文件只回答一个问题——
/// 在设计规模上限（2000 本，NFR-07）下，搜索与书库列表查询是否满足
/// FR-106 的响应门（中位数 < 100ms）。
///
/// 口径与做法：
/// - drift 内存库（`NativeDatabase.memory()`），无磁盘 IO，聚焦查询本身；
/// - 每项先预热 3 次（消除 JIT/缓存冷启动），再连测 20 次，取中位数做断言门
///   （对机器/CI 噪声稳健），最大值一并打印仅供参考；
/// - 计时对象是 `watchBooks(...).first`：单次取首帧即取消订阅，
///   含 SQL 执行与行映射开销，不含流订阅常驻；
/// - 不引入 sleep、不动态调参，迭代次数固定，结果可复现、可跨机对比。
///
/// 输出末尾附可直接粘贴进 docs/08 的登记摘要（含环境与口径说明）。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/db/daos/books_dao.dart';

/// 设计规模上限（docs/01 NFR-07）。
const int _totalBooks = 2000;

/// 「斗罗大陆 1..30」同前缀系列规模。
const int _seriesSize = 30;

/// 高频作者数量（每位作者 60 本 → 重复 50+ 本）。
const int _topAuthorCount = 10;

/// 每位高频作者的书数。
const int _booksPerTopAuthor = 60;

/// 高频作者区块结束索引（不含）。
const int _topAuthorEnd = _booksPerTopAuthor * _topAuthorCount; // 600

/// 系列区块结束索引（不含）。
const int _seriesEnd = _topAuthorEnd + _seriesSize; // 630

/// 分组规模（加分项 e：1 组 100 本）。
const int _groupSize = 100;

/// 搜索常见词（a 项）：预期命中数百本（种子中约 1/5 普通书 + 系列 30 本）。
const String _commonQuery = '大陆';

/// 搜索零命中词（b 项）：种子中不可能出现的字符串。
const String _missQuery = 'zzqqxx绝不存在的书名918273';

/// 每项预热次数。
const int _warmupRuns = 3;

/// 每项计时次数（取中位数）。
const int _timedRuns = 20;

/// FR-106 性能门：单次查询响应中位数上限（毫秒）。
const double _fr106GateMs = 100;

/// drift 版本（取自 apps/sync_reader/pubspec.lock；升级依赖后请同步此行）。
const String _driftVersion = '2.35.3';

/// 入库时间基点（每本递增 1 分钟，覆盖"添加时间"排序面）。
final int _addedAtBase = DateTime(2026, 1, 1).millisecondsSinceEpoch;

/// 最近阅读时间基点（每本回退 1 小时 → 最近约 83 天内分布）。
final int _lastReadBase = DateTime(2026, 10, 20).millisecondsSinceEpoch;

/// 格式轮转（docs/05 §3.2：txt | epub | md | pdf）。
const List<String> _formats = ['txt', 'epub', 'md', 'pdf'];

/// 高频作者与其代表作（书名系列化 → 同前缀重复，贴近真实书库分布）。
const List<(String, List<String>)> _topAuthorWorks = [
  ('唐家三少', ['天火大道', '生肖守护神', '绝世唐门']),
  ('天蚕土豆', ['斗破苍穹', '武动乾坤', '大主宰']),
  ('辰东', ['遮天', '完美世界', '圣墟']),
  ('我吃西红柿', ['盘龙', '吞噬星空', '莽荒纪']),
  ('刘慈欣', ['三体', '球状闪电', '超新星纪元']),
  ('金庸', ['射雕英雄传', '神雕侠侣', '倚天屠龙记']),
  ('古龙', ['多情剑客无情剑', '楚留香传奇', '陆小凤传奇']),
  ('东野圭吾', ['白夜行', '嫌疑人X的献身', '解忧杂货店']),
  ('J.K.罗琳', ['神奇动物在哪里', '偶发空缺', '布谷鸟的呼唤']),
  ('江南', ['龙族', '九州缥缈录', '此间的少年']),
];

/// 普通作者池（低频重复；含英文作者 → 作者列的中英混合）。
const List<String> _generalAuthors = [
  '余华',
  '王小波',
  '迟子建',
  '阿城',
  '汪曾祺',
  '张爱玲',
  '钱钟书',
  '杨绛',
  '木心',
  '马伯庸',
  'George Orwell',
  '张宏杰',
  '黄仁宇',
  '许倬云',
  '李泽厚',
  '冯友兰',
  '盐野七生',
  '司马辽太郎',
  '高阳',
  '二月河',
];

String _bookId(int i) => 'bench${i.toString().padLeft(6, '0')}';

/// 按全局序号 i 生成书名：高频作者系列 / 斗罗大陆系列 / 普通书三类区块；
/// 普通书约 1/5 含「大陆」（保证 a 项命中数百本），其余覆盖
/// 纯中文 / 中英混合 / 纯英文 / 长短书名等形态。
String _titleFor(int i) {
  if (i < _topAuthorEnd) {
    // 高频作者：同一作者多部代表作各带卷号 → 大量同前缀书名。
    final work = _topAuthorWorks[i ~/ _booksPerTopAuthor].$2;
    final v = i % _booksPerTopAuthor;
    return '${work[v % work.length]} 第${v ~/ work.length + 1}卷';
  }
  if (i < _seriesEnd) {
    return '斗罗大陆 ${i - _topAuthorEnd + 1}';
  }
  final j = i - _seriesEnd;
  if (j % 5 == 0) {
    return '失落的大陆编年史 第$j部'; // 约 1/5 命中「大陆」
  }
  switch (j % 8) {
    case 0:
      return '山月不知心底事（全本典藏纪念版·校注${j % 9 + 1}册）'; // 长书名
    case 1:
      return 'Flutter 跨端开发实战手记·第${j % 40}篇'; // 中英混合
    case 2:
      return '雪${j % 97}'; // 一字短书名（少量重复前缀）
    case 3:
      return '夜航船札记 ${j % 13}辑';
    case 4:
      return 'A Brief History of Timekeeping Vol.${j % 24}'; // 纯英文
    case 5:
      return '人间烟火考 ${j % 500}';
    case 6:
      return '机器学习导论（第${j % 12 + 1}版）';
    default:
      return '短篇集结号 第${j % 100}号';
  }
}

/// 作者分布：高频作者区块各 60 本（唐家三少另加系列 30 本 → 90 本）、
/// 普通书每 13 本留一本空作者（schema 允许，对应解析失败的文件）。
String _authorFor(int i) {
  if (i < _topAuthorEnd) {
    return _topAuthorWorks[i ~/ _booksPerTopAuthor].$1;
  }
  if (i < _seriesEnd) {
    return '唐家三少'; // 系列归属高频作者，凑足"Top 作者 50+ 本"
  }
  final j = i - _seriesEnd;
  if (j % 13 == 0) {
    return '';
  }
  return _generalAuthors[j % _generalAuthors.length];
}

/// 构造第 i 本书的行（确定性，无随机数；全字段合理填充）。
BooksCompanion _bookRow(int i) {
  final format = _formats[i % _formats.length];
  final read = i % 3 == 0; // 约 1/3 的书有阅读痕迹（lastReadAt + 进度行）
  return BooksCompanion.insert(
    bookId: _bookId(i),
    title: _titleFor(i),
    format: format,
    fileName: '${_bookId(i)}.$format',
    contentHash: 'sha256:${i.toRadixString(16).padLeft(64, '0')}',
    sizeBytes: 200_000 + i * 137,
    tocFingerprint: 'tfp:${i.toRadixString(16).padLeft(16, '0')}',
    addedAt: _addedAtBase + i * 60 * 1000,
    author: Value(_authorFor(i)),
    localPath: Value('/bench/${_bookId(i)}.dat'),
    coverPath: i % 7 == 0
        ? Value('/bench/${_bookId(i)}.png')
        : const Value.absent(),
    lastReadAt: Value(read ? _lastReadBase - i * 60 * 60 * 1000 : null),
    totalSeconds: Value(read ? 1200 + i % 5400 : 0),
  );
}

/// 单项测量：预热 [_warmupRuns] 次后连测 [_timedRuns] 次，
/// 返回中位数/最大值（毫秒）与末次命中行数。
/// 中位数取上中位（偶数次样本排序后取第 n/2 个，断言门偏保守）。
Future<({double medianMs, double maxMs, int rows})> _measureQuery(
  Future<int> Function() run,
) async {
  for (var w = 0; w < _warmupRuns; w++) {
    await run();
  }
  final samples = <int>[];
  var rows = 0;
  for (var t = 0; t < _timedRuns; t++) {
    final sw = Stopwatch()..start();
    rows = await run();
    sw.stop();
    samples.add(sw.elapsedMicroseconds);
  }
  samples.sort();
  return (
    medianMs: samples[samples.length ~/ 2] / 1000.0,
    maxMs: samples.last / 1000.0,
    rows: rows,
  );
}

void main() {
  setUpAll(() {
    // 基准表格必须完整落控制台（供登记 docs/08），关闭 debugPrint 节流。
    debugPrint = debugPrintSynchronously;
  });

  tearDownAll(() {
    debugPrint = debugPrintThrottled;
  });

  test('FR-106/NFR-07 规模基准（NFR 性能门，非功能用例）：2000 本搜索与书库查询', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customSelect('SELECT 1').getSingle(); // 触发 beforeOpen（pragma 路径）

    // ---- 1. 灌种子：2000 本书 + 约 1/3 进度行 + 1 组 100 本（全部走现有 API） ----
    final seedSw = Stopwatch()..start();
    final group = await db.bookGroupsDao.createGroup('基准分组');
    var progressRows = 0;
    await db.transaction(() async {
      for (var i = 0; i < _totalBooks; i++) {
        await db.booksDao.upsertCompanion(_bookRow(i));
        if (i % 3 == 0) {
          progressRows++;
          await db.progressDao.upsert(
            bookId: _bookId(i),
            locatorJson:
                '{"type":"txt","chapterIndex":${i % 50},"charOffset":${i % 4096}}',
            percent: (i % 100) / 100,
          );
        }
      }
      for (var i = _seriesEnd; i < _seriesEnd + _groupSize; i++) {
        await db.booksDao.setGroup(_bookId(i), group.groupId);
      }
    });
    seedSw.stop();

    // 种子规模自检：确保基准真的跑在 2000 本上（口径校验，非性能门）。
    expect(await db.booksDao.readAllBookIds(), hasLength(_totalBooks));

    // ---- 2. 测量项（测查询本身：watchBooks(...).first 单次取帧） ----
    Future<int> hitSearch() async =>
        (await db.booksDao.watchBooks(query: _commonQuery).first).length;
    Future<int> missSearch() async =>
        (await db.booksDao.watchBooks(query: _missQuery).first).length;
    Future<int> defaultList() async =>
        (await db.booksDao.watchBooks().first).length;
    Future<int> titleSorted() async =>
        (await db.booksDao.watchBooks(sort: BookSort.title).first).length;
    Future<int> groupFiltered() async =>
        (await db.booksDao.watchBooks(groupFilterId: group.groupId).first)
            .length;

    final hitRes = await _measureQuery(hitSearch);
    final missRes = await _measureQuery(missSearch);
    final defaultRes = await _measureQuery(defaultList);
    final titleRes = await _measureQuery(titleSorted);
    final groupRes = await _measureQuery(groupFiltered);

    // 种子命中数校验（保证 a 项确实是"数百本"量级的常见词搜索）。
    expect(
      hitRes.rows,
      greaterThan(200),
      reason: '「$_commonQuery」应命中数百本（本种子约 304 本）',
    );
    expect(hitRes.rows, lessThan(_totalBooks));
    expect(missRes.rows, 0);
    expect(defaultRes.rows, _totalBooks);
    expect(titleRes.rows, _totalBooks);
    expect(groupRes.rows, _groupSize);

    // ---- 3. 打印登记表格（可直接粘贴进 docs/08） ----
    String gate(double ms) => ms < _fr106GateMs ? '通过' : '超门';
    final report = StringBuffer()
      ..writeln('=' * 76)
      ..writeln('FR-106 / NFR-07 规模基准（2000 本书库搜索与书库查询）')
      ..writeln(
        '环境    : ${Platform.operatingSystem} | '
        '${Platform.operatingSystemVersion}',
      )
      ..writeln(
        '口径    : drift 内存库 NativeDatabase.memory()（无磁盘 IO）；'
        'drift $_driftVersion（apps/sync_reader/pubspec.lock）',
      )
      ..writeln(
        '规模    : $_totalBooks 本书 / $progressRows 条进度行 / '
        '1 组 $_groupSize 本；灌库 ${seedSw.elapsedMilliseconds} ms',
      )
      ..writeln(
        '方法    : 每项预热 $_warmupRuns 次后连测 $_timedRuns 次，'
        '取中位数（断言门）与最大值；计时含 SQL 执行与行映射'
        '（watchBooks(...).first 单帧），不含流订阅常驻',
      )
      ..writeln('-' * 76)
      ..writeln('| 项 | 查询 | 命中行数 | 中位数 | 最大值 |')
      ..writeln(
        '| a | 搜索常见词「$_commonQuery」（默认最近阅读排序） '
        '| ${hitRes.rows} | ${hitRes.medianMs.toStringAsFixed(1)} ms '
        '| ${hitRes.maxMs.toStringAsFixed(1)} ms |',
      )
      ..writeln(
        '| b | 搜索零命中词（默认最近阅读排序） | ${missRes.rows} '
        '| ${missRes.medianMs.toStringAsFixed(1)} ms '
        '| ${missRes.maxMs.toStringAsFixed(1)} ms |',
      )
      ..writeln(
        '| c | 书库默认列表（无搜索，最近阅读排序） | ${defaultRes.rows} '
        '| ${defaultRes.medianMs.toStringAsFixed(1)} ms '
        '| ${defaultRes.maxMs.toStringAsFixed(1)} ms |',
      )
      ..writeln(
        '| d | 全量按书名排序 | ${titleRes.rows} '
        '| ${titleRes.medianMs.toStringAsFixed(1)} ms '
        '| ${titleRes.maxMs.toStringAsFixed(1)} ms |',
      )
      ..writeln(
        '| e | 分组过滤（$_groupSize 本组，加分项不计门） '
        '| ${groupRes.rows} | ${groupRes.medianMs.toStringAsFixed(1)} ms '
        '| ${groupRes.maxMs.toStringAsFixed(1)} ms |',
      )
      ..writeln('-' * 76)
      ..writeln(
        'FR-106 门（中位数 < $_fr106GateMs ms）：'
        'a ${gate(hitRes.medianMs)} / b ${gate(missRes.medianMs)} / '
        'c ${gate(defaultRes.medianMs)} / d ${gate(titleRes.medianMs)}',
      )
      ..writeln('=' * 76);
    debugPrint(report.toString());

    // ---- 4. FR-106 性能门：中位数 < 100ms（断言失败即测试失败） ----
    void expectUnderGate(String label, double medianMs) {
      expect(
        medianMs,
        lessThan(_fr106GateMs),
        reason:
            'FR-106 门未过（$label：中位数 '
            '${medianMs.toStringAsFixed(1)} ms ≥ $_fr106GateMs ms）。'
            '2000 本规模下该查询超标，需排查索引缺失/全表扫描点'
            '（docs/01 FR-106、NFR-07；实测登记 docs/08）',
      );
    }

    expectUnderGate('a 搜索命中「$_commonQuery」', hitRes.medianMs);
    expectUnderGate('b 搜索零命中', missRes.medianMs);
    expectUnderGate('c 书库默认列表', defaultRes.medianMs);
    expectUnderGate('d 书名排序全量', titleRes.medianMs);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
