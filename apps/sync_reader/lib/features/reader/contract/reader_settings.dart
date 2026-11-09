/// 阅读设置实体（FR-206）：排版仅本地保存，不同步（docs/07 记录）。
///
/// v1.1（docs/10 A10/A11/A14/Q2/Q5/Q9）：
/// - 阅读主题 3→4 套，色值权威源为 `core/design_tokens.dart` 的
///   [AppReaderTheme]/`ReaderPalette`；
/// - 出厂默认：字号 19、行高 1.95、翻页模式「分页」（旧版默认滚动）；
/// - 字体三选（衬线·黑体·楷体），衬线为默认（Q2），系统字体栈不打包（Q4）。
///
/// v1.2（docs/10 A23–A26，阅读页重设计）：
/// - 阅读主题 4→7 套（B2）：枚举名稳定（持久化兼容），label 改朴素颜色
///   描述，新增 slate/dusk/ink；
/// - 新增段距（整行空行）、首行缩进开关、夜间亮度（B3）、翻页动画（B5）
///   四项排版设置；
/// - JSON schema v3：v≥2 直读主题枚举名（v1 的 legacy 映射仅对更旧数据），
///   新增键缺省回落默认（只增不删，读方容忍）。
library;

import '../../../core/design_tokens.dart'
    show AppFonts, AppReaderTheme, ReaderPalette;

/// 阅读主题（B2：白色/米黄/浅绿/浅灰蓝/深灰/深棕/纯黑 七套；
/// 与 [AppReaderTheme] 一一对应）。
///
/// 色值不在此定义——权威源为 design_tokens 的 `ReaderPalette`，
/// 各渲染器主题映射经 [toAppReaderTheme] 取色。
enum ReaderTheme {
  /// 白色（默认；v1.1 label「纸白」）。
  paper('白色'),

  /// 米黄（旧版「纸张」的升级）。
  beige('米黄'),

  /// 浅绿（v1.1 label「护眼」）。
  green('浅绿'),

  /// 浅灰蓝（v1.2 新增）。
  slate('浅灰蓝'),

  /// 深灰（夜间系；v1.1 label「夜间」）。
  dark('深灰'),

  /// 深棕（夜间系，暖调；v1.2 新增）。
  dusk('深棕'),

  /// 纯黑（夜间系，OLED 友好；v1.2 新增）。
  ink('纯黑');

  const ReaderTheme(this.label);

  /// 中文显示名（排版面板/设置页用；朴素颜色描述，B2）。
  final String label;

  /// 是否夜间系（B3：夜间亮度滑块只在夜间系背景出现）。
  bool get isNight => switch (this) {
    ReaderTheme.dark || ReaderTheme.dusk || ReaderTheme.ink => true,
    _ => false,
  };

  /// → 设计令牌阅读主题（唯一取色入口）。
  AppReaderTheme toAppReaderTheme() => switch (this) {
    ReaderTheme.paper => AppReaderTheme.paper,
    ReaderTheme.beige => AppReaderTheme.beige,
    ReaderTheme.green => AppReaderTheme.green,
    ReaderTheme.slate => AppReaderTheme.slate,
    ReaderTheme.dark => AppReaderTheme.dark,
    ReaderTheme.dusk => AppReaderTheme.dusk,
    ReaderTheme.ink => AppReaderTheme.ink,
  };

  /// 该主题的权威配色（design_tokens [ReaderPalette]）。
  ReaderPalette get palette => toAppReaderTheme().palette;
}

/// 翻页模式。
enum ReaderPageMode { scroll, page }

/// 翻页动画方式（B5）：上下滑动为默认（正文像滚动一样纵向推移），
/// 左右翻页横向推移。仅分页模式有意义。
enum ReaderPageTurnAxis { vertical, horizontal }

/// 段距（B4）：以**整行**为单位的段间空行数——「紧」= 段间无空行仅靠
/// 缩进分段（中文书籍通行排法）；空行属显示层插入，不改字符坐标语义，
/// 且不破坏行网格（每页行数恒定、页底留白恒定）。
enum ReaderParagraphGap {
  /// 紧：段间无空行。
  tight(0),

  /// 疏：段间空一行。
  oneLine(1),

  /// 松：段间空两行。
  twoLines(2);

  const ReaderParagraphGap(this.lines);

  /// 段间空行数（整行单位）。
  final int lines;
}

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
    this.pageTurnAxis = ReaderPageTurnAxis.vertical,
    this.paragraphGap = ReaderParagraphGap.tight,
    this.firstLineIndent = true,
    this.nightBrightness = 1.0,
    this.txtEncodingOverride = ReaderTextEncoding.auto,
    this.volumeKeyPageTurn = false,
  });

  /// 出厂默认（docs/10 §4.4：正文 19px / 行高 1.95；Q9 默认分页；
  /// Q2 默认衬线——由字体解析把 null 解析为衬线栈；B5 默认上下滑动）。
  static const ReaderSettings defaults = ReaderSettings();

  /// 正文字号（逻辑像素；出厂默认 19，范围 12–32、步进 1，A14）。
  final double fontSize;

  /// 行距倍数（出厂默认 1.95，docs/10 §4.4）。
  final double lineHeight;

  /// 页边距（逻辑像素，四边对称）。
  final double pageMargin;

  /// 阅读主题（白色/米黄/浅绿/浅灰蓝/深灰/深棕/纯黑，B2）。
  final ReaderTheme theme;

  /// 字体族原始设置（null = 默认衬线；历史遗留键与 [AppFonts] 常量统一经
  /// [resolvedFontFamily]/[resolvedFontFamilyFallback] 解析）。
  final String? fontFamily;

  /// 翻页模式：滚动 / 分页（Q9：出厂默认分页）。
  final ReaderPageMode pageMode;

  /// 翻页动画方式（B5）：上下滑动（默认）/ 左右翻页；仅分页模式有意义。
  final ReaderPageTurnAxis pageTurnAxis;

  /// 段距（B4）：紧 / 空一行 / 空两行（整行单位，出厂默认紧）。
  final ReaderParagraphGap paragraphGap;

  /// 段落首行缩进 2em 开关（B4；关 = 顶格，显示层不再插全角空格）。
  final bool firstLineIndent;

  /// 夜间亮度系数（B3）：0.8–1.3，作用于整屏（背景与正文一起变）；
  /// 仅夜间系主题（[ReaderTheme.isNight]）生效，出厂默认 1.0。
  final double nightBrightness;

  /// txt 编码覆盖。
  final ReaderTextEncoding txtEncodingOverride;

  /// 音量键翻页（FR-209，Android 专属）：开启后按音量键翻页、不再调节
  /// 音量（音量上键 = 上一页，音量下键 = 下一页）；其他平台该设置无效。
  final bool volumeKeyPageTurn;

  /// 当前 JSON 形态标记（v1.2 = 3；旧数据无该键或为 2）。
  ///
  /// v2 引入形态标记消歧 `'paper'` 新旧语义（v1 = 米黄系「纸张」，
  /// v2+ = 纸白）。v3 仅新增键（段距/缩进/亮度/翻页动画），缺省回落
  /// 默认，主题读取规则与 v2 相同：**v≥2 直读枚举名，v<2 走 legacy 映射**。
  static const int jsonSchemaVersion = 3;

  /// v1.0 旧主题名 → 新枚举映射（docs/10 A11 迁移）：
  /// - v1.0 `light`（浅色）→ [ReaderTheme.paper]（白色）；
  /// - v1.0 `paper`（纸张，米黄系 #F5EFDC）→ [ReaderTheme.beige]（米黄）；
  /// - v1.0 `dark` → [ReaderTheme.dark]（深灰，色值换新 #14151A）；
  /// - 未知值回落默认 [ReaderTheme.paper]（只增不删，读方容错）。
  static ReaderTheme themeFromLegacyName(Object? name) => switch (name) {
    'light' => ReaderTheme.paper,
    'paper' => ReaderTheme.beige,
    'dark' => ReaderTheme.dark,
    'beige' || 'green' || 'slate' || 'dusk' || 'ink' => ReaderTheme.paper,
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
    'pageTurnAxis': pageTurnAxis.name,
    'paragraphGap': paragraphGap.name,
    'firstLineIndent': firstLineIndent,
    'nightBrightness': nightBrightness,
    'txtEncodingOverride': txtEncodingOverride.name,
    'volumeKeyPageTurn': volumeKeyPageTurn,
  };

  /// JSON 反序列化；未知枚举值/缺字段一律回落默认，保证向后兼容。
  ///
  /// 主题读取按持久化的形态标记分流：v≥2 直读枚举名（v3 与 v2 同规则）；
  /// v1 旧形态（无 `v` 键）经 [themeFromLegacyName] 容错映射
  /// （light→paper、paper→beige、dark→dark，未知→paper）。
  factory ReaderSettings.fromJson(Map<String, Object?> json) {
    T? enumByName<T extends Enum>(List<T> values, Object? name) =>
        values.where((v) => v.name == name).firstOrNull;
    final schemaVersion = switch (json['v']) {
      final int n => n,
      _ => 1,
    };
    final readsEnumThemeDirectly = schemaVersion >= 2;
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
      theme: readsEnumThemeDirectly
          ? (enumByName(ReaderTheme.values, json['theme']) ?? defaults.theme)
          : themeFromLegacyName(json['theme']),
      fontFamily: switch (json['fontFamily']) {
        final String s => s,
        _ => null,
      },
      pageMode:
          enumByName(ReaderPageMode.values, json['pageMode']) ??
          defaults.pageMode,
      pageTurnAxis:
          enumByName(ReaderPageTurnAxis.values, json['pageTurnAxis']) ??
          defaults.pageTurnAxis,
      paragraphGap:
          enumByName(ReaderParagraphGap.values, json['paragraphGap']) ??
          defaults.paragraphGap,
      firstLineIndent: switch (json['firstLineIndent']) {
        final bool b => b,
        _ => defaults.firstLineIndent,
      },
      nightBrightness: switch (json['nightBrightness']) {
        final num n => n.toDouble().clamp(0.8, 1.3),
        _ => defaults.nightBrightness,
      },
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
    ReaderPageTurnAxis? pageTurnAxis,
    ReaderParagraphGap? paragraphGap,
    bool? firstLineIndent,
    double? nightBrightness,
    ReaderTextEncoding? txtEncodingOverride,
    bool? volumeKeyPageTurn,
  }) => ReaderSettings(
    fontSize: fontSize ?? this.fontSize,
    lineHeight: lineHeight ?? this.lineHeight,
    pageMargin: pageMargin ?? this.pageMargin,
    theme: theme ?? this.theme,
    fontFamily: clearFontFamily ? null : (fontFamily ?? this.fontFamily),
    pageMode: pageMode ?? this.pageMode,
    pageTurnAxis: pageTurnAxis ?? this.pageTurnAxis,
    paragraphGap: paragraphGap ?? this.paragraphGap,
    firstLineIndent: firstLineIndent ?? this.firstLineIndent,
    nightBrightness: nightBrightness ?? this.nightBrightness,
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
          pageTurnAxis == other.pageTurnAxis &&
          paragraphGap == other.paragraphGap &&
          firstLineIndent == other.firstLineIndent &&
          nightBrightness == other.nightBrightness &&
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
    pageTurnAxis,
    paragraphGap,
    firstLineIndent,
    nightBrightness,
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
