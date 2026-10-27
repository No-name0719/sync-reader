/// 批量导入目录扫描器（FR-109）：递归扫描一个文件夹，收集所有
/// `FormatRegistry` 已注册 handler 支持扩展名的文件，供确认页清单展示。
///
/// 设计约定：
/// - 纯逻辑类（无 UI / Riverpod 依赖），依赖仅注入注册表，便于单测；
/// - "支持格式"的判定复用 `FormatRegistry.byExtension`（即全部 handler
///   扩展名集合的并集，大小写不敏感），新增格式注册后扫描自动跟进；
/// - 无法访问的条目（无权限 / 悬空链接 / 读取中途消失）静默跳过并计数，
///   单个坏条目不中断整次扫描；
/// - 规模上限（NFR-07）：可导入文件数达到 [maxFiles] 即停止扫描并标记
///   截断，由 UI 提示"结果不完整"；
/// - 迭代栈遍历（非递归），深层目录不消耗调用栈；`followLinks: false`
///   防止链接环导致死循环。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../features/reader/contract/format_registry.dart';

/// 扫描到的候选文件（只含扫描期能拿到的静态信息；哈希与去重标记由
/// 确认页的分析阶段补充）。
class ScannedFile {
  const ScannedFile({
    required this.path,
    required this.relativePath,
    required this.ext,
    required this.sizeBytes,
  });

  /// 绝对路径（导入管线直接消费）。
  final String path;

  /// 相对扫描根目录的路径（清单页展示用）。
  final String relativePath;

  /// 小写扩展名（不含点）。
  final String ext;

  /// 文件字节数。
  final int sizeBytes;
}

/// 一次扫描的结果。
class ScanResult {
  const ScanResult({
    required this.files,
    required this.skippedCount,
    required this.truncated,
    required this.rootMissing,
  });

  /// 收集到的可导入文件（按相对路径字典序，保证结果稳定可测）。
  final List<ScannedFile> files;

  /// 静默跳过的无法访问条目数（无权限 / 悬空链接等）。
  final int skippedCount;

  /// 可导入文件数达到上限被截断（清单不完整，UI 需提示）。
  final bool truncated;

  /// 根目录不存在或不是目录（UI 提示错误，无候选）。
  final bool rootMissing;
}

/// 目录扫描器。
class BookScanner {
  BookScanner({required this._registry, this.maxFiles = defaultMaxFiles});

  /// 单次扫描的可导入文件数上限（NFR-07：2000 本规模）。
  static const defaultMaxFiles = 2000;

  final FormatRegistry _registry;

  /// 截断阈值（测试可注入更小值）。
  final int maxFiles;

  /// 递归扫描 [root]，返回可导入清单。
  ///
  /// 永不抛出：根缺失返回 [ScanResult.rootMissing]，坏条目计入
  /// skippedCount，其余异常也折叠为 rootMissing。
  Future<ScanResult> scan(Directory root) async {
    final rootPath = root.path;
    final rootStat = await _statQuiet(root);
    if (rootStat == null || rootStat.type != FileSystemEntityType.directory) {
      return const ScanResult(
        files: [],
        skippedCount: 0,
        truncated: false,
        rootMissing: true,
      );
    }

    final files = <ScannedFile>[];
    var skipped = 0;
    var truncated = false;

    // 手工栈迭代，避免深层嵌套目录递归爆栈。
    final pending = <Directory>[root];
    while (pending.isNotEmpty && !truncated) {
      final dir = pending.removeLast();
      final List<FileSystemEntity> entries;
      try {
        // followLinks: false —— 链接不展开遍历，杜绝链接环死循环。
        entries = await dir.list(followLinks: false).toList();
      } catch (_) {
        skipped++; // 目录无权限 / 已消失：静默计数。
        continue;
      }
      for (final entry in entries) {
        // followLinks: false 下链接以 Link 类型返回：一律不展开遍历
        // （链接环免疫），目标缺失（悬空）的链接计为不可访问。
        if (entry is Directory) {
          pending.add(entry);
          continue;
        }
        if (entry is! File) {
          final stat = await _statQuiet(entry);
          if (stat == null || stat.type == FileSystemEntityType.notFound) {
            skipped++;
          }
          continue;
        }
        // 真实文件：stat 取大小（竞态消失 → notFound，计不可访问）。
        final stat = await _statQuiet(entry);
        if (stat == null || stat.type != FileSystemEntityType.file) {
          skipped++;
          continue;
        }
        final ext = p.extension(entry.path).replaceFirst('.', '').toLowerCase();
        if (ext.isEmpty) continue;
        // 由注册表统一判定支持性（= 各 handler 扩展名的并集）。
        if (_registry.byExtension(ext) == null) continue;
        // 达到上限即截断：本文件与后续可导入文件不再收集
        // （名额只被可导入文件占用）。
        if (files.length >= maxFiles) {
          truncated = true;
          break;
        }
        files.add(
          ScannedFile(
            path: entry.path,
            relativePath: p.relative(entry.path, from: rootPath),
            ext: ext,
            sizeBytes: stat.size,
          ),
        );
      }
    }

    files.sort((a, b) => a.relativePath.compareTo(b.relativePath));
    return ScanResult(
      files: files,
      skippedCount: skipped,
      truncated: truncated,
      rootMissing: false,
    );
  }

  /// 带静默兜底的 stat：任何异常返回 null（调用方计为不可访问）。
  Future<FileStat?> _statQuiet(FileSystemEntity entity) async {
    try {
      return await entity.stat();
    } catch (_) {
      return null;
    }
  }
}
