import 'dart:convert';
import 'dart:io';

import 'package:streampath/data/models/web_dav_file.dart';
import 'package:streampath/data/remote/webdav_client.dart';
import 'package:streampath/domain/services/webdav_bdmv_service.dart';
import 'package:streampath/domain/services/webdav_service.dart';

class _DelayedDav extends WebDAVService {
  _DelayedDav()
    : super(
        client: WebDavClient(baseUrl: 'https://disc.test/dav'),
        profileId: 'benchmark',
      );

  final requests = <String>[];
  int active = 0;
  int peak = 0;

  @override
  Future<List<WebDavFile>> fetchDirectory(
    String path, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh) throw StateError('Discovery must use fresh listings');
    requests.add(path);
    active++;
    if (active > peak) peak = active;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    active--;
    return _tree[path] ?? const [];
  }
}

WebDavFile _entry(String path, {bool directory = false}) => WebDavFile(
  name: path.split('/').last,
  href: Uri(path: '/dav/$path${directory ? '/' : ''}').toString(),
  isDirectory: directory,
  size: directory ? 0 : 100,
);

final _tree = <String, List<WebDavFile>>{
  'disc': [
    _entry('disc/BDMV', directory: true),
    _entry('disc/CERTIFICATE', directory: true),
  ],
  'disc/BDMV': [
    _entry('disc/BDMV/index.bdmv'),
    for (final name in ['BACKUP', 'CLIPINF', 'META', 'PLAYLIST', 'STREAM'])
      _entry('disc/BDMV/$name', directory: true),
  ],
  'disc/CERTIFICATE': [_entry('disc/CERTIFICATE/BACKUP', directory: true)],
  'disc/BDMV/BACKUP': [
    _entry('disc/BDMV/BACKUP/CLIPINF', directory: true),
    _entry('disc/BDMV/BACKUP/PLAYLIST', directory: true),
  ],
  'disc/BDMV/META': [_entry('disc/BDMV/META/DL', directory: true)],
  'disc/BDMV/CLIPINF': [],
  'disc/BDMV/PLAYLIST': [_entry('disc/BDMV/PLAYLIST/00001.mpls')],
  'disc/BDMV/STREAM': [],
  'disc/BDMV/BACKUP/CLIPINF': [],
  'disc/BDMV/BACKUP/PLAYLIST': [],
  'disc/BDMV/META/DL': [],
  'disc/CERTIFICATE/BACKUP': [],
};

Future<void> main() async {
  for (final cache in ['cold', 'warm']) {
    for (var run = 1; run <= 5; run++) {
      final dav = _DelayedDav();
      final clock = Stopwatch()..start();
      final disc = await WebDavBdmvService.discover(dav, 'disc');
      clock.stop();
      if (disc.files.isEmpty ||
          dav.requests.length != 12 ||
          dav.requests.toSet().length != 12) {
        throw StateError('Discovery request count changed');
      }
      stdout.writeln(
        'BDMV_DISCOVERY_BENCH=${jsonEncode({'cache': cache, 'run': run, 'elapsedMs': clock.elapsedMilliseconds, 'propfind': dav.requests.length, 'peak': dav.peak})}',
      );
    }
  }
}
