import 'package:flutter/material.dart';

import 'directory_wheel_scroll_region.dart';

/// 设置分类的独立表单容器。
///
/// 每个分类拥有自己的 [Form]、滚动控制器和页面存储键，分类切换不会串用验证或滚动状态。
class SettingsCategoryForm extends StatelessWidget {
  const SettingsCategoryForm({
    super.key,
    required this.sectionName,
    required this.formKey,
    required this.scrollController,
    required this.content,
  });

  final String sectionName;
  final GlobalKey<FormState> formKey;
  final ScrollController scrollController;
  final Widget content;

  @override
  Widget build(BuildContext context) {
    return Form(
      key: formKey,
      child: DirectoryWheelScrollRegion(
        controller: scrollController,
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: Scrollbar(
            key: ValueKey<String>('settings-scrollbar-$sectionName'),
            controller: scrollController,
            thumbVisibility: true,
            interactive: true,
            child: SingleChildScrollView(
              key: PageStorageKey<String>('settings-page-$sectionName'),
              controller: scrollController,
              padding: EdgeInsets.fromLTRB(
                MediaQuery.sizeOf(context).width < 900 ? 16 : 24,
                16,
                MediaQuery.sizeOf(context).width < 900 ? 16 : 24,
                24,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1200),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [content],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
