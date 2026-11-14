class MpvMenuShortcuts {
  const MpvMenuShortcuts({
    this.open = 'Ctrl+Alt+m',
    this.up = 'UP',
    this.down = 'DOWN',
    this.confirm = 'ENTER',
    this.close = 'ESC',
  });

  final String open;
  final String up;
  final String down;
  final String confirm;
  final String close;

  List<String> get values => [open, up, down, confirm, close];

  Map<String, String> toJson() => {
    'open': open,
    'up': up,
    'down': down,
    'confirm': confirm,
    'close': close,
  };

  factory MpvMenuShortcuts.fromJson(Map<String, dynamic> json) {
    const defaults = MpvMenuShortcuts();
    return MpvMenuShortcuts(
      open: json['open'] as String? ?? defaults.open,
      up: json['up'] as String? ?? defaults.up,
      down: json['down'] as String? ?? defaults.down,
      confirm: json['confirm'] as String? ?? defaults.confirm,
      close: json['close'] as String? ?? defaults.close,
    );
  }
}
