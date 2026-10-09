import 'dart:convert';
import 'dart:io';
import '../models/media_connection.dart';
import '../models/film_catalog_item.dart';
import 'windows_credential_text_store.dart';

/// 独立来源配置只保存连接参数，密码和服务器令牌写入 Windows 凭据管理器。
class MediaConnectionStore {
  MediaConnectionStore(this.file);
  final File file;
  final List<MediaConnection> connections = [];
  Future<void> _tail = Future.value();
  Future<void> load() async {
    if (!await file.exists()) return;
    final value = jsonDecode(await file.readAsString()) as Map;
    if (value['version'] != 1) {
      throw const FilmCatalogException('connectionConfigFailed');
    }
    connections.clear();
    for (final json in value['sources'] as List) {
      final connection = MediaConnection.fromJson(
        Map<String, dynamic>.from(json as Map),
      );
      connection.validate();
      connections.add(connection);
    }
  }

  WindowsCredentialTextStore credential(String id) =>
      WindowsCredentialTextStore('StreamPath/media-source/$id');
  Future<Map<String, dynamic>> secrets(String id) async {
    final text = await credential(id).read();
    return text == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(text) as Map);
  }

  Future<void> save(
    MediaConnection connection, {
    Map<String, dynamic>? secrets,
  }) => _enqueue(() async {
    connection.validate();
    final credentials = credential(connection.id);
    final previous = secrets == null ? null : await credentials.read();
    if (secrets != null) {
      await credential(connection.id).write(jsonEncode(secrets));
    }
    final rows = [...connections];
    final index = rows.indexWhere((row) => row.id == connection.id);
    if (index < 0) {
      rows.add(connection);
    } else {
      rows[index] = connection;
    }
    try {
      await _write(rows);
    } catch (_) {
      if (secrets != null) {
        if (previous == null) { await credentials.delete(); } else { await credentials.write(previous); }
      }
      rethrow;
    }
    connections
      ..clear()
      ..addAll(rows);
  });
  Future<void> remove(String id) => _enqueue(() async {
    final rows = connections.where((row) => row.id != id).toList();
    await _write(rows);
    connections
      ..clear()
      ..addAll(rows);
    await credential(id).delete();
  });
  Future<void> _write(List<MediaConnection> rows) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.partial');
    await temporary.writeAsString(
      jsonEncode({
        'version': 1,
        'sources': rows.map((row) => row.toJson()).toList(),
      }),
      flush: true,
    );
    await temporary.rename(file.path);
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final task = _tail.then((_) => action());
    _tail = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  Future<void> close() => _tail;
}
