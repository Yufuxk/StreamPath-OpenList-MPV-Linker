import 'dart:async';

import 'package:flutter/material.dart';

import '../localization/app_localizations.dart';
import 'film_detail_buttons.dart';
import 'sp_back_icon.dart';

class FilmDetailBackButton extends StatefulWidget {
  const FilmDetailBackButton({super.key, required this.scrollController});
  final ScrollController scrollController;

  @override
  State<FilmDetailBackButton> createState() => _FilmDetailBackButtonState();
}

class _FilmDetailBackButtonState extends State<FilmDetailBackButton> {
  Timer? _scrollIdle;
  bool _scrolling = false;
  bool _hovered = false;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    widget.scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    _scrollIdle?.cancel();
    if (!_scrolling) setState(() => _scrolling = true);
    // 滚轮更新在同一帧开始和结束，保留短暂显示便于用户发现按钮。
    _scrollIdle = Timer(const Duration(milliseconds: 700), () {
      setState(() => _scrolling = false);
    });
  }

  @override
  void dispose() {
    widget.scrollController.removeListener(_onScroll);
    _scrollIdle?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _scrolling || _hovered || _focused;
    final actionStyle = FilmDetailActionButton.styleOf(context);
    return MouseRegion(
      key: const Key('film-detail-back-region'),
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Focus(
          onFocusChange: (value) => setState(() => _focused = value),
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            child: IgnorePointer(
              ignoring: !visible,
              child: FilmDetailActionSurface(
                radius: 999,
                child: IconButton(
                  key: const Key('film-detail-back'),
                  tooltip: context.l10n.text('返回'),
                  style: ButtonStyle(
                    backgroundColor: actionStyle.backgroundColor,
                    side: actionStyle.side,
                    shape: const WidgetStatePropertyAll(CircleBorder()),
                  ),
                  icon: const SPBackIcon(),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
