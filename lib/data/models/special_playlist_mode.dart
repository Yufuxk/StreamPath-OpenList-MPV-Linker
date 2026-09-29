enum SpecialPlaylistMode {
  off,
  ovaOnly,
  all;

  static SpecialPlaylistMode fromJson(Object? value) =>
      SpecialPlaylistMode.values.where((mode) => mode.name == value).firstOrNull ??
      SpecialPlaylistMode.ovaOnly;
}
