/// 凭据规范化（写入前 + 读取时的防御；v1.1 移动端 401 排查）。
///
/// 规则（只动"两端"与不可见字符，中间的可见字符一律保留）：
/// - **去零宽字符**：U+200B（零宽空格）/ U+200C（零宽非连接符）/ U+200D
///   （零宽连接符）/ U+FEFF（BOM）。从网页/聊天窗口复制应用密码时最常见的
///   残留，坚果云一旦收到就一定 401（应用密码按字节比对）。
/// - **去首尾空白**：空格、制表符、回车、换行。复制时最容易带入，且在
///   密码框里**看不见**（obscureText 只显示圆点）。
/// - 中间的可见字符（大小写、内部空格）**不动**：应用密码是 16 位全小写
///   字母数字，中间不会有合法空格，擅自改动反而会引入新错误。
///
/// 两侧都要用：
/// - **写入前**（向导页落凭据）→ 存进去的就是干净值；
/// - **读取时**（[SyncFacade.readConfig]）→ 防御旧版本写入的脏数据
///   （历史版本只 trim 过账号、密码没 trim）。
library;

/// 零宽字符集合（U+200B~U+200D、U+FEFF）。
final RegExp _zeroWidthPattern = RegExp('[\u200B-\u200D\uFEFF]');

/// 规范化账号 / 应用密码：去零宽字符 + 去首尾空白。
///
/// 中间字符不动（大小写、内部空格保留）。
String normalizeCredentialValue(String raw) =>
    raw.replaceAll(_zeroWidthPattern, '').trim();

/// 规范化 WebDAV 服务地址：去零宽字符 + 去首尾空白 + 去尾斜杠。
///
/// 去尾斜杠后与「带尾斜杠」在请求构造上等价（两者都由 `_uri` 容忍），
/// 但统一成一种形态可以避免 `baseUrl + rootPath` 拼出 `//`。
String normalizeBaseUrlValue(String raw) {
  var value = normalizeCredentialValue(raw);
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

/// 规范化同步根目录：去零宽字符 + 去首尾空白（保留前导 `/`）。
String normalizeRootPathValue(String raw) => normalizeCredentialValue(raw);
