/// 跨页面共用的用户可见文案常量。
///
/// 同一句话在多个页面出现时抽到这里，避免同一含义出现两套措辞。
/// 仅放**确实跨模块复用**的文案；模块内独有的文案仍留在各自文件里。
library;

/// 删除本书的确认弹窗正文（书库页与书籍详情页共用同一段）。
///
/// 措辞依据 `docs/10-界面重设计方案.md` §4.7b 的删除语义规范：
/// 本地立即移出书库、正文文件删除、墓碑同步到云端。
const String kDeleteBookDialogBody =
    '删除后的行为：\n'
    '· 本书会从书库移除（阅读进度一并清除）；\n'
    '· 本地正文文件立即删除（释放磁盘空间，不可恢复）；\n'
    '· 删除标记会同步到云端，其他设备的此书也会从书库移除'
    '（它们的正文文件仍保留）。\n\n'
    '不会删除你磁盘上的原始书籍文件。';

/// 删除本书的确认弹窗标题（书库页与书籍详情页共用）。
String deleteBookDialogTitle(String title) => '删除《$title》？';

/// 导入时「同时上传到云端」勾选项标题。
const String kImportUploadToCloudLabel = '同时上传到云端';

/// 导入时未勾选上传的说明（书库页与批量导入页共用）。
const String kImportNotUploadHint = '其它设备看不到这几本书';

/// 批量导入入口标题（书库页与批量导入页共用）。
const String kBatchImportFolderTitle = '批量导入（文件夹）';

/// 导入进度文案（书库页与批量导入页共用）。
String importProgressLabel(int completed, int total, String currentName) =>
    '正在导入（$completed/$total）：$currentName';

/// 尚未配置同步账号时的提示（占位书下载失败分支共用）。
const String kSyncNotConfiguredHint =
    '尚未配置同步账号，请先在"同步设置"中完成配置';

/// 连接测试执行异常时的失败文案（同步设置页与引导页共用）。
const String kConnectionTestExceptionText = '连接测试执行异常，请稍后重试';

/// 目录不可得时的占位文案。
const String kTocUnavailableText = '暂不可得';
