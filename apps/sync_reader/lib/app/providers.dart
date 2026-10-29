/// 依赖装配（Riverpod providers，docs/03 §2 app/DI）。
///
/// 数据库相关 provider 是后续所有功能代理的根：注入测试时可用
/// `ProviderScope(overrides: [databaseProvider.overrideWithValue(测试内存库)])`。
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/db/app_database.dart';
import '../data/db/daos/app_settings_dao.dart';
import '../data/db/daos/books_dao.dart';
import '../data/db/daos/progress_dao.dart';
import '../data/db/daos/reading_days_dao.dart';
import '../data/db/daos/reader_settings_dao.dart';
import '../data/db/daos/sync_queue_dao.dart';
import '../data/files/book_file_store.dart';
import '../features/reader/contract/format_registry.dart';
import '../features/reader/contract/reader_settings_repository.dart';
import '../features/reader/formats/epub/epub_format_handler.dart';
import '../features/reader/formats/md/md_format_handler.dart';
import '../features/reader/formats/pdf/pdf_format_handler.dart';
import '../features/reader/formats/txt/txt_format_handler.dart';

/// 应用数据库（进程生命周期单例；关闭随容器 dispose）。
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

/// 书籍 DAO。
final booksDaoProvider = Provider<BooksDao>(
  (ref) => ref.watch(databaseProvider).booksDao,
);

/// 进度 DAO。
final progressDaoProvider = Provider<ProgressDao>(
  (ref) => ref.watch(databaseProvider).progressDao,
);

/// 阅读日统计 DAO（FR-208 按天统计）。
final readingDaysDaoProvider = Provider<ReadingDaysDao>(
  (ref) => ref.watch(databaseProvider).readingDaysDao,
);

/// 阅读偏好 DAO。
final readerSettingsDaoProvider = Provider<ReaderSettingsDao>(
  (ref) => ref.watch(databaseProvider).readerSettingsDao,
);

/// 待同步队列 DAO（M2）。
final syncQueueDaoProvider = Provider<SyncQueueDao>(
  (ref) => ref.watch(databaseProvider).syncQueueDao,
);

/// 应用级设置 DAO（v1.1：accent / 外观模式持久化，docs/10 §4.7）。
final appSettingsDaoProvider = Provider<AppSettingsDao>(
  (ref) => ref.watch(databaseProvider).appSettingsDao,
);

/// 文件存储（应用支持目录下的 files/，见 [BookFileStore] 文档注释）。
final bookFileStoreProvider = FutureProvider<BookFileStore>((ref) async {
  final support = await getApplicationSupportDirectory();
  final store = BookFileStore(Directory(p.join(support.path, 'files')));
  await store.ensureLayout();
  return store;
});

/// 阅读设置仓库（变更经 [ReaderSettingsRepository.changes] 广播）。
final readerSettingsRepositoryProvider = Provider<ReaderSettingsRepository>(
  (ref) => ReaderSettingsRepository(ref.watch(readerSettingsDaoProvider)),
);

/// 格式注册表：注册 M1 的四个基线 handler。
/// 后续代理升级某格式时，在注册处替换实现即可，注册表结构不变。
final formatRegistryProvider = Provider<FormatRegistry>((ref) {
  final registry = FormatRegistry()
    ..register(TxtFormatHandler())
    ..register(MdFormatHandler())
    ..register(PdfFormatHandler())
    ..register(EpubFormatHandler());
  return registry;
});
