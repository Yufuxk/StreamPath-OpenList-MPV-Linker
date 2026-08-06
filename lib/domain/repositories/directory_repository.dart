import '../../data/models/web_dav_file.dart';

/// 目录仓库抽象接口。
///
/// 遵循 Clean Architecture 依赖倒置：UI/逻辑层只依赖此接口，
/// 具体实现（远程 WebDAV + Hive 缓存，或测试 Mock）可自由替换。
///
/// 接口语义围绕 **异步按需加载** 设计：
///  - 用户点击目录时调用 [fetchDirectory]（懒加载，不预取全部层级）；
///  - 界面首帧可先取 [cachedDirectory] 秒开，再后台刷新。
abstract interface class DirectoryRepository {
  /// 获取目录内容；[forceRefresh] 为 true 时跳过缓存强制走网络。
  Future<List<WebDavFile>> fetchDirectory(
    String path, {
    bool forceRefresh = false,
  });

  /// 同步读取缓存内容（无网络等待；无缓存返回 null）。
  List<WebDavFile>? cachedDirectory(String path);

  /// 将服务器返回的 href 解析为可访问的完整 URL（播放/下载用）。
  String resolveUrl(String href);

  /// 服务器根地址。
  String get baseUrl;
}
