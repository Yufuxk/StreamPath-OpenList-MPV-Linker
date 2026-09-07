import 'package:flutter/material.dart';

import '../../data/models/local_root_config.dart';
import 'browser_page.dart';

/// 本地目录入口直接复用完整的浏览页交互和播放会话实现。
class LocalBrowserPage extends StatelessWidget {
  const LocalBrowserPage({super.key, required this.root});

  final LocalRootConfig root;

  @override
  Widget build(BuildContext context) => BrowserPage(localRoot: root);
}
