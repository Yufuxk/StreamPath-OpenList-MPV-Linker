import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import '../theme/glass_tokens.dart';
import 'directory_scroll_view.dart';
import 'sp_icons.dart';

/// 菜单整体复用对话框材质，背景模糊只施加一次。
class SPMenuSurface extends StatelessWidget {
  const SPMenuSurface({
    super.key,
    required this.child,
    this.radius = AppTheme.dropdownBorderRadius,
  });
  final Widget child;
  final BorderRadius radius;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = theme.glass;
    final surface = Material(
      color: glass.enabled
          ? glass.modalSurface
          : AppTheme.dropdownMenuColor(theme),
      surfaceTintColor: Colors.transparent,
      elevation: glass.enabled ? glass.modalElevation : 4,
      shadowColor: glass.modalShadowColor,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(
          color: glass.enabled
              ? glass.modalBorderColor
              : theme.colorScheme.outlineVariant,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
    if (!glass.enabled) return surface;
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: glass.modalBlurSigma,
          sigmaY: glass.modalBlurSigma,
        ),
        child: surface,
      ),
    );
  }
}

Future<T?> showSPMenu<T>({
  required BuildContext context,
  required RelativeRect position,
  required List<PopupMenuEntry<T>> items,
  T? initialValue,
  bool useRootNavigator = false,
  BoxConstraints? constraints,
  bool? requestFocus,
  Color? color,
  ShapeBorder? shape,
}) => showMenu<T>(
  context: context,
  position: position,
  useRootNavigator: useRootNavigator,
  constraints: constraints,
  requestFocus: requestFocus,
  color: Colors.transparent,
  surfaceTintColor: Colors.transparent,
  elevation: 0,
  shadowColor: Colors.transparent,
  shape:
      shape ??
      const RoundedRectangleBorder(borderRadius: AppTheme.dropdownBorderRadius),
  clipBehavior: Clip.antiAlias,
  menuPadding: EdgeInsets.zero,
  items: [
    _SPMenuPanel<T>(
      items,
      initialValue: initialValue,
      maxHeight: math.min(
        constraints?.maxHeight ?? double.infinity,
        MediaQuery.sizeOf(context).height -
            MediaQuery.paddingOf(context).vertical -
            32,
      ),
    ),
  ],
);

class _SPMenuPanel<T> extends PopupMenuEntry<T> {
  const _SPMenuPanel(this.items, {this.initialValue, required this.maxHeight});
  final List<PopupMenuEntry<T>> items;
  final T? initialValue;
  final double maxHeight;
  @override
  double get height => items.fold(16, (height, entry) => height + entry.height);
  @override
  bool represents(T? value) => false;
  @override
  State<_SPMenuPanel<T>> createState() => _SPMenuPanelState<T>();
}

class _SPMenuPanelState<T> extends State<_SPMenuPanel<T>> {
  @override
  Widget build(BuildContext context) => SPMenuSurface(
    child: ConstrainedBox(
      constraints: BoxConstraints(maxHeight: widget.maxHeight),
      child: DirectoryScrollView(
        builder: (controller) => SingleChildScrollView(
          controller: controller,
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final entry in widget.items)
                if (widget.initialValue != null &&
                    entry.represents(widget.initialValue))
                  ColoredBox(
                    color: Theme.of(context).highlightColor,
                    child: entry,
                  )
                else
                  entry,
            ],
          ),
        ),
      ),
    ),
  );
}

class SPPopupMenuButton<T> extends StatelessWidget {
  const SPPopupMenuButton({
    super.key,
    required this.itemBuilder,
    this.tooltip,
    this.icon,
    this.initialValue,
    this.onSelected,
  });
  final PopupMenuItemBuilder<T> itemBuilder;
  final String? tooltip;
  final Widget? icon;
  final T? initialValue;
  final PopupMenuItemSelected<T>? onSelected;
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip ?? MaterialLocalizations.of(context).showMenuTooltip,
    icon: icon ?? const Icon(SPIcons.more),
    onPressed: () async {
      final box = context.findRenderObject()! as RenderBox;
      final overlay =
          Navigator.of(context).overlay!.context.findRenderObject()!
              as RenderBox;
      final position = RelativeRect.fromRect(
        Rect.fromPoints(
          box.localToGlobal(Offset.zero, ancestor: overlay),
          box.localToGlobal(
            box.size.bottomRight(Offset.zero),
            ancestor: overlay,
          ),
        ),
        Offset.zero & overlay.size,
      );
      final value = await showSPMenu<T>(
        context: context,
        position: position,
        items: itemBuilder(context),
        initialValue: initialValue,
      );
      if (value != null) onSelected?.call(value);
    },
  );
}

Widget buildSPTextSelectionMenu(
  BuildContext context,
  EditableTextState state,
) => buildSPSelectionToolbar(
  context,
  state.contextMenuAnchors,
  state.contextMenuButtonItems,
);

Widget buildSPSelectionToolbar(
  BuildContext context,
  TextSelectionToolbarAnchors anchors,
  List<ContextMenuButtonItem> items,
) {
  if (Theme.of(context).platform != TargetPlatform.windows) {
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: anchors,
      buttonItems: items,
    );
  }
  const edge = 8.0;
  final top = MediaQuery.paddingOf(context).top + edge;
  return Padding(
    padding: EdgeInsets.fromLTRB(edge, top, edge, edge),
    child: CustomSingleChildLayout(
      delegate: DesktopTextSelectionToolbarLayoutDelegate(
        anchor: anchors.primaryAnchor - Offset(edge, top),
      ),
      child: SizedBox(
        width: 222,
        child: SPMenuSurface(
          radius: const BorderRadius.all(Radius.circular(8)),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: AdaptiveTextSelectionToolbar.getAdaptiveButtons(
                context,
                items,
              ).toList(),
            ),
          ),
        ),
      ),
    ),
  );
}

/// 表单字段和弹出选项共用整块菜单，不使用旧透明下拉路由。
class SPDropdownButtonFormField<T> extends FormField<T> {
  SPDropdownButtonFormField({
    super.key,
    required this.items,
    super.initialValue,
    required this.onChanged,
    this.decoration,
    this.dropdownColor,
    this.borderRadius,
    this.isExpanded = false,
    this.isDense = true,
    this.hint,
    this.disabledHint,
    super.validator,
    super.onSaved,
    this.style,
    this.icon,
    this.menuMaxHeight,
    this.focusNode,
    this.autofocus = false,
    this.onTap,
    this.onMenuClosed,
    this.itemHeight = kMinInteractiveDimension,
    super.autovalidateMode,
    this.selectedItemBuilder,
    this.padding,
  }) : super(
         enabled: onChanged != null && (items?.isNotEmpty ?? false),
         builder: (state) => _SPDropdownField<T>(state: state),
       );
  final List<DropdownMenuItem<T>>? items;
  final ValueChanged<T?>? onChanged;
  final InputDecoration? decoration;
  final Color? dropdownColor;
  final BorderRadius? borderRadius;
  final bool isExpanded, isDense, autofocus;
  final Widget? hint, disabledHint, icon;
  final TextStyle? style;
  final double? menuMaxHeight, itemHeight;
  final FocusNode? focusNode;
  final VoidCallback? onTap, onMenuClosed;
  final DropdownButtonBuilder? selectedItemBuilder;
  final EdgeInsetsGeometry? padding;
  @override
  FormFieldState<T> createState() => _SPDropdownFormFieldState<T>();
}

class _SPDropdownFormFieldState<T> extends FormFieldState<T> {
  @override
  void didUpdateWidget(covariant SPDropdownButtonFormField<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialValue != widget.initialValue) {
      setValue(widget.initialValue);
    }
  }
}

class _SPDropdownField<T> extends StatefulWidget {
  const _SPDropdownField({required this.state});
  final FormFieldState<T> state;
  @override
  State<_SPDropdownField<T>> createState() => _SPDropdownFieldState<T>();
}

class _SPDropdownFieldState<T> extends State<_SPDropdownField<T>> {
  bool _focused = false, _open = false;
  final _ownedFocusNode = FocusNode();
  FocusNode get _focusNode => field.focusNode ?? _ownedFocusNode;
  SPDropdownButtonFormField<T> get field =>
      widget.state.widget as SPDropdownButtonFormField<T>;
  Future<void> _show() async {
    if (!field.enabled || _open) return;
    _focusNode.requestFocus();
    field.onTap?.call();
    _open = true;
    try {
      final box = context.findRenderObject()! as RenderBox;
      final overlay =
          Navigator.of(context).overlay!.context.findRenderObject()!
              as RenderBox;
      final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
      final width = math.min(box.size.width, overlay.size.width - 16);
      final value = await showSPMenu<T>(
        context: context,
        position: RelativeRect.fromRect(
          Rect.fromLTWH(origin.dx, origin.dy + box.size.height, width, 0),
          Offset.zero & overlay.size,
        ),
        initialValue: widget.state.value,
        constraints: BoxConstraints(
          minWidth: width,
          maxWidth: width,
          maxHeight: field.menuMaxHeight ?? double.infinity,
        ),
        items: [
          for (final item in field.items!)
            PopupMenuItem<T>(
              value: item.value,
              enabled: item.enabled,
              onTap: item.onTap,
              height: field.itemHeight ?? kMinInteractiveDimension,
              child: Align(alignment: item.alignment, child: item.child),
            ),
        ],
      );
      if (!mounted || value == null) return;
      widget.state.didChange(value);
      field.onChanged!(value);
    } finally {
      _open = false;
      if (mounted) field.onMenuClosed?.call();
    }
  }

  @override
  void dispose() {
    _ownedFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final index =
        field.items?.indexWhere((item) => item.value == widget.state.value) ??
        -1;
    final selected = index < 0
        ? null
        : (field.selectedItemBuilder?.call(context)[index] ??
              field.items![index].child);
    final label = field.enabled
        ? selected ?? field.hint
        : field.disabledHint ?? selected ?? field.hint;
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowDown): ActivateIntent(),
      },
      child: Actions(
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _show();
              return null;
            },
          ),
        },
        child: Focus(
          focusNode: _focusNode,
          autofocus: field.autofocus,
          canRequestFocus: field.enabled,
          onFocusChange: (value) {
            if (mounted) setState(() => _focused = value);
          },
          child: Semantics(
            button: true,
            enabled: field.enabled,
            child: InkWell(
              canRequestFocus: false,
              onTap: field.enabled ? _show : null,
              borderRadius: field.borderRadius ?? AppTheme.dropdownBorderRadius,
              child: InputDecorator(
                isFocused: _focused,
                isEmpty: label == null,
                decoration: (field.decoration ?? const InputDecoration())
                    .copyWith(
                      enabled: field.enabled,
                      errorText: widget.state.errorText,
                    )
                    .applyDefaults(Theme.of(context).inputDecorationTheme),
                child: DefaultTextStyle(
                  style:
                      field.style ?? Theme.of(context).textTheme.titleMedium!,
                  child: Padding(
                    padding: field.padding ?? EdgeInsets.zero,
                    child: Row(
                      mainAxisSize: field.isExpanded
                          ? MainAxisSize.max
                          : MainAxisSize.min,
                      children: [
                        if (field.isExpanded)
                          Expanded(child: label ?? const SizedBox.shrink())
                        else
                          label ?? const SizedBox.shrink(),
                        const SizedBox(width: 8),
                        field.icon ??
                            Icon(
                              Icons.arrow_drop_down,
                              size: 16,
                              color: field.enabled
                                  ? Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant
                                  : Theme.of(context).disabledColor,
                            ),
                      ],
                    ),
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
