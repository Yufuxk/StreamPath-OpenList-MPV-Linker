enum FilmWatchStatus { unwatched, inProgress, watched }

class FilmWatchState {
  const FilmWatchState({
    this.status = FilmWatchStatus.unwatched,
    this.fraction = 0,
  });
  final FilmWatchStatus status;
  final double fraction;
  static const unwatched = FilmWatchState();
  static const watched = FilmWatchState(
    status: FilmWatchStatus.watched,
    fraction: 1,
  );
  factory FilmWatchState.fromFraction(double value) => value >= 1
      ? watched
      : value > 0
      ? FilmWatchState(status: FilmWatchStatus.inProgress, fraction: value)
      : unwatched;
}
