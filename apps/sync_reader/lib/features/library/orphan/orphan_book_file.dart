/// 游离正文文件条目（FR-408）。
///
/// 扫描期生成的只读快照。游离文件的三种真实形态（docs/04 §7.1）：
/// - [OrphanShape.orphanArea]：本端删除/自检移入 `files/orphans/` 区的
///   整书目录（`{bookId}-{时间戳}/source.{ext}`，BookFileStore.moveToOrphans）；
/// - [OrphanShape.layeredResidue]：`books/{bookId}/source.{ext}` 分层目录
///   仍在、但 bookId 已不在 books 表（典型：收到他端 tombstone 后保留正文）；
/// - [OrphanShape.flat]：`books/{bookId}.{ext}` 平铺正文，主干不在 books 表。
library;

/// 游离条目来源形态。
enum OrphanShape {
  /// orphans/ 游离区（本端删除移入 / 自检迁移）。
  orphanArea,

  /// books/ 下分层目录残留（书目已不在）。
  layeredResidue,

  /// books/ 下平铺文件残留。
  flat,
}

/// 单个游离文件条目。
class OrphanBookFile {
  const OrphanBookFile({
    required this.path,
    required this.fileName,
    required this.stem,
    required this.ext,
    required this.sizeBytes,
    required this.formatId,
    this.containerPath,
    this.shape = OrphanShape.flat,
  });

  /// 正文文件绝对路径（挂回 / 惰性解析直接消费）。
  final String path;

  /// 展示名：平铺为文件名；目录形态为其所在目录名（含 bookId 语义）。
  final String fileName;

  /// bookId 语义主干：平铺为文件名主干；目录形态为目录名（orphans 区
  /// 已剥去 `-时间戳` 后缀）。封面残留清理按此查 `covers/{stem}.png`。
  final String stem;

  /// 正文小写扩展名（不含点）。
  final String ext;

  /// 正文字节数。
  final int sizeBytes;

  /// 格式标识（来自 handler.formatId，与 books.format 同名）。
  final String formatId;

  /// 承载条目的容器实体（目录形态为其目录；平铺为 null）。彻底删除按
  /// 容器递归删除；挂回成功后容器被清空，也应顺手移除。
  final String? containerPath;

  /// 来源形态（面板角标展示）。
  final OrphanShape shape;

  /// 展示用格式角标（如 `TXT`）。
  String get formatLabel => formatId.toUpperCase();

  /// 展示用来源角标。
  String get shapeLabel => switch (shape) {
    OrphanShape.orphanArea => '本端删除',
    OrphanShape.layeredResidue => '书目缺失',
    OrphanShape.flat => '未关联',
  };
}
