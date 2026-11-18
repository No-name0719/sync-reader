/// 阅读页重设计（v1.2 B1–B8）逐屏截图 harness（一次性验证基建，产物不入库）。
///
/// 运行方式（goldens 产出）：
///
/// ```bash
/// cd apps/sync_reader
/// READER_SHOTS=1 flutter test --update-goldens test/goldens/reader_screens_test.dart
/// ```
///
/// - 常规 `flutter test`（无 `READER_SHOTS=1`）直接跳过，无 CI 风险；
/// - 产物：`ui_audit/reader_v12/reader-{宽}-{主题}-{轴向}.png`
///   （4 档宽度 × 7 套背景 × 2 种翻页动画 = 56 张）+ 夜间亮度 80% 两张
///   + 翻页动画进行中两张；
/// - 字体：fontTools 把系统仿宋/黑体的 name 表改写为阅读默认字体族
///   （Noto Serif SC / Noto Sans SC）后由 FontLoader 注册（真字体渲染，
///   教训见 docs/10 §9.4：金测默认字体渲染方块、按内部族名分组、TTC 取
///   不到字形）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

import 'package:sync_reader/features/reader/contract/book_file.dart';
import 'package:sync_reader/features/reader/contract/progress_anchor.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/formats/epub/epub_format_handler.dart';
import 'package:sync_reader/features/reader/formats/md/md_format_handler.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_format_handler.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_paginator.dart';
import 'package:sync_reader/features/reader/reader_brightness.dart';
import 'package:sync_reader/features/reader/reader_chrome.dart';

import '../library/support/text_only_epub.dart';

/// 4 档视口（v1.1 逐屏比对同一组宽度）。
const _viewports = <(String, Size)>[
  ('1440', Size(1440, 900)),
  ('1180', Size(1180, 800)),
  ('860', Size(860, 700)),
  ('390', Size(390, 844)),
];

/// 样章（自拟内容，与任何受版权作品无关）：四章，每章八段左右。
const String _bookText = '''
第一章 落雪
天还没有亮透，落在瓦上的雪先有了声音。细而密，像有人在屋顶上筛一把碎米，簌簌地落了半夜。林砚是被这声音叫醒的，他睁开眼，看见窗纸上一片淡白，屋里冷得像一口井。
他躺着没有动。屋梁上挂着一串去年的干辣椒，红得发暗，像一排缩起来的小灯笼。风从瓦缝里钻进来，先吹动辣椒，再吹到他脸上，带着一股陈年的、被雪水泡过的辣味。
母亲在灶间咳了一声，接着是勺子碰锅沿的响。他坐起来，摸到床头的火柴，划了三根才点着灯。灯芯很短，火苗缩成一小团，把他的影子推到墙上，影子的肩膀比他还瘦。
「雪大。」母亲在灶间说，并没有回头。
他应了一声，把棉袄披上，又想起什么，从柜子最底下翻出一只铁皮盒子。盒盖上印着褪色的红漆字，盒子里原本是一副眼镜，镜片早就碎了，现在只剩一副空框，框腿上的漆也磨得发亮。
母亲没有回头，只是把火拨旺了些：「那盒子你还留着。」
「留着。」他说。
雪下到晌午才停。林砚吃了半碗粥，把碗洗了，碗口朝下扣在灶台上。然后他做了一件事：把院里的水缸盖上，又把墙根那一溜柴火往里挪了挪，腾出一块干燥的地方。做完这些，他站在门口看了很久。四下里白得晃眼，屋檐下的冰凌子挂了一排，长短不齐，像一排没写完的字。
临睡前他去灶间添了柴，看见灶膛里还埋着几块没烧透的炭，红着，像几粒很小的星。他没有再添柴，把灶门半掩着，让那点红慢慢自己熄。
他忽然想起父亲说过的一句话：雪落下来的时候，是替天把话说完。那时他不懂，如今还是不懂，只是觉得这句话在这样的天气里说出来，很合适。
他吹了灯，摸黑回到床上。黑暗里，雪落在瓦上的声音反而更清楚了，一层压着一层，像有人在很远的地方翻一本很厚的书。他听着听着就睡着了，梦里也是白的，白得没有边。
第二天醒来，雪已经停了。院里的雪被风扫成一垄一垄，靠着墙根堆着。母亲在灶间熬粥，米香混着柴火气，从门缝里挤进来。他穿好衣服出门，把院门推开一条缝，门外的雪光涌进来，晃得他眯起了眼。
第二章 旧渡口
开春以后，水路上的冰才开始松。林砚每隔几天就要去一趟渡口，那是往县里寄信的必经之处。渡口的船家姓周，人们都叫他老周，一条船，一个孩子，一支竹篙。
老周的船停在岸边，看上去和别的船没什么两样，可林砚知道，那船底是平的。别的船底是尖的，一到浅滩就搁浅；平底的船可以在任何地方靠岸，哪怕只是几尺水的泥滩。这道理是老周花了二十年想出来的。
「县城的邮路改了。」老周有一天说，「往后信要走下游。」
林砚的手停了一下。信是母亲托他寄的，寄给一个地址，那个地址在很多年前已经换了三回人了。信到了，也未必有人收。
「那就走下游。」他说。
老周看了他一眼，把竹篙换了个手：「下游远，多半天的水。」
「多半天的水，换一条还通着的路，值。」
船到河心的时候起了风。不大，但水面上起了细碎的皱纹，把天光揉成了一片一片。老周把篙插下去，不是一插到底，而是插到船不动了为止，然后站着看水。林砚没接话，老周也不再讲，两个人就看了一程的水。
第三章 灯下
那年冬天来得早。腊月初八就下了头一场大雪，之后是第二场、第三场，一场接着一场，中间几乎没有停顿。整个村子被雪封了半个月，进出全靠一条被踩出来的窄道。
林砚在屋里读书。书是父亲留下的，一共三十七本，摞在床头的木箱上，最上面那本总是翻烂的。他读得很慢，一天读不了几页，因为要一边读一边想。
母亲在灶间做针线。她眼睛不好，灯举得离脸很近，针脚走得慢，一针要停三次。有一次她忽然说：「你读书的样子，跟你爹一个样。」
「他读书吗？」
「读。」母亲说，「读得没你好。他读一句，要抬头看半天窗。」
林砚笑起来。他没见过父亲读书——父亲死在他七岁那年，他关于父亲的一切都是拼凑出来的：一只大手，一件带补丁的棉袄，还有一句谁在窗外叫的问话。
灯芯爆了一下，火苗跳了跳，屋里的影子跟着晃了晃。母亲把灯捻小了些，说：「夜里看书，费油。省着点。」
林砚说好。他把书合上，又打开，把刚才那一段重读了一遍。窗外风过，雪粒打在纸上沙沙地响，像有什么东西在屋檐下翻书。
第四章 归船
开春以后，老周说要收船了。
「往哪儿去？」林砚问。
「下游。」老周蹲在船头补篙，「听说那边修了个新渡口，水深，能走大船。」
「这边呢？」
「这边桥修起来了。」老周说，「以后不用摆渡了。」
林砚没有接话。桥是去年修的，青石拱券，桥面很宽，能过两辆卡车。修桥那天全村人都去看，孩子在桥上跑，老人坐在桥头抽烟，谁也没有想到这条河从此会安静下来。
那天晚上他回家，把书箱翻了个遍。父亲的书，母亲的针线，那只铁皮盒子，还有三十七本旧书里唯一一本他还没读过的《潮汐》。是本讲海的书，讲的是船怎样靠洋流走路，从不逆着水硬撑。
「船是顺着水走的。」他忽然想，「人也是。」
第二天他没有去拉船。他去了渡口，坐在老周的船上，一直坐到日头偏西。老周在船尾补网，没有问他在等什么，他也没有解释。临走前，老周从舱里拿出一样东西递给他：一张折成四折的旧船票，落款是二十多年前的一个渡口名字。
''';

Future<BookFile> _writeBook() async {
  final dir = await Directory.systemTemp.createTemp('reader_shots');
  final file = File('${dir.path}${Platform.pathSeparator}样章.txt');
  await file.writeAsBytes(Uint8List.fromList(utf8.encode(_bookText)));
  return BookFile.fromPath(file.path);
}

/// 从当前目录向上查找仓库根的 ui_audit/fonts（测试进程 CWD = 包目录，
/// 字体产物在仓库根 ui_audit/ 下，不入库）。
File _locateFont(String fileName) {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final candidate = File(
      '${dir.path}${Platform.pathSeparator}ui_audit'
      '${Platform.pathSeparator}fonts${Platform.pathSeparator}$fileName',
    );
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError('找不到字体文件 $fileName（需要先运行 ui_audit/fonts 的生成脚本）');
}

Future<void> _loadFonts() async {
  final fonts = <String, String>{
    'Noto Serif SC': 'NotoSerifSC-alias.ttf',
    'Noto Sans SC': 'NotoSansSC-alias.ttf',
  };
  for (final entry in fonts.entries) {
    final file = _locateFont(entry.value);
    assert(file.existsSync(), '字体文件缺失：${file.path}');
    final bytes = await file.readAsBytes();
    final loader = FontLoader(entry.key)
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }
}

void main() {
  final enabled = Platform.environment['READER_SHOTS'] == '1';
  if (!enabled) {
    // 常规测试运行直接跳过（截图只按需产出）。
    return;
  }
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    TxtPaginator.debugSyncPagination = true;
    await TestWidgetsFlutterBinding.instance.runAsync(_loadFonts);
  });

  tearDownAll(() {
    TxtPaginator.debugSyncPagination = false;
  });

  /// 泵一帧阅读视图并截图。
  Future<void> shoot(
    WidgetTester tester, {
    required String name,
    required Size surface,
    required ReaderSettings settings,
    bool midTurn = false,
  }) async {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final bf = await tester.runAsync(_writeBook);
    final renderer =
        (await tester.runAsync(
              () => TxtFormatHandler().createRenderer(
                bf!,
                settings,
                ProgressAnchor.empty,
              ),
            ))!
            as dynamic;
    addTearDown(renderer.dispose);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Builder(
            // v1.3：正文视图用与真实阅读页相同的垂直内缩包裹（顶条/底条
            // 让位），保证金测产物与真实阅读页一致。
            builder: (context) => ReaderBrightnessFilter(
              isNightTheme: settings.theme.isNight,
              brightness: settings.nightBrightness,
              child: Padding(
                padding: readerBodyInsets(context),
                child: renderer.buildView(context),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    if (midTurn) {
      // 翻页动画进行中的一帧（B5 推移动画证据）。样章第一章 > 2 页，
      // 章内翻页不触发换章（换章会中途换 PageController，无法取中间帧）。
      unawaited(renderer.controller.nextPage());
      // FakeAsync 下 ticker 首帧只启动不推进：先 pump 一帧启动动画，
      // 再推进 90ms（约 2/3 行程，easeOutCubic）捕获推移中间帧。
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 90));
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('../../../../ui_audit/reader_v12/$name.png'),
      );
      await tester.pumpAndSettle();
    } else {
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('../../../../ui_audit/reader_v12/$name.png'),
      );
    }
  }

  for (final (widthName, surface) in _viewports) {
    for (final theme in ReaderTheme.values) {
      for (final axis in ReaderPageTurnAxis.values) {
        final axisName = axis == ReaderPageTurnAxis.vertical ? 'v' : 'h';
        testWidgets(
          'reader-$widthName-${theme.name}-$axisName',
          (tester) => shoot(
            tester,
            name: 'reader-$widthName-${theme.name}-$axisName',
            surface: surface,
            settings: ReaderSettings.defaults.copyWith(
              theme: theme,
              pageMode: ReaderPageMode.page,
              pageTurnAxis: axis,
            ),
          ),
        );
      }
    }
  }

  // 夜间亮度 80%（B3：整屏变暗仍达标）——深灰主题两轴向。
  testWidgets(
    'reader-1440-dark-v-brightness80',
    (tester) => shoot(
      tester,
      name: 'reader-1440-dark-v-brightness80',
      surface: const Size(1440, 900),
      settings: ReaderSettings.defaults.copyWith(
        theme: ReaderTheme.dark,
        pageMode: ReaderPageMode.page,
        pageTurnAxis: ReaderPageTurnAxis.vertical,
        nightBrightness: 0.8,
      ),
    ),
  );
  testWidgets(
    'reader-1440-dusk-h-brightness80',
    (tester) => shoot(
      tester,
      name: 'reader-1440-dusk-h-brightness80',
      surface: const Size(1440, 900),
      settings: ReaderSettings.defaults.copyWith(
        theme: ReaderTheme.dusk,
        pageMode: ReaderPageMode.page,
        pageTurnAxis: ReaderPageTurnAxis.horizontal,
        nightBrightness: 0.8,
      ),
    ),
  );

  // 翻页动画进行中（B5 证据）——深灰主题两轴向。
  testWidgets(
    'reader-1440-dark-v-midturn',
    (tester) => shoot(
      tester,
      name: 'reader-1440-dark-v-midturn',
      surface: const Size(1440, 900),
      settings: ReaderSettings.defaults.copyWith(
        theme: ReaderTheme.dark,
        pageMode: ReaderPageMode.page,
        pageTurnAxis: ReaderPageTurnAxis.vertical,
      ),
      midTurn: true,
    ),
  );
  testWidgets(
    'reader-1440-dark-h-midturn',
    (tester) => shoot(
      tester,
      name: 'reader-1440-dark-h-midturn',
      surface: const Size(1440, 900),
      settings: ReaderSettings.defaults.copyWith(
        theme: ReaderTheme.dark,
        pageMode: ReaderPageMode.page,
        pageTurnAxis: ReaderPageTurnAxis.horizontal,
      ),
      midTurn: true,
    ),
  );

  // —— v1.4.4：四格式「翻页中帧」对照（docs/10 §9.21 §6.2）——
  //
  // 核心验收物：**四格式的翻页中帧看不出差别**（同样的推移方向与位移）。
  //
  // 覆盖说明（如实记录，不假装齐全）：
  // - txt / epub / md：可进 harness（纯 Dart 渲染，字体已注册）；
  // - **pdf 进不了**：pdfrx 需要 pdfium 原生库，flutter test 环境不加载
  //   （见 test/reader/pdf/pdf_page_turn_test.dart 头注）→ pdf 的翻页帧
  //   只能真机截图（scripts/drive_app.ps1），且其动画由库提供（纵向平移，
  //   见 docs/10 §9.21.4 遗留风险）；
  // - **md 没有翻页动画**：md 暂按滚动呈现（FR-204 未强制分页），故只出
  //   静止帧，用于确认「md 与其它格式的差异只在于翻页方式」。

  /// 翻页对照的两种视口（手机竖屏 + 桌面）。
  const turnViewports = <(String, Size)>[
    ('390', Size(390, 844)),
    ('1440', Size(1440, 900)),
  ];

  /// 写 md 夹具（与 txt 样章同文，便于肉眼比对排版）。
  Future<BookFile> writeMdBook() async {
    final dir = await Directory.systemTemp.createTemp('reader_turn_md');
    final file = File('${dir.path}${Platform.pathSeparator}样章.md');
    await file.writeAsBytes(Uint8List.fromList(utf8.encode(_bookText)));
    return BookFile.fromPath(file.path);
  }

  /// 写 epub 夹具（**纯文字**：插图独占一页且解码异步，会让「翻页中帧」的
  /// 推入页拍成空白，无法与其它格式同口径比对）。
  Future<BookFile> writeEpubBook() async {
    final dir = await Directory.systemTemp.createTemp('reader_turn_epub');
    final file = File('${dir.path}${Platform.pathSeparator}样章.epub');
    await file.writeAsBytes(buildTextOnlyEpub());
    return BookFile.fromPath(file.path);
  }

  /// 四格式翻页对照截图。
  ///
  /// [midTurn] = true 时截「翻页动画进行中」的一帧（约 2/3 行程）。
  Future<void> shootTurn(
    WidgetTester tester, {
    required String format,
    required String widthName,
    required Size surface,
    required bool midTurn,
  }) async {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final settings = ReaderSettings.defaults.copyWith(
      theme: ReaderTheme.paper,
      pageMode: ReaderPageMode.page,
    );
    final dynamic renderer;
    switch (format) {
      case 'txt':
        final bf = await tester.runAsync(_writeBook);
        renderer = await tester.runAsync(
          () => TxtFormatHandler().createRenderer(
            bf!,
            settings,
            ProgressAnchor.empty,
          ),
        );
      case 'epub':
        final bf = await tester.runAsync(writeEpubBook);
        renderer = await tester.runAsync(
          () => EpubFormatHandler().createRenderer(
            bf!,
            settings,
            ProgressAnchor.empty,
          ),
        );
      case 'md':
        final bf = await tester.runAsync(writeMdBook);
        renderer = await tester.runAsync(
          () => MdFormatHandler().createRenderer(
            bf!,
            settings,
            ProgressAnchor.empty,
          ),
        );
      default:
        throw StateError('未知格式 $format');
    }
    addTearDown(renderer.dispose);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Builder(
            builder: (context) => ReaderBrightnessFilter(
              isNightTheme: settings.theme.isNight,
              brightness: settings.nightBrightness,
              child: Padding(
                padding: readerBodyInsets(context),
                child: renderer.buildView(context),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    if (midTurn) {
      // 起翻 → 推进到约 2/3 行程（统一时长 280ms + easeOutCubic）捕获推移
      // 中间帧。txt/epub 的翻页动画时长与缓动同源于公共规格。
      unawaited(renderer.controller.nextPage());
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 140));
    }
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile(
        '../../../../ui_audit/turn_v14/$format-$widthName-${midTurn ? 'midturn' : 'rest'}.png',
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final (widthName, surface) in turnViewports) {
    for (final format in const ['txt', 'epub']) {
      testWidgets(
        'turn-$format-$widthName-rest',
        (tester) => shootTurn(
          tester,
          format: format,
          widthName: widthName,
          surface: surface,
          midTurn: false,
        ),
      );
      testWidgets(
        'turn-$format-$widthName-midturn',
        (tester) => shootTurn(
          tester,
          format: format,
          widthName: widthName,
          surface: surface,
          midTurn: true,
        ),
      );
    }
    // md：只有滚动，没有翻页动画 → 只出静止帧（差异如实记录）。
    testWidgets(
      'turn-md-$widthName-rest',
      (tester) => shootTurn(
        tester,
        format: 'md',
        widthName: widthName,
        surface: surface,
        midTurn: false,
      ),
    );
  }
}
