enum DiscTitleSelectionPolicy {
  full,
  single,
  adaptive;

  static DiscTitleSelectionPolicy fromJson(Object? value) =>
      values.where((policy) => policy.name == value).firstOrNull ?? full;
}
