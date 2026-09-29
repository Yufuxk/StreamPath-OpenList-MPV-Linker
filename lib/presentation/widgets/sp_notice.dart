import 'package:flutter/material.dart';

/// 全局短反馈入口；外观由 StreamPath 主题统一控制。
class SPNotice extends SnackBar {
  const SPNotice({super.key, required super.content, super.duration});
}
