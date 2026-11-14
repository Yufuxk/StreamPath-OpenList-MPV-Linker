enum VideoWindowMode {
  external,
  embedded;

  static VideoWindowMode fromJson(Object? value) =>
      value == 'embedded' ? embedded : external;
}
