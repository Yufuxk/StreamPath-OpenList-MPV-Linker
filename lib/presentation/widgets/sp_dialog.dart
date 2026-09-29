import 'package:flutter/material.dart';

/// StreamPath 对话框内容；继续使用现有 showGlassDialog 路由和材质层。
class SPDialog extends StatelessWidget {
  const SPDialog({super.key, this.title, this.content, this.actions});

  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) =>
      AlertDialog(title: title, content: content, actions: actions);
}
