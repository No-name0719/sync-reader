/// 阅读设置实体（FR-206）：排版仅本地保存，不同步（docs/07 记录）。
///
/// v1.1（docs/10 A10/A11/A14/Q2/Q5/Q9）：
/// - 阅读主题 3→4 套（纸白/米黄/护眼/夜间），色值权威源为
///   `core/design_tokens.dart` 的 [AppReaderTheme]/`ReaderPalette`；
/// - 出厂默认：字号 19、行高 1.95、翻页模式「分页」（旧版默认滚动）；
/// - 字体三选（衬线·黑体·楷体），衬线为默认（Q2），系统字体栈不打包（Q4）。
library;

import '../../../core/design_tokens.dart'
    show AppFonts, AppReaderTheme, ReaderPalette;

/// 阅读主题（Q5：纸白 / 米黄 / 护眼 / 夜间 四套；与 [AppReaderTheme] 一一对应）。
///
/// 色值不在此定义——权威源为 design_tokens 的 `ReaderPalette`，
/// 各渲染器主题映射经 [toAppReaderTheme] 取色。
enum ReaderTheme {
  /// 纸白（默认）。
  paper('纸白'),

  /// 米黄（旧版「纸张」的升级）。
  beige('米黄'),

  /// 护眼（v1.1 新增，淡绿）。
  green('护眼'),

  /// 夜间（比旧版 #121212 更柔和）。
  dark('夜间');

  const ReaderTheme(this.label);

  /// 中文显示名（排版面板/设置页用）。
  final String label;

  /// → 设计令牌阅读主题（唯一取色入口）。
  AppReaderTheme toAppReaderTheme() => switch (this) {
    ReaderTheme.paper => AppReaderTheme.paper,
    ReaderTheme.beige => AppReaderTheme.beige,
    ReaderTheme.green => AppReaderTheme.green,
    ReaderTheme.dark => AppReaderTheme.dark,
  };

  /// 该主题的权威配色（design_tokens [ReaderPalette]）。
  ReaderPalette get palette => toAppReaderTheme().palette;
}

/// 翻页模式。
enum ReaderPageMode { scroll, page }

/// 正文段落首行缩进（A10：2em，两个全角空格 U+3000 等价实现——Flutter 无
/// 原生 text-indent，全角空格是中文排版的通行做法）。
///
/// txt 分页测量/渲染、epub/md 段落显示层与 Aa 面板预览共用本常量，
/// 避免四处各写一份。
const String kReaderParagraphIndent = '\u3000\u3000';

/// txt 正文编码覆盖（渲染时生效；`auto` = BOM → 严格 UTF-8 → GBK 探测）。
/// 新格式编码按需扩展枚举值（docs/02 §D2.5：扩展格式自由）。
enum ReaderTextEncoding { auto, utf8, gbk }

/// 阅读偏好值对象（不可变；经 JSON 存入 reader_settings 表）。
class ReaderSettings {
  const ReaderSettings({
    this.fontSize = 19.0,
    this.lineHeight = 1.95,
    this.pageMargin = 16.0,
    this.theme = ReaderTheme.paper,
    this.fontFamily,
    this.pageMode = ReaderPageMode.page,
    this.txtEncodingOverride = ReaderTextEncoding.auto,
    this.volumeKeyPageTurn = false,
  });

  /// 出厂默认（docs/10 §4.4：正文 19px / 行高 1.95；Q9 默认分页；
  /// Q2 默认衬线——由字体解析把 null 解析为衬线栈）。
  static const ReaderSettings defaults = ReaderSettings();

  /// 正文字号（逻辑像素；出厂默认 19，范围 12–32、步进 1，A14）。
  final double fontSize;

  /// 行距倍数（出厂默认 1.95，docs/10 §4.4）。
  final double lineHeight;

  /// 页边距（逻辑像素，四边对称）。
  final double pageMargin;

  /// 阅读主题（纸白/米黄/护眼/夜间）。
  final ReaderTheme theme;

  /// 字体族原始设置（null = 默认衬线；历史遗留键与 [AppFonts] 常量统一经
  /// [resolvedFontFamily]/[resolvedFontFamilyFallback] 解析）。
  final String? fontFamily;

  /// 翻页模式：滚动 / 分页（Q9：出厂默认分页）。
  final ReaderPageMode pageMode;

  /// txt 编码覆盖。
  final ReaderTextEncoding txtEncodingOverride;

  /// 音量键翻页（FR-209，Android 专属）：开启后按音量键翻页、不再调节
  /// 音量（音量上键 = 上一页，音量下键 = 下一页）；其他平台该设置无效。
  final bool volumeKeyPageTurn;

  /// 当前 JSON 形态标记（v1.1 = 2；旧数据无该键）。
  ///
  /// 主题枚举 v1.1 重命名后，持久化名 `'paper'` 在新旧语义下含义不同
  /// （v1.0 = 米黄系「纸张」，v1.1 = 纸白），必须靠形态标记消歧：
  /// 读旧值（无标记）时 `'paper'` 映射为米黄，repository 随即以新形态
  /// 覆写落盘，此后 `'paper'` 恒为新语义（纸白）。
  static const int jsonSchemaVersion = 2;

  /// v1.0 旧主题名 → 新枚举映射（docs/10 A11 迁移）：
  /// - v1.0 `light`（浅色）→ [ReaderTheme.paper]（纸白）；
  /// - v1.0 `paper`（纸张，米黄系 #F5EFDC）→ [ReaderTheme.beige]（米黄）；
  /// - v1.0 `dark` → [ReaderTheme.dark]（夜间，色值换新 #14151A）；
  /// - 未知值回落默认 [ReaderTheme.paper]（只增不删，读方容错）。
  static ReaderTheme themeFromLegacyName(Object? name) => switch (name) {
    'light' => ReaderTheme.paper,
    'paper' => ReaderTheme.beige,
    'dark' => ReaderTheme.dark,
    'beige' || 'green' => ReaderTheme.paper, // 理论不出现在 v1.0：防御回落
    _ => ReaderTheme.paper,
  };

  /// JSON 序列化（存 reader_settings 表；演进只增不删，读方容忍未知键）。
  Map<String, Object?> toJson() => {
    'v': jsonSchemaVersion,
    'fontSize': fontSize,
    'lineHeight': lineHeight,
    'pageMargin': pageMargin,
    'theme': theme.name,
    'fontFamily': fontFamily,
    'pageMode': pageMode.name,
    'txtEncodingOverride': txtEncodingOverride.name,
    'volumeKeyPageTurn': volumeKeyPageTurn,
  };

  /// JSON 反序列化；未知枚举值/缺字段一律回落默认，保证向后兼容。
  ///
  /// 主题读取按 [jsonSchemaVersion] 分流：新形态直读枚举名；
  /// 旧形态（无 `v` 键）经 [themeFromLegacyName] 容错映射
  /// （light→paper、paper→beige、dark→dark，未知→paper）。
  factory ReaderSettings.fromJson(Map<String, Object?> json) {
    T? enumByName<T extends Enum>(List<T> values, Object? name) =>
        values.where((v) => v.name == name).firstOrNull;
    final isNewSchema = json['v'] == jsonSchemaVersion;
    return ReaderSettings(
      fontSize: switch (json['fontSize']) {
        final num n => n.toDouble(),
        _ => defaults.fontSize,
      },
      lineHeight: switch (json['lineHeight']) {
        final num n => n.toDouble(),
        _ => defaults.lineHeight,
      },
      pageMargin: switch (json['pageMargin']) {
        final num n => n.toDouble(),
        _ => defaults.pageMargin,
      },
      theme: isNewSchema
          ? (enumByName(ReaderTheme.values, json['theme']) ?? defaults.theme)
          : themeFromLegacyName(json['theme']),
      fontFamily: switch (json['fontFamily']) {
        final String s => s,
        _ => null,
      },
      pageMode:
          enumByName(ReaderPageMode.values, json['pageMode']) ??
          defaults.pageMode,
      txtEncodingOverride:
          enumByName(ReaderTextEncoding.values, json['txtEncodingOverride']) ??
          defaults.txtEncodingOverride,
      volumeKeyPageTurn: switch (json['volumeKeyPageTurn']) {
        final bool b => b,
        _ => defaults.volumeKeyPageTurn, // 旧 JSON 无该键 → 默认关闭（向后兼容）
      },
    );
  }

  /// 复制并部分覆盖。
  ReaderSettings copyWith({
    double? fontSize,
    double? lineHeight,
    double? pageMargin,
    ReaderTheme? theme,
    String? fontFamily,
    bool clearFontFamily = false,
    ReaderPageMode? pageMode,
    ReaderTextEncoding? txtEncodingOverride,
    bool? volumeKeyPageTurn,
  }) => ReaderSettings(
    fontSize: fontSize ?? this.fontSize,
    lineHeight: lineHeight ?? this.lineHeight,
    pageMargin: pageMargin ?? this.pageMargin,
    theme: theme ?? this.theme,
    fontFamily: clearFontFamily ? null : (fontFamily ?? this.fontFamily),
    pageMode: pageMode ?? this.pageMode,
    txtEncodingOverride: txtEncodingOverride ?? this.txtEncodingOverride,
    volumeKeyPageTurn: volumeKeyPageTurn ?? this.volumeKeyPageTurn,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReaderSettings &&
          fontSize == other.fontSize &&
          lineHeight == other.lineHeight &&
          pageMargin == other.pageMargin &&
          theme == other.theme &&
          fontFamily == other.fontFamily &&
          pageMode == other.pageMode &&
          txtEncodingOverride == other.txtEncodingOverride &&
          volumeKeyPageTurn == other.volumeKeyPageTurn;

  @override
  int get hashCode => Object.hash(
    fontSize,
    lineHeight,
    pageMargin,
    theme,
    fontFamily,
    pageMode,
    txtEncodingOverride,
    volumeKeyPageTurn,
  );

  @override
  String toString() => 'ReaderSettings${toJson()}';
}

/// 字体栈解析结果：主字体 + 回退栈（Q4：系统字体栈，不打包字体文件）。
class ReaderFontStack {
  const ReaderFontStack(this.family, this.fallback);

  /// 主字体（TextStyle.fontFamily）。
  final String family;

  /// 回退栈（TextStyle.fontFamilyFallback）。
  final List<String> fallback;
}

/// 衬线（宋体）回退栈（Q2 默认正文；docs/10 §3.2 阅读正文栈）。
const List<String> kSerifFontFallback = <String>[
  'Source Han Serif SC',
  'Songti SC',
  'SimSun',
];

/// 黑体回退栈。
const List<String> kSansFontFallback = <String>[
  'Microsoft YaHei',
  'PingFang SC',
  'Source Han Sans SC',
];

/// 楷体回退栈。
const List<String> kKaiFontFallback = <String>[
  'STKaiti',
  'KaiTi_GB2312',
  'DFKai-SB',
];

/// 字体设置原始值 → 字体栈解析（三渲染器共用，保证排版一致）。
///
/// 接受的历史值：
/// - null / '' → 衬线（Q2 默认）；
/// - v1.0 面板控件键 `'serif'` → 衬线、`'sans'` → 黑体、`'monospace'` → 等宽；
/// - 设置页写入的 [AppFonts] 常量（'Noto Serif SC' 等）按语义归位；
/// - 其它自定义字体名按名称直用，回退衬线栈。
ReaderFontStack resolveReaderFont(String? fontFamily) {
  switch (fontFamily) {
    case null || '':
      return ReaderFontStack(AppFonts.serif, kSerifFontFallback);
    case 'serif' || AppFonts.serif:
      return ReaderFontStack(AppFonts.serif, kSerifFontFallback);
    case 'sans' || AppFonts.sans:
      return ReaderFontStack(AppFonts.sans, kSansFontFallback);
    case 'kai' || AppFonts.kai:
      return ReaderFontStack(AppFonts.kai, kKaiFontFallback);
    case 'monospace':
      return ReaderFontStack(AppFonts.mono, const <String>['monospace']);
    default:
      return ReaderFontStack(fontFamily, kSerifFontFallback);
  }
}

/// 阅读设置的字体解析便捷扩展。
extension ReaderSettingsFonts on ReaderSettings {
  /// 解析后的正文主字体（Q2：null/未设置 = 衬线宋体）。
  String get resolvedFontFamily => resolveReaderFont(fontFamily).family;

  /// 解析后的字体回退栈。
  List<String> get resolvedFontFamilyFallback =>
      resolveReaderFont(fontFamily).fallback;
}
