import 'package:flutter/material.dart';
import '../theme/glass_tokens.dart';
import '../localization/app_text.dart';
import 'glass_surface.dart';

class SettingsGroupCard extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = Theme.of(context).glass;
    return GlassSurface(
      level: GlassSurfaceLevel.raised,
      border: Border.all(color: tokens.borderColor),
      showShadow: false,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 24, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText(
                      title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (description.isNotEmpty) const SizedBox(height: 2),
                    if (description.isNotEmpty)
                      AppText(
                        description,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
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
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: child,
    );
  }
}
