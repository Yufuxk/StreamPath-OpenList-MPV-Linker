import 'package:flutter/material.dart';
import 'sp_icons.dart';

import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import '../theme/glass_tokens.dart';
import 'glass_surface.dart';

/// 视频、音频和蓝光会话共用的成品下边栏。
class PlaybackBar extends StatefulWidget {
  const PlaybackBar({
    super.key,
    required this.title,
    required this.dirLabel,
    required this.icon,
    required this.tooltip,
    required this.deleting,
    required this.onPressed,
    required this.onDelete,
    required this.onSecondaryTapDown,
    this.onSubtitles,
    this.onSkipSeason,
    this.onPrevious,
    this.onNext,
    this.subtitle,
  });

  final String title;
  final String dirLabel;
  final IconData icon;
  final String tooltip;
  final bool deleting;
  final VoidCallback? onPressed;
  final VoidCallback onDelete;
  final GestureTapDownCallback onSecondaryTapDown;
  final VoidCallback? onSubtitles;
  final VoidCallback? onSkipSeason;
  final VoidCallback? onPrevious, onNext;
  final Widget? subtitle;

  @override
  State<PlaybackBar> createState() => _PlaybackBarState();
}

class _PlaybackBarState extends State<PlaybackBar> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapDown: widget.onSecondaryTapDown,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 68,
          decoration: BoxDecoration(
            color: _hovered ? Theme.of(context).hoverColor : Colors.transparent,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    widget.subtitle ??
                        AppText(
                          widget.dirLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (widget.onSubtitles != null)
                _actionSlot(
                  IconButton(
                    icon: const Icon(SPIcons.subtitles),
                    tooltip: context.l10n.text('蓝光外挂字幕'),
                    onPressed: widget.deleting ? null : widget.onSubtitles,
                  ),
                ),
              if (widget.onPrevious != null)
                _actionSlot(
                  IconButton(
                    icon: const Icon(SPIcons.previous),
                    tooltip: context.l10n.text('上一集'),
                    onPressed: widget.deleting ? null : widget.onPrevious,
                  ),
                ),
              if (widget.onNext != null)
                _actionSlot(
                  IconButton(
                    icon: const Icon(SPIcons.next),
                    tooltip: context.l10n.text('下一集'),
                    onPressed: widget.deleting ? null : widget.onNext,
                  ),
                ),
              if (widget.onSkipSeason != null)
                _actionSlot(
                  IconButton(
                    icon: const Icon(SPIcons.next),
                    tooltip: context.l10n.text('跳过本季'),
                    onPressed: widget.deleting ? null : widget.onSkipSeason,
                  ),
                ),
              _actionSlot(
                IconButton.filled(
                  icon: Icon(widget.icon),
                  tooltip: context.l10n.text(widget.tooltip),
                  onPressed: widget.deleting ? null : widget.onPressed,
                ),
              ),
              _actionSlot(
                IconButton(
                  icon: const Icon(SPIcons.delete),
                  tooltip: context.l10n.text('删除并关闭对应播放器'),
                  onPressed: widget.deleting ? null : widget.onDelete,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionSlot(Widget button) =>
      SizedBox.square(dimension: 48, child: Center(child: button));
}

/// 多个播放下边栏共用的玻璃表面和分隔线。
class PlaybackBarsSurface extends StatelessWidget {
  const PlaybackBarsSurface({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).glass;
    return GlassSurface(
      level: GlassSurfaceLevel.raised,
      automaticBorder: false,
      showShadow: false,
      border: Border(top: BorderSide(color: tokens.dividerColor)),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var index = 0; index < children.length; index++) ...[
              if (index > 0)
                const Divider(height: 1, indent: 16, endIndent: 16),
              children[index],
            ],
          ],
        ),
      ),
    );
  }
}
