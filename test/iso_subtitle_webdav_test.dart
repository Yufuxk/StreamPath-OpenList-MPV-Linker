import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/core/errors/app_exception.dart';
import 'package:streampath/data/local/iso_subtitle_store.dart';
import 'package:streampath/data/models/web_dav_file.dart';
import 'package:streampath/data/remote/webdav_client.dart';
import 'package:streampath/domain/services/iso_subtitle_service.dart';
import 'package:streampath/domain/services/webdav_media_source_adapter.dart';
import 'package:streampath/domain/services/webdav_service.dart';

class _Webdav extends WebDAVService {
  _Webdav({String id = 'profile-one'})
    : super(
        client: WebDavClient(
          baseUrl: 'https://test.example/dav',
          username: 'test',
          password: 'secret',
        ),
        profileId: id,
      );
  final directories = <String, List<WebDavFile>>{};
  final downloads = <String>[];
  bool fail = false;
  @override
  Future<List<WebDavFile>> fetchDirectory(
    String path, {
    bool forceRefresh = false,
  }) async => directories[path] ?? [];
  @override
  Future<List<int>> fetchFileBytes(
    String url, {
    required int maxBytes,
    required Duration timeout,
  }) async {
    downloads.add(url);
    if (fail) throw AppException.network('Test failure');
    return [0xff, 0xfe, 65, 0];
  }
}

void main() {
  late Directory root;
  late _Webdav service;
  final iso = WebDavFile(
    name: '动画.iso',
    href: '/dav/BD/%E5%8A%A8%E7%94%BB.iso?token=secret',
    isDirectory: false,
    size: 100,
    modified: DateTime.utc(2026),
  );
  final sub = WebDavFile(
    name: 'mpls00003',
    href: '/dav/BD/Subs/mpls00003.ass',
    isDirectory: false,
    size: 4,
  );
  Future<IsoSubtitleContext> discover() async {
    final context = IsoSubtitleContext(
      source: WebDavMediaSourceAdapter(service),
      iso: iso,
      isoPath: 'BD/动画.iso',
      store: IsoSubtitleStore(Directory('${root.path}/maps')),
    );
    await context.discover();
    return context;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('iso-webdav-');
    service = _Webdav();
    service.directories['BD'] = [
      iso,
      const WebDavFile(name: 'Subs', href: '/dav/BD/Subs/', isDirectory: true),
      const WebDavFile(
        name: 'Fonts',
        href: 'https://evil.example/dav/BD/Fonts/',
        isDirectory: true,
      ),
    ];
    service.directories['BD/Subs'] = [
      sub,
      const WebDavFile(
        name: 'bad.ass',
        href: 'https://evil.example/dav/BD/Subs/bad.ass',
        isDirectory: false,
      ),
      const WebDavFile(
        name: 'deep.ass',
        href: '/dav/BD/Subs/deep/deep.ass',
        isDirectory: false,
      ),
      const WebDavFile(
        name: 'escape.ass',
        href: '/dav/BD/Subs/%2e%2e/escape.ass',
        isDirectory: false,
      ),
    ];
  });
  tearDown(() async => root.delete(recursive: true));
  test('href 扩展名、中文路径与源/层级隔离；会话复用已读取字节', () async {
    final context = await discover();
    expect(context.candidates.map((c) => c.path), ['BD/Subs/mpls00003.ass']);
    expect(context.effective, {'00003': 'BD/Subs/mpls00003.ass'});
    expect(service.downloads.length, 1);
    final session = await context.prepare(
      Directory('${root.path}/session'),
      sessionId: 'web',
      pipeName: 'pipe',
      menu: true,
      autoSelect: true,
    );
    expect(service.downloads.length, 1);
    final path = session.localBindings['00003']!;
    expect(await File(path).readAsBytes(), [0xff, 0xfe, 65, 0]);
    final script = await File(session.scriptPath!).readAsString();
    expect(script, isNot(contains('secret')));
    expect(script, isNot(contains('https://test.example')));
  });
  test('下载失败仍生成无字幕播放脚本，并记录失败状态', () async {
    service.fail = true;
    final context = await discover();
    final args = await context.prepareArgs(
      Directory('${root.path}/failed'),
      sessionId: 'fail',
      pipeName: 'pipe',
      menu: false,
      autoSelect: true,
    );
    expect(args.any((a) => a.startsWith('--script=')), isTrue);
    expect(context.issues, contains('download'));
  });
  test('不同 profile 的同名 ISO 不共享绑定 key', () async {
    final first = await discover();
    final source = WebDavMediaSourceAdapter(_Webdav(id: 'profile-two'));
    final second = IsoSubtitleContext(
      source: source,
      iso: iso,
      isoPath: 'BD/动画.iso',
      store: first.store,
    );
    expect(first.key, isNot(second.key));
  });
}
