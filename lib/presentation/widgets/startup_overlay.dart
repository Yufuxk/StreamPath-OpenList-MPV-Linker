import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../localization/app_text.dart';

/// 首屏完成布局后淡出并释放整窗加载遮罩。
class StartupOverlay extends StatefulWidget {
  const StartupOverlay({super.key, required this.ready, required this.child});

  final ValueListenable<bool> ready;
  final Widget child;

  @override
  State<StartupOverlay> createState() => _StartupOverlayState();
}

class _StartupOverlayState extends State<StartupOverlay> {
  bool _removed = false;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: widget.ready,
    builder: (context, ready, child) => Stack(
      fit: StackFit.expand,
      children: [
        Opacity(
          key: const Key('startup-content'),
          opacity: ready ? 1 : 0,
          child: child!,
        ),
        if (!_removed)
          Positioned.fill(
            child: AnimatedOpacity(
              key: const Key('startup-overlay'),
              opacity: ready ? 0 : 1,
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              onEnd: () {
                if (widget.ready.value) setState(() => _removed = true);
              },
              child: AbsorbPointer(
                child: Material(
                  key: const Key('startup-surface'),
                  color: Theme.of(context).scaffoldBackgroundColor,
                  child: Center(
                    child: SizedBox(
                      width: 240,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'StreamPath',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 24),
                          const LinearProgressIndicator(minHeight: 3),
                          const SizedBox(height: 16),
                          const AppText('正在加载影视库…'),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
    child: widget.child,
  );
}
