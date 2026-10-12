import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 橱窗与侧边栏共用的内嵌浮动滑块组合按钮，选中状态由调用方持有。
class FilmSegmentedControl<T> extends StatelessWidget {
  const FilmSegmentedControl({
    super.key,
    required this.segments,
    required this.selected,
    required this.onSelectionChanged,
    this.direction = Axis.horizontal,
  }) : assert(segments.length > 0);

  /// 每个选项须提供非空 label。
  final List<ButtonSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onSelectionChanged;
  final Axis direction;

  @override
  Widget build(BuildContext context) {
    final index = segments.indexWhere((segment) => segment.value == selected);
    assert(index >= 0, 'The selected value must belong to the segments.');
    const shape = StadiumBorder();
    final vertical = direction == Axis.vertical;
    final position = segments.length == 1
        ? 0.0
        : -1 + 2 * index / (segments.length - 1);

    Widget button(ButtonSegment<T> segment) {
      final selectedSegment = segment.value == selected;
      final content = Semantics(
        label: segment.tooltip,
        selected: selectedSegment,
        inMutuallyExclusiveGroup: true,
        child: TextButton(
          key: ValueKey(segment.value),
          onPressed: segment.enabled
              ? () {
                  if (!selectedSegment) onSelectionChanged(segment.value);
                }
              : null,
          style:
              TextButton.styleFrom(
                foregroundColor: selectedSegment
                    ? Colors.black
                    : Colors.white.withValues(alpha: .7),
                disabledForegroundColor: selectedSegment
                    ? Colors.black.withValues(alpha: .38)
                    : Colors.white.withValues(alpha: .38),
                backgroundColor: Colors.transparent,
                minimumSize: Size(0, vertical ? 54 : 34),
                padding: EdgeInsets.symmetric(
                  horizontal: vertical ? 0 : 12,
                  vertical: 7,
                ),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.standard,
                shape: shape,
                textStyle: TextStyle(
                  fontSize: 12,
                  fontWeight: selectedSegment
                      ? FontWeight.w600
                      : FontWeight.w500,
                ),
              ).copyWith(
                side: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.focused)
                      ? BorderSide(
                          color: (selectedSegment ? Colors.black : Colors.white)
                              .withValues(alpha: .7),
                        )
                      : BorderSide.none,
                ),
                overlayColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.pressed)
                      ? (selectedSegment ? Colors.black : Colors.white)
                            .withValues(alpha: .12)
                      : states.contains(WidgetState.hovered)
                      ? (selectedSegment ? Colors.black : Colors.white)
                            .withValues(alpha: .06)
                      : Colors.transparent,
                ),
              ),
          child: segment.label!,
        ),
      );
      return segment.tooltip == null
          ? content
          : Tooltip(
              message: segment.tooltip!,
              excludeFromSemantics: true,
              child: content,
            );
    }

    final content = Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedAlign(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              alignment: AlignmentDirectional(
                vertical ? 0 : position,
                vertical ? position : 0,
              ),
              child: FractionallySizedBox(
                widthFactor: vertical ? 1 : 1 / segments.length,
                heightFactor: vertical ? 1 / segments.length : 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(999),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x40000000),
                        blurRadius: 6,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (vertical)
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final segment in segments)
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: button(segment),
                ),
            ],
          )
        else
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final segment in segments) Expanded(child: button(segment)),
            ],
          ),
      ],
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          constraints: BoxConstraints(minWidth: vertical ? 0 : 180),
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .6),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.white.withValues(alpha: .15)),
          ),
          child: vertical ? content : IntrinsicWidth(child: content),
        ),
      ),
    );
  }
}
