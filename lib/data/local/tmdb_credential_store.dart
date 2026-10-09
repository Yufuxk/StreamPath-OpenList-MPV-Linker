import 'windows_credential_text_store.dart';

/// TMDB 凭据与媒体来源凭据使用各自的独立目标。
class TmdbCredentialStore extends WindowsCredentialTextStore {
  const TmdbCredentialStore() : super(targetName);
  static const targetName = 'StreamPath/tmdb';
}
