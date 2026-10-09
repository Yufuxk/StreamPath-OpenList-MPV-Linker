import 'package:flutter/material.dart';

import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import '../theme/app_theme.dart';
import '../theme/installed_fonts.dart';
import 'sp_controls.dart';
import 'sp_menu.dart';

/// 从系统字体列表选择界面字体，空值使用系统推荐字体。
class SPFontPicker extends StatefulWidget {
  const SPFontPicker({
    super.key,
    required this.selectedFamily,
    required this.onChanged,
  });

  final String? selectedFamily;
  final ValueChanged<String?> onChanged;

  @override
  State<SPFontPicker> createState() => _SPFontPickerState();
}

class _SPFontPickerState extends State<SPFontPicker> {
  late Future<List<String>> _families;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _families = InstalledFonts.list();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<String>>(
      future: _families,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Row(
            children: [
              const Expanded(child: AppText('读取系统字体失败')),
              SPButton(
                kind: SPButtonKind.subtle,
                onPressed: () =>
                    setState(() => _families = InstalledFonts.list()),
                label: const AppText('重试'),
              ),
            ],
          );
        }
        final names = snapshot.data ?? const <String>[];
        final selected = widget.selectedFamily;
        final options = [
          if (selected != null && !names.contains(selected)) selected,
          ...names,
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 4),
              child: ExcludeSemantics(
                child: AppText(
                  '软件字体',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            Semantics(
              label: context.l10n.text('软件字体'),
              child: SPDropdownButtonFormField<String>(
                key: const Key('interface-font-selector'),
                focusNode: _focusNode,
                onMenuClosed: _focusNode.unfocus,
                initialValue: selected ?? '',
                isExpanded: true,
                menuMaxHeight: 420,
                dropdownColor: AppTheme.dropdownMenuColor(Theme.of(context)),
                borderRadius: AppTheme.dropdownBorderRadius,
                items: [
                  DropdownMenuItem<String>(
                    value: '',
                    child: const AppText('系统默认（Segoe UI）'),
                  ),
                  for (final name in options)
                    DropdownMenuItem<String>(
                      value: name,
                      child: Text(name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: snapshot.hasData
                    ? (value) {
                        _focusNode.unfocus();
                        widget.onChanged(value == '' ? null : value);
                      }
                    : null,
              ),
            ),
          ],
        );
      },
    );
  }
}
