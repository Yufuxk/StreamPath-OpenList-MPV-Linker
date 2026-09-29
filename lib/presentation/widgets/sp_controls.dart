import 'package:flutter/material.dart';

/// StreamPath 桌面按钮的常用视觉层级。
enum SPButtonKind { primary, secondary, tonal, subtle }

/// Windows Fluent 图标字形；Windows 10 使用 MDL2 回退。
class SPGlyph extends StatelessWidget {
  const SPGlyph(this.codePoint, {super.key, this.size = 20, this.color});

  final int codePoint;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Text(
      String.fromCharCode(codePoint),
      textScaler: TextScaler.noScaling,
      style: TextStyle(
        inherit: false,
        fontFamily: 'Segoe Fluent Icons',
        fontFamilyFallback: const ['Segoe MDL2 Assets'],
        fontSize: size,
        height: 1,
        color: color ?? Theme.of(context).colorScheme.onSurface,
      ),
    ),
  );
}

/// 统一按钮的尺寸、边界及鼠标和键盘状态。
class SPButton extends StatelessWidget {
  const SPButton({
    super.key,
    this.controlKey,
    required this.onPressed,
    required this.label,
    this.icon,
    this.kind = SPButtonKind.secondary,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    this.minimumHeight = 36,
  });

  final Key? controlKey;
  final VoidCallback? onPressed;
  final Widget label;
  final Widget? icon;
  final SPButtonKind kind;
  final EdgeInsetsGeometry padding;
  final double minimumHeight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = switch (kind) {
      SPButtonKind.primary => scheme.primary,
      SPButtonKind.secondary => scheme.surfaceContainerHigh,
      SPButtonKind.tonal => scheme.primaryContainer,
      SPButtonKind.subtle => Colors.transparent,
    };
    final foreground = switch (kind) {
      SPButtonKind.primary => scheme.onPrimary,
      SPButtonKind.tonal => scheme.onPrimaryContainer,
      _ => scheme.onSurface,
    };
    Color stateBackground(Set<WidgetState> states) {
      if (states.contains(WidgetState.disabled)) {
        return scheme.onSurface.withValues(alpha: 0.06);
      }
      if (states.contains(WidgetState.pressed)) {
        return Color.alphaBlend(foreground.withValues(alpha: 0.16), background);
      }
      if (states.contains(WidgetState.hovered)) {
        return Color.alphaBlend(foreground.withValues(alpha: 0.08), background);
      }
      return background;
    }

    final style = ButtonStyle(
      animationDuration: const Duration(milliseconds: 120),
      backgroundColor: WidgetStateProperty.resolveWith(stateBackground),
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? scheme.onSurface.withValues(alpha: 0.38)
            : foreground,
      ),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      splashFactory: NoSplash.splashFactory,
      side: WidgetStateProperty.resolveWith(
        (states) => BorderSide(
          color: states.contains(WidgetState.focused)
              ? scheme.primary
              : kind == SPButtonKind.secondary
              ? scheme.outlineVariant
              : Colors.transparent,
          width: states.contains(WidgetState.focused) ? 2 : 1,
        ),
      ),
      shape: const WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
        ),
      ),
      padding: WidgetStatePropertyAll(padding),
      minimumSize: WidgetStatePropertyAll(Size(0, minimumHeight)),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    final child = icon == null
        ? label
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [icon!, const SizedBox(width: 8), label],
          );
    return switch (kind) {
      SPButtonKind.primary || SPButtonKind.tonal => FilledButton(
        key: controlKey,
        onPressed: onPressed,
        style: style,
        child: child,
      ),
      SPButtonKind.secondary => OutlinedButton(
        key: controlKey,
        onPressed: onPressed,
        style: style,
        child: child,
      ),
      SPButtonKind.subtle => TextButton(
        key: controlKey,
        onPressed: onPressed,
        style: style,
        child: child,
      ),
    };
  }
}

/// 保留调用方布局，只统一列表与导航行的交互表面。
class SPTile extends StatelessWidget {
  const SPTile({
    super.key,
    required this.child,
    this.onTap,
    this.onSecondaryTapDown,
    this.selected = false,
    this.borderRadius = BorderRadius.zero,
  });

  final Widget child;
  final VoidCallback? onTap;
  final GestureTapDownCallback? onSecondaryTapDown;
  final bool selected;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Ink(
      decoration: BoxDecoration(
        color: selected ? scheme.primaryContainer : Colors.transparent,
        borderRadius: borderRadius,
      ),
      child: InkWell(
        onTap: onTap,
        onSecondaryTapDown: onSecondaryTapDown,
        splashFactory: NoSplash.splashFactory,
        hoverColor: theme.hoverColor,
        highlightColor: theme.highlightColor,
        focusColor: theme.focusColor,
        hoverDuration: const Duration(milliseconds: 120),
        borderRadius: borderRadius,
        child: child,
      ),
    );
  }
}

/// 设置项开关沿用 Flutter 的表单语义，外观由主题统一控制。
class SPToggleTile extends SwitchListTile {
  const SPToggleTile({
    super.key,
    required super.value,
    required super.onChanged,
    super.title,
    super.subtitle,
    super.contentPadding,
  }) : super(dense: true);
}
