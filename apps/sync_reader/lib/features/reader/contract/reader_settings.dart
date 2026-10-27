/// 阅读设置实体（FR-206）：排版仅本地保存，不同步（docs/07 记录）。
library;

/// 阅读主题。
enum ReaderTheme { light, dark, paper }

/// 翻页模式。
enum ReaderPageMode { scroll, page }

/// txt 正文编码覆盖（渲染时生效；`auto` = BOM → 严格 UTF-8 → GBK 探测）。
/// 新格式编码按需扩展枚举值（docs/02 §D2.5：扩展格式自由）。
enum ReaderTextEncoding { auto, utf8, gbk }

/// 阅读偏好值对象（不可变；经 JSON 存入 reader_settings 表）。
class ReaderSettings {
  const ReaderSettings({
    this.fontSize = 18.0,
    this.lineHeight = 1.6,
    this.pageMargin = 16.0,
    this.theme = ReaderTheme.light,
    this.fontFamily,
    this.pageMode = ReaderPageMode.scroll,
    this.txtEncodingOverride = ReaderTextEncoding.auto,
  });

  /// 出厂默认。
  static const ReaderSettings defaults = ReaderSettings();

  /// 正文字号（逻辑像素）。
  final double fontSize;

  /// 行距倍数。
  final double lineHeight;

  /// 页边距（逻辑像素，四边对称）。
  final double pageMargin;

  /// 主题：浅色 / 深色 / 纸张色。
  final ReaderTheme theme;

  /// 字体族（null = 平台默认）。
  final String? fontFamily;

  /// 翻页模式：滚动 / 分页。
  final ReaderPageMode pageMode;

  /// txt 编码覆盖。
  final ReaderTextEncoding txtEncodingOverride;

  /// JSON 序列化（存 reader_settings 表；演进只增不删，读方容忍未知键）。
  Map<String, Object?> toJson() => {
    'fontSize': fontSize,
    'lineHeight': lineHeight,
    'pageMargin': pageMargin,
    'theme': theme.name,
    'fontFamily': fontFamily,
    'pageMode': pageMode.name,
    'txtEncodingOverride': txtEncodingOverride.name,
  };

  /// JSON 反序列化；未知枚举值/缺字段一律回落默认，保证向后兼容。
  factory ReaderSettings.fromJson(Map<String, Object?> json) {
    T? enumByName<T extends Enum>(List<T> values, Object? name) =>
        values.where((v) => v.name == name).firstOrNull;
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
      theme: enumByName(ReaderTheme.values, json['theme']) ?? defaults.theme,
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
  }) => ReaderSettings(
    fontSize: fontSize ?? this.fontSize,
    lineHeight: lineHeight ?? this.lineHeight,
    pageMargin: pageMargin ?? this.pageMargin,
    theme: theme ?? this.theme,
    fontFamily: clearFontFamily ? null : (fontFamily ?? this.fontFamily),
    pageMode: pageMode ?? this.pageMode,
    txtEncodingOverride: txtEncodingOverride ?? this.txtEncodingOverride,
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
          txtEncodingOverride == other.txtEncodingOverride;

  @override
  int get hashCode => Object.hash(
    fontSize,
    lineHeight,
    pageMargin,
    theme,
    fontFamily,
    pageMode,
    txtEncodingOverride,
  );

  @override
  String toString() => 'ReaderSettings${toJson()}';
}
