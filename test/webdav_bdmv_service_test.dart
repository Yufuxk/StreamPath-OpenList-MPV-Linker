import 'dart:io';
import 'package:streampath/data/models/media_library_item.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/core/errors/app_exception.dart';
import 'package:streampath/data/local/iso_subtitle_store.dart';
import 'package:streampath/data/models/web_dav_file.dart';
import 'package:streampath/data/remote/webdav_client.dart';
import 'package:streampath/domain/services/webdav_service.dart';
import 'package:streampath/domain/services/webdav_bdmv_service.dart';
import 'package:streampath/domain/services/webdav_media_source_adapter.dart';
import 'package:streampath/domain/services/iso_subtitle_service.dart';
import 'package:streampath/domain/services/iso_access_provider.dart';
import 'package:streampath/domain/services/iso_bridge_client.dart';
import 'package:path/path.dart' as p;

class _Dav extends WebDAVService {
  _Dav()
    : super(
        client: WebDavClient(
          baseUrl: 'https://disc.test/dav',
          username: '',
          password: '',
        ),
        profileId: 'test',
      );
  final tree = <String, List<WebDavFile>>{};
  final reads = <String>[];
  @override
  Future<List<WebDavFile>> fetchDirectory(
    String path, {
    bool forceRefresh = false,
  }) async {
    reads.add(path);
    return tree[path] ?? [];
  }

  @override
  Future<List<int>> fetchFileBytes(
    String url, {
    required int maxBytes,
    required Duration timeout,
  }) async => '1\n00:00:01,000 --> 00:00:02,000\nHello\n'.codeUnits;
}

WebDavFile entry(String path, {bool directory = false, String? href}) =>
    WebDavFile(
      name: path.split('/').last,
      href: href ?? Uri(path: '/dav/$path${directory ? '/' : ''}').toString(),
      isDirectory: directory,
      size: directory ? 0 : 100,
    );

void main() {
  late _Dav dav;
  setUp(() {
    dav = _Dav();
    dav.tree['盘 片'] = [
      entry('盘 片/BDMV', directory: true),
      entry('盘 片/Subs', directory: true),
    ];
    dav.tree['盘 片/BDMV'] = [
      entry('盘 片/BDMV/index.bdmv'),
      for (final dir in ['PLAYLIST', 'CLIPINF', 'STREAM'])
        entry('盘 片/BDMV/$dir', directory: true),
    ];
    dav.tree['盘 片/BDMV/PLAYLIST'] = [entry('盘 片/BDMV/PLAYLIST/00001.mpls')];
    dav.tree['盘 片/BDMV/STREAM'] = [entry('盘 片/BDMV/STREAM/00001.m2ts')];
    dav.tree['盘 片/Subs'] = [entry('盘 片/Subs/mpls00001.srt')];
  });
  test('清单传递有效 HTTP 版本，弱 ETag 不作为内容身份', () async {
    dav.tree['盘 片/BDMV/PLAYLIST'] = [
      const WebDavFile(
        name: '00001.mpls',
        href: '/dav/盘 片/BDMV/PLAYLIST/00001.mpls',
        isDirectory: false,
        size: 100,
        etag: '"v1"',
        lastModifiedHeader: 'Wed, 26 Jun 2024 12:00:00 GMT',
      ),
    ];
    dav.tree['盘 片/BDMV/STREAM'] = [
      const WebDavFile(
        name: '00001.m2ts',
        href: '/dav/盘 片/BDMV/STREAM/00001.m2ts',
        isDirectory: false,
        size: 100,
        etag: 'W/"weak"',
        lastModifiedHeader: 'invalid',
      ),
    ];
    final disc = await WebDavBdmvService.discover(dav, '盘 片');
    final playlist = disc.files.singleWhere(
      (e) => e['path'] == 'BDMV/PLAYLIST/00001.mpls',
    );
    expect(playlist['etag'], '"v1"');
    expect(playlist['lastModified'], 'Wed, 26 Jun 2024 12:00:00 GMT');
    final stream = disc.files.singleWhere(
      (e) => e['path'] == 'BDMV/STREAM/00001.m2ts',
    );
    expect(stream.containsKey('etag'), isFalse);
    expect(stream.containsKey('lastModified'), isFalse);
  });

  test('根目录和 BDMV 入口一致，清单保留真实 href 且不扫描字幕/片库', () async {
    final root = await WebDavBdmvService.discover(dav, '盘 片');
    final folder = await WebDavBdmvService.discover(dav, '盘 片/BDMV');
    expect(root.href, folder.href);
    expect(root.files, folder.files);
    expect(root.isDirectory, isTrue);
    expect(root.isIso, isFalse);
    expect(root.href, contains('%E7%9B%98%20%E7%89%87/'));
    expect(dav.reads, isNot(contains('盘 片/Subs')));
    expect(dav.reads, isNot(contains('')));
  });
  test('拒绝跨源、子目录越界及大小写冲突', () async {
    for (final invalid in [
      entry('盘 片/BDMV/bad', href: 'https://evil.test/dav/盘 片/BDMV/bad'),
      entry('盘 片/BDMV/sub/extra'),
      entry('盘 片/BDMV/INDEX.BDMV'),
    ]) {
      dav.tree['盘 片/BDMV']!.add(invalid);
      await expectLater(
        WebDavBdmvService.discover(dav, '盘 片'),
        throwsA(isA<AppException>()),
      );
      dav.tree['盘 片/BDMV']!.removeLast();
    }
  });
  test('缺少 CLIPINF 不作为完整光盘打开', () async {
    dav.tree['盘 片/BDMV']!.removeWhere((e) => e.name == 'CLIPINF');
    await expectLater(
      WebDavBdmvService.discover(dav, '盘 片'),
      throwsA(isA<AppException>()),
    );
  });
  test('字幕从光盘根发现，原生 revision 更新后重载手动绑定', () async {
    final temp = await Directory.systemTemp.createTemp('bdmv-subs-');
    try {
      final disc = await WebDavBdmvService.discover(dav, '盘 片');
      disc.structureRevision = 'version-one';
      final context = IsoSubtitleContext(
        source: WebDavMediaSourceAdapter(dav),
        iso: disc,
        isoPath: disc.rootPath,
        store: IsoSubtitleStore(temp),
      );
      await context.discover();
      expect(context.candidates.map((e) => e.path), ['盘 片/Subs/mpls00001.srt']);
      expect(context.revision, 'version-one');
      await context.store.update(
        context.key,
        context.revision,
        '00001',
        '盘 片/Subs/mpls00001.srt',
      );
      await context.refreshDiscRevision();
      expect(context.bindings['00001'], '盘 片/Subs/mpls00001.srt');
      expect(context.changed, isFalse);
      disc.structureRevision = 'version-two';
      await context.refreshDiscRevision();
      expect(context.revision, 'version-two');
      expect(context.changed, isTrue);
      await File(
        p.join(temp.path, '${context.key}.json'),
      ).writeAsString('{broken');
      await context.refreshDiscRevision();
      expect(context.writable, isFalse);
      expect(context.issues, contains('map'));
    } finally {
      await temp.delete(recursive: true);
    }
  });
  test('BDMV 媒体库根路径持久化并兼容旧 ISO 记录', () {
    for (final root in ['', '盘 片']) {
      final item = MediaLibraryItem(
        sourceId: 'test',
        parentPath: '',
        name: '盘 片',
        kind: MediaLibraryKind.iso,
        discRootPath: root,
      );
      final restored = MediaLibraryItem.fromJson(item.toJson());
      expect(restored.discRootPath, root);
      expect(restored.targetPath, root);
      expect(restored.stableKey, item.stableKey);
    }
    final old = MediaLibraryItem.fromJson({
      'sourceId': 'test',
      'parentPath': 'films',
      'name': 'disc.iso',
      'kind': 'iso',
    });
    expect(old.discRootPath, isNull);
    expect(old.targetPath, 'films/disc.iso');
  });
  test('菜单目录 capability 不放松原 ISO 路径和长度校验', () {
    final session = p.join(Directory.systemTemp.path, 'bdmv-session');
    final msg = <String, dynamic>{
      'type': 'ready',
      'version': 1,
      'port': 0,
      'token': '0' * 32,
      'totalBytes': 12345,
      'titles': <Object>[],
      'capability': 'winfsp-bdmv-v1',
      'mode': 'hdmv',
      'discPath': p.join(session, 'disc'),
    };
    expect(
      IsoBridgeReady.fromMessage(
        msg,
        remoteMenu: true,
        bdmv: true,
        mountedSessionPath: session,
      ).discPath,
      p.join(session, 'disc'),
    );
    expect(
      () => IsoBridgeReady.fromMessage(
        msg,
        remoteMenu: true,
        mountedSessionPath: session,
      ),
      throwsA(isA<IsoBridgeProtocolException>()),
    );
    msg['discPath'] = p.join(session, 'elsewhere');
    expect(
      () => IsoBridgeReady.fromMessage(
        msg,
        remoteMenu: true,
        bdmv: true,
        mountedSessionPath: session,
      ),
      throwsA(isA<IsoBridgeProtocolException>()),
    );
  });
}
