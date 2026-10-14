import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/glass_tokens.dart';
import '../localization/app_text.dart';
import 'glass_surface.dart';

class SettingsGroupCard extends StatefulWidget {
  const SettingsGroupCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String description;
  final Widget child;

  @override
  State<SettingsGroupCard> createState() => _SettingsGroupCardState();
}

class _SettingsGroupCardState extends State<SettingsGroupCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = Theme.of(context).glass;
    return GlassSurface(
      level: GlassSurfaceLevel.raised,
      border: Border.all(color: tokens.panelBorderColor),
      showShadow: false,
      borderRadius: AppTheme.panelRadius,
      blur: true,
      clipBehavior: Clip.antiAlias,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: AppTheme.hoverDuration,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: AppTheme.panelRadius,
            color: _hovered ? Theme.of(context).hoverColor : Colors.transparent,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnimatedOpacity(
                    opacity: _hovered ? 1 : 0.6,
                    duration: AppTheme.hoverDuration,
                    child: Icon(widget.icon, size: 24, color: scheme.primary),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AppText(
                          widget.title,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (widget.description.isNotEmpty)
                          const SizedBox(height: 2),
                        if (widget.description.isNotEmpty)
                          AppText(
                            widget.description,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              widget.child,
            ],
          ),
        ),
      ),
    );
  }
}

class SettingsProgressPanel extends StatelessWidget {
  const SettingsProgressPanel({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: .38),
        borderRadius: AppTheme.controlRadius,
        border: Border.all(color: Theme.of(context).glass.borderColor),
      ),
      child: child,
    );
  }
}
