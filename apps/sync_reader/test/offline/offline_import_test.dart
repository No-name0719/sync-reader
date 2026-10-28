/// FR-601 离线导入用例（服务层直调，手法同 test/library/book_import_service_test）：
/// 飞行模式（connectivity=none）下经导入流水线导入 txt / epub 各一本，
/// 断言入库成功且全程零同步动作（适配器供应零创建 → 零网络调用）。
///
/// 导入流水线本身不触碰 connectivity / 同步门面（纯本地：哈希 → 去重 →
/// 解析 → 落盘 → 落库）；本用例把"零网络"固化为可验证断言：即便同步账号
/// 已配置、适配器供应在线旁待命，导入全程也绝不创建适配器实例。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/data/secure/secure_credential_store.dart';
import 'package:sync_reader/data/sync/drift_local_library.dart';
import 'package:sync_reader/data/sync/drift_sync_store.dart';
import 'package:sync_reader/features/library/import/book_import_service.dart';
import 'package:sync_reader/features/reader/contract/format_registry.dart';
import 'package:sync_reader/features/reader/formats/epub/epub_format_handler.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_format_handler.dart';
import 'package:sync_reader/features/sync/sync_facade.dart';
import 'package:sync_reader/features/sync/sync_status.dart';

import 'offline_env.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // connectivity 平台通道 mock 为 none（飞行模式的物理底座）：
    // checkConnectivity 恒报无网络，事件流保持静默。
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/connectivity'),
          (call) async => <String>['none'],
        );
  });

  test('飞行模式前置：connectivity 上报 none', () async {
    final types = await Connectivity().checkConnectivity();
    expect(types, [ConnectivityResult.none]);
  });

  test('离线导入 txt 与 epub 各一本：入库成功、零同步动作、零网络调用', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
    final tmp = await Directory.systemTemp.createTemp('offline_import');
    final store = BookFileStore(tmp);
    await store.ensureLayout();

    // 同步侧旁路待命：凭据配置齐全 + 适配器供应带创建计数（一旦有任何
    // 同步动作发生，createCalls 必然 > 0；产物为内存适配器，绝无真实网络）。
    final credentials = InMemoryCredentialStore();
    await credentials.save(SecureKeys.webdavAccount, 'reader@example.com');
    await credentials.save(SecureKeys.webdavPassword, 'app-secret');
    final adapterProvider = CountingAdapterProvider();
    final outcomes = <SyncStatusOutcome>[];
    final facade = SyncFacade(
      adapterProvider: adapterProvider,
      credentials: credentials,
      store: DriftSyncStore(db: db, credentials: credentials),
      library: DriftLocalLibrary(db: db, fileStore: Future.value(store)),
      readPreferences: () async => const SyncPreferencesSnapshot(),
      onOutcome: outcomes.add,
    );

    // 源文件：txt（真实 handler 按文件名解析标题）+ epub（内联最小夹具）。
    final txtBytes = utf8.encode('第一章 开端\n离线导入的正文内容。\n');
    final txtFile = File(p.join(tmp.path, '三体.txt'));
    await txtFile.writeAsBytes(txtBytes, flush: true);
    final epubBytes = buildMinimalEpub(coverBytes: tinyPng);
    final epubFile = File(p.join(tmp.path, '夹具书名.epub'));
    await epubFile.writeAsBytes(epubBytes, flush: true);

    final service = BookImportService(
      booksDao: db.booksDao,
      registry: FormatRegistry()
        ..register(TxtFormatHandler())
        ..register(EpubFormatHandler()),
      fileStore: Future.value(store),
    );

    // 导入（飞行模式下真实执行）。
    final summary = await service.importFiles([txtFile.path, epubFile.path]);

    // 全部成功入库。
    expect(summary.failures, isEmpty, reason: '离线不得产生导入失败');
    expect(summary.duplicates, isEmpty);
    expect(summary.imported, hasLength(2));

    final byFormat = {for (final b in summary.imported) b.format: b};
    final txt = byFormat['txt']!;
    final epub = byFormat['epub']!;

    // txt：真实 handler 解析（文件名兜底标题）+ 正文原样复制入库。
    expect(txt.title, '三体');
    expect(txt.fileName, '三体.txt');
    expect(File(txt.localPath!).readAsBytesSync(), txtBytes);
    expect((await db.booksDao.getById(txt.bookId))!.title, '三体');

    // epub：真实 handler 解析 OPF（标题/封面来自夹具）。
    expect(epub.title, '夹具书名');
    expect(epub.coverPath, isNotNull);
    expect(File(epub.coverPath!).existsSync(), isTrue);
    expect(File(epub.localPath!).readAsBytesSync(), epubBytes);
    expect((await db.booksDao.getById(epub.bookId))!.format, 'epub');

    // 零同步动作：适配器供应零创建（导入链路从未触碰云端/网络），
    // 引擎从未构建，门面无任何状态上报。
    expect(adapterProvider.createCalls, 0, reason: '导入全程不得创建适配器');
    expect(facade.engineReady, isFalse, reason: '导入不得触发同步引擎构建');
    expect(outcomes, isEmpty);

    await facade.dispose();
    await db.close();
    await tmp.delete(recursive: true);
  });
}

/// 内联最小 epub 夹具（与 test/library/support/minimal_epub.dart 同构，
/// 目录内自洽故复制；OPF 元数据 + 封面声明 + 单章正文）。
Uint8List buildMinimalEpub({required List<int> coverBytes}) {
  final container =
      '<?xml version="1.0"?><container version="1.0" '
      'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
      '<rootfile full-path="OEBPS/content.opf" '
      'media-type="application/oebps-package+xml"/></rootfiles></container>';
  final opf =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<package xmlns="http://www.idpf.org/2007/opf" '
      'unique-identifier="uid" version="2.0">'
      '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:title>夹具书名</dc:title><dc:creator>夹具作者</dc:creator>'
      '<dc:language>zh</dc:language>'
      '<dc:identifier id="uid">urn:uuid:test-epub-0001</dc:identifier>'
      '<meta name="cover" content="cover-image"/></metadata>'
      '<manifest>'
      '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
      '<item id="c1" href="chapter1.xhtml" '
      'media-type="application/xhtml+xml"/>'
      '<item id="cover-image" href="cover.png" media-type="image/png"/>'
      '</manifest>'
      '<spine toc="ncx"><itemref idref="c1"/></spine></package>';
  final ncx =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
      '<head><meta name="dtb:uid" content="urn:uuid:test-epub-0001"/></head>'
      '<docTitle><text>夹具书名</text></docTitle>'
      '<navMap><navPoint id="n1"><navLabel><text>第一章</text></navLabel>'
      '<content src="chapter1.xhtml"/></navPoint></navMap></ncx>';
  final chapter =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第一章</title>'
      '</head><body><h1>第一章</h1><p>夹具正文段落。</p></body></html>';

  final archive = Archive()
    ..add(ArchiveFile.bytes('mimetype', utf8.encode('application/epub+zip')))
    ..add(ArchiveFile.string('META-INF/container.xml', container))
    ..add(ArchiveFile.string('OEBPS/content.opf', opf))
    ..add(ArchiveFile.string('OEBPS/toc.ncx', ncx))
    ..add(ArchiveFile.string('OEBPS/chapter1.xhtml', chapter))
    ..add(ArchiveFile.bytes('OEBPS/cover.png', coverBytes));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
